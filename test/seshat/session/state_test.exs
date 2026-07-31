defmodule Seshat.Session.StateTest do
  use ExUnit.Case, async: true

  alias Seshat.Session.State

  # The GenServer isn't started here — its init queries Ableton over OSC, which
  # needs a live Live. The listener-push handling is pure given a state map, so
  # it is exercised by calling handle_info/2 directly.
  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        song: %{
          tempo: 120.0,
          time_sig_numerator: 4,
          time_sig_denominator: 4,
          is_playing: false,
          root_note: 0,
          scale_name: "Major",
          groove_amount: nil,
          swing_amount: nil
        },
        tracks: [],
        return_tracks: [],
        master: nil,
        returns_readable?: true,
        unreconciled: %{}
      },
      overrides
    )
  end

  defp track(index, name) do
    %{index: index, name: name, volume: 0.85, pan: 0.0, mute: false, solo: false}
  end

  defp return(index, name) do
    %{index: index, name: name, volume: 0.85, pan: 0.0, mute: false, solo: false}
  end

  defp master(overrides \\ %{}) do
    Map.merge(%{volume: 0.85, pan: 0.0, cue_volume: 0.85}, overrides)
  end

  defp push(state, address, args) do
    {:noreply, state} = State.handle_info({:osc_message, address, args}, state)
    state
  end

  describe "song property pushes" do
    test "records a new root note" do
      state = push(state(), "/live/song/get/root_note", [7])

      assert state.song.root_note == 7
    end

    test "records a new scale name" do
      state = push(state(), "/live/song/get/scale_name", ["Minor"])

      assert state.song.scale_name == "Minor"
    end

    test "key changes leave the rest of the song state alone" do
      state =
        state()
        |> push("/live/song/get/root_note", [2])
        |> push("/live/song/get/scale_name", ["Dorian"])

      assert state.song.root_note == 2
      assert state.song.scale_name == "Dorian"
      assert state.song.tempo == 120.0
      assert state.song.time_sig_numerator == 4
    end

    # The listener echo is the only verification channel these two setters have:
    # /live/song/set/* never replies, so a push landing here is what proves the
    # value took. `swing_amount` additionally comes from the fork's song.py.
    test "records a new swing amount" do
      state = push(state(), "/live/song/get/swing_amount", [0.25])

      assert state.song.swing_amount == 0.25
    end

    test "records a new groove amount" do
      state = push(state(), "/live/song/get/groove_amount", [1.3])

      assert state.song.groove_amount == 1.3
    end

    test "swing and groove changes leave the rest of the song state alone" do
      state =
        state()
        |> push("/live/song/get/swing_amount", [0.16])
        |> push("/live/song/get/groove_amount", [+0.0])

      assert state.song.swing_amount == 0.16
      assert state.song.groove_amount == +0.0
      assert state.song.tempo == 120.0
      assert state.song.scale_name == "Major"
    end

    test "still handles the properties that were already listened to" do
      state =
        state()
        |> push("/live/song/get/tempo", [128.0])
        |> push("/live/song/get/is_playing", [1])

      assert state.song.tempo == 128.0
      assert state.song.is_playing == true
    end

    test "an unhandled address is ignored rather than crashing" do
      assert push(state(), "/live/song/get/something_new", [1]) == state()
    end
  end

  describe "stale?/2" do
    test "the same names in the same order are not stale" do
      refute State.stale?([track(0, "Drums"), track(1, "Bass")], ["Drums", "Bass"])
    end

    test "a deleted track is stale" do
      assert State.stale?([track(0, "Drums"), track(1, "Bass")], ["Drums"])
    end

    test "an added track is stale" do
      assert State.stale?([track(0, "Drums")], ["Drums", "Bass"])
    end

    test "a rename is stale" do
      assert State.stale?([track(0, "Drums")], ["Beats"])
    end

    test "a reorder is stale even though the same names are present" do
      assert State.stale?([track(0, "Drums"), track(1, "Bass")], ["Bass", "Drums"])
    end

    test "an empty mirror against a live session is stale" do
      assert State.stale?([], ["Drums"])
    end

    test "an empty mirror against an empty session is not stale" do
      refute State.stale?([], [])
    end

    # `nil` is "we could not read the list", which is a different fact from "the
    # list is empty" and must not reconcile against anything. Being stale against
    # every pushed list is what heals a failed refresh: the next structure push
    # disagrees by definition and triggers the authoritative re-read.
    test "an unknown mirror is stale against an empty session" do
      assert State.stale?(nil, [])
    end

    test "an unknown mirror is stale against a live session" do
      assert State.stale?(nil, ["Drums"])
    end
  end

  describe "song structure pushes" do
    test "a track list matching the mirror leaves the state untouched" do
      mirrored = state(%{tracks: [track(0, "Drums"), track(1, "Bass")]})

      assert push(mirrored, "/live/song/get/tracks", ["Drums", "Bass"]) == mirrored
    end

    test "a return list matching the mirror leaves the state untouched" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      assert push(mirrored, "/live/song/get/return_tracks", ["Reverb"]) == mirrored
    end

    # A return list that disagrees with the mirror normally triggers do_refresh,
    # which needs Ableton. When returns aren't readable it must not — otherwise
    # each push refreshes, each refresh re-subscribes, and each re-subscribe
    # pushes again, forever. That branch is pure, so it is the one testable half
    # of the disagreement case.
    test "a disagreeing return list is ignored while returns are unreadable" do
      mirrored = state(%{return_tracks: [], returns_readable?: false})

      assert push(mirrored, "/live/song/get/return_tracks", ["Reverb"]) == mirrored
    end

    # The brake against an unbounded refresh spin: a refresh that comes back
    # still disagreeing records the list it failed on, and a repeat of that exact
    # list must not refresh again. Pre-setting the record is what makes the
    # branch reachable without Ableton — taking it means do_refresh is never
    # called, which is the whole assertion.
    test "a name list that already failed to reconcile is not refreshed on again" do
      mirrored =
        state(%{
          tracks: [track(0, "Drums")],
          unreconciled: %{tracks: ["Drums", "Bass"]}
        })

      assert push(mirrored, "/live/song/get/tracks", ["Drums", "Bass"]) == mirrored
    end

    # A refresh that couldn't read the track count leaves `tracks: nil`, and
    # `stale?(nil, _)` is true, so without the brake every subsequent push would
    # refresh again — the unbounded spin, reached by the failure path this whole
    # change adds. Pre-setting the record proves the brake still holds when the
    # mirror side is unknown rather than a list.
    test "the brake still holds when the mirror side is unknown" do
      mirrored =
        state(%{
          tracks: nil,
          unreconciled: %{tracks: ["Drums", "Bass"]}
        })

      assert push(mirrored, "/live/song/get/tracks", ["Drums", "Bass"]) == mirrored
    end

    test "the return list gets the same brake" do
      mirrored =
        state(%{
          return_tracks: [return(0, "Reverb")],
          unreconciled: %{return_tracks: ["Reverb", "Delay"]}
        })

      assert push(mirrored, "/live/song/get/return_tracks", ["Reverb", "Delay"]) == mirrored
    end

    # A *different* list has to get a fresh attempt, or one unreconcilable push
    # would deafen the mirror to every real change after it.
    test "a list that matches the mirror lifts the brake" do
      mirrored =
        state(%{
          tracks: [track(0, "Drums")],
          unreconciled: %{tracks: ["Drums", "Bass"]}
        })

      state = push(mirrored, "/live/song/get/tracks", ["Drums"])

      assert state.unreconciled == %{}
    end
  end

  describe "track scalar pushes onto an unknown track list" do
    # A failed refresh leaves `tracks: nil` — unknown, not empty. A scalar push
    # for a list we don't hold has nothing to land on, and building a one-track
    # mirror out of a volume push would invent every other field. Dropped, and
    # the next structure push re-reads the lot.
    test "a volume push is a no-op" do
      mirrored = state(%{tracks: nil})

      assert push(mirrored, "/live/track/get/volume", [0, 0.5]) == mirrored
    end

    test "a name push is a no-op" do
      mirrored = state(%{tracks: nil})

      assert push(mirrored, "/live/track/get/name", [0, "Drums"]) == mirrored
    end

    test "a mute push is a no-op" do
      mirrored = state(%{tracks: nil})

      assert push(mirrored, "/live/track/get/mute", [0, 1]) == mirrored
    end
  end

  describe "return track and master pushes" do
    test "a name push updates that return and no other" do
      state =
        %{return_tracks: [return(0, "Reverb"), return(1, "Delay")]}
        |> state()
        |> push("/live/return_track/get/name", [1, "Tape Delay"])

      assert Enum.map(state.return_tracks, & &1.name) == ["Reverb", "Tape Delay"]
    end

    test "a name query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/name", [0, "ok", "Hall"])

      assert Enum.map(state.return_tracks, & &1.name) == ["Hall"]
    end

    test "a volume push updates that return and no other" do
      state =
        %{return_tracks: [return(0, "Reverb"), return(1, "Delay")]}
        |> state()
        |> push("/live/return_track/get/volume", [0, 0.5])

      assert Enum.map(state.return_tracks, & &1.volume) == [0.5, 0.85]
    end

    test "a volume query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/volume", [0, "ok", 0.25])

      assert Enum.map(state.return_tracks, & &1.volume) == [0.25]
    end

    test "a push for an index the mirror doesn't have is a no-op" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      assert push(mirrored, "/live/return_track/get/volume", [3, 0.5]) == mirrored
    end

    test "a pan push updates that return and no other" do
      state =
        %{return_tracks: [return(0, "Reverb"), return(1, "Delay")]}
        |> state()
        |> push("/live/return_track/get/panning", [1, -0.4])

      assert Enum.map(state.return_tracks, & &1.pan) == [0.0, -0.4]
    end

    test "a pan query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/panning", [0, "ok", 0.25])

      assert Enum.map(state.return_tracks, & &1.pan) == [0.25]
    end

    # The getter replies 0/1 and Live's own listener pushes a bool, so both
    # spellings have to normalize — otherwise the mirror holds two ways of
    # saying "muted" and every reader has to know both.
    test "a mute push normalizes an int to a boolean" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/mute", [0, 1])

      assert Enum.map(state.return_tracks, & &1.mute) == [true]
    end

    test "a mute push normalizes a bool the same way" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/mute", [0, true])

      assert Enum.map(state.return_tracks, & &1.mute) == [true]
    end

    test "a mute query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/mute", [0, "ok", 1])

      assert Enum.map(state.return_tracks, & &1.mute) == [true]
    end

    test "a solo push normalizes and touches only that return" do
      state =
        %{return_tracks: [return(0, "Reverb"), return(1, "Delay")]}
        |> state()
        |> push("/live/return_track/get/solo", [1, 1])

      assert Enum.map(state.return_tracks, & &1.solo) == [false, true]
    end

    test "a solo query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/solo", [0, "ok", 0])

      assert Enum.map(state.return_tracks, & &1.solo) == [false]
    end

    test "a master volume push leaves pan and cue volume alone" do
      state =
        %{master: master()}
        |> state()
        |> push("/live/master/get/volume", [0.7])

      assert state.master == %{volume: 0.7, pan: 0.0, cue_volume: 0.85}
    end

    test "a master pan push leaves volume and cue volume alone" do
      state =
        %{master: master()}
        |> state()
        |> push("/live/master/get/panning", [-0.25])

      assert state.master == %{volume: 0.85, pan: -0.25, cue_volume: 0.85}
    end

    test "a cue volume push leaves volume and pan alone" do
      state =
        %{master: master()}
        |> state()
        |> push("/live/master/get/cue_volume", [0.4])

      assert state.master == %{volume: 0.85, pan: 0.0, cue_volume: 0.4}
    end

    # There is exactly one master, so there is no index to be wrong about — a
    # push arriving before any refresh has read one builds the map rather than
    # being dropped. The fields it doesn't carry stay unknown, never 0.0.
    test "a master push into an empty mirror builds it with the rest unknown" do
      state = push(state(), "/live/master/get/panning", [0.5])

      assert state.master == %{volume: nil, pan: 0.5, cue_volume: nil}
    end

    # The error envelope shares its address and arity with the ok envelope, so
    # only the literal "ok" and the float guard keep the message text out of the
    # mirror. Relax either and a return gets named "error".
    test "a name error envelope is ignored rather than mirrored" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      assert push(mirrored, "/live/return_track/get/name", [0, "error", "no such return"]) ==
               mirrored
    end

    test "a volume error envelope is ignored rather than mirrored" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      assert push(mirrored, "/live/return_track/get/volume", [0, "error", "no such return"]) ==
               mirrored
    end

    test "pan, mute and solo error envelopes are ignored rather than mirrored" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      for address <- [
            "/live/return_track/get/panning",
            "/live/return_track/get/mute",
            "/live/return_track/get/solo"
          ] do
        assert push(mirrored, address, [0, "error", "no such return"]) == mirrored
      end
    end
  end

  # `/live/startup` and the stale branches of the two structure pushes all call
  # do_refresh/1, which queries Ableton — untestable here by design
  # (testing.md: never reach Transport.query/3), and covered by /smoke-test.
end
