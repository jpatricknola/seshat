# CLAUDE.md

## Project: Ableton AI Assistant (codename: whatever you're calling it)

### Overview

An AI-powered assistant for Ableton Live, built with Elixir/Phoenix LiveView.
Users type natural language commands in a browser UI, which are parsed into
structured commands and sent to Ableton via OSC.

### Architecture

```
Browser → Phoenix LiveView → LLM Intent Parser → Command Registry → OSC Transport → AbletonOSC → Ableton Live
```

### Key Design Decisions

- **Ableton Bridge**: AbletonOSC (MIDI Remote Script) for POC, future migration to custom Max for Live WebSocket device
- **OSC Transport**: UDP to localhost:11000 (AbletonOSC default)
- **LLM**: Anthropic Claude API for intent parsing. Returns JSON with structured commands.
- **No over-engineering**: POC targets simple single-action commands (pan, volume, mute, solo). Compound commands come later.

### Ableton Live Object Model (LOM) Mapping

The command vocabulary maps directly to the LOM hierarchy:

- Song → Track → MixerDevice → Pan / Volume / Sends
- Song → Track → Devices → Parameters
- AbletonOSC message format: `/live/track/set/panning [track_index, value]`
- Pan values: -1.0 (full left) to 1.0 (full right)
- Volume values: 0.0 to 1.0 (mapped to dB internally by Ableton)

### Module Structure

- `lib/assistant/osc/transport.ex` — GenServer wrapping :gen_udp for OSC communication
- `lib/assistant/osc/message.ex` — OSC message encoding
- `lib/assistant/commands/registry.ex` — Maps internal command structs to OSC messages
- `lib/assistant/commands/parser.ex` — LLM-based intent parsing (natural language → command struct)
- `lib/assistant/session/state.ex` — Mirrors Ableton session state (tracks, devices, parameters)
- `lib/assistant_web/live/` — LiveView UI

### Current POC Goal

Prove the full loop: user types "pan track 1 to the left" → LLM parses →
OSC message sent → Ableton pans the track. That's it. Nothing more until this works.

### Tech Stack

- Elixir / Phoenix LiveView
- AbletonOSC (Python MIDI Remote Script, installed in Ableton)
- Anthropic Claude API for NLP
- No database needed yet

### Conventions

- Use standard Phoenix/Elixir conventions
- Commands are represented as structs, not raw maps
- All OSC interaction goes through the Transport GenServer — nothing sends UDP directly
