defmodule Seshat.Tools.FollowCam do
  @moduledoc """
  View steering: making every mutating tool's effect visible in Live.

  A tool that writes notes into a slot the user can't see hasn't confirmed
  anything — the 2026-07-28 validation run's headline finding was a user
  assuming `write_midi_notes` had *failed* because Session view showed only an
  anonymous coloured rectangle. Acting beats instructing: the change appearing
  on screen is the confirmation.

  So after a create, write or delete succeeds, its handler calls `steer/2`,
  which selects what the tool touched and shows the pane it lives in — a clip
  write opens the note editor on the clip, a device load opens the device chain,
  a delete lands on whatever now occupies that index.

  Two halves, deliberately split:

    * `calls/2` is **pure** — tool name plus the facts the handler gathered, to
      an ordered list of `{address, args}`. Every steering send is
      fire-and-forget UDP with no reply, so nothing can be asserted at the wire;
      this function is where the whole decision lives and where the tests drive
      it.
    * `steer/2` sends them, swallowing every failure. Steering must never fail
      or delay the tool it follows: the tool already succeeded, and a dead
      transport is not a reason to turn a successful write into an error.

  Which tools steer is a settled decision, not a per-tool judgment: creates,
  writes and deletes do; parameter tweaks, transport, renames and reads do not.
  A view that jumps on every volume nudge is what would make someone ask for an
  off switch, and there is deliberately no off switch.
  """

  alias Seshat.OSC.Transport

  require Logger

  @doc """
  The ordered steering messages for a tool, given the facts its handler holds.

  Pure. Returns `[]` for anything that doesn't steer, so a caller never has to
  ask whether a tool is in the list.

  Facts are a map with atom keys; each clause documents what it needs:

    * `:track`, `:slot` — clip coordinates (slot = scene index)
    * `:device` — device index within `track.devices`
    * `:return` — return-track index, its own index space
    * `:scene`
    * `:remaining` — how many objects of that kind are left *after* a delete

  Addresses are string literals on purpose: `vendored_addresses_test` greps
  `lib/` for `"/live/…"` literals to check both directions of the vendored
  seam, and an interpolated address is invisible to it.
  """
  @spec calls(String.t(), map()) :: [{String.t(), list()}]

  # --- Clips ---
  #
  # Selection first, then the panes. The clip is put into the Detail view by
  # index rather than by "whatever is selected", so the two can't disagree if a
  # stray selection lands in between.
  def calls(tool, %{track: track, slot: slot})
      when tool in ["write_midi_notes", "remove_notes", "duplicate_clip", "capture_midi"] do
    [
      {"/live/view/set/selected_clip", [track, slot]},
      {"/live/view/set/detail_clip", [track, slot]},
      {"/live/view/show_view", ["Session"]},
      {"/live/view/show_view", ["Detail/Clip"]}
    ]
  end

  # No detail pane: the slot is empty now, so there is nothing for the note
  # editor to show. The gap in the grid is the evidence.
  def calls("delete_clip", %{track: track, slot: slot}) do
    [
      {"/live/view/set/selected_clip", [track, slot]},
      {"/live/view/show_view", ["Session"]}
    ]
  end

  # --- Tracks ---
  #
  # No pane change: track headers are visible in Session and Arrangement both,
  # so forcing Session here would fight a user working in the Arrangement.
  def calls(tool, %{track: track}) when tool in ["create_track", "duplicate_track"] do
    [{"/live/view/set/selected_track", [track]}]
  end

  def calls("delete_track", %{track: _track, remaining: 0}), do: []

  def calls("delete_track", %{track: track, remaining: remaining}) do
    [{"/live/view/set/selected_track", [min(track, remaining - 1)]}]
  end

  # --- Return tracks ---
  #
  # `/live/view/set/selected_track` indexes `song.tracks`, where returns don't
  # appear, so returns get their own vendored address.
  def calls("create_return_track", %{return: index}) do
    [{"/live/return_track/select", [index]}]
  end

  # Deleting the last return steers nowhere: the only container left to fall
  # back on is the master, which is out of scope (its one tool is a parameter
  # tweak, and parameter tweaks don't steer).
  def calls("delete_return_track", %{return: _index, remaining: 0}), do: []

  def calls("delete_return_track", %{return: index, remaining: remaining}) do
    [{"/live/return_track/select", [min(index, remaining - 1)]}]
  end

  # --- Scenes ---
  #
  # Scenes exist only in Session view, so the pane is unconditional here.
  def calls(tool, %{scene: scene}) when tool in ["create_scene", "duplicate_scene"] do
    [
      {"/live/view/set/selected_scene", [scene]},
      {"/live/view/show_view", ["Session"]}
    ]
  end

  def calls("delete_scene", %{scene: _scene, remaining: 0}), do: []

  def calls("delete_scene", %{scene: scene, remaining: remaining}) do
    [
      {"/live/view/set/selected_scene", [min(scene, remaining - 1)]},
      {"/live/view/show_view", ["Session"]}
    ]
  end

  # --- Devices ---
  #
  # `device: -1` is `load_item`'s "not on the chain yet" — some VST/AU plugins
  # instantiate asynchronously. Selecting the track still opens the chain the
  # device is arriving on, which is the useful half.
  def calls("load_device", %{track: track, device: -1}) do
    [
      {"/live/view/set/selected_track", [track]},
      {"/live/view/show_view", ["Detail/DeviceChain"]}
    ]
  end

  def calls(tool, %{track: track, device: device})
      when tool in ["load_device", "bypass_device"] and device >= 0 do
    [
      {"/live/view/set/selected_device", [track, device]},
      {"/live/view/show_view", ["Detail/DeviceChain"]}
    ]
  end

  # An empty chain has no device to select, and is itself the evidence that the
  # delete landed — so show it.
  def calls("delete_device", %{track: track, device: _device, remaining: 0}) do
    [
      {"/live/view/set/selected_track", [track]},
      {"/live/view/show_view", ["Detail/DeviceChain"]}
    ]
  end

  def calls("delete_device", %{track: track, device: device, remaining: remaining}) do
    [
      {"/live/view/set/selected_device", [track, min(device, remaining - 1)]},
      {"/live/view/show_view", ["Detail/DeviceChain"]}
    ]
  end

  def calls(_tool, _facts), do: []

  @doc """
  Sends a tool's steering messages, best effort.

  Always `:ok`. A steering send that fails is logged and dropped: the tool it
  follows has already succeeded, so the worst case is a change the user has to
  find by hand — turning that into an error would be strictly worse. Transport
  being dead or absent (a test run with nothing listening, Ableton closed
  between the write and the steer) exits the caller, which is caught here for
  the same reason.
  """
  @spec steer(String.t(), map()) :: :ok
  def steer(tool, facts) do
    Enum.each(calls(tool, facts), fn {address, args} ->
      case Transport.send_message(address, args) do
        :ok -> :ok
        {:error, reason} -> Logger.debug("Follow cam: #{address} failed: #{inspect(reason)}")
      end
    end)
  catch
    :exit, _ ->
      Logger.debug("Follow cam: transport unavailable, skipped steering for #{tool}")
      :ok
  end
end
