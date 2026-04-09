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

  require Logger

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
    with :ok <- create_and_name_track(type, name) do
      Seshat.Session.State.refresh()
      :ok
    end
  end

  def execute(%Command{command: :write_notes, track: track, clip_slot: slot, clip_length: length, notes: notes}) do
    with :ok <- ensure_clip(track, slot, length),
         :ok <- add_notes(track, slot, notes) do
      Logger.info("Wrote #{Enum.count(notes)} notes to track #{track}, clip slot #{slot}")
      :ok
    end
  end

  def execute(%Command{command: :new_project, tracks: tracks}) do
    with :ok <- open_new_set(),
         :ok <- wait_for_ableton(),
         :ok <- clear_default_tracks(),
         :ok <- create_tracks(tracks) do
      Seshat.Session.State.refresh()
      :ok
    end
  end

  # --- Private helpers: MIDI notes ---

  defp ensure_clip(track, slot, length) do
    case Transport.query("/live/clip_slot/get/has_clip", [track, slot]) do
      {:ok, {_addr, [_t, _s, 1]}} -> :ok
      {:ok, {_addr, [_t, _s, true]}} -> :ok
      {:ok, {_addr, [_t, _s, 0]}} -> Transport.send_message("/live/clip_slot/create_clip", [track, slot, length / 1.0])
      {:ok, {_addr, [_t, _s, false]}} -> Transport.send_message("/live/clip_slot/create_clip", [track, slot, length / 1.0])
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_notes(track, slot, notes) do
    note_args =
      Enum.flat_map(notes, fn n ->
        [n.pitch, n.start_beat / 1.0, n.duration / 1.0, n.velocity, 0]
      end)

    Transport.send_message("/live/clip/add/notes", [track, slot | note_args])
  end

  # --- Private helpers ---

  defp create_and_name_track(type, name) do
    osc_address =
      case type do
        :midi -> "/live/song/create_midi_track"
        :audio -> "/live/song/create_audio_track"
      end

    with {:ok, {_addr, [count]}} <- Transport.query("/live/song/get/num_tracks", []),
         :ok <- Transport.send_message(osc_address, [-1]),
         :ok <- Transport.send_message("/live/track/set/name", [count, name]) do
      :ok
    end
  end

  defp create_tracks(tracks) do
    Enum.reduce_while(tracks, :ok, fn %{track_type: type, name: name}, :ok ->
      case create_and_name_track(type, name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp open_new_set do
    case System.cmd("osascript", [
           "-e", "tell application \"Ableton Live 12\" to activate",
           "-e", "tell application \"System Events\" to keystroke \"n\" using command down"
         ]) do
      {_output, 0} ->
        Logger.info("Sent Cmd+N to Ableton via AppleScript")
        :ok

      {output, code} ->
        Logger.error("AppleScript failed (exit #{code}): #{output}")
        {:error, "Failed to open new Ableton set"}
    end
  end

  defp wait_for_ableton(retries \\ 20, delay_ms \\ 500) do
    case Transport.query("/live/test", []) do
      {:ok, _} ->
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(delay_ms)
        wait_for_ableton(retries - 1, delay_ms)

      {:error, reason} ->
        Logger.error("Ableton not responding after new set: #{inspect(reason)}")
        {:error, "Ableton not responding after opening new set"}
    end
  end

  defp clear_default_tracks do
    case Transport.query("/live/song/get/num_tracks", []) do
      {:ok, {_addr, [count]}} ->
        # Delete tracks in reverse order to avoid index shifting
        Enum.each((count - 1)..0//-1, fn i ->
          Transport.send_message("/live/song/delete_track", [i])
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
