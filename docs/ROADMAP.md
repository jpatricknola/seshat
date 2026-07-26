# Roadmap

The single living list of what's **not built yet**. When something here ships,
delete it from this file; if it shipped from a detailed plan doc, move that doc
to [archive/](archive/) with a status banner. [archive/](archive/) holds
point-in-time plans and decision records — never treat those as current.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address.

---

## Priority 1 — Clip-slot state

Planned — implementation plan in [PLAN_clip_slot_state.md](PLAN_clip_slot_state.md).

Session state is track-level only: we don't know which slots hold clips, which
are empty, which are playing or recording, or their names and lengths. So
`fire_clip`, `duplicate_clip`, and note-writing all operate on guessed slot
indices. A per-track slot map (has_clip, name, length, is_playing) eliminates
a whole class of blind operations.

- Tool: `get_clip_slots` — query on demand to start; promote into
  `Session.State` only if read frequently.
- Use `/live/song/get/track_data [start, end, properties…]` with
  `clip_slot.*` / `clip.*` properties — one bulk query for the whole grid,
  not O(tracks × scenes) round-trips of `/live/clip_slot/get/has_clip`.
- Include **scene count and names** (`/live/song/get/num_scenes`) — the scene
  list and the slot grid are the same axis; resolves "the chorus" → scene
  index.
- Include **track type** (`track.has_midi_input`) — `write_midi_notes`
  against an audio track is another silent blind failure; it rides the same
  bulk query.

## Priority 2 — Send levels

"Add some reverb to the vocals." "Turn down the delay send on the drums."

```
/live/track/get/send    [track_id, send_id]          → [track_id, send_id, value]
/live/track/set/send    [track_id, send_id, value]
```

- Send IDs are 0-indexed (send A = 0, send B = 1, …). Values 0.0–1.0.
- Tool: `set_track_send` — track, send index, value.
- The agent needs return-track names to resolve "the reverb send" → send index.
  Return tracks come after regular tracks in the track list; surface their
  names (via session state or a query in the tool itself).

## Capture MIDI

"Keep that." The user noodles an idea on their controller and the agent grabs
it — Live remembers recent MIDI input even on un-armed tracks.

```
/live/song/capture_midi
```

- Tool: `capture_midi` — single fire-and-forget message, no Registry needed.
- Pairs with `get_clip_notes`: capture, then tighten the timing,
  harmonize, or build a variation. Turns the collaboration bidirectional —
  today the agent generates and the user listens; this lets the user play and
  the agent edit.

## Sound catalog follow-ups

Deliberately left out of catalog v1 (see
[archive/PLAN_sound_catalog.md](archive/PLAN_sound_catalog.md) for context):

- **LLM enrichment** for untagged/third-party items — needs an API key or an
  MCP-client-driven tagging turn.
- **User XMP tags** — read `User Library/Ableton Folder Info/12/`.
- **`samples` category** in the browser export (huge, rarely tag-searched).
- **Windows DB location** for `Seshat.Library.AbletonDB` (currently macOS only;
  returns `{:error, :not_found}` cleanly elsewhere).
- **Audition / hot-swap loop** — a `delete_device` tool so the agent can try a
  sound, judge, and swap it.

## Session state improvements

1. **Return track names** — needed for send levels (above).
2. **Device list per track** — so the agent sees loaded devices without a
   `get_track_devices` round-trip.

Query on-demand in the tools to start; promote into `Session.State` only if
read frequently. (Scene names and track type moved into the clip-slot state
item above.)

## Idea — MCP mode in the browser UI

Give `AssistantLive` a second backend: spawn headless Claude Code (`claude -p`)
as a subprocess consuming Seshat's own `/mcp` endpoint, so the browser UI works
off a Claude subscription instead of an API key, with a per-conversation
toggle. Designed but never built — full plan (milestones, streaming UI, tested
CLI flags that may have drifted) in
[archive/PLAN_mcp_browser_ui.md](archive/PLAN_mcp_browser_ui.md).

## Smaller OSC surface

- **Clip properties** — loop points, launch mode, warp mode, clip gain.
- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low value
  for AI control.
- **Recording modes** — session record, arrangement overdub, punch in/out.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groove amount** — `/live/song/get|set/groove_amount`; pairs with "make it
  swing" now that `get_clip_notes` has landed.

## Deliberately not planned

- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Return/master-track device loading, device *removal* beyond the audition
  loop above, rack inner chains, parameter listeners (live meters/automation
  following) — revisit if a real workflow needs them.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
