# Implementation Plan: Write MIDI Notes to Track

## Goal

User types natural language like "put a quarter note C on beat 1 of the bass track"
and Seshat writes that MIDI note into a clip in Ableton Live via OSC.

---

## Example User Inputs

**Simple:**
- "Put a quarter note on beat one in the bass, playing an A"
- "Play a C3 on the downbeat of the kick drum track"
- "Add a whole note G on the bass, bar 1"

**Multiple notes:**
- "On the upbeat of 2, play a C sharp"
- "Walking bass line: E on 1, G on 2, A on 3, B on 4"
- "Eighth note hits on every beat, all C1"
- "Dotted quarter note E on beat 1, then an eighth note G on the and of 2"

**Chords:**
- "C major chord on beat 1, whole note, in the pad track"
- "Am7 on the keys, quarter notes on 1 and 3"

**Velocity/dynamics:**
- "Ghost note E on the and of 4 in the bass"
- "Loud stab on beat 3, F minor"
- "Accent the hit on beat 3"

**Conversational/loose:**
- "Just throw a low E on the one"
- "Add some off-beat stabs on the synth, E minor on the ands"

---

## AbletonOSC API Surface

The relevant OSC messages for MIDI note writing:

| OSC Address | Args | Description |
|---|---|---|
| `/live/clip_slot/create_clip` | `[track, scene, length_beats]` | Create an empty MIDI clip |
| `/live/clip/add/notes` | `[track, scene, note, start, duration, velocity, mute]` | Add a single note to a clip |
| `/live/clip/get/notes` | `[track, scene]` | Read existing notes |
| `/live/clip/remove/notes` | `[track, scene, note, start, duration]` | Remove notes |
| `/live/clip_slot/has_clip` | `[track, scene]` | Check if clip exists |

Key parameters:
- **note**: MIDI number 0-127 (C4 = 60)
- **start**: Position in beats (0.0 = beat 1, 1.0 = beat 2, etc.)
- **duration**: Length in beats (1.0 = quarter note at 4/4)
- **velocity**: 0-127 (64 = default, 127 = max)
- **mute**: 0 or 1

---

## Data Model

### Note Representation (what the LLM produces)

The LLM tool call should produce a list of notes, each with:

```json
{
  "track": 0,
  "clip_slot": 0,
  "clip_length": 4.0,
  "notes": [
    {
      "pitch": 60,
      "start_beat": 0.0,
      "duration": 1.0,
      "velocity": 100
    }
  ]
}
```

### Mapping Reference (for LLM system prompt)

**Note names to MIDI numbers:**
- C4 = 60 (middle C), D4 = 62, E4 = 64, F4 = 65, G4 = 67, A4 = 69, B4 = 71
- Each octave = +/- 12. "Low E" = E2 (40), "high C" = C5 (72)
- Sharps: +1 semitone. Flats: -1 semitone

**Beat positions to start times (in 4/4):**
- Beat 1 = 0.0, Beat 2 = 1.0, Beat 3 = 2.0, Beat 4 = 3.0
- "And of 1" = 0.5, "and of 2" = 1.5, etc.
- "E of 1" = 0.25, "a of 1" = 0.75 (16th note subdivisions)
- "Upbeat of 2" = 1.5 (same as "and of 2")
- "Downbeat" = 0.0

**Duration names to beat values (in 4/4):**
- Whole note = 4.0
- Half note = 2.0
- Quarter note = 1.0
- Eighth note = 0.5
- Sixteenth note = 0.25
- Dotted quarter = 1.5
- Dotted eighth = 0.75
- Triplet quarter = 0.667

**Velocity mappings:**
- Ghost note = 30-40
- Soft/piano = 50-60
- Normal = 90-100
- Loud/accent/forte = 110-120
- Max = 127

**Common chords (root = C, apply transposition):**
- Major: [0, 4, 7]
- Minor: [0, 3, 7]
- 7th: [0, 4, 7, 10]
- m7: [0, 3, 7, 10]
- Maj7: [0, 4, 7, 11]
- dim: [0, 3, 6]
- aug: [0, 4, 8]

---

## Implementation Steps

### 1. Tool Definition (`lib/seshat/tools/definitions.ex`)

Add a `write_midi_notes` tool:

