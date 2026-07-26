# Plan — Clip-slot state (`get_clip_slots`)

Roadmap Priority 1. One new read-only tool, `get_clip_slots`, that returns the
whole Session-view grid in one call: per track — name, type (MIDI/audio/group),
and every clip slot (empty, or clip name / length / playing / recording) — plus
the scene list (count and names).

## Context

Session state today is track-level only. The model can see tracks, tempo and
key, but not which slots hold clips, which are empty, which are playing, or
what anything is called. So `fire_clip`, `duplicate_clip`, `delete_clip` and
`write_midi_notes` all operate on guessed slot indices, and "fire the chorus"
can't resolve "the chorus" to a scene. Worse, `write_midi_notes` against an
audio track fails silently — nothing in the current surface reveals track type.

One bulk query fixes all of it:

- **`/live/song/get/track_data`** returns properties for a whole block of
  tracks and *all their clip slots* in a single reply — no
  O(tracks × scenes) round-trips of `/live/clip_slot/get/has_clip`.
- Scene names ride along as per-scene `/live/scene/get/name` queries (cheap,
  and there is no bulk scene-name address).

Per the roadmap (and the same call made for `get_track_devices`): **query on
demand** — a new tool, not new `Session.State` fields. Promote to
`Session.State` later only if usage shows it read constantly.

Two research findings that changed the obvious approach (both verified in the
installed AbletonOSC source, `~/Music/Ableton/User Library/Remote
Scripts/AbletonOSC/abletonosc/song.py` and
`pythonosc/osc_message_builder.py`):

1. **Empty slots come back as OSC nil (`N` type tag)** — `track_data` appends
   Python `None` for every `clip.*` property of an empty slot, and pythonosc
   encodes `None` as type tag `N` with no payload bytes.
   `Seshat.OSC.Message.decode/1` has **no clause for `"N"`** — today a
   `track_data` reply containing any empty slot would crash the Transport's
   `handle_info` with a `FunctionClauseError`. Part 1 fixes the decoder first.
2. **The reply is one flat list with a computable shape** — per track, each
   `track.*` property contributes 1 value and each `clip.*`/`clip_slot.*`
   property contributes exactly `num_scenes` values, in the order the
   properties were given. Parsing therefore needs `num_scenes` up front, and
   is a pure chunking function we can unit-test without Ableton.

## OSC contract

All request addresses verified against
[abletonosc-api-docs.md](abletonosc-api-docs.md); reply shapes for
`track_data` verified against the installed AbletonOSC source (`song.py`
`song_get_track_data`).

| Address | Request args | Reply |
|---|---|---|
| `/live/song/get/num_tracks` | — | `[num_tracks]` |
| `/live/song/get/num_scenes` | — | `[num_scenes]` |
| `/live/song/get/track_data` | `[start_track, end_track, prop…]` | flat `[values…]`, see below |
| `/live/scene/get/name` | `[scene_id]` | `[scene_id, name]` |

`track_data` specifics (from source):

- `start_track` is inclusive, `end_track` **exclusive** (`range(min, max)`).
  `end_track = -1` means "all tracks", but we always pass explicit bounds
  because parsing needs the count anyway.
- Covers **regular tracks only** (`song.tracks`) — return and master tracks
  are not in the range, which is exactly right for a clip grid.
- Properties we request, in this order:
  `track.name`, `track.has_midi_input`, `track.is_foldable`,
  `clip_slot.has_clip`, `clip.name`, `clip.length`, `clip.is_playing`,
  `clip.is_recording`.
- Reply shape per track: 3 single values (the `track.*` props), then 5 runs of
  `num_scenes` values each (the slot-level props), i.e. **`3 + 5 × num_scenes`
  values per track**, tracks concatenated in order.
- Wire types: names are strings (`s`); `length` is a float (`f`);
  `has_clip` / `has_midi_input` / `is_foldable` / `is_playing` /
  `is_recording` are real OSC booleans (`T`/`F`); every `clip.*` value for an
  **empty slot is OSC nil (`N`)**. `clip_slot.*` values are never nil.
