# Plan: Consolidate the tool surface — 67 tools to 52, no capability lost

> **Archived 2026-08-28 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ (see the PR for the
> implementer's per-item report, the review's verdict and nits — two applied,
> two declined — and the assumptions carried through the run). The roadmap's
> "Consolidate the tool surface" entry and "Modify a note in place" (absorbed
> into `edit_notes`) are both removed; the wording-coverage follow-up the
> review raised is now roadmap "Pin the wording of `edit_notes`' partial-
> failure message"; the `priv/AbletonOSC/FORK_GAPS.md` note-modification row
> is a known carry-over, recorded on the PR rather than done here because the
> standalone fork clone was on an unmerged branch.

_Roadmap #1 · planned 2026-08-27 · options in
[evaluating/tool-surface-scaling.md](../evaluating/tool-surface-scaling.md)_

## Context

Seshat ships 67 tools — 62,784 bytes of schema, roughly 16k tokens, in every
request. The roadmap's ready items and the generation research would add
~30 more on the current one-thing-one-tool pattern. The ceiling that bites
first is not context but **selection accuracy**: the model mis-picks between
confusable names (`set_track_volume` / `set_return_track_volume` /
`set_master_volume` are three names for one idea), and that failure is
silent — it reads as a careless model, never as an architectural cost.

Two consolidation patterns already exist in `Definitions` and are argued in
the file itself: parameterise on `target` (`@device_target`, six device
tools instead of eighteen) and one-tool-many-optional-properties
(`set_clip_properties`, one tool instead of twelve). They stopped being
applied when the mixer tools were written. This plan applies them to every
same-verb-different-target neighbour in the file, replaces the
read/remove/rewrite chain with one `edit_notes`, strips 10 copies of a
developer-facing sentence out of model-facing text, and writes the rule that
keeps the count from creeping back — including the shape future AX work
follows, so the next LOM-gap command arrives as an enum value rather than a
tool name.

**Nothing on the wire changes.** Every address this plan sends is already
sent by the tool it replaces; no fork commit, no `mix abletonosc.install`, no
Live restart. It is a breaking change to the *tool contract*, which nothing
deployed depends on.

This is also the first enforcement point for the boundary the future build-out
depends on: **backend completeness is not tool-surface completeness.** The OSC
fork can close every LOM gap, AX can accumulate bounded native commands, and
generation can combine multiple providers without publishing one tool per
capability. The stable layers are a small set of producer intentions → domain
operations that own validation/sequencing/undo/verification → OSC, AX and
generation adapters. This PR writes that boundary into the standing decision
record, the project conventions and the add-tool workflow, and adds a hard
review-line tripwire plus real-handshake surface measurements so later work
cannot reduce it to advice that nobody checks.

Three things research changed about the roadmap entry as written:

1. **`set_loop` is not a clip fold.** The entry (and the options doc, now
   corrected) had it folding into `set_clip_properties`. It is the *song's*
   arrangement loop (`/live/song/set/loop`), a different object from the
   clip loop brace; both descriptions already spend a sentence keeping them
   apart. It stays. The count is therefore 67 → 52, not 51.
2. **`edit_notes` needs no fork change, but must normalise what it reads
   before it rewrites.** The LOM's in-place edit (`apply_note_modifications`)
   is keyed on `note_id`, which the fork's `/live/clip/get/notes` reply does
   not carry (FORK_GAPS.md, "Notes flatten to five fields"). So `edit_notes`
   composes read → remove window → re-add, inside one handler and one undo
   step. Measured 2026-08-27 (below): the round trip is lossless in the five
   wire fields and one `undo` reverts it as a unit — but the reply carries
   `mute` as a boolean and velocity as a float, and `Seshat.OSC.Message`
   has no type tag for booleans, so re-sending the reply's fields verbatim
   **crashes `Transport`** (reproduced). The handler converts before it
   sends.
