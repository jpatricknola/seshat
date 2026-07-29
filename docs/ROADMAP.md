# Roadmap

The single living list of what's **not built yet**, written as a priority-ordered
issue queue: **#1 is the biggest win, work top to bottom.** Ranking is
**impact-per-effort**: mission impact weighed against cost, so a medium-impact
quick win outranks a high-impact slog. Issue numbers are
ranks, not stable identifiers — when something ships, delete its issue and let
the rest renumber (the `/ship` skill handles this). If a shipped issue had a
detailed plan doc, move that doc to [archive/](archive/) with a status banner.
[archive/](archive/) holds point-in-time plans and decision records — never
treat those as current.

Each issue gives the goal, why it's worth building, and the context a plan
author needs — it is **not** an implementation plan. Plans get written per
issue (the `/plan` skill) when the work is picked up.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address — naming is irregular, and a wrong address fails silently.

**The play-and-keep arc (#1 · #6 · #7):** today the agent generates and
the user listens. `capture_midi` (shipped 2026-07-28) and per-clip properties
(shipped 2026-07-29 — a clip's own loop brace, play markers, and launch
settings are now readable and writable) were the first two steps; these three
remaining issues — session record, quantize, groove — carry the rest: the
user plays, Seshat keeps it and cleans it up. That is the largest gap between
the current state and the mission, and it is cheap: mostly upstream
addresses, and quantize's now ships with the fork. The quick wins interleaved
among them come from the 2026-07-28 validation run
([validation-script-thoughts-and-findings.md](validation-script-thoughts-and-findings.md)).

---

## #1 · Session record — deliberate takes into clip slots

**Goal:** tools to start/stop Session-view recording and report record state:
`/live/song/set/session_record [1|0]`, `/live/song/trigger_session_record`,
`/live/song/get/session_record_status`.

**Plan:** [PLAN_session_record.md](PLAN_session_record.md).

**Why:** `set_track_arm` and `start_playing` exist, but nothing actually
records — the record loop is incomplete, so those tools currently lead
nowhere. Two things it buys that `capture_midi` cannot: the deliberate take
into a chosen slot ("record me an eight-bar take on the keys track"), and
**audio at all** — capture is MIDI-only by construction, so a vocal, a guitar
or any hardware has no route into the set today. That second one is the real
capability gap, and it is the reason this outranks everything below it.

**Planner notes:**
- **Fixed-length record already works today — build the take on it.**
  `ClipSlot.fire()` takes `record_length` in beats as its first optional
  positional argument, and AbletonOSC forwards everything after the two
  indices straight into the method (`params[2:]`,
  [clip_slot.py](../priv/AbletonOSC/abletonosc/clip_slot.py) line 19). So
  `/live/clip_slot/fire <track> <slot> <beats>` is a fixed-length take with
  **no fork change at all**. Verified against Live 12.4.3 on 2026-07-29:
  firing an empty slot on an armed track with `8.0` recorded for exactly two
  bars, stopped itself, and left an 8.0-beat clip playing with its loop brace
  and play markers already at 0.0–8.0; the same fire with no argument was
  still recording (length `6.3072e7`, Live's placeholder) long past that.
  Live's own control surfaces use the same call —
  `novation/fixed_length_recording.pyc` and `APC64/recording.pyc` both do
  `slot.fire(record_length=…)`.
- **So "who ends the take" is largely answered: Live does.** "Record me an
  eight-bar take on the keys" is one fire with `bars × beats_per_bar` from the
  mirrored time signature. What's left is the *open-ended* take — "just record
  until I stop you" — which still needs the user stopping by hand or a second
  conversational turn, because their hands are on an instrument and they
  cannot type "stop". Decide whether the tool takes an optional length and
  falls back to open-ended, and what stops an open-ended one
  (`/live/clip_slot/stop`, or firing the recording slot again to drop into
  playback).
- **Count-in is reachable, just unexposed.** `count_in_duration` and
  `is_counting_in` are both in Live 12's LOM (checked against the name table
  in `_MxDCore/LomTypes.pyc`, 2026-07-29) — AbletonOSC simply doesn't register
  them, which is not the same as Live not having them. Adding each is one line
  in `song.py`'s `properties_rw` / `properties_r`, an ordinary fork commit.
  Buy it only if the take design actually calls for a count-in.
- `/live/clip_slot/fire` on an empty slot of an armed track is the actual
  "record into *this* slot" mechanic; `session_record` is the global switch.
  Decide which one the tool drives.
- **The arm precondition cannot be checked against the mirror.**
  `Seshat.Session.State` does not mirror `arm`, so the tool can't know from
  memory whether the track will actually record — and firing an empty slot on
  a disarmed track launches nothing, silently, which is the failure mode this
  project least tolerates. `/live/track/get/arm` exists; decide whether the
  tool queries it, arms the track itself, or reports the precondition back to
  the user.
- **The echo has to work before the clip exists.**
  `/live/clip/get/is_recording` needs a clip to already be there — on the
  empty slot just fired, there isn't one. The pre-start echo is clip-slot
  level: `will_record_on_start`, `is_triggered`, `playing_status`. Upstream's
  `clip_slot.py` registers all three; they were missing from the address docs
  until 2026-07-29 and are documented now.
- `/live/song/get|set/midi_recording_quantization` shapes what the take comes
  out as. Decide whether the tool touches it or leaves it to Live's own
  setting — and note it is a *different* enum from `quantize_clip`'s (#6).
- **The follow cam covers this.** A take is a clip appearing in a slot, which
  is exactly what `Seshat.Tools.FollowCam` steers to — the `{track, slot}`
  clause in [follow_cam.ex](../lib/seshat/tools/follow_cam.ex) already lists
  `capture_midi` and the record tool joins it. Mind the timing: the clip is
  worth looking at when recording *starts*, not when the reply is written.
- Decide where record state lives. `session_record` and
  `session_record_status` are both listenable, so "report record state" is a
  `Session.State` field vs. a query-in-the-reply choice, not a new address.
  `Handlers.capture_diff/2` + `snapshot_grid/0` already answer "what clip
  appeared" if a diff is wanted — though a take into a *chosen* slot knows
  where to look and can just read that slot back.
- Scope is Session view only: arrangement overdub and punch in/out stay out
  (see Deliberately not planned).
- Decide the tool shape: one `session_record` tool with a state param vs.
  separate start/stop — look at how `set_metronome`/transport tools are
  shaped for consistency.
- Recording lands in the armed track's playing slot; the description must
  spell out the preconditions (armed track, slot choice) in the house style —
  see [TOOL_AUDIT.md](TOOL_AUDIT.md) §04 for the exemplary-description
  pattern.

## #2 · `start_new_project` — the setup wizard, and prompt budget back

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

## #3 · Producer personas — switchable musical taste

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

## #4 · Catalog vocabulary — read tag axes, teach the menu proactively

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

## #5 · Catalog staleness check — reindex without being asked

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
  already record one.
- The Ableton DB path comes from `Seshat.Library.AbletonDB` (per-machine;
  the Windows caveat stays with "Deliberately not planned", not this issue).
- Decide the surfacing point: a line in `search_library` replies, a startup
  check, or both.

## #6 · `quantize_clip` — the most common MIDI cleanup

**Goal:** quantize a clip's notes to a grid with an amount (0–1 for partial
quantize), via the Live Object Model's `Clip.quantize(grid, amount)`.

