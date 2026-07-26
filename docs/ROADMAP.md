# Roadmap

The single living list of what's **not built yet**. When something here ships,
delete it from this file; if it shipped from a detailed plan doc, move that doc
to [archive/](archive/) with a status banner. [archive/](archive/) holds
point-in-time plans and decision records — never treat those as current.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address.

---

## Priority 1 — Send levels & return tracks

"Add some reverb to the vocals." "Turn down the delay send on the drums."
The 2026-07 tool audit ranks this the biggest capability gap: mixing stops at
volume/pan/mute/solo — no way to build space or depth. Planned — full plan
(six tools, vendored return_track.py handler, session-state additions) in
[PLAN_send_levels.md](PLAN_send_levels.md).

```
/live/track/get/send             [track_id, send_id]          → [track_id, send_id, value]
/live/track/set/send             [track_id, send_id, value]
/live/song/create_return_track   []
/live/song/delete_return_track   [track_index]
```

- Send IDs are 0-indexed (send A = 0, send B = 1, …). Values 0.0–1.0.
- Tools: `set_track_send` — track, send index, value; `create_return_track`
  so a send target can be built from scratch, not just used if present.
- The agent needs return-track names to resolve "the reverb send" → send index.
  Return tracks come after regular tracks in the track list; surface their
  names (via session state or a query in the tool itself).
- **Return & master levels** ride along (audit: Low-Med): the mixer setters
  reach regular tracks only. The Track API doc says return/master are
  addressable — verify the indexing against the installed AbletonOSC source
  before relying on it (`track_data` notably covers `song.tracks` only).

## Priority 2 — Device removal & bypass

Audit: Med-High. `load_device` + `set_device_parameter` make the device
workflow one-way — a wrong load can't be undone, and there's no A/B. Also
unlocks the catalog audition/hot-swap loop (below).

- `delete_device` — **upstream has it after all**: `/live/track/delete_device`
  is registered as a track *method* in the installed AbletonOSC
  (`abletonosc/track.py`, `methods = ["delete_device", "stop_all_clips"]`).
  Argument shape confirmed against that source and already added to
  [abletonosc-api-docs.md](abletonosc-api-docs.md) — `track_id, device_id`, no
  reply. No vendored Python needed; this is only a tool away.
- Bypass may be free: every Live device's parameter 0 is "Device On", so
  `set_device_parameter` can already A/B a device — verify, then either add a
  `bypass_device` convenience or just teach the `set_device_parameter`
  description the trick.
- Reordering the chain is out of scope until a workflow demands it.

## Capture MIDI & session record

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
- **Session record** belongs here too (audit: Medium — `set_track_arm` +
  `start_playing` exist but nothing actually records, so the record loop is
  incomplete): `/live/song/set/session_record [1|0]` and
  `/live/song/trigger_session_record`, with
  `/live/song/get/session_record_status` to report state. Arrangement
  overdub / punch in-out stay out (Session view only).

## Clip properties & MIDI cleanup

Audit: Medium ×2. `set_loop` is the *song* loop — a clip's own loop brace,
length after creation, and launch quantization are unreachable; and the most
common MIDI cleanup move (quantize) currently takes a full
read → remove → rewrite by hand.

- **Per-clip properties** — loop points (`/live/clip/get|set/loop_start`,
  `loop_end`, `looping`), launch mode/quantization; warp mode and clip gain
  for audio clips. Check each address against
  [abletonosc-api-docs.md](abletonosc-api-docs.md) — naming is irregular.
- **`quantize_clip`** — **no upstream address**; the Live Object Model has
  `Clip.quantize(grid, amount)`, so this needs a vendored handler the same
  way `/live/browser/*` does. Alternative without Python: an Elixir-side
  read → snap → rewrite using the existing note tools — worse (loses
  Live-native swing handling) but zero install surface.

## Sound catalog follow-ups

Deliberately left out of catalog v1 (see
[archive/PLAN_sound_catalog.md](archive/PLAN_sound_catalog.md) for context):

- **LLM enrichment** for untagged/third-party items — needs an API key or an
  MCP-client-driven tagging turn.
- **User XMP tags** — read `User Library/Ableton Folder Info/12/`.
- **`samples` category** in the browser export (huge, rarely tag-searched).
- **Windows DB location** for `Seshat.Library.AbletonDB` (currently macOS only;
  returns `{:error, :not_found}` cleanly elsewhere).
- **Audition / hot-swap loop** — needs `delete_device`, now tracked under
  Priority 2 (device removal & bypass) above.

## Session state improvements

1. **Return track names** — needed for send levels (above).
2. **Device list per track** — so the agent sees loaded devices without a
   `get_track_devices` round-trip.
3. **Clip grid** — `get_clip_slots` (shipped, see
   [archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) queries
   on demand; promote the grid into `Session.State` only if usage shows it
   read constantly. Clip-slot listeners are a large subscription surface
   (tracks × scenes × properties) — not worth it until then.

Query on-demand in the tools to start; promote into `Session.State` only if
read frequently.

## Idea — MCP mode in the browser UI

Give `AssistantLive` a second backend: spawn headless Claude Code (`claude -p`)
as a subprocess consuming Seshat's own `/mcp` endpoint, so the browser UI works
off a Claude subscription instead of an API key, with a per-conversation
toggle. Designed but never built — full plan (milestones, streaming UI, tested
CLI flags that may have drifted) in
[archive/PLAN_mcp_browser_ui.md](archive/PLAN_mcp_browser_ui.md).

## Smaller OSC surface

- **`set_time_signature`** — audit: Low-Med, cheap symmetry win
  (`get_session_state` reports it, `set_tempo` exists, no setter).
  `/live/song/set/signature_numerator` + `/live/song/set/signature_denominator`.
- **Modify a note in place** — audit: Low. Changing one note's velocity today
  is read → remove range → rewrite; works, a direct edit would be cleaner.
- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low value
  for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groove amount** — `/live/song/get|set/groove_amount`; pairs with "make it
  swing" now that `get_clip_notes` has landed.
- **Groups · routing/IO · automation** — audit: Low, breadth for later.
  Grouping tracks, input/output routing & monitoring, automation envelopes.

## Deliberately not planned

- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Return/master-track device loading, device *reordering* (removal & bypass
  are now Priority 2 above), rack inner chains, parameter listeners (live
  meters/automation following) — revisit if a real workflow needs them.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
