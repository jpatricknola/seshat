# Roadmap

The single living list of what's **not built yet**. When something here ships,
delete it from this file; if it shipped from a detailed plan doc, move that doc
to [archive/](archive/) with a status banner. [archive/](archive/) holds
point-in-time plans and decision records — never treat those as current.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address.

---

## Priority 1 — Send levels

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
3. **Track type** (MIDI vs audio) — what supports notes vs audio recording.
4. **Scene count and names** — resolve "the chorus" → scene index.

Query on-demand in the tools to start; promote into `Session.State` only if
read frequently.

## Idea — MCP mode in the browser UI

Give `AssistantLive` a second backend: spawn headless Claude Code (`claude -p`)
as a subprocess consuming Seshat's own `/mcp` endpoint, so the browser UI works
off a Claude subscription instead of an API key, with a per-conversation
toggle. Designed but never built — full plan (milestones, streaming UI, tested
CLI flags that may have drifted) in
[archive/PLAN_mcp_browser_ui.md](archive/PLAN_mcp_browser_ui.md).

## Priority 2 — smaller OSC surface

- **Clip properties** — loop points, launch mode, warp mode, clip gain.
- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low value
  for AI control.
- **Recording modes** — session record, arrangement overdub, punch in/out.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Bulk track data** — `/live/song/get/track_data [start, end, properties…]`;
  a `get_session_state` optimization, not needed at current track counts.

## Deliberately not planned

- Return/master-track device loading, device *removal* beyond the audition
  loop above, rack inner chains, parameter listeners (live meters/automation
  following) — revisit if a real workflow needs them.
