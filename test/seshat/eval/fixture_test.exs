defmodule Seshat.Eval.FixtureTest do
  use ExUnit.Case, async: true

  alias Seshat.Eval.Fixture

  setup do
    {:ok, fixture: Fixture.load!("named_tracks_and_reverb")}
  end

  describe "get_session_state" do
    # Rendered by `Handlers.format_session_state/5` itself. If the fixture grew
    # its own prose, the model under test would be reading text no user ever
    # sees, and the routing measured would be routing against a different
    # contract.
    test "reads through the real formatter", %{fixture: fixture} do
      {:ok, text} = Fixture.call(fixture, "get_session_state", %{})

      assert text =~ "120.0 BPM, 4/4, stopped, key: C Major"
      assert text =~ ~s{Track 0 "Drums": pan=0.0, volume=0.85}
      assert text =~ ~s{Track 1 "Bass"}
      assert text =~ ~s{Return 0 "Reverb" (send A): volume=0.7}
      assert text =~ ~s{Return 1 "Delay" (send B)}
      assert text =~ "Master (shown as Main in Live 12): volume=0.85"
      refute text =~ "unknown"
    end
  end

  describe "get_clip_notes" do
    test "renders the fixture's four notes", %{fixture: fixture} do
      {:ok, text} = Fixture.call(fixture, "get_clip_notes", %{"track" => 1})

      assert text =~ ~s{Clip "Bass" on track 1, slot 0}
      assert text =~ "4 note(s)"
      assert text =~ "C2 (36)"
      assert text =~ "D#2 (39)"
      assert text =~ "G2 (43)"
    end

    test "honours the pitch and time window", %{fixture: fixture} do
      {:ok, text} =
        Fixture.call(fixture, "get_clip_notes", %{
          "track" => 1,
          "start_time" => 2.0,
          "time_span" => 1.0
        })

      assert text =~ "1 note(s)"
      assert text =~ "D#2 (39)"
      refute text =~ "G2 (43)"
    end

    test "a clip the fixture does not hold is an error, not an empty clip", %{fixture: fixture} do
      assert {:error, text} = Fixture.call(fixture, "get_clip_notes", %{"track" => 0})
      assert text =~ "No clip in slot 0 on track 0 in this evaluation fixture"
    end
  end

  describe "get_clip_slots" do
    test "shows the grid through the real formatter", %{fixture: fixture} do
      {:ok, text} = Fixture.call(fixture, "get_clip_slots", %{})

      assert text =~ "2 scene(s)"
      assert text =~ ~s{Track 0 "Drums" (audio): all 2 slot(s) empty}
      assert text =~ ~s{Track 1 "Bass" (MIDI):}
      assert text =~ ~s{slot 0: "Bass" — 4.0 beats}
    end
  end

  describe "mutations" do
    test "succeed, name what was asked for, and change nothing", %{fixture: fixture} do
      {:ok, text} =
        Fixture.call(fixture, "set_mixer", %{"target" => "master", "volume" => 0.75})

      assert text =~ "Done: set_mixer target=master, volume=0.75"
      assert text =~ "nothing was sent to Ableton"

      {:ok, after_text} = Fixture.call(fixture, "get_session_state", %{})
      assert after_text =~ "Master (shown as Main in Live 12): volume=0.85"
    end

    test "a mutation with no arguments still succeeds", %{fixture: fixture} do
      assert {:ok, text} = Fixture.call(fixture, "undo", %{})
      assert text =~ "Done."
    end
  end

  describe "unsupported reads" do
    test "are errors naming the fixture, so nothing proceeds on invented state", %{
      fixture: fixture
    } do
      assert {:error, text} = Fixture.call(fixture, "get_track_devices", %{"track" => 0})
      assert text =~ "not available in this evaluation fixture"
    end
  end
end
