defmodule Seshat.Commands.Registry do
  @moduledoc """
  Executes multi-step Command sequences via Transport.

  Single-message tools call `Seshat.OSC.Transport` directly from
  `Seshat.Tools.Handlers` — a Command only exists for operations that need
  ordering: query-then-create, ensure-then-write, clear-then-rebuild.

  OSC addresses per AbletonOSC:
    /live/song/create_midi_track  [index]               (-1 = append)
    /live/song/create_audio_track [index]               (-1 = append)
    /live/track/set/name          [track_index, name]
    /live/clip_slot/create_clip   [track_index, slot, length]
    /live/clip/add/notes          [track_index, slot, pitch, start, dur, vel, mute, ...]
    /live/song/delete_track       [track_index]
  """

  alias Seshat.Commands.Command
  alias Seshat.OSC.Transport

  require Logger

  # A clip-slot index that doesn't exist gets no reply at all (AbletonOSC raises
  # inside the callback and sends nothing), so this timeout is really "how long
  # until we call it a bad index". Matches the guard timeout in
  # `Seshat.Tools.Handlers` rather than Transport's 5s default: a typo shouldn't
  # stall a write for five seconds.
  @slot_query_timeout 2_000

  @spec execute(Command.t()) :: :ok | {:error, term()}
  def execute(%Command{command: :create_track, track_type: type, name: name}) do
    with :ok <- create_and_name_track(type, name) do
      Seshat.Session.State.refresh()
      :ok
    end
  end

  def execute(%Command{
        command: :write_notes,
        track: track,
        clip_slot: slot,
        clip_length: length,
        notes: notes
      }) do
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

  # The echoed indices are checked against the ones we asked about: Transport
  # correlates replies by address alone, so a reply abandoned by an earlier
  # timeout can arrive while a later query for the same address is pending, and
  # acting on another slot's answer would create a clip over the wrong material.
  defp ensure_clip(track, slot, length) do
    case Transport.query("/live/clip_slot/get/has_clip", [track, slot], @slot_query_timeout) do
      {:ok, {_addr, [reply_track, reply_slot, has_clip]}}
      when reply_track == track and reply_slot == slot ->
        # AbletonOSC sends booleans for some properties and 0/1 for others.
        if has_clip in [1, true] do
          :ok
        else
          Transport.send_message("/live/clip_slot/create_clip", [track, slot, length / 1.0])
        end

      {:ok, _mismatched} ->
        {:error,
         "Ableton's reply about slot #{slot} on track #{track} was for a different slot — it " <>
           "belongs to an earlier query that timed out. Nothing was written; try again."}

      {:error, reason} ->
        {:error, reason}
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
           "-e",
           "tell application \"Ableton Live 12\" to activate",
           "-e",
           "tell application \"System Events\" to keystroke \"n\" using command down"
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
