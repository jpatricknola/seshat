defmodule Seshat.Commands.Command do
  @moduledoc """
  Struct representing a multi-step Ableton operation.

  Only operations that need sequencing become Commands — single-message
  tools call `Seshat.OSC.Transport` directly from `Seshat.Tools.Handlers`.
  """

  @type t :: %__MODULE__{
          command: :create_track | :create_return_track | :new_project | :write_notes,
          track: non_neg_integer() | nil,
          track_type: :midi | :audio | nil,
          name: String.t() | nil,
          tracks: [%{track_type: :midi | :audio, name: String.t()}] | nil,
          clip_slot: non_neg_integer() | nil,
          clip_length: float() | nil,
          notes: [map()] | nil
        }

  defstruct [
    :command,
    :track,
    :track_type,
    :name,
    :tracks,
    :clip_slot,
    :clip_length,
    :notes
  ]
end
