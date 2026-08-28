defmodule Seshat.Tools.FollowCamTest do
  @moduledoc """
  Every steering send is fire-and-forget UDP with no reply, so nothing about
  follow cam can be asserted at the wire — `calls/2` is where the whole decision
  lives, and this is the only place it can be checked. Exact sequences, in
  order: which pane opens after which selection is the part a reordering would
  silently break.
  """

  use ExUnit.Case, async: true

  alias Seshat.Tools.FollowCam

  describe "clips" do
    test "a write selects the clip, details it, and opens the note editor" do
      assert FollowCam.calls("write_midi_notes", %{track: 2, slot: 1}) == [
               {"/live/view/set/selected_clip", [2, 1]},
               {"/live/view/set/detail_clip", [2, 1]},
               {"/live/view/show_view", ["Session"]},
               {"/live/view/show_view", ["Detail/Clip"]}
             ]
    end

    # set_clip_properties is in this list on purpose: it reads like a parameter
    # tweak but its headline use is reshaping a clip's audible extent right
    # after a capture, and the moved loop brace in the note editor is the
    # confirmation.
    # quantize_clip belongs here for the plainest reason of all: it rewrites the
    # clip's note starts, and the notes visibly snapping in the note editor is
    # the confirmation the reply's counts are describing.
    test "edit_notes, duplicate_clip, capture_midi, set_clip_properties, stop_recording and quantize_clip steer the same way" do
      expected = FollowCam.calls("write_midi_notes", %{track: 0, slot: 3})

      tools = [
        "edit_notes",
        "duplicate_clip",
        "capture_midi",
        "set_clip_properties",
        "stop_recording",
        "quantize_clip"
      ]

      for tool <- tools do
        assert FollowCam.calls(tool, %{track: 0, slot: 3}) == expected
      end
    end

    # No detail pane: the slot is empty now, so there is nothing for the note
    # editor to show and the gap in the grid is the evidence.
    test "a delete shows the emptied slot in Session and nothing else" do
      assert FollowCam.calls("delete_clip", %{track: 1, slot: 4}) == [
               {"/live/view/set/selected_clip", [1, 4]},
               {"/live/view/show_view", ["Session"]}
             ]
    end

    # Same shape as a delete, for the opposite reason: at steer time the clip may
    # not exist yet (a fire with the transport playing waits for the launch
    # quantization boundary), and `detail_clip` on an empty slot is a silent
    # no-op that would leave the previous clip in the editor.
    test "starting a take shows the recording slot in Session and opens no detail pane" do
      assert FollowCam.calls("record_clip", %{track: 2, slot: 0}) == [
               {"/live/view/set/selected_clip", [2, 0]},
               {"/live/view/show_view", ["Session"]}
             ]
    end
  end

  describe "tracks" do
    # Track headers are visible in Session and Arrangement both, so forcing a
    # pane here would fight a user working in the Arrangement.
    test "create and duplicate select the track without changing the pane" do
      assert FollowCam.calls("create_track", %{track: 3}) ==
               [{"/live/view/set/selected_track", [3]}]

      assert FollowCam.calls("duplicate_track", %{track: 4}) ==
               [{"/live/view/set/selected_track", [4]}]
    end

    test "deleting from the middle lands on the successor at the same index" do
      assert FollowCam.calls("delete_track", %{track: 1, remaining: 4}) ==
               [{"/live/view/set/selected_track", [1]}]
    end

    test "deleting the last track clamps back onto the new last one" do
      assert FollowCam.calls("delete_track", %{track: 3, remaining: 3}) ==
               [{"/live/view/set/selected_track", [2]}]
    end

    test "deleting the only track steers nowhere" do
      assert FollowCam.calls("delete_track", %{track: 0, remaining: 0}) == []
    end
  end

  describe "return tracks" do
    # /live/view/set/selected_track indexes song.tracks, where returns don't
    # appear — hence the vendored address.
    test "create selects the new return through the vendored address" do
      assert FollowCam.calls("create_track", %{return: 2}) ==
               [{"/live/return_track/select", [2]}]
    end

    test "delete clamps onto the return that took its place" do
      assert FollowCam.calls("delete_track", %{return: 2, remaining: 2}) ==
               [{"/live/return_track/select", [1]}]

      assert FollowCam.calls("delete_track", %{return: 0, remaining: 3}) ==
               [{"/live/return_track/select", [0]}]
    end

    # The only container left would be the master, which is deliberately out of
    # scope: its one tool is a parameter tweak, and parameter tweaks don't steer.
    test "deleting the last return steers nowhere" do
      assert FollowCam.calls("delete_track", %{return: 0, remaining: 0}) == []
    end
  end

  describe "scenes" do
    # Scenes exist only in Session view, so the pane is unconditional.
    test "create and duplicate select the scene and show Session" do
      assert FollowCam.calls("create_scene", %{scene: 5}) == [
               {"/live/view/set/selected_scene", [5]},
               {"/live/view/show_view", ["Session"]}
             ]

      assert FollowCam.calls("duplicate_scene", %{scene: 2}) == [
               {"/live/view/set/selected_scene", [2]},
               {"/live/view/show_view", ["Session"]}
             ]
    end

    test "delete clamps and still shows Session" do
      assert FollowCam.calls("delete_scene", %{scene: 7, remaining: 7}) == [
               {"/live/view/set/selected_scene", [6]},
               {"/live/view/show_view", ["Session"]}
             ]

      assert FollowCam.calls("delete_scene", %{scene: 1, remaining: 5}) == [
               {"/live/view/set/selected_scene", [1]},
               {"/live/view/show_view", ["Session"]}
             ]
    end

    test "deleting the last scene steers nowhere" do
      assert FollowCam.calls("delete_scene", %{scene: 0, remaining: 0}) == []
    end
  end

  describe "devices" do
    test "a load selects the device and opens the chain" do
      assert FollowCam.calls("load_device", %{track: 1, device: 0}) == [
               {"/live/view/set/selected_device", [1, 0]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    # -1 is load_item's "not on the chain yet" — an asynchronously instantiating
    # VST/AU. Selecting the track still opens the chain it is arriving on.
    test "a load with no device index yet falls back to the track" do
      assert FollowCam.calls("load_device", %{track: 2, device: -1}) == [
               {"/live/view/set/selected_track", [2]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "bypass shows the device it toggled" do
      assert FollowCam.calls("bypass_device", %{track: 0, device: 2}) == [
               {"/live/view/set/selected_device", [0, 2]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "deleting from the middle of a chain lands on the successor" do
      assert FollowCam.calls("delete_device", %{track: 1, device: 0, remaining: 2}) == [
               {"/live/view/set/selected_device", [1, 0]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "deleting the last device in a chain clamps back one" do
      assert FollowCam.calls("delete_device", %{track: 1, device: 2, remaining: 2}) == [
               {"/live/view/set/selected_device", [1, 1]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    # An empty chain has no device to select, and is itself the evidence that
    # the delete landed — so show it.
    test "emptying a chain shows the empty chain on its track" do
      assert FollowCam.calls("delete_device", %{track: 3, device: 0, remaining: 0}) == [
               {"/live/view/set/selected_track", [3]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end
  end

  # `/live/view/set/selected_track` and `set/selected_device` index `song.tracks`,
  # where returns and the master don't appear — so every clause below has to use
  # one of Seshat's own selects. Steering a return's device with the regular
  # address wouldn't fail; it would silently show a *different* track's device,
  # which is the whole reason these are separate clauses rather than one.
  describe "devices on return tracks" do
    test "a load selects the device on the return and opens the chain" do
      assert FollowCam.calls("load_device", %{return: 1, device: 0}) == [
               {"/live/return_track/select_device", [1, 0]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "a load with no device index yet falls back to the return itself" do
      assert FollowCam.calls("load_device", %{return: 2, device: -1}) == [
               {"/live/return_track/select", [2]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "bypass shows the return's device it toggled" do
      assert FollowCam.calls("bypass_device", %{return: 0, device: 2}) == [
               {"/live/return_track/select_device", [0, 2]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "deleting from the middle of a return's chain lands on the successor" do
      assert FollowCam.calls("delete_device", %{return: 1, device: 0, remaining: 2}) == [
               {"/live/return_track/select_device", [1, 0]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "deleting the last device on a return clamps back one" do
      assert FollowCam.calls("delete_device", %{return: 1, device: 2, remaining: 2}) == [
               {"/live/return_track/select_device", [1, 1]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "emptying a return's chain shows the empty chain on the return" do
      assert FollowCam.calls("delete_device", %{return: 3, device: 0, remaining: 0}) == [
               {"/live/return_track/select", [3]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end
  end

  describe "devices on the master track" do
    # The master has no index at all, so its facts carry `master: true` rather
    # than a number — and both of its select addresses take one argument fewer.
    test "a load selects the device on the master and opens the chain" do
      assert FollowCam.calls("load_device", %{master: true, device: 1}) == [
               {"/live/master/select_device", [1]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "a load with no device index yet falls back to the master itself" do
      assert FollowCam.calls("load_device", %{master: true, device: -1}) == [
               {"/live/master/select", []},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "bypass shows the master's device it toggled" do
      assert FollowCam.calls("bypass_device", %{master: true, device: 0}) == [
               {"/live/master/select_device", [0]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "deleting from the middle of the master's chain lands on the successor" do
      assert FollowCam.calls("delete_device", %{master: true, device: 0, remaining: 2}) == [
               {"/live/master/select_device", [0]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "deleting the last device on the master clamps back one" do
      assert FollowCam.calls("delete_device", %{master: true, device: 2, remaining: 2}) == [
               {"/live/master/select_device", [1]},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end

    test "emptying the master's chain shows the empty chain on the master" do
      assert FollowCam.calls("delete_device", %{master: true, device: 0, remaining: 0}) == [
               {"/live/master/select", []},
               {"/live/view/show_view", ["Detail/DeviceChain"]}
             ]
    end
  end

  describe "tools that don't steer" do
    # The in-list is settled and exhaustive: parameter tweaks, transport,
    # renames and reads deliberately leave the view alone. A view that jumps on
    # every volume nudge is what would make someone ask for the off switch this
    # design doesn't have.
    test "a parameter tweak, a transport call and a rename produce no calls" do
      assert FollowCam.calls("set_mixer", %{track: 0}) == []
      assert FollowCam.calls("fire_clip", %{track: 0, slot: 0}) == []
      assert FollowCam.calls("set_mixer", %{return: 0}) == []
      assert FollowCam.calls("get_session_state", %{}) == []
      assert FollowCam.calls("get_clip_properties", %{track: 0, slot: 0}) == []
    end

    test "a steering tool called without the facts it needs produces no calls" do
      assert FollowCam.calls("delete_track", %{track: 1}) == []
      assert FollowCam.calls("load_device", %{track: 1}) == []
    end
  end

  describe "steer/2" do
    # Nothing is listening in the test environment, so this exercises exactly
    # the path that must never fail a tool: Transport absent or dead.
    test "returns :ok with no transport running" do
      assert FollowCam.steer("write_midi_notes", %{track: 0, slot: 0}) == :ok
    end

    test "returns :ok for a tool that doesn't steer" do
      assert FollowCam.steer("set_tempo", %{}) == :ok
    end
  end
end
