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

## #1 · Make catalog persistence atomic and report write failures

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

## #2 · Catalog staleness check — notice without being asked

Implementation plan: [PLAN_catalog_staleness_check.md](PLAN_catalog_staleness_check.md).

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

## #3 · Verify destructive mutations before reporting success

**Goal:** destructive and structural operations check their target before
mutating and confirm the result afterward, instead of returning success as soon
as `:gen_udp.send/4` returns.

**Why:** a rejected delete and a dropped packet are indistinguishable from a
successful one, because nothing waits on a setter — and the follow cam then
steers to a destination that may not exist. The reachable trigger is a stale
model-held index. (The original framing, "Python catches Live API exceptions
and only logs them," is half obsolete: the fork now sends a correlated error
for a rejected setter. Seshat still discards it — see the third planner note
below — so the symptom is unchanged, but the fix has a cheaper option than it
did.)

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
- **A third option exists now, cheaper than a read-back: the correlated
  setter failure.** The fork's dispatch-boundary rework stopped
  `_call_method`/`_set_property` swallowing exceptions, so a rejected setter
  or generic method now sends `/live/error ["request", <its own address>,
  message, argc, *args]` — the same envelope a failing *query* gets, naming
  the request and its arguments. Today Seshat throws that away:
  `Transport.send_message/2` has already returned `:ok`, and the error is
  broadcast on `"osc:in"` and answers nobody. The lever is a short grace
  window after a silent setter — hold the tool step open for roughly one
  AbletonOSC tick (~100ms, and 212ms was the measured client-call-to-result
  figure for a rejection) and report the rejection if one arrives, rather
  than paying a full read-back round trip. That is not the round-trip-per-
  mutation design rejected above: nothing is *queried*, the wait is bounded
  by a tick rather than by `@query_timeout`, and a clean setter costs
  nothing extra. Weigh it against the read-back on a per-setter basis —
  read-back proves the value landed, the envelope only proves it wasn't
  refused — and note it needs a Transport-side subscription to unmatched
  `"request"` errors, which does not exist yet. Requires the fork's
  `_dispatch` commit installed; verify with `mix abletonosc.install` first.
- **Two more Tier-A setters named by the 2026-08-03 integration review**
  ([abletonosc-integration-review.md](evaluating/abletonosc-integration-review.md),
  §4 item 6): `set_track_arm` returns "Armed track N" unverified while
  `record_clip`'s internal `arm_track/1` exists precisely because Live can
  refuse to arm, and `set_time_signature` fires two independent messages and
  can report a plain error with the signature half-applied. Both belong to
  this item's surface. (`set_track_send` from the same review shipped
  separately, with a read-back rather than a wording hedge — see
  [CLAUDE.md](../CLAUDE.md)'s Current focus.)

## #4 · Catalog vocabulary — read tag axes, teach the menu proactively

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

## #5 · Monitored refresh worker for `Session.State`

**Goal:** move the mirror rebuild off the GenServer's synchronous path and give
it an overall deadline plus freshness / connection / last-error metadata, so a
slow or unreachable Ableton cannot block every mirror read behind it.

**Why:** this lived in "Deliberately not planned" — the larger half of the
2026-07-29 review's session-refresh finding, deferred rather than declined, with
one stated reopen condition: *"the blocking window is short and has never been
observed. Reconsider if the blocking window is ever actually seen."* **It was
observed on 2026-08-02.** An ordinary undo burst raced a rebuild, and one
rejected index blocked `do_refresh/1` inside the GenServer for a full five
seconds — see "Correlate `/live/error` so a failed query fails fast" for the
measurement. The condition has fired, so this belongs in the queue rather than
in the declined list.

**The gating fix has now shipped.** "Correlate `/live/error` so a failed query
fails fast" cut that same window from ~5,000ms to roughly one AbletonOSC tick
(≤100ms) without restructuring anything, which may have removed this item's
entire motivation. Buy it only if blocking is still observed after
re-measuring against the shipped fix — the same discipline the catalog levers
get from "Search eval harness". Ranked here for that reason: conditional, and
the shipped fix may retire it outright.

**Planner notes:**
- Only the fabricated-defaults half of the original finding shipped (2026-07-30);
  refresh still runs sequential synchronous OSC calls inside the GenServer.
- The OSC query queue changed the contention picture after that review was
  written — re-establish the real blocking behaviour by measurement before
  designing against the review's description of it.
- `@refresh_sync_timeout` already bounds what the *caller* waits, not what the
  refresh costs. That asymmetry is what this item is actually about.
- **If this is ever picked up, reach for `Seshat.OSC.Transport.query_batch/2`
  first**, not a new fork bulk-snapshot endpoint. "Batch the N+1 reads into
  one AbletonOSC tick" (shipped 2026-08-04, archived at
  [archive/PLAN_batched_queries.md](archive/PLAN_batched_queries.md))
  measured the mirror rebuild's own ~73-query cost as the same disease this
  item targets, at ~4.6s; a batched rebuild would cost roughly 3 ticks
  instead, which may shrink the blocking window enough on its own to retire
  this item without a worker. Re-measure against a batched rebuild before
  designing the worker.

