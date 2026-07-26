# Plan — `get_clip_notes` (+ key/scale in session state)

> **Status: active plan.** When this ships, move this doc to
> [archive/](archive/) with a status banner and delete the item from
> [ROADMAP.md](ROADMAP.md) (the `/ship` skill does both).

Roadmap Priority 1. Two deliverables in one pass:

1. **`get_clip_notes`** — read the MIDI notes in a clip, so content-dependent
   edits (transpose, fix a note, humanize, swing) stop being destructive
   rewrites. The write side already exists (`write_midi_notes` preserves
   notes, `remove_notes` takes a range); this is the missing read leg.
2. **Key and scale in `get_session_state`** — `root_note` + `scale_name`, so
   the model knows what key it is reading and writing in. Riding along
   because it is two queries and the two features compound.

## Non-goals

- No transform tools (`transpose_clip`, `quantize_clip`, …). The design bet
  is that the LLM composes edits from read + remove + write. Revisit only if
  real usage shows the three-call loop failing.
- No clip-slot map — that is Priority 2, a separate tool.
- No per-note mute *writing* — `write_midi_notes` stays as is; mute state is
  surfaced read-only in this tool's output.

## OSC addresses (verified against [abletonosc-api-docs.md](abletonosc-api-docs.md))

| Address | Args | Reply |
|---|---|---|
| `/live/clip/get/notes` | `track, slot [, start_pitch, pitch_span, start_time, time_span]` | `track, slot, then flat 5-tuples: pitch, start_time, duration, velocity, mute, …` |
| `/live/clip_slot/get/has_clip` | `track, slot` | `track, slot, has_clip` |
| `/live/clip/get/is_midi_clip` | `track, slot` | `track, slot, is_midi_clip` |
| `/live/clip/get/name` | `track, slot` | `track, slot, name` |
| `/live/clip/get/length` | `track, slot` | `track, slot, length` |
| `/live/song/get/root_note` | | `root_note` (pitch class, C = 0) |
| `/live/song/get/scale_name` | | `scale_name` (e.g. "Major") |