3. **`set_mixer`'s `track` is optional, not "pass 0".** `@device_target`
   keeps `track` required with a "pass 0 for master" wart because the
   overwhelmingly common device case is a regular track. The mixer is
   different: the master and cue are ordinary targets ("turn the master
   down" is a daily request), and a required index on a target that has
   none would be the wart the model hits most. `track` is required by the
   handler when `target` is `track` or `return`, and ignored otherwise — the
   schema cannot express conditional requirement, so the handler reports
   the omission by name.

## OSC contract

Every address below is already in use by a tool this plan removes or
extends; none is new. Cited from [priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md).

### `set_mixer` — by target and property

| Target | Property | Address | Args | Reply |
|---|---|---|---|---|
| track | volume | `/live/track/set/volume` | `track_id, volume` | none |
| track | pan | `/live/track/set/panning` | `track_id, panning` | none |
| track | mute | `/live/track/set/mute` | `track_id, 0\|1` | none |
| track | solo | `/live/track/set/solo` | `track_id, 0\|1` | none |
| track | arm | `/live/track/set/arm` | `track_id, 0\|1` | none |
| track | name | `/live/track/set/name` | `track_id, name` | none |
| return | volume | `/live/return_track/get/volume` then `set/volume` | `return_index` → `return_index, "ok", volume`; `return_index, volume` | get replies, set silent |
| return | pan | `/live/return_track/get/panning` then `set/panning` | as above | as above |
| return | mute | `/live/return_track/get/mute` then `set/mute` | `return_index` → `return_index, "ok", 0\|1`; `return_index, 0\|1` | as above |
| return | solo | `/live/return_track/get/solo` then `set/solo` | as above | as above |
| return | name | `/live/return_track/get/name` then `set/name` | `return_index` → `return_index, "ok", name`; `return_index, name` | as above |
| master | volume | `/live/master/get/volume` then `set/volume` | `[]` → `volume`; `volume` | bare value, no echo |
| master | pan | `/live/master/get/panning` then `set/panning` | `[]` → `pan`; `pan` | bare value |
| cue | volume | `/live/master/get/cue_volume` then `set/cue_volume` | `[]` → `value`; `value` | bare value |

Properties a target lacks are refused in the reply before anything is sent:
returns have no `arm` (return_track.py:47); the master has no `mute`, `solo`,
`arm` or `name` setter (return_track.py:44, `Session.State` line 165); cue
has only `volume`. The regular-track setters stay fire-and-forget with no
"was" value, as today — their values are mirrored by push and
`get_session_state` is the read. The return/master/cue setters keep today's
guard-read-then-set (`query_echoed/4`, `master_volume/0`,
`master_bare_float/2`) and report the "was" value per property.

### `create_track` / `delete_track` with `return`

| Operation | Address | Request args | Reply |
|---|---|---|---|
| pre/post-create count | `/live/return_track/get/count` | none | `count` |
| create return | `/live/song/create_return_track` | none | none |
| name new return | `/live/return_track/set/name` | `return_index, name` | none |
| delete guard | `/live/return_track/get/name` | `return_index` | `return_index, "ok", name` or `return_index, "error", message` |
| delete return | `/live/song/delete_return_track` | `return_index` | none |
| post-delete count (follow-cam steering) | `/live/return_track/get/count` | none | `count` |

`create_track` continues to express the create sequence internally as
`Registry.execute(%Command{command: :create_return_track})`; that is an Elixir
implementation detail, not an OSC argument.

### `set_clip_properties` gains `name`

`/live/clip/set/name` `track_id, clip_id, name`; read back via
`/live/clip/get/name` → `track_id, clip_id, name`, which `@clip_common_reads`
already reads.

### `edit_notes`

| Step | Address | Args | Reply |
|---|---|---|---|
| guard | `/live/clip_slot/get/has_clip`, `/live/clip/get/is_midi_clip` | `track, slot` | echoed indices + value (existing `ensure_clip/2`, `ensure_midi_clip/2`) |
| read | `/live/clip/get/notes` | `track, slot [, start_pitch, pitch_span, start_time, time_span]` | `track, slot, (pitch, start, duration, velocity, mute)*` — echo is the two indices only |
| remove | `/live/clip/remove/notes` | same optional range shape | none |
| re-add | `/live/clip/add/notes` | `track, slot, (pitch, start, duration, velocity, mute)*` — **velocity as integer, mute as 0/1** | none |
| verify | `/live/clip/get/notes` | same window | as read |

**Measured 2026-08-27, Live 12.4.3**, on a scratch MIDI clip with off-grid
values (start 1.6667, duration 0.3333, velocities 37/100/127):

- Read → remove window (pitch 60, span 1, whole time) → re-add with velocity
  +10: the two matched notes came back with identical start/duration to the
  float32 value first read (`0.33330002427101135`, `1.666700005531311`) and
  velocity `110.0`/`47.0`; the two unmatched notes were byte-identical
  before and after. Count preserved.
- Bracketed in one `begin_undo_step`/`end_undo_step`, a single `undo`
  restored the pre-edit notes exactly.
- **Window semantics are by note start.** Removing window `t=2.0..3.0` on
  pitch 60 left the note starting at 1.6667 (which sounds until 3.4167)
  untouched. `edit_notes`'s match is "notes that *start* inside the window",
  and the description says so.
- The reply's `mute` is `false`/`true` and velocity is `100.0`;
  `Seshat.OSC.Message.type_tag/1` has no clause for booleans, so a verbatim
  re-send raised `FunctionClauseError` inside the `Transport` GenServer and
  took it down (restarted by its supervisor). The handler converts `mute`
  to `0|1` and rounds velocity to an integer before `add/notes`.

## Parts

### 1. `Definitions` — the new and extended schemas

File: [lib/seshat/tools/definitions.ex](../../lib/seshat/tools/definitions.ex).

**1a. Add `set_mixer`; remove the thirteen it replaces** — `set_track_volume`,
`set_track_pan`, `set_track_mute`, `set_track_solo`, `set_track_arm`,
`set_track_name`, `set_return_track_volume`, `set_return_track_pan`,
`set_return_track_mute`, `set_return_track_solo`, `set_master_volume`,
`set_master_pan`, `set_cue_volume`.

Draft:

```elixir
%{
  name: "set_mixer",
  description:
    "Set any of a track's mixer controls in one call — volume, pan, mute, solo, arm, " <>
      "name — on a regular track, a return track, the master, or the cue output. Send " <>
      "only the properties you are changing, at least one. target defaults to 'track'. " <>
      "Track and return indices are 0-based and separate spaces: 'track 1' = track 0; " <>
      "return 0 = send A's return (see get_session_state for both). track is required " <>
      "for target 'track' and 'return' and ignored for 'master' and 'cue'. " <>
      "Volume is Live's fader scale, NOT linear and NOT topping out at unity: " <>
      "0.0 = silence, 0.6 = about -10 dB ('quiet'), 0.85 = unity gain (0 dB, where a " <>
      "new track sits — prefer this for 'all the way up'), 1.0 = +6 dB of boost. The " <>
      "reply echoes the approximate dB. Pan: -1.0 hard left, 0.0 center, 1.0 hard " <>
      "right; the master pan tilts the whole mix and nearly always stays at 0. " <>
      "Each target has a subset: returns have no arm; the master has volume and pan " <>
      "only; cue has volume only (the browser-preview/headphone level, not what the " <>
      "audience hears) — a property the target lacks is refused by name and nothing " <>
      "else in the call is sent. Return, master and cue replies name the previous " <>
      "value. To change how much a track feeds a return, use set_track_send.",
  parameters: %{
    type: "object",
    properties: %{
      "target" => %{
        type: "string",
        enum: ["track", "return", "master", "cue"],
        description: "Which mixer strip. Defaults to 'track'."
      },
      "track" => %{
        type: "integer", minimum: 0,
        description: "0-indexed track (target 'track') or return track (target 'return'). Ignored for 'master' and 'cue'."
      },
      "volume" => %{type: "number", minimum: 0.0, maximum: 1.0,
        description: "Fader position. 0.0 = silence, 0.85 = unity (0 dB), 1.0 = +6 dB"},
      "pan" => %{type: "number", minimum: -1.0, maximum: 1.0,
        description: "-1.0 = hard left, 0.0 = center, 1.0 = hard right"},
      "mute" => %{type: "boolean", description: "true = muted"},
      "solo" => %{type: "boolean", description: "true = soloed"},
      "arm" => %{type: "boolean", description: "true = armed for recording (regular tracks only)"},
      "name" => %{type: "string", description: "New name (regular and return tracks only)"}
    },
    required: []
  }
}
```

`required: []` with `target` optional is the `@device_target` shape;
`definitions_test`'s "every index-shaped property declares minimum: 0" still
holds for `track`.

**1b. `create_track.track_type` gains `"return"`; `create_return_track` is
removed.** The description adds one sentence: *"'return' creates a return
track — shared-effect host that every track gains a send to (return N =
send letter N; Live caps a set at 12) — appended after the existing returns
and empty until load_device (target: 'return') fills it."*

**1c. `delete_track` gains `target: "track" | "return"` (default `track`);
`delete_return_track` is removed.** Description adds: *"target 'return'
deletes a return track by return index (0 = send A); the returns after it
shift down a place with their send letters — re-check get_session_state
before touching another send."*

**1d. `set_clip_properties` gains `"name"`** (`type: "string"`), one clause
in the description: *"name renames the clip."* `set_clip_name` is removed.
`write_midi_notes`'s `name` parameter description currently ends
"`set_clip_name` renames later" — change to `set_clip_properties`.

**1e. Add `edit_notes`; remove `remove_notes`.** Draft:

```elixir
%{
  name: "edit_notes",
  description:
    "Edit or delete the MIDI notes in a window of a clip, in place, as one undoable " <>
      "step — 'make the third note quieter', 'shift the bassline up an octave', 'delete " <>
      "the hats in bar 2'. The window is a pitch range (start_pitch + pitch_span) and a " <>
      "time range (start_time + time_span, in beats from the clip's start); a note is in " <>
      "the window if it STARTS inside it — a note that begins before the window and " <>
      "sounds into it is not touched. Omit the window to edit every note. Then give " <>
      "at least one change: transpose (semitones, may be negative), velocity (absolute " <>
      "1-127) or velocity_delta (added, clamped to 1-127), duration (absolute beats) or " <>
      "shift (beats added to each start, may be negative), or delete: true. Changes " <>
      "apply to every note in the window; to touch one note, make the window exactly " <>
      "its pitch and start. Results outside 0-127 or before beat 0 are refused before " <>
      "anything changes. Call get_clip_notes first to see what is there; the reply " <>
      "reports how many notes matched and reads the window back. Track and clip_slot are " <>
      "0-based; slot N sits in scene N. Live's per-note probability, velocity deviation " <>
      "and release velocity are reset to defaults on edited notes (the wire cannot carry " <>
      "them); unedited notes are untouched.",
  parameters: %{
    type: "object",
    properties: %{
      "track" => %{type: "integer", minimum: 0, description: "0-indexed track number"},
      "clip_slot" => %{type: "integer", minimum: 0, description: "0-indexed scene/clip slot (default 0)"},
      "start_pitch" => %{type: "integer", minimum: 0, maximum: 127, description: "Lowest pitch in the window (default 0)"},
      "pitch_span" => %{type: "integer", minimum: 1, maximum: 128, description: "Pitches spanned (default 128 = all)"},
      "start_time" => %{type: "number", minimum: 0.0, description: "Window start in beats (default 0.0)"},
      "time_span" => %{type: "number", minimum: 0.0, description: "Window length in beats (default: whole clip)"},
      "transpose" => %{type: "integer", minimum: -127, maximum: 127, description: "Semitones to add to each pitch"},
      "velocity" => %{type: "integer", minimum: 1, maximum: 127, description: "Set every matched note's velocity"},
      "velocity_delta" => %{type: "integer", minimum: -126, maximum: 126, description: "Add to each velocity, clamped 1-127"},
      "duration" => %{type: "number", minimum: 0.001, description: "Set every matched note's length, in beats"},
      "shift" => %{type: "number", description: "Beats to add to each start (negative = earlier)"},
      "delete" => %{type: "boolean", description: "true = remove the matched notes instead of editing them"}
    },
    required: ["track"]
  }
}
```

`get_clip_notes`'s description names the edit loop as "get_clip_notes →
decide changes → remove_notes (with a pitch/time range) → write_midi_notes";
rewrite to "get_clip_notes → edit_notes for changes to existing notes, or
write_midi_notes to add new ones" and change "the same range parameters
remove_notes takes" to `edit_notes`.

**1f. Description diet.** Delete every occurrence of `"Requires Seshat's
AbletonOSC extension (mix abletonosc.install)."` — 10 today; after 1a–1c the
only surviving occurrence is on `get_track_sends` (the other nine belong to
removed definitions).
It is addressed to a developer; the model cannot act on it, and an
uninstalled extension already surfaces through `@return_extension_hint` at
the moment it matters. `mix precommit`'s format pass reflows the strings.

Also remove the now-dangling cross-references: "Same fader scale as
set_track_volume" (was in three descriptions), "For a regular track's pan
use set_track_pan", and any `set_track_*` mention in `get_session_state`,
`record_clip` or `Instructions` (grep `set_track_` / `set_return_track_` /
`set_master_` / `set_cue_` / `set_clip_name` / `remove_notes` /
`create_return_track` / `delete_return_track` across `lib/`).

### 2. `Handlers` — dispatch

File: [lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex).

**2a. `do_call("set_mixer", params)`.** Shape:

1. `target = Map.get(params, "target", "track")`; `changes = Map.take(params,
   @mixer_properties)` with `@mixer_properties ~w(volume pan mute solo arm
   name)` in that fixed order (deterministic write list, as
   `@clip_scalar_properties`).
2. Refuse, with nothing sent: empty `changes` — note `Validation` **ignores
   keys the schema doesn't name** (`validation.ex`, "Params not named in the
   schema are ignored"), so `%{"track" => 0, "gain" => 0.5}` arrives here as
   an empty `changes`, and this refusal must list the six valid properties
   so the model learns which name it wanted; a property the target lacks
   (`@mixer_supported %{"track" => all six, "return" => ~w(volume pan mute
   solo name), "master" => ~w(volume pan), "cue" => ~w(volume)}`), naming
   every unsupported key in one sentence; `track` missing when target is
   `track`/`return`.
3. Per target, apply each change in order and collect one result line each:
   - `track`: the six existing bodies, fire-and-forget, reusing
     `volume_display/1` and `pan_display/1`. Lines read "volume 0.85
     (0.0 dB)", "muted", "renamed to 'Bass'".
   - `return`: the four existing guard-then-set bodies (`query_echoed/4`
     with `@return_extension_hint`) plus `name` via
     `/live/return_track/get/name` → `set/name`. Lines carry "— was …"
     and `return_track_label/1`.
   - `master`: `master_volume/0` / `master_bare_float/2` then set; `cue`:
     `master_bare_float("/live/master/get/cue_volume", …)` then set, with
     today's "browser-preview level, not the master output" sentence.
4. Reply: one header naming the strip ("Track 2 ('Bass'):", "Return 0
   ('Room Reverb'):", "Master (shown as Main in Live 12):", "Cue:") and the
   lines. Regular and return names are best-effort labels from
   `State.tracks/0` / `State.return_tracks/0` (the existing
   `return_track_label/1` pattern), with a requested `name` overriding the
   mirrored old name; unavailable or stale state falls back to the raw index.
   A guard failure mid-list stops there and reports which properties were
   already sent, in the `send_clip_writes/3` style.

No `FollowCam` (mixer tweaks and renames don't steer — settled in
`FollowCam`'s moduledoc) and no `State.refresh()` (every value has a
listener; the comment above today's return setters moves with them).
The thirteen old clauses are deleted.

**2b. `create_track` with `"return"`.** New clause head
`do_call("create_track", %{"track_type" => "return", "name" => name})` above
the existing `when type in ["midi", "audio"]` clause, whose body is today's
`create_return_track` body verbatim — including the reply's `load_device
(target: 'return', track: N)` steer and `FollowCam.steer("create_track",
%{return: index})`. The `create_return_track` clause is deleted.

**2c. `delete_track` with `target`.** `do_call("delete_track", %{"track" =>
index, "target" => "return"})` above the existing clause, body from today's
`delete_return_track` with `steer_after_delete("delete_track", %{return:
index}, "/live/return_track/get/count")`. The existing clause's head matches
`"target" => "track"` or absent — simplest is to normalise
`Map.get(params, "target", "track")` in one clause and branch.

**2d. `set_clip_properties` `name`.** Add `"name"` to
`@clip_scalar_properties`' tail so it rides the ordered write list (position
is irrelevant to Live — it pairs with nothing — put it last). Add
`clip_set_address("name")` → `/live/clip/set/name`. `clip_value_matches?/3`
already falls through to `sent == got` for non-numeric values, so the
read-back needs nothing; `format_clip_value/2` does **not** — its fallback is
`format_number/1` — so add a `("name", value)` clause rendering `'Verse A'`.
Widen `clip_property_writes/2`'s return typespec and its moduledoc's
"everything else to floats" claim to include string scalar values; once
`name` joins the write list, `[{String.t(), number()}]` is no longer true.
`set_clip_name`'s clause is deleted; its `FollowCam` steer is inherited from
`set_clip_properties`.

**2e. `do_call("edit_notes", params)`.**

1. Normalise the window and the changes (`Map.take(params, ~w(transpose
   velocity velocity_delta duration shift delete))`). If no range key is
   supplied, use `[0, 128, -8192.0, 16384.0]` internally so "every note"
   includes notes before beat 0 and pitch 127; if any range key is supplied,
   fill all four with the declared user-facing defaults (`0`, `128`, `0.0`,
   `9999.0`), matching `note_range_args/1`'s all-or-nothing convention.
   Refuse with nothing sent: no change given; `velocity` and
   `velocity_delta` both given; `delete` with any other change.
2. `ensure_clip/2`, `ensure_midi_clip/2` (both exist).
3. Read the window with `query_correlated("/live/clip/get/notes", [track,
   slot | window], echo: [track, slot])` and `parse_clip_notes/1` — the
   exact call `get_clip_notes` makes.
4. Zero matches → `{:ok, "No notes start inside that window … nothing was
   changed"}` (not an error: the model asked a question about an empty
   range).
5. Compute the rewritten notes in pure code (`Seshat.Tools.NoteEdit.apply/2`
   — a new small module beside `Seshat.Music.Pitch`, so the arithmetic is
   unit-tested without a sink): transpose/velocity/duration/shift applied;
   any pitch outside 0–127 or start below 0.0 after the edit refuses the
   whole call by name ("transposing +12 would push 3 notes above G9 …
   nothing was changed"); `velocity_delta` clamps to 1–127 and the reply
   says how many clamped.
6. `send_message("/live/clip/remove/notes", [track, slot | window])`, then —
   unless `delete` — `send_message("/live/clip/add/notes", [track, slot |
   flat])` with each note as `[pitch, start / 1.0, duration / 1.0,
   round(velocity), if(mute, do: 1, else: 0)]`. Both silent; both inside the
   one undo step `call/2` already wraps. Check both send results. A failed
   remove reports that nothing was changed; a failed add reports that the
   matching notes were removed but could not be restored and directs the model
   to `undo` immediately — it must not continue into a success-shaped reply.
7. Read the window back the same way; report `matched` and the change applied.
   After `delete`, confirm that the original match window is empty. After an
   edit, a shifted or transposed note may now sit outside the original window,
   so read the bounding rectangle covering the old window and edited notes,
   then compare the expected edited note tuples as a multiset within that
   reply. Do **not** compare the reply's total count to `matched`: unrelated
   notes inside that larger rectangle are valid and would create a false
   mismatch. Report any missing expected tuples and direct the model to
   `get_clip_notes`; extra unrelated tuples are not an error.
8. `FollowCam.steer("edit_notes", %{track: track, slot: slot})` — add
   `"edit_notes"` to the clip list in `FollowCam.calls/2` where
   `"remove_notes"` is today.

`remove_notes`'s clause is deleted.

**2f. `describe_error` / timeouts.** `edit_notes` gets the `catch :exit`
branch `get_clip_notes` has, worded for a write ("nothing was changed" is
true only before step 6 — after the sends, say "the notes were rewritten
but could not be read back").

### 3. `FollowCam`

File: [lib/seshat/tools/follow_cam.ex](../../lib/seshat/tools/follow_cam.ex).

- `"edit_notes"` joins the clip list; `"remove_notes"` leaves it.
- `calls("create_return_track", %{return: index})` becomes
  `calls("create_track", %{return: index})`; the two `delete_return_track`
  clauses become `calls("delete_track", %{return: …, remaining: …})`. The
  existing `calls("create_track", %{track: index})` and
  `calls("delete_track", %{track: …})` clauses are distinguished by the
  fact key, which is how the device clauses already tell chains apart.

### 4. `Command` / `Registry`

No change. `create_track` with `"return"` builds
`%Command{command: :create_return_track, name: name}` directly;
`Registry.execute/1`'s clause and `ensure_return_created/2` stay. The one
string to touch: `ensure_return_created/2`'s cap message says "with
delete_return_track first" → "with delete_track (target: 'return') first".

### 5. Tests

- `test/seshat/tools/definitions_test.exs`: count → **52**; the expected-
  names list swaps the fifteen removed names for `set_mixer` and
  `edit_notes`. Add: `set_mixer` and `delete_track` advertise their `target`
  enums and neither requires `target`; `create_track.track_type` enum is
  `["midi", "audio", "return"]`; no description contains
  `mix abletonosc.install`; no description names a removed tool. Add a
  separate `length(tools) <= 80` review-line assertion whose failure explains
  that changing the exact-count assertion is not approval to cross the ceiling;
  crossing it requires a plan with the surface measurements and selection case
  in `adding-a-tool.md`.
- `test/seshat/tools/handlers_test.exs`: the four `set_track_*` describes
  become one `set_mixer` describe (each property's datagram, in order;
  multi-property call sends one datagram per property; unsupported property
  refused with nothing sent; missing `track` refused; `master` ignores
  `track`; return/master/cue guard-then-set traces against
  `Seshat.Test.OSCSink` with "was" in the reply, one straggler-then-answered
  path). The normalisation and validation describes that use
  `set_track_pan`/`set_track_mute`/`set_track_volume` retarget to
  `set_mixer` (`%{track: 0, pan: -1.0}`), asserting the same datagrams.
  New: `create_track` `"return"` runs the return sequence and steers
  `/live/return_track/select`; `delete_track` `target: "return"` sends
  `/live/song/delete_return_track`; `set_clip_properties` `name` sends
  `/live/clip/set/name` and reads it back; `edit_notes` — the full trace
  (get, remove, add, get) with velocity as integer and mute as `0|1` in the
  `add` datagram, `delete` sends no `add`, zero matches sends nothing,
  out-of-range transpose refused with nothing sent, a failed add reports the
  partial removal honestly, and missing expected read-back tuples are worded.
- `handlers_test`: omitting the whole match window uses the negative-time,
  pitch-127-capable catch-all window; an edited note whose read-back rectangle
  also contains an unrelated note does not produce a false count mismatch.
- `handlers_test`: `set_mixer` with only an unknown key is refused naming
  the six valid properties, nothing sent.
- New `test/seshat/tools/note_edit_test.exs` for the pure arithmetic:
  transpose, absolute and delta velocity with clamping, duration, shift,
  the refusal conditions, mute preserved.
- `test/seshat/tools/follow_cam_test.exs`: the return clauses under their
  new tool names; `edit_notes` in the clip-tool list.
- `test/seshat/tools/validation_test.exs` and `test/seshat/mcp/tools_test.exs`,
  `server_test.exs`: every `set_track_pan` example becomes `set_mixer`
  with `pan`; the "return and master mixer setters" describe becomes
  `set_mixer` bounds per property. `tools_test`'s "every device tool
  advertises the same target enum" is unchanged (device enum is still
  `["return", "master"]`; `set_mixer`'s is its own).
- `test/seshat/commands/registry_test.exs:40` asserts on the string
  "delete_return_track" — update with Part 4.

### 6. Docs, skill, smoke tests

- [CLAUDE.md](../../CLAUDE.md) module map: a row for
  `lib/seshat/tools/note_edit.ex` — "Pure note-edit arithmetic behind
  `edit_notes` (transpose, velocity, duration, shift, delete, range
  refusals); no OSC" — beside the `follow_cam.ex` row.
- [CLAUDE.md](../../CLAUDE.md) design decisions: retain the explicit three-layer
  boundary — model-facing producer intentions → domain operations → OSC/AX/
  generation adapters — and the rule that bridge/provider completeness never
  publishes tools automatically. `Handlers` stays the sole name dispatcher;
  substantial algorithms and multi-backend workflows live in focused modules
  behind it. `Registry` stays limited to bounded `%Command{}` OSC sequences,
  not a generic workflow engine.
- [docs/evaluating/tool-surface-scaling.md](../evaluating/tool-surface-scaling.md):
  retain the standing architecture section added during planning. It records:
  the routing decision every newly closed fork gap takes; cohesion limits for
  property bags and action enums; the boundary between thin dispatch and domain
  modules; the extract-before-a-third-copy rule for conditional preflight; the
  provider-invisible generation contract; and count/bytes/largest-schema/
  near-neighbour/conditional-case/selection measurements for every surface
  change. Its recommended sequence makes a repeatable tool-selection prompt
  corpus a gate when generation moves from research onto the roadmap, before
  the first generative tool lands rather than as cleanup afterwards.
- [.claude/docs/adding-a-tool.md](../../.claude/docs/adding-a-tool.md): retain and
  enforce **"Before minting a name"** ahead of "The four steps":

  > A new tool name is justified only when the model must *choose* between
  > this and an existing tool — a different verb, or a different noun. The
  > same verb aimed elsewhere is a `target` value (`set_mixer`, the device
  > tools). The same noun's other property is an optional parameter
  > (`set_clip_properties`, `set_mixer`). A sequence the user thinks of as
  > one action is one tool whose handler composes the primitives
  > (`edit_notes`). **80 tools is the review line**: past it, a plan adding
  > a definition argues in writing why none of those shapes fit; past ~90,
  > the modal tool set in
  > [tool-surface-scaling.md](../../docs/evaluating/tool-surface-scaling.md)
  > is the next lever, not another name.
  >
  > **Accessibility-backed actions follow the same rule with two fixed
  > shapes.** A Live command with no LOM address (Stem Separation, Convert
  > Drums, Extract Groove) is an enum value on `run_live_command`; a Live
  > Settings value is an enum value on `live_setting` (`get`/`set`) — the
  > two audio-output tools fold into it the day a second setting arrives.
  > Each enum value is still one bounded case in `native/seshat_ax/main.m`
  > with its own safety case and an **independent read-back** (a count push
  > into `Session.State`, a re-read of the setting); a command with no
  > read-back does not enter the enum. The helper never gains a generic
  > press, dump or keystroke command. Per-command caveats (Suite gate,
  > duration, dialogs) go in the enum value's description.

  The operational version also says that closing `FORK_GAPS.md` is not a
  publication queue; defines the cohesion limit for a property bag/action
  enum; tells substantial logic and provider workflows to sit in focused
  modules behind `Handlers`; requires all conditional refusals before
  transport and a shared convention before a third bespoke support matrix;
  and requires the five surface measurements above. Keep the independent
  `<= 80` test documented as the review tripwire.

  Also update the `set_track_send` example if it references a removed
  neighbour, and the "~36KB of schemas" figure to "~60KB".
- [.claude/skills/add-tool/SKILL.md](../../.claude/skills/add-tool/SKILL.md):
  step 0 applies the naming/publication test before address research. It stops
  when the capability is a target, property, internal/read-back step, or part
  of an existing high-level action, and otherwise requires the surface
  measurements and selection check before minting a name.
- [README.md:98-99](../../README.md#L98): the return/master sentence names
  `create_return_track`, `delete_return_track`, `set_return_track_volume`,
  `set_master_volume` → `create_track`/`delete_track` with `target: 'return'`,
  `set_mixer`.
- [.claude/docs/command-flow.md:7](../../.claude/docs/command-flow.md#L7) and
  [.claude/skills/smoke-test/scripts/mcp_call.py:10-11](../../.claude/skills/smoke-test/scripts/mcp_call.py#L10):
  the `set_track_pan` example → `set_mixer {"track": 0, "pan": -1.0}`.
- The same `mcp_call.py` gains `stats`: after a real `tools/list` handshake,
  compact-JSON encode the advertised tool array (`ensure_ascii: false`, no
  whitespace) and print its count and byte size, plus the largest individual
  tool's name and byte size. This measures the client-visible contract rather
  than an Elixir-side approximation. Document it in
  `docs/smoke_tests/auto/mcp-surface.md § The surface budget is measured, not
  guessed`; record the post-consolidation result and compare it with the
  67-tool/62,784-byte planning baseline only if the compact encoding reproduces
  that baseline (otherwise record the new metric without pretending the two
  methods are comparable).
- [docs/evaluating/generative features/music-generation-user-stories.md](../evaluating/generative%20features/music-generation-user-stories.md):
  retain the product decision that tools name reversible producer actions, not
  providers or pipeline stages; a bake-off changes an adapter, not
  `Definitions`, and revision earns a separate name only when it proves a
  distinct workflow.
- Standing capability records
  [docs/evaluating/abletonosc-integration-review.md](../evaluating/abletonosc-integration-review.md)
  and
  [docs/evaluating/generative features/live-improv-exploration.md](../evaluating/generative%20features/live-improv-exploration.md):
  replace removed model-facing tool names with `set_mixer`, `edit_notes`,
  `create_track track_type: "return"`, and `set_clip_properties` as applicable.
  Do not rewrite OSC address names or archived plan history.
- [priv/AbletonOSC/FORK_GAPS.md](../../priv/AbletonOSC/FORK_GAPS.md): update the
  note-modification row's disposition "Roadmap **Modify a note in
  place**" → "`edit_notes` composes remove + add today; a widened reply
  with `note_id` would let it preserve probability/deviation/release
  velocity". Make and merge this documentation change in the standalone fork
  clone — never in `priv/AbletonOSC` — then bump the Seshat submodule pin to
  the merged `origin/master` commit. No install or Live restart is needed
  because no runtime file changed.
- Smoke tests: see Live verification.
- `docs/ROADMAP.md`: at `/ship`, remove #1 and "Modify a note in place"
  (absorbed). Not now.

## Testing

All pure, against `Seshat.Test.OSCSink`, nothing through
`Transport.query/3` to a real Live: the traces above, the definitions
tripwires (including the independent 80-tool ceiling), the `NoteEdit`
arithmetic. `mix precommit` green is the bar. The
MCP parity tests (`Seshat.MCP.ToolsTest`) regenerate from `Definitions` and
need only the example-name swaps.

## Live verification

Nothing in `mix test` reaches any of this. Run the automated half with
`/smoke-test`. No new Python: the bridge as installed is the bridge these
tests need. Written 2026-08-27 by `/smoke-write`; the rows it tripped were
send-only setters (regular-track `set_mixer`, `edit_notes`' remove/add, the
clip `name` write), model-facing text (two new descriptions, three rewritten
edit-loop sentences), and the advertised schema (`required: []` on a
mutating tool).

New, all with `Last run: —`:

- `smoke_tests/auto/mixer.md § One set_mixer call moves several controls` —
  the fan-out; one property missing from the mirror is a wrong branch.
  *2026-08-28: passed — volume 0.6 / pan −0.5 / mute in one call all in the mirror; one `undo` restored all three.*
- `smoke_tests/auto/mixer.md § A property the target lacks is refused with
  nothing sent` — the all-or-nothing pre-send check.
  *2026-08-28: passed — `arm` on a return and `mute` on the master each refused by name, return volume unchanged, zero `Setting property for return_track` lines in Log.txt.*
- `smoke_tests/auto/mixer.md § Master and cue ignore track, and read back
  their old value` — the optional-`track` decision, live.
  *2026-08-28: passed — `track: 7` on master raised nothing; both replies carried "was …".*
- `smoke_tests/auto/mixer.md § Boundaries and a bad return index` — 0.0/1.0
  and ±1.0, plus the vendored guard's immediate error.
  *2026-08-28: passed — +6 dB / 50R and −inf read back; return 99 refused in 0.37s naming "1 return track(s)".*
- `smoke_tests/auto/clips.md § edit_notes rewrites only the window` — the
  measured round trip, including the velocity-int / mute-0|1 conversion
  that a verbatim re-send gets wrong.
  *2026-08-28: passed — vel 110/47 with starts and durations unchanged to every digit, other notes identical, one `undo` restored the first read. Reply leaks the `9999.0` time sentinel (ROADMAP #19).*
- `smoke_tests/auto/clips.md § A window edit that would leave the range is
  refused` — refusal before the sends.
  *2026-08-28: passed after correcting the test — `transpose: 60` on G4 is exactly 127 and legal; `61` and `shift: -1.0` both refused before sending, clip untouched, `-12` read back as 55.*
- `smoke_tests/auto/clips.md § delete: true empties the window and nothing
  else` — match-by-start semantics.
  *2026-08-28: semantics passed — the 1.6667 note survived, one `undo` restored the fourth — but the reply said "in the whole clip" for a beats-2–3 window (ROADMAP #19).*
- `smoke_tests/auto/clips.md § Renaming rides set_clip_properties` — the
  string property through the numeric write/read-back path.
  *2026-08-28: passed — `name` and `looping` echoed in one reply, name on the right slot in `get_clip_slots`.*
- `smoke_tests/auto/mcp-surface.md § A mutating tool with nothing required
  survives the client` — list-level risk of `required: []`, and the two
  handler-side rejections arriving as tool results.
  *2026-08-28: passed — 52-tool list survived, `required: []` on the wire, `pan: -1.0` read back fresh from Live, both empty-call shapes answered as tool results by the Elixir validator, never `-32602`.*
- `smoke_tests/auto/mcp-surface.md § The surface budget is measured, not
  guessed` — the real advertised count/bytes and largest-schema cohesion
  check, rather than treating the count alone as success.
  *2026-08-28: measured — 52 tools / 58,709 bytes / `set_clip_properties` 3,585; not comparable to the 62,784 planning figure (different method), recorded as the new baseline.*
- `smoke_tests/manual/conversation.md § Mixer and note edits route to one
  call each` — the whole bet: does one name route better than thirteen.

Existing tests to **rename in place** during implementation (their tool
goes; their guarantee does not — keep the titles):

- `smoke_tests/manual/on-screen.md § The return and master mixer setters
  move the right control` and `§ The return and master mixer listeners
  push` — the setter list becomes `set_mixer` per target.
- `smoke_tests/auto/mirror.md § The scalar mixer setters no longer trigger
  a refresh` — same substitution; its baseline note and
  `smoke_tests/auto/sends.md`'s set-up, `smoke_tests/auto/undo.md § A
  multi-message tool is still one step`, and
  `smoke_tests/manual/on-screen.md § Loading onto a return, and onto the
  master` swap `create_return_track` for `create_track track_type:
  "return"`.
- `smoke_tests/manual/by-ear.md § Cue volume is audible` — `set_mixer
  target: "cue"`.
- `smoke_tests/auto/mcp-surface.md`'s three `set_track_pan` probes →
  `set_mixer` with `pan`.
- `smoke_tests/manual/conversation.md § Show-first sequencing` names
  `set_loop`, which stays — no change.

**Uncovered:** Live rejecting `arm` on a group track or a track with no
armable input (fire-and-forget on the regular-track path; only Log.txt
shows it — accepted, as it was for `set_track_arm`); the `set_mixer` `name`
branch on a return renaming the wrong return under a concurrent hand edit
(the index race every index-addressed setter has); whether a client other
than Claude Desktop tolerates `required: []` (one client on this machine).

## Out of scope

- **Track colour** (`/live/track/set/color_index`) as a `set_mixer`
  property. The options doc suggests it; it stays in roadmap #19's grab bag
  because it needs a read-back design (colour isn't mirrored) that this
  plan shouldn't grow.
- **Folding `get_audio_outputs`/`set_audio_output` into `live_setting`.**
  The shape is written into `adding-a-tool.md` by this plan; the fold
  happens when a second setting arrives, per the options doc.
- **`run_live_command`.** No AX command beyond audio output exists yet;
  the shape is documented, not built.
- **A `note_id`-carrying `/live/clip/get/notes` reply and
  `apply_note_modifications`** — the fork gap that would let `edit_notes`
  preserve probability/deviation/release velocity. Stays in FORK_GAPS.md.
- **`select_track`/`select_scene` merge, `show_view`/`hide_view` merge,
  `bypass_device`/`delete_device` merge** — declined in the options doc.
- **`Session.State` changes** — none needed; every value `set_mixer` writes
  is already mirrored or deliberately not (arm).
- **CLAUDE.md's "Current focus" narrative**, which names the old tools
  historically — `/ship` syncs it.

## Open questions

None left open by the research. Two decisions worth the user's eye rather
than questions:

- `set_mixer.track` optional (handler-enforced) rather than `@device_target`'s
  required-with-"pass 0" — reasoning in Context §3. If consistency with the
  device tools is preferred, the change is one word in the schema and one
  sentence in the description.
- `edit_notes` refuses an out-of-range result rather than clamping pitch/start
  (it clamps only `velocity_delta`, where clamping is the musical intent).
  Clamping pitch silently would pile notes onto G9/C-2; refusing costs the
  model one retry with a smaller transpose.
