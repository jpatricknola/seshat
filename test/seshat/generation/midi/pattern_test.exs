defmodule Seshat.Generation.Midi.PatternTest do
  use ExUnit.Case, async: true

  alias Seshat.Generation.Midi.Pattern

  defp beats(onsets), do: Enum.map(onsets, & &1.beat)
  defp accents(onsets), do: Enum.map(onsets, & &1.accent)

  describe "compile/4" do
    test "one bar of 1/16 lands four steps per beat" do
      assert {:ok, onsets} = Pattern.compile("X-x-x-x-X-x-x-x-", "1/16", 1, 4)

      assert beats(onsets) == [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5]
      assert accents(onsets) == [:accent, :hit, :hit, :hit, :accent, :hit, :hit, :hit]
      assert Enum.all?(onsets, &(&1.step_beats == 0.25))
    end

    test "every resolution divides the beat the way its name says" do
      for {resolution, per_beat} <- [
            {"1/8", 2},
            {"1/8T", 3},
            {"1/16", 4},
            {"1/16T", 6},
            {"1/32", 8}
          ] do
        pattern = String.duplicate("x", per_beat * 4)
        assert {:ok, onsets} = Pattern.compile(pattern, resolution, 1, 4)
        assert length(onsets) == per_beat * 4
        assert List.first(onsets).step_beats == 1 / per_beat
      end
    end

    test "ghosts and rests are distinguished, and rests produce no onset" do
      assert {:ok, onsets} = Pattern.compile("Xg-x", "1/16", 1, 1)
      assert beats(onsets) == [0.0, 0.25, 0.75]
      assert accents(onsets) == [:accent, :ghost, :hit]
    end

    # A model laying a pattern out readably must compile identically to one
    # written as a single run — otherwise the grammar punishes legibility.
    test "bar separators and whitespace are ignored" do
      assert Pattern.compile("x-x-|x-x-", "1/16", 1, 4) ==
               Pattern.compile("x-x- x-x-", "1/16", 1, 4)

      assert Pattern.compile("x-x-|x-x-", "1/16", 1, 4) ==
               Pattern.compile("x-x-x-x-", "1/16", 1, 4)
    end
  end

  describe "filling the bars" do
    test "a one-bar pattern repeats whole across four" do
      assert {:ok, onsets} = Pattern.compile("x---x---x---x---", "1/16", 4, 4)
      assert length(onsets) == 16
      assert beats(onsets) == Enum.map(0..15, &(&1 * 1.0))
    end

    test "a length that does not divide is refused, naming both lengths" do
      assert {:error, message} = Pattern.compile(String.duplicate("x", 12), "1/16", 4, 4)
      assert message =~ "12 steps long"
      assert message =~ "clip holds 64"
      assert message =~ "repeated whole, never cut"
      assert message =~ "Nothing was written."
    end

    test "a pattern longer than the clip is refused rather than truncated" do
      assert {:error, message} = Pattern.compile(String.duplicate("x", 20), "1/16", 1, 4)
      assert message =~ "20 steps long"
      assert message =~ "16 steps fit"
    end
  end

  describe "refusals" do
    test "a bad character is named with its position among the steps" do
      assert {:error, message} = Pattern.compile("x-x-o-x-", "1/16", 1, 4)
      assert message =~ "step 5"
      assert message =~ "\"o\""
      assert message =~ "X for an accent"
    end

    # Positions count *steps*, not bytes: a model that laid its bars out with
    # separators would otherwise be told to fix a position it cannot find.
    test "the position ignores separators and whitespace" do
      assert {:error, message} = Pattern.compile("x-x- | x-o-", "1/16", 1, 4)
      assert message =~ "step 7"
    end

    test "an empty pattern is refused" do
      assert {:error, message} = Pattern.compile("||  ", "1/16", 1, 4)
      assert message =~ "no steps in it"
    end

    test "an unknown resolution names the ones that exist" do
      assert {:error, message} = Pattern.compile("xxxx", "1/12", 1, 4)
      assert message =~ "1/16T"
    end

    # 7/8 is 3.5 beats to the bar, which is 10.5 triplet-8ths — not a grid.
    test "a bar that does not divide into whole steps is refused as a signature problem" do
      assert {:error, message} = Pattern.compile("xxx", "1/8T", 1, 3.5)
      assert message =~ "3.5 beats"
      assert message =~ "set_time_signature"
    end
  end

  describe "size" do
    # The dense case the write chunker exists for: 16 bars of 1/32 is 512 steps.
    test "sixteen bars at 1/32 compiles 512 onsets" do
      pattern = String.duplicate("x", 32)
      assert {:ok, onsets} = Pattern.compile(pattern, "1/32", 16, 4)
      assert length(onsets) == 512
      assert List.last(onsets).beat == 63.875
    end
  end
end
