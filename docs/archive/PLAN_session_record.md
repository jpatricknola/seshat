# Plan — Session record: deliberate takes into clip slots

> **Archived 2026-07-29 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. `record_clip` and
> `stop_recording` live in `Seshat.Tools.Definitions` / `Handlers`
> (`record_length_beats/3` plus the session-recording helper block), with
> `Seshat.Tools.FollowCam` steering to the slot/clip they touch. No fork
> change was needed — the feature rides `/live/clip_slot/fire`'s existing
> `record_length` argument. The four ⚠️ open questions below (record-length
> beat counting in odd meters, re-fire-to-stop behavior, `is_triggered`'s
> queued-window reading, and exclusive-arm interaction) were never resolved
> against a live Ableton. They are carried forward in the `/smoke-test` skill,
> which has a section for these two tools listing all nine checks — that, not
> this document, is where the open questions now live. The one roadmap
> follow-up (the clip-grid-in-session-state trigger, which session record was
> the event this item waited on) is noted in `docs/ROADMAP.md` #19.

Roadmap #1 (at the time this was written). Two new tools — `record_clip` and `stop_recording` — that close
the record loop: a deliberate take into a chosen Session slot, fixed-length
("record me eight bars on the keys") or open-ended ("record until I stop
you"), on MIDI *and audio* tracks. **No fork changes and no
`mix abletonosc.install`** — the whole feature rides on
`/live/clip_slot/fire`'s optional `record_length` argument, which the
installed bridge already forwards (verified against Live 12.4.3 on
2026-07-29, raw OSC). Pure Elixir plus one docs-row touch-up.

## Context

`set_track_arm` and `start_playing` exist, but nothing records — arming a
track today leads nowhere. `capture_midi` (shipped 2026-07-28) covers the
retroactive "keep that" move, but it is MIDI-only by construction and Live
places the clip wherever it likes. This plan adds the two things capture
cannot do: the deliberate take into a *chosen* slot, and **audio at all** — a
vocal, a guitar, or hardware currently has no route into the set. That second
one is the real capability gap and the reason this is #1.

Research findings that shape the plan (mostly inherited from the roadmap
entry's own 2026-07-29 verification, re-checked against the fork source):

- **Fixed-length record needs no fork change.** Upstream's
  `clip_slot.py` handler forwards everything after the two indices straight
  into the LOM method (`params[2:]`,
  [clip_slot.py](../priv/AbletonOSC/abletonosc/clip_slot.py) line 19), and
  `ClipSlot.fire()`'s first optional positional argument is `record_length`
  in beats. Fired at an empty slot on an armed track with `8.0`, Live
  recorded exactly two bars (4/4), stopped itself, and left an 8.0-beat clip
  looping with brace and markers already set. Live's own control surfaces
  (`novation/fixed_length_recording.pyc`, `APC64/recording.pyc`) use the same
  call. So "who ends the take" is answered for the fixed-length case: Live
  does, in-process, with no timer on our side.
- **The global `session_record` switch is the wrong mechanic for this tool.**
  The roadmap goal names `/live/song/set/session_record`,
  `trigger_session_record`, and `session_record_status`, but its planner
  notes correctly pivot: firing an empty slot on an armed track is the
  "record into *this* slot" mechanic; `session_record` is a global switch
  over *all* armed tracks with no slot choice. The slot fire is what the user
  story asks for, and it is also the only path that gets fixed-length
  semantics for free. The global addresses stay unused (see Out of scope).
- **The arm precondition cannot be checked against the mirror.**
  `Seshat.Session.State` does not mirror `arm`, and firing an empty slot on a
  *disarmed* track launches nothing, silently — the failure mode this project
  least tolerates. `/live/track/get/arm`, `/live/track/get/can_be_armed`, and
  `/live/clip_slot/get/will_record_on_start` are all upstream and documented;
  the tool queries and auto-arms (see Part 2 rationale).
- **The echo has to work before the clip exists.** `/live/clip/get/is_recording`
  needs a clip; on a just-fired empty slot there may not be one yet (a fire
  with the transport playing queues until the next launch-quantization
  boundary). The pre-start echo is slot-level: `is_triggered` (documented,
  upstream). The plan's echo uses only documented booleans — `has_clip`,
  `is_recording`, `is_triggered` — and deliberately avoids `playing_status`,
  whose enum values are documented nowhere in our address docs.
- **`get_clip_slots` already reports per-slot recording state** — the
  `recording?` flag in `parse_track_data/3` ([handlers.ex](../lib/seshat/tools/handlers.ex))
  renders as `[recording]` in the grid. "Report record state" from the
  roadmap goal is therefore already served for the reading side; the two new
  tools' replies cover the rest. No `Session.State` field is added — record
  state is transient, read rarely, and per the house rule promotion to the
  mirror needs frequent reads (the clip-grid precedent,
  [archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)).

Everything else follows settled patterns: single-object tools live in
`Handlers` and call `Transport` directly (no `%Command{}`); guards error
loudly instead of no-opping (the `fire_clip`/`write_midi_notes` precedent);
every guard reads through `query_echoed`/`query_flag` so a stray reply can't
answer for the wrong slot; the follow cam steers to what the tool touched.

## OSC contract

All addresses upstream, all registered in the fork
([clip_slot.py](../priv/AbletonOSC/abletonosc/clip_slot.py),
[track.py](../priv/AbletonOSC/abletonosc/track.py)), all in
[abletonosc-api-docs.md](abletonosc-api-docs.md). Getters echo the indices
ahead of the value — exactly what `query_echoed`/`query_flag` verify. Setters
and method calls never reply.

| Address | Request | Reply | Use here |
|---|---|---|---|
| `/live/clip_slot/get/has_clip` | `track, slot` | `track, slot, has_clip` | Slot-empty guard (inverse of `ensure_clip/3`) and post-fire echo |
| `/live/track/get/arm` | `track` | `track, armed` | Arm precondition read |
| `/live/track/get/can_be_armed` | `track` | `track, can_be_armed` | Group-track guard (groups can't record) |
| `/live/track/set/arm` | `track, 1` | — | Auto-arm; silent, so verified by re-reading `arm` |
| `/live/clip_slot/get/will_record_on_start` | `track, slot` | `track, slot, will_record_on_start` | The definitive "firing this records" check, post-arm |
| `/live/clip_slot/fire` | `track, slot[, record_length_beats]` | — | The take itself. With the third arg Live records exactly that many beats and stops itself; without, records until stopped. Extra args forwarded positionally into `ClipSlot.fire()` (`record_length`, then `launch_quantization`, `force_legato` — we send at most one) |
| `/live/clip_slot/get/is_triggered` | `track, slot` | `track, slot, is_triggered` | Echo: fired-and-waiting-on-quantization |
| `/live/clip/get/is_recording` | `track, slot` | `track, slot, is_recording` | Echo once the clip exists; also `stop_recording`'s guard |

`record_length` is in **beats**; Live's song-time beat is a quarter note, so
bars → beats is `bars × numerator × 4 / denominator` from the mirrored time
signature. ⚠️ The 2026-07-29 verification was in 4/4, where quarter-note
beats and signature counts coincide — the formula is unverifiable in odd
meters without Live (smoke item 6; worst case is a wrong-length clip and a
one-line formula fix).

⚠️ Two Live behaviours the contract relies on but raw OSC has not re-proven:
re-firing a recording slot ends the take at the next launch-quantization
boundary and drops it into looped playback (this is how Live users end a take
by clicking the slot, and the documented `ClipSlot.fire` semantics — smoke
item 3); and `is_triggered` reads true in the queued window between fire and
the quantization boundary (smoke item 4).

The docs table row for `/live/clip_slot/fire` says `track_index, clip_index`
with `record_length` only in the ℹ️ note below it — Part 5 adds the optional
argument to the row itself so the table is honest on its own.

## Tool shape — two tools, slot-addressed

- **`record_clip(track, clip_slot, bars?)`** — starts the take. `bars` given:
  Live stops it itself; omitted: open-ended. Not a `session_record` state
  toggle (`set_metronome`-style): starting and finishing a take have
  different arguments, different guards, and different replies, and the
  finish must *not* fire an empty slot by accident — a state param would put
  both behind one guard set.
- **`stop_recording(track, clip_slot)`** — finishes the take by re-firing the
  recording slot: the recording ends at the next launch-quantization boundary
  (a musically aligned loop end) and the clip drops straight into looped
  playback. Also ends a fixed-length take early. Slot arguments are required:
  the model always knows them (`record_clip`'s reply names them, and
  `get_clip_slots` shows `[recording]`), and the alternative —
  `/live/song/set/session_record 0` — is global, needs no fork but ends the
  take immediately at whatever odd length it has reached, with quantization
  semantics we cannot verify. Rejected: `/live/clip_slot/stop`, which stops
  the track's playback entirely rather than dropping the take into its loop.

Auto-arm rather than report-and-stop: "record me a take on the keys" *is*
consent to arm — bouncing back with "the track isn't armed, shall I arm it?"
would be a wasted turn for a user whose hands are on an instrument. The reply
says when it armed. The guard chain still errors loudly where arming can't
help: occupied slot, group track (`can_be_armed` false), or
`will_record_on_start` still false after a verified arm.

## Parts

### Part 1 — Definitions: `record_clip` and `stop_recording`

[lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex), placed
after `capture_midi` (the recording group). Draft descriptions — prompt text
for a model that can't see the code, per the §04 house pattern (preconditions,
units, index bases, which tool first, what the reply means):

`record_clip`:

> Record a take into a chosen Session clip slot in Ableton Live — the
> deliberate "record me eight bars on the keys" move, and the only way to
> record audio (capture_midi is retroactive and MIDI-only). Track and slot
> indices are 0-based; the slot must be empty — use get_clip_slots first to
> pick a free slot, or delete_clip a bad take. Arms the track automatically
> if it isn't armed (the reply says so). With bars given, Live records
> exactly that many bars of the current time signature, stops recording by
> itself, and leaves the clip looping — no stop call needed. Without bars
> the take runs until stop_recording. Timing: if the transport is already
> playing, recording starts at the next launch-quantization boundary
> (usually the next bar) — start playback first when the user wants a
> predictable punch-in; from a stopped transport it starts immediately, so
> make sure the user is ready *before* calling. Audio tracks record
> whatever input is routed to them in Live — Seshat cannot choose or check
> the input, so a silent take usually means the input isn't set. The reply
> says whether recording is running or queued for the boundary. The view
> follows: the slot is selected in the Session grid, turning red as it
> records.

Parameters: `track` (integer, "0-indexed track number"), `clip_slot`
(integer, "0-indexed scene/clip slot — must be empty"), `bars` (number,
optional, "How many bars to record, in the set's current time signature.
Omit for an open-ended take finished later with stop_recording."). Required:
`track`, `clip_slot`.

`stop_recording`:

> Finish a take that is recording in a Session clip slot (started by
> record_clip, or any clip Ableton Live is session-recording): recording
> ends at the next launch-quantization boundary — a musically aligned loop
> end — and the clip drops straight into looped playback; it keeps playing.
> Also ends a fixed-length take early. Track and slot are 0-based — the
> ones record_clip's reply named; get_clip_slots marks the recording slot
> if unsure. Errors if nothing is recording there. To scrap a take instead:
> stop it, then delete_clip.

Parameters: `track`, `clip_slot` (both integer, required).

### Part 2 — Handlers: `record_clip`

[lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex), a
`do_call/2` clause next to `capture_midi`. Sequence:

1. **Slot empty guard** — new private `ensure_slot_empty/2`, the inverse of
   `ensure_clip/3` via `query_flag("/live/clip_slot/get/has_clip", …)`:
   occupied slot → error naming `delete_clip` and `get_clip_slots`
   (re-firing an occupied slot would launch that clip, not record).
2. **Arm** — `query_flag("/live/track/get/arm")`; if false,
   `query_flag("/live/track/get/can_be_armed")` (false → error: group
   tracks have no slots of their own — record inside the group; mirrors
   `ensure_not_group_track`'s wording), then
   `Transport.send_message("/live/track/set/arm", [track, 1])` and re-read
   `arm` to verify (silent setter — the guard is the difference between an
   error and a lie). Remember whether we armed, for the reply.
3. **`will_record_on_start`** — `query_flag` on the slot; false after a
   verified arm → error ("Live reports firing this slot would not record —
   check the track's input routing/monitoring in Live"); nothing fired.
4. **Length** — if `bars` present: `beats = record_length_beats(bars, num,
   denom)` with the numerator/denominator from `State.song()` (push-fresh).
   `record_length_beats/3` is a **public pure helper** (the `capture_diff/2`
   pattern): `bars * numerator * 4 / denominator`, returning a float.
   Validate `bars > 0` → error otherwise.
5. **Fire** — `Transport.send_message("/live/clip_slot/fire",
   [track, slot, beats])` (float) or `[track, slot]` when open-ended.
6. **Echo** — `query_flag` `has_clip`: true → `query_flag` `is_recording` →
   "recording now"; `has_clip` false → `query_flag` `is_triggered` → true:
   "queued — starts at the next bar"; all false → error stating the take
   did not start and nothing is recording (fire is silent, so this is the
   only honest signal). Live processes OSC in order, so these reads run
   after the fire has been handled.
7. **Follow cam** — `FollowCam.steer("record_clip", %{track: track, slot:
   slot})` after a successful echo.
8. **Reply** — fixed-length: `Recording N bars (X beats) into track T, slot
   S — Live stops the take itself and leaves it looping.` Open-ended:
   `Recording into track T, slot S until stop_recording.` Append `Armed the
   track first.` when step 2 armed, and the queued/immediate distinction
   from step 6.

Pre-fire guard timeouts get the `capture_midi`-style `catch :exit` with a
"nothing was sent" message; each guard already catches its own timeout via
`query_echoed`.

### Part 3 — Handlers: `stop_recording`

1. `ensure_clip(track, slot)` — no clip means nothing recording (also
   covers the empty-slot case where a re-fire would *start* a recording,
   the one hazard this guard exists to kill).
2. `query_flag("/live/clip/get/is_recording")` — false → error ("Nothing is
   recording in slot S on track T — get_clip_slots shows what is.").
3. `Transport.send_message("/live/clip_slot/fire", [track, slot])` — the
   re-fire that drops the take into playback at the boundary.
4. `FollowCam.steer("stop_recording", %{track: track, slot: slot})`.
5. Reply: `Finishing the take in track T, slot S — it ends at the next
   quantization boundary and keeps looping. get_clip_notes or
   get_clip_properties to inspect it; delete_clip to scrap it.` (No length
   read-back: mid-finalisation the clip still reports Live's placeholder
   length, so a read here would echo garbage.)

### Part 4 — FollowCam clauses

[lib/seshat/tools/follow_cam.ex](../lib/seshat/tools/follow_cam.ex):

- `record_clip` → `selected_clip` + `show_view Session` (the `delete_clip`
  shape). The red slot in the grid is the confirmation; the detail pane is
  skipped because at steer time the clip may not exist yet (queued fire),
  and `detail_clip` on an empty slot is a silent no-op that would leave a
  stale clip in the pane. This satisfies the roadmap's timing note: the
  steer happens when the take starts, not when it ends.
- `stop_recording` → added to the full clip-steer list
  (`write_midi_notes` group: `selected_clip`, `detail_clip`, `Session`,
  `Detail/Clip`) — the finished take in the note editor (or waveform, for
  audio) is the payoff moment. This widens the settled "creates, writes and
  deletes steer" rule the same way `set_clip_properties` did: finishing a
  take is the moment the written thing exists.

### Part 5 — Docs row

[abletonosc-api-docs.md](abletonosc-api-docs.md): change the
`/live/clip_slot/fire` row's request params to
`track_index, clip_index, [record_length]` (the ℹ️ note already explains
it), and drop the note's "Nothing in Seshat uses it yet — see roadmap #1"
sentence.

### Part 6 — Tests and counts

- `test/seshat/tools/definitions_test.exs`: count 51 → **53**.
- `record_length_beats/3` unit tests: 4/4 × 8 bars → 32.0; 3/4 × 4 → 12.0;
  6/8 × 2 → 6.0; fractional bars.
- `FollowCam.calls/2` tests for both new tools (existing test file pattern).
- MCP parity is generated + already asserted by `Seshat.MCP.ToolsTest`.

### Part 7 — TOOL_AUDIT inventory

[TOOL_AUDIT.md](TOOL_AUDIT.md) §05: two new rows (`record_clip`,
`stop_recording`), noting the §02 record-loop gap they close. Also mark the
§02 "Record into a slot" gap row **ADDRESSED** (strikethrough style, the
sends/returns precedent in the same table), noting what remains out: global
multi-track session record and count-in, both deliberate (see Out of scope).

## Testing

**Pure (`mix test`, no Ableton):** Part 6 in full — definitions count and
schema parity, `record_length_beats/3`, FollowCam calls. The handler clauses
themselves reach `Transport.query/3` and are deliberately untested at that
layer.

**`/smoke-test` (needs Live + AbletonOSC):** nothing below has executed
through the tool path — the 2026-07-29 verification was raw OSC only.

1. Fixed-length take through the tool: empty slot, armed MIDI track, 2 bars
   → clip of exactly 8.0 beats (4/4), stops itself, loops.
2. Auto-arm: same on a *disarmed* track → tool arms it, reply says so.
3. Open-ended take + `stop_recording` → recording ends at the next bar
   boundary and the clip keeps looping (⚠️ re-fire semantics).
4. Echo wording: fire with transport playing → "queued" (⚠️ `is_triggered`
   true in the window); with transport stopped → "recording now".
5. **Audio take** — the headline: audio track with input routed, 4 bars →
   audible material in the clip.
6. Non-4/4: 6/8 set, 2 bars → clip is actually two bars (⚠️ beat-unit
   assumption in `record_length_beats/3`).
7. Guards: occupied slot, group track, disarmable-but-`will_record_on_start`
   false (e.g. no input) each produce their specific error, nothing fired.
8. `stop_recording` on a fixed-length take ends it early; on a slot that is
   merely playing → the "nothing is recording" error (and the clip keeps
   playing — the guard must run before any fire).
9. Follow cam: `record_clip` lands the view on the reddening slot;
   `stop_recording` opens the finished take in the editor.

## Out of scope

- **Global session record** (`/live/song/set/session_record`,
  `trigger_session_record`, `session_record_status`) — the multi-track
  "record everything armed" jam take. Different user story, no slot choice,
  and simultaneous multi-slot starts through sequential fires are racy.
  Stays on the roadmap if a real workflow asks for it.
- **Count-in** — `count_in_duration`/`is_counting_in` are in Live 12's LOM
  but unregistered upstream; exposing them is a one-line fork commit *plus*
  an install and a Live restart. v1 stays fork-free deliberately; the
  transport-playing quantization window plus the metronome is the runway.
  Buy it only if smoke testing shows takes starting before the user is
  ready.
- **`midi_recording_quantization`** — left to Live's own setting; `quantize_clip`
  (roadmap #6) is the after-the-fact cleanup and its enum is different.
- **Arrangement recording, overdub, punch in/out** — Session view only, per
  the standing "Deliberately not planned" entry.
- **Naming the take** (`record_clip` taking a `name`) — `set_clip_name`
  exists and renaming mid-record is unverified; revisit with capture_midi's
  `name` precedent if it grates.
- **Mirroring record state in `Session.State`** — read rarely; `get_clip_slots`
  and the tool replies cover it (decision recorded in Context).

## Open questions

All four need a live Ableton — none can be resolved at planning time, and
none block starting implementation; they are the first things to check in
`/smoke-test`.

1. ⚠️ **`record_length` beat units in odd meters** (smoke 6). Assumed:
   quarter-note beats, Live's song-time convention —
   `bars × numerator × 4 / denominator`. If Live counts signature beats
   instead, the fix is one line in `record_length_beats/3`.
2. ⚠️ **Re-fire finishing semantics** (smoke 3). Assumed: firing a recording
   slot ends the take at the next launch-quantization boundary and drops to
   looped playback — the documented `ClipSlot.fire` behaviour and how Live
   users end takes by clicking. If wrong, fallback is
   `/live/song/set/session_record 0` (immediate, unquantized end).
3. ⚠️ **`is_triggered` during the queued window** (smoke 4). Assumed true
   between fire and the quantization boundary. If it reads false, the echo's
   all-false branch would mislabel a healthy queued take as a failure — the
   check order (`has_clip` → `is_recording` → `is_triggered`) localises the
   fix to one branch.
4. ⚠️ **Auto-arm via OSC always lands** (smoke 2). Assumed: `set/arm` works
   regardless of Live's exclusive-arm preference (the LOM setter is direct).
   The re-read guard already converts a failed arm into a loud error rather
   than a silent non-recording, so the cost of being wrong is an error
   message, not a lie.
