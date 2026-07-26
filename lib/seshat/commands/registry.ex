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
    /live/song/create_return_track                        (no args — appends)
    /live/return_track/get/count  []                    → [count]        (Seshat ext.)
    /live/return_track/set/name   [return_index, name]                   (Seshat ext.)
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

  # `/live/return_track/get/count` comes from Seshat's own return_track.py, so an
  # un-run `mix abletonosc.install` means no reply at all rather than an error.
  # Short timeout for the same reason as the slot query: this is "how long until
  # we call the extension missing", not a real wait.
  @return_probe_timeout 2_000

  @doc """
  Runs a multi-step Command.

  Most sequences report only success or failure; `:create_return_track` also
  hands back the new return's index, which the caller needs for its reply and
  can't safely re-derive afterwards (another create would shift it).
  """
  @spec execute(Command.t()) :: :ok | {:ok, non_neg_integer()} | {:error, term()}
  def execute(%Command{command: :create_track, track_type: type, name: name}) do
    with :ok <- create_and_name_track(type, name) do
      Seshat.Session.State.refresh()
      :ok
    end
  end

  def execute(%Command{command: :create_return_track, name: name}) do
    with {:ok, before_count} <- return_track_count(),
         :ok <- Transport.send_message("/live/song/create_return_track", []),
         {:ok, after_count} <- return_track_count(),
         :ok <- ensure_created(before_count, after_count),
         # The new return's index is the *old* count: Live appends returns, and
         # upstream's create takes no index argument.
         :ok <- Transport.send_message("/live/return_track/set/name", [before_count, name]) do
      Seshat.Session.State.refresh()
      {:ok, before_count}
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
  # A mismatch reissues the query once — consuming the stale reply also clears
  # Transport's `pending`, so our own answer is usually already on the wire behind
  # it — and only a second mismatch is reported.
  #
  # The timeout is caught here rather than by the calling handler clause, which
  # can't tell a slot lookup that never answered from a transport that stopped
  # answering later in the sequence.
  defp ensure_clip(track, slot, length, reissued? \\ false) do
    case Transport.query("/live/clip_slot/get/has_clip", [track, slot], @slot_query_timeout) do
      {:ok, {_addr, [reply_track, reply_slot, has_clip]}}
      when reply_track == track and reply_slot == slot ->
        # AbletonOSC sends booleans for some properties and 0/1 for others.
        if has_clip in [1, true] do
          :ok
        else
          Transport.send_message("/live/clip_slot/create_clip", [track, slot, length / 1.0])
        end

      {:ok, _mismatched} when not reissued? ->
        ensure_clip(track, slot, length, true)

      {:ok, _mismatched} ->
        {:error,
         "Ableton's replies about slot #{slot} on track #{track} were for a different slot, " <>
           "twice in a row — they belong to an earlier query that timed out. Nothing was " <>
           "written; try again."}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out looking up clip slot #{slot} on track #{track}, so no notes were written. A " <>
         "slot index that doesn't exist gets no reply from Ableton at all, so check the slot " <>
         "with get_clip_slots."}
  end

  defp add_notes(track, slot, notes) do
    note_args =
      Enum.flat_map(notes, fn n ->
        [n.pitch, n.start_beat / 1.0, n.duration / 1.0, n.velocity, 0]
      end)

    Transport.send_message("/live/clip/add/notes", [track, slot | note_args])
  end

  # --- Private helpers: return tracks ---

  # Doubles as the "is return_track.py installed?" probe, so it runs *before* the
  # create as well as after: fail-fast beats leaving an unnamed return behind.
  defp return_track_count do
    case Transport.query("/live/return_track/get/count", [], @return_probe_timeout) do
      {:ok, {_addr, [count]}} when is_integer(count) ->
        {:ok, count}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from /live/return_track/get/count: #{inspect(args)}"}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the return track count, so nothing was created. That address comes " <>
         "from Seshat's AbletonOSC extension — run `mix abletonosc.install` and restart " <>
         "Ableton Live, and check Live is running with AbletonOSC enabled."}
  end

  # Live caps a set at 12 return tracks. Whether the LOM call raises or no-ops at
  # the cap, the count is the observable truth either way.
  defp ensure_created(before_count, after_count) when after_count > before_count, do: :ok

  defp ensure_created(before_count, _after_count) do
    {:error,
     "Ableton did not create a return track — the set already has #{before_count}, which is " <>
       "Live's limit (12). Nothing was created or renamed. Delete a return you no longer need " <>
       "with delete_return_track first."}
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
