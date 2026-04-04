# Command Flow

End-to-end path from user input to Ableton state change.

## Pipeline

```
User types text in browser
        │
        ▼
SeshatWeb.AssistantLive
  handle_event("submit", ...)
  → start_async(:parse_and_send, fn -> run(input, log) end)
        │
        ▼
Seshat.Session.State.tracks()     ← current Ableton state (track names, values)
        │
        ▼
Seshat.Commands.Parser.parse(input, tracks, history)
  → Calls Claude API (Haiku) with:
      - System prompt defining command schema
      - Session state (track names + current values)
      - Last 5 successful commands as conversation history
  → Returns {:ok, %Command{}} or {:error, reason}
        │
        ▼
Seshat.Commands.Registry.execute(%Command{})
  → Pattern matches on command type
  → May involve multi-step sequences (e.g. create track + name it)
  → Calls into the transport layer
        │
        ▼
Seshat.OSC.Transport (GenServer)          ← current bridge: AbletonOSC over UDP
  → Encodes via Seshat.OSC.Message        ← swappable in the future (M4L WebSocket, etc.)
  → Sends to Ableton, receives responses
  → Broadcasts incoming messages via PubSub on "osc:in"
        │
        ▼
Seshat.Session.State (subscribes to "osc:in")
  → Updates in-memory track state
  → Can be explicitly refreshed after structural changes (e.g. track creation)
```

## Command Struct

```elixir
%Seshat.Commands.Command{
  command: :pan | :volume | :mute | :solo | :create_track,
  track: non_neg_integer() | nil,   # nil for create_track
  value: float() | nil,             # nil for create_track
  track_type: :midi | :audio | nil, # only for create_track
  name: String.t() | nil            # only for create_track
}
```

Fields are optional depending on command type. Mixer commands use `track` + `value`.
Structural commands like `create_track` use `track_type` + `name`.

## LLM Contract

The parser's system prompt defines two JSON shapes:

Mixer commands:
```json
{"command": "pan", "track": 0, "value": -1.0}
```

Track creation:
```json
{"command": "create_track", "track_type": "midi", "name": "Drums"}
```

Error:
```json
{"error": "brief reason"}
```

The system prompt is augmented at runtime with:
- Current track state (names, pan, volume, mute, solo) when available
- Conversation history (last 5 successful commands as user/assistant turns)

Model: `claude-haiku-4-5-20251001`, max_tokens: 128

## Implemented Commands

| Command | What it does | Key fields |
|---------|-------------|------------|
| `:pan` | Set track panning | track, value (-1.0 to 1.0) |
| `:volume` | Set track volume | track, value (0.0 to 1.0) |
| `:mute` | Mute/unmute track | track, value (0 or 1) |
| `:solo` | Solo/unsolo track | track, value (0 or 1) |
| `:create_track` | Create and name a new track | track_type (:midi/:audio), name |
