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
      name: "get_session_state",
      description:
        "Get the current state of all tracks in the Ableton Live session. " <>
          "Returns track names, indices, volume, pan, mute, and solo status. " <>
          "Use this before making relative adjustments ('turn it up a bit') " <>
          "or when you need to know what tracks exist.",
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