## #6 · `start_new_project` — the setup wizard, and prompt budget back

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
- **Sequenced here, not at the top.** It stays immediately above personas —
  smaller, fixes a named validation finding, and frees budget the persona
  work will want — but nothing is broken while it's missing: the cost is one
  awkward session opening the model can be steered through by hand, so the
  correctness and catalog items above it earn more per hour of effort.

## #7 · Producer personas — switchable musical taste

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

## #8 · AX-backed audio output — the first narrow UI workflow

**Goal:** `get_audio_outputs` and `set_audio_output` tools that let a user say
“switch Live to the headphones,” resolve the installed device name, change
Live's application-wide output through semantic macOS Accessibility elements,
verify the result, and restore the UI within a user-visible latency budget.

**Why:** audio-device selection is absent from Live 12.4.3's LOM, so OSC cannot
reach it. The 2026-08-03 spike succeeded without coordinates, keystrokes,
AppleScript, or screenshots: it enumerated the named choices, selected a second
device, read the value back, and restored the original. The native round trip
took 1.55 seconds, but an exploratory conversational turn took 37 seconds while
code was compiled on demand — shipping value depends on moving compilation and
permission setup out of the request path and measuring what the user waits for.

**User stories:**
- As a producer whose sound is coming from the laptop, I can say “switch Live
  to the headphones” and hear it move promptly without opening Settings myself.
- As a producer, a successful reply means Live's selected output was read back,
  not merely that a UI action was attempted.
- As a producer, Live's Settings and application focus return to how I had them;
  changing output does not leave cleanup work on screen.

**Planner notes:**
- [Implementation plan: AX-backed audio-output selection](PLAN_audio_output.md).
- LOM-first remains absolute. The reusable AX boundary is available only to a
  concrete, independently verified LOM gap with named elements and read-back;
  this is not a generic UI-control tool.
- Acceptance: three fresh local-client “headphones” requests each change Live's
  verified value within 10 seconds; the setter's own MCP call finishes within 5
  seconds. Permission onboarding is one-time and outside that normal path.
- The tool definition must opt out of OSC undo wrapping. Audio preferences are
  outside the Live Set's LOM undo history, and the tool must work without
  emitting unrelated begin/end datagrams.

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

## #12 · `set_clip_properties` reads the loop pair before the `looping` toggle lands

**Goal:** setting `looping` *and* the loop points in one call produces the
intended brace on a clip whose stored loop points differ from its play markers.

**Why:** recorded as a known wart by the 07/2026 review of the clip property
tools, and carried since then as a caveat inside the smoke-test checklist —
which is the wrong home for a defect, since a checklist item that says "if it
misbehaves, the fix is…" is a bug report nobody triaged. With looping off,
Live aliases the loop points onto the play markers. `set_clip_properties`
reads that pair *before* the `looping` toggle goes out, so on such a clip both
the write ordering and the single-sided validation can run against stale
values, and the resulting brace is not the one asked for.

**Planner notes:**
- The fix is stated in the original review: send `looping` first, then read the
  pair context, then order the loop-point writes. Confirm the read really is
  ordered before the toggle in `Seshat.Tools.Handlers` before assuming it.
- Ordering logic is pure-testable — the existing write-ordering tests in
  `handlers_test.exs` are the place. What is not pure-testable is whether Live
  aliases as described; that is a measurement, and it belongs in
  [abletonosc-api-docs.md](abletonosc-api-docs.md) once made.
- The live check already exists as
  `smoke_tests/auto/clips.md § The loop pair with looping off`, where a failure is
  currently the *expected* result. Cite it from the plan, and when this ships,
  rewrite that test so a failure means a regression again.

## #13 · Search eval harness — numbers before opinions

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

## #14 · Widen the search slate at tied score bands

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

## #15 · Accepted-search memory

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

## #16 · Browser preview audition

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

## #17 · Opt-in `samples` index

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

## #18 · LLM enrichment at reindex

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

## #19 · User XMP tags

**Goal:** read the user's own tags from
`User Library/Ableton Folder Info/12/`.

**Why:** user-authored tags are the highest-precision signal a personal
library can have; currently ignored. Small, but only matters once the user
actually tags things — hence the low rank.

**User stories:**
- As a producer who has tagged parts of my own library, those tags count in
  search — they're the most precise signal about my sounds that exists.

---

## #20 · Read-only audio input display — warn before a silent take

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

## #21 · Device list per track in session state

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

## #22 · Modify a note in place

**Goal:** edit one note's velocity/length/pitch directly instead of
read → remove range → rewrite.

**Why:** the current path works but is three calls and a footgun
(`remove_notes` ranges). Cleaner, not urgent.

