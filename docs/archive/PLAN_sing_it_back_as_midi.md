> **Archived 2026-08-30 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The feature now lives in
> `set_mixer`'s input-routing and monitoring properties, `Session.State`'s
> per-track mirror, `record_clip`'s silent-take warning, the fifth `convert`
> command on `native/seshat_ax/main.m`, `Seshat.AX.Client.convert/1`, and the
> `convert_audio_to_midi` tool definition and handler. Live verification has
> not run — see the plan's own "Live verification" section below and the
> cited `docs/smoke_tests/` files, all still `*Last run: —*` for the checks
> this feature added.

# Plan — Sing it back as MIDI: a sung take, converted, on the instrument you meant

_Roadmap item: **"Sing it back as MIDI — a sung take, converted, on the
instrument you meant"** (currently #1). Written 2026-08-30, rewritten the same
day once the AX route was measured and the fork half landed._

## Context

A guitarist with a backing track down wants to sing a solo idea and hear it back
on a guitar patch. Seshat can already create the track, record the take, read
the notes, quantize them, and load an instrument. Two things are missing, and
this plan builds both:

1. **Audio input routing and monitoring.** `record_clip`'s own description
   admits it — *"Seshat cannot choose or check the input, so a silent take
   usually means the input isn't set."* Every address needed is already
   registered in the fork and **nothing under `lib/` sends any of them**.
2. **Convert.** Live's `Create → Convert Melody to New MIDI Track` is absent
   from the LOM at any spelling. It is a menu command, reachable only through
   the macOS Accessibility helper.

