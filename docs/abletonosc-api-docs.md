# AbletonOSC API Reference

> Source: https://github.com/jpatricknola/AbletonOSC — Seshat's fork of
> [ideoforms/AbletonOSC](https://github.com/ideoforms/AbletonOSC), checked out
> as a submodule at `priv/AbletonOSC` and installed by `mix abletonosc.install`.
> Addresses marked "Seshat extension" below exist only in the fork; `SESHAT.md`
> at the fork root lists every divergence, including its fixes to upstream's
> own code.
> Protocol: OSC over UDP
> Send commands to: **`127.0.0.1:11000`**
> Reply port: 11001
> The fork binds its command socket to loopback only, so nothing off this
> machine can reach any address below. Callback replies go to the originating
> host — which can therefore only be loopback — on port 11001, and listener
> pushes, `/live/startup` and `/live/error` go to a fixed `127.0.0.1:11001` that
> incoming traffic never retargets. Upstream binds `0.0.0.0` and follows the
> last sender; see `SESHAT.md` in the fork, and don't widen either without
> `docs/evaluating/SECURITY_BACKLOG.md`'s deployment-gated work.
> Wildcard patterns supported (e.g., `/live/clip/get/* 0 0` queries all properties of track 0, clip 0).

---

## Round trips cost ticks, not datagrams

**Measured against Live 12 on 2026-08-04** (harness bound to `127.0.0.1:11001`
with no Seshat instance running; large-burst runs at 9 tracks, temporary tracks
deleted afterwards). This is the fact every read-shaped design decision here
rests on, so it is stated before the address tables rather than inside one.

`manager.py` schedules `tick()` once per 100ms on Live's main thread, and each
tick's `osc_server.process()` drains **every** datagram already queued on the
socket, answering each inline. A query therefore costs ~100ms because it waits
for the next tick — not because the datagram is expensive.

| Test | Result |
|---|---|
| Serialized getter ×20, same address (`/live/song/get/tempo`) | 99.6–100.4ms each — exactly one tick per query |
| Serialized getters ×20, alternating addresses | identical: 99.1–100.4ms each |
| Burst of 10 different-address song getters, ×3 | all 10 answered in **one tick**, 1.1–1.9ms spread |
| Burst of 45 (5 mixer getters × 9 tracks) ×3 | 45/45 in one tick, 11.7–13.0ms spread |
| Burst of 63 (song scalars + 8 scene names + 45 track reads) | 63/63 in one tick, 14.2ms spread, **zero drops** |
| Same-address burst (`/live/track/get/name` × 9 tracks at once) | 9/9 in one tick, replies in send order, told apart by the echoed index |
| Bulk endpoints (`track_names`, `scenes/name`, `track_data`) | one tick each — **identical latency to a burst** |
| Single query at random phase ×10 | uniform 15–100ms — RTT is time-to-next-tick and nothing else |

Consequences, all of them load-bearing:

- **N serialized reads cost N ticks; the same N sent back-to-back cost one.**
  That is what `Seshat.OSC.Transport.query_batch/2` exists for, and what
  `get_clip_properties`, `get_track_sends` and the regular-track device reads
  use. Replies inside a tick arrive in datagram order; per-message processing is
  ~0.25ms.
- **A bulk endpoint buys no latency over a burst.** Adding aggregate addresses
  to the fork to collapse an N+1 read was evaluated on these numbers and not
  pursued — see `docs/archive/PLAN_batched_queries.md`. Reopen only for a read needing
  more than one burst's worth of datagrams, or an atomic multi-tick snapshot.
- **63 datagrams is where the evidence stops, not where the wire breaks.** Both
  socket directions carry 64KB buffers against ~40-byte requests and ~60-byte
  replies. `query_batch/2` caps a batch at 64 entries for that reason; measure
  before raising it.

---

## Application API

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/test` | | `'ok'` | Confirmation message in Live + OSC reply |
| `/live/application/get/version` | | `major_version, minor_version` | Live's version |
| `/live/application/get/average_process_usage` | | `average_process_usage` | Live's average CPU load. ⚠️ `application.py` also *sends* one argument-less datagram on this address every time AbletonOSC initialises — a stray sibling of `/live/startup`, not a reply to anything; ignore it |
| `/live/api/reload` | | | Live reload of AbletonOSC server code (dev only — see the warning below) |
| `/live/api/get/log_level` | | `log_level` | Current log level (default: `info`) |
| `/live/api/set/log_level` | `log_level` | | Set log level: `debug`, `info`, `warning`, `error`, `critical` |
| `/live/api/show_message` | `message` | | Show message in Live's status bar |

⚠️ **Don't reach for `/live/api/reload`.** Two problems, both observed:

1. It reloads modules, not files on disk that Live never imported. Editing the
   Python in `priv/AbletonOSC` does nothing until `mix abletonosc.install`
   copies it across, and a reload won't pick up a *new* module either — that
   needs Live restarted, or AbletonOSC toggled off and back on under
   Preferences > Link/Tempo/MIDI > Control Surface.
2. It can take the whole API down. `clear_handlers()` runs first, then
   `clear_api()` raises `KeyError` on any listener registered against a track
   that no longer exists — leaving zero handlers registered and no way to
   re-register them over OSC, since `/live/api/reload` has unregistered itself
   too. Every address then answers "Unknown OSC address" until Live is
   restarted or the control surface is toggled.

### Status Messages (sent automatically)

| Address | Response Params | Description |
|---|---|---|
| `/live/startup` | | Sent when AbletonOSC starts |
| `/live/error` | `"request", address, error_msg, arg_count, *request_args` | A handler callback raised. Carries the request that produced it, and is sent **instead of** a reply — the request gets no other answer. Fork-only (see `SESHAT.md`); upstream sends only the shape below. |
| `/live/error` | `"log", error_msg` | An error with no originating OSC request — parse failures, wildcard-branch failures, a handler's own internal error logs. Never correlatable to a request. |

`arg_count` makes the variable tail explicit and keeps a zero-argument request
from needing a special case; `request_args` are the request's own arguments
echoed back with their wire types intact (so an OSC `f` is still 32-bit —
compare against a 32-bit round-trip of what was sent, never a 64-bit float).
`Seshat.OSC.Transport` is the only place that knows this payload: a `"request"`
error matching the in-flight query's address *and* every argument fails that
query immediately instead of letting it wait out its timeout.

Measured on the wire, Live 12.4.3, 2026-08-03 — `get_track_devices` on a track
index past the end of the set produced exactly one datagram, and no
`"log"`-tagged duplicate for the same failure:

```
/live/error ["request", "/live/track/get/devices/name", "Index out of range", 1, 99]
```

The whole rejection, client call to tool result, took 212ms against a 5,000ms
query timeout. The raising address is the one that actually raised, which is not
always the address the tool is named for: `get_clip_notes` on a bad index raises
at its `/live/clip_slot/get/has_clip` guard, never reaching
`/live/clip/get/notes`.

---

## Song API

Top-level Song object. Playback control, scene/track creation, cue points, global params (tempo, metronome).

### Song Methods

| Address | Query Params | Description |
|---|---|---|
| `/live/song/begin_undo_step` | | ⚠️ **Seshat fork addition** — open an explicit undo step. Everything changed before the matching `end` collapses into one entry in Live's undo history |
| `/live/song/end_undo_step` | | ⚠️ **Seshat fork addition** — close the open undo step. Harmless when none is open; `begin` does not refcount, so the first `end` closes |
| `/live/song/capture_and_insert_scene` | | Capture the currently playing clips into a new scene inserted below the selected one (Live's "Capture and Insert Scene" command) |
| `/live/song/capture_midi` | | Capture MIDI |
| `/live/song/continue_playing` | | Resume session playback |
| `/live/song/create_audio_track` | `index` | Create audio track at index (-1 = end) |
| `/live/song/create_midi_track` | `index` | Create MIDI track at index (-1 = end) |
| `/live/song/create_return_track` | | Create return track |
| `/live/song/create_scene` | `index` | Create scene at index (-1 = end) |
| `/live/song/cue_point/jump` | `cue_point` | Jump to cue point (by name or index) |
| `/live/song/cue_point/add_or_delete` | | Add/delete cue point at cursor |
| `/live/song/cue_point/set/name` | `cue_point` | Rename cue point by index |
| `/live/song/delete_scene` | `scene_index` | Delete scene |
| `/live/song/delete_return_track` | `return_index` | Delete return track — indexes `song.return_tracks`, a separate space from regular track indices |
| `/live/song/delete_track` | `track_index` | Delete track |
| `/live/song/duplicate_scene` | `scene_index` | Duplicate scene |
| `/live/song/duplicate_track` | `track_index` | Duplicate track |
| `/live/song/force_link_beat_time` | | Force Ableton Link to adopt Live's current beat time |
| `/live/song/jump_by` | `time` | Jump song position by beats |
| `/live/song/jump_to_next_cue` | | Jump to next cue marker |
| `/live/song/jump_to_prev_cue` | | Jump to previous cue marker |
| `/live/song/re_enable_automation` | | Re-enable automation that manual tweaks have overridden (Live's "Re-Enable Automation" button) |
| `/live/song/redo` | | Redo last undone operation |
| `/live/song/set_or_delete_cue` | | Toggle a cue point at the playhead — the same LOM method `/live/song/cue_point/add_or_delete` above calls; two addresses, one behaviour |
| `/live/song/start_playing` | | Start session playback |
| `/live/song/stop_playing` | | Stop session playback |
| `/live/song/stop_all_clips` | | Stop all clips |
| `/live/song/tap_tempo` | | Tap tempo |
| `/live/song/trigger_session_record` | | Trigger session record |
| `/live/song/undo` | | Undo last operation |

#### Song method extensions (Seshat — not in upstream AbletonOSC)

⚠️ `begin_undo_step` and `end_undo_step` do **not** exist in stock AbletonOSC.
They are two entries in the generic methods list of `abletonosc/song.py` in
Seshat's fork (`priv/AbletonOSC`), installed with `mix abletonosc.install`
(restart Live afterwards). Like every other row in this table they are
send-only: nothing replies, so a missing install is indistinguishable from
success on the wire — undo simply goes back to reverting whole conversations.

Left to itself Live groups script-driven mutations into undo steps by its own
activity-sensitive rules; `Song.begin_undo_step()` / `Song.end_undo_step()` are
what Ableton's own Push script uses to make the boundary explicit.
`Seshat.Tools.Handlers.call/2` wraps every tool dispatch in a pair, so one tool
call is exactly one undo step. Measured on Live 12.4.3 (2026-08-01): an empty
pair leaves the history untouched, an unmatched `end` is harmless, and `begin`
does not refcount.

**`can_undo` / `can_redo`, measured on Live 12.4.3 (2026-08-02, probe rig).**
`Seshat.Tools.Handlers`'s `history_guard/2` reads one of these before sending an
`undo` or `redo`, and `/live/song/undo` and `/live/song/redo` never reply — so
what these two properties actually do is the only thing that can turn "off the
end of the history" into an honest refusal rather than a fabricated success.

- **Both are plain `bool` attributes** — `type=bool`, `callable=False`, and
  neither raises. A reply is therefore always encodable; a `getattr` yielding
  something unencodable is not a failure mode here.
- **Not hardwired true.** In a set reading `can_undo=True can_redo=True`, one
  new edit (a `create_midi_track`) flipped `can_redo` to **False** — so the
  guard's refusal branch is reachable on real hardware.
- **They track availability independently and in both directions.** Undoing
  that edit flipped `can_redo` back to `True` while `can_undo` never moved. A
  `false` reading therefore means the stack is genuinely empty, not that the
  property is stuck.
- ⚠️ **`can_undo=False` at a genuinely empty history is still unmeasured** — it
  needs File → New Live Set, which no probe can reach without discarding the
  open set. Tracked as measurement tripwire 5 in
  [smoke_tests/auto/undo.md](smoke_tests/auto/undo.md) as *`can_undo=False` is reachable
  at an empty history*; fold the reading in here once made.

### Song Getters

Listen via `/live/song/start_listen/<property>`, stop via
`/live/song/stop_listen/<property>`, and receive responses on
`/live/song/get/<property>`.

| Address | Response Params | Description |
|---|---|---|
| `/live/song/get/arrangement_overdub` | `arrangement_overdub` | Arrangement overdub state |
| `/live/song/get/back_to_arranger` | `back_to_arranger` | "Back to arranger" lit state |
| `/live/song/get/can_redo` | `can_redo` | Redo available? Plain `bool` attribute — see the measured semantics below |
| `/live/song/get/can_undo` | `can_undo` | Undo available? Plain `bool` attribute — see the measured semantics below |
| `/live/song/get/clip_trigger_quantization` | `clip_trigger_quantization` | Clip trigger quantization level |
| `/live/song/get/current_song_time` | `current_song_time` | Current song time (beats) |
| `/live/song/get/groove_amount` | `groove_amount` | Groove Pool amount (0.0-1.3; 1.0 = the dial's 100%, 1.3 = its 130% maximum); scales how strongly each clip's *assigned* groove applies — no effect on clips without one |
| `/live/song/get/is_ableton_link_enabled` | `is_ableton_link_enabled` | Ableton Link on? (1=on, 0=off) |
| `/live/song/get/is_playing` | `is_playing` | Song playing? |
| `/live/song/get/loop` | `loop` | Looping? |
| `/live/song/get/loop_length` | `loop_length` | Loop length |
| `/live/song/get/loop_start` | `loop_start` | Loop start point |
| `/live/song/get/metronome` | `metronome_on` | Metronome on/off |
| `/live/song/get/midi_recording_quantization` | `midi_recording_quantization` | MIDI recording quantization |
| `/live/song/get/nudge_down` | `nudge_down` | Nudge down |
| `/live/song/get/nudge_up` | `nudge_up` | Nudge up |
| `/live/song/get/punch_in` | `punch_in` | Punch in |
| `/live/song/get/punch_out` | `punch_out` | Punch out |
| `/live/song/get/record_mode` | `record_mode` | Record mode |
| `/live/song/get/root_note` | `root_note` | Root note |
| `/live/song/get/scale_name` | `scale_name` | Scale name |
| `/live/song/get/session_record` | `session_record` | Session record enabled? |
| `/live/song/get/session_record_status` | `session_record_status` | Session record status |
| `/live/song/get/signature_denominator` | `denominator` | Time signature denominator |
| `/live/song/get/signature_numerator` | `numerator` | Time signature numerator |
| `/live/song/get/song_length` | `song_length` | Arrangement length (beats) |
| `/live/song/get/swing_amount` | `swing_amount` | Global swing amount (0.0-1.0); applied by MIDI record quantization and `/live/clip/quantize` |
| `/live/song/get/tempo` | `tempo_bpm` | Song tempo |

### Song Setters

| Address | Query Params | Description |
|---|---|---|
| `/live/song/set/arrangement_overdub` | `arrangement_overdub` | Set arrangement overdub (1=on, 0=off) |
| `/live/song/set/back_to_arranger` | `back_to_arranger` | Set back to arranger (1=on, 0=off) |
| `/live/song/set/clip_trigger_quantization` | `clip_trigger_quantization` | Set clip trigger quantization |
| `/live/song/set/current_song_time` | `current_song_time` | Set song time (beats) |
| `/live/song/set/groove_amount` | `groove_amount` | Set Groove Pool amount (0.0-1.3); 0 = assigned grooves off |
| `/live/song/set/is_ableton_link_enabled` | `is_ableton_link_enabled` | Enable/disable Ableton Link (1=on, 0=off) |
| `/live/song/set/loop` | `loop` | Set looping (1=on, 0=off) |
| `/live/song/set/loop_length` | `loop_length` | Set loop length |
| `/live/song/set/loop_start` | `loop_start` | Set loop start |
| `/live/song/set/metronome` | `metronome_on` | Set metronome (1=on, 0=off) |
| `/live/song/set/midi_recording_quantization` | `midi_recording_quantization` | Set MIDI recording quantization |
| `/live/song/set/nudge_down` | `nudge_down` | Set nudge down |
| `/live/song/set/nudge_up` | `nudge_up` | Set nudge up |
| `/live/song/set/punch_in` | `punch_in` | Set punch in |
| `/live/song/set/punch_out` | `punch_out` | Set punch out |
| `/live/song/set/record_mode` | `record_mode` | Set record mode |
| `/live/song/set/root_note` | `root_note` | Set the song's root note (int; pairs with the documented getter) |
| `/live/song/set/scale_name` | `scale_name` | Set the song's scale by name (string; pairs with the documented getter) |
| `/live/song/set/session_record` | `session_record` | Set session record (1=on, 0=off) |
| `/live/song/set/signature_denominator` | `signature_denominator` | Set time sig denominator |
| `/live/song/set/signature_numerator` | `signature_numerator` | Set time sig numerator |
| `/live/song/set/swing_amount` | `swing_amount` | Set global swing amount (0.0-1.0) |
| `/live/song/set/tempo` | `tempo_bpm` | Set tempo |

### Song: Track/Scene/Cue Queries

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/song/get/cue_points` | | `name, time, ...` | List cue points |
| `/live/song/get/num_scenes` | | `num_scenes` | Number of scenes |
| `/live/song/get/num_tracks` | | `num_tracks` | Number of regular tracks (excludes return and master tracks) |
| `/live/song/get/scenes/name` | `[index_min, index_max]` | `[names...]` | All scene names in one reply, in index order (optional half-open range — see below) |
| `/live/song/get/track_names` | `[index_min, index_max]` | `[names...]` | Regular track names, in index order (optional range) |
| `/live/song/get/track_data` | `start_track, end_track, properties...` | `[values...]` | Bulk track/clip data query (regular tracks only) |

The three track queries iterate `song.tracks`, so return tracks and the master
track are absent from their counts and their index space. Return-track count
and names come from `/live/return_track/get/count` and
`/live/return_track/get/name` — see the Return Track & Master API below.

`/live/song/get/scenes/name` differs from `track_names` in three ways worth
knowing before relying on it: the range is half-open (`[min, max)`, so
`0 num_scenes` reads everything), `-1` is **not** accepted as "to the end"
(`track_names` special-cases it; here `range(min, -1)` is simply empty, so the
reply is an empty list that looks exactly like a set with no scenes), and the
reply carries **names only — the range is not echoed back**, so on a transport
that correlates by address alone a straggler from an earlier ranged query is
indistinguishable from the current reply by content.

#### Bulk Track Data

`/live/song/get/track_data` queries multiple tracks/clips at once. Properties use format `track.property_name`, `clip.property_name`, or `clip_slot.property_name`.

Example: `/live/song/get/track_data 0 12 track.name clip.name clip.length` queries tracks 0–11.

#### Legacy structure export — do not use

`/live/song/export/structure` (no arguments, replies `1`) dumps every track's
clips, devices and parameters to a JSON file. ⚠️ It predates the hardened
export pattern `/live/browser/export` uses and keeps everything that pattern
was built to remove: it writes to a **fixed, world-guessable path** in the
global temp directory (`abletonosc-song-structure.json`) with Live's
privileges, and on macOS it first blanks `TMPDIR` **for the whole Live
process** so that path is discoverable — redirecting every temp file Live
creates afterwards. Upstream code, kept only to avoid an unforced divergence;
Seshat never calls it. Read structure through the per-address queries or
`track_data` instead.

### Beat Events

Call `/live/song/start_listen/beat` to receive beat messages on `/live/song/get/beat` with the current beat number. Stop with `/live/song/stop_listen/beat`.

---

## View API

User interface control — selecting tracks, scenes, clips, devices.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/view/get/selected_scene` | | `scene_index` | Selected scene (0-indexed) |
| `/live/view/get/selected_track` | | `track_index` | Selected track (0-indexed) |
| `/live/view/get/selected_clip` | | `track_index, scene_index` | Selected clip |
| `/live/view/get/selected_device` | | `track_index, device_index` | Selected device (0-indexed) |
| `/live/view/set/selected_scene` | `scene_index` | | Set selected scene |
| `/live/view/set/selected_track` | `track_index` | | Set selected track |
| `/live/view/set/selected_clip` | `track_index, scene_index` | | Set selected clip |
| `/live/view/set/selected_device` | `track_index, device_index` | | Set selected device |
| `/live/view/start_listen/selected_scene` | | `selected_scene` | Listen for scene selection changes |
| `/live/view/start_listen/selected_track` | | `selected_track` | Listen for track selection changes |
| `/live/view/stop_listen/selected_scene` | | | Stop listening for scene changes |
| `/live/view/stop_listen/selected_track` | | | Stop listening for track changes |
| `/live/view/show_view` | `view_name` | | ⚠️ **Seshat extension** — bring a pane into view |
| `/live/view/hide_view` | `view_name` | | ⚠️ **Seshat extension** — put a pane away |
| `/live/view/get/is_view_visible` | `view_name` | `view_name, "ok", visible` or `view_name, "error", message` | ⚠️ **Seshat extension** — is a pane visible? `visible` is 1 or 0 |
| `/live/view/set/detail_clip` | `track_index, scene_index` | | ⚠️ **Seshat extension** — put a clip in the Detail view |

- `/live/view/set/selected_track` resolves its index through `song.tracks`, so
  it reaches **regular tracks only** — a return track cannot be selected on it at
  any index. Use `/live/return_track/select` (Seshat extension, see the Return
  Track & Master API below).

### View extensions (Seshat — not in upstream AbletonOSC)

⚠️ Four rows above do **not** exist in stock AbletonOSC: `show_view`,
`hide_view`, `get/is_view_visible` and `set/detail_clip`. They are served by
`abletonosc/view.py` in Seshat's fork (`priv/AbletonOSC`), installed with
`mix abletonosc.install` (restart Live afterwards). They are not the only Seshat
addresses living in an *upstream* file — `/live/song/begin_undo_step` and
`/live/song/end_undo_step` are two more, in `song.py` (see Song Methods above).
Without that install all four here are unknown: the three setters silently do
nothing, and the getter never replies.

Upstream can *select* a track, scene, clip or device, but it cannot show the
pane those live in, put one away, or say which panes are open at all:
`Application.View.show_view`, `.hide_view`, `.is_view_visible` and
`song.view.detail_clip` have no upstream address. Seshat's view steering needs
the first — selecting a clip nobody can see is not confirmation that anything
happened — and its view tools need the rest.

- `show_view` takes one of Live's own pane names: `Browser`, `Arranger`,
  `Session`, `Detail`, `Detail/Clip`, `Detail/DeviceChain`. `FollowCam` sends
  `Session`, `Detail/Clip` and `Detail/DeviceChain` after a mutation; the
  `show_view` tool exposes all six, so `Arranger`, `Browser` and bare `Detail`
  are also model-reachable for direct navigation and pre-action sequencing.
- `hide_view` takes the same six names — the Python passes the name through
  verbatim — but only two of them genuinely hide anything. Measured against
  Live 12 Suite, 2026-07-31, reading all six flags back after every send:

  | Sent | What actually happens |
  |---|---|
  | `Browser` | browser closes — a true hide |
  | `Detail` | detail panel closes, and its active tab flag goes false with it — a true hide |
  | `Session` | Arranger becomes visible instead — a main-view swap, not a hide |
  | `Arranger` | Session becomes visible instead — a main-view swap, not a hide |
  | `Detail/Clip` | detail panel stays open, flips to `Detail/DeviceChain` |
  | `Detail/DeviceChain` | detail panel stays open, flips to `Detail/Clip` |

  Seshat's `hide_view` **tool** therefore offers only `Browser` and `Detail`:
  the address is silent, so a name that merely swaps or does nothing would be
  an undetectable no-op. Switching between Session and Arrangement is
  `show_view`'s job, and closing the detail panel is bare `Detail`.
- `get/is_view_visible` takes any of the six and answers for all of them,
  including the sub-views. `Detail/Clip` and `Detail/DeviceChain` mean "the
  detail panel is open **and** that tab is active": exactly one of them reads 1
  while `Detail` reads 1, and both read 0 when the panel is hidden.
  `Session` and `Arranger` measured strictly complementary — never both 1, never
  both 0 — so the main view can be derived from the pair, and
  `focused_document_view` is not needed.
- `set/detail_clip` puts `song.tracks[track_index].clip_slots[scene_index]`'s
  clip into the Detail view. Pair it with `show_view Detail/Clip` to open the
  note editor on it.
- **The three setters are silent**, like upstream's setters — an unknown view
  name or an empty clip slot is logged to Live's `Log.txt` and nothing goes on
  the wire. `show_view` and `set/detail_clip` are view steering that follows an
  already-successful tool, and steering must never fail or delay the thing it
  follows, so the ok/error envelope the fork's *getters* use deliberately does
  not apply. `hide_view` is silent for consistency with them, and is verified
  instead from the Elixir side by reading `get/is_view_visible` back.
- **`get/is_view_visible` always replies**, in that envelope, echoing the name
  it was asked about, because a caller waits on it: silence must mean only
  "the fork isn't installed". An unrecognised name is a fast `"error"` reply
  ("The specified View Identifier does not exist" — Live raises here, unlike
  `show_view`, which ignores one), never a guard timeout. The boolean is an int
  on the wire, 1 or 0, like every other AbletonOSC boolean.
- **Read-after-write ordering holds.** A `hide_view` immediately followed by a
  read reflects the hide: AbletonOSC processes datagrams sequentially on Live's
  timer thread, and roughly thirty send-then-read-six cycles in the 2026-07-31
  measurement produced zero stale reads. No sleep is needed between them.

---

## Track API

**Regular (audio/MIDI) tracks only.** Every handler here resolves its index
through `song.tracks`, which holds audio and MIDI tracks and nothing else — a
return track or the master track cannot be reached on any `/live/track/*`
address, at any index. Return tracks and the master are addressable through
Seshat's return_track extension (see below); sends, being a property of a
*regular* track's mixer, live here.

Volume, panning, send, mute, solo, devices, clips.

Listen via `/live/track/start_listen/<property> <track_index>`, stop via
`/live/track/stop_listen/<property> <track_index>`, and receive responses on
`/live/track/get/<property>` with `<track_index> <value>`. `*` in place of the
index subscribes every track.

⚠️ Listener pairs exist for the **scalar** properties only (the property loops
in `track.py`, plus `volume` and `panning`). The composite getters — `send`,
the routing properties, `clips/*`, `arrangement_clips/*`, `devices/*`,
`num_devices` — register no listeners: `/live/track/start_listen/send` is an
unknown address and fails silently, which also means **nothing pushes a
send's accepted value into the mirror** after `/live/track/set/send`.
Reading the value back is therefore the only way to observe that a send
landed, which is what `set_track_send` does.

**Measured against Live 12.4.3 on 2026-08-04** (`smoke_tests/auto/sends.md`),
for that read-back:

- **A `/live/track/get/send` issued immediately after `/live/track/set/send`
  returns the new value.** Five consecutive set-then-get pairs at
  in-process spacing (microseconds apart, well inside one AbletonOSC tick)
  all reported the value just written — AbletonOSC processes the two
  datagrams in arrival order at that spacing, never the stale value.
- **Live applies no quantization to a send value.** `0.0`, `0.37` and `1.0`
  each round-tripped to themselves; the only distortion is the OSC wire's
  32-bit float (`0.37` returns as `0.3700000047683716`), so a comparison
  rounded to 4 decimals matches exactly across the whole 0.0–1.0 range.
- **A send index Live doesn't have raises on the *getter*.** `send_id` 9
  against a one-return set raises `IndexError: Index out of range` on
  `/live/track/get/send`, arriving via the structured `/live/error` in
  ~0.14s (measured end-to-end through an MCP HTTP call), not as a timeout.

> ⚠️ **These listeners are fixed in the fork**, in `AbletonOSCHandler._stop_listen`
> and `TrackHandler`'s mixer-listener pair. Same addresses, same arguments, same
> pushes — nothing calling them can tell the difference, which is exactly why the
> bug is worth writing down.
>
> A listener is keyed by track index but bound to a track *object*, and upstream
> unbinds it from whatever object the index resolves to at teardown time. Delete a
> track and every later index shifts, so re-subscribing tries to unbind the old
> callback from the wrong track: the removal fails, the base class swallows it as
> "likely benign", and the old listener stays alive pushing under an index that
> now belongs to someone else. A rename afterwards writes one track's name onto
> another in `Seshat.Session.State`. The fork unbinds from the object the callback
> was actually registered on, which `_start_listen` already records in
> `listener_objects`.
>
> The mixer listeners (volume, panning) had a second bug: they never recorded
> anything in `listener_objects` at all, so `_clear_listeners` raised `KeyError`
> on script reload once either was active. They now key as
> `("value", (track_id, prop))` with the `DeviceParameter` stored, and stop
> through the fixed base class.
>
> Seshat used to fix this from outside, by re-registering the five affected
> addresses from a `track_listeners.py` that had to be instantiated after
> `TrackHandler`. That file no longer exists.

### Track Methods

| Address | Query Params | Description |
|---|---|---|
| `/live/track/delete_clip` | `track_id, clip_index` | Delete the clip in slot `clip_index`. No reply — same address family as `/live/clip_slot/delete_clip`, which Seshat uses instead |
| `/live/track/delete_device` | `track_id, device_id` | Delete a device from the track's chain. **No reply, ever** — `_call_method` returns nothing, and a bad index raises inside the callback, so success and failure look identical on the wire. Callers must verify by re-reading `/live/track/get/num_devices` |
| `/live/track/stop_all_clips` | `track_id` | Stop all clips on track |

### Track Getters

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/track/get/arm` | `track_id` | `track_id, armed` | Track armed? |
| `/live/track/get/available_input_routing_channels` | `track_id` | `track_id, channel, ...` | List input channels |
| `/live/track/get/available_input_routing_types` | `track_id` | `track_id, type, ...` | List input routes |
| `/live/track/get/available_output_routing_channels` | `track_id` | `track_id, channel, ...` | List output channels |
| `/live/track/get/available_output_routing_types` | `track_id` | `track_id, type, ...` | List output routes |
| `/live/track/get/can_be_armed` | `track_id` | `track_id, can_be_armed` | Can track be armed? |
| `/live/track/get/color` | `track_id` | `track_id, color` | Track color |
| `/live/track/get/color_index` | `track_id` | `track_id, color_index` | Track color index |
| `/live/track/get/current_monitoring_state` | `track_id` | `track_id, state` | Monitoring state (1=on, 0=off) |
| `/live/track/get/fired_slot_index` | `track_id` | `track_id, index` | Currently-fired slot |
| `/live/track/get/fold_state` | `track_id` | `track_id, fold_state` | Group folded state |
| `/live/track/get/has_audio_input` | `track_id` | `track_id, has_audio_input` | Has audio input? |
| `/live/track/get/has_audio_output` | `track_id` | `track_id, has_audio_output` | Has audio output? |
| `/live/track/get/has_midi_input` | `track_id` | `track_id, has_midi_input` | Has MIDI input? |
| `/live/track/get/has_midi_output` | `track_id` | `track_id, has_midi_output` | Has MIDI output? |
| `/live/track/get/input_routing_channel` | `track_id` | `track_id, channel` | Current input routing channel |
| `/live/track/get/input_routing_type` | `track_id` | `track_id, type` | Current input routing type |
| `/live/track/get/output_routing_channel` | `track_id` | `track_id, channel` | Current output routing channel |
| `/live/track/get/output_meter_left` | `track_id` | `track_id, level` | Output level, left |
| `/live/track/get/output_meter_level` | `track_id` | `track_id, level` | Output level, both channels |
| `/live/track/get/output_meter_right` | `track_id` | `track_id, level` | Output level, right |
| `/live/track/get/output_routing_type` | `track_id` | `track_id, type` | Current output routing type |
| `/live/track/get/is_foldable` | `track_id` | `track_id, is_foldable` | Is a group? |
| `/live/track/get/is_grouped` | `track_id` | `track_id, is_grouped` | In a group? |
| `/live/track/get/is_visible` | `track_id` | `track_id, is_visible` | Visible? (1=on, 0=off) |
| `/live/track/get/mute` | `track_id` | `track_id, mute` | Muted? (1=on, 0=off) |
| `/live/track/get/name` | `track_id` | `track_id, name` | Track name |
| `/live/track/get/panning` | `track_id` | `track_id, panning` | Track panning (-1.0 to 1.0) |
| `/live/track/get/playing_slot_index` | `track_id` | `track_id, index` | Currently-playing slot |
| `/live/track/get/send` | `track_id, send_id` | `track_id, send_id, value` | Send level (0.0 to 1.0) |
| `/live/track/get/solo` | `track_id` | `track_id, solo` | Soloed? |
| `/live/track/get/volume` | `track_id` | `track_id, volume` | Track volume (0.0 to 1.0) |

### Track Setters

| Address | Query Params | Description |
|---|---|---|
| `/live/track/set/arm` | `track_id, armed` | Set arm (1=on, 0=off) |
| `/live/track/set/color` | `track_id, color` | Set color |
| `/live/track/set/color_index` | `track_id, color_index` | Set color index |
| `/live/track/set/current_monitoring_state` | `track_id, state` | Set monitoring |
| `/live/track/set/fold_state` | `track_id, fold_state` | Set group fold (1=on, 0=off) |
| `/live/track/set/input_routing_channel` | `track_id, channel` | Set input routing channel |
| `/live/track/set/input_routing_type` | `track_id, type` | Set input routing type |
| `/live/track/set/mute` | `track_id, mute` | Set mute (1=on, 0=off) |
| `/live/track/set/name` | `track_id, name` | Set track name |
| `/live/track/set/output_routing_channel` | `track_id, channel` | Set output routing channel |
| `/live/track/set/output_routing_type` | `track_id, type` | Set output routing type |
| `/live/track/set/panning` | `track_id, panning` | Set panning (-1.0 to 1.0) |
| `/live/track/set/send` | `track_id, send_id, value` | Set send level |
| `/live/track/set/solo` | `track_id, solo` | Set solo (1=on, 0=off) |
| `/live/track/set/volume` | `track_id, volume` | Set volume (0.0 to 1.0) |

### Track: Clip Queries

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/track/get/clips/name` | `track_id` | `track_id, [name, ...]` | All clip names |
| `/live/track/get/clips/length` | `track_id` | `track_id, [length, ...]` | All clip lengths |
| `/live/track/get/clips/color` | `track_id` | `track_id, [color, ...]` | All clip colors |
| `/live/track/get/arrangement_clips/name` | `track_id` | `track_id, [name, ...]` | Arrangement clip names |
| `/live/track/get/arrangement_clips/length` | `track_id` | `track_id, [length, ...]` | Arrangement clip lengths |
| `/live/track/get/arrangement_clips/start_time` | `track_id` | `track_id, [start_time, ...]` | Arrangement clip start times |

### Track: Device Queries

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/track/get/num_devices` | `track_id` | `track_id, num_devices` | Number of devices |
| `/live/track/get/devices/name` | `track_id` | `track_id, [name, ...]` | All device names |
| `/live/track/get/devices/type` | `track_id` | `track_id, [type, ...]` | All device types |
| `/live/track/get/devices/class_name` | `track_id` | `track_id, [class, ...]` | All device class names |
| `/live/track/get/devices/can_have_chains` | `track_id` | `track_id, [can_have_chains, ...]` | Per device: is it a rack (can hold chains)? |

---

## Clip Slot API

Container for clips. Create, delete, and query clip existence.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/clip_slot/fire` | `track_index, clip_index, [record_length]` | | Fire clip slot — with `record_length` (beats), records for exactly that long (see note below) |
| `/live/clip_slot/stop` | `track_index, clip_index` | | Stop the slot's playing clip |
| `/live/clip_slot/create_clip` | `track_index, clip_index, length` | | Create clip in slot |
| `/live/clip_slot/delete_clip` | `track_index, clip_index` | | Delete clip |
| `/live/clip_slot/get/has_clip` | `track_index, clip_index` | `track_index, clip_index, has_clip` | Has clip? |
| `/live/clip_slot/get/controls_other_clips` | `track_index, clip_index` | `track_index, clip_index, controls_other_clips` | Group slot controlling the clips below it? |
| `/live/clip_slot/get/is_group_slot` | `track_index, clip_index` | `track_index, clip_index, is_group_slot` | Slot belongs to a group track? |
| `/live/clip_slot/get/is_playing` | `track_index, clip_index` | `track_index, clip_index, is_playing` | Slot's clip playing? |
| `/live/clip_slot/get/is_triggered` | `track_index, clip_index` | `track_index, clip_index, is_triggered` | Fired and waiting on quantization? |
| `/live/clip_slot/get/playing_status` | `track_index, clip_index` | `track_index, clip_index, playing_status` | Slot playing status |
| `/live/clip_slot/get/will_record_on_start` | `track_index, clip_index` | `track_index, clip_index, will_record_on_start` | Firing this slot would record (armed track, empty slot)? |
| `/live/clip_slot/get/has_stop_button` | `track_index, clip_index` | `track_index, clip_index, has_stop_button` | Has stop button? |
| `/live/clip_slot/set/has_stop_button` | `track_index, clip_index, has_stop_button` | | Set stop button (1=on, 0=off) |
| `/live/clip_slot/duplicate_clip_to` | `track_index, clip_index, target_track, target_clip` | | Duplicate clip to target slot |

Every `get/` property above also has
`/live/clip_slot/start_listen/<property>` and
`/live/clip_slot/stop_listen/<property>`.

> ℹ️ **`fire` takes an optional `record_length`, and that is fixed-length
> recording.** The handler passes everything after the two indices straight
> into `ClipSlot.fire()`, whose first optional positional argument is
> `record_length` in beats (then `launch_quantization`, `force_legato`). Fire
> an empty slot on an armed track with a length and Live records exactly that
> long, stops itself, and leaves a clip of that length playing — loop brace
> and play markers already set. With no length it records until something
> stops it. Verified against Live 12.4.3, 2026-07-29; it is also how Live's
> own control surfaces implement fixed-length record. This is what `record_clip`
> and `stop_recording` are built on.

> ⚠️ **`duplicate_clip_to` is a merge hazard.** Upstream PRs #182 and #185 rename
> it to `duplicate_to` with no alias, and Seshat's `duplicate_clip` tool depends
> on the old name — so merging either into the fork breaks the tool silently
> (an unknown address over UDP just does nothing). Recorded in `SESHAT.md` at the
> fork root; the `audit-osc` workflow is what catches it.

---

## Clip API

Audio or MIDI clip. Start/stop, notes, name, gain, pitch, color, playing state/position.

Every `get/` property below also has
`/live/clip/start_listen/<property> <track_id> <clip_id>` and
`/live/clip/stop_listen/<property> <track_id> <clip_id>`; pushes arrive on the
matching `get/` address as `track_id, clip_id, value`. The `playing_position`
pair is listed explicitly only because it is the one Seshat uses.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/clip/fire` | `track_id, clip_id` | | Start clip |
| `/live/clip/stop` | `track_id, clip_id` | | Stop clip |
| `/live/clip/duplicate_loop` | `track_id, clip_id` | | Duplicate clip loop |
| `/live/clip/quantize` | `track_id, clip_id, grid, amount` | | **Seshat extension** (fork only). Quantize the clip's notes. `grid` is Live's `GridQuantization` enum — see below. `amount` is 0.0–1.0 (Live's UI shows it as a percentage). No reply, ever |
| `/live/clip/get/notes` | `track_id, clip_id, [start_pitch, pitch_span, start_time, time_span]` | `track_id, clip_id, pitch, start_time, duration, velocity, mute, ...` | Query notes (optional range) |
| `/live/clip/add/notes` | `track_id, clip_id, pitch, start_time, duration, velocity, mute, ...` | | Add MIDI notes |
| `/live/clip/remove/notes` | `[start_pitch, pitch_span, start_time, time_span]` | | Remove notes (no params = all) |
| `/live/clip/remove_notes_by_id` | `track_id, clip_id, note_id, ...` | | Remove notes by Live note id. ⚠️ Of limited use here: `get/notes` replies carry no ids, so nothing in this API yields an id to pass |
| `/live/clip/get/color` | `track_id, clip_id` | `track_id, clip_id, color` | Clip color |
| `/live/clip/set/color` | `track_id, clip_id, color` | | Set clip color |
| `/live/clip/get/color_index` | `track_id, clip_id` | `track_id, clip_id, color_index` | Color index (0-69) |
| `/live/clip/set/color_index` | `track_id, clip_id, color_index` | | Set color index (0-69) |
| `/live/clip/get/name` | `track_id, clip_id` | `track_id, clip_id, name` | Clip name |
| `/live/clip/set/name` | `track_id, clip_id, name` | | Set clip name |
| `/live/clip/get/gain` | `track_id, clip_id` | `track_id, clip_id, gain` | Clip gain |
| `/live/clip/set/gain` | `track_id, clip_id, gain` | | Set clip gain |
| `/live/clip/get/gain_display_string` | `track_id, clip_id` | `track_id, clip_id, gain_display_string` | Human-readable gain as dB string (audio clips only, read-only) |
| `/live/clip/get/length` | `track_id, clip_id` | `track_id, clip_id, length` | Clip length |
| `/live/clip/get/sample_length` | `track_id, clip_id` | `track_id, clip_id, sample_length` | Sample length |
| `/live/clip/get/start_time` | `track_id, clip_id` | `track_id, clip_id, start_time` | Start time |
| `/live/clip/get/end_time` | `track_id, clip_id` | `track_id, clip_id, end_time` | End time (beats) |
| `/live/clip/get/pitch_coarse` | `track_id, clip_id` | `track_id, clip_id, semitones` | Coarse pitch |
| `/live/clip/set/pitch_coarse` | `track_id, clip_id, semitones` | | Set coarse pitch |
| `/live/clip/get/pitch_fine` | `track_id, clip_id` | `track_id, clip_id, cents` | Fine pitch |
| `/live/clip/set/pitch_fine` | `track_id, clip_id, cents` | | Set fine pitch |
| `/live/clip/get/file_path` | `track_id, clip_id` | `track_id, clip_id, file_path` | Clip file path |
| `/live/clip/get/is_audio_clip` | `track_id, clip_id` | `track_id, clip_id, is_audio_clip` | Is audio clip? |
| `/live/clip/get/is_midi_clip` | `track_id, clip_id` | `track_id, clip_id, is_midi_clip` | Is MIDI clip? |
| `/live/clip/get/is_playing` | `track_id, clip_id` | `track_id, clip_id, is_playing` | Is playing? |
| `/live/clip/get/is_overdubbing` | `track_id, clip_id` | `track_id, clip_id, is_overdubbing` | Is overdubbing? |
| `/live/clip/get/is_recording` | `track_id, clip_id` | `track_id, clip_id, is_recording` | Is recording? |
| `/live/clip/get/is_triggered` | `track_id, clip_id` | `track_id, clip_id, is_triggered` | Fired and waiting on quantization? (clip-level twin of the clip_slot/scene property) |
| `/live/clip/get/will_record_on_start` | `track_id, clip_id` | `track_id, clip_id, will_record_on_start` | Will record on start? |
| `/live/clip/get/playing_position` | `track_id, clip_id` | `track_id, clip_id, playing_position` | Playing position |
| `/live/clip/start_listen/playing_position` | `track_id, clip_id` | | Listen for playing position |
| `/live/clip/stop_listen/playing_position` | `track_id, clip_id` | | Stop listening for position |
| `/live/clip/get/looping` | `track_id, clip_id` | `track_id, clip_id, looping` | Clip loop on/off (1=on, 0=off) |
| `/live/clip/set/looping` | `track_id, clip_id, looping` | | Set clip loop on/off (1=on, 0=off) |
| `/live/clip/get/loop_start` | `track_id, clip_id` | `track_id, clip_id, loop_start` | Loop start |
| `/live/clip/set/loop_start` | `track_id, clip_id, loop_start` | | Set loop start |
| `/live/clip/get/loop_end` | `track_id, clip_id` | `track_id, clip_id, loop_end` | Loop end |
| `/live/clip/set/loop_end` | `track_id, clip_id, loop_end` | | Set loop end |
| `/live/clip/get/warping` | `track_id, clip_id` | `track_id, clip_id, warping` | Warp mode |
| `/live/clip/set/warping` | `track_id, clip_id, warping` | | Set warp mode |
| `/live/clip/get/launch_mode` | `track_id, clip_id` | `track_id, clip_id, launch_mode` | Launch mode (0=Trigger, 1=Gate, 2=Toggle, 3=Repeat) |
| `/live/clip/set/launch_mode` | `track_id, clip_id, launch_mode` | | Set launch mode |
| `/live/clip/get/launch_quantization` | `track_id, clip_id` | `track_id, clip_id, launch_quantization` | Launch quantization (0=Global, 1=None, 2=8Bars, 3=4Bars, 4=2Bars, 5=1Bar, 6=1/2, 7=1/2T, 8=1/4, 9=1/4T, 10=1/8, 11=1/8T, 12=1/16, 13=1/16T, 14=1/32) |
| `/live/clip/set/launch_quantization` | `track_id, clip_id, launch_quantization` | | Set launch quantization |
| `/live/clip/get/ram_mode` | `track_id, clip_id` | `track_id, clip_id, ram_mode` | RAM mode (0=False, 1=True) |
| `/live/clip/set/ram_mode` | `track_id, clip_id, ram_mode` | | Set RAM mode |
| `/live/clip/get/warp_mode` | `track_id, clip_id` | `track_id, clip_id, warp_mode` | Warp mode (0=Beats, 1=Tones, 2=Texture, 3=Re-Pitch, 4=Complex, 6=Pro) |
| `/live/clip/set/warp_mode` | `track_id, clip_id, warp_mode` | | Set warp mode |
| `/live/clip/get/has_groove` | `track_id, clip_id` | `track_id, clip_id, has_groove` | Has groove? |
| `/live/clip/get/legato` | `track_id, clip_id` | `track_id, clip_id, legato` | Legato (0=False, 1=True) |
| `/live/clip/set/legato` | `track_id, clip_id, legato` | | Set legato |
| `/live/clip/get/position` | `track_id, clip_id` | `track_id, clip_id, position` | Position (LoopStart) |
| `/live/clip/set/position` | `track_id, clip_id, position` | | Set position |
| `/live/clip/get/muted` | `track_id, clip_id` | `track_id, clip_id, muted` | Muted? (0=False, 1=True) |
| `/live/clip/set/muted` | `track_id, clip_id, muted` | | Set muted |
| `/live/clip/get/velocity_amount` | `track_id, clip_id` | `track_id, clip_id, velocity_amount` | Velocity amount (0.0-1.0) |
| `/live/clip/set/velocity_amount` | `track_id, clip_id, velocity_amount` | | Set velocity amount |
| `/live/clip/get/start_marker` | `track_id, clip_id` | `track_id, clip_id, start_marker` | Start marker |
| `/live/clip/set/start_marker` | `track_id, clip_id, start_marker` | | Set start marker (beats) |
| `/live/clip/get/end_marker` | `track_id, clip_id` | `track_id, clip_id, end_marker` | End marker |
| `/live/clip/set/end_marker` | `track_id, clip_id, end_marker` | | Set end marker (beats) |

### `/live/clips/*` — experimental upstream pair, do not use

Two more addresses are registered in `clip.py` under the plural prefix
`/live/clips/`: `/live/clips/filter [note_name, ...]` mutes every session clip
whose notes fall outside the given set, and
`/live/clips/unfilter [track_start, track_end]` unmutes clips again (no
arguments = every track). They are upstream experiments, not
API: `filter` infers a clip's notes from a suffix in its **name** (regex
`[_-][A-G]...$`), builds a whole-set cache on first use that is **never
invalidated** — clips added, deleted or renamed later are judged by stale
data — and both silently rewrite `muted` across the entire set with no reply.
Documented so the addresses aren't mistaken for gaps; nothing in Seshat calls
them and nothing should.

### A fired slot's clip does not exist yet

Measured 2026-08-03, Live 12.4.3. `/live/clip_slot/fire` is processed in
datagram order like anything else, but the clip it creates lands
**asynchronously**. Polling immediately after the fire with launch quantization
set to None, `/live/clip_slot/get/has_clip` answered `False` on the first query
and `True` 99ms later — with `/live/clip/get/is_recording` already `True` by
that second read.

So datagram ordering does not buy you the engine state a fire *triggers*. Any
read-back that treats an immediate `has_clip: false` as "nothing was created"
will misreport a take that started fine; `Handlers.record_echo/3` re-reads once
for exactly this reason. A slot genuinely waiting for a boundary has no clip for
up to a full bar, so the two cases are still distinguishable — just not on one
read.

### `clip_trigger_quantization` is not the `launch_quantization` enum

Measured 2026-08-03, Live 12.4.3, and an easy way to silently change a global
setting while thinking you restored it. The **song** property
`/live/song/set/clip_trigger_quantization` is offset from the **clip** property
`launch_quantization` used by `set_clip_properties`, because the clip enum
starts with `0=Global` and the song enum has no such entry:

| Value | `clip_trigger_quantization` (song) | `launch_quantization` (clip) |
|---|---|---|
| 0 | None | Global |
| 1 | 8 bars | None |
| 4 | **1 bar** (`q_bar`, Live's default) | 2 bars |
| 5 | 1/2 (`q_half`) | **1 bar** |

Read it back with `/live/song/get/clip_trigger_quantization`, which answers with
a name (`q_bar`, `q_half`) rather than the integer — the only cheap way to be
sure which enum you just wrote into.

### The loop pair rejects an inversion, silently

Measured 2026-08-03, Live 12.4.3. `/live/clip/set/loop_start` with a value at or
past the current `loop_end` **does nothing** — Live does not clamp it to a legal
value, and nothing comes back on the wire. Live raises
`Cannot set LoopStart behind LoopEnd`, `AbletonOSCHandler` catches it and writes
`ERROR:abletonosc:… - Error setting clip.loop_start: …` to Live's `Log.txt`, and
the property keeps its old value. (`/live/clip/set/loop_end` is symmetric.)

That is why `set_clip_properties` validates the pair caller-side and orders the
two writes end-first when a brace moves entirely past its old position: without
both, moving a brace forward would silently half-apply.

Also measured the same day: **with `looping` off, `loop_start`/`loop_end` read
`0.0` and the clip length** — they do not track `start_marker`/`end_marker`. A
clip with markers at 0.0–2.0 and an 8-beat length reports a loop pair of
0.0–8.0. Reading the pair to decide anything while looping is off therefore
reads the clip extent, not the brace Live will restore when looping goes back on
(that brace survives independently — measured by toggling looping off and on
around a 2.0–6.0 brace, which came back as 2.0–6.0).

### Quantization grid

`/live/clip/quantize`'s `grid` argument is Live's `GridQuantization` enum, which
is **not** the `RecordingQuantization` enum used elsewhere in Live's API, and
**not** the `launch_quantization` enum `set_clip_properties` uses (where 1/16 is
`12`). Sending the wrong integer quantizes to the wrong grid, silently.

The table below was **measured against a running Live on 2026-07-31**, one clip
per enum value, five probe notes chosen so that every candidate grid produces a
distinct set of landing positions, `amount` 1.0, read back with
`/live/clip/get/notes`. Identical results in 4/4 and 6/8, so the mapping does
not depend on the time signature.

| Value | Grid | | Value | Grid |
|---|---|---|---|---|
| 0 | none (nothing moves) | | 5 | **1/16** (0.25 beat) |
| 1 | 1/4 (1.0 beat) | | 6 | 1/16 triplet (1/6 beat) |
| 2 | 1/8 (0.5 beat) | | 7 | 1/16 triplet (1/6 beat) |
| 3 | 1/8 triplet (1/3 beat) | | 8 | 1/32 (0.125 beat) |
| 4 | 1/8 triplet (1/3 beat) | | ≥9 | invalid — nothing happens |

Notes on the measurements, because they contradict what this file said until
2026-07-31 (previously: `1=8 bars … 5=1/2, 6=1/4, 7=1/8, 8=1/16, 9=1/32`, every
row of it wrong; the fork's `abletonosc/clip.py` carried the same wrong table
until its comment was corrected to the measured one):

- **Triplet grids exist** — 1/8T and 1/16T. The old claim that there are none,
  and that swing instead comes from the song's `swing_amount`, is wrong in its
  first half; the second half is still untested here, though the fork now
  exposes `/live/song/set/swing_amount` to test it with.
- **There are no bar-length grids, and no 1/2 grid.** Nothing in the valid
  range is coarser than a 1/4 note.
- **3 and 4 behave identically, as do 6 and 7.** Reproduced across separate
  runs and both meters. Reason unknown; prefer the lower value of each pair.
- **Values ≥ 9 do nothing at all.** No error, no reply, no movement — the
  callback raises inside AbletonOSC and the exception is logged and swallowed,
  which on the wire is indistinguishable from success.
- Only note *starts* move; durations are preserved, except that a move which
  lands two same-pitch notes on one point **merges** them (later velocity
  wins) and a move that creates a same-pitch overlap **trims** the earlier
  note. `amount` is linear: `new = old + amount × (target − old)`.

---

## Scene API

Trigger a row of clips simultaneously. Set/query name, color, tempo, time signature.

### Scene Methods

| Address | Query Params | Description |
|---|---|---|
| `/live/scene/fire` | `scene_id` | Trigger scene |
| `/live/scene/fire_as_selected` | `scene_id` | Trigger scene, select next |
| `/live/scene/fire_selected` | | Trigger selected scene, select next |

### Scene Getters

Listen via `/live/scene/start_listen/<property> <scene_index>`, stop via
`/live/scene/stop_listen/<property> <scene_index>`, and receive responses on
`/live/scene/get/<property>`.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/scene/get/color` | `scene_id` | `scene_id, color` | Scene color |
| `/live/scene/get/color_index` | `scene_id` | `scene_id, color_index` | Color index |
| `/live/scene/get/is_empty` | `scene_id` | `scene_id, is_empty` | Is empty? |
| `/live/scene/get/is_triggered` | `scene_id` | `scene_id, is_triggered` | Is triggered? |
| `/live/scene/get/name` | `scene_id` | `scene_id, name` | Scene name |
| `/live/scene/get/tempo` | `scene_id` | `scene_id, tempo` | Scene tempo |
| `/live/scene/get/tempo_enabled` | `scene_id` | `scene_id, tempo_enabled` | Tempo enabled? |
| `/live/scene/get/time_signature_numerator` | `scene_id` | `scene_id, numerator` | Time sig numerator |
| `/live/scene/get/time_signature_denominator` | `scene_id` | `scene_id, denominator` | Time sig denominator |
| `/live/scene/get/time_signature_enabled` | `scene_id` | `scene_id, enabled` | Time sig enabled? |

### Scene Setters

| Address | Query Params | Description |
|---|---|---|
| `/live/scene/set/name` | `scene_id, name` | Set name |
| `/live/scene/set/color` | `scene_id, color` | Set color |
| `/live/scene/set/color_index` | `scene_id, color_index` | Set color index |
| `/live/scene/set/tempo` | `scene_id, tempo` | Set tempo |
| `/live/scene/set/tempo_enabled` | `scene_id, tempo_enabled` | Set tempo enabled |
| `/live/scene/set/time_signature_numerator` | `scene_id, numerator` | Set time sig numerator |
| `/live/scene/set/time_signature_denominator` | `scene_id, denominator` | Set time sig denominator |
| `/live/scene/set/time_signature_enabled` | `scene_id, enabled` | Set time sig enabled |

---

## Device API

Instruments and effects. Query/set parameters.

Every `/live/device/*` address resolves its track through `song.tracks`
(`device.py`, `create_device_callback`) — **regular tracks only**. Devices on
return tracks and the master are unreachable through this API; they have their
own addresses under `/live/return_track/device/*` and `/live/master/device/*`
in the Return Track & Master API below, which is also where
`/live/track/delete_device`'s and `/live/view/set/selected_device`'s equivalents
live (both resolve through `song.tracks` too).

Parameter 0 of every device is its "Device On" switch — the power button in the
device's corner — so `/live/device/set/parameter/value <track> <device> 0 0.0`
bypasses a device and `1.0` re-enables it. ⚠️ The parameter's identity comes
from the Live Object Model, not from a smoke test; `bypass_device` reads
parameter 0's `value_string` and refuses unless it reads On/Off rather than
trusting it blind.

Every `get/` property in the table below (`name`, `type`, `class_name`) also
has `/live/device/start_listen/<property> <track_id> <device_id>` and
`/live/device/stop_listen/<property> <track_id> <device_id>` — but ⚠️ **these three pairs
are hobbled as registered** (verified against `device.py` at the current pin,
2026-08-03). The registration strips both indices before they reach
`_start_listen`, so the push arrives on the `get/` address carrying the
**bare value only** — no track or device echo — and the listener is keyed per
*property*, not per device, so subscribing a second device to the same
property silently replaces the first. One subscription per property at a
time, and a push cannot say which device it describes. Don't build on these
three until the fork registers them with `include_ids=True` (the flag
`parameter/value` below already uses correctly).

Listen for parameter changes via
`/live/device/start_listen/parameter/value <track_index> <device_index> <parameter_index>`,
and stop with `stop_listen/parameter/value` (same three arguments). Each change
pushes **two** datagrams: one on `/live/device/get/parameter/value` and one on
`/live/device/get/parameter/value_string`, both echoing all three indices.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/device/get/name` | `track_id, device_id` | `track_id, device_id, name` | Device name |
| `/live/device/get/class_name` | `track_id, device_id` | `track_id, device_id, class_name` | Device class name |
| `/live/device/get/type` | `track_id, device_id` | `track_id, device_id, type` | Device type (1=instrument, 2=audio_effect, 4=midi_effect) |
| `/live/device/get/num_parameters` | `track_id, device_id` | `track_id, device_id, num_parameters` | Number of parameters |
| `/live/device/get/parameters/name` | `track_id, device_id` | `track_id, device_id, [name, ...]` | Parameter names |
| `/live/device/get/parameters/value` | `track_id, device_id` | `track_id, device_id, [value, ...]` | Parameter values |
| `/live/device/get/parameters/min` | `track_id, device_id` | `track_id, device_id, [value, ...]` | Parameter min values |
| `/live/device/get/parameters/max` | `track_id, device_id` | `track_id, device_id, [value, ...]` | Parameter max values |
| `/live/device/get/parameters/is_quantized` | `track_id, device_id` | `track_id, device_id, [value, ...]` | Is quantized? (int/bool param) |
| `/live/device/set/parameters/value` | `track_id, device_id, value, ...` | | Set all parameter values |
| `/live/device/get/parameter/value` | `track_id, device_id, parameter_id` | `track_id, device_id, parameter_id, value` | Get single parameter |
| `/live/device/get/parameter/value_string` | `track_id, device_id, parameter_id` | `track_id, device_id, parameter_id, value` | Get parameter as string (e.g., "2500 Hz") |
| `/live/device/get/parameter/name` | `track_id, device_id, parameter_id` | `track_id, device_id, parameter_id, name` | Get single parameter's name |
| `/live/device/set/parameter/value` | `track_id, device_id, parameter_id, value` | | Set single parameter |

### Device Type Reference

- `name`: human-readable name
- `type`: 1 = instrument, 2 = audio_effect, 4 = midi_effect — measured against
  Live 12.4.3 on 2026-07-31 (an Operator reports 1, a Reverb and an EQ Eight
  report 2). The first two were documented the other way round until then; if
  another source disagrees, it is repeating the old guess.
- `class_name`: Live instrument/effect name (e.g., Operator, Reverb). External plugins: AuPluginDevice, PluginDevice. Racks: InstrumentGroupDevice, etc.

---

## Browser API (Seshat extension — not in upstream AbletonOSC)

⚠️ These seven addresses do **not** exist in stock AbletonOSC. They are served by
`abletonosc/browser.py` in Seshat's fork (`priv/AbletonOSC`), installed with
`mix abletonosc.install` (restart Live afterwards). Without that install all
seven addresses are unknown and queries time out.

Unlike the rest of AbletonOSC, these always reply — including on every error
path — so a query resolves instead of hanging.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/browser/get/items` | `category, filter, max_results` | `category, filter, 'ok', returned, total, [name, path, uri, ...]` | Search a browser category |
| `/live/browser/get/items` | | `category, filter, 'error', message` | Unknown category, or indexing failed |
| `/live/browser/load_item` | `track_id, uri` | `track_id, uri, 'ok', device_name, device_index` | Load a browser item onto a track |
| `/live/browser/load_item` | | `track_id, uri, 'error', message` | Bad track index, unknown uri, or load failed |
| `/live/browser/load_item_on_return` | `return_index, uri` | `return_index, uri, 'ok', return_name, device_name, device_index` | Load a browser item onto a return track's chain |
| `/live/browser/load_item_on_return` | | `return_index, uri, 'error', message` | Bad return index, unknown uri, load failed, or the load didn't land on the return |
| `/live/browser/load_item_on_master` | `uri` | `uri, 'ok', device_name, device_index` | Load a browser item onto the master track's chain |
| `/live/browser/load_item_on_master` | | `uri, 'error', message` | Missing/unknown uri, load failed, or the load didn't land on the master |
| `/live/browser/export` | | `export_path, 'ok', total_items` | Walk every category and write the whole index to a JSON file the handler names |
| `/live/browser/export` | | `'', 'error', message` | Arguments supplied, no category indexable, or the write failed |
| `/live/browser/preview_item` | `uri` | `uri, 'ok', name` | Audition a browser item without loading it — nothing in the set changes |
| `/live/browser/preview_item` | | `uri, 'error', message` | Missing or unknown uri, or the preview call failed |
| `/live/browser/stop_preview` | | `'ok'` | Stop the running preview |
| `/live/browser/stop_preview` | | `'error', message` | The stop call failed |

- `preview_item` plays through Live's **cue** bus, so audibility depends on the
  set's cue routing: with cue routed nowhere the preview is silent. That is a
  property of the user's set, not something the handler can detect, so a silent
  preview still replies `'ok'`. Whether a given preset carries a preview at all
  is Live's business too.
- `stop_preview` takes no argument and so has no bad-index failure to report,
  but it replies anyway — unlike the index-less getters below, nothing else
  confirms that the preview stopped.

- `category`: `instruments`, `sounds`, `drums`, `audio_effects`, `midi_effects`,
  `plugins`, `samples`, `user_library`
- `filter`: case-insensitive substring match on `"path/name"`, so it matches
  folder names too. `""` = no filter.
- `max_results`: clamped to 1–100 by the Python handler.
- `returned` is how many name/path/uri **triples** follow; `total` is how many
  matched before truncation.
- `path` is the `/`-joined chain of browser folder names above the item
  (`"Bass/808 & Sub"`), `""` for a top-level item.
- `export` takes **no arguments**. It chooses its own destination inside
  `~/.seshat/browser-exports` and returns the absolute path it wrote; an error
  reply carries `''` in that slot, so it never names a partial file.
- `uri` values come from `get/items` or `export` and are stable within a Live
  session — never construct one.
- The first walk of a large category takes seconds (it runs on Live's UI
  thread, capped at 20,000 nodes / depth 6); the result is cached per category
  for the rest of the Live session. `export` is the exception: it always drops
  the cache and re-walks, so a reindex picks up Packs and presets added since
  the last walk.
- `load_item` selects the target track and loads in one operation, then reads
  the track's device list back so `device_name` reflects what actually landed.
- `device_index` is that device's position in `track.devices` — the index
  `/live/view/set/selected_device` and every `/live/device/*` address take — so
  the caller can act on what it just loaded without re-reading the chain. It is
  **`-1`** when the device isn't on the chain to be indexed: some VST/AU plugins
  instantiate asynchronously and aren't there yet when the reply is built.
  `load_item` does not always append at the end (an instrument lands *before*
  existing audio effects), so the index is found by diffing the chain against
  what it held immediately before the load — the device that's new — falling
  back to a name match, then the last device, when diffing doesn't resolve it.
- `load_item` is regular tracks only (`song.tracks`). Return tracks and the
  master are reached with `load_item_on_return` / `load_item_on_master`
  instead — separate addresses rather than a widened `load_item`, so the
  original keeps its exact reply shape and the arity itself says which index
  space was targeted. All three share one implementation: `browser.load_item`
  loads onto `song.view.selected_track`, which accepts a return or the master
  perfectly well.
- `load_item_on_return`'s reply carries the **return's name read back after the
  load**, not the one it had before: Live renames an empty return the moment its
  first device lands (`A-Return` → `A-Reverb`, measured 2026-07-31), so the
  post-load name is the only correct one to report.
- ⚠️ **A non-effect load on a return or the master does not fail — it creates a
  stray MIDI track.** Measured 2026-07-31 on both: `browser.load_item` with an
  instrument selected loads it onto a *new* track and leaves the target chain
  untouched. So both new endpoints verify the load twice — the set's track count
  must be unchanged, and the target's chain must have gained a device — and
  return `'error'` naming the stray track if not. The stray track is **not**
  deleted; the reply names it and leaves removing it to the caller.

### `/live/browser/export`

Backs `Seshat.Library.Catalog.reindex/1`. It walks every category except
`samples` and writes one JSON file, rather than replying over OSC — a full
index is far past what a UDP datagram (or `get/items`' 100-item cap) can carry,
and Python and Elixir share a filesystem.

**The request carries no path.** The handler creates a uniquely named file with
`tempfile.mkstemp` inside `~/.seshat/browser-exports` (created owner-only on
demand) and returns the absolute path in the reply's first slot; Elixir reads it,
then deletes it. The old `[dest_path]` form — which opened a caller-supplied path
with Live's privileges — is rejected with an error reply and an error-level log
line, and writes nothing. A request in the old form against a current install, or
a no-argument request against an install predating 2026-07-30, means
`mix abletonosc.install` and a Live restart are overdue; `reindex_library` says
so rather than reporting a browser failure.

Because only the handler knows an export's name, only the handler can clean up an
export whose reply never arrived (a query timeout, a lost datagram, a path Elixir
refused). It sweeps at startup and before each export, removing matching
**regular** direct children of the export root that are at least ten minutes old
— old enough that no in-flight caller, bounded by the 120s query timeout, can
still be reading one.

```json
{
  "sounds": [
    {"name": "808 Drifter.adg", "path": "Bass/808 & Sub", "uri": "query:Sounds#Bass:FileId_5200"}
  ],
  "instruments": [ ... ]
}
```

- Takes up to a minute on a large library, all of it on Live's UI thread — the
  UI will hitch. Query it with a generous timeout (Seshat uses 120s).
- A category that fails to index is logged and skipped; the export still
  succeeds with the rest. Only a total failure returns `'error'`.
- `samples` is excluded deliberately: it is by far the largest category and raw
  samples carry no useful tags. Reach them with `get/items`.
- The `FileId_<n>` in a preset uri is the primary key of Ableton's own browser
  database, which is where Seshat gets preset tags — see
  `Seshat.Library.AbletonDB`.

---

## Return Track & Master API (Seshat extension — not in upstream AbletonOSC)

⚠️ These fifty-one addresses do **not** exist in stock AbletonOSC. They are served
by `abletonosc/return_track.py` in Seshat's fork (`priv/AbletonOSC`), installed
with `mix abletonosc.install` (restart Live afterwards). Without that install all
fifty-one addresses are unknown and queries time out.

They exist because upstream reaches regular tracks only: every `/live/track/*`
handler resolves its index through `song.tracks`. Return tracks live in
`song.return_tracks` and the master in `song.master_track`, so upstream can
create and delete a return track but can neither name one nor touch its level,
and the master fader is unreachable entirely. `/live/view/set/selected_track`
indexes `song.tracks` too, which is why selecting a return needs an address of
ours as well — and so do `/live/device/*`, `/live/track/delete_device` and
`/live/view/set/selected_device`, which is why the whole device surface is
repeated here.

⚠️ **The master has no `mute`, `solo` or `arm` at all.** Reading one raises
`RuntimeError("Main track has no 'mute' property!")` rather than returning
something falsy (measured 2026-07-31, Live 12.4.3), so those addresses simply do
not exist here — and `hasattr` is not a safe feature test on a LOM object.
Return tracks have no `arm` either. Live 12 also calls the master track **Main**
in its UI and in those error strings; `song.master_track.name` is `'Main'`.

Return-track indices are 0-based **within `song.return_tracks`** — a separate
index space from regular tracks. Return N is the target of send N on every
regular track: return 0 = send A, return 1 = send B, and so on. The master
track needs no index at all.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/return_track/get/count` | | `count` | Number of return tracks. Also the "is the extension installed?" probe |
| `/live/return_track/get/name` | `return_index` | `return_index, "ok", name` | Return track name |
| | | `return_index, "error", message` | Index out of range |
| `/live/return_track/set/name` | `return_index, name` | | Rename a return track |
| `/live/return_track/get/volume` | `return_index` | `return_index, "ok", volume` | Return fader, 0.0 to 1.0 |
| | | `return_index, "error", message` | Index out of range |
| `/live/return_track/set/volume` | `return_index, volume` | | Set the return fader |
| `/live/return_track/get/panning` | `return_index` | `return_index, "ok", pan` | Return pan, -1.0 to 1.0 |
| | | `return_index, "error", message` | Index out of range |
| `/live/return_track/set/panning` | `return_index, pan` | | Set the return pan |
| `/live/return_track/get/mute` | `return_index` | `return_index, "ok", 0\|1` | Return muted? |
| | | `return_index, "error", message` | Index out of range |
| `/live/return_track/set/mute` | `return_index, 0\|1` | | Mute/unmute the return |
| `/live/return_track/get/solo` | `return_index` | `return_index, "ok", 0\|1` | Return soloed? |
| | | `return_index, "error", message` | Index out of range |
| `/live/return_track/set/solo` | `return_index, 0\|1` | | Solo/unsolo the return |
| `/live/return_track/select` | `return_index` | | Select a return track in Live's UI |
| `/live/master/get/volume` | | `volume` | Master fader, 0.0 to 1.0 |
| `/live/master/set/volume` | `volume` | | Set the master fader |
| `/live/master/get/panning` | | `pan` | Master pan, -1.0 to 1.0 |
| `/live/master/set/panning` | `pan` | | Set the master pan |
| `/live/master/get/cue_volume` | | `value` | Cue (preview/headphone) level, 0.0 to 1.0 |
| `/live/master/set/cue_volume` | `value` | | Set the cue level |
| `/live/master/select` | | | Select the master track in Live's UI |
| `/live/return_track/start_listen/name` | `return_index` | | Push `/live/return_track/get/name [return_index, name]` on every change |
| `/live/return_track/stop_listen/name` | `return_index` | | |
| `/live/return_track/start_listen/volume` | `return_index` | | Push `/live/return_track/get/volume [return_index, volume]` on every change |
| `/live/return_track/stop_listen/volume` | `return_index` | | |
| `/live/return_track/start_listen/panning` | `return_index` | | Push `/live/return_track/get/panning [return_index, pan]` on every change |
| `/live/return_track/stop_listen/panning` | `return_index` | | |
| `/live/return_track/start_listen/mute` | `return_index` | | Push `/live/return_track/get/mute [return_index, muted]` on every change |
| `/live/return_track/stop_listen/mute` | `return_index` | | |
| `/live/return_track/start_listen/solo` | `return_index` | | Push `/live/return_track/get/solo [return_index, soloed]` on every change |
| `/live/return_track/stop_listen/solo` | `return_index` | | |
| `/live/master/start_listen/volume` | | | Push `/live/master/get/volume [volume]` on every change |
| `/live/master/stop_listen/volume` | | | |
| `/live/master/start_listen/panning` | | | Push `/live/master/get/panning [pan]` on every change |
| `/live/master/stop_listen/panning` | | | |
| `/live/master/start_listen/cue_volume` | | | Push `/live/master/get/cue_volume [value]` on every change |
| `/live/master/stop_listen/cue_volume` | | | |

### Return Track & Master: Device Chains

Upstream's `/live/device/*`, `/live/track/delete_device` and
`/live/view/set/selected_device` all resolve through `song.tracks`, so the whole
device surface is repeated here — once indexed by return, once for the master.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/return_track/get/devices` | `return_index` | `return_index, "ok", count, [name, type, class_name] × count` | The return's whole device chain in one reply |
| | | `return_index, "error", message` | Index out of range |
| `/live/master/get/devices` | | `count, [name, type, class_name] × count` | The master's device chain (no index → no failure path) |
| `/live/return_track/device/get/name` | `return_index, device_index` | `return_index, device_index, "ok", name` | Device name |
| | | `return_index, device_index, "error", message` | Either index out of range |
| `/live/master/device/get/name` | `device_index` | `device_index, "ok", name` | Device name |
| | | `device_index, "error", message` | Index out of range |
| `/live/return_track/device/get/parameters` | `return_index, device_index` | `return_index, device_index, "ok", device_name, count, [name, value, min, max] × count` | Every parameter in one reply |
| | | `return_index, device_index, "error", message` | Either index out of range |
| `/live/master/device/get/parameters` | `device_index` | `device_index, "ok", device_name, count, [name, value, min, max] × count` | Every parameter in one reply |
| | | `device_index, "error", message` | Index out of range |
| `/live/return_track/device/get/parameter/value` | `return_index, device_index, parameter_index` | `return_index, device_index, parameter_index, "ok", value` | One parameter's numeric value |
| | | `return_index, device_index, parameter_index, "error", message` | Any index out of range |
| `/live/master/device/get/parameter/value` | `device_index, parameter_index` | `device_index, parameter_index, "ok", value` | One parameter's numeric value |
| | | `device_index, parameter_index, "error", message` | Either index out of range |
| `/live/return_track/device/get/parameter/value_string` | `return_index, device_index, parameter_index` | `return_index, device_index, parameter_index, "ok", string` | Live's display value ("2.5 kHz") |
| | | `return_index, device_index, parameter_index, "error", message` | Any index out of range |
| `/live/master/device/get/parameter/value_string` | `device_index, parameter_index` | `device_index, parameter_index, "ok", string` | Live's display value |
| | | `device_index, parameter_index, "error", message` | Either index out of range |
| `/live/return_track/device/set/parameter/value` | `return_index, device_index, parameter_index, value` | | Set one parameter (silent) |
| `/live/master/device/set/parameter/value` | `device_index, parameter_index, value` | | Set one parameter (silent) |
| `/live/return_track/delete_device` | `return_index, device_index` | `return_index, device_index, "ok", remaining` | Delete a device; `remaining` is the chain length re-read afterwards |
| | | `return_index, device_index, "error", message` | Either index out of range, or the delete raised |
| `/live/master/delete_device` | `device_index` | `device_index, "ok", remaining` | Delete a device from the master chain |
| | | `device_index, "error", message` | Index out of range, or the delete raised |
| `/live/return_track/select_device` | `return_index, device_index` | | Select a device on a return, in Live's UI |
| `/live/master/select_device` | `device_index` | | Select a device on the master, in Live's UI |

- **Getters always reply**, on the address they were called on, including on
  every error path — the same rule as the Browser API above, and the opposite of
  upstream's "raise inside the callback and send nothing". For an optional
  extension that silence is ambiguous: a bad index would be indistinguishable
  from an install that never happened, and would cost a full guard timeout to
  learn nothing either way. With the envelope, **an error reply means a bad
  index and silence means the extension isn't loaded.**
- **The index-less master getters reply with the bare value**, no envelope:
  `get/count`, `/live/master/get/volume`, `/live/master/get/panning`,
  `/live/master/get/cue_volume` and `/live/master/get/devices` take nothing to
  look up, so they have no failure to report.
- **`delete_device` is the one setter-shaped address that replies.** It is a
  *method* with a real failure path — the same class as `load_item` — and the
  alternative is sandwiching it between two count reads to learn whether it
  landed. Its `remaining` is the chain length re-read from Live afterwards, not
  a number computed from the request.
- **The two list getters combine what upstream splits.** `get/devices` carries
  `count` then `count` × `(name, type, class_name)`;
  `device/get/parameters` carries `device_name`, `count`, then `count` ×
  `(name, value, min, max)`. Upstream needs three and five separate round trips
  respectively, and on a protocol with no request ids, assembling parallel lists
  from separate replies risks describing two different devices. `count` comes
  first so the flat tail stays parseable — a tail that isn't a whole number of
  triples (or quadruples), or whose group count disagrees with `count`, is a
  shape error the caller must reject rather than truncate. A large device
  (Operator, ~130 parameters) makes a ~5–6 KB datagram; `Transport`'s receive
  buffer is 64 KB, and upstream's own list getters already ship multi-KB
  replies.
- **Setters are silent**, like upstream's. Every caller guards with the matching
  getter immediately beforehand, so a bad index has already been reported by the
  time a setter goes out, and nothing waits on one.
- `select`, `select_device` and `/live/master/select` are silent too, for a
  stronger reason: they are view steering that follows a tool which has already
  succeeded, and steering must never fail — or delay — the thing it follows. A
  bad index is logged in Live and nothing happens. `song.view.select_device`
  also opens `Detail/DeviceChain` on its own (measured 2026-07-31), so the
  follow cam needs no separate pane call after one.
- Volume is `mixer_device.volume.value` on Live's fader scale, the same property
  and scale as `/live/track/get|set/volume`. Panning is
  `mixer_device.panning.value`, -1.0 to 1.0, displayed by Live in its L/C/R form
  (`-1.0` → `50L`, `0.0` → `C`, `1.0` → `50R`) — not degrees or a percentage.
  Cue volume is `mixer_device.cue_volume.value`, 0.0 to 1.0, parameter name
  **`Preview Volume`**, and shares the *identical* dB curve with track volume
  (`0.0` → `-inf dB`, `0.5` → `-14.0 dB`, `0.85` → `0.0 dB`, `1.0` → `6.0 dB`).
  All three measured against Live 12.4.3, 2026-07-31.
- Mute and solo are plain `Track` properties, not DeviceParameters — so their
  listeners use the base class's `_start_listen` while the three mixer
  parameters need the hand-rolled one below. The getters report `0`/`1`; Live's
  own push carries a bool.
- Creating and deleting return tracks is upstream's job:
  `/live/song/create_return_track` (no arguments, appends after the existing
  returns) and `/live/song/delete_return_track [return_index]`. A newly created
  return's index is therefore the old `get/count` — query the count, create,
  then `set/name` at that index.
- Sends belong to the *regular* track that feeds the return, so they stay on
  `/live/track/get|set/send [track_id, send_id, ...]` in the Track API above.
- **The listeners push the bare value**, not the ok/error envelope — a push has
  no failure path to report, and the differing arity is what lets
  `Seshat.Session.State` accept a push and a query reply on the same address
  without confusing them. Like upstream's listeners, each sends once immediately
  on subscribe. `start_listen`/`stop_listen` reply with nothing at all on a bad
  index (they are guarded by `get/count` and nothing waits on them).
- A `get/*` address therefore carries both query replies and listener pushes.
  Live's own track listeners upstream already work this way, and a push landing
  on a pending query is harmless: it carries a current value.
- Return-track volume, pan and the master's cue level are listened to on
  `mixer_device.*`, which are `DeviceParameter`s with `add_value_listener`
  rather than Track properties — so those listeners are hand-rolled instead of
  using the base class's `_start_listen`, which would derive
  `/live/return_track/get/value`. Because the base class's bookkeeping key is
  `(prop, params)` and `prop` is forced to `"value"` for all of them, the
  property has to be discriminated in the *params* half:
  `(index, "volume")`, `(index, "panning")`, `("master", "cue_volume")` and so
  on. Without that, subscribing a return's pan would silently evict its volume
  listener. The tuple never reaches the wire.
- **Re-subscribing an index unbinds the object it used to mean.** These
  listeners are keyed by return index but bound to a return-track object, and
  deleting a return renumbers everything after it. Upstream's `_stop_listen`
  removes the callback from whatever target it is *handed*, so re-subscribing
  index 0 after a delete would try to unbind it from the wrong object, silently
  fail, and leave the old listener pushing under an index that now belongs to
  someone else. The fork's base class unbinds from the object the callback was
  actually registered on, which is what makes any index-keyed listener safe —
  see the note under the Track API above.

---

## Song Structure API (Seshat extension — not in upstream AbletonOSC)

⚠️ These four addresses do **not** exist in stock AbletonOSC. They are served by
`abletonosc/song_structure.py` in Seshat's fork (`priv/AbletonOSC`), installed
with `mix abletonosc.install` (restart Live afterwards).

Upstream's `SongHandler` registers `start_listen` only for the *scalar* Song
properties in its hardcoded list (tempo, root_note, is_playing, …). `tracks` and
`return_tracks` are lists of LOM objects, so they aren't in it — meaning nothing
upstream fires when a track is added, deleted, duplicated or reordered, and
`Seshat.Session.State`'s mirror drifts silently.

| Address | Query Params | Response Params | Description |
|---|---|---|---|
| `/live/song/start_listen/tracks` | | | Push `/live/song/get/tracks` on every change to the track list |
| `/live/song/stop_listen/tracks` | | | |
| `/live/song/start_listen/return_tracks` | | | Push `/live/song/get/return_tracks` on every change to the return list |
| `/live/song/stop_listen/return_tracks` | | | |

The two push addresses are **push-only** — sent by the listener callback, never
registered as handlers, so querying them gets silence:

| Push address | Args |
|---|---|
| `/live/song/get/tracks` | `name0, name1, …` (regular tracks, in order) |
| `/live/song/get/return_tracks` | `name0, name1, …` (return tracks, in send order) |

- **Names only, deliberately.** The push is a change *signal*; `Session.State`
  compares it against its mirror and re-reads everything only when it differs, so
  this handler never becomes a second source of truth for track state.
- Upstream registers no handler on either push address — its equivalent is
  `/live/song/get/track_names`, a different address. No collision.
- Neither address exists on stock AbletonOSC, so a Live without the install just
  drops the `start_listen` messages: no error, and the mirror falls back to
  refresh-only staleness.

### `/live/startup` is acted on

AbletonOSC sends `/live/startup` (see the Application API above) whenever its
control surface initialises — Live launching, a different set being loaded, or
AbletonOSC toggled off and on. `Seshat.Session.State` treats it as a refresh
trigger, because by that point every listener registered against the previous
song object is dead: without it the mirror would be stale *permanently*, not
just until the next change.

---

## MidiMap API

Assign MIDI CC to Live parameters. Note: channels are 0-indexed (MIDI channel 1 = index 0).

| Address | Query Params | Description |
|---|---|---|
| `/live/midimap/map_cc` | `track_id, device_id, param_id, channel, cc` | Map CC to parameter |

---

## Quick Reference: Common POC Commands

```
# Test connection
/live/test

# Get session info
/live/song/get/tempo
/live/song/get/num_tracks
/live/song/get/track_names

# Transport
/live/song/start_playing
/live/song/stop_playing
/live/song/set/tempo 120.0

# Track control (track_id is 0-indexed)
/live/track/set/panning 0 -1.0       # Pan track 0 hard left
/live/track/set/panning 0 0.0        # Pan track 0 center
/live/track/set/panning 0 1.0        # Pan track 0 hard right
/live/track/set/volume 0 0.85        # Set track 0 volume
/live/track/set/mute 0 1             # Mute track 0
/live/track/set/mute 0 0             # Unmute track 0
/live/track/set/solo 0 1             # Solo track 0
/live/track/set/solo 0 0             # Unsolo track 0

# Create/delete tracks
/live/song/create_midi_track -1      # New MIDI track at end
/live/song/create_audio_track -1     # New audio track at end
/live/song/delete_track 3            # Delete track 3
```
