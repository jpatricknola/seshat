defmodule Seshat.Generation.Midi.BassTest do
  use ExUnit.Case, async: true

  alias Seshat.Generation.Midi.Bass
  alias Seshat.Generation.Midi.Pattern

  defp kick(pattern, bars \\ 1) do
    {:ok, onsets} = Pattern.compile(pattern, "1/16", bars, 4)
    onsets
  end

  defp spec(overrides) do
    Map.merge(
      %{
        role: "Bass",
        pattern: nil,
        relationship: nil,
        resolution: "1/16",
        roots: [36],
        bars: 1,
        beats_per_bar: 4
      },
      overrides
    )
  end

  defp beats(onsets), do: Enum.map(onsets, & &1.beat)

  describe "lock" do
    test "lands on exactly the followed onsets, and nowhere else" do
      followed = kick("x-------x---x---")
      assert {:ok, onsets} = Bass.compile(spec(%{relationship: "lock"}), followed)

      assert beats(onsets) == Enum.map(followed, & &1.beat)
    end

    test "collapses two drum onsets that share a beat into one bass note" do
      followed = [
        %{beat: 0.0, accent: :accent, step_beats: 0.25},
        %{beat: 0.0, accent: :hit, step_beats: 0.25},
        %{beat: 2.0, accent: :hit, step_beats: 0.25}
      ]

      assert {:ok, onsets} = Bass.compile(spec(%{relationship: "lock"}), followed)
      assert beats(onsets) == [0.0, 2.0]
    end
  end

  describe "answer" do
    test "plays the 8th after an isolated onset and never on the onset itself" do
      followed = kick("x---------------")
      assert {:ok, onsets} = Bass.compile(spec(%{relationship: "answer"}), followed)

      assert beats(onsets) == [0.5]
    end

    # A busy kick is the case `answer` exists to stay out of: an onset with
    # another within a beat of it is left alone.
    test "stays out of the way of onsets that are already answered" do
      followed = kick("x---x-------x---")
      assert {:ok, onsets} = Bass.compile(spec(%{relationship: "answer"}), followed)

      # Onsets sit on beats 0, 1 and 3. Beat 0 has beat 1 within a beat of it,
      # so it is left alone; beats 1 and 3 are isolated and get answered.
      assert beats(onsets) == [1.5, 3.5]
      refute Enum.any?(onsets, fn onset -> onset.beat in Enum.map(followed, & &1.beat) end)
    end

    test "an answer past the end of the clip is dropped rather than clipped" do
      followed = kick("---------------x")
      assert {:ok, onsets} = Bass.compile(spec(%{relationship: "answer"}), followed)

      assert beats(onsets) == []
    end
  end

  describe "sustain" do
    test "spans the bar's first followed onset to its last" do
      followed = kick("x-------x-------|x-------x---x---", 2)

      assert {:ok, [first, second]} =
               Bass.compile(spec(%{relationship: "sustain", bars: 2, roots: [36, 38]}), followed)

      assert first.beat == 0.0
      # First onset at beat 0, last at beat 2, held just short of the next note.
      assert_in_delta first.duration, 1.9, 0.001
      assert second.beat == 4.0
      assert second.pitch == 38
    end

    # A bar the drums leave empty gets no bass note: inventing one would be the
    # module's own idea rather than the drummer's.
    test "a bar with no followed onsets gets no note" do
      followed = kick("x-------x-------|----------------", 2)

      assert {:ok, onsets} =
               Bass.compile(spec(%{relationship: "sustain", bars: 2, roots: [36, 38]}), followed)

      assert beats(onsets) == [0.0]
    end
  end

  describe "independence from the drums" do
    # The shortcut this module exists not to take: copying the kick's velocity
    # contour makes a "conditioned" bass sound like a kick with pitch.
    test "drum accents change nothing about the bass" do
      loud = Enum.map(kick("x---x---x---x---"), &%{&1 | accent: :accent})
      quiet = Enum.map(kick("x---x---x---x---"), &%{&1 | accent: :ghost})

      assert Bass.compile(spec(%{relationship: "lock"}), loud) ==
               Bass.compile(spec(%{relationship: "lock"}), quiet)
    end

    test "the phrase shape is positional: the bar's first note leads" do
      followed = kick("x---x---x---x---")
      assert {:ok, [first | rest]} = Bass.compile(spec(%{relationship: "lock"}), followed)

      assert first.accent == :accent
      assert Enum.all?(rest, &(&1.accent in [:hit, :ghost]))
    end

    # A note a 16th before the next one is a pickup, and pickups are ghosted.
    test "a note immediately before the next is ghosted" do
      followed = kick("x--xx-----------")
      assert {:ok, onsets} = Bass.compile(spec(%{relationship: "lock"}), followed)

      assert Enum.map(onsets, & &1.accent) == [:accent, :ghost, :hit]
    end
  end

  describe "pitching" do
    test "each bar takes its own root" do
      followed = kick("x-------x-------x-------x-------", 4)

      assert {:ok, onsets} =
               Bass.compile(
                 spec(%{relationship: "lock", bars: 4, roots: [36, 38, 40, 41]}),
                 followed
               )

      assert Enum.map(onsets, & &1.pitch) == [36, 36, 38, 38, 40, 40, 41, 41]
    end

    test "an explicit pattern is the independent wiring, pitched the same way" do
      assert {:ok, onsets} =
               Bass.compile(
                 spec(%{pattern: "x-x-x-x-", resolution: "1/8", bars: 2, roots: [36, 43]}),
                 []
               )

      assert beats(onsets) == [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]
      assert Enum.map(onsets, & &1.pitch) == [36, 36, 36, 36, 43, 43, 43, 43]
    end

    # A pattern ignores the drums outright — that is what keeps the
    # independent-versus-conditioned comparison one factor rather than two.
    test "an explicit pattern ignores the followed part entirely" do
      with_drums =
        Bass.compile(spec(%{pattern: "x-x-", resolution: "1/8"}), kick("x---x---x---x---"))

      without = Bass.compile(spec(%{pattern: "x-x-", resolution: "1/8"}), [])

      assert with_drums == without
    end
  end

  describe "validate_roots/3" do
    test "accepts one root per bar inside the register" do
      assert Bass.validate_roots([28, 43], 2, "Bass") == :ok
    end

    test "refuses the wrong number of roots, naming both counts" do
      assert {:error, message} = Bass.validate_roots([36], 4, "Bass")
      assert message =~ "1 root(s) for 4 bar(s)"
      assert message =~ "repeating it where the harmony does not move"
    end

    test "refuses a root outside the bass register, naming the range" do
      assert {:error, message} = Bass.validate_roots([36, 60], 2, "Bass")
      assert message =~ "60"
      assert message =~ "28–43"
      assert message =~ "E1–G2"
    end

    test "refuses missing roots outright" do
      assert {:error, message} = Bass.validate_roots(nil, 1, "Bass")
      assert message =~ "needs roots"

      assert {:error, empty} = Bass.validate_roots([], 1, "Bass")
      assert empty =~ "no roots"
    end
  end

  describe "refusals" do
    test "neither a pattern nor a relationship is refused by name" do
      assert {:error, message} = Bass.compile(spec(%{}), [])
      assert message =~ "\"Bass\""
      assert message =~ "lock, answer, sustain"
    end
  end
end
