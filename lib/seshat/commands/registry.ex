defmodule Seshat.Commands.Registry do
  @moduledoc """
  Maps Command structs to OSC messages and dispatches them via Transport.

  OSC addresses per AbletonOSC:
    /live/track/set/panning       [track_index, value]  (-1.0 left, 1.0 right)
    /live/track/set/volume        [track_index, value]  (0.0–1.0)
    /live/track/set/mute          [track_index, value]  (1 = muted, 0 = unmuted)
    /live/track/set/solo          [track_index, value]  (1 = solo, 0 = unsolo)
    /live/song/create_midi_track  [index]               (-1 = append)
    /live/song/create_audio_track [index]               (-1 = append)
    /live/track/set/name          [track_index, name]
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

  def execute(%Command{command: :create_track, track_type: type, name: name}) do
    osc_address =
      case type do
        :midi -> "/live/song/create_midi_track"
        :audio -> "/live/song/create_audio_track"
      end

    with {:ok, {_addr, [count]}} <- Transport.query("/live/song/get/num_tracks", []),
         :ok <- Transport.send_message(osc_address, [-1]),
         :ok <- Transport.send_message("/live/track/set/name", [count, name]) do
      Seshat.Session.State.refresh()
      :ok
    end
  end
end
