# Roadmap

The single living list of what to do next — features, defects, and security
work in one ranked queue. The top item is the biggest win, work top to
bottom. 

**Adding an issue to the roadmap**
An issue must state its goal and why it's worth building. Where the value is user-visible, include user stories — concrete moments that show the feature earning its place. Internal plumbing items wont usually have a user story. An issue must also include context for the plan author — a roadmap entry is **not** an implementation plan. Plans get written per issue (the `/plan` skill) when the work is picked up.  

Ranking criteria is **impact-per-effort**, mission impact weighed against cost. A medium-impact quick win outranks a high-impact slog.  Place the new issue in the appropriate order for its priority.  

**Removing an issue from the roadmap**
Issue numbers are ranks, not stable identifiers - when something ships, delete all trace of it from the roadmap and let the rest renumber (the `/ship` skill handles this). If a shipped issue had a detailed plan doc, move that doc to [archive/](archive/) with a status banner. Nothing else about a ship stays here — this file documents future work only, and ship history lives in git, CLAUDE.md's Current focus, and [archive/](archive/). A shipped issue is mentioned below only where an *open* item needs it as context.  **Cite an issue by its title, never by its rank**
A rank is correct only until the next ship, and a stale one doesn't look stale — it silently points at a different item. Any cross-reference written by rank will quickly become wrong, trust me, its happened a lot.