**Reply shape verified against the installed AbletonOSC source**
(`clip.py`'s `clip_get_notes` + `create_clip_callback`):

- Reply is exactly `(track_index, clip_index, *notes)` where each note
  contributes exactly 5 fields: `pitch, start_time, duration, velocity,
  mute` — chunk the tail by 5. Still fail loudly (clear `{:error, …}`) if
  the tail length isn't divisible by 5, as a guard against future upstream
  drift, but today it can't happen.
- Loose types in the parser: `pitch` is an int, `start_time`/`duration` are
  floats, `velocity` can be a **float** in Live 11+ (not always int), and
  `mute` arrives as a bool.
- The range args are **all-or-nothing**: the handler raises unless it gets
  exactly 0 or 4 args. So if *any* range param is passed, fill all four
  (defaults mirroring `remove_notes`: 0, 128, 0.0, 9999.0); if none, send
  bare `[track, slot]` and AbletonOSC applies its own catch-all defaults
  (`0, 127, -8192, 16384` — the negative start covers notes before the
  clip start marker).
- Querying a slot with **no clip raises inside AbletonOSC** (`.clip` is
  `None`) → no reply → 5s timeout. This confirms the `has_clip` guard below
  is required, not just nice.

## Tool definition (`lib/seshat/tools/definitions.ex`)

```elixir
%{
  name: "get_clip_notes",
  description:
    "Read the MIDI notes in a clip in Ableton Live. " <>
      "Track indices are 0-based; clip_slot defaults to 0. " <>
      "Returns every note as pitch (with note name), start beat, duration in beats, " <>
      "velocity, and whether the note is muted, plus the clip's name and length. " <>
      "ALWAYS call this before editing existing material — transposing, fixing a note, " <>
      "humanizing velocities, adding to an existing part — so you work with what is " <>
      "actually there instead of overwriting it. " <>
      "The typical edit loop is: get_clip_notes → decide changes → remove_notes " <>
      "(with a pitch/time range) → write_midi_notes. " <>
      "Optionally restrict the read to a pitch/time window using the same range " <>
      "parameters remove_notes takes.",
  parameters: %{
    type: "object",
    properties: %{
      "track" => %{type: "integer", description: "0-indexed track number"},
      "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot (default 0)"},
      "start_pitch" => %{type: "integer", description: "Lowest pitch to include (default 0)"},
      "pitch_span" => %{
        type: "integer",
        description: "Number of pitches to span (default 128 = all)"
      },
      "start_time" => %{type: "number", description: "Start time in beats (default 0.0)"},
      "time_span" => %{
        type: "number",
        description: "Time span in beats (default: entire clip)"
      }
    },
    required: ["track"]
  }
}
```

Range parameter names deliberately mirror `remove_notes` so the model can
carry the same window through the read → remove → write loop.

## Handler (`lib/seshat/tools/handlers.ex`)

A `do_call/2` clause under `# --- Notes ---`, next to `remove_notes`. Direct
`Transport.query` calls — this is reads only, so no `%Command{}`/Registry
(Registry is for mutation sequences). Multiple inline queries per handler is
the established pattern (`get_track_devices`, `get_device_parameters`).

Shape:

1. **Guard: slot has a clip.** Query `/live/clip_slot/get/has_clip` first
   (same guard Registry uses at
   [registry.ex:58](../lib/seshat/commands/registry.ex#L58)). Empty slot →
   instant, useful error ("No clip in slot N on track M — use fire-able slots
   from get_session_state") instead of a 5s timeout on the notes query.
2. **Guard: clip is MIDI.** `/live/clip/get/is_midi_clip` — audio clip →
   clear error naming the clip, since a notes query against an audio clip
   will not answer.
3. **Context.** `/live/clip/get/name` and `/live/clip/get/length` for the
   header line.
4. **Notes.** `/live/clip/get/notes` with the four range args when any range
   param was passed, bare `[track, slot]` otherwise (mirror `remove_notes`
   defaults: 0, 128, 0.0, entire clip). Chunk the reply tail into 5-tuples.
5. Default 5s query timeout is fine — notes replies are small. `catch :exit`
   with a message pointing at `get_session_state` and the slot index, like
   the other query handlers.

Output is a pure formatter (`format_clip_notes/…`, private, beside
`format_device_parameters`) so it can be unit-tested without a Transport:

```
Clip "Bassline" on track 1, slot 0 — 4.0 beats, 6 notes:
  C2 (36)  start=0.0   dur=0.5   vel=100
  G2 (43)  start=0.5   dur=0.5   vel=90
  C2 (36)  start=1.0   dur=0.25  vel=100  [muted]
  ...
```

- Note names via a small pitch→name helper (C4 = 60, sharps only: C#, D#, …).
  The model does the theory, but names remove a whole class of off-by-octave
  mistakes.
- Empty MIDI clip (0 notes) is a **success**, not an error: state the clip
  exists and is empty — that answers "what's in this clip".

## Key/scale in session state (`lib/seshat/session/state.ex`)

Follows the "new session state" steps in
[adding-a-tool.md](../.claude/docs/adding-a-tool.md):

1. Add `root_note: 0, scale_name: "Major"` to the initial song map.
2. Query both in `do_refresh/1` (`query_song_int` / new `query_song_string`
   helper — no song-level string getter exists yet).
3. Add `root_note` and `scale_name` to `@listened_song_properties` and add
   the two `handle_info` clauses. **Verified against the installed AbletonOSC
   source** (`~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`):
   both properties are in `song.py`'s `properties_rw`, so the
   `start_listen` handlers are registered, and `handler.py`'s
   `_start_listen` maps them to Live's `add_root_note_listener` /
   `add_scale_name_listener` — present in the LOM since Live 11.1, and this
   machine runs Live 12 Suite. Two useful mechanics confirmed in the source:
   subscribing **immediately pushes the current value** (so the listener
   path self-initialises; the refresh-time query is belt and braces), and
   the push arrives as `/live/song/get/<prop> [value]` — the same
   single-value shape the existing song `handle_info` clauses match.
4. Surface in `get_session_state`'s song line via the same pitch-class→name
   helper (root_note is 0–11, C = 0):

   ```
   120.0 BPM, 4/4, stopped, key: C Major
   ```

5. Update `get_session_state`'s **description** in `Definitions` to mention
   it now returns the song's key and scale — in MCP mode the description is
   the only prompt the model gets.

Caveat worth keeping: Live reports C Major even when the user never touched
the scale controls. The `get_session_state` description should say the key is
"as set in Live's scale controls" so the model treats it as a strong hint,
not gospel.

## Tests

- `definitions_test.exs` — bump the tool count (the deliberate tripwire).
- MCP parity (`Seshat.MCP.ToolsTest`) — automatic once the definition exists;
  `get_clip_notes` round-trips `Macro.camelize/underscore` fine.
- Unit-test the pure parts, per [testing rules](../.claude/rules/testing.md)
  (nothing that touches `Transport.query`):
  - note-list parsing: chunking flat 5-tuples, the non-divisible-by-5 error,
    empty list;
  - `format_clip_notes` output including the `[muted]` flag;
  - pitch→note-name helper (both directions of the octave math: 36 → C2,
    60 → C4, 61 → C#4).
- Session state: extend existing `Session.State` tests for the two new song
  fields and their `handle_info` pushes.

## Smoke test (needs live Ableton — `/smoke-test` flow)

1. Write a known 4-note pattern with `write_midi_notes`, read it back with
   `get_clip_notes` — pitches, starts, durations, velocities round-trip.
2. Read with a pitch range and a time range — only windowed notes return.
3. Empty slot → the has_clip error. Audio clip → the is_midi_clip error.
   Empty MIDI clip → success with 0 notes.
4. Confirm a float velocity round-trips (record or draw a note with a
   non-integer velocity in Live 12) — reply arity itself is already
   verified in source.
5. Change Live's scale controls; confirm `get_session_state` shows the new
   key (listener support already verified in source — this just confirms the
   end-to-end path).
6. The full collaborator loop: "transpose the bassline up a fifth" end-to-end
   — read, remove range, rewrite shifted.

## Ship checklist

`mix precommit` green → run `/ship`: delete Priority 1 from
[ROADMAP.md](ROADMAP.md) (the key/scale bullet in "Session state
improvements" ships with it), archive this doc, sync the CLAUDE.md focus
line to clip-slot state.
