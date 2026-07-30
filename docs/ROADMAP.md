# Roadmap

The single living list of what to do next — **features, defects and security
work in one ranked queue.** **#1 is the biggest win, work top to bottom.**
Ranking is **impact-per-effort**: mission impact weighed against cost, so a
medium-impact quick win outranks a high-impact slog. Issue numbers are ranks,
not stable identifiers — when something ships, delete its issue and let the rest
renumber (the `/ship` skill handles this). If a shipped issue had a detailed plan
doc, move that doc to [archive/](archive/) with a status banner.

**So cite an item by its title, never by its rank, anywhere outside this file.**
A rank is correct only until the next ship, and a stale one doesn't look stale —
it silently points at a different item. Every cross-reference written by rank has
already gone wrong at least once ("roadmap #5 and #12" in the smoke-test skill
meant quantize and browser preview when written; three ships later those ranks
were two unrelated defects). Inside this file ranks are fine — they renumber
together. Dated historical records ([archive/](archive/), validation-run
findings) keep whatever rank was true when written; they are history, not
pointers.
[archive/](archive/) holds point-in-time plans and decision records — never treat
those as current.

Each issue gives the goal, why it's worth building, and the context a plan author
needs — it is **not** an implementation plan. Plans get written per issue (the
`/plan` skill) when the work is picked up.

**Two sibling docs hold the evidence, not the queue.** Ranked items that came
from the 2026-07-29 external review link into them; read the linked section
before planning one, because several of the review's recommendations were
verified and then deliberately narrowed or rejected:

- [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md) — the review itself: each
  confirmed defect with file:line evidence, a response recording what we accepted
  and what we declined, and a declined section for findings we are not acting on.
- [SECURITY_BACKLOG.md](SECURITY_BACKLOG.md) — security work. Its **Fix now**
  section is fully resolved as of 2026-07-30: the AbletonOSC loopback bind,
  the browser export path restriction, and the Elixir listener/decoder
  hardening all shipped. Its **Deployment-gated** items are *not* in this
  queue: HTTP authentication, production binding, rate limiting and the
  multi-user design activate only when something binds beyond loopback or a
  second person is invited.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address — naming is irregular, and a wrong address fails silently.

**#1–#4 are all defects, and that is the point.** The feature queue is
displaced because they are either near-free or silently corrupting data. #10
and #11 are one catalog pass.

