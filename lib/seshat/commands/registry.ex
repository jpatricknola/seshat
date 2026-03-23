defmodule Seshat.Commands.Registry do
  @moduledoc """
  Maps Command structs to OSC messages and dispatches them via Transport.

  OSC addresses per AbletonOSC:
    /live/track/set/panning  [track_index, value]  (-1.0 left, 1.0 right)
    /live/track/set/volume   [track_index, value]  (0.0–1.0)
    /live/track/set/mute     [track_index, value]  (1 = muted, 0 = unmuted)
    /live/track/set/solo     [track_index, value]  (1 = solo, 0 = unsolo)
  """

  alias Seshat.Commands.Command
  alias Seshat.OSC.Transport

  @spec execute(Command.t()) :: :ok | {:error, term()}
  def execute(%Command{command: :pan, track: track, value: value}) do
    Transport.send_message("/live/track/set/panning", [track, value / 1.0])
  end

  def execute(%Command{command: :volume, track: track, value: value}) do
    Transport.send_message("/live/track/set/volume", [track, value / 1.0])
  end

  def execute(%Command{command: :mute, track: track, value: value}) do
    Transport.send_message("/live/track/set/mute", [track, trunc(value)])
  end

  def execute(%Command{command: :solo, track: track, value: value}) do
    Transport.send_message("/live/track/set/solo", [track, trunc(value)])
  end
end