**Why:** "tighten the timing" is the most common cleanup move on played
MIDI — the direct follow-up to `capture_midi`/session record (#1). Today it
takes a full
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

## #7 · Groove amount — "make it swing"

**Goal:** read/set the global groove amount:
`/live/song/get|set/groove_amount`.

**Why:** the third leg of played-MIDI cleanup after quantize: humanize/swing.
Small, upstream, and it completes the play-and-keep arc's editing vocabulary.

**Planner notes:** single scalar property, transport-tool shaped. Check the
value range in the API docs rather than assuming 0–1.

## #8 · `set_time_signature`

**Goal:** `/live/song/set/signature_numerator` +
`/live/song/set/signature_denominator`.

**Why:** cheap symmetry win — `get_session_state` reports the time signature
and `set_tempo` exists, but there's no setter. Anything in 3/4 or 6/8 starts
with a manual step today.

**Planner notes:** two addresses, one tool. Session state already listens to
both properties, so the echo can verify against the mirror.

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

**Planner notes:**
- Verify Anubis supports image content in tool results (the MCP spec does).
- Downscale before returning — full-res screenshots are token-expensive.
- One-time macOS Screen Recording permission for the BEAM process; capture
  works occluded but not minimized.
- API-key mode would need image blocks threaded through `Seshat.Agent`'s
  loop — decide whether to support it there or keep this MCP-only.

## #10 · Search eval harness — numbers before opinions

**Goal:** a repeatable harness that scores `search_library` relevance against
a fixed set of realistic "describe a sound" queries, so every further catalog
lever gets measured instead of argued.

**Why:** lever №9 of [sound-search-options.md](sound-search-options.md),
estimated at a morning's work. It exists to **gate #11–#16**: after #4 lands,
the eval decides whether any of the remaining catalog levers are still worth
buying. Sequenced after #4 because #4 is a certain win with or without
numbers.

**Planner notes:** the result-quality work already used a six-query/77-slot
benchmark informally (see
[archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md));
formalize that rather than inventing a new one. Runs offline against the
catalog — no Ableton needed.

---

**Gate: issues #11–#16 are catalog levers that wait on #10's eval.** Buy each
only if the eval still shows the miss it targets after #4 lands. They're
ranked by [sound-search-options.md](sound-search-options.md)'s
impact-per-effort ordering.

## #11 · Widen the search slate at tied score bands

**Goal:** when the score band straddling the result cut is large (the ~46
identical-tag `E-Piano *` presets), show more of the band rather than
pretending rank means something inside it.

**Why:** lever №4 — a presentation fix for ranking headroom that scoring
provably can't close (a graded per-term variant measured +1 slot across six
queries and was rejected). Hours of work, honest fix.

