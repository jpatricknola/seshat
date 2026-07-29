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
          "Common mappings: 'hard left' = -1.0, 'slightly left' = -0.3, 'center' = 0.0, 'hard right' = 1.0. " <>
          "The reply echoes the position as Live displays it (50L / C / 50R) — check it against " <>
          "what the user asked for.",
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
          "The 0.0-1.0 range is Live's fader scale, which is NOT linear and does NOT top out at " <>
          "unity: 0.85 is unity gain (0 dB, where a new track sits) and 1.0 is +6 dB of boost. " <>
          "Common mappings: 'off'/'silent' = 0.0, 'quiet' = 0.6 (about -10 dB), " <>
          "'normal'/'unity'/'full' = 0.85 (0 dB), 'max'/'boost' = 1.0 (+6 dB). " <>
          "Prefer 0.85 for 'turn it up all the way' unless the user actually wants it pushed " <>
          "past unity. The reply echoes the approximate dB value — check it against what the " <>
          "user asked for.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "value" => %{
            type: "number",
            minimum: 0.0,
            maximum: 1.0,
            description:
              "Fader position. 0.0 = silence, 0.85 = unity gain (0 dB), 1.0 = +6 dB (maximum boost)"
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
            description:
              "Short descriptive label for the track (e.g. 'Drums', 'Lead Synth', 'Vocals')"
          }
        },
        required: ["track_type", "name"]
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
          "Use get_session_state first to resolve track names to indices and to check the current time signature. " <>
          "Use get_clip_slots first to pick an empty slot on an actually-MIDI track: writing to " <>
          "an audio track or a group track is rejected with an error and nothing is written. " <>
          "Clip slot N sits in scene N — slot 0 is the first scene. " <>
          "Optionally pass name to label the clip. After the write, Live's view follows " <>
          "automatically — the clip is selected with the note editor open — so no select_track " <>
          "call is needed to show the result.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{
            type: "integer",
            description: "0-indexed track number (must be a MIDI track)"
          },
          "clip_slot" => %{
            type: "integer",
            description: "0-indexed scene/clip slot. Defaults to 0 if omitted."
          },
          "name" => %{
            type: "string",
            description:
              "Optional clip name, shown on the clip in Live's Session grid and in " <>
                "get_clip_slots readouts. Only used when creating or writing the clip — omit " <>
                "to leave it unnamed (there is no auto-generated fallback); set_clip_name " <>
                "renames later."
          },
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
                "pitch" => %{
                  type: "integer",
                  minimum: 0,
                  maximum: 127,
                  description: "MIDI note number. C4 = 60."
                },
                "start_beat" => %{
                  type: "number",
                  minimum: 0.0,
                  description: "Start position in beats from clip start. Beat 1 = 0.0."
                },
                "duration" => %{
                  type: "number",
                  minimum: 0.01,
                  description: "Note length in beats. Quarter note = 1.0."
                },
                "velocity" => %{
                  type: "integer",
                  minimum: 1,
                  maximum: 127,
                  description: "Note velocity. Normal = 100."
                }
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
    %{
      name: "capture_midi",
      description:
        "Retroactively capture the MIDI the user just played into a new Session clip — " <>
          "Ableton Live keeps a buffer of recent MIDI input even when nothing was armed or " <>
          "recording, so this is the \"keep that\" move when the user stumbles onto something " <>
          "good while noodling. Call it right away: the buffer is ephemeral, and re-playing an " <>
          "idea never feels the same. Nothing about placement is yours to choose — Live itself " <>
          "decides which track(s) the material belongs to (the tracks that received the MIDI) " <>
          "and where the clip lands; the only parameter is an optional name for what it keeps. " <>
          "The reply reports exactly which clip(s) appeared (track, slot, length, whether Live " <>
          "started them playing) and whether Live adjusted the song tempo to match the playing " <>
          "— it does that when the transport was stopped. MIDI only; audio can't be captured. " <>
          "If nothing MIDI was played since the last capture, the reply says nothing appeared. " <>
          "The view follows the capture automatically: the new clip is selected with the note " <>
          "editor open, even mid-playback. " <>
          "Follow up with get_clip_notes to inspect what was kept, or set_clip_name to rename it.",
      parameters: %{
        type: "object",
        properties: %{
          "name" => %{
            type: "string",
            description:
              "Optional name for the captured clip(s), shown in Live's Session grid. Omit to " <>
                "leave them unnamed."
          }
        },
        required: []
      }
    },
    %{
      name: "record_clip",
      description:
        "Record a take into a chosen Session clip slot in Ableton Live — the deliberate " <>
          "\"record me eight bars on the keys\" move, and the only way to record audio " <>
          "(capture_midi is retroactive and MIDI-only). Track and slot indices are 0-based; " <>
          "the slot must be empty — use get_clip_slots first to pick a free slot, or " <>
          "delete_clip a bad take. Arms the track automatically if it isn't armed (the reply " <>
          "says so). With bars given, Live records exactly that many bars of the current time " <>
          "signature, stops recording by itself, and leaves the clip looping — no stop call " <>
          "needed. Without bars the take runs until stop_recording. Timing: if the transport " <>
          "is already playing, recording starts at the next launch-quantization boundary " <>
          "(usually the next bar) — start playback first when the user wants a predictable " <>
          "punch-in; from a stopped transport it starts immediately, so make sure the user is " <>
          "ready *before* calling. Audio tracks record whatever input is routed to them in " <>
          "Live — Seshat cannot choose or check the input, so a silent take usually means the " <>
          "input isn't set. The reply says whether recording is running or queued for the " <>
          "boundary. The view follows: the slot is selected in the Session grid, turning red " <>
          "as it records.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{
            type: "integer",
            description: "0-indexed scene/clip slot — must be empty"
          },
          "bars" => %{
            type: "number",
            description:
              "How many bars to record, in the set's current time signature. Omit for an " <>
                "open-ended take finished later with stop_recording."
          }
        },
        required: ["track", "clip_slot"]
      }
    },
    %{
      name: "stop_recording",
      description:
        "Finish a take that is recording in a Session clip slot (started by record_clip, or " <>
          "any clip Ableton Live is session-recording): recording ends at the next " <>
          "launch-quantization boundary — a musically aligned loop end — and the clip drops " <>
          "straight into looped playback; it keeps playing. Also ends a fixed-length take " <>
          "early. Track and slot are 0-based — the ones record_clip's reply named; " <>
          "get_clip_slots marks the recording slot if unsure. Errors if nothing is recording " <>
          "there. To scrap a take instead: stop it, then delete_clip.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot"}
        },
        required: ["track", "clip_slot"]
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
          "Track indices are 0-based. Clip slot N sits in scene N, also 0-based: scene 1 = slot 0. " <>
          "Use get_clip_slots first to see which slots actually hold clips: firing an empty slot " <>
          "would stop the track rather than start anything, so this tool rejects it with an " <>
          "error. Use stop_clip if stopping was the intent.",
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
          "Track indices are 0-based. Clip slot N sits in scene N, also 0-based: scene 1 = slot 0. " <>
          "Use get_clip_slots first to see which clips are actually playing.",
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
      description:
        "Delete a clip from a clip slot in Ableton Live. " <>
          "Clip slot N sits in scene N, both 0-based: scene 1 = slot 0. " <>
          "Use get_clip_slots first to confirm which slot holds the clip you mean to delete.",
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
        "Duplicate a clip to another slot in Ableton Live. " <>
          "Clip slot N sits in scene N, both 0-based: scene 1 = slot 0. " <>
          "Use get_clip_slots first to find the source clip and an empty target slot — " <>
          "duplicating onto an occupied slot overwrites it.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "Source track (0-indexed)"},
          "clip_slot" => %{type: "integer", description: "Source scene/clip slot (0-indexed)"},
          "target_track" => %{type: "integer", description: "Target track (0-indexed)"},
          "target_clip_slot" => %{
            type: "integer",
            description: "Target scene/clip slot (0-indexed)"
          }
        },
        required: ["track", "clip_slot", "target_track", "target_clip_slot"]
      }
    },
    %{
      name: "set_clip_name",
      description:
        "Rename a clip in Ableton Live. " <>
          "Clip slot N sits in scene N, both 0-based: scene 1 = slot 0. " <>
          "Use get_clip_slots first to confirm which slot holds the clip.",
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
    %{
      name: "get_clip_properties",
      description:
        "Read one clip's playback properties: clip type (MIDI/audio), name, length in beats, " <>
          "loop on/off and loop brace (loop_start/loop_end), play markers " <>
          "(start_marker/end_marker), launch mode and quantization, legato, velocity amount — " <>
          "plus gain (with its dB display value), warp mode, and warping for audio clips. " <>
          "Track and clip_slot are 0-based; slot N sits in scene N. All positions count from " <>
          "the clip's own start (position 0), in beats — except on an audio clip with warping " <>
          "off, where Live counts them in seconds; the reply names the unit it is reporting. " <>
          "Use get_clip_slots first to find which slots " <>
          "hold clips, and this tool before set_clip_properties to see the current values — " <>
          "e.g. what length and loop brace Live inferred for a captured clip.",
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
      name: "set_clip_properties",
      description:
        "Set a clip's own loop brace, play markers, launch behavior, or (audio clips only) " <>
          "gain/warp. This is the clip's OWN loop — distinct from set_loop, which moves the " <>
          "song's global arrangement loop. Track and clip_slot are 0-based; slot N sits in " <>
          "scene N. All properties are optional — send only what you're changing, at least " <>
          "one. Positions are in beats from the clip's start — except on an audio clip with " <>
          "warping off, where Live counts them in seconds; call get_clip_properties first, " <>
          "which names the unit. To loop a section: set looping " <>
          "true with loop_start/loop_end, and usually start_marker to the loop start so launch " <>
          "begins there — note loop_start/loop_end only act as the loop brace while looping is " <>
          "on (while off, Live treats them as the play start/end markers). To trim or extend a " <>
          "non-looping clip, set start_marker/end_marker. There is no direct length setter — " <>
          "length follows from the markers (or the loop while looping), and the reply echoes " <>
          "every value Live actually applied (each write is verified by re-read): check it " <>
          "matched the intent. launch_mode: 0=Trigger, 1=Gate, 2=Toggle, 3=Repeat. " <>
          "launch_quantization: 0=Global, 1=None, 2=8 bars, 3=4 bars, 4=2 bars, 5=1 bar, " <>
          "6=1/2, 7=1/2T, 8=1/4, 9=1/4T, 10=1/8, 11=1/8T, 12=1/16, 13=1/16T, 14=1/32. " <>
          "velocity_amount is 0.0–1.0. Audio only — gain: nonlinear 0.0–1.0, trust the dB the " <>
          "reply echoes rather than the number; warp_mode: 0=Beats, 1=Tones, 2=Texture, " <>
          "3=Re-Pitch, 4=Complex, 6=Complex Pro; warping: on/off. Audio-only properties on a " <>
          "MIDI clip are rejected with an error. Use get_clip_properties first to see current " <>
          "values.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot"},
          "looping" => %{
            type: "boolean",
            description: "true = the clip loops over its brace, false = it plays through once"
          },
          "loop_start" => %{
            type: "number",
            minimum: 0,
            description: "Loop brace start, in beats from the clip's start"
          },
          "loop_end" => %{
            type: "number",
            minimum: 0,
            description: "Loop brace end, in beats from the clip's start"
          },
          "start_marker" => %{
            type: "number",
            minimum: 0,
            description: "Where playback begins on launch, in beats from the clip's start"
          },
          "end_marker" => %{
            type: "number",
            minimum: 0,
            description: "Where a non-looping clip stops, in beats from the clip's start"
          },
          "launch_mode" => %{
            type: "integer",
            enum: [0, 1, 2, 3],
            description: "0=Trigger, 1=Gate, 2=Toggle, 3=Repeat"
          },
          "launch_quantization" => %{
            type: "integer",
            minimum: 0,
            maximum: 14,
            description:
              "0=Global, 1=None, 2=8 bars, 3=4 bars, 4=2 bars, 5=1 bar, 6=1/2, 7=1/2T, 8=1/4, " <>
                "9=1/4T, 10=1/8, 11=1/8T, 12=1/16, 13=1/16T, 14=1/32"
          },
          "legato" => %{
            type: "boolean",
            description: "true = a relaunch continues from the current playback position"
          },
          "velocity_amount" => %{
            type: "number",
            minimum: 0.0,
            maximum: 1.0,
            description: "How much MIDI velocity affects clip volume, 0.0–1.0"
          },
          "gain" => %{
            type: "number",
            minimum: 0.0,
            maximum: 1.0,
            description:
              "Audio clips only. Nonlinear 0.0–1.0 — trust the dB value the reply echoes"
          },
          "warp_mode" => %{
            type: "integer",
            enum: [0, 1, 2, 3, 4, 6],
            description:
              "Audio clips only. 0=Beats, 1=Tones, 2=Texture, 3=Re-Pitch, 4=Complex, " <>
                "6=Complex Pro"
          },
          "warping" => %{
            type: "boolean",
            description: "Audio clips only. true = the clip follows the song tempo"
          }
        },
        required: ["track", "clip_slot"]
      }
    },
    # --- Scene control ---
    %{
      name: "fire_scene",
      description:
        "Launch/fire an entire scene (row of clips) in Ableton Live. " <>
          "Scene indices are 0-based: scene 1 = 0. " <>
          "Use get_clip_slots first to resolve a scene name ('the chorus') to its index " <>
          "and see what each scene would launch.",
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
        "Turn the song's global loop on or off and optionally set its range in Ableton Live. " <>
          "This is the arrangement/transport loop that spans the whole song — NOT a clip's own " <>
          "loop brace; for 'loop this clip' or 'loop the good two bars' use " <>
          "set_clip_properties. " <>
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
          "Optionally specify a pitch and time range to remove specific notes. " <>
          "Track indices are 0-based, and clip slot N sits in scene N: scene 1 = slot 0.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot (default 0)"},
          "start_pitch" => %{type: "integer", description: "Lowest pitch to remove (default 0)"},
          "pitch_span" => %{
            type: "integer",
            description: "Number of pitches to span (default 128 = all)"
          },
          "start_time" => %{type: "number", description: "Start time in beats (default 0.0)"},
          "time_span" => %{
            type: "number",
            description: "Time span in beats (default: entire clip)"
          }
        },
        required: ["track"]
      }
    },
    %{
      name: "get_clip_notes",
      description:
        "Read the MIDI notes in a clip in Ableton Live. " <>
          "Track indices are 0-based; clip slot N sits in scene N (scene 1 = slot 0) and " <>
          "clip_slot defaults to 0. When talking to the user, refer to tracks and scenes by " <>
          "name or by their 1-based numbers as shown in Live, not by these indices. " <>
          "Returns every note as pitch (with note name), start beat, duration in beats, " <>
          "velocity, and whether the note is muted, plus the clip's name and length. " <>
          "ALWAYS call this before editing existing material — transposing, fixing a note, " <>
          "humanizing velocities, adding to an existing part — so you work with what is " <>
          "actually there instead of overwriting it. " <>
          "The typical edit loop is: get_clip_notes → decide changes → remove_notes " <>
          "(with a pitch/time range) → write_midi_notes. " <>
          "Optionally restrict the read to a pitch/time window using the same range " <>
          "parameters remove_notes takes. " <>
          "Use get_clip_slots first to see which slots hold MIDI clips worth reading.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "clip_slot" => %{type: "integer", description: "0-indexed scene/clip slot (default 0)"},
          "start_pitch" => %{type: "integer", description: "Lowest pitch to include (default 0)"},
          "pitch_span" => %{
            type: "integer",
            description: "Number of pitches to span (default 128 = all)"
          },
          "start_time" => %{type: "number", description: "Start time in beats (default 0.0)"},
          "time_span" => %{
            type: "number",
            description: "Time span in beats (default: entire clip)"
          }
        },
        required: ["track"]
      }
    },
    # --- Sound catalog ---
    %{
      name: "search_library",
      description:
        "Search the sound catalog: a persistent, tag-aware index of every instrument, preset, " <>
          "drum kit and effect in this user's Ableton Live library. " <>
          "PREFER THIS OVER list_browser_items — it is instant (no round-trip to Live), it " <>
          "searches folder paths and tags as well as names, and it works even when Ableton is " <>
          "closed. Fall back to list_browser_items only when this returns nothing. " <>
          "Most presets carry tags written by Ableton's own sound designers. The tag vocabulary " <>
          "is this user's library, not a fixed list — reindex_library and every truncated " <>
          "result report the real tags with counts; trust those over guesses. " <>
          "Put the kind of sound in `query` and character words in `tags`: tags are scored, not " <>
          "strict — at least one must match, and results carrying more of them rank higher, so " <>
          "guessing ['Analog', 'Warm'] still returns the Analog matches even if 'Warm' isn't a " <>
          "real tag here. If nothing comes back, the reply names which tag failed and lists real " <>
          "tags carried by what your query alone matched — retry with one of those rather than " <>
          "abandoning the search. " <>
          "PASS `category` WHENEVER YOU KNOW THE KIND: without it a name match wins on words " <>
          "alone, so 'electric piano' puts the Electric Piano Amp effect above every actual " <>
          "piano. Use 'sounds' or 'instruments' for something to play, 'audio_effects' for " <>
          "something to process it with. " <>
          "WHEN CHOOSING: weigh the musical context — the tempo, the other tracks and the genre " <>
          "from get_session_state and from what the user has said — and present the top 3–5 " <>
          "candidates with a one-line reason each, then let the user pick. Only load the first " <>
          "hit without asking if the user told you to just pick one — then say why in a phrase " <>
          "and name the runner-up, so redirecting costs the user one sentence. " <>
          "Each result is one preset: `name — tags [folder paths] (uri)`. A preset Live files " <>
          "under several devices lists all of them, so 'Analog/Synth Lead · Operator/Synth Lead' " <>
          "is a single sound either device can play — not two options. The uri goes straight to " <>
          "load_device. " <>
          "If the catalog is empty, say so and offer to run reindex_library.",
      parameters: %{
        type: "object",
        properties: %{
          "query" => %{
            type: "string",
            description:
              "Case-insensitive words that must ALL appear somewhere in the item's name, folder " <>
                "path, tags or description (e.g. 'bass', 'analog lead', '808'). Omit to browse " <>
                "purely by tag and category."
          },
          "tags" => %{
            type: "array",
            items: %{type: "string"},
            description:
              "Character or kind tags, e.g. ['Analog', 'Soft']. At least one must match; the " <>
                "more that match, the higher the result ranks. Case-insensitive, " <>
                "punctuation-insensitive substrings — 'bass' matches '808 Bass', 'hi-hat' " <>
                "matches 'Closed Hihat'."
          },
          "category" => %{
            type: "string",
            enum: [
              "instruments",
              "sounds",
              "drums",
              "audio_effects",
              "midi_effects",
              "plugins",
              "user_library"
            ],
            description:
              "Restrict to one part of the browser. 'sounds' = ready-made instrument presets, " <>
                "'instruments' = Live's synths and samplers themselves, 'drums' = drum kits, " <>
                "'audio_effects'/'midi_effects' = effects, 'plugins' = third-party VST/AU, " <>
                "'user_library' = the user's own saved presets. Omit to search everything. " <>
                "Raw samples are not in the catalog — use list_browser_items for those."
          },
          "max_results" => %{
            type: "integer",
            minimum: 1,
            maximum: 50,
            description: "Maximum items to return. Defaults to 15."
          }
        },
        required: []
      }
    },
    %{
      name: "reindex_library",
      description:
        "Rebuild the sound catalog that search_library reads: walk Live's whole browser and " <>
          "merge in the tags from Ableton's own preset database, then save the result to disk. " <>
          "Run this once before the first search_library call, and again after the user " <>
          "installs new Packs, adds plugins, or saves their own presets — not otherwise. " <>
          "Ableton Live must be running. It takes up to a minute and Live's UI may be " <>
          "unresponsive while it runs, so tell the user before starting it. " <>
          "The catalog persists across restarts, so this is not something to repeat per session.",
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      }
    },
    # --- Browser / device loading ---
    %{
      name: "list_browser_items",
      description:
        "Search Ableton Live's browser directly for instruments, effects, sounds, or samples " <>
          "that can be loaded onto a track. Returns each match as a name, its folder path, and " <>
          "a `uri` — the uri is what load_device needs. " <>
          "TRY search_library FIRST: it covers the same items with tags and no round-trip to " <>
          "Live. Use this one when search_library comes back empty, when the catalog has never " <>
          "been built, or for raw samples (which the catalog does not index). " <>
          "A MIDI track makes no sound until an instrument is loaded onto it, so a normal " <>
          "workflow is: create_track (midi) → list_browser_items (instruments) → load_device → " <>
          "write_midi_notes → fire_clip. " <>
          "ALWAYS call this before load_device and use a uri from the results — never guess or " <>
          "invent a uri, and never reuse one from an earlier session. " <>
          "Categories: 'instruments' = Live's synths and samplers (Operator, Wavetable, Analog, " <>
          "Drum Rack, Simpler); 'sounds' = ready-made instrument presets grouped by kind of " <>
          "sound (Bass, Pad, Lead, Keys); 'drums' = drum kits and drum-rack presets; " <>
          "'audio_effects' = effects for shaping audio (Reverb, Delay, EQ Eight, Compressor); " <>
          "'midi_effects' = effects that transform MIDI before the instrument (Arpeggiator, " <>
          "Chord, Scale); 'plugins' = installed third-party VST/AU plugins; 'samples' = raw " <>
          "audio samples; 'user_library' = the user's own saved presets and racks. " <>
          "Pass a filter to keep the result list small and relevant — an unfiltered search of a " <>
          "big category returns only the first max_results of many. " <>
          "The first search of a large category (samples, sounds, plugins) can take several " <>
          "seconds while Live indexes it; later searches are fast.",
      parameters: %{
        type: "object",
        properties: %{
          "category" => %{
            type: "string",
            enum: [
              "instruments",
              "sounds",
              "drums",
              "audio_effects",
              "midi_effects",
              "plugins",
              "samples",
              "user_library"
            ],
            description: "Which part of Live's browser to search"
          },
          "filter" => %{
            type: "string",
            description:
              "Case-insensitive substring match on the item name (e.g. 'operator', 'reverb', " <>
                "'808'). Omit or pass \"\" to list everything in the category."
          },
          "max_results" => %{
            type: "integer",
            minimum: 1,
            maximum: 100,
            description: "Maximum items to return. Defaults to 25."
          }
        },
        required: ["category"]
      }
    },
    %{
      name: "load_device",
      description:
        "Load a browser item (instrument, effect, or preset) onto a track in Ableton Live. " <>
          "The uri MUST come from a list_browser_items call — there is no way to construct one. " <>
          "Track indices are 0-based: 'track 1' = index 0. " <>
          "Loading an instrument onto a MIDI track is what makes its MIDI notes audible. " <>
          "Loading an audio effect appends it to the end of the track's device chain, after the " <>
          "instrument, so effects can be stacked by calling this repeatedly. " <>
          "The reply names the device that actually landed on the track — check it matches what " <>
          "you asked for before telling the user it worked. " <>
          "A wrong or unwanted load is not permanent: delete_device removes it, which is how to " <>
          "audition candidates in place (load, listen, delete, load the next). " <>
          "The view follows the load automatically — the new device is selected with its panel " <>
          "open.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{
            type: "integer",
            description: "0-indexed track number to load onto"
          },
          "uri" => %{
            type: "string",
            description: "Browser item uri, exactly as returned by list_browser_items"
          }
        },
        required: ["track", "uri"]
      }
    },
    # --- Device chain / parameters ---
    %{
      name: "get_track_devices",
      description:
        "List the device chain on a track in Ableton Live: every instrument, audio effect, and " <>
          "MIDI effect, in chain order, with its 0-based device index. " <>
          "Track indices are 0-based: 'track 1' = index 0. " <>
          "Use this to see what load_device actually put on a track, to resolve a device name " <>
          "('the reverb') to the device index that get_device_parameters, " <>
          "set_device_parameter, delete_device and bypass_device all need, or to check whether " <>
          "a track has an instrument at all. " <>
          "Racks (e.g. an Instrument Rack preset) appear as a single device — their inner " <>
          "chain is not listed.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"}
        },
        required: ["track"]
      }
    },
    %{
      name: "get_device_parameters",
      description:
        "List every parameter of one device on a track: 0-based parameter index, name, current " <>
          "value, and the min–max range the value must stay within. " <>
          "Track and device indices are 0-based — call get_track_devices first to find the " <>
          "device index. " <>
          "Use this before set_device_parameter to resolve a parameter name ('the filter " <>
          "cutoff') to its index and to learn the legal value range. " <>
          "Values are Ableton's internal units — often normalized 0.0–1.0, but not always; " <>
          "trust the min/max in the output, not an assumption. " <>
          "When talking to the user, refer to tracks and devices by name or 1-based UI number, " <>
          "never raw index.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "device" => %{
            type: "integer",
            description: "0-indexed device on the track, as returned by get_track_devices"
          }
        },
        required: ["track", "device"]
      }
    },
    %{
      name: "set_device_parameter",
      description:
        "Set one parameter of one device on a track in Ableton Live. " <>
          "All indices are 0-based. ALWAYS call get_device_parameters first — it gives the " <>
          "parameter index and the min–max range the value must stay within; values outside " <>
          "the range are clamped by Live. " <>
          "The reply echoes the parameter's new human-readable display value (e.g. '2.5 kHz', " <>
          "'-12 dB') — check it against what the user asked for. " <>
          "For relative changes ('a bit brighter'), read the current value first and move it " <>
          "a small fraction of the range. " <>
          "To switch a whole device on or off (bypass), use bypass_device instead of setting " <>
          "parameter 0 by hand.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "device" => %{
            type: "integer",
            description: "0-indexed device on the track, as returned by get_track_devices"
          },
          "parameter" => %{
            type: "integer",
            description: "0-indexed parameter, as returned by get_device_parameters"
          },
          "value" => %{
            type: "number",
            description: "New value, within the min–max range reported by get_device_parameters"
          }
        },
        required: ["track", "device", "parameter", "value"]
      }
    },
    %{
      name: "delete_device",
      description:
        "Delete a device from a track's chain in Ableton Live — the undo for load_device, and " <>
          "one half of the audition loop: delete the current candidate, load the next, compare " <>
          "by ear. " <>
          "Track and device indices are 0-based — ALWAYS call get_track_devices first to " <>
          "confirm which index is which. " <>
          "Deleting a device shifts every later device's index down by one, so indices noted " <>
          "before the delete are stale; the reply lists the remaining chain with its fresh " <>
          "indices. " <>
          "Regular tracks only — devices on return or master tracks are out of reach. " <>
          "To compare with/without a device instead of removing it, use bypass_device.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "device" => %{
            type: "integer",
            description: "0-indexed device on the track, as returned by get_track_devices"
          }
        },
        required: ["track", "device"]
      }
    },
    %{
      name: "bypass_device",
      description:
        "Switch a device on or off in place. Off is a bypass: the device stays in the chain " <>
          "with all its settings intact but stops processing — the way to A/B a sound with and " <>
          "without it ('here's the drums with the compressor… and without'). " <>
          "enabled: false switches it off, enabled: true brings it back unchanged. " <>
          "Track and device indices are 0-based — call get_track_devices first to find the " <>
          "device index. " <>
          "This toggles the device's own power switch (its parameter 0, 'Device On'), exactly " <>
          "like clicking the device's on/off button in Live. " <>
          "Bypassing an instrument silences its track. Regular tracks only. " <>
          "To remove the device from the chain entirely, use delete_device.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", description: "0-indexed track number"},
          "device" => %{
            type: "integer",
            description: "0-indexed device on the track, as returned by get_track_devices"
          },
          "enabled" => %{
            type: "boolean",
            description: "false bypasses the device, true re-enables it"
          }
        },
        required: ["track", "device", "enabled"]
      }
    },
    %{
      name: "get_session_state",
      description:
        "Get the current state of all tracks in the Ableton Live session. " <>
          "Returns tempo, time signature, the song's key and scale, track names, indices, " <>
          "volume, pan, mute, and solo status, plus the return tracks (name and volume, in " <>
          "send order: return 0 = send A) and the master volume. " <>
          "Return-track indices are their own 0-based space, separate from regular tracks — " <>
          "this is how you resolve 'the reverb send' to the send index set_track_send needs. " <>
          "The key is whatever Live's scale controls are set to — a strong hint about what to " <>
          "write, not gospel, since Live reports C Major when the user has never touched them. " <>
          "Use this before making relative adjustments ('turn it up a bit'), " <>
          "when you need to know what tracks exist, or before writing MIDI notes. " <>
          "Changes made in Ableton's own UI — including tracks added, deleted or " <>
          "reordered by hand — stream in automatically, so this is normally current " <>
          "without asking; pass refresh: true only if the state it reports ever " <>
          "looks wrong. " <>
          "Indices are 0-based but Ableton's UI numbers tracks from 1 — when talking " <>
          "to the user, refer to tracks by name or 1-based UI number, never raw index.",
      parameters: %{
        type: "object",
        properties: %{
          "refresh" => %{
            type: "boolean",
            description:
              "Re-read everything from Ableton before answering, instead of serving the " <>
                "mirrored state. Slower — use only when the reported state looks wrong."
          }
        },
        required: []
      }
    },
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
          "clip slots). " <>
          "When talking to the user, refer to tracks and scenes by name or 1-based " <>
          "UI number, never raw index.",
      parameters: %{type: "object", properties: %{}, required: []}
    },
    # --- Sends, return tracks, master ---
    #
    # Everything below except set_track_send / get_track_sends' send reads needs
    # Seshat's return_track.py extension to AbletonOSC (mix abletonosc.install).
    %{
      name: "set_track_send",
      description:
        "Set a send level on a regular track — how much of that track's signal feeds a return " <>
          "track (shared reverb, delay, etc.). " <>
          "Track indices are 0-based: 'track 1' = index 0. " <>
          "Sends are 0-indexed in return-track order: send 0 = send A = the first return track, " <>
          "send 1 = send B = the second. " <>
          "Use get_session_state to see the return tracks and resolve 'the reverb send' to a " <>
          "send index, and get_track_sends to read current levels before relative changes. " <>
          "Value is 0.0 (off) to 1.0 (maximum). For 'a little reverb' start around 0.25–0.4; " <>
          "0.6+ is a drenched, obvious effect. " <>
          "The send is only audible if its return track has an effect loaded. " <>
          "Regular tracks only — for a return track's own level use set_return_track_volume.",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{
            type: "integer",
            minimum: 0,
            description: "0-indexed regular track number"
          },
          "send" => %{
            type: "integer",
            minimum: 0,
            description: "0-indexed send: 0 = send A = return track 0, 1 = send B, and so on"
          },
          "value" => %{
            type: "number",
            minimum: 0.0,
            maximum: 1.0,
            description: "Send amount. 0.0 = no signal sent, 1.0 = maximum"
          }
        },
        required: ["track", "send", "value"]
      }
    },
    %{
      name: "get_track_sends",
      description:
        "Read every send level on one track, labeled with the send letter and the return track " <>
          "it feeds. " <>
          "Track indices are 0-based: 'track 1' = index 0. " <>
          "Use this before relative send changes ('a bit less delay') or to see which send " <>
          "index feeds which return. " <>
          "Requires Seshat's AbletonOSC extension (mix abletonosc.install).",
      parameters: %{
        type: "object",
        properties: %{
          "track" => %{
            type: "integer",
            minimum: 0,
            description: "0-indexed regular track number"
          }
        },
        required: ["track"]
      }
    },
    %{
      name: "create_return_track",
      description:
        "Create a new return track in Ableton Live and name it. " <>
          "Return tracks host shared effects (reverb, delay) that regular tracks feed via " <>
          "sends; the new return is appended after existing ones, and every track " <>
          "automatically gains the matching send (new return's index = new send's index; " <>
          "return 0 = send A). " <>
          "Live allows at most 12 return tracks; the tool errors at the cap. " <>
          "The new return is empty — Seshat cannot yet load a device onto a return track, so " <>
          "ask the user to drop the effect onto it in Live. " <>
          "Requires Seshat's AbletonOSC extension (mix abletonosc.install).",
      parameters: %{
        type: "object",
        properties: %{
          "name" => %{
            type: "string",
            description:
              "Short descriptive label for the return track (e.g. 'Room Reverb', 'Slap Delay')"
          }
        },
        required: ["name"]
      }
    },
    %{
      name: "delete_return_track",
      description:
        "Delete a return track. " <>
          "Return-track indices are 0-based and separate from regular track indices: return 0 " <>
          "= the first return = send A (see get_session_state). " <>
          "Deleting a return shifts the indices and send letters of the returns after it — " <>
          "re-check get_session_state afterwards. " <>
          "Requires Seshat's AbletonOSC extension (mix abletonosc.install).",
      parameters: %{
        type: "object",
        properties: %{
          "return_track" => %{
            type: "integer",
            minimum: 0,
            description: "0-indexed return track: 0 = the first return = send A"
          }
        },
        required: ["return_track"]
      }
    },
    %{
      name: "set_return_track_volume",
      description:
        "Set the volume of a return track — the overall level of the shared effect it hosts. " <>
          "Return-track indices are 0-based and separate from regular tracks: return 0 = send " <>
          "A's return (see get_session_state). " <>
          "Same fader scale as set_track_volume: 0.0 = silence, 0.85 = unity gain (0 dB), " <>
          "1.0 = +6 dB. " <>
          "To change how much one track feeds the effect, use set_track_send instead. " <>
          "Requires Seshat's AbletonOSC extension (mix abletonosc.install).",
      parameters: %{
        type: "object",
        properties: %{
          "return_track" => %{
            type: "integer",
            minimum: 0,
            description: "0-indexed return track: 0 = the first return = send A"
          },
          "value" => %{
            type: "number",
            minimum: 0.0,
            maximum: 1.0,
            description:
              "Fader position. 0.0 = silence, 0.85 = unity gain (0 dB), 1.0 = +6 dB (maximum boost)"
          }
        },
        required: ["return_track", "value"]
      }
    },
    %{
      name: "set_master_volume",
      description:
        "Set the master track's output volume in Ableton Live. " <>
          "Same fader scale as set_track_volume: 0.0 = silence, 0.85 = unity gain (0 dB, where " <>
          "a new set sits), 1.0 = +6 dB. " <>
          "Lower this if the master is clipping; prefer track volumes and sends for balance " <>
          "moves. " <>
          "Requires Seshat's AbletonOSC extension (mix abletonosc.install).",
      parameters: %{
        type: "object",
        properties: %{
          "value" => %{
            type: "number",
            minimum: 0.0,
            maximum: 1.0,
            description:
              "Fader position. 0.0 = silence, 0.85 = unity gain (0 dB), 1.0 = +6 dB (maximum boost)"
          }
        },
        required: ["value"]
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
