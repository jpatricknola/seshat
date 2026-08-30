# Plan: `convert_audio_to_midi` drops the Accessibility helper

> **Archived 2026-08-30 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The feature now lives in
> `Seshat.Tools.Handlers`'s `convert_audio_to_midi` clause, running over
> `/live/clip/audio_to_midi` and `/live/clip/get/is_convertible_to_midi`;
> `native/seshat_ax/main.m` and `Seshat.AX.Client` lost the `convert` command
> and now serve only `get_audio_outputs`/`set_audio_output`. Live
> verification did not run — see CLAUDE.md's "Current focus" for what still
> needs a person and a running Ableton. Open follow-ups: `mix routing.eval`
> was not run for the description change, and `mix ax.install` was
> deliberately not run to avoid an unattended Accessibility re-approval.

**Roadmap item:** `convert_audio_to_midi` drops the Accessibility helper —
re-implement the conversion on the fork's `/live/clip/audio_to_midi` address
and delete the `convert` command from the AX helper, leaving
`get_audio_outputs` / `set_audio_output` as the only Accessibility-backed
tools.

**Status: planned 2026-08-30.** The fork half is already shipped and
installed: [fork #34](https://github.com/jpatricknola/AbletonOSC/issues/34)
merged `abletonosc/conversions.py`, the gitlink points at the merge, and
`mix abletonosc.install` has run. **Live has not been restarted since the
install** — an installed handler is not a loaded one — so the first act of
implementation is a Live restart (or `/live/api/reload`) and a by-hand probe
of `/live/clip/get/is_convertible_to_midi` before any Elixir is written.

## Context

The tool works today, so this is a reliability item, not a capability one.
The current implementation selects the clip over OSC, then drives Live's
`Create` menu through the native Accessibility helper: Live must be brought
to the front, one of three menu titles compiled into `main.m` by name is
pressed (a Live rename or a non-English install breaks it silently),
`AXEnabled` lies until AppKit validates lazily (hence a ~350 ms wait), and a
disabled command is indistinguishable from one that was never pressed. To
satisfy the menu's validation the tool also has to `focus_view Session`,
confirm the selection through two independent reads, and leave the user on
the Session view afterwards. None of that survives the move to
`/live/clip/audio_to_midi`.

Two things are gained beyond deletion:

- `/live/clip/get/is_convertible_to_midi` replaces the hand-rolled
  empty-slot and MIDI-clip guards with Live's own predicate, wrapped by the
  fork so it always answers instead of raising.
- Live's real rejection reaches the reply: the address answers an
  `("error", message)` envelope with Live's own words, where the AX path
  could only say "the menu item was disabled".

The one real design question is the **asynchronous reply**:
`/live/clip/audio_to_midi` answers `"ok", -1` before the new track exists
(measured; see `priv/AbletonOSC/API.md` § "Conversions" — `-1` is an answer,
never a failure), and the track appeared within about three seconds. So the
handler must wait for the track rather than reading back immediately, and a
timeout after the accepted call must say "wait / check", never "it failed".
This plan keeps a bounded poll (the pattern `API.md` recommends for a client
that doesn't want to manage a listener subscription inside one tool call) and
resolves *which* track is new by diffing `/live/song/get/track_names` before
and after — the fork measured new tracks appended last, the old AX run
measured one landing directly after the source, and `API.md` is explicit that
ordering is an observation, not a promise, so the index is read, never
assumed.

No fork change, no new tool, no `Definitions` count change, no
`Session.State` change (the mirror already hears the new track via
`song_structure.py`'s push and its debounced refresh).

## OSC contract

The fork owns the wire facts; the conversions rows below cite
[priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md) § "Conversions — audio to
MIDI, Simpler and Drum Rack" rather than restating its measurements.

New to `lib/` (both registered in `abletonosc/conversions.py`, both already
covered by `vendored_addresses_test`'s doc-coverage direction):

| Address | Request | Reply |
|---|---|---|
| `/live/clip/get/is_convertible_to_midi` | `track_id, clip_id` | `track_id, clip_id, convertible` — always answers; `false` for a MIDI clip, an empty slot, or a Live without `Live.Conversions`, without calling Live |
| `/live/clip/audio_to_midi` | `track_id, clip_id, type` (`type` is the name `"melody"`/`"harmony"`/`"drums"`, never the enum int) | `track_id, clip_id, "ok", new_track_id` or `track_id, clip_id, "error", message` — **asynchronous**, so `new_track_id` is always `-1` today |

Already-documented upstream addresses this handler consumes (all already
sent elsewhere in `lib/` except `track_names`):

| Address | Request | Reply | Used for |
|---|---|---|---|
| `/live/song/get/track_names` | *(none — full range)* | `[names...]` in index order, regular tracks only | before/after diff: the count (list length) and the identity of the appeared track |
| `/live/clip_slot/get/has_clip` | `track_id, clip_id` | `track_id, clip_id, has_clip` | refusal diagnosis + read-back |
| `/live/clip/get/is_midi_clip` | `track_id, clip_id` | `track_id, clip_id, is_midi` | refusal diagnosis |
| `/live/track/get/name` | `track_id` | `track_id, name` | read-back |
| `/live/track/get/devices/name` | `track_id` | `track_id, names...` | read-back |
| `/live/clip/get/notes` | `track_id, clip_id` | `track_id, clip_id, notes...` | read-back |

Addresses that leave `lib/` with the AX dance (still registered in the
fork's `view.py` and still documented; only their use goes):
`/live/view/focus_view`, `/live/view/get/focused_document_view`,
`/live/view/set/selected_clip` (this call site — `FollowCam` keeps its own),
`/live/view/set/highlighted_clip_slot`, `/live/view/get/selected_clip`,
`/live/view/get/highlighted_clip_slot`.

## Part 1 — the handler goes to OSC end to end

`lib/seshat/tools/handlers.ex`, the `do_call("convert_audio_to_midi", ...)`
clause and its `# --- Audio to MIDI helpers ---` section.

New flow, in wire order (each step names what it replaces):

1. **Guard: Live's own predicate.** `query_correlated/4` on
   `/live/clip/get/is_convertible_to_midi` with `echo: [track, slot]` and
   `@guard_timeout`. A truthy field proceeds. A falsy field is *diagnosed*
   rather than reported raw — Live answers `false` for every unconvertible
   case alike, and the tailored refusals are worth keeping:
   - reuse `ensure_clip(track, slot, @convert_empty_hint)`: an empty slot
     keeps today's wording (routes to `record_clip` / `generate_audio`);
   - else `clip_is_midi/2`: a MIDI clip keeps today's wording minus the
     "Ableton Live was never brought to the front" clause (routes to
     `get_clip_notes` / `edit_notes` / `quantize_clip`);
   - else a new generic: Live says this clip can't be converted — it may be
     too short or silent, or this Live may not offer Convert (Live 9+,
     Standard and Suite).
   A timeout or unreadable reply refuses with "nothing was converted"
   wording, as today. This replaces `ensure_clip` + `ensure_convertible_clip`
   as the *primary* guard while keeping both helpers for the diagnosis.
   Delete: `focus_session_grid/0`, `confirm_session_focus/0`,
   `select_clip_for_convert/2`, `read_clip_coordinate/2`,
   `selection_error/4` — nothing needs focus or selection any more.

2. **Names before.** One query on `/live/song/get/track_names` (no
   arguments), `@guard_timeout`. The reply carries no echo; the standing
   defence is structural, exactly as `query_scene_names/1` argues: every
   name must be a string, and the length *is* the track count. Failure here
   refuses before anything is sent — nothing mutated, honest. This replaces
   `convert_track_count(:before)` (the count is the list's length), and
   `convert_track_count/1` is deleted.

3. **The conversion.** `query_correlated/4` on `/live/clip/audio_to_midi`
   with args `[track, slot, mode]` (the tool's `mode` string is the wire
   name verbatim — no mapping table; `convert_command/1` and its three menu
   titles are deleted), `echo: [track, slot]`, default 5s timeout. Fields:
   - `["ok", _new_track_id]` → accepted; the id is `-1` today and is treated
     only as "accepted" — the index is *always* resolved by the diff in
     step 4, so a future synchronous Live changes nothing here;
   - `["error", message]` → `{:error, ...}` rendering Live's own message
     (through `remote_error/1`'s framing);
   - timeout or unreadable reply **after the send** → an error that says the
     conversion *was requested* and Live did not reply — check
     `get_session_state`, a new track may still appear. Never "nothing was
     converted": the datagram may well have landed.

4. **Await and resolve.** Poll `/live/song/get/track_names` until its length
   is `length(before) + 1`, bounded by retuned attributes:
   `@convert_settle_attempts 20`, `@convert_settle_delay 250` (the measured
   appearance was ~3s; 20 × (250ms + a ~100ms tick per poll) ≈ 7s of
   patience, against today's ~2.5s which the measurement outgrew). Outcomes:
   - length `== before + 1` → the new index is the first position where the
     two lists diverge (`before` exhausted → the appended-last case). A run
     of identical names can make that position ambiguous only among
     equally-named tracks, and step 5's read-back confirms the choice.
   - length `> before + 1` → today's honest "more than one track appeared"
     error, unchanged in spirit.
   - never rises → "Live accepted the conversion but no track has appeared
     yet (waited ~7s) — a long clip may still be analysing. Check
     get_session_state in a moment before converting again." **Not** a
     "nothing was converted" claim — with an accepted async call, absence of
     evidence is only "not yet".
   - a poll whose reply is unreadable or times out → the same "may still
     appear" framing, as `convert_count_timeout(:after)` does today.

5. **Reply.** `convert_reply/4` and its helpers (`read_converted_track/2`,
   `convert_headline/5`, `convert_notes_line/3`, `convert_instrument_line/1`)
   stay as they are: `FollowCam.steer/2` to the resolved track (unchanged in
   `follow_cam.ex` — track selection only, no pane change), the best-effort
   `query_batch/2` read-back of name / devices / `has_clip` at the source's
   slot index, the notes count, and the quantize/edit coda. One addition: if
   the names diff resolved but the read-back's name disagrees with the name
   the diff identified, keep the reply but say the read-back disagreed —
   never present one read as confirmation of the other. If step 4 saw the
   count rise but the *after* names read failed outright, reply `{:ok, ...}`
   with "a new track appeared but which one could not be read back — check
   get_session_state", and skip the steer (never aim the view at a guess).

6. **The `catch :exit` boundary moves.** Today's clause-level `catch` says
   "nothing was converted", which is only true for exits raised by the
   pre-send guards. Steps 3–5 own their timeouts internally (as
   `convert_track_count/1` did), so the clause-level catch keeps its wording
   and keeps being reachable only before the send. Verify that property in
   the rewrite rather than assuming it survived.

Comment blocks: the big "Order is the whole design" comment above the clause
is rewritten around the new two hazards — the async reply and the
resolve-by-diff — and the focus/selection measurements it records move to
git history (they document a mechanism that no longer exists; `API.md` keeps
the wire facts).

## Part 2 — the tool description stops describing the menu

`lib/seshat/tools/definitions.ex`, the `convert_audio_to_midi` entry. Same
name, same three parameters, same enum, same `required` — the published
schema shape does not change, and the tool count stays 54.

Draft description:

> Turn an audio clip into a new MIDI track playing the same part — Ableton
> Live's own Convert, run through the Live API. Use 'melody' for a single
> line (a sung or hummed solo, a bass part), 'harmony' for chords and pads,
> 'drums' for a beat, which lands on a Drum Rack. Track and slot are 0-based
> and must hold an **audio** clip; anything Live cannot convert — a MIDI
> clip, an empty slot, a clip with nothing to track — is refused with the
> reason before anything changes. Live converts asynchronously: the tool
> waits for the new track (a few seconds) and names it only once it exists,
> carrying an instrument Live chose — replace that with load_device once you
> know what the user wants it to sound like. Live analyses pitch, so the
> result follows what was actually played, warts included: expect to follow
> up with quantize_clip and edit_notes rather than expecting a clean part.
> The source clip is untouched. Live 9+, Standard and Suite.

Gone: "briefly brings Ableton Live to the front… does not switch it back"
(no longer true), and "the new track arrives directly after the source
track" (an observation `API.md` declines to promise; the reply names the
real index, which is better than a schema-level claim).

Kept: `minimum: 0` on both indices, with its comment updated —
`conversions.py`'s `_clip` indexes `song.tracks[track_index]` in Python,
where a negative index resolves from the end of the list instead of raising,
so the bound is still load-bearing, just for a different consumer.

The section comment above the entry ("OSC selection, macOS Accessibility
press… the third tool that leaves the Live Object Model") is rewritten: this
tool no longer leaves the LOM at all.

## Part 3 — the AX helper loses `convert`

- `native/seshat_ax/main.m`: delete the `convert` dispatch branch,
  `ConvertTransaction`, `kConvertCommands`, `IsAllowedConvertCommand`,
  `kCodeCommandUnavailable`, the usage string's `convert` clause, and the
  header-comment paragraphs describing the command. `kCodeUnknownCommand`
  stays (it is the generic unknown-subcommand refusal). The compiled-in
  menu-title allowlist and the `AXPick`-after-`AXPress` sequence go with it.
- `lib/seshat/ax/client.ex`: delete `convert/1`, `@callback convert/1`, the
  `"command_unavailable"` row of `@codes`, and the moduledoc/`@doc`
  paragraphs describing the convert case (including the line 31 "argued
  once" passage — the argument is now history, recorded in the roadmap entry
  and fork issue #34). The lock, deadline and failure-shape machinery is
  untouched; `list_outputs/0` and `set_output/1` keep it earning its place.
- `mix ax.install` must be re-run by the implementer to prove `main.m` still
  compiles warnings-clean and to shrink the installed helper —
  deliberately outside `mix compile` and CI, so **no test in this repo
  executes the Objective-C**; note whether macOS still trusts the renamed
  binary (the task reports it). A stale installed helper is harmless in the
  meantime: nothing calls `convert` any more.
- `test/seshat/ax/client_test.exs`: delete the `convert/1` describe block
  and any convert fixtures. The two-door grep test stays and must still
  hold in both directions — `client.ex` still spawns for the audio-output
  tools, so nothing about the pinned file list changes; check the
  lock-wording test at ~line 535 whose comment cites `convert/1` sharing
  the lock, and reword the comment (the *behaviour* it pins — feature-
  neutral lock wording — is still right).
- `test/support/fake_ax_client.ex`: drop `convert` support if it has any
  beyond the generic response map.

## Part 4 — pure tests

`test/seshat/tools/handlers_test.exs`, the `convert_audio_to_midi` describe
block, rewritten against `Seshat.Test.OSCSink` scripted traces (no
`FakeAXClient` involvement at all):

- **Happy path with a wire-order assertion** — the whole point of the
  rewrite is order: `end_undo_step`, `begin_undo_step`,
  `is_convertible_to_midi`, `track_names`, `audio_to_midi`, `track_names`
  (poll), then the read-back batch. Reply script: predicate truthy, names
  `["Audio"]`, conversion `["ok", -1]`, names `["Audio", "3-Melody to MIDI"]`,
  batch name/devices/has_clip, notes. Asserts the reply names track 1 and
  Live's name, the notes count, the instrument, and the quantize coda.
- **The diff resolves a mid-list insertion** — before
  `["Drums", "Voice", "Pad"]`, after `["Drums", "Voice", "Voice to MIDI",
  "Pad"]` → track 2. This is the test that pins resolve-by-diff over
  resolve-by-position.
- **`"ok", n ≥ 0` is not trusted over the diff** — a scripted synchronous-
  style reply still resolves by names.
- **Refusals**: predicate falsy + empty slot → `record_clip`/`generate_audio`
  hint, no `audio_to_midi` datagram in the trace; predicate falsy + MIDI
  clip → `get_clip_notes` routing, no mutation datagram; predicate falsy +
  audio clip present → the generic "Live says it can't convert" wording.
- **Live's own rejection**: conversion replies `["error", "..."]` → the
  message reaches the caller, no poll follows.
- **Accepted but no track**: predicate truthy, `["ok", -1]`, polls all
  answer the old names → the reply says *accepted / may still appear /
  check get_session_state*, and asserts it does **not** say "nothing was
  converted".
- **More than one track appeared** → the honest can't-tell error.
- **After-names read fails once the count rose** → `{:ok, ...}` with the
  "which one could not be read back" wording and no steer datagram.
- **Guard timeout before the send** keeps the "nothing was converted"
  wording (the clause-level catch property from Part 1 step 6).

`test/seshat/osc/vendored_addresses_test.exs`:

- Add the exactly-listed "still sent by lib/" pin the file's own comment
  promises: a `@vendored_conversion_addresses` list carrying
  `/live/clip/get/is_convertible_to_midi` and `/live/clip/audio_to_midi`,
  joined into the "exactly-listed … addresses are still the ones lib/
  sends" test alongside the song and view lists.
- Remove `/live/view/focus_view`, `/live/view/get/focused_document_view`
  and `/live/view/get/highlighted_clip_slot` from `@vendored_view_addresses`
  — this change removes their only `lib/` call sites, and that list is
  asserted in both directions. They stay registered in `view.py` and
  documented in `API.md`; the whole-file registration pin keeps guarding
  them against an upstream merge, exactly as the file's comment describes
  for `selected_track_identity`.

`test/seshat/tools/definitions_test.exs`: no count change (54 stays 54); the
expected-names list is untouched. Check no description-text assertion pins
the old wording.

## Part 5 — docs that describe the old mechanism

- `docs/smoke_tests/auto/convert.md` — **already rewritten in this planning
  pass** for the OSC path (four checks; see Live verification).
- `docs/smoke_tests/manual/on-screen.md` — **already done in this pass**:
  "Convert brings Live forward and gives it back" is replaced by "Convert
  leaves Live's focus and view alone", per the roadmap's instruction to
  delete the focus-dance checks with the mechanism and add one covering the
  view not moving. Its undo observation moved into `auto/convert.md` as an
  agent-runnable check. The archived
  [PLAN_sing_it_back_as_midi.md](PLAN_sing_it_back_as_midi.md) still
  cites the old title; archived plans are point-in-time records and are left
  as they stand — the citation was never run, and the mechanism it covered
  is what this change deletes.
- `docs/smoke_tests/auto/README.md` — **already done in this pass**: the
  `convert.md` table row no longer says "AX menu press".
- `CLAUDE.md` — the module-map rows for `native/seshat_ax/main.m`
  ("five-command JSON protocol", "convert fires only one of three
  compiled-in menu titles") and `lib/seshat/ax/client.ex` ("and for
  `convert_audio_to_midi`'s single menu press") must be corrected in the
  implementation PR (four-command protocol, audio-output tools only); the
  Current-focus narrative is `/ship`'s job, not this plan's.
- `README.md` — the "Three tools … do not go through AbletonOSC for the one
  step that matters" passage (~lines 120–138) becomes false once this ships:
  `convert_audio_to_midi` leaves that list, the helper's protocol drops from
  five commands to four, and the "fire one of *three compiled-in* Convert
  commands … exactly as Convert was argued" sentences describe a mechanism
  that no longer exists. Rewrite the passage around the two audio-output
  tools; the Convert story survives only as the past-tense cautionary
  example it already is in `.claude/docs/ableton-lom.md`. *(Added by
  plan-review — this file was missing from the old-mechanism sweep.)*
- `manual/by-ear.md` and `manual/conversation.md` need no edits — their
  convert checks are mechanism-neutral by design.

## Testing

All pure, all against `Seshat.Test.OSCSink` — nothing reaches
`Transport.query/3` against a real socket, and the AX fake disappears from
this tool's tests entirely (Part 4). `mix precommit` before done. The
Objective-C deletion is compile-checked only by `mix ax.install` on the
implementer's machine (macOS-only, outside CI) — say so in the PR.

Part 2 rewrites a tool description, so **`mix routing.eval` is warranted**
per CLAUDE.md's verification rules: run it on the branch (on demand, never in
`mix precommit`) and attach the run's `report.md` to the PR. *(Added by
plan-review — the obligation was in the planning report but not the doc.)*

## Live verification

Nothing in `mix test` reaches any of this — the suite supplies every reply
itself, so coverage here starts from zero. **Before `/smoke-test` runs:
restart Live** (the installed `conversions.py` predates the running
interpreter; an installed handler is not a loaded one), and restart the
Seshat server on the branch — the 2026-08-30 sing-it-back review was burned
by a server serving pre-change code.

- `smoke_tests/auto/convert.md § A converted clip lands as a new track whose
  notes read back` — the whole new path end to end: async accept, bounded
  wait, resolve-by-diff, read-back. Also records where Live actually puts
  the new track (Open question 2).
- `smoke_tests/auto/convert.md § One undo accounts for the converted track`
  — measures whether the async conversion folds into the tool call's undo
  step (Open question 3).
- `smoke_tests/auto/convert.md § A refusal names why, before anything is
  converted` — the predicate-plus-diagnosis guard, both refusal flavours.
- `smoke_tests/auto/convert.md § A bad index refuses cleanly and fast` —
  the structured `/live/error` fast-fail on the new vendored addresses; the
  stale-install detector.

**Run 2026-08-30 (Live 12.4.5, bridge `af17cfc`, all three install comparisons
green).** The four `auto/` citations above all **passed**; the three `manual/`
ones below remain `*Last run: —*` and still need a person.

- *A converted clip lands…* — count 2 → 3, the reply named track 2
  `"3-Melody to MIDI"` only once it existed, 11 unquantized notes read back
  from the source's own slot, source clip untouched. **Open question 1 answered:**
  the converted clip lands in the *same scene row* as the source.
  **Open question 2 answered, and it contradicts `API.md`:** with a marker track
  placed below the source, the new track landed **directly after the source**
  (index 2, pushing the marker to 3), not appended last. `API.md`'s three
  "appended last" samples all had the source on the last track, where the two
  outcomes are indistinguishable. Resolve-by-diff read it correctly; the
  appended-last assumption the plan rejected would have named the marker track.
- *One undo accounts…* — **Open question 3 answered: the clean answer.** One undo
  restored the pre-convert count with the source untouched, measured twice
  (converted track last, and inserted mid-list). Live folds the asynchronous
  conversion into the single undo step the tool call brackets.
- *A refusal names why…* — MIDI clip refused in 0.46s, empty slot in 0.34s, each
  with its own wording and its own routing. One predicate bit, two diagnoses.
- *A bad index refuses…* — 0.22s, Live's own "Index out of range". Live's
  `Log.txt` shows the `IndexError` raised on
  `/live/clip/get/is_convertible_to_midi` — the guard address — proving the
  refusal landed before any conversion was requested.

**Open question 4 (a reply lagging past ~7s on long material) was not provoked**
— every check used a 2-bar clip, as the plan's "uncovered" note says. The
may-still-appear wording remains untested against a real slow conversion.

- `smoke_tests/manual/on-screen.md § Convert leaves Live's focus and view
  alone` — the deletion's user-visible half: no focus steal, no menu, no
  view jump; eyes only.
- `smoke_tests/manual/by-ear.md § Sing a line, hear it back as a guitar` —
  the headline arc over the new mechanism; still `*Last run: —*` from the
  sing-it-back ship, so this branch is the one that finally runs it.
- `smoke_tests/manual/conversation.md § A sung take routes to setup, record,
  then convert` — the rewritten description is model-facing text; a fresh
  conversation in a real client, on the user's computer (instructions don't
  reach bridged cloud sessions, and Claude Desktop truncates instructions at
  2,048 characters silently — unchanged here, but the check rides the
  conversation).

**Uncovered, deliberately:** a *long* clip's conversion latency (every check
uses a 2-bar clip; the may-still-appear path past ~7s can only be provoked
by material no check specifies — the wording is the mitigation); a Live
edition with no `Live.Conversions` (nothing here can downgrade Live; the
predicate's `false` plus the generic refusal is the designed behaviour,
⚠️ unmeasured); a non-English Live (no longer load-bearing — the menu-title
dependency is what this change deletes); and the Simpler/Drum-Rack sibling
addresses, which are out of scope below.

## Out of scope

- `/live/clip/create_midi_track_with_simpler`,
  `/live/clip/create_drum_rack_from_audio_clip`,
  `/live/device/sliced_simpler_to_drum_rack` — shipped in the same fork
  merge, deliberately unused here. *Slice to New MIDI Track* is a different
  producer intention; it needs its own roadmap item and scoring, per the
  roadmap entry's own warning against folding them in.
- A push-based wait (subscribing the handler to `Session.State`'s structure
  push instead of polling). `API.md` recommends the listener pattern for a
  standing client; inside one bounded tool call, a poll is fewer moving
  parts and the same tick cost. If a future item needs sub-second convert
  latency, that is where it goes.
- Retiring `focus_view` / `get/focused_document_view` /
  `get/highlighted_clip_slot` from the fork or from `show_view`'s orbit —
  they stay registered and documented; only this tool's use of them ends.
- Any `Session.State` change — the structure push already covers the new
  track.

## Open questions

1. **Which slot the converted clip lands in on the new track.** The
   read-back (and the notes count) read `[new_track, slot]` — the source's
   slot index — which the AX implementation also assumed and which no live
   run has ever confirmed (`auto/convert.md` has never run). ⚠️ Needs live
   Ableton; Live is not running on this machine at planning time (only the
   Seshat server's beam holds port 11001). Assumption: Live keeps the scene
   row. The cost of being wrong is a degraded reply detail ("slot reads as
   empty — check get_clip_slots"), not a wrong claim, because the read-back
   is best-effort and says what it saw. The first `/smoke-test convert` run
   settles it; if Live puts the clip elsewhere, fix the read-back to scan
   the new track's slots instead.
2. **Where Live inserts the new track.** Fork measurements say appended
   last (source was last); the AX-path run saw it land directly after the
   source. The plan removes every dependency on the answer
   (resolve-by-diff), so this stays open only as a fact worth recording —
   `auto/convert.md`'s first check asks the runner to note it. No code
   change hangs on the answer.
3. **Whether the async conversion folds into the tool call's undo step.**
   The track appears while the `begin_undo_step`/`end_undo_step` bracket is
   still open (the handler waits for it), but Live's conversion runs on its
   own thread and nothing measured says which undo step it joins. ⚠️ Needs
   live Ableton. Nothing in the tool's reply or description claims an undo
   count, so no wording rides on it; `auto/convert.md § One undo accounts
   for the converted track` measures it, and the description gains an undo
   sentence only if the measurement shows a surprise.
4. **Whether `/live/clip/audio_to_midi`'s own reply can lag past 5s on
   long material.** The fork measured a prompt `"ok", -1` on short clips —
   the LOM call returns before the analysis finishes, which is the whole
   async finding — so the assumption is the reply is prompt regardless of
   clip length. ⚠️ Unprovable without long source material in a live set.
   The mitigation is already designed: a post-send timeout uses the
   "requested, not confirmed — check get_session_state" wording, so even a
   wrong assumption never reports a done conversion as never-sent.