**[Deliberately not planned](#deliberately-not-planned)**
The section at the end of this file records ideas that were weighed and
declined, each with the condition that would reopen it. Check it before
proposing or re-proposing work. Add to the list when rejecting a proposed issue.  


---

## #1 · The mirror goes stale after a burst of structural changes — and stays stale

**Goal:** after a burst of structural changes — several undos, several
creates, a handful of deletes by hand in Live — `get_session_state` converges
on the truth by itself. It must never present a track that no longer exists as
present.

**Why:** measured 2026-08-01, smoke-testing the undo-granularity branch. Three
`create_track` calls, then three `undo` calls (all three undos worked — the
tracks really were gone in Live). The three reads that followed:

1. `get_session_state`, no refresh → errored, "the session mirror did not
   answer — it may be mid-refresh against an unresponsive Ableton."
2. `get_session_state`, no refresh → a **stale, internally inconsistent**
   snapshot: it listed the deleted Track 1 "Bass" as present, alongside a
   Track 2 whose name, pan, volume and mute were all "unknown".
3. `get_session_state` with `refresh: true` → correct: only Track 0 "1-MIDI".

Reading 2 is the defect. The mirror did not say "I don't know" — it named a
deleted track as present, which is the same class of failure the "no
fabricated values" work removed for the scalar song fields and never closed
for the track list. A producer has no reason to suspect the answer, and no
reason to know `refresh` exists.

Three causes compound, and no single one of them is the whole bug:

- **The debounce window is shorter than the gap between tool calls.**
  `@refresh_debounce_ms` is 1,000ms
  ([lib/seshat/session/state.ex](../lib/seshat/session/state.ex)), but calls
  issued in *separate model rounds* arrive ~2.1s apart at the floor (measured
  2026-07-31, recorded in the `/smoke-test` skill). So a burst spread over
  several rounds never coalesces — each call gets its own refresh — and each
  refresh is still in flight when the next mutation lands. For this pattern
  1,000ms is close to the worst available value: too short to merge, long
  enough to overlap.
- **A rebuild racing a structural change comes back degraded.** `do_refresh/1`
  reads `num_tracks`, then queries five properties per index. When a track
  disappears between those, the per-index query gets no reply at all
  (AbletonOSC's track getters are silent on a bad index), the caller waits out
  the 5s timeout, and later replies run one index behind — `read_tracks/2`'s
  echo check then rejects every name and yields `nil`. That is the "unknown"
  Track 2.
- **The brake then stops it healing.** `finalize_reconciliations/3` records a
  rebuild that couldn't reproduce the pushed list as `unreconciled` and
  deliberately does not retry, which is correct as far as it goes — it is what
  stops an unbounded refresh/re-subscribe/push spin. But the result is a
  knowingly-wrong mirror held indefinitely behind a single `Logger.warning`,
  until `refresh: true`, `/live/startup`, or a *different* push list arrives.

**User stories:**
- As a producer, after undoing the last few things I asked for, asking "what's
  in the set?" tells me what is actually there — not a track I just removed.
- As a producer, I never have to learn that a "refresh" exists, or that asking
  twice gives different answers.
- As a producer, undoing a batch costs one verification read after the batch,
  not a state read after every undo or a chain of automatic retries.

**Planner notes:**

Three changes, ranked. The first is the one that makes the mirror honest, the
second is what makes it recover, and the third prevents the race but wants
measurement before it is taken.

1. **A degraded rebuild must never become the mirror.** *(the must-do)*
   `do_refresh/1` already states this rule and argues for it — when
   `num_tracks` fails it sets `tracks: nil` rather than keeping the old list,
   because *"keeping the old list serves the previous set's tracks as this
   set's. Unknown, not stale-but-plausible."* That rule simply does not cover
   the case measured here: when the count *answers* but the per-track reads
   fail, the half-`nil` list is merged in wholesale. Every query helper returns
   a bare `nil` on an echo mismatch or a timeout, so a rebuild that resolved
   nothing is indistinguishable from one that resolved everything — which is
   how "Bass, present" ended up beside a row of unknowns. Fix: if a rebuild
   could not name tracks it should have named, treat the track read as failed
   and set `tracks: nil`. This applies a rule the file already argues for to
   the case it doesn't reach, and it converts a confidently wrong answer into
   an honest one.

2. **Distinguish "disagreed" from "degraded"; allow exactly one retry.**
   *(makes it self-heal)* The brake in `finalize_reconciliations/3` is right to
   exist — without it the unbounded refresh → re-subscribe → push → refresh
   spin its comment describes is real. But it currently treats "Live says X,
   the mirror says Y" and "the rebuild resolved nothing at all" as the same
   outcome, and only the first is a genuine disagreement. A rebuild that
   yielded `nil` for everything has not disagreed with the push, it has
   *failed*. Give that case one re-schedule and record the brake only if the
   second attempt also fails. One retry is bounded; it is not the spin. This is
   the smallest change that would have let the measured run recover without
   the user knowing `refresh: true` exists.

3. **Stop re-deriving a count that was just handed to us.** *(prevents it —
   measure first)* This is what made the first read error, and the arithmetic
   is stark: `@query_timeout` is 5,000ms and `read_tracks/2` issues **five**
   queries per index, so a single over-reported track is **25 seconds** of dead
   waiting. Upstream's `/live/track/get/name` is silent on a bad index — no
   error, no reply, just the full timeout, five times over. Meanwhile
   `song_structure.py` has already pushed the authoritative name list,
   atomically, from Live's own callback, and `reconcile/4` receives it as
   `names` before discarding it to re-derive the count via `num_tracks`. Using
   `length(names)` when the refresh was triggered by a structure push removes
   the dead-index queries in the common case. Ranked third because it narrows
   the race rather than closing it — another change landing mid-read still
   skews it — and because it alters the refresh's shape rather than its failure
   handling.

**Two fixes that look obvious and should not be taken:**

- **Do not raise `@refresh_debounce_ms` past the ~2.1s inter-round floor.** It
  would make bursts genuinely coalesce, but it widens the interval in which
  every read is served from a stale mirror. That trades this symptom for a
  quieter one, and the quieter one is harder to notice.
- **Do not have `undo`/`redo` call `State.refresh/0`.** They don't today, which
  is why the mirror only learned via `song_structure.py`'s push — but adding it
  papers over the one trigger that happened to be measured. The identical race
  reproduces from hand-edits in Live with no tool call involved.

**Scope and coverage:**
- Changes 1 and 2 together are roughly 30 lines in one file
  ([lib/seshat/session/state.ex](../lib/seshat/session/state.ex)), and are what
  convert this from silently wrong to honest and self-correcting.
- Keep the consumer-side contract explicit in `get_session_state`'s description
  and degraded/error replies: after a batch, read once at the end; never retry
  automatically in the same response, including with `refresh: true`. If that
  one read cannot verify the result, report the uncertainty to the user.
- Repeat the Claude Desktop reproduction as an orchestration acceptance check:
  after three tracks are created and the user says "undo", the trace is exactly
  three `undo` calls followed by one ordinary `get_session_state` call — no
  reads between undos and no follow-up state call.
- Fold in **"Unit coverage for the mirror-refresh cross-key loop brake"**
  (further down this queue): the brake is precisely the mechanism under-tested
  here, and changes 1 and 2 both land inside it, so a fix wants that coverage
  anyway.
- Full evidence, including the wire-level reasoning, is in PR #54's body under
  "Live verification".

## #2 · `undo` reports success it never observed

**Goal:** `undo` and `redo` stop claiming an outcome they cannot see, and a
batch undo ends with the model able to say what actually reverted — without a
state read after every single call.

**Why:** measured 2026-08-01, running the repeated-undo acceptance check
through Claude Desktop. Three MIDI tracks were created in one request (Bass,
then Keys, then Drums); "undo that" produced three `undo` calls, all three
returned `"Undone"` — and **Bass was still there afterwards**.

Bass was created *first*, so it sits deepest in the stack and undo pops
newest-first. Two tracks going and the deepest one surviving is the signature
of one undo being consumed by a step that was not a track creation, sitting on
top of the history — not of an undo failing to send. But **nothing in the
system can tell those apart after the fact**, and that is the defect. A dropped
datagram, an unexpected step on top, and reaching the bottom of the history all
produce the identical string.

The reply is a claim made before any evidence could exist:

```elixir
case Transport.send_message("/live/song/undo", []) do
  :ok -> {:ok, "Undone"}
```

`:ok` there means `:gen_udp.send/4` accepted the datagram. `/live/song/undo`
never replies, so there is nothing else it could mean. The model then reported,
accurately, that it had "three vague success signals and no per-track
confirmation either way."

This became a user-facing problem the day repeated undo became the *instructed*
workflow: `undo`'s description now tells the model to call it once per mutating
tool call when reversing a request. That instruction assumes the top of the
stack is what the model thinks it is, and nothing checks that assumption or
notices when it breaks.

**User stories:**
- As a producer, when I ask to undo what I just asked for and one part of it
  doesn't revert, Seshat tells me — instead of reporting three successes and
  leaving me to spot the leftover track myself.
- As a producer, "undo that" that only partly worked is a sentence I hear about,
  not something I discover later.

**Planner notes:**
- Both verification addresses already exist upstream and are already documented
  (`/live/song/get/can_undo`, `/live/song/get/can_redo` in
  [docs/abletonosc-api-docs.md](abletonosc-api-docs.md)). **No fork change, no
  `mix abletonosc.install`, no Live restart.** The plan for the undo-granularity
  work deliberately deferred exposing them — *"nothing needs it yet; stays off
  the roadmap until something does"* — and this is the something.
- **Do not add a state read per `undo` call, and do not add a retry chain.**
  That is ruled out by the user story on the stale-mirror item above: a batch
  undo should cost one verification read *after the batch*. The cheap shape:
  1. **`undo`/`redo` stop asserting.** `"Undone"` should say the request was
     sent, not that history moved. A one-string change, and the honest floor
     regardless of what else is built.
  2. **Put the verification in the description, once per batch.** After undoing
     N calls, one `get_session_state`, and an explicit report when the expected
     things did not all revert. One read per batch, which is what the story
     above asks for.
  3. **Optional, one query:** guard the first undo of a batch with `can_undo`
     so hitting the bottom of the history is an honest error rather than a
     cheerful `"Undone"`. Worth it only if the wall proves common in practice.
- Related, and worth reading together: **"Verify destructive mutations before
  reporting success"** further down this queue is the same family — a mutation
  reporting success as soon as `:gen_udp.send/4` returns. This entry is ranked
  well above it because the undo path now has an instruction telling the model
  to repeat the call, which multiplies an unverified claim by N.
- Still unexplained and worth establishing during planning: **what occupied the
  top of the undo stack.** Selection changes, the follow cam's view steering,
  and Live's own housekeeping are all candidates; none has been measured. If
  something Seshat does routinely lands a step on the history, that is a second
  finding hiding behind this one.

## #3 · `start_new_project` — the setup wizard, and prompt budget back

**Goal:** a tool that catches "let's start a new project" / "start fresh" and
runs the opening of a session: report what's in the open set, name any empty
leftover track, and gather the one-line brief (genre, tempo, mood, reference)
its reply asks for. It **reads and guides; it does not mutate** — the actual
work stays with `create_track` / `delete_track`, with the model in the loop.

**Why:** two wins at once. It fixes finding #1 of the 2026-07-28 validation
run ("start a new project" only appended tracks, leaving the default set's
leftovers behind), and it moves that rule off the *instructions* budget,
which is hard-capped — see below. A tool description routes a user utterance
far more reliably than a bullet in a block that gets truncated from the
bottom, and a reply can name the empty track it actually found instead of
asserting a cleanup unconditionally and hoping the model checks.

**User stories:**
- As a producer saying "let's start something fresh," I get a quick read of
  what's in the open set and one question — genre, tempo, mood, reference —
  so the session starts from my idea, not from leftovers.
- As a producer, the default set's empty leftover track gets noticed and put
  to use, instead of new tracks silently piling up beside it.

**Planner notes:**
- **The 2,048-character ceiling is the point.** Claude Desktop truncates
  server `instructions` mid-sentence at 2,048 characters and says nothing
  (measured 2026-07-29; see the comment above `@text` in
  [lib/seshat/instructions.ex](../lib/seshat/instructions.ex)). Tool schemas
  have no such cap — ~36KB ships every request. So moving a rule from the
  instructions into a tool description or reply costs nothing in total
  context and buys room on the one budget that silently drops content.
- **The "New project" bullet is already gone from `Seshat.Instructions`**
  (removed 2026-07-29, ~230 characters back). Nothing states replace-not-append
  until this ships — the model will append tracks, as it did before that rule
  was written. That gap is deliberate: the rule was bought back as budget on
  the assumption this tool follows.
- **No file operations, ever.** Opening or saving a set is a human step —
  Live's save dialog swallows keystrokes and no code should discard a user's
  work. That is settled; see
  [archive/create-project-removal.md](archive/create-project-removal.md).
- **Read-only is what keeps it from repeating history.** Every failure of the
  removed `create_project` came from fire-and-forget mutation through Live's
  post-load settling window. A tool that only reads `Session.State` and
  returns guidance cannot reproduce any of it.
- The default set is now a single blank MIDI track, so "leftovers" is at most
  one track — the reply should say what it found, not describe a mess.
- Trigger phrasing carries the whole routing job now, so the description has
  to cover the ways the intent is actually spoken. Standard `/add-tool`
  discipline, load-bearing here.
- Sequenced above personas: smaller, fixes a named validation finding, and
  frees budget the persona work will want.

## #4 · Make catalog persistence atomic and report write failures

**Goal:** a reindex that cannot be persisted says so, and a crash mid-write
cannot leave a truncated `catalog.json`.

**Why:** [catalog.ex:831-838](../lib/seshat/library/catalog.ex#L831-L838) logs a
write failure and then returns `{:ok, summary}` — the tool reports success while
the next start restores an old or empty catalog. `File.write/2` is not atomic.

**User stories:**
- As a producer, if a reindex couldn't be saved I'm told right then — not
  left to discover at the next launch that search has been answering from an
  old library.

**Planner notes:**
- Write to a temporary file, sync, rename — then report durable success.
- **Skip the ETS generation swap.** The review also flagged that
  `:ets.delete_all_objects/1` before `insert_all` lets a concurrent search see an
  empty table. Real, but reindex is a rare user-initiated operation that freezes
  Live's UI for up to a minute and that the user is waiting on; a few
  milliseconds of empty results inside that window is not observable.
- **Do this in one pass with "Catalog staleness check"** — same writer, and that
  issue needs a built-at timestamp written there anyway.
- From the 2026-07-29 external review; the durability half accepted, the ETS
  generation swap declined above.

## #5 · Catalog staleness check — notice without being asked

**Goal:** a free freshness check — does `catalog.json` exist, and is its
build timestamp newer than the mtime of Ableton's browser database? Run it
when the user initiates a catalog operation such as `search_library`. When the
catalog is missing or stale, the tool result says that a reindex is needed,
that it can take up to a minute, and that Live's UI will freeze while it runs.
The model can then warn the user and offer to invoke `reindex_library`.

**Why:** 2026-07-28 validation run: the script literally has the *user*
asking whether an index exists yet — backwards. The user shouldn't need to
know when the freshness check is needed. The check costs two file stats and is
naturally triggered by the operation that depends on the catalog. The expensive
rebuild remains announced and explicit because a tool cannot both warn the user
and complete the rebuild before returning its result.

**User stories:**
- As a producer who just installed a new Pack, my next library search notices
  that its catalog is stale and offers to refresh it — I do not have to know
  when or how to check the index myself, and I am warned before Live freezes.

**Planner notes:**
- `catalog.json` needs a built-at timestamp if the merge writer doesn't
  already record one — which is why this pairs with "Make catalog persistence
atomic".
- The Ableton DB path comes from `Seshat.Library.AbletonDB` (per-machine;
  the Windows caveat stays with "Deliberately not planned", not this issue).
- Put the check at the start of `search_library`, and share the same helper
  with any future catalog operation that depends on freshness.
- If a stale catalog is still readable, `search_library` may return its results
  with the warning rather than turning staleness into a hard failure. A missing
  catalog must return the reindex guidance instead of pretending that an empty
  search found nothing.
- A startup check may log or cache the stale status, but it must not start a
  reindex: no MCP conversation may be connected to receive the warning.

## #6 · Verify destructive mutations before reporting success

**Goal:** destructive and structural operations check their target before
mutating and confirm the result afterward, instead of returning success as soon
as `:gen_udp.send/4` returns.

**Why:** Python catches Live API exceptions and only logs them, so a rejected
delete or a dropped packet is indistinguishable from a successful one — and the
follow cam then steers to a destination that may not exist. The reachable
trigger is a stale model-held index.

**User stories:**
- As a producer, when a delete never actually happened in Live, Seshat says
  so — instead of confirming success and steering my view toward a track
  that doesn't exist.

**Planner notes:**
- **Keep ordinary parameter setters fire-and-forget.** The review's headline
  recommendation — structured acknowledgements from every mutation endpoint —
  is rejected: it reverses the settled rule in
  [.claude/rules/osc.md](../.claude/rules/osc.md) ("Setters stay silent — each
  is guarded by its getter first, and nothing waits on one"), and adds a
  round-trip to every mutation, adding load to the query queue that now
  serializes every OSC request.
- The pattern already exists: `delete_device` bounds-checks then verifies by
  re-count, `set_clip_properties` verifies each write by re-read. Extend that to
  the remaining destructive operations and stop.
- Ranked here rather than higher because the surface is broad — this is the
  slog of the correctness items.
- From the 2026-07-29 external review; the verify-before-mutate half accepted,
  structured setter acknowledgements rejected above.
- **Fold in the `remove_notes` footgun fix** (2026-07-31 external tool
  audit): with no range given it silently deletes every note in the clip. Require an explicit range or `all: true`
  before a full wipe — the same principle (destructive intent must be
  explicit), a few lines in `Definitions` + `Handlers`, and small enough to
  ride along here (or as a drive-by before this item is picked up) rather
  than rank on its own.

## #7 · Catalog vocabulary — read tag axes, teach the menu proactively

**Goal:** read the tag *axes* (Character, Genres, Type, …) and the
preset→device relation out of Ableton's database, and surface the real
vocabulary proactively in tool replies — so the model sees the menu before
ordering, instead of guessing tags and learning only from failures.

**Why:** this is levers №1+№2 of
[sound-search-options.md](evaluating/sound-search-options.md) — read that doc before
planning; it grounds every claim in measurements. The top of the search
funnel leaks first-attempt vocabulary misses ("warm" isn't a tag here, `Soft`
is), and the axes fix real traps the flat tag list creates (`Distortion` the
device tag vs. `Distorted` the character tag). Highest certain win left in
the catalog area, at Low/Low-Med effort. №2 also enables future levers, which
is why they ship together.

**User stories:**
- As a producer asking for "a warm pad," the first slate is right because
  Seshat already knows this library's word for it is `Soft` — it sees the
  menu before ordering instead of guessing and learning from misses.
- As a producer asking for "something distorted," I get presets with a
  distorted *character*, not everything touched by the Distortion *device* —
  the axes keep those apart.

**Planner notes:**
- The axis lives in `files.parent_id`, which
  `Seshat.Library.AbletonDB.read_tags/1` currently discards; the
  preset→device map is the `file_devices` table (4,535 rows on the dev
  machine).
- Vocabulary is per-machine (depends on installed Packs) — it must flow
  through replies/catalog data, never be hardcoded in a tool description.
  That rule already governs `search_library`'s design.
- Requires a catalog rebuild (`reindex_library`) — fine, just say so; no
  migration shims (see CLAUDE.md).

## #8 · Producer personas — switchable musical taste

**Goal:** layer a *persona* onto the base session instructions. 
Personas live one per file in [priv/producers/](../priv/producers/)
(five placeholder stubs exist; `mona_dust.md` is the default); a `load_producer` tool (plus
`list_producers`) loads one into the conversation mid-session:
"load me Volt Kessler" changes the session's whole aesthetic.

**Why:** The feel of colloborating with different styles of producer is valuable to the user.
Also different songs might benefit from a different producer. Personas should carry aesthetic taste: sonic palette, genre instincts. Maybe other fun details like stylistic language differences in the responses.

**User stories:**
- As a producer, "load me Volt Kessler" changes what every following pick
  reaches for — a different palette, same tools, no re-explaining a whole
  aesthetic in every prompt.
- As a producer with a direction of my own, my stated taste still leads; the
  persona only fills in where I haven't said anything yet.

**Planner notes:**
- the base text([lib/seshat/instructions.ex](../lib/seshat/instructions.ex) 
  is delivered via the instrucions.  We could put the persona here but there are 2 VERY BAD limitations. 
  Its only loaded at the start of the session, which precedes the first user command, so a user has no way to select the producer being loaded. 
  Also there is a strict 2048 character limit on this field, and the base text needs to use most of it, not much room for the producer persona. 
- Because of these limitations, the planner should explore out of the box creative solutions to loading a producer. 
  Even resorting to asking a user to manual input a file or text somewhere in the desktop client. 
  Consider all possible avenues and angles for getting the mcp consumer to respond with a desired persona. 
  so we are unfortunately quite limited with the space that can be given to a persona if using this delivery method. 
- **The taste hierarchy:  the user's communicated taste
  always leads; the persona is the *default* — the prior that fills in when
  the user hasn't said yet.** 
- The stubbed out personas are placeholders and need to be edited manually,
  continuous iteration is expected as we can only guess and check while using.

## #9 · `screenshot_live` — let Seshat see the screen

**Goal:** capture Live's window (macOS `screencapture` targeted by window
ID) and return the image in the MCP tool result, so the client model —
already vision-capable — can look at the actual UI when the user asks about
it.

**Why:** 2026-07-28 validation run: "why can't I see the notes?" — OSC is
blind to presentation. The mirror knows session *state*, never what's on
screen (focused view, open dialogs, browser panes), so UI questions today
get guesses. Trigger is user UI questions, not routine post-action use —
the follow cam (shipped 2026-07-29) covers that.

**User stories:**
- As a producer asking "why can't I see the notes?", Seshat looks at my
  actual screen and answers — instead of guessing from mirrored state that
  can't see a dialog, a collapsed pane, or where focus went.

**Planner notes:**
- Verify Anubis supports image content in tool results (the MCP spec does).
- Downscale before returning — full-res screenshots are token-expensive.
- One-time macOS Screen Recording permission for the BEAM process; capture
  works occluded but not minimized.

## #10 · Restart the MCP supervisor after abnormal failure

**Goal:** change the nested MCP supervisor's child spec from
`restart: :temporary` to `:transient`.

**Why:** [application.ex:80](../lib/seshat/application.ex#L80) means an abnormal
exit permanently removes MCP service while the Phoenix endpoint keeps looking
healthy — the tools simply stop existing, with nothing saying why.

**Planner notes:**
- **`:transient`, not `:permanent`.** The review offered `:permanent` first;
  that would take the whole application down when Anubis genuinely cannot
  start, which is very likely why `:temporary` was chosen. `:transient`
  restarts on abnormal exit only, which is exactly the case described.
- One line. Do it in passing while touching `application.ex` rather than
  scheduling it.
- Raised as a speculative risk by the 2026-07-29 external review — the failure
  has not been reproduced, only reasoned from the child spec.

## #11 · MCP `tools/call` with `arguments: null` crashes instead of a readable rejection

**Goal:** a `tools/call` whose `"arguments"` is JSON `null` gets a
model-readable rejection — same channel as any other invalid call — instead
of an unhandled crash.

**Why:** found during pr-review of "Model-readable rejections for invalid
tool parameters in MCP mode" (2026-07-31). Peri accepts `arguments: null` and
passes it straight through, so `Seshat.MCP.Server`'s new interception (see
that item, now shipped) never sees it: `Seshat.Tools.Handlers.call/2` is
guarded `when is_binary(name) and is_map(params)`
([handlers.ex:221](../lib/seshat/tools/handlers.ex#L221)), so `params: nil`
raises a `FunctionClauseError` — no `:invalid_params` error is ever produced,
no reply reaches the client. It is the same "invalid params → opaque
failure" class that feature exists to close, reached by a route that skips
the interception entirely: an absent `"arguments"` key and a non-map value
(e.g. a JSON array) are both handled, but an explicit `null` is neither.

**Planner notes:**
- Likely a one-line normalization at the seam: treat `nil` the same as an
  absent key (Anubis already defaults an absent `"arguments"` to `%{}` before
  this point — see case E in
  [archive/PLAN_mcp_readable_rejections.md](archive/PLAN_mcp_readable_rejections.md)). Decide
  whether that belongs in `Seshat.MCP.Server`'s `handle_request/2` clause or
  in `Handlers.call/2` itself.
- Small effort — pair it with a case in
  [test/seshat/mcp/server_test.exs](../test/seshat/mcp/server_test.exs)
  alongside the existing non-map-`arguments` (array) case.

## #12 · Search eval harness — numbers before opinions

**Goal:** a repeatable harness that scores `search_library` relevance against
a fixed set of realistic "describe a sound" queries, so every further catalog
lever gets measured instead of argued.

**Why:** lever №9 of [sound-search-options.md](evaluating/sound-search-options.md),
estimated at a morning's work. It exists to **gate the catalog levers below it**:
after "Catalog vocabulary" lands, the eval decides whether any of the remaining
catalog levers are still worth buying. Sequenced after "Catalog vocabulary"
because that one is a certain win with or without numbers.

**Planner notes:** the result-quality work already used a six-query/77-slot
benchmark informally (see
[archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md));
formalize that rather than inventing a new one. Runs offline against the
catalog — no Ableton needed.

---

**Gate: the six issues below are catalog levers that wait on "Search eval
harness".** Buy each only if the eval still shows the miss it targets after
"Catalog vocabulary" lands. They're ranked by
[sound-search-options.md](evaluating/sound-search-options.md)'s impact-per-effort ordering.

## #13 · Widen the search slate at tied score bands

**Goal:** when the score band straddling the result cut is large (the ~46
identical-tag `E-Piano *` presets), show more of the band rather than
pretending rank means something inside it.

**Why:** lever №4 — a presentation fix for ranking headroom that scoring
provably can't close (a graded per-term variant measured +1 slot across six
queries and was rejected). Hours of work, honest fix.

**User stories:**
- As a producer choosing an e-piano, when dozens of presets score
  identically, I see the honest breadth of the tie — not an arbitrary top
  five pretending rank means something inside it.

## #14 · Accepted-search memory

**Goal:** remember what a description resolved to — "this request led to this
accepted preset" — and let it bias future rankings.

**Why:** lever №8. `use_count`/recency already bias rankings, but the
description→preset association is thrown away today. Compounds over time; a
personal tool can afford a personal memory.

**User stories:**
- As a producer who settled on a particular preset for "dusty keys" last
  week, the same request surfaces it first this week — my accepted picks
  teach the search what my words mean.

**Planner notes:** this is the one catalog feature that wants a write-side
store. Keep it out of the read-only catalog file — a separate small file
under `~/.seshat/` — and it is still not a database (see CLAUDE.md).

## #15 · Browser preview audition

**Goal:** play a preset's browser preview instead of loading it, so the agent
can flip through ten candidates in the time one heavy preset takes to
instantiate.

**Why:** lever №6 — the lighter cousin of the shipped audition loop
(`delete_device`/`bypass_device`). Metadata will never distinguish two `Soft`
pads as well as ten seconds of audio. Explicitly sequenced after the eval:
better search may make it unnecessary.

**User stories:**
- As a producer torn between two `Soft` pads the tags can't tell apart, we
  flip through their browser previews and pick by ear — ten candidates
  auditioned in the time one heavy preset takes to load.

**Planner notes:** the fork already ships `/live/browser/preview_item` and
`/live/browser/stop_preview`; what remains here is the Elixir tool. The
preview plays through Live's cue channel — the tool description must
surface that audibility depends on cue routing.

## #16 · Opt-in `samples` index

**Goal:** index the `samples` category (3,567 items) into the catalog,
returned **only** when `category: samples` is explicitly requested.

**Why:** lever №7, the only category still invisible — "a vinyl crackle" is
unfindable while `Crackle Vinyl Pop.wav` sits in the browser. Sample uris
carry FileIds, so tag-awareness comes free.

**User stories:**
- As a producer asking for "a vinyl crackle," the sample that's sitting
  right there in Live's browser is actually findable — today no search can
  reach it.

**Planner notes:** samples is why `EXPORT_CATEGORIES` excludes it and the
20k-node scan cap exists — measure the walk cost first. Keeping samples out
of default results is a hard requirement so the preset slate stays clean.

## #17 · LLM enrichment at reindex

**Goal:** generate tags/descriptions for untagged and third-party items at
reindex time, using an external model service or an MCP-client-driven tagging
turn.

**Why:** lever №5 — highest ceiling (it attacks the thin-signal problem
directly: ~200 of 5,795 entries say anything real about their sound) and
highest cost. Last resort: buy only if the search eval still shows first-slate
misses on thin-tagged entries after everything above. Concrete evidence from
the 2026-07-28 validation run: for "warm, slightly out-of-tune electric
piano," the character lived only in preset *names* — E-Piano Rusty, Old
School, MKII Old, Cheap were invisible to tag scoring because no warm/aged/
detuned vocabulary exists to carry them.

**User stories:**
- As a producer asking for "a warm, slightly out-of-tune electric piano,"
  the presets whose character lives only in their names — E-Piano Rusty,
  MKII Old — finally rank on their sound instead of their tag luck.

## #18 · User XMP tags

**Goal:** read the user's own tags from
`User Library/Ableton Folder Info/12/`.

**Why:** user-authored tags are the highest-precision signal a personal
library can have; currently ignored. Small, but only matters once the user
actually tags things — hence the low rank.

**User stories:**
- As a producer who has tagged parts of my own library, those tags count in
  search — they're the most precise signal about my sounds that exists.

---

## #19 · Read-only audio input display — warn before a silent take

**Goal:** surface a track's audio input routing, read-only, so `record_clip`
can warn when an audio take is about to record nothing.

**Why:** `record_clip`'s description admits Seshat "cannot choose or check
the input," so an audio take is a coin flip on whether anything was routed —
a silent take discovered after the fact. Upstream already has every address
needed (`/live/track/get/input_routing_type` / `_channel` and the
`available_*` lists — no fork change). Raised as a Medium gap by the
2026-07-31 external tool audit; ranked
here rather than higher because audio recording is a side path in a
MIDI-first workflow and the failure it prevents is recoverable and already
documented in `record_clip`'s description.

**User stories:**
- As a producer setting up a guitar take, Seshat tells me "that track is
  listening to Ext. In 3/4" — or that no input is routed — before recording,
  instead of us finding a silent clip after.

**Planner notes:**
- Read side only. The write side (`/live/track/set/input_routing_*`) stays in
  the grab bag — that's where the sharp edges are.
- Smallest version: `record_clip` reads the routing before firing on an audio
  track and names it in the reply. Decide whether it's also worth a line in
  `get_session_state` before building more surface than the warning needs.
- Routing values are strings from Live's own menus; report them verbatim,
  don't interpret.

## #20 · Device list per track in session state

**Goal:** mirror each track's device chain in `Seshat.Session.State`, so the
agent sees loaded devices without a `get_track_devices` round-trip.

**Why:** device-chain reads are frequent (every load/delete/bypass verifies
by re-read), and the session-state mirror is push-fresh for everything else.
Quality-of-life multiplier for the now-complete device workflow — but the
gain is latency and tokens, not user-visible experience, hence the rank.

**Planner notes:** needs device add/remove listeners per track — check what
upstream offers before assuming a new handler is required. The clip-grid
precedent applies (see the "Clip grid in session state" note): query-on-demand
shipped first, promotion to
push state only once usage justified the subscription surface. Usage now
plausibly does; confirm before building. These listeners are index-keyed —
the fork already fixes the wrong-object unbind in the handler base class, so
any listener work here is an ordinary fork commit, no override gymnastics.

## #21 · Modify a note in place

**Goal:** edit one note's velocity/length/pitch directly instead of
read → remove range → rewrite.

**Why:** the current path works but is three calls and a footgun
(`remove_notes` ranges). Cleaner, not urgent.

**User stories:**
- As a producer saying "make the third note a little quieter," that's one
  clean edit — not a read, a range delete, and a rewrite that can clip the
  notes around it.

## #22 · Clip grid in session state — only if usage demands it

**Goal:** promote the clip grid from on-demand (`get_clip_slots`, shipped)
into push-fresh `Session.State`.

**Why (conditional):** clip-slot listeners are a large subscription surface
(tracks × scenes × properties). The standing decision
([archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) is to
wait for evidence the grid is read constantly. Session record has now shipped
alongside `capture_midi`, so the trigger this item was waiting on has
happened — worth checking whether grid-read frequency actually justifies the
subscription surface before building it. Index-keyed listeners, like the
device-chain mirror's — these are ordinary fork commits on the fixed base class.

## #23 · Small OSC breadth — grab bag

Individually tiny, none blocking a workflow; pick up opportunistically:

- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low
  value for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groups · routing/IO · automation** — grouping tracks, input/output
  routing & monitoring, automation envelopes. (The read-only input *display*
  graduated to its own item, "Read-only audio input display"; the write side
  stays here.)
- **Sends on return tracks** (return→return routing, feedback sends) —
  niche, needs Live's "sends only" awareness, no named workflow yet.
- **Groove Pool assignment by index** — `Clip.groove` is unserializable over
  the wire, but a fork handler could assign it Python-side from
  `song.groove_pool.grooves[i]`, which would make `set_groove_amount` live in
  Seshat-only sessions. Niche until a user actually has grooves in their
  pool; recorded so the "groove amount is inert" audit finding doesn't get
  re-litigated.

## #24 · Adopt MCP `2026-07-28` when Anubis supports it

**Goal:** serve MCP's stateless `2026-07-28` protocol over both Streamable HTTP
and stdio while retaining legacy compatibility for as long as clients need it.

**Why:** `2026-07-28` removes the `initialize` / `notifications/initialized`
handshake and `Mcp-Session-Id`, moves version and client capabilities into
per-request `_meta`, adds mandatory `server/discover`, requires
`Mcp-Method` / `Mcp-Name` HTTP headers and `resultType` on results, and makes
list responses cacheable. Claude support began rolling out on 2026-07-28.
Seshat is currently pinned to `anubis_mcp` 1.10.0, whose newest supported
protocol is `2025-11-25`; current dual-era clients can fall back to that legacy
flow, so this is not an active break.

**Planner notes:**
- Wait for an Anubis release with native `2026-07-28` support; do not implement
  the wire protocol inside Seshat. The existing `~> 1.10` constraint may admit
  a later 1.x release, leaving only a lock update plus any new transport option.
- Prefer dual-era operation initially. A modern-only client cannot use the
  current server, while a dual-era client probes `server/discover` and falls
  back to legacy initialization.
- Seshat's application state already lives outside MCP transport sessions:
  tools delegate to `Seshat.Tools.Handlers` and do not use the per-client Anubis
  frame. No tool or OSC redesign should be needed.
- Verify that `Seshat.MCP.Server.server_instructions/0` reaches the
  `server/discover` result. The new protocol retains `instructions`, but today
  Anubis emits them from the legacy initialize response and this guidance is
  load-bearing.
- The SDK should own per-request `_meta`, standard HTTP headers, `resultType`,
  cache fields, version errors and discovery dispatch. Seshat's static tool
  list is already deterministic and does not vary by connection.
- Keep the current GET/SSE path while supporting legacy clients; modern
  `2026-07-28` replaces the standalone GET stream with
  `subscriptions/listen`. Revisit the router comments and
  `Seshat.MCP.LogFilter` after the Anubis upgrade.
- Authorization changes do not apply while Seshat remains unauthenticated and
  loopback-only. Tasks, roots, sampling, elicitation and MCP logging are not
  used here.
- Add wire-level tests for `server/discover`, a direct stateless `tools/list`
  and `tools/call`, required response fields, HTTP headers, instructions, and
  legacy fallback. Existing MCP tests cover component parity and the
  instructions callback, not transport negotiation.
- Primary references:
  [release overview](https://blog.modelcontextprotocol.io/posts/2026-07-28/),
  [key changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
  [discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
  and
  [version compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).

## #25 · Unit coverage for the mirror-refresh cross-key loop brake

**Goal:** make `Seshat.Session.State`'s `finalize_reconciliations/3` (and the
`carried_over` computation in `run_refresh/2`) callable from `mix test`, so the
cross-key structural loop brake has automated coverage instead of resting on
`/smoke-test` alone.

**Why:** flagged as a coverage gap in the "Coalesce mirror refreshes" PR
review (2026-08-01). That change bounded the asynchronous full-refresh
backlog to one running plus one trailing rebuild, and its cross-key brake is
what stops a degraded rebuild from spinning refresh → re-subscribe → push →
refresh forever. `finalize_reconciliations/3` is pure but only reachable
through `do_refresh/1`, which needs live `Transport.query/3` calls — so
`mix test` never exercises it, and the plan deliberately drew the smoke-test
boundary there rather than adding a test-only injected refresh function.
`/smoke-test`'s five checks all run against a *healthy* Ableton, though, so
none of them enters the degraded-rebuild path either; losing the brake would
flood Live with refresh traffic and nothing today would catch it before a
human noticed. Not a regression — this path was equally untested before that
change — but the file just grew a scheduler around it, which is exactly when
a latent gap like this is worth closing.

**Planner notes:**
- The reviewer's own suggestion: make `finalize_reconciliations/3` (and the
  `carried_over` computation it depends on) callable directly in tests,
  bypassing `do_refresh/1`'s OSC calls, rather than adding a new mock-transport
  abstraction the original plan explicitly rejected as disproportionate.
- Keep the boundary the plan already drew: only the OSC round trip itself
  stays live-only. Everything downstream of a rebuilt mirror map should be
  plain data in, plain data out.
- Low priority: no regression, no user-visible symptom, and the live behavior
  is inferred from the same `_start_listen` machinery already proven for the
  master listeners. Worth doing opportunistically or the next time
  `Session.State`'s refresh path is touched.

---

## Deliberately not planned

- **Deployment-gated security work** — HTTP authentication on `/mcp`,
  production binding, rate limiting, and the multi-user design
  question. Not in this queue by design; see
  [SECURITY_BACKLOG.md](evaluating/SECURITY_BACKLOG.md) for the two triggers that activate
  them. Note that authentication alone does not make Seshat multi-user — one
  transport, one mirror, one Ableton.
- **The vendored Python test harness reloads AbletonOSC on import.**
  `priv/AbletonOSC/tests/__init__.py` sends `/live/api/reload` at module level,
  outside any fixture, so even `pytest --collect-only` reloads the Remote Script
  in a live session. Declined 2026-07-30: it is upstream's harness and we never
  run it — `mix test` only *greps* the vendored Python
  (`vendored_addresses_test`), and nothing here invokes `pytest`. Fixing it
  means carrying a divergence in a file we do not execute through every upstream
  merge. Instead: don't run `pytest` against a Live session that matters.
  **Reconsider if** we ever adopt the Python suite as part of our own
  verification.
- **`pythonosc`'s dispatcher has an invalid escape sequence.**
  `priv/AbletonOSC/pythonosc/dispatcher.py` uses `'[\w|\+]*'`, which emits a
  `SyntaxWarning` and treats `|` as a literal class member. Declined 2026-07-30:
  this is `pythonosc` vendored inside AbletonOSC vendored inside our fork — two
  levels from code we own — and editing it buys one silenced warning for a
  `SESHAT.md` divergence entry and a merge conflict surface. **Reconsider if**
  an Ableton release bumps the bundled Python to a version where this is an
  error, or if the file needs changing for another reason — then fix it in
  passing. Upstream `pythonosc` is the right owner.
- **A PubSub restart would leave `Session.State` permanently unsubscribed.**
  State subscribes only in `init/1`, and it is a `:one_for_one` sibling of
  `Phoenix.PubSub`, so a PubSub restart leaves it registered in a dead registry
  and deaf to OSC broadcasts. The mechanism is real. Declined 2026-07-30 because
  the offered fix is worse than the disease: `:rest_for_one` at
  [application.ex:39](../lib/seshat/application.ex#L39) would, given the current
  child order, restart Transport, Session.State, Catalog, the MCP supervisor
  **and the Phoenix endpoint** on any PubSub blip — a guaranteed heavy failure
  traded for a hypothetical one. `Phoenix.PubSub` crashing is close to unheard
  of. **Reconsider if it is ever actually observed**, and then take the targeted
  option: monitor PubSub and re-subscribe after replacement.
  `get_session_state`'s `refresh: true` is already a manual backstop for a
  mirror that has gone stale for any reason.
- **The monitored refresh worker for `Session.State`** — an overall deadline
  plus freshness/connection/last-error metadata, the larger half of the
  2026-07-29 review's session-refresh finding. Only the fabricated-defaults half
  shipped (2026-07-30); refresh still runs sequential synchronous OSC calls
  inside the GenServer. Deferred, not declined: the blocking window is short and
  has never been observed, and the OSC query queue changed the contention
  picture anyway. **Reconsider if the blocking window is ever actually seen.**
- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Device *reordering* (removal & bypass
  shipped — see `delete_device`/`bypass_device`), rack inner chains, parameter
  listeners (live meters/automation following) — revisit if a real workflow
  needs them.
- Embeddings or a semantic index for the catalog — the LLM is already the
  semantic layer and has the musical context.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](evaluating/bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
- **Machinery around the fork's two known soft spots** (recorded 2026-07-28
  with the fork itself): a pre-push guard for an unpushed `priv/AbletonOSC`
  commit behind a bumped pin (today it surfaces only as a confusing CI
  checkout failure), and a mechanical check that the fork's `SESHAT.md` stays
  current (a missing divergence entry is invisible until the next upstream
  merge). Both are covered by prose in `/implement` and `/pr-review`; neither
  is worth automating while upstream is dormant and there is one committer.
  Reopen if a merge actually goes wrong because of one.
- Anything related to Windows. It would be nice for this to work on a windows machine,
  but currently we are not focused on this.
