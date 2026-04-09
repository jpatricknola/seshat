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
      name: "delete_track",
      description:
        "Delete a track from the Ableton Live session. " <>
          "Track indices are 0-based: 'track 1' = index 0. " <>
          "Use get_session_state first to confirm the track index.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number to delete"}
        },
        required: ["track"]
      }
    },
    %{
      name: "duplicate_track",
      description:
        "Duplicate a track in the Ableton Live session (copies the track and all its clips/devices). " <>
          "Track indices are 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number to duplicate"}
        },
        required: ["track"]
      }
    },
    %{
      name: "set_track_name",
      description: "Rename a track in Ableton Live. Track indices are 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "name" => %{type: "string", description: "New name for the track"}
        },
        required: ["track", "name"]
      }
    },
    %{
      name: "set_tempo",
      description:
        "Set the song tempo in Ableton Live. " <>
          "Value is in BPM (beats per minute). Typical range: 20-999.",
      parameters: %{
        type: "object",
        properties: %{
          "bpm" => %{type: "number", minimum: 20.0, maximum: 999.0, description: "Tempo in BPM"}
        },
        required: ["bpm"]
      }
    },
    %{
      name: "start_playing",
      description: "Start playback in Ableton Live.",
      parameters: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "stop_playing",
      description: "Stop playback in Ableton Live.",
      parameters: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "set_metronome",
      description: "Turn the metronome on or off in Ableton Live.",
      parameters: %{
        type: "object",
        properties: %{
          "enabled" => %{type: "boolean", description: "true = on, false = off"}
        },
        required: ["enabled"]
      }
    },
    %{
      name: "set_track_arm",
      description:
        "Arm or disarm a track for recording in Ableton Live. " <>
          "Track indices are 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "armed" => %{type: "boolean", description: "true = armed, false = disarmed"}
        },
        required: ["track", "armed"]
      }
    },
    # --- Undo / Redo ---
    %{
      name: "undo",
      description: "Undo the last action in Ableton Live.",
      parameters: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "redo",
      description: "Redo the last undone action in Ableton Live.",
      parameters: %{type: "object", properties: %{}, required: []}
    },
    # --- Clip control ---
    %{
      name: "fire_clip",
      description:
        "Launch/fire a clip in Ableton Live. " <>
          "Track indices are 0-based. Clip slot (scene) is 0-based: scene 1 = 0.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot"}
        },
        required: ["track", "clip_slot"]
      }
    },
    %{
      name: "stop_clip",
      description:
        "Stop a playing clip in Ableton Live. " <>
          "Track indices are 0-based. Clip slot (scene) is 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot"}
        },
        required: ["track", "clip_slot"]
      }
    },
    %{
      name: "delete_clip",
      description: "Delete a clip from a clip slot in Ableton Live.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot"}
        },
        required: ["track", "clip_slot"]
      }
    },
    %{
      name: "duplicate_clip",
      description:
        "Duplicate a clip to another slot in Ableton Live.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "Source track (0-indexed)"},
          "clip_slot" => %{type: "integer", description: "Source scene/clip slot (0-indexed)"},
          "target_track" => %{type: "integer", description: "Target track (0-indexed)"},
          "target_clip_slot" => %{type: "integer", description: "Target scene/clip slot (0-indexed)"}
        },
        required: ["track", "clip_slot", "target_track", "target_clip_slot"]
      }
    },
    %{
      name: "set_clip_name",
      description: "Rename a clip in Ableton Live.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot"},
          "name" => %{type: "string", description: "New name for the clip"}
        },
        required: ["track", "clip_slot", "name"]
      }
    },
    # --- Scene control ---
    %{
      name: "fire_scene",
      description:
        "Launch/fire an entire scene (row of clips) in Ableton Live. " <>
          "Scene indices are 0-based: scene 1 = 0.",
      parameters: %{
        type: "object",
        properties: %{
          "scene" => %{type: "integer", description: "0-indexed scene number"}
        },
        required: ["scene"]
      }
    },
    %{
      name: "create_scene",
      description: "Create a new scene in Ableton Live. Use index -1 to append at the end.",
      parameters: %{
        type: "object",
        properties: %{
          "index" => %{type: "integer", description: "Position to insert scene (-1 = end)"}
        },
        required: ["index"]
      }
    },
    %{
      name: "delete_scene",
      description: "Delete a scene from the Ableton Live session. Scene indices are 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "scene" => %{type: "integer", description: "0-indexed scene number to delete"}
        },
        required: ["scene"]
      }
    },
    %{
      name: "duplicate_scene",
      description: "Duplicate a scene in Ableton Live. Scene indices are 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "scene" => %{type: "integer", description: "0-indexed scene number to duplicate"}
        },
        required: ["scene"]
      }
    },
    %{
      name: "set_scene_name",
      description: "Rename a scene in Ableton Live. Scene indices are 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "scene" => %{type: "integer", description: "0-indexed scene number"},
          "name" => %{type: "string", description: "New name for the scene"}
        },
        required: ["scene", "name"]
      }
    },
    # --- Loop control ---
    %{
      name: "set_loop",
      description:
        "Turn looping on or off and optionally set the loop range in Ableton Live. " <>
          "Loop start and length are in beats (e.g. bar 5 in 4/4 = beat 16.0, 4 bars = 16.0 beats).",
      parameters: %{
        type: "object",
        properties: %{
          "enabled" => %{type: "boolean", description: "true = loop on, false = loop off"},
          "start" => %{type: "number", description: "Loop start position in beats (optional)"},
          "length" => %{type: "number", description: "Loop length in beats (optional)"}
        },
        required: ["enabled"]
      }
    },
    # --- View selection ---
    %{
      name: "select_track",
      description: "Select a track in Ableton Live's UI. Track indices are 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"}
        },
        required: ["track"]
      }
    },
    %{
      name: "select_scene",
      description: "Select a scene in Ableton Live's UI. Scene indices are 0-based.",
      parameters: %{
        type: "object",
        properties: %{
          "scene" => %{type: "integer", description: "0-indexed scene number"}
        },
        required: ["scene"]
      }
    },
    # --- Notes ---
    %{
      name: "remove_notes",
      description:
        "Remove MIDI notes from a clip in Ableton Live. " <>
          "With no range specified, removes ALL notes. " <>
          "Optionally specify a pitch and time range to remove specific notes.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot (default 0)"},
          "start_pitch" => %{type: "integer", description: "Lowest pitch to remove (default 0)"},
          "pitch_span" => %{type: "integer", description: "Number of pitches to span (default 128 = all)"},
          "start_time" => %{type: "number", description: "Start time in beats (default 0.0)"},
          "time_span" => %{type: "number", description: "Time span in beats (default: entire clip)"}
        },
        required: ["track"]
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