- The reply is a single UDP datagram on the same `/live/song/get/track_data`
  address (Transport's address-based correlation works as-is). Booleans and
  nils carry no payload, so size is dominated by clip-name strings; the
  existing 64KB `recbuf` covers any realistic set, but we still batch (below)
  so a monster set degrades to more queries instead of a truncated datagram.

Batching rule: query tracks in batches of
`max(1, div(4000, 3 + 5 * num_scenes))` tracks per `track_data` call
(one batch for any normal set — 16 tracks × 16 scenes is 1,328 values; a
40 × 40 set is ~8,100 values and gets two batches). Sequential
`Transport.query` calls, default 5s timeout each — `track_data` is an
in-process loop inside Live and returns fast.

Scene names are `num_scenes` sequential `/live/scene/get/name` queries.
Fast, tiny replies; no guard needed (the index range comes from `num_scenes`
in the same pass).

## Parts

### Part 1 — Decode OSC nil ([lib/seshat/osc/message.ex](../lib/seshat/osc/message.ex))

Add one decoder clause beside the `T`/`F` ones:

```elixir
defp decode_arg("N", data), do: {nil, data}
```

No payload bytes, decodes to `nil`. Encoding side unchanged — Seshat never
sends nil. This lands first because without it every `track_data` reply with
an empty slot kills the decode.

### Part 2 — Tool definition ([lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex))

Append to `@tools`. Draft (the description is the whole prompt in MCP mode):

```elixir
%{
  name: "get_clip_slots",
  description:
    "Read the whole Session-view clip grid in Ableton Live: every scene " <>
      "(with its name) and, for each track, its type and every clip slot — " <>
      "empty, or holding a clip with its name, length in beats, and whether " <>
      "it is playing or recording. " <>
      "Track and slot indices are 0-based; slot N is scene N (one row of " <>
      "the grid). " <>
      "ALWAYS call this before firing, duplicating, deleting, or writing " <>
      "into a clip slot you have not already seen this conversation — it is " <>
      "the only way to know which slots are occupied, and it resolves scene " <>
      "names like 'the chorus' to a scene index. " <>
      "Track type matters: write_midi_notes only works on MIDI tracks; " <>
      "group tracks hold no clips of their own. " <>
      "Returns only regular tracks (no return/master tracks — those have no " <>
      "clip slots).",
  parameters: %{type: "object", properties: %{}, required: []}
}
```

No parameters — the whole grid in one call, like `get_session_state`. (A
`track` filter param was considered and dropped: the reply is already compact,
and the point of the tool is the overview.)

### Part 3 — Handler ([lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex))

A `do_call("get_clip_slots", _params)` clause, placed near
`get_session_state`. Reads only, so direct `Transport.query` — no
`%Command{}`/Registry (Registry is for mutation sequences). Shape:

1. `/live/song/get/num_tracks`, `/live/song/get/num_scenes`. Zero tracks →
   `{:ok, "No tracks in the session"}`-style success. Zero scenes can't
   happen in a real Live set (Live always has ≥ 1 scene).
2. `/live/scene/get/name` for each scene index, collected in order.
3. `/live/song/get/track_data` per batch (rule above) with the 8 properties
   in the order given in the OSC contract; concatenate the batch replies.
4. Parse with a **pure** `parse_track_data/3` (public, beside
   `parse_clip_notes/1`): takes the flat values, `num_scenes`, and the track
   count in this batch; chunks into `3 + 5 * num_scenes` per track, then
   builds one map per track (`name`, `midi?`, `group?`, and a slots list of
   `nil` / `%{name:, length:, playing?:, recording?:}`). Fail loudly (clear
   `{:error, …}` naming the actual and expected length) if the reply length
   is not `tracks * (3 + 5 * num_scenes)` — same upstream-drift guard
   `parse_clip_notes/1` uses.
   A slot is empty iff `has_clip` is falsy (`truthy?/1` — belt and braces
   against 0/1 vs booleans); the nil `clip.*` values for empty slots are
   simply discarded.
5. Format with a pure `format_clip_slots/2` (scenes, tracks). Sketch:

   ```
   4 scene(s): 0 "Intro", 1 "Verse", 2 "Chorus", 3 ""

   Track 0 "Drums" (MIDI):
     slot 0: "Beat A" — 4.0 beats [playing]
     slot 1: "Beat B" — 8.0 beats
     slots 2-3: empty
   Track 1 "Bass" (MIDI): all 4 slots empty
   Track 2 "Vox" (audio):
     slot 2: "Take 3" — 16.0 beats [recording]
     slots 0-1, 3: empty
   ```

   - Consecutive empty slots collapse into ranges — with 30 scenes the
     output would otherwise be mostly the word "empty".
   - Track label from the flags: `is_foldable` → `group`, else
     `has_midi_input` → `MIDI`, else `audio`.
   - Unnamed clips arrive as `""` — print `(unnamed)` so the model doesn't
     emit confusing empty quotes.
6. `catch :exit` → timeout error pointing at Ableton/AbletonOSC, same wording
   family as `get_track_devices`.

### Part 4 — Cross-references in existing tool descriptions ([lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex))

The tool only kills blind slot operations if the slot-consuming tools point
at it. Add one sentence — "Use get_clip_slots first to see which slots hold
clips (and which tracks are MIDI)" appropriately phrased — to the descriptions
of: `fire_clip`, `stop_clip`, `delete_clip`, `duplicate_clip`,
`write_midi_notes`, `get_clip_notes`, and `fire_scene` (scene-name
resolution). Keep each to a single added sentence; these descriptions are
prompt budget.

### Part 5 — Tests

- [test/seshat/tools/definitions_test.exs](../test/seshat/tools/definitions_test.exs)
  — bump the count tripwire **40 → 41**.
- MCP parity (`Seshat.MCP.ToolsTest`) is automatic; `get_clip_slots`
  round-trips `Macro.camelize/underscore`.
- Message decoding: a `decode` test with an `N` in the type tags (mixed with
  `s`/`f`/`T`/`F`) asserting `nil` lands in the right position and following
  args still decode.
- `parse_track_data/3`: happy path (2 tracks × 2 scenes, one empty slot →
  nil), wrong-length reply → `{:error, …}`, boolean-vs-integer flag handling.
- `format_clip_slots/2`: the sketch above — range collapsing, all-empty
  track, `[playing]`/`[recording]` flags, `(unnamed)` clip, group label.

Nothing tests through `Transport.query/3` (per
[.claude/rules/testing.md](../.claude/rules/testing.md)) — the handler's
query choreography is exercised only by the smoke test.

### Part 6 — Smoke test (needs live Ableton — `/smoke-test` flow)

1. A set with named scenes, a group track, an audio track, and a part-filled
   grid: `get_clip_slots` output matches what Live shows (names, lengths,
   emptiness, track types).
2. Fire a clip, call again → `[playing]` moves. Record-arm and record into a
   slot → `[recording]`.
3. A set large enough to force two batches (e.g. duplicate tracks past the
   batch threshold) → output identical in shape, no truncation.
4. The motivating flows end-to-end: "fire the chorus" (scene name → index)
   and "add a bassline in a new slot" (model picks an actually-empty slot on
   an actually-MIDI track).

## Out of scope

- **Promoting the grid into `Session.State`** — stays on the roadmap ("query
  on-demand … promote only if read frequently"). Clip-slot listeners are a
  large subscription surface (tracks × scenes × properties); not worth it
  until usage data says so.
- **Return-track names / send levels** — Priority 2. `track_data` doesn't
  cover return tracks anyway.
- **Clip properties beyond the grid** (loop points, launch mode, warp, gain)
  — "Smaller OSC surface" roadmap entry.
- **A `has_stop_button` / slot-color read** — no workflow needs it.
- **Using `get_clip_slots` inside `Registry.ensure_clip/3`** — the existing
  per-slot `has_clip` guard is the right size there; one slot, one query.

## Open questions

None left open as user-blocking; two items need the smoke test to confirm
(both flagged ⚠️ in spirit above):

1. ⚠️ **Nil wire format in practice.** That empty slots arrive as type tag
   `N` is verified in the vendored pythonosc source
   (`osc_message_builder.py`: `None` → `ARG_TYPE_NIL`, no payload), not yet
   on the wire. If a different AbletonOSC version encoded `None` differently
   the decode test wouldn't catch it. First implementation step with Ableton
   open: fire one `track_data` query at a set with an empty slot and check
   the Transport debug log. The plan assumes `N`.
2. ⚠️ **Group-track slots.** Assumed (from LOM behaviour) that a group
   track's clip slots report `has_clip = false` even when child clips are
   playing "through" the group row. If the smoke test shows otherwise,
   suppress the slot listing for `is_foldable` tracks and print only
   `(group)` — the formatter already isolates that choice.

Decisions made rather than left open (reasoning in one line each):

- **Query-on-demand tool, not `Session.State`** — roadmap's own call;
  matches `get_track_devices` precedent.
- **No parameters on the tool** — the overview is the product; filtering
  saves almost nothing.
- **`clip_slot.has_clip` requested even though nil-ness of `clip.name` would
  do** — it is the property the codebase already treats as ground truth
  (`ensure_clip`), booleans are nearly free on the wire, and emptiness stays
  explicit instead of inferred.
- **`track.is_foldable` included** — one value per track prevents the model
  treating a group track as a writable audio track.
- **Scene names via per-scene queries** — no bulk address exists; N tiny
  sequential queries are fine at real-world scene counts.
- **Batched `track_data`** — keeps any single datagram far under the 64KB
  socket buffer; one batch in the normal case.
