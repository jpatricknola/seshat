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
            description:
              "Short descriptive label for the track (e.g. 'Drums', 'Lead Synth', 'Vocals')"
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
          "track" => %{
            type: "integer",
            description: "0-indexed track number (must be a MIDI track)"
          },
          "clip_slot" => %{
            type: "integer",
            description: "0-indexed scene/clip slot. Defaults to 0 if omitted."
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
      description: "Duplicate a clip to another slot in Ableton Live.",
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
          "Most presets carry tags written by Ableton's own sound designers, which is what " <>
          "makes character-based search possible. Common character tags: Analog, Digital, " <>
          "Acoustic, Electric, Bright, Dark, Warm, Soft, Punchy, Distorted, Clean, Sub, " <>
          "Rhythmic, Evolving, Wide, Mono. Common kind tags: Bass, 808 Bass, Synth Bass, Lead, " <>
          "Pad, Keys, Piano, Strings, Brass, Kick, Snare, Hi-hat, Clap, Percussion. " <>
          "Put the kind of sound in `query` and the character in `tags` — 'a warm analog bass' " <>
          "is query 'bass' + tags ['Analog', 'Warm']. Tag filters are strict (every tag must " <>
          "match), so start with one or two and loosen if nothing comes back. " <>
          "WHEN CHOOSING: weigh the musical context — the tempo, the other tracks and the genre " <>
          "from get_session_state and from what the user has said — and present the top 3–5 " <>
          "candidates with a one-line reason each, then let the user pick. Only load the first " <>
          "hit without asking if the user told you to just pick one. " <>
          "Each result is `name — tags [folder path] (uri)`; the uri goes straight to " <>
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
              "Tags the item must ALL carry, e.g. ['Analog', 'Punchy']. Matched " <>
                "case-insensitively as substrings, so 'bass' also matches '808 Bass'."
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
          "you asked for before telling the user it worked.",
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
          "('the reverb') to the device index that get_device_parameters and " <>
          "set_device_parameter need, or to check whether a track has an instrument at all. " <>
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
          "trust the min/max in the output, not an assumption.",
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
          "a small fraction of the range.",
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
      name: "get_session_state",
      description:
        "Get the current state of all tracks in the Ableton Live session. " <>
          "Returns tempo, time signature, track names, indices, volume, pan, mute, and solo status. " <>
          "Use this before making relative adjustments ('turn it up a bit'), " <>
          "when you need to know what tracks exist, or before writing MIDI notes. " <>
          "Indices are 0-based but Ableton's UI numbers tracks from 1 — when talking " <>
          "to the user, refer to tracks by name or 1-based UI number, never raw index.",
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