## #12 · Accepted-search memory

**Goal:** remember what a description resolved to — "this request led to this
accepted preset" — and let it bias future rankings.

**Why:** lever №8. `use_count`/recency already bias rankings, but the
description→preset association is thrown away today. Compounds over time; a
personal tool can afford a personal memory.

**Planner notes:** this is the one catalog feature that wants a write-side
store. Keep it out of the read-only catalog file — a separate small file
under `~/.seshat/` — and it is still not a database (see CLAUDE.md).

## #13 · Browser preview audition

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

## #14 · Opt-in `samples` index

**Goal:** index the `samples` category (3,567 items) into the catalog,
returned **only** when `category: samples` is explicitly requested.

**Why:** lever №7, the only category still invisible — "a vinyl crackle" is
unfindable while `Crackle Vinyl Pop.wav` sits in the browser. Sample uris
carry FileIds, so tag-awareness comes free.

**Planner notes:** samples is why `EXPORT_CATEGORIES` excludes it and the
20k-node scan cap exists — measure the walk cost first. Keeping samples out
of default results is a hard requirement so the preset slate stays clean.

## #15 · LLM enrichment at reindex

**Goal:** generate tags/descriptions for untagged and third-party items at
reindex time, using an API key or an MCP-client-driven tagging turn.

**Why:** lever №5 — highest ceiling (it attacks the thin-signal problem
directly: ~200 of 5,795 entries say anything real about their sound) and
highest cost. Last resort: buy only if the #11 eval still shows first-slate
misses on thin-tagged entries after everything above. Concrete evidence from
the 2026-07-28 validation run: for "warm, slightly out-of-tune electric
piano," the character lived only in preset *names* — E-Piano Rusty, Old
School, MKII Old, Cheap were invisible to tag scoring because no warm/aged/
detuned vocabulary exists to carry them.

## #16 · User XMP tags

**Goal:** read the user's own tags from
`User Library/Ableton Folder Info/12/`.

**Why:** user-authored tags are the highest-precision signal a personal
library can have; currently ignored. Small, but only matters once the user
actually tags things — hence the low rank.

---

## #17 · Device list per track in session state

**Goal:** mirror each track's device chain in `Seshat.Session.State`, so the
agent sees loaded devices without a `get_track_devices` round-trip.

**Why:** device-chain reads are frequent (every load/delete/bypass verifies
by re-read), and the session-state mirror is push-fresh for everything else.
Quality-of-life multiplier for the now-complete device workflow — but the
gain is latency and tokens, not user-visible experience, hence the rank.

**Planner notes:** needs device add/remove listeners per track — check what
upstream offers before assuming a new handler is required. The clip-grid
precedent applies (see #20 note): query-on-demand shipped first, promotion to
push state only once usage justified the subscription surface. Usage now
plausibly does; confirm before building. These listeners are index-keyed —
the fork already fixes the wrong-object unbind in the handler base class, so
any listener work here is an ordinary fork commit, no override gymnastics.

## #18 · Return/master mixer completeness

**Goal:** return-track pan/mute/solo, master pan, cue volume.

**Why:** the sends/returns work shipped levels only. The fork's
`return_track.py` handler already has the return/master surface open, so
each of these is one more address as an ordinary fork commit — low-effort
breadth whenever someone's nearby. (The 2026-07-28 PR review confirmed the
LOM details: return mute/solo are plain listenable props, master pan is
`mixer_device.panning`, cue volume is `mixer_device.cue_volume`, and the
master has no mute/solo/arm.)

## #19 · Modify a note in place

**Goal:** edit one note's velocity/length/pitch directly instead of
read → remove range → rewrite.

**Why:** the current path works but is three calls and a footgun
(`remove_notes` ranges). Cleaner, not urgent.

## #20 · Clip grid in session state — only if usage demands it

**Goal:** promote the clip grid from on-demand (`get_clip_slots`, shipped)
into push-fresh `Session.State`.

**Why (conditional):** clip-slot listeners are a large subscription surface
(tracks × scenes × properties). The standing decision
([archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) is to
wait for evidence the grid is read constantly. Revisit after session record
(#1) ships — `capture_midi` (shipped) and record will raise grid-read
frequency. Index-keyed listeners like #17's — these are ordinary fork
commits on the fixed base class.

## #21 · Small OSC breadth — grab bag

Individually tiny, none blocking a workflow; pick up opportunistically:

- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low
  value for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groups · routing/IO · automation** — grouping tracks, input/output
  routing & monitoring, automation envelopes.
- **Sends on return tracks** (return→return routing, feedback sends) —
  niche, needs Live's "sends only" awareness, no named workflow yet.

## #22 · MCP mode in the browser UI

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