**The play-and-keep arc (#6 · #8):** today the agent generates and the user
listens. `capture_midi` (shipped 2026-07-28), per-clip properties (shipped
2026-07-29 — a clip's own loop brace, play markers, and launch settings are now
readable and writable), and session record (shipped 2026-07-29 —
`record_clip`/`stop_recording` land a deliberate take, fixed-length or
open-ended, into a chosen Session slot) were the first three steps; these two
remaining issues — quantize, groove — carry the rest: the user plays, Seshat
keeps it and cleans it up. That is the largest gap between the current state and
the mission, and it is cheap: mostly upstream addresses, and quantize's now ships
with the fork.

---

## #1 · Stop fabricating session state after OSC failures

**Goal:** when a refresh query fails, `Session.State` reports the value as
unknown instead of substituting a plausible one.

**Why:** [state.ex:337-344](../lib/seshat/session/state.ex#L337-L344) falls back
to 120 BPM, 4/4 and C Major on any failed song query, and a failed track-count
query keeps the *previous* set's track list. The model cannot tell fresh state
from fabricated state — and it does not merely report those numbers, it writes
bar lengths and note positions against them. Wrong musical output from a silent
failure, fixed by deleting the defaults.

**Planner notes:**
- **Do the defaults only.** The review also proposed a monitored refresh worker
  with an overall deadline and freshness/connection/last-error metadata; that is
  deferred as a risk to revisit if the blocking window is ever actually
  observed. #2 changes the contention picture anyway.
- Decide how "unknown" reaches the model in `get_session_state`'s reply — a
  stated unknown is strictly better than a plausible wrong number, but it has to
  read as one.
- Finding #7 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #2 · Serialize OSC queries and clean up timed-out callers

**Goal:** one query in flight at a time, with an internal timer, late replies
discarded, and the next request dequeued only on completion.

**Why:** `Transport` holds a single `pending` slot and returns `{:noreply, ...}`,
so it accepts the next query immediately; replies correlate by OSC address
alone. Two overlapping queries to the *same* address with different arguments
means the second caller silently receives the first's data. The realistic
trigger is not multi-client MCP — it is `Session.State` re-reading every track
name when the structure listener fires, asynchronously, from a different process
than whatever tool call is in flight.

**Planner notes:**
- The moduledoc at `transport.ex:43-47` explicitly reasons that a timed-out
  caller needs no cleanup. That is sound for sequential callers and unsound the
  moment two overlap — rewrite it with the fix.
- **Elixir-side queue only.** The review's "stronger long-term fix" of adding
  request identifiers to the AbletonOSC protocol is declined: a wire-format
  divergence on every address, carried against upstream forever, to solve what a
  queue already solves.
- Finding #1 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #3 · Enforce tool ranges and non-negative indices centrally

**Goal:** out-of-range numbers and negative indices are rejected before they
reach Ableton, in one place that covers both entry modes.

**Why:** two defects with one seam. `minimum: 0` is present on the newer tools
and missing on the older ones (`set_track_pan`, `set_track_volume`,
`delete_track`, `duplicate_track`, `set_track_name`), and Python indexes Live's
collections directly — so `track: -1` operates on the *last* track while the
reply echoes "track -1". Separately, [schema.ex:45](../lib/seshat/mcp/schema.ex#L45)
turns every JSON Schema `number` into an unconstrained
`{:either, {:float, :integer}}`, so `set_track_pan` accepts `2.0` against a
declared maximum of `1.0`.

**Planner notes:**
- **Validate in `Handlers`.** The review framed the bounds loss as an MCP
  conversion problem, which implies API-key mode is fine — it isn't: that path
  has no validation layer at all and the Anthropic API does not enforce tool
  schemas either. `Handlers.call/2` is the single dispatch point both modes
  share.
- Correct `MCP.Schema` too, so the advertised schema matches what is enforced.
- **No Python bounds checks.** The review's third bullet would diverge
  `track.py`, `clip.py` and `scene.py` permanently for redundant defence once
  Elixir validates and the socket is loopback-bound.
- The realistic caller is a model hallucinating Python's `-1 == last`, not an
  attacker.
- Findings #3 and #4 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #4 · Verify `create_track` actually succeeds

**Goal:** confirm the track count rose before returning an index and naming it.

**Why:** [registry.ex:203-216](../lib/seshat/commands/registry.ex#L203-L216)
reads the pre-create count, fires create and rename, and returns that count
unverified. A dropped create means the rename targets an invalid index while
Seshat reports success and the follow cam steers there — and subsequent device
loads or note writes then target the wrong track.

**Planner notes:**
- `Registry.ensure_created/2` sits *directly above* `create_and_name_track/2` in
  the same file doing exactly this for return tracks. This is applying a local
  pattern, not designing one.
- Update the `create_track` row in [TOOL_AUDIT.md](TOOL_AUDIT.md) when it ships —
  the wart is recorded there now.
- Finding #6 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #5 · `start_new_project` — the setup wizard, and prompt budget back

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

## #6 · `quantize_clip` — the most common MIDI cleanup

**Goal:** quantize a clip's notes to a grid with an amount (0–1 for partial
quantize), via the Live Object Model's `Clip.quantize(grid, amount)`.

**Why:** "tighten the timing" is the most common cleanup move on played
MIDI — the direct follow-up to `capture_midi`/session record (both shipped).
Today it takes a full
read → remove → rewrite by hand, which loses Live-native swing handling and
burns tool calls.

**Planner notes:**
- **The address already exists:** the fork ships `/live/clip/quantize
  [track_id, clip_id, grid, amount]` via the clip methods list (per upstream
  PR #198). What remains here is the Elixir tool. The grid is the
  `GridQuantization` enum (0=none, 4=bar, 6=1/4, 7=1/8, 8=1/16, 9=1/32 —
  full table in
  [abletonosc-api-docs.md](abletonosc-api-docs.md)), **not**
  `RecordingQuantization` — the tool description must carry it.
- The rejected alternative (Elixir-side read → snap → rewrite with existing
  note tools) is recorded here deliberately: zero install surface but worse
  results (no Live-native swing). Don't resurrect it without new evidence.
- Partial quantize (amount < 1.0) is the musically useful form — full
  quantize kills feel. The description should teach that.

## #7 · `set_time_signature`

**Goal:** `/live/song/set/signature_numerator` +
`/live/song/set/signature_denominator`.

**Why:** cheap symmetry win — `get_session_state` reports the time signature
and `set_tempo` exists, but there's no setter. Anything in 3/4 or 6/8 starts
with a manual step today.

**Planner notes:** two addresses, one tool. Session state already listens to
both properties, so the echo can verify against the mirror.

## #8 · Groove amount — "make it swing"

**Goal:** read/set the global groove amount:
`/live/song/get|set/groove_amount`.

**Why:** the third leg of played-MIDI cleanup after quantize: humanize/swing.
Small, upstream, and it completes the play-and-keep arc's editing vocabulary.

**Planner notes:** single scalar property, transport-tool shaped. Check the
value range in the API docs rather than assuming 0–1.

## #9 · Preserve partial agent results at the tool-iteration limit

**Goal:** when `Seshat.Agent` hits `@max_iterations`, return the commands it
already executed and the conversation so far, and surface a warning in the UI.

**Why:** [agent.ex:83-86](../lib/seshat/agent.ex#L83-L86) discards both
`executed` and `messages` and returns a generic error. Nine or ten rounds of
real mutations land, the UI reports an error with no record of them, the
conversation isn't kept, and the obvious user response — retry — repeats
everything. Partial side effects go invisible exactly when recovery information
matters most.

**Planner notes:**
- Scoped to API-key mode, which is the dev/fallback path — that is why it ranks
  here and not higher. The fix is small and the failure is silent, which is the
  combination worth clearing.
- The LiveView error branch leaves history unchanged; both halves need doing or
  neither helps.
- Finding #9 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #10 · Make catalog persistence atomic and report write failures

**Goal:** a reindex that cannot be persisted says so, and a crash mid-write
cannot leave a truncated `catalog.json`.

**Why:** [catalog.ex:831-838](../lib/seshat/library/catalog.ex#L831-L838) logs a
write failure and then returns `{:ok, summary}` — the UI reports success while
the next start restores an old or empty catalog. `File.write/2` is not atomic.

**Planner notes:**
- Write to a temporary file, sync, rename — then report durable success.
- **Skip the ETS generation swap.** The review also flagged that
  `:ets.delete_all_objects/1` before `insert_all` lets a concurrent search see an
  empty table. Real, but reindex is a rare user-initiated operation that freezes
  Live's UI for up to a minute and that the user is waiting on; a few
  milliseconds of empty results inside that window is not observable.
- **Do this in one pass with #11** — same writer, and #11 needs a built-at
  timestamp written there anyway.
- Finding #8 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #11 · Catalog staleness check — reindex without being asked

**Goal:** a free freshness check — does `catalog.json` exist, and is its
build timestamp newer than the mtime of Ableton's browser database? Run it
at server startup and/or on `search_library` calls; when the catalog is
missing or stale, tell the user a reindex is needed and will take up to a
minute (Live's UI freezes), then run it.

**Why:** 2026-07-28 validation run: the script literally has the *user*
asking whether an index exists yet — backwards. The user shouldn't need to
know indexing exists. The check costs two file stats; the expensive rebuild
stays announced and cause-driven instead of manual or unprompted.

**Planner notes:**
- `catalog.json` needs a built-at timestamp if the merge writer doesn't
  already record one — which is why this pairs with #10.
- The Ableton DB path comes from `Seshat.Library.AbletonDB` (per-machine;
  the Windows caveat stays with "Deliberately not planned", not this issue).
- Decide the surfacing point: a line in `search_library` replies, a startup
  check, or both.

## #12 · Verify destructive mutations before reporting success

**Goal:** destructive and structural operations check their target before
mutating and confirm the result afterward, instead of returning success as soon
as `:gen_udp.send/4` returns.

**Why:** Python catches Live API exceptions and only logs them, so a rejected
delete or a dropped packet is indistinguishable from a successful one — and the
follow cam then steers to a destination that may not exist. The reachable
trigger is a stale model-held index.

**Planner notes:**
- **Keep ordinary parameter setters fire-and-forget.** The review's headline
  recommendation — structured acknowledgements from every mutation endpoint —
  is rejected: it reverses the settled rule in
  [.claude/rules/osc.md](../.claude/rules/osc.md) ("Setters stay silent — each
  is guarded by its getter first, and nothing waits on one"), adds a round-trip
  to every mutation, and multiplies #2's exposure.
- The pattern already exists: `delete_device` bounds-checks then verifies by
  re-count, `set_clip_properties` verifies each write by re-read. Extend that to
  the remaining destructive operations and stop.
- Ranked here rather than higher because the surface is broad — this is the
  slog of the correctness items.
- Finding #5 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #13 · Catalog vocabulary — read tag axes, teach the menu proactively

**Goal:** read the tag *axes* (Character, Genres, Type, …) and the
preset→device relation out of Ableton's database, and surface the real
vocabulary proactively in tool replies — so the model sees the menu before
ordering, instead of guessing tags and learning only from failures.

**Why:** this is levers №1+№2 of
[sound-search-options.md](sound-search-options.md) — read that doc before
planning; it grounds every claim in measurements. The top of the search
funnel leaks first-attempt vocabulary misses ("warm" isn't a tag here, `Soft`
is), and the axes fix real traps the flat tag list creates (`Distortion` the
device tag vs. `Distorted` the character tag). Highest certain win left in
the catalog area, at Low/Low-Med effort. №2 also enables future levers, which
is why they ship together.

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

## #14 · Producer personas — switchable musical taste

**Goal:** layer a *persona* — musical taste, and only taste — onto the base
session instructions. Personas live one per file in [priv/producers/](../priv/producers/)
(five stubs exist; `mona_dust.md` is the default); the default composes onto
`Seshat.Instructions` at the same seam `Seshat.Agent.system_prompt/0` already
uses, and a `load_producer` tool (plus `list_producers`) switches mid-session:
"load me Volt Kessler" changes the session's whole aesthetic.

**Why:** taste as a feature instead of a wording debate: different producer,
different palette, same tools. The split is strict (Patrick, 2026-07-29):
personas carry *only* aesthetic taste — sonic palette, genre instincts.
Everything behavioral — slate style, opinionatedness, register, the
"my gut for an 86 BPM lo-fi track…" voice from the 2026-07-28 run — lives in
the base text ([lib/seshat/instructions.ex](../lib/seshat/instructions.ex),
shipped 2026-07-29) and stays consistent across personas. Swapping producers
changes what Seshat reaches for, never how it works.

**Planner notes:**
- **MCP `instructions` are delivered once, at initialize** — mid-session
  switching cannot go through that channel. It must be a tool whose *reply*
  carries the new persona into context and states that it supersedes the
  previous one; that reaches the model identically in both modes. API-key
  mode can additionally swap for real, since `system_prompt/0` composes per
  call.
- Personas are musically expressed, never machine-specific — "warm and
  dusty," not tag names; the model maps taste onto this machine's library via
  `search_library`'s replies. Same rule that governs tool descriptions.
- **The taste hierarchy (Patrick, 2026-07-29): the user's communicated taste
  always leads; the persona is the *default* — the prior that fills in when
  the user hasn't said yet.** The base text's voice section is already
  written as read-and-execute-the-user's-taste, so a persona slots in
  underneath it; add one line to the base stating the hierarchy when this
  ships.
- Flesh the five stubs out from one sentence to a real (but short) voice each
  — a persona rides on top of the base text in every session's context.
- **Constant iteration is the expected mode** (Patrick, 2026-07-29): personas
  will be dialed in mid-work based on responses, so `load_producer` must read
  the persona file from disk at call time — edit the file, re-invoke the
  tool, and the new text lands in context with no recompile, restart, or
  reconnect. Do not compile personas in. (The base text will be iterated
  even more, but its loop is connect-bound regardless — instructions are
  delivered at initialize. If the recompile step in that loop grates,
  `Seshat.Instructions.text/0` can trivially become a runtime file read;
  decide when the friction is actually felt.)
- Decide persistence: does a chosen producer survive reconnect (a small file
  under `~/.seshat/`, still not a database) or reset to the default each
  session?
- The groundwork is already in place, from the session-instructions work
  (shipped 2026-07-29): the composition seam is
  `Seshat.Agent.system_prompt/0`, the 2,048-character delivery ceiling and its
  proof are recorded in
  [archive/PLAN_mcp_server_instructions.md](archive/PLAN_mcp_server_instructions.md),
  and the base text's voice section already reads as execute-the-user's-taste,
  which is what a persona slots underneath.

## #15 · `screenshot_live` — let Seshat see the screen

**Goal:** capture Live's window (macOS `screencapture` targeted by window
ID) and return the image in the MCP tool result, so the client model —
already vision-capable — can look at the actual UI when the user asks about
it.

**Why:** 2026-07-28 validation run: "why can't I see the notes?" — OSC is
blind to presentation. The mirror knows session *state*, never what's on
screen (focused view, open dialogs, browser panes), so UI questions today
get guesses. Trigger is user UI questions, not routine post-action use —
the follow cam (shipped 2026-07-29) covers that.

**Planner notes:**
- Verify Anubis supports image content in tool results (the MCP spec does).
- Downscale before returning — full-res screenshots are token-expensive.
- One-time macOS Screen Recording permission for the BEAM process; capture
  works occluded but not minimized.
- API-key mode would need image blocks threaded through `Seshat.Agent`'s
  loop — decide whether to support it there or keep this MCP-only.

## #16 · Restart the MCP supervisor after abnormal failure

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
- Speculative risk in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #17 · Search eval harness — numbers before opinions

**Goal:** a repeatable harness that scores `search_library` relevance against
a fixed set of realistic "describe a sound" queries, so every further catalog
lever gets measured instead of argued.

**Why:** lever №9 of [sound-search-options.md](sound-search-options.md),
estimated at a morning's work. It exists to **gate #18–#23**: after #13 lands,
the eval decides whether any of the remaining catalog levers are still worth
buying. Sequenced after #13 because #13 is a certain win with or without
numbers.

**Planner notes:** the result-quality work already used a six-query/77-slot
benchmark informally (see
[archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md));
formalize that rather than inventing a new one. Runs offline against the
catalog — no Ableton needed.

---

**Gate: issues #18–#23 are catalog levers that wait on #17's eval.** Buy each
only if the eval still shows the miss it targets after #13 lands. They're
ranked by [sound-search-options.md](sound-search-options.md)'s
impact-per-effort ordering.

## #18 · Widen the search slate at tied score bands

**Goal:** when the score band straddling the result cut is large (the ~46
identical-tag `E-Piano *` presets), show more of the band rather than
pretending rank means something inside it.

**Why:** lever №4 — a presentation fix for ranking headroom that scoring
provably can't close (a graded per-term variant measured +1 slot across six
queries and was rejected). Hours of work, honest fix.

## #19 · Accepted-search memory

**Goal:** remember what a description resolved to — "this request led to this
accepted preset" — and let it bias future rankings.

**Why:** lever №8. `use_count`/recency already bias rankings, but the
description→preset association is thrown away today. Compounds over time; a
personal tool can afford a personal memory.

**Planner notes:** this is the one catalog feature that wants a write-side
store. Keep it out of the read-only catalog file — a separate small file
under `~/.seshat/` — and it is still not a database (see CLAUDE.md).

## #20 · Browser preview audition

**Goal:** play a preset's browser preview instead of loading it, so the agent
can flip through ten candidates in the time one heavy preset takes to
instantiate.

**Why:** lever №6 — the lighter cousin of the shipped audition loop
(`delete_device`/`bypass_device`). Metadata will never distinguish two `Soft`
pads as well as ten seconds of audio. Explicitly sequenced after the eval:
better search may make it unnecessary.

**Planner notes:** the fork already ships `/live/browser/preview_item` and
`/live/browser/stop_preview`; what remains here is the Elixir tool. The
preview plays through Live's cue channel — the tool description must
surface that audibility depends on cue routing.

## #21 · Opt-in `samples` index

**Goal:** index the `samples` category (3,567 items) into the catalog,
returned **only** when `category: samples` is explicitly requested.

**Why:** lever №7, the only category still invisible — "a vinyl crackle" is
unfindable while `Crackle Vinyl Pop.wav` sits in the browser. Sample uris
carry FileIds, so tag-awareness comes free.

**Planner notes:** samples is why `EXPORT_CATEGORIES` excludes it and the
20k-node scan cap exists — measure the walk cost first. Keeping samples out
of default results is a hard requirement so the preset slate stays clean.

## #22 · LLM enrichment at reindex

**Goal:** generate tags/descriptions for untagged and third-party items at
reindex time, using an API key or an MCP-client-driven tagging turn.

**Why:** lever №5 — highest ceiling (it attacks the thin-signal problem
directly: ~200 of 5,795 entries say anything real about their sound) and
highest cost. Last resort: buy only if the #17 eval still shows first-slate
misses on thin-tagged entries after everything above. Concrete evidence from
the 2026-07-28 validation run: for "warm, slightly out-of-tune electric
piano," the character lived only in preset *names* — E-Piano Rusty, Old
School, MKII Old, Cheap were invisible to tag scoring because no warm/aged/
detuned vocabulary exists to carry them.

## #23 · User XMP tags

**Goal:** read the user's own tags from
`User Library/Ableton Folder Info/12/`.

**Why:** user-authored tags are the highest-precision signal a personal
library can have; currently ignored. Small, but only matters once the user
actually tags things — hence the low rank.

---

## #24 · Cap large tool-result payloads in API-key mode

**Goal:** bound what accumulates in `Seshat.Agent`'s `messages` and the
LiveView's log for the life of a conversation.

**Why:** full tool inputs and outputs accumulate unbounded, and catalog and
device results are exactly the payloads large enough to matter — a single local
user can exhaust the Anthropic context window on `search_library` output alone,
and LiveView process memory grows with it.

**Planner notes:** capping large tool-result payloads before they enter
`messages` is the cheap majority of the fix; skip summarising old turns until
needed. MCP mode is primary and keeps no history in this process, which is why
this ranks here. Speculative risk in
[../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## #25 · Device list per track in session state

**Goal:** mirror each track's device chain in `Seshat.Session.State`, so the
agent sees loaded devices without a `get_track_devices` round-trip.

**Why:** device-chain reads are frequent (every load/delete/bypass verifies
by re-read), and the session-state mirror is push-fresh for everything else.
Quality-of-life multiplier for the now-complete device workflow — but the
gain is latency and tokens, not user-visible experience, hence the rank.

**Planner notes:** needs device add/remove listeners per track — check what
upstream offers before assuming a new handler is required. The clip-grid
precedent applies (see #28 note): query-on-demand shipped first, promotion to
push state only once usage justified the subscription surface. Usage now
plausibly does; confirm before building. These listeners are index-keyed —
the fork already fixes the wrong-object unbind in the handler base class, so
any listener work here is an ordinary fork commit, no override gymnastics.

## #26 · Return/master mixer completeness

**Goal:** return-track pan/mute/solo, master pan, cue volume.

**Why:** the sends/returns work shipped levels only. The fork's
`return_track.py` handler already has the return/master surface open, so
each of these is one more address as an ordinary fork commit — low-effort
breadth whenever someone's nearby. (The 2026-07-28 PR review confirmed the
LOM details: return mute/solo are plain listenable props, master pan is
`mixer_device.panning`, cue volume is `mixer_device.cue_volume`, and the
master has no mute/solo/arm.)

## #27 · Modify a note in place

**Goal:** edit one note's velocity/length/pitch directly instead of
read → remove range → rewrite.

**Why:** the current path works but is three calls and a footgun
(`remove_notes` ranges). Cleaner, not urgent.

## #28 · Clip grid in session state — only if usage demands it

**Goal:** promote the clip grid from on-demand (`get_clip_slots`, shipped)
into push-fresh `Session.State`.

**Why (conditional):** clip-slot listeners are a large subscription surface
(tracks × scenes × properties). The standing decision
([archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) is to
wait for evidence the grid is read constantly. Session record has now shipped
alongside `capture_midi`, so the trigger this item was waiting on has
happened — worth checking whether grid-read frequency actually justifies the
subscription surface before building it. Index-keyed listeners like #25's —
these are ordinary fork commits on the fixed base class.

## #29 · Small OSC breadth — grab bag

Individually tiny, none blocking a workflow; pick up opportunistically:

- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low
  value for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groups · routing/IO · automation** — grouping tracks, input/output
  routing & monitoring, automation envelopes.
- **Sends on return tracks** (return→return routing, feedback sends) —
  niche, needs Live's "sends only" awareness, no named workflow yet.

## #30 · MCP mode in the browser UI

**Goal:** give `AssistantLive` a second backend — headless Claude Code
(`claude -p`) as a subprocess consuming Seshat's own `/mcp` endpoint — so the
browser UI runs off a Claude subscription instead of an API key, with a
per-conversation toggle.

**Why:** removes the API-key requirement from the only mode that needs one.
Designed but never built; ranked low because MCP mode already serves the
project's one user.

**Planner notes:** full design (milestones, streaming UI, tested CLI flags
that may have drifted) in
[archive/PLAN_mcp_browser_ui.md](archive/PLAN_mcp_browser_ui.md) — verify the
CLI flags against current Claude Code before trusting it.


---

## Deliberately not planned

- **Deployment-gated security work** — HTTP authentication on `/mcp` and the
  LiveView, production binding, rate limiting, and the multi-user design
  question. Not in this queue by design; see
  [SECURITY_BACKLOG.md](SECURITY_BACKLOG.md) for the two triggers that activate
  them. Note that authentication alone does not make Seshat multi-user — one
  transport, one mirror, one Ableton.
- **Three findings from the 2026-07-29 review were declined** — the vendored
  Python test harness's import-time reload, the `pythonosc` invalid escape
  sequence, and `:rest_for_one` for PubSub recovery. Reasons and
  reconsider-if conditions are in
  [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md)'s declined section; don't
  re-derive them.
- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Return/master-track device loading, device *reordering* (removal & bypass
  shipped — see `delete_device`/`bypass_device`), rack inner chains, parameter
  listeners (live meters/automation following) — revisit if a real workflow
  needs them.
- Embeddings or a semantic index for the catalog — the LLM is already the
  semantic layer and has the musical context.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](bridge-options.md); reopen only if a Remote
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
