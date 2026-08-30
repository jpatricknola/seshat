defmodule Seshat.Generation.Midi.PerformanceTest do
  use ExUnit.Case, async: true

  alias Seshat.Generation.Midi.Pattern
  alias Seshat.Generation.Midi.Performance
  alias Seshat.Generation.Midi.Profiles

  defp onsets(pattern \\ "x-x-x-x-x-x-x-x-", bars \\ 1) do
    {:ok, onsets} = Pattern.compile(pattern, "1/16", bars, 4)
    onsets
  end

  defp context(overrides \\ %{}) do
    {:ok, _lane_name, lane} = Profiles.lane_for("rock", 36)

    Map.merge(
      %{
        pitch: 36,
        lane: lane,
        humanize: 1.0,
        swing: 0.0,
        seed: 7,
        part_index: 0,
        clip_beats: 4.0,
        beats_per_bar: 4
      },
      overrides
    )
  end

  describe "determinism" do
    test "the same seed twice is the same take, note for note" do
      first = Performance.perform(onsets(), context())
      second = Performance.perform(onsets(), context())

      assert first == second
    end

    test "a different seed is a different take" do
      first = Performance.perform(onsets(), context())
      second = Performance.perform(onsets(), context(%{seed: 8}))

      refute first == second
    end

    # Two parts of one request must not share a stream, or adding a hat lane
    # would silently change the kick's feel.
    test "the part index separates the streams" do
      first = Performance.perform(onsets(), context())
      second = Performance.perform(onsets(), context(%{part_index: 1}))

      refute first == second
    end
  end

  describe "humanize: 0.0" do
    # The A/B arm the acceptance slate needs. Not "nearly mechanical": exactly
    # the grid, or the comparison settles nothing.
    test "is the raw grid, exactly" do
      notes = Performance.perform(onsets(), context(%{humanize: 0.0}))

      assert Enum.map(notes, & &1.start_time) == Enum.map(onsets(), & &1.beat)
      assert Enum.all?(notes, &(&1.velocity_deviation == 0.0))
      assert Enum.all?(notes, &(&1.probability == 1.0))
    end

    test "flattens velocity to one value per accent class" do
      {:ok, gridded} = Pattern.compile("Xxg-", "1/16", 1, 1)
      notes = Performance.perform(gridded, context(%{humanize: 0.0, clip_beats: 1.0}))

      assert [accent, hit, ghost] = Enum.map(notes, & &1.velocity)
      assert accent > hit
      assert hit > ghost
      # No contour, no jitter: the same class twice is the same number.
      repeat = Performance.perform(gridded, context(%{humanize: 0.0, clip_beats: 1.0, seed: 99}))
      assert Enum.map(repeat, & &1.velocity) == [accent, hit, ghost]
    end

    # Ghost probability is a *variation* mechanism, so it belongs with the rest
    # of the feel rather than surviving into the mechanical arm.
    test "leaves ghosts certain" do
      {:ok, gridded} = Pattern.compile("g-g-", "1/16", 1, 1)
      notes = Performance.perform(gridded, context(%{humanize: 0.0, clip_beats: 1.0}))

      assert Enum.all?(notes, &(&1.probability == 1.0))
    end
  end

  describe "the performed take" do
    test "moves notes off the grid without reordering them" do
      notes = Performance.perform(onsets(), context())
      starts = Enum.map(notes, & &1.start_time)

      assert starts == Enum.sort(starts)
      assert Enum.any?(Enum.zip(starts, Enum.map(onsets(), & &1.beat)), fn {a, b} -> a != b end)
    end

    test "never starts a note before the clip or at its end" do
      notes = Performance.perform(onsets(), context(%{humanize: 1.0}))

      assert Enum.all?(notes, &(&1.start_time >= 0.0))
      assert Enum.all?(notes, &(&1.start_time < 4.0))
      assert Enum.all?(notes, &(&1.start_time + &1.duration <= 4.0 + 1.0e-9))
    end

    test "keeps every displacement inside three sigma of the lane's own spread" do
      {:ok, _lane_name, lane} = Profiles.lane_for("jazz", 42)
      gridded = onsets()
      notes = Performance.perform(gridded, context(%{lane: lane}))

      ceiling = (abs(lane["timing_mean"]) + 3 * lane["timing_sd"]) * 0.25 + 1.0e-6

      for {note, onset} <- Enum.zip(notes, gridded) do
        assert abs(note.start_time - onset.beat) <= ceiling
      end
    end

    test "accents are louder than hits, which are louder than ghosts" do
      {:ok, gridded} = Pattern.compile("X-x-g-x-", "1/16", 1, 2)
      notes = Performance.perform(gridded, context(%{clip_beats: 2.0}))
      [accent, hit, ghost, _hit] = Enum.map(notes, & &1.velocity)

      assert accent > hit
      assert hit > ghost
    end

    test "ghosts carry a chance below one and everything else is certain" do
      {:ok, gridded} = Pattern.compile("X-g-", "1/16", 1, 1)
      [accent, ghost] = Performance.perform(gridded, context(%{clip_beats: 1.0}))

      assert accent.probability == 1.0
      assert ghost.probability < 1.0
      assert ghost.probability > 0.0
    end

    test "velocity stays inside Live's range at an extreme profile" do
      lane = %{
        "timing_mean" => 0.0,
        "timing_sd" => 0.0,
        "velocity_sd" => 200.0,
        "ghost_probability" => 0.5,
        "velocity" => %{
          "accent" => %{"mean" => 126.0, "sd" => 90.0},
          "hit" => %{"mean" => 3.0, "sd" => 90.0},
          "ghost" => %{"mean" => 1.0, "sd" => 90.0}
        }
      }

      notes = Performance.perform(onsets("Xxg-Xxg-Xxg-Xxg-"), context(%{lane: lane}))

      assert Enum.all?(notes, &(&1.velocity >= 1.0 and &1.velocity <= 127.0))
      assert Enum.all?(notes, &(&1.velocity_deviation <= 48.0))
    end

    test "every note carries the eight fields Live's extended address takes" do
      [note | _rest] = Performance.perform(onsets(), context())

      assert Map.keys(note) |> Enum.sort() ==
               ~w(duration mute pitch probability release_velocity start_time velocity
                  velocity_deviation)a

      assert note.mute == 0
      assert note.release_velocity == 64.0
    end
  end

  describe "swing" do
    # Off-8ths only: the "and" of the beat, not every 16th and not the downbeat.
    test "displaces the off-8ths and leaves the on-beats alone" do
      {:ok, gridded} = Pattern.compile("x-x-", "1/16", 1, 1)
      straight = Performance.perform(gridded, context(%{humanize: 1.0, swing: 0.0, seed: 3}))
      swung = Performance.perform(gridded, context(%{humanize: 1.0, swing: 0.5, seed: 3}))

      [on_straight, off_straight] = Enum.map(straight, & &1.start_time)
      [on_swung, off_swung] = Enum.map(swung, & &1.start_time)

      assert on_straight == on_swung
      assert off_swung > off_straight
    end

    test "no swing survives humanize 0.0" do
      {:ok, gridded} = Pattern.compile("x-x-", "1/16", 1, 1)
      notes = Performance.perform(gridded, context(%{humanize: 0.0, swing: 1.0}))

      assert Enum.map(notes, & &1.start_time) == [0.0, 0.5]
    end
  end
end