**The fork half is done.** `/live/view/focus_view` shipped in `b3db749` (#27)
and the three focus/selection reads in `ef4189e` (#29); `API.md`'s
`current_monitoring_state` rows are corrected. Seshat's gitlink is at `ef4189e`
and `mix abletonosc.install` has deployed it byte-identically.
**This plan is Elixir and Objective-C only** — every address it names is
registered and documented in the fork.

All of it is exercised against the running bridge. `focus_view` was measured
against `b3db749` (four focus transitions, bidirectional); the #29 reads were
checked at `ef4189e` on 2026-08-30 after a Live restart:
`get/highlighted_clip_slot` answered `(0, 0)`, `set/highlighted_clip_slot 0 0`
applied and read back, and `set/highlighted_clip_slot 99 0` was refused with
`ValueError: Track index out of range for category 'track': 99 (this song has 1)`
— validated, not subscripted, as the row promises.
⚠️ `get/focused_document_view` is confirmed **registered and not raising** only:
it does not log, and its reply goes to the port Seshat holds, so its *value* is
unverified until Part 6 is the first caller to read one.

### Measured facts this plan is built on

All measured 2026-08-30 against Live 12.4.5 Suite, macOS 15.7.4. They are
stated here because each one constrains an implementation choice below; the
probe that produced the AX half is committed at
[native/seshat_ax/probe/menu_probe.m](../../native/seshat_ax/probe/menu_probe.m).

| Fact | What it constrains |
|---|---|
| **Convert works.** Twice: an 8-bar source gave a 32-beat MIDI clip, and a 4-bar `generate_audio` render gave a 16-beat clip of 5 notes. `AXPick` on the enabled menu item is what fires it. | The feature is real. Part 4 onward is ordinary work. |
| **`AXPick` on the command item; `AXPress` on the menu-bar item.** `AXPress` opens the `Create` menu (`AXError=0`). `AXPick` fires the command. `AXPress` on a command `AXMenuItem` has **never been executed** in Live. | Part 4 uses `AXPick` for the command. Do not substitute `AXPress`. |
| **`AXEnabled` is meaningless until the menu is opened.** AppKit validates lazily; every selection-dependent Create item read `false` on a closed menu regardless of selection, clip type or activation. | Part 4 must open the menu, wait, then read — and `AXCancel` on every path that does not pick. |
| **UI focus, not selection, is what enables the command — and `focus_view` supplies it.** Driven both ways over OSC with nobody touching Live: `focus_view Arranger` → `false`, `Session` → `true`, `Browser` → `false`, `Session` → `true`. | Part 6 sends `focus_view Session` before selecting. This is a precondition, not view steering. |
| **The whole arc runs with no human touch.** `create_track` → `generate_audio` (4 bars) → `set_selected_clip` → `focus_view Session` → `AXPick` produced track `3-Melody to MIDI` holding `MIDI <source clip name>`, 16 beats, 5 notes. | The feature is buildable exactly as specified below. |
| **Note starts can be negative.** The converted clip's first note began at `start=-0.0116`. | Anything reading converted notes must not assume `start >= 0`. |
| **Naming is predictable.** Track is `Melody to MIDI` (Live prefixes its own UI number); the clip is `MIDI ` plus the source clip's name. | Part 6 can identify the new track by name as well as position. |
| **The new track lands directly after the source track**, not at the end — `Melody to MIDI` arrived at index 3 and the pre-existing MIDI track renumbered behind it. | Part 6 must not assume the new track is last. |
| **Completion arrives as a structural push.** Both the convert and a control `Insert MIDI Track` appeared as `Property tracks changed of song`. No dialog appeared (`windows=1 [Untitled]` before and 300 ms after). | Part 6 waits on the track count, never polls AX. |
| **`current_monitoring_state` is `0 = In, 1 = Auto, 2 = Off`** — Live's own `Push2/routing.pyc` binds `monitoring_states.IN/.AUTO/.OFF` in that order; track 0 answered `1`, Live's default of Auto. | Part 1 exposes a string enum, never the integer. |
| **A wrong input-routing name is a silent no-op.** `set/input_routing_type` with an unmatched name logged a warning and sent **nothing** — no reply, no `/live/error`. `track_set_input_routing_type` loops the available list and falls through to `logger.warning`. | Part 1 must validate against the available list *before* sending, and read back after. |

### Musical honesty

Convert Melody is monophonic pitch tracking, not transcription. Slides, bends
and breathy attacks come back as note salad; a clean line comes back usable. The
tool description routes the model to `quantize_clip` and `edit_notes` as the
*expected* second pass rather than promising a clean result. Convert Harmony and
Convert Drums are the same menu and the same mechanism, so the tool takes a mode
enum rather than being melody-only.

**The 2026-08-30 test run is not evidence against the converter.** Its source
was a Stable Audio render described as an electric guitar solo, which the user
judged by ear to be four notes and musically poor. Convert returned five notes —
faithful tracking of weak material, not weak tracking. That is consistent with
the existing ruling that SA3→transcribe is a poor primary MIDI strategy: the
generator is the weak link. **This feature's input is a human voice** — a real
monophonic performance with clean pitch and attacks — which is Convert Melody's
best case rather than its worst, so the by-ear check in Live verification is
what actually judges the feature.

Convert is Live 9+, **Standard and Suite** — no edition gate.

## OSC contract

Every address is registered in the fork and documented in
[priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md). The track- and clip-family
replies carry the echoed indices first, which is what `query_correlated/4`
matches on. The view getters (`selected_clip`, `highlighted_clip_slot`,
`focused_document_view`) and `num_tracks` echo **nothing** — they correlate by
address alone, so a stale straggler is indistinguishable by content; Part 6's
cross-check of two independent selection reads is the defence there, not an
echo.

### Input routing and monitoring — Parts 1–3

| Address | Request | Reply | Notes |
|---|---|---|---|
| `/live/track/get/available_input_routing_types` | `track_id` | `track_id, name, ...` | Flat tail of `display_name` strings, **no count prefix**. The count-first shape elsewhere in `API.md` is the return/master *output* variant — different family, do not copy it |
| `/live/track/get/available_input_routing_channels` | `track_id` | `track_id, name, ...` | Same shape. Reflects the *currently selected type* |
| `/live/track/get/input_routing_type` | `track_id` | `track_id, name` | `display_name` of the current object |
| `/live/track/get/input_routing_channel` | `track_id` | `track_id, name` | |
| `/live/track/set/input_routing_type` | `track_id, name` | — | **No reply, and no error on a bad name** |
| `/live/track/set/input_routing_channel` | `track_id, name` | — | Same silent-no-op behaviour |
| `/live/track/get/current_monitoring_state` | `track_id` | `track_id, state` | `0 = In, 1 = Auto, 2 = Off` |
| `/live/track/set/current_monitoring_state` | `track_id, state` | — | Generic `properties_rw` setter; fire-and-forget |
| `/live/track/get/can_be_armed` | `track_id` | `track_id, can_be_armed` | The preflight. Live's own `can_monitor` is `can_be_armed and not is_frozen` |

**Returns and the master have no input section** — the fork deliberately
registers no input address for either. The new properties are
regular-track-only.

### Convert — Parts 4–6

| Address | Request | Reply | Notes |
|---|---|---|---|
| `/live/view/show_view` | `view_name` | — | Makes the pane visible |
| `/live/view/focus_view` | `view_name` | — | Gives it keyboard focus. **This is what enables the menu command**; `show_view` alone does not |
| `/live/view/get/focused_document_view` | | `"ok", view_name` or `"error", message` | Reads focus back. `view_name` is `Session` or `Arranger` only — partial verification, see `API.md` |
| `/live/view/set/selected_clip` | `track_index, scene_index` | — | Moves the ring; honoured by the menu once the grid has focus |
| `/live/view/get/selected_clip` | | `track_index, scene_index` | Read-back proving the ring landed |
| `/live/view/get/highlighted_clip_slot` | | `track_index, scene_index` | The slot itself, as a second read-back independent of the ring |
| `/live/view/set/highlighted_clip_slot` | `track_index, scene_index` | — on success, `/live/error` on a bad index | **Not a silent setter** — it validates both indices, so an out-of-range value is an error rather than a wrap-around |
| `/live/song/get/num_tracks` | | `num_tracks` | Before/after count bracketing the pick |
| `/live/clip_slot/get/has_clip` | `track_index, clip_index` | `track_index, clip_index, has_clip` | Guard: the slot holds something |
| `/live/clip/get/is_midi_clip` | `track_id, clip_id` | `track_id, clip_id, is_midi_clip` | Guard: it is audio, not MIDI |
| `/live/clip/get/notes` | `track_id, clip_id` | notes | Proof the converted clip has content |

### AX contract — Part 4

A fifth command on the helper's JSON protocol:

```
seshat-ax convert --command "Convert Melody to New MIDI Track"
```

- Title must be one of **three** compiled-in strings: `Convert Melody to New
  MIDI Track`, `Convert Harmony to New MIDI Track`, `Convert Drums to New MIDI
  Track`. Anything else is `{"ok":false,"code":"unknown_command"}` without
  touching AX. No generic press, no tree dump, no keystroke, no coordinates.
- Path: bundle id `com.ableton.live` → `AXMenuBar` → `AXMenuBarItem` titled
  `Create` → `AXMenuItem` with that exact `AXTitle`. Located by title and role,
  never by sibling order.
- Activate Live and wait for `NSRunningApplication.active` **on a runloop** —
  sleeping never sees the notification. Re-locate the item after activation.
- **`AXPress` the `Create` menu-bar item to open the menu, wait ~350 ms, then
  read `AXEnabled`.** A reading taken before this is worthless.
- `false` → `{"ok":false,"code":"command_unavailable"}` carrying the title,
  after `AXCancel` on the menu-bar item. Never pick.
- `true` → `AXUIElementPerformAction(item, kAXPickAction)`. Record the
  `AXError`.
- Report `AXWindows` ~200 ms later so the reply can say whether a dialog
  appeared. Convert raised none in the measured run; if one does, the tool
  refuses to claim success rather than driving it.
- Restore the previously frontmost application **and wait for the restore** — a
  fire-and-forget restore lands during the next run and breaks it.
- `kAXCancelAction` on the menu-bar item on every non-picking exit, so a failure
  never leaves the Create menu hanging open.
- `kProtocolVersion` → **2**. `Seshat.AX.Client` already refuses a mismatch and
  names `mix ax.install`.

## Numbered parts

### 1. `set_mixer` gains input routing and monitoring

**Files:** [lib/seshat/tools/definitions.ex](../../lib/seshat/tools/definitions.ex),
[lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)

This is a property on an existing intention, not a new tool — setting a track's
input is the same producer intention as setting its arm.

Three new `set_mixer` properties:

- `"input_type"` — string. *"Live's own name for the input source, exactly as it
  appears in the track's Input Type chooser (for example 'Ext. In',
  'Resampling', or another track's name). Names come from the user's interface
  and their set, so never guess one — read them from get_session_state or from
  this tool's own error, which lists the real names."*
- `"input_channel"` — string, same treatment. *"Set input_type in the same call
  when changing both; the channel list depends on the type."*
- `"monitoring"` — string, `enum: ["in", "auto", "off"]`. **An enum, never the
  raw integer** — the wire values are the reverse of what a reader assumes and a
  wrong integer is an undetectable no-op. *"'auto' (Live's default) passes the
  input through only while the track is armed and no clip is playing; 'in'
  always passes it through, which is what you want while a player sets levels
  before a take; 'off' never does."*

In `Handlers`:

- Add all three to `@mixer_properties` (fixed order, deterministic write list).
- Add them to `@mixer_supported` under **`"track"` only**. Returns and master
  then refuse by name through the existing atomic preflight — no new mechanism.
- **Validate before sending.** For `input_type`: read
  `available_input_routing_types`, and if the requested name is not in it,
  refuse with the real names listed. Same for `input_channel` against
  `available_input_routing_channels`. This is the whole point — an unmatched
  name is silently dropped by the fork, so a tool that just sends is a tool that
  lies.
- **The refusal is also the discovery path, and that is deliberate.** Input
  names come from the user's audio interface and their set, so they cannot be
  documented in a tool description or guessed. The model learns them from the
  listing in this error and from Part 3's no-input refusal, which carries the
  same list. That makes a first routing attempt on an unfamiliar machine cost
  one refused call — acceptable, because the alternative is either a read tool
  (a tool name for a list the model needs twice in a session) or padding every
  `get_session_state` reply with every input on every audio track. If usage
  shows the refused first call is a real cost, the cheap fix is adding the list
  to `get_session_state`'s audio-track line, not a new tool.
- **Order the writes:** type first, then re-read `available_input_routing_channels`,
  then channel. The channel list is rebuilt per type.
- **Read back after.** Report the value Live holds, not the value requested.
- Monitoring maps `in → 0`, `auto → 1`, `off → 2`, table-driven in one place.
  Preflight `can_be_armed`; a track that cannot be armed cannot monitor.

`set_mixer`'s description gains one sentence naming the new properties and one
pointing at `get_session_state` to read them. Keep it short — that description
is already 18 lines against the 3,585-byte `set_clip_properties` ceiling
recorded in `mcp-surface.md`.

### 2. `Session.State` mirrors the input, `get_session_state` renders it

**Files:** [lib/seshat/session/state.ex](../../lib/seshat/session/state.ex),
[lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)

Three new per-track fields: `input_type`, `input_channel`, `monitoring`.

⚠️ **There is no existing batched track read.** `Session.State.read_tracks/2`
is a deliberate per-index serial loop, and its own doc block defers a batched
rewrite to the gated roadmap item "Monitored refresh worker for
`Session.State`" — do not rewrite that loop here. Add the new fields to its
per-track step, reading them in **one `Transport.query_batch/2` call per
track** rather than three more serial queries, so the rebuild does not grow by
three round trips per track.

The mirror does not yet know a track's *type* — `read_tracks/2` reads name,
volume, pan, mute and solo only — so "audio tracks only" needs a
discriminator: read `/live/track/get/has_audio_input` in the same batch and
store it. A routing read that errors or goes unanswered stays `nil` and
renders nothing, which also quietly covers any track (a group, say) that
reports audio input but has no input chooser.

**No listeners.** `current_monitoring_state` has a listen pair; the two routing
properties are custom handlers with none. Mixing one pushed value with two
polled ones in the same row invites exactly the staleness `Session.State` is
careful about, so all three are read on refresh and none by listener.

Render on the track line **only for audio tracks**, so a MIDI-only set's reply
does not grow. Report the strings verbatim — never interpret an input name.

### 3. `record_clip` warns before a silent take

**File:** [lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)

When the target track is an **audio** track, read `input_routing_type` and
`current_monitoring_state` in one batch before firing, then:

- Name the input verbatim in the reply — *"recording track 3, listening to
  Ext. In 3/4"*.
- If the type reads Live's no-input value, **refuse before recording**, name the
  `set_mixer` properties that fix it, **and list the inputs this machine
  actually offers** (`available_input_routing_types`, read in the same batch).
  A take that records silence is worse than a refusal, and this refusal is
  one call from being actionable rather than one guess plus one call.
- If monitoring is `off`, warn but **still record** — off is legal and normal
  when the player monitors through their interface.
- ⚠️ The display name Live uses for "no input" is unmeasured (Open question 2).
  Until it is, treat an *empty* type string as no input and otherwise report
  verbatim without refusing.

MIDI tracks take neither path and are unchanged.

Delete the *"Seshat cannot choose or check the input"* sentence from
`record_clip`'s description — it stops being true here — and replace it with the
`set_mixer` pointer.

### 4. The helper's fifth command

**File:** [native/seshat_ax/main.m](../../native/seshat_ax/main.m)

Implement `convert --command "<title>"` exactly as the AX contract above
specifies. Reuse the existing transaction shape: one `kActionDeadline`, one
unconditional cleanup block with a single `return NULL`-shaped exit, restore-and-
wait. The three allowlisted titles are a `static const` array with a comment
naming this plan and stating why a generic press is not offered.

Then `mix ax.install`. ⚠️ `~/.seshat/bin/` does not exist on the development
machine — the helper has never been installed there, so this is a first install,
not an upgrade, and macOS will need the printed path approved.

### 5. `Seshat.AX.Client.convert/1`

**File:** [lib/seshat/ax/client.ex](../../lib/seshat/ax/client.ex)

One public function beside `list_outputs/0` and `set_output/1`, one new
`@callback`, sharing the existing lock, the existing 5,000 ms budget measured
from the handler call, and the existing failure shape.

No new door — same module, same binary, same grep exemption.
`client_test.exs`'s file list needs no change.

### 6. `convert_audio_to_midi`

**Files:** [lib/seshat/tools/definitions.ex](../../lib/seshat/tools/definitions.ex),
[lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)

This one earns a tool name: it consumes an audio clip and produces a track — a
different workflow, not a property of an existing intention.

```
convert_audio_to_midi(track, clip_slot, mode)
  mode: "melody" | "harmony" | "drums"   (required, no default)
```

`track` and `clip_slot` declare `minimum: 0` in the schema, and `Validation`
enforces it before dispatch. Load-bearing, not style:
`/live/view/set/selected_clip` is one of the three legacy view setters that
resolve a negative index from the *end* of the list instead of raising
(`API.md` § Selected-track identity — "`-1` is an answer, never an argument"),
so without the bound a negative index could slip past the guards and convert a
clip on the wrong track.

Draft description:

> Turn an audio clip into a new MIDI track playing the same part — Ableton
> Live's own Convert. Use 'melody' for a single line (a sung or hummed solo, a
> bass part), 'harmony' for chords and pads, 'drums' for a beat, which lands on
> a Drum Rack. Track and slot are 0-based and must hold an **audio** clip; a
> MIDI clip is refused. Live analyses pitch, so the result follows what was
> actually played, warts included: expect to follow up with quantize_clip and
> edit_notes rather than expecting a clean part. The new track arrives directly
> after the source track, carrying an instrument Live chose — replace it with
> load_device once you know what the user wants it to sound like. **This briefly
> brings Ableton Live to the front**, so do it between takes, never during one.
> Live 9+, Standard and Suite.

Handler sequence, in this order:

1. `/live/clip_slot/get/has_clip` and `/live/clip/get/is_midi_clip` — **refuse
   an empty slot or a MIDI clip before touching AX.** Guards before side
   effects.
2. `/live/view/show_view Session`, then `/live/view/focus_view Session`, then
   `/live/view/get/focused_document_view` to **confirm focus landed**. Focus is
   what makes Live's menu validation see the selection at all — measured, and
   measured bidirectionally. Anything but `Session` is a refusal here, naming
   focus, rather than a `command_unavailable` three steps later that blames the
   clip.
   ⚠️ Partial verification, per `API.md`: the read answers only `Session` or
   `Arranger`, so it catches an Arranger focus and not a Browser one. Treat a
   `Session` reading as necessary, not sufficient — step 5's refusal is still
   the backstop.
3. `/live/view/set/selected_clip`, then `/live/view/get/selected_clip` **and**
   `/live/view/get/highlighted_clip_slot` to confirm the selection landed. A
   selection that did not land would make the pick act on something else — the
   one genuinely dangerous failure here — and the two reads disagree exactly
   when the ring moved but the slot did not. Refuse on disagreement.
   `set/highlighted_clip_slot` is available as a second write path if the ring
   ever proves insufficient; it is not needed on the measured path, so do not
   send it speculatively.
4. `/live/song/get/num_tracks` — the before count.
5. `Seshat.AX.Client.convert/1`. `command_unavailable` renders as *"Live would
   not convert that clip"* plus the selection it saw. Focus and selection were
   both verified above, so this error means Live itself declined — not that a
   precondition silently failed.
6. Wait, bounded, for the count to rise by **exactly one**. No rise, or more than
   one → report honestly and name no index, as `Registry`'s `create_track` guard
   does. **Resolve the new track by position after the source track, never by
   assuming it is last.**
7. Read the new track's name and its clip's notes; report note count and the
   instrument Live loaded, and route to `load_device` to change it. Length is
   inherited from the source, not normalised — the measured convert produced 32
   beats from 8 bars.

`undo_step` stays **true** — this changes the Set. `definitions_test`'s pin on
`unstepped_names/0` must remain exactly the two audio-output tools.

`FollowCam.steer/2` on the new track index.

### 7. Bookkeeping

- `test/seshat/tools/definitions_test.exs`: tool count **53 → 54**. Measured
  post-implementation (`mix run --no-start`, no app started): 54 tools,
  63,880 bytes serialized, largest schema `generate_audio` at 3,792 bytes,
  then `set_clip_properties` (3,555), `search_library` (3,353),
  `set_mixer` (3,285) — well under the budget `.claude/docs/adding-a-tool.md`
  asks a plan minting a name to watch.
- **`docs/smoke_tests/auto/README.md`'s file table gains `convert.md`.** Already
  done on this branch. Named here because the `generate_audio` PR shipped with
  exactly this line missing, which silently skipped that PR's only live coverage
  on every full `/smoke-test` sweep.
- `native/seshat_ax/probe/menu_probe.m` is part of this diff. It is not product
  code and is excluded from `mix ax.install` by construction — that task
  compiles the single named source `native/seshat_ax/main.m` rather than
  globbing — and `client_test.exs`'s process-start grep covers `lib/` only.
  Keep it committed: the 2026-08-03 `ax-probe`'s source was never kept and only
  its binary survives, which is why tonight's findings needed a new probe from
  scratch.
- The submodule pin is at `ef4189e` and already committed on this branch
  (`38e9ef5`). Nothing further to do; noted so a reviewer reading the diff knows
  the gitlink move is intentional and which fork PRs it carries (#27, #29).
- `mix routing.eval` — required, `Definitions` changed. Attach `report.md`.
- `mix precommit`.

## Testing

Pure, no Ableton:

- The `monitoring` enum rejecting `"In"`, `1`, `true` — the wire value is an
  integer the model never sees.
- Monitoring name → wire integer, both directions, table-driven.
- `@mixer_supported`: `input_type` on `target: "return"` is refused by name and
  **nothing is sent** — assert zero datagrams at `Seshat.Test.OSCSink`.
- Routing validation: a name absent from the available list is refused *before*
  any set datagram, and the error carries the real names. Assert wire order —
  available-list read, then set, then read-back.
- Write ordering: type before channel, with the channel list re-read between.
- `record_clip`'s pre-read: an empty input type refuses and sends no record
  message; a named input records and the name appears verbatim; a MIDI track
  takes neither path.
- `convert_audio_to_midi` against the fake `Seshat.AX.Client`: the MIDI-clip
  refusal happens before any AX call; `command_unavailable` produces the
  readable refusal; a count that does not rise names no index. Assert arrival
  order at the sink — has_clip, is_midi_clip, show, focus, **read focus back**,
  set selected, get selected, **get highlighted slot**, count. Cover the two new
  refusals: a focused view that is not `Session`, and a ring that disagrees with
  the highlighted slot; neither reaches the AX client.
- MCP component parity with `Definitions`, as generated.

Not testable here, by construction: every AX call, and the silent-no-op of a bad
routing name — `Transport.send_message/2` cannot be made to fail against the
harness.

## Live verification

Nothing in `mix test` reaches any of this — every address is at
`Transport.query/3` or below, and the setters never reply. Assume **zero** prior
coverage on the routing surface. Run the automated half with `/smoke-test`.
`mix ax.install` is required first and has never run on this machine.

Parts 1–3:

- `smoke_tests/auto/mixer.md § An input route round-trips, and a name Live
  doesn't have changes nothing` — the measured silent-no-op; a bogus name
  reported as applied means the validation or the read-back is missing.
  **Ran 2026-08-30 (PR review), passed.** On a fresh audio track,
  `input_type: "Seshat Not A Real Route"` was refused before anything went out,
  naming Live's real list: `'Ext. In', 'Resampling', 'Main', 'No Input'`.
  `get_session_state refresh: true` afterwards still read
  `in="Ext. In"/"1"` — unchanged. `input_type: "Resampling"` was accepted and
  read back as `in="Resampling"` (no channel, and the renderer correctly omits
  the channel clause when Live reports none). Live's `Log.txt` tail past the
  baseline offset carries **zero** `input_routing` lines, so the refused name
  reached neither the wire nor the fork's fall-through warning.
  ⚠️ This run also **answers open question 2**, which the implementation
  assumed the other way: Live's name for "nothing routed" on this machine is
  the literal routing type `"No Input"`, not an empty string. See the findings
  in the PR review — the empty-string branches in `check_audio_input` and
  `track_input_summary` never fire here.
- `smoke_tests/auto/mixer.md § input_type and monitoring are refused on a return
  and the master`
  **Ran 2026-08-30 (PR review), passed.** `target: "return", track: 0,
  input_type: "Ext. In"` → *"A return track has no input_type — it has volume,
  pan, mute, solo, name. Nothing in this call was sent."*; `target: "master",
  monitoring: "in"` → *"The master has no monitoring — it has volume, pan.
  Nothing in this call was sent."* Refused at the `@mixer_supported` preflight,
  before index resolution — the set has no return tracks at all and neither
  call complained about the index. `Log.txt` shows no `input_routing` line for
  either.
- `smoke_tests/auto/recording.md § An audio take names its input, or refuses
  before recording`
  **Ran 2026-08-30 (PR review). Second half passed; the refusal half did not
  reproduce as written, and what happened instead is a finding.** A fresh audio
  track on this machine defaults to a *real* input (`Ext. In` / `1`), so the
  test's first call recorded rather than refusing — exactly the case the test's
  own ⚠️ anticipates. `record_clip bars: 1` named it verbatim:
  *"Listening to \"Ext. In\" on \"1/2\"."*, and `get_clip_slots` showed the
  4.0-beat take land. Driving the track to Live's actual no-input value
  (`set_mixer input_type: "No Input"`) and recording did **not** reach
  `check_audio_input`'s refusal: `can_be_armed` is false under `No Input`, so
  `ensure_armed` refused first with *"Track 1 can't be armed for recording…
  Group tracks have no clip slots of their own"* — a correct refusal with a
  wrong reason. Nothing was recorded either way, so no silent take escaped, but
  the guard this citation exists to exercise was never the thing that fired.
- `smoke_tests/auto/recording.md § Monitoring set to off warns but still records`
  **Ran 2026-08-30 (PR review), passed.** `set_mixer monitoring: "off"` on the
  routed audio track, then `record_clip bars: 1` on an empty slot: the reply
  carried *"Monitoring is off, so the input won't be heard through Live while
  it records; that is normal when the player monitors through their interface,
  and set_mixer monitoring: 'in' changes it"* **and** fired the take, which
  `get_clip_slots` confirmed as a 4.0-beat clip. `monitoring: "in"` then
  round-tripped and read back as `monitoring in` through
  `get_session_state refresh: true`. Which physical button each name moves is
  still the manual `on-screen.md` check — see the finding on the fresh-track
  default reading `off`.
- `smoke_tests/manual/on-screen.md § Monitoring in, auto, off move the right
  button` — the dial check for a mapping derived from Live's shipped Push 2
  script plus one wire reading. Getting it backwards is completely silent.
- `smoke_tests/manual/on-screen.md § The input choosers move, and the channel
  list follows the type` — confirms the write ordering by eye.

Parts 4–6:

- `smoke_tests/auto/convert.md § A converted clip lands as a new track whose
  notes read back` — `generate_audio` supplies the audio clip, so an agent runs
  it alone.
  **Ran 2026-08-30 (PR review), passed — first end-to-end run of this feature
  through the tool surface.** `generate_audio bars: 2` put an 8.0-beat clip in
  track 1 slot 2, then `convert_audio_to_midi mode: "melody"` replied
  *"Converted the melody in slot 2 on track 1 to a new MIDI track 2
  \"3-Melody to MIDI\". It holds 10 note(s). Live put \"Melody to MIDI\" on
  it…"*. Verified by read-back, not by the reply: `get_clip_slots` showed the
  track count risen from 2 to **3**, the new track at index **2** (directly
  after the source, as the plan requires — not last), holding
  `"MIDI simple solo clarinet melody, one note at"` at 8.0 beats in slot 2,
  with the source audio clip still in track 1 slot 2 untouched.
  `get_clip_notes` returned 10 notes, the first at
  `start=-0.0116` — reproducing the plan's measured negative note start on a
  second, independent convert.
- `smoke_tests/auto/convert.md § A MIDI clip is refused before Live is ever
  touched` — guard-before-side-effects; reaching the helper's own refusal is a
  failure even though the answer is right.
  **Ran 2026-08-30 (PR review), passed on the observable half.**
  `write_midi_notes` put a 2-note clip in track 0 slot 0;
  `convert_audio_to_midi` on it returned *"Slot 0 on track 0 holds a MIDI clip,
  and Convert turns *audio* into MIDI — nothing was converted and Ableton Live
  was never brought to the front."* `get_clip_slots` afterwards showed the
  track count unchanged. ⚠️ **Not covered by this run:** whether Live actually
  stayed in the background. That is a screen observation, and it belongs to
  `manual/on-screen.md § Convert brings Live forward and gives it back`; the
  refusal wording asserts it, and `handlers_test`'s
  `refute_receive {:ax_call, :convert, _}` pins the code path, but neither is
  the same as seeing it.
- `smoke_tests/auto/convert.md § An empty slot and a bad index refuse cleanly`
  **Ran 2026-08-30 (PR review), passed.** `clip_slot: 5` on the audio track →
  *"Slot 5 on track 1 is empty… Convert needs an audio clip to work from —
  record one with record_clip, or make one with generate_audio."*; `track: 99`
  → *"Index out of range. Nothing further was sent — check get_session_state
  for the indices that actually exist."* — Live's own structured `/live/error`
  arriving through the `has_clip` guard, not an AX deadline. Both returned
  promptly with no ~5s pause, and `get_clip_slots` showed the track count
  unchanged after both.
- `smoke_tests/manual/on-screen.md § Convert brings Live forward and gives it
  back` — focus restore, no menu or dialog left open, and how many `undo` calls
  the convert costs.
- `smoke_tests/manual/by-ear.md § Sing a line, hear it back as a guitar` — the
  only check that can fail the *feature* rather than the code.

Surface:

- `smoke_tests/manual/conversation.md § A sung take routes to setup, record,
  then convert` — judges `mode` selection from what the user said.
- `smoke_tests/auto/mcp-surface.md § The tool list survives a real handshake` —
  a client that rejects the schema refuses the **whole list**. Its only recorded
  run is 2026-08-28 at 52 tools and is stale.
  **Ran 2026-08-30 (PR review), passed.** `mcp_call.py list` over a real
  handshake against the running server: **54 tools**, matching
  `Definitions.all()` and `definitions_test.exs`'s pin, with
  `convert_audio_to_midi` present. `mcp_call.py schema convert_audio_to_midi`
  survives intact — `minimum: 0` preserved on both `track` and `clip_slot`
  (load-bearing against `set/selected_clip`'s negative-index wrap-around),
  `mode` carrying its three-value enum, and all three in `required`.
  `set_mixer` advertises `input_type`, `input_channel` and `monitoring`, the
  last with its `["in","auto","off"]` enum.
- `smoke_tests/auto/mcp-surface.md § The surface budget is measured, not guessed`
  **Ran 2026-08-30 (PR review), passed.** `mcp_call.py stats`: **54 tools /
  66,960 bytes / largest `generate_audio` at 3,875 bytes**. Up one tool and
  2,838 bytes from the 2026-08-30 `generate_audio` baseline of 53 / 64,122 /
  3,875 — the largest tool is unchanged, so the growth is `convert_audio_to_midi`
  plus `set_mixer`'s three new properties. The client-visible number is ~5%
  above the plan's Elixir-side estimate of 63,880, the same direction and rough
  size as the gap recorded for the two previous surfaces.

**Uncovered:**

- **Whether `AXPress` works on the command item.** The contract uses `AXPick`
  because that is what was measured; no test here covers `AXPress`.
- **Every input name but this machine's.** A set opened elsewhere offers
  different names, and two routings sharing a display name cannot be provoked on
  demand.
- **Convert Harmony and Convert Drums.** All three modes ship; only `melody` is
  tested, because only it has a user story here.
- **Concurrent AX callers.** Serialization is pinned against the fake; two real
  converts racing for the menu is not provokable through the tool surface.

## Out of scope

- **Output routing, groups, automation envelopes** — stay in the roadmap's
  "Small OSC breadth — grab bag".
- **The other Create-menu commands** — Stem Separation, Slice, Extract Groove,
  Bounce stay with "Live-native generation spike — can AX drive the Create
  menu?"
- **A clip-selection tool.** `set_selected_clip` and `focus_view` are used inside
  the convert handler and not exposed. Selecting a clip is a step inside an
  intention, not one itself.
- **Driving any dialog.** If Convert raises one, the tool reports it and refuses
  to claim success.
- **Making the converted result good.** Cleanup is `quantize_clip` and
  `edit_notes`, which already exist.
- **Count-in.** The fork exposes `get/count_in_duration` and no setter. Grab bag
  if it ever matters.

## Open questions

1. ~~**Does `focus_view("Session")` over OSC enable the command the way a click
   does?**~~ **Closed 2026-08-30 by measurement, against the installed pin.**
   Yes, and it is bidirectional: `Arranger` → `false`, `Session` → `true`,
   `Browser` → `false`, `Session` → `true`, all over OSC with nobody touching
   Live. The full arc then ran end to end and produced a converted MIDI track.
   `focused_document_view` and `highlighted_clip_slot` were not needed to make
   it work and have since shipped anyway in `ef4189e` (#29), so Part 6 verifies
   both preconditions rather than sending them blind.

2. **What does Live call "no input"?** ⚠️ Unmeasured, so Part 3 cannot refuse by
   name. **Assumed:** an empty string, with any non-empty value reported verbatim
   and not refused. Getting this wrong makes the warning weaker, never wrong.

3. **Is the whole convert one undo step?** ⚠️ The run that fired it was not
   bracketed. **Assumed:** a UI-originated command does not fold into Seshat's
   bracket, so the reply says the convert may need more than one `undo`.
   Measurable in one probe pass, and cheap to fold into the Part 4 install run.
