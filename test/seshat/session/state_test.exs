defmodule Seshat.Session.StateTest do
  use ExUnit.Case, async: true

  alias Seshat.Session.State

  # The GenServer isn't started here — its init queries Ableton over OSC, which
  # needs a live Live. The listener-push handling is pure given a state map, so
  # it is exercised by calling handle_info/2 directly.
  defp state do
    %{
      song: %{
        tempo: 120.0,
        time_sig_numerator: 4,
        time_sig_denominator: 4,
        is_playing: false,
        root_note: 0,
        scale_name: "Major"
      },
      tracks: []
    }
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
end
