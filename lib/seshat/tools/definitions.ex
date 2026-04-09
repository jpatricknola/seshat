defmodule Seshat.Tools.Definitions do
  @moduledoc """
  Tool schemas shared by both MCP and API key modes.

  Each tool is defined once in a format-agnostic structure, then serialized
  to either MCP or Anthropic API format as needed.
  """

  @tools [
    %{
      name: "set_track_pan",
      description:
        "Set the stereo panning position of a track in Ableton Live. " <>
          "Track indices are 0-based: 'track 1' = index 0. " <>
          "Value ranges from -1.0 (full left) through 0.0 (center) to 1.0 (full right). " <>
          "Common mappings: 'hard left' = -1.0, 'slightly left' = -0.3, 'center' = 0.0, 'hard right' = 1.0.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "value" => %{
            type: "number",
            minimum: -1.0,
            maximum: 1.0,
            description: "Pan position. -1.0 = full left, 0.0 = center, 1.0 = full right"
          }
        },
        required: ["track", "value"]
      }
    },
    %{
      name: "set_track_volume",
      description:
        "Set the volume level of a track in Ableton Live. " <>
          "Track indices are 0-based: 'track 1' = index 0. " <>
          "Value ranges from 0.0 (silence) to 1.0 (full volume). " <>
          "Common mappings: 'off'/'silent' = 0.0, 'half' = 0.5, 'full'/'max' = 1.0.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "value" => %{
            type: "number",
            minimum: 0.0,
            maximum: 1.0,
            description: "Volume level. 0.0 = silence, 1.0 = full volume"
          }
        },
        required: ["track", "value"]
      }
    },
    %{
      name: "set_track_mute",
      description:
        "Mute or unmute a track in Ableton Live. " <>
          "Track indices are 0-based: 'track 1' = index 0.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "muted" => %{type: "boolean", description: "true = muted, false = unmuted"}
        },
        required: ["track", "muted"]
      }
    },
    %{
      name: "set_track_solo",
      description:
        "Solo or unsolo a track in Ableton Live. " <>
          "Track indices are 0-based: 'track 1' = index 0.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "soloed" => %{type: "boolean", description: "true = soloed, false = unsoloed"}
        },
        required: ["track", "soloed"]
      }
    },
    %{
      name: "create_track",
      description:
        "Create a new track in Ableton Live and give it a name. " <>
          "Use 'midi' for software instruments (synths, samplers, drum machines, keys, pads). " <>
          "Use 'audio' for recording external sources (vocals, guitar, bass, field recordings).",
      parameters: %{
        type: "object",
        properties: %{
          "track_type" => %{
            type: "string",
            enum: ["midi", "audio"],
            description: "midi = software instruments, audio = external recording"
          },
          "name" => %{
            type: "string",
            description: "Short descriptive label for the track (e.g. 'Drums', 'Lead Synth', 'Vocals')"
          }
        },
        required: ["track_type", "name"]
      }
    },
    %{
      name: "create_project",
      description:
        "Start a new Ableton Live project with a set of tracks. " <>
          "Opens a fresh set and creates the specified tracks. " <>
          "Use 'midi' for software instruments, 'audio' for external recording.",
      parameters: %{
        type: "object",
        properties: %{
          "tracks" => %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                "track_type" => %{
                  type: "string",
                  enum: ["midi", "audio"],
                  description: "midi = software instruments, audio = external recording"
                },
                "name" => %{type: "string", description: "Short descriptive label"}
              },
              required: ["track_type", "name"]
            },
            description: "List of tracks to create in the new project"
          }
        },
        required: ["tracks"]
      }
    },
    %{
      name: "write_midi_notes",
      description:
        "Write MIDI notes into a clip on a track in Ableton Live. " <>
          "Creates a new clip in the specified slot if one doesn't exist. " <>
          "Notes are added to the clip (existing notes are preserved). " <>
          "Track indices are 0-based. Clip slot defaults to 0 (first scene). " <>
          "Pitch is MIDI note number (0-127): C4 (middle C) = 60, D4 = 62, E4 = 64, F4 = 65, G4 = 67, A4 = 69, B4 = 71. Each octave = 12 semitones. Sharps = +1, flats = -1. " <>
          "start_beat is position in beats from clip start: beat 1 = 0.0, beat 2 = 1.0, 'and of 1' = 0.5, 'e of 1' = 0.25. " <>
          "duration is length in beats: whole = 4.0, half = 2.0, quarter = 1.0, eighth = 0.5, sixteenth = 0.25, dotted quarter = 1.5. " <>
          "velocity is 1-127: ghost note = 30, soft = 50, normal = 100, loud/accent = 120, max = 127. " <>
          "For chords, add multiple notes with the same start_beat and duration. " <>
          "Common chord intervals from root: major [0,4,7], minor [0,3,7], 7th [0,4,7,10], m7 [0,3,7,10], maj7 [0,4,7,11]. " <>
          "Use get_session_state first to resolve track names to indices and to check the current time signature.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number (must be a MIDI track)"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot. Defaults to 0 if omitted."},
          "clip_length" => %{
            type: "number",
            description:
              "Clip length in beats. E.g. 4.0 = one bar of 4/4, 3.0 = one bar of 3/4. " <>
                "Only used when creating a new clip. Should be >= the latest note end time."
          },
          "notes" => %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                "pitch" => %{type: "integer", minimum: 0, maximum: 127, description: "MIDI note number. C4 = 60."},
                "start_beat" => %{type: "number", minimum: 0.0, description: "Start position in beats from clip start. Beat 1 = 0.0."},
                "duration" => %{type: "number", minimum: 0.01, description: "Note length in beats. Quarter note = 1.0."},
                "velocity" => %{type: "integer", minimum: 1, maximum: 127, description: "Note velocity. Normal = 100."}
              },
              required: ["pitch", "start_beat", "duration", "velocity"]
            },
            description: "Array of MIDI notes to write"
          }
        },
        required: ["track", "notes"]
      }
    },
    %{
      name: "get_session_state",
      description:
        "Get the current state of all tracks in the Ableton Live session. " <>
          "Returns tempo, time signature, track names, indices, volume, pan, mute, and solo status. " <>
          "Use this before making relative adjustments ('turn it up a bit'), " <>
          "when you need to know what tracks exist, or before writing MIDI notes.",
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    }
  ]

  @doc "Returns all tool definitions as format-agnostic maps."
  def all, do: @tools

  @doc "Returns tool definitions in Anthropic API tool use format."
  def to_anthropic_tools do
    Enum.map(@tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters
      }
    end)
  end
end