```elixir
%{
  name: "write_midi_notes",
  description: "Write MIDI notes into a clip on a track...",
  parameters: %{
    type: "object",
    properties: %{
      "track" => %{type: "integer", description: "0-indexed track number"},
      "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot (default 0)"},
      "clip_length" => %{type: "number", description: "Clip length in beats (e.g. 4.0 for one bar of 4/4)"},
      "notes" => %{
        type: "array",
        items: %{
          type: "object",
          properties: %{
            "pitch" => %{type: "integer", minimum: 0, maximum: 127},
            "start_beat" => %{type: "number", minimum: 0.0},
            "duration" => %{type: "number", minimum: 0.0},
            "velocity" => %{type: "integer", minimum: 1, maximum: 127}
          },
          required: ["pitch", "start_beat", "duration", "velocity"]
        }
      }
    },
    required: ["track", "notes"]
  }
}
```

### 2. Tool Handler (`lib/seshat/tools/handlers.ex`)

Add a `call("write_midi_notes", ...)` clause that:
1. Defaults `clip_slot` to 0 and `clip_length` to 4.0 if not provided
2. Checks if a clip already exists in the slot (query `/live/clip_slot/has_clip`)
3. Creates the clip if needed (`/live/clip_slot/create_clip`)
4. Sends each note via `/live/clip/add/notes`
5. Returns a summary string

### 3. Registry (`lib/seshat/commands/registry.ex`)

Add an `execute` clause for a new `:write_notes` command. This handles the
OSC sequencing:

```
create clip (if needed) → add note 1 → add note 2 → ... → done
```

### 4. Command Struct (`lib/seshat/commands/command.ex`)

Extend the struct to support the new command type:

```elixir
@type t :: %__MODULE__{
  command: :pan | :volume | :mute | :solo | :create_track | :new_project | :write_notes,
  ...
  clip_slot: non_neg_integer() | nil,
  clip_length: float() | nil,
  notes: [map()] | nil
}
```

### 5. Agent System Prompt (`lib/seshat/agent.ex`)

Add MIDI note context to the system prompt so the LLM knows:
- Note name → MIDI number mapping
- Beat position → start time mapping
- Duration name → beat value mapping
- Velocity → dynamics mapping
- Chord intervals
- Default assumptions (octave 3-4 for bass, octave 4-5 for melody, clip_slot 0, etc.)

---

## Design Decisions

### Clip slot handling
- Default to clip slot 0 (first scene) unless the user specifies otherwise
- If a clip already exists, add notes to it (don't replace)
- If no clip exists, create one with the appropriate length

### What the LLM does vs. what the code does
- **LLM resolves**: note names → MIDI numbers, beat references → float positions,
  duration names → float values, dynamics → velocity integers, track names → indices,
  chords → individual note arrays
- **Code handles**: OSC message sequencing, clip creation, defaults, validation

### Clip length inference
- The LLM should set `clip_length` based on the notes being written
- If all notes fit in 4 beats, use 4.0 (one bar)
- If notes span multiple bars, use the appropriate length

### Bars and scenes
- For POC, we target clip slot 0 (scene 1) only
- Multi-bar writing puts everything in one clip of the right length
- Multi-scene support (arrangement-style writing) is a future feature

---

## Files to Modify

1. `lib/seshat/commands/command.ex` — add new fields
2. `lib/seshat/commands/registry.ex` — add `:write_notes` execution
3. `lib/seshat/tools/definitions.ex` — add `write_midi_notes` tool schema
4. `lib/seshat/tools/handlers.ex` — add handler clause
5. `lib/seshat/agent.ex` — update system prompt with MIDI context

## Files to Potentially Add

- `lib/seshat/mcp/tools/write_midi_notes.ex` — MCP tool module (if following existing pattern)

---

## Open Questions

1. **AbletonOSC note API** — Need to verify the exact OSC addresses and argument
   order against the AbletonOSC source. The addresses above are based on the
   documented API but should be confirmed against the installed version.

2. **Clip creation race condition** — After creating a clip, do we need a small
   delay before writing notes? May need to query back to confirm clip exists.

3. **Quantization** — Should we snap notes to the nearest grid position, or trust
   the LLM to produce clean values? For POC, trust the LLM.

4. **Existing clip behavior** — When a clip already has notes and the user says
   "add a note on beat 3", we should add (not replace). But what about "write a
   bass line on the bass track" — should that clear first? For POC, always add.
