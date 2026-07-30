defmodule Seshat.Commands.Registry do
  @moduledoc """
  Executes multi-step Command sequences via Transport.

  Single-message tools call `Seshat.OSC.Transport` directly from
  `Seshat.Tools.Handlers` — a Command only exists for operations that need
  ordering: query-then-create, ensure-then-write.

  OSC addresses per AbletonOSC:
    /live/song/create_midi_track  [index]               (-1 = append)
    /live/song/create_audio_track [index]               (-1 = append)
    /live/track/set/name          [track_index, name]
    /live/clip_slot/create_clip   [track_index, slot, length]
    /live/clip/add/notes          [track_index, slot, pitch, start, dur, vel, mute, ...]
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

  `:write_notes` reports only success or failure. The two creates also hand back
  the new object's index, which the caller needs for its reply and for steering
  Live's view onto it, and can't safely re-derive afterwards (another create
  would shift it).
  """
  @spec execute(Command.t()) :: :ok | {:ok, non_neg_integer()} | {:error, term()}
  def execute(%Command{command: :create_track, track_type: type, name: name}) do
    with {:ok, index} <- create_and_name_track(type, name) do
      Seshat.Session.State.refresh()
      {:ok, index}
    end
  end

  def execute(%Command{command: :create_return_track, name: name}) do
    with {:ok, before_count} <- return_track_count(:pre_create),
         :ok <- Transport.send_message("/live/song/create_return_track", []),
         {:ok, after_count} <- return_track_count(:post_create),
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

  # --- Private helpers: MIDI notes ---

  # The echoed indices are checked against the ones we asked about: Transport
  # serializes queries but correlates replies by address alone, so a reply
  # abandoned by an earlier timeout can still answer the next query on that same
  # address, and acting on another slot's answer would create a clip over the
  # wrong material. A mismatch reissues the query once — the reissue asks the
  # same indices, so the straggler's genuine successor usually answers it, though
  # that is mitigation rather than a guarantee: the genuine reply can land in the
  # gap between the rejection and the reissue, in which case it is broadcast and
  # the reissue times out. Only a second mismatch is reported.
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
  #
  # `context` picks the timeout message: a timeout on the *pre*-create count means
  # the create was never sent, so "nothing was created" is true. A timeout on the
  # *post*-create count is a different situation — the create message is already
  # on the wire and may well have landed — so it gets its own wording rather than
  # falsely claiming nothing happened.
  defp return_track_count(context) do
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
      {:error, return_track_count_timeout_message(context)}
  end

  defp return_track_count_timeout_message(:pre_create) do
    "Timed out reading the return track count, so nothing was created. That address comes " <>
      "from Seshat's AbletonOSC extension — run `mix abletonosc.install` and restart " <>
      "Ableton Live, and check Live is running with AbletonOSC enabled."
  end

  defp return_track_count_timeout_message(:post_create) do
    "Sent the create, but timed out confirming the new return track count afterwards — a " <>
      "return track may have been created but could not be confirmed or named. Check " <>
      "get_session_state for an unnamed extra return before creating another."
  end

  @doc """
  Decides whether `/live/song/create_return_track` actually created one, from
  the return-track count either side of it.

  Live caps a set at 12 return tracks. Whether the LOM call raises or no-ops at
  the cap is undocumented and version-dependent, so the count is the observable
  truth either way — and the reason for a non-create matters, because "you're at
  Live's limit" and "the message didn't land" ask the user for different things.

  Public because it is the pure half of a sequence that otherwise needs a live
  Ableton to reach.
  """
  @spec ensure_created(non_neg_integer(), non_neg_integer()) :: :ok | {:error, String.t()}
  def ensure_created(before_count, after_count) when after_count > before_count, do: :ok

  def ensure_created(before_count, _after_count) when before_count >= 12 do
    {:error,
     "Ableton did not create a return track — the set is already at Live's limit of 12 " <>
       "return tracks. Nothing was created or renamed. Delete a return you no longer need " <>
       "with delete_return_track first."}
  end

  def ensure_created(before_count, after_count) do
    {:error,
     "Ableton did not create a return track — the count went from #{before_count} to " <>
       "#{after_count}, which is below Live's 12-return limit, so the create message may not " <>
       "have landed. Nothing was renamed. Check get_session_state and try again."}
  end

  # --- Private helpers ---

  defp create_and_name_track(type, name) do
    osc_address =
      case type do
        :midi -> "/live/song/create_midi_track"
        :audio -> "/live/song/create_audio_track"
      end

    # The pre-create count *is* the new track's index: both creates are sent with
    # -1, which appends.
    with {:ok, {_addr, [count]}} <- Transport.query("/live/song/get/num_tracks", []),
         :ok <- Transport.send_message(osc_address, [-1]),
         :ok <- Transport.send_message("/live/track/set/name", [count, name]) do
      {:ok, count}
    end
  end
end
