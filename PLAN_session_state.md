# Implementation Plan: Enrich Session State

## Goal

Our `Session.State` GenServer currently only tracks per-track properties
(name, volume, pan, mute, solo). We're missing song-level information that
the agent needs for context — especially as we add features like MIDI note
writing where tempo and time signature directly affect interpretation.

---

## What We Have Today

```elixir
%{
  tracks: [
    %{index: 0, name: "Bass", volume: 0.85, pan: 0.0, mute: false, solo: false},
    ...
  ]
}
```

Queried on startup via `/live/song/get/num_tracks` + per-track property queries.
Live updates via AbletonOSC listeners (`start_listen`).

---

## What We're Missing

### Song-Level Properties

| Property | OSC Query | OSC Response | Why We Need It |
|---|---|---|---|
| **Tempo** | `/live/song/get/tempo` | `[float]` (BPM) | Context for note timing, "fast arpeggio" interpretation, general session awareness |
| **Time sig numerator** | `/live/song/get/signature_numerator` | `[int]` | "Beat 3" means different things in 3/4 vs 4/4; determines bar length for clip creation |
| **Time sig denominator** | `/live/song/get/signature_denominator` | `[int]` | Needed to correctly interpret "quarter note" in 6/8 vs 4/4 |
| **Song name** | `/live/song/get/name` | `[string]` | Useful context for the agent, not critical |
| **Is playing** | `/live/song/get/is_playing` | `[int]` | Lets agent know if transport is running; may affect commands |

### Per-Track Properties We Could Add Later (not in scope now)

| Property | OSC Query | Notes |
|---|---|---|
| Arm state | `/live/track/get/arm` | Useful when recording |
| Clip slots / clip names | `/live/clip_slot/...` | Needed for MIDI note writing to know what clips exist |
| Device names | `/live/device/get/name` | Useful for "change the reverb on the vocals" |
| Send levels | `/live/track/get/send` | Needed for send/return routing commands |

These are noted for awareness but **not part of this plan**.

---

## Implementation

### 1. Extend the state shape

Current:
```elixir
%{tracks: [...]}
```

New:
```elixir
%{
  song: %{
    tempo: 120.0,
    time_sig_numerator: 4,
    time_sig_denominator: 4,
    name: "Untitled",
    is_playing: false
  },
  tracks: [...]
}
```

### 2. Query song properties on startup/refresh (`do_refresh/1`)

After the existing track queries, add song-level queries:

```elixir
tempo = query_float(Transport, "/live/song/get/tempo", [], 120.0)
sig_num = query_int(Transport, "/live/song/get/signature_numerator", [], 4)
sig_den = query_int(Transport, "/live/song/get/signature_denominator", [], 4)
name = query_string(Transport, "/live/song/get/name", [], "Untitled")
is_playing = query_int(Transport, "/live/song/get/is_playing", [], 0) |> to_bool()
```

Note: The existing `query_float/4`, `query_string/4`, and `query_int/4` helpers
take a track index as the third arg. Song-level queries take no args, so we'll
need to either add overloads or adjust the helpers slightly. The simplest approach
is song-specific query helpers that pass `[]` as the OSC args.

### 3. Subscribe to live updates

AbletonOSC supports listeners for song-level properties:

```
/live/song/start_listen/tempo
/live/song/start_listen/signature_numerator
/live/song/start_listen/signature_denominator
/live/song/start_listen/is_playing
```

Add these in `subscribe_listeners/1` (or a new `subscribe_song_listeners/0`).

Handle incoming updates with new `handle_info` clauses:

```elixir
def handle_info({:osc_message, "/live/song/get/tempo", [value]}, state)
def handle_info({:osc_message, "/live/song/get/signature_numerator", [value]}, state)
def handle_info({:osc_message, "/live/song/get/signature_denominator", [value]}, state)
def handle_info({:osc_message, "/live/song/get/is_playing", [value]}, state)
```

### 4. Expose via client API

Add a `song/0` function alongside the existing `tracks/0`:

```elixir
def song, do: GenServer.call(__MODULE__, :song)
```

### 5. Update `get_session_state` tool output

In `lib/seshat/tools/handlers.ex`, update the `call("get_session_state", ...)` clause
to include song-level info in the summary:

```
Tempo: 120.0 BPM | Time Signature: 4/4 | Playing: no

Track 0 "Bass": pan=0.0, volume=0.85
...
```

This means the agent automatically has tempo and time sig context whenever it
checks session state — no extra tool call needed.

---

## Files to Modify

1. **`lib/seshat/session/state.ex`** — new state shape, song queries, song listeners, song update handlers, `song/0` client function
2. **`lib/seshat/tools/handlers.ex`** — update `get_session_state` output to include song info

---

## Open Questions

1. **Song-level query helper** — The existing `query_float/4` etc. pass a track
   index as the OSC arg. Song queries pass no args. Cleanest fix: add
   `query_song_float/3` helpers, or make the arg list explicit.

2. **AbletonOSC listener addresses** — Need to verify that `/live/song/start_listen/tempo`
   etc. exist in our installed AbletonOSC version. If not, we poll on refresh only
   (no live updates for song properties).

3. **Time signature changes mid-song** — Ableton supports this but AbletonOSC may
   only expose the global/initial time sig. For POC this is fine — most songs have
   one time signature.
