defmodule Seshat.Commands.Registry do
  @moduledoc """
  Executes multi-step Command sequences via Transport.

  Single-message tools call `Seshat.OSC.Transport` directly from
  `Seshat.Tools.Handlers` — a Command only exists for operations that need
  ordering: query-then-create, ensure-then-write.

  OSC addresses per AbletonOSC:
    /live/song/create_midi_track  [index]               (-1 = append)
    /live/song/create_audio_track [index]               (-1 = append)
    /live/song/get/num_tracks     []                  → [count]
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

  # A clip-slot index that doesn't exist used to get no reply at all — AbletonOSC
  # raised inside the callback and sent nothing — so this timeout was really "how
  # long until we call it a bad index". The fork's structured `/live/error` ended
  # that: the raise now comes back correlated and the query fails in
  # milliseconds, so a bad index no longer spends this budget. The short timeout
  # stays for what is left (a dropped datagram, an install predating the fork),
  # matching the guard timeout in `Seshat.Tools.Handlers` rather than Transport's
  # 5s default: neither should stall a write for five seconds.
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
         :ok <- ensure_return_created(before_count, after_count),
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

      # Rendered here rather than passed through: the string a handler shows the
      # model must never be an inspected Transport term. A rejected slot lookup
      # carries the same guarantee as an unanswered one — nothing was written —
      # so it keeps the timeout branch's consequence sentence.
      {:error, reason} ->
        {:error,
         "#{Transport.describe_error(reason)} — the clip slot could not be read, so no notes " <>
           "were written. Check the slot with get_clip_slots."}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out looking up clip slot #{slot} on track #{track}, so no notes were written. A " <>
         "bad slot index is normally rejected outright rather than met with silence, so this " <>
         "points at Ableton — check it is running with AbletonOSC enabled, then re-check the " <>
         "slot with get_clip_slots."}
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
        {:error, Transport.describe_error(reason)}
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

  Exactly one more, not merely "went up": `before_count` is a claim about *which
  index is ours*, and only an increase of one supports it. A user adding a return
  by hand in Live while the tool runs is ordinary here, and renaming
  `before_count` after a jump of two would rename theirs.

  Public because it is the pure half of a sequence that otherwise needs a live
  Ableton to reach.
  """
  @spec ensure_return_created(non_neg_integer(), non_neg_integer()) :: :ok | {:error, String.t()}
  def ensure_return_created(before_count, after_count) when after_count == before_count + 1,
    do: :ok

  def ensure_return_created(before_count, after_count) when after_count > before_count + 1 do
    {:error,
     "The return track count went from #{before_count} to #{after_count} — more than one " <>
       "return track appeared, so Seshat can't tell which one it created. Nothing was " <>
       "renamed. Check get_session_state and rename the new return track by hand, or delete " <>
       "the extras and try again."}
  end

  def ensure_return_created(before_count, _after_count) when before_count >= 12 do
    {:error,
     "Ableton did not create a return track — the set is already at Live's limit of 12 " <>
       "return tracks. Nothing was created or renamed. Delete a return you no longer need " <>
       "with delete_return_track first."}
  end

  def ensure_return_created(before_count, after_count) do
    {:error,
     "Ableton did not create a return track — the count went from #{before_count} to " <>
       "#{after_count}, which is below Live's 12-return limit, so the create message may not " <>
       "have landed. Nothing was renamed. Check get_session_state and try again."}
  end

  # --- Private helpers: regular tracks ---

  # The return sibling's 2s @return_probe_timeout is an "is return_track.py
  # installed?" probe and must not be copied here: /live/song/get/num_tracks is
  # upstream's, so silence means Live isn't answering at all — the same condition
  # every other upstream query faces. Transport's 5s default it is.
  #
  # `context` picks the timeout message for the same reason it does for returns:
  # a timeout before the create means nothing was created, a timeout after it
  # means a track may well exist.
  defp track_count(context) do
    case Transport.query("/live/song/get/num_tracks", []) do
      {:ok, {_addr, [count]}} when is_integer(count) ->
        {:ok, count}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from /live/song/get/num_tracks: #{inspect(args)}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error, track_count_timeout_message(context)}
  end

  defp track_count_timeout_message(:pre_create) do
    "Timed out reading the track count, so nothing was created. Check that Ableton Live is " <>
      "running with AbletonOSC enabled."
  end

  defp track_count_timeout_message(:post_create) do
    "Sent the create, but timed out confirming the new track count afterwards — a track may " <>
      "have been created but could not be confirmed or named. Check get_session_state for an " <>
      "unnamed extra track before creating another."
  end

  @doc """
  Decides whether `/live/song/create_midi_track` (or `_audio_`) actually created
  one, from the track count either side of it.

  The create is a fire-and-forget method call and AbletonOSC's `_call_method`
  swallows Live API exceptions into its log, so the count is the only signal that
  reaches us at all. Unlike returns there is no cap to name: regular tracks are
  uncapped in Standard/Suite and capped only in Intro/Lite, and nothing on the
  wire reveals the edition — so an unchanged count gets one message naming both
  possible causes rather than asserting either.

  Exactly one more, not merely "went up", for the same reason as
  `ensure_return_created/2`: `before_count` is the index we are about to rename
  and hand back, and only an increase of one supports that claim.

  Public because it is the pure half of a sequence that otherwise needs a live
  Ableton to reach.
  """
  @spec ensure_track_created(non_neg_integer(), non_neg_integer()) :: :ok | {:error, String.t()}
  def ensure_track_created(before_count, after_count) when after_count == before_count + 1,
    do: :ok

  def ensure_track_created(before_count, after_count) when after_count > before_count + 1 do
    {:error,
     "The track count went from #{before_count} to #{after_count} — more than one track " <>
       "appeared, so Seshat can't tell which one it created. Nothing was renamed. Check " <>
       "get_session_state and rename the new track by hand, or delete the extras and try again."}
  end

  def ensure_track_created(before_count, after_count) do
    {:error,
     "Ableton did not create a track — the count went from #{before_count} to #{after_count}. " <>
       "Nothing was renamed. Some Live editions (Intro/Lite) cap the number of tracks; " <>
       "otherwise the create message may not have landed. Check get_session_state and try " <>
       "again."}
  end

  defp create_and_name_track(type, name) do
    osc_address =
      case type do
        :midi -> "/live/song/create_midi_track"
        :audio -> "/live/song/create_audio_track"
      end

    # The pre-create count *is* the new track's index: both creates are sent with
    # -1, which appends. Only true once the count has been seen to rise by
    # exactly one, which is what ensure_track_created/2 checks before the rename.
    with {:ok, before_count} <- track_count(:pre_create),
         :ok <- Transport.send_message(osc_address, [-1]),
         {:ok, after_count} <- track_count(:post_create),
         :ok <- ensure_track_created(before_count, after_count),
         :ok <- Transport.send_message("/live/track/set/name", [before_count, name]) do
      {:ok, before_count}
    end
  end
end
