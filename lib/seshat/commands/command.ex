defmodule Seshat.Commands.Command do
  @moduledoc "Struct representing a parsed Ableton command."

  @type t :: %__MODULE__{
          command: :pan | :volume | :mute | :solo,
          track: non_neg_integer(),
          value: float()
        }

  defstruct [:command, :track, :value]
end
