defmodule Seshat.Commands.Command do
  @moduledoc "Struct representing a parsed Ableton command."

  @type t :: %__MODULE__{
          command: :pan | :volume | :mute | :solo | :create_track | :new_project,
          track: non_neg_integer() | nil,
          value: float() | nil,
          track_type: :midi | :audio | nil,
          name: String.t() | nil,
          tracks: [%{track_type: :midi | :audio, name: String.t()}] | nil
        }

  defstruct [:command, :track, :value, :track_type, :name, :tracks]
end