**User stories:**
- As a producer saying "make the third note a little quieter," that's one
  clean edit — not a read, a range delete, and a rewrite that can clip the
  notes around it.

## #23 · Clip grid in session state — only if usage demands it

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

## #24 · Small OSC breadth — grab bag

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

## #25 · Adopt MCP `2026-07-28` when Anubis supports it

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

## #26 · A rejected index says which index, and what to call next

**Goal:** a tool call Live rejects for a bad index tells the model which index
was bad and which `get_*` tool resolves it, instead of the bare "Ableton
rejected the request: Index out of range".

**Partly solved already, by accident — re-scope before planning this.** Measured
2026-08-05 (`/smoke-test bridge`): `get_track_devices` on track 99 now replies
"Index out of range. Nothing further was sent — check get_session_state for the
indices that actually exist." The batched-reads work of 2026-08-04 routed the
converted reads through `Handlers.remote_error/1` instead of
`Transport.describe_error/1`, and `remote_error/1` already carries the
what-to-call-next half of this item's goal. So the goal now holds on the four
batched read sites and not on the rest, which still render the bare
`describe_error/1` string — the inconsistency is arguably worse than the
uniform gap this item was written against. What is still missing everywhere,
including the batched paths, is the *which index* half: the reply says to check
`get_session_state` but never names 99. Both are in the `/live/error` payload
already (`address`, `arg_count`, the args), so this is still only rendering.

**Why:** found running the never-run agent smoke tests on 2026-08-03
([smoke_tests/auto/devices.md](smoke_tests/auto/devices.md) § Device error paths are
errors, not stalls). The guidance was never deleted — it was stranded. The
helpful wording ("Check both indices with `get_track_devices` first") lives on
`do_call`'s `catch :exit` timeout branch
([handlers.ex:2886](../lib/seshat/tools/handlers.ex#L2886) and siblings), and
the `/live/error` correlation shipped the same day made that branch unreachable
for a bad index: Live's rejection now arrives in ~0.19s and renders through
`Transport.describe_error/1`, which knows only the message Python sent. The
fast-fail is the right behaviour and is not in question; the regression is that
the model went from a slow, actionable message to a fast, generic one, on
exactly the path a model is most likely to hit by guessing an index.

**User stories:**
- As a producer, when I name a track that isn't there, Seshat re-checks and
  corrects itself in the same breath instead of telling me Ableton rejected
  something and stopping.

**Planner notes:**
- The information is present at the rejection site — `/live/error`'s structured
  payload carries `address`, `arg_count` and the request args (see
  `Seshat.OSC.Transport`'s "Failed-query correlation"), so the offending index is
  in hand; only the rendering drops it.
- Decide where the hint belongs. `describe_error/1` is deliberately the one
  place a caller renders the message, but it is tool-agnostic — a per-tool hint
  probably wants to travel with the `{:error, reason}` the handler clause
  already matches, not be pattern-matched onto message strings inside Transport.
- Audit the other `catch :exit` hints for the same stranding while in there;
  this is unlikely to be the only one the fast-fail bypassed.
- Small effort. The pure layer can cover it: `transport_test.exs` already
  constructs `/live/error` payloads, so the rendering is testable without Live.

## #27 · `set_device_parameter` on a regular track loses Live's rejection message

**Goal:** an invalid device or parameter index on a **regular-track**
`set_device_parameter` call reports Live's actual rejection ("Ableton rejected
the request: Index out of range"), not the generic "did not confirm it" that
`read_back_value/2` currently produces for every non-`{:ok, _}` outcome.

**Why:** found in the `echo-checks` PR review (2026-08-03,
[handlers.ex:4216](../lib/seshat/tools/handlers.ex#L4216)). The vendored
paths (`target: "return"`/`"master"`) pre-guard with `query_echoed/4` before
sending, so a bad index is diagnosed pre-mutation; the regular-track clause
has no such guard and relies on `read_back_value/2`'s post-mutation read as
its only index diagnosis. That helper collapses every failure —
`{:error, {:live_error, "Index out of range"}}` included — to `:unconfirmed`,
so the model is told to "verify with `get_device_parameters`", which fails
the same way instead of surfacing the real error. Same theme as the item
above (a fast-fail losing a diagnostic it already has), different site.

**User stories:**
- As a producer, when I name a device or parameter that doesn't exist,
  Seshat tells me the index was rejected instead of sending me in a circle
  through `get_device_parameters`.

**Planner notes:**
- Cheapest fix, per the review: let `read_back_value/2` pass
  `{:error, {:live_error, _}}` through unchanged so the regular-track clause
  can render it via `Transport.describe_error/1`, keeping `:unconfirmed` only
  for a genuine non-answer (mismatch, stale, timeout).
  `set_vendored_parameter`'s call site already handles a bare `{:error,
  reason}` alongside `:unconfirmed`, so the pattern exists.
  Pure-layer testable with the existing `OSCSink` pattern used for the
  reissue tests around this function.

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
