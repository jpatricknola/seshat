defmodule Seshat.Generation.Midi.ProfilesTest do
  @moduledoc """
  The committed profiles, pinned inside the envelope they were measured in.

  This is the guard against a bad re-harvest shipping quietly. Nothing here
  asserts a *particular* number — that would make the JSON unrebuildable — but a
  profile whose timing, velocity spread or ghost dynamics fall outside what real
  drumming looks like is a harvest that went wrong, and it fails here rather
  than an hour into a listening session.
  """

  use ExUnit.Case, async: true

  alias Seshat.Generation.Midi.Profiles
  alias Seshat.Tools.Definitions

  @harvested ~w(rock funk jazz latin hiphop dance)
  @authored ~w(lofi boom_bap house techno trap)

  describe "the committed document" do
    test "carries the dataset's attribution, licence and citation" do
      attribution = Profiles.document()["attribution"]

      assert attribution["dataset"] =~ "Groove MIDI Dataset"
      assert attribution["licence"] =~ "CC-BY 4.0"
      assert attribution["citation"] =~ "Gillick"
      assert attribution["url"] =~ "groove-v1.0.0-midionly.zip"
      assert attribution["sha256"] =~ ~r/^[0-9a-f]{64}$/
    end

    test "names the script that produced it" do
      assert Profiles.document()["generated_by"] == "experiments/gmd_profiles/harvest.py"
    end
  end

  describe "coverage" do
    test "every published style has a profile, harvested or authored" do
      assert Enum.sort(Profiles.names()) == Enum.sort(@harvested ++ @authored)
    end

    # Parity by construction — the enum is *read* from the profiles — but pinned
    # anyway, because the first person to hardcode the enum will not notice
    # they have broken the link.
    test "the tool's style enum and the profiles are the same set" do
      %{parameters: schema} = Enum.find(Definitions.all(), &(&1.name == "generate_midi"))
      enum = schema.properties["style"].enum

      assert Enum.sort(enum) == Enum.sort(Profiles.names())
    end

    test "every profile carries every lane" do
      for style <- Profiles.names() do
        {:ok, profile} = Profiles.fetch(style)
        assert Enum.sort(Map.keys(profile["lanes"])) == Enum.sort(Profiles.lanes())
      end
    end

    test "an unknown style is an error, never another style's numbers" do
      assert Profiles.fetch("drum-and-bass") == :error
      assert Profiles.lane_for("drum-and-bass", 36) == :error
      assert Profiles.swing("drum-and-bass") == 0.0
    end
  end

  describe "provenance" do
    test "harvested profiles say so and name no donor" do
      for style <- @harvested do
        assert Profiles.harvested?(style), "#{style} lost its harvested flag"
        assert Profiles.authored_from(style) == nil
      end
    end

    # Nothing authored may be reported as measured: the reply tells the user
    # which it used, and that sentence has to stay true.
    test "authored profiles name their donor and are not claimed as harvested" do
      for style <- @authored do
        refute Profiles.harvested?(style), "#{style} is claiming to be harvested"
        assert Profiles.authored_from(style) in @harvested
        {:ok, profile} = Profiles.fetch(style)
        assert is_binary(profile["authored_note"])
      end
    end
  end

  describe "the measured envelope" do
    # Human microtiming against a 16th grid: GMD's per-lane means run to about a
    # tenth of a 16th, and the authored profiles shift them further. Anything
    # past a fifth is a harvest that mis-read the grid.
    test "mean timing offsets stay inside a fifth of a 16th" do
      for {style, lane, values} <- lanes() do
        assert abs(values["timing_mean"]) <= 0.2,
               "#{style}/#{lane} timing_mean #{values["timing_mean"]} is outside the envelope"

        assert values["timing_sd"] >= 0.0 and values["timing_sd"] <= 0.5,
               "#{style}/#{lane} timing_sd #{values["timing_sd"]} is outside the envelope"
      end
    end

    # Measured range across the committed profiles is roughly 20-51; the bound
    # is deliberately wider than the data and far narrower than "any number".
    # A lane with no spread at all would be a machine, which is the failure this
    # catches.
    test "velocity spread is a real spread, and not an absurd one" do
      for {style, lane, values} <- lanes() do
        assert values["velocity_sd"] >= 10.0 and values["velocity_sd"] <= 55.0,
               "#{style}/#{lane} velocity_sd #{values["velocity_sd"]} is outside the envelope"
      end
    end

    test "the accent classes stay ordered and inside Live's range" do
      for {style, lane, values} <- lanes() do
        %{"accent" => accent, "hit" => hit, "ghost" => ghost} = values["velocity"]

        assert ghost["mean"] >= 1.0, "#{style}/#{lane} ghosts are silent"
        assert accent["mean"] <= 127.0, "#{style}/#{lane} accents are past Live's ceiling"

        assert accent["mean"] > hit["mean"],
               "#{style}/#{lane} accents are not louder than ordinary hits"

        assert hit["mean"] > ghost["mean"],
               "#{style}/#{lane} ghosts are not quieter than ordinary hits"
      end
    end

    test "ghost probability is a probability, and worth having" do
      for {style, lane, values} <- lanes() do
        probability = values["ghost_probability"]

        assert probability > 0.0 and probability <= 1.0,
               "#{style}/#{lane} ghost_probability #{probability} is not a probability"
      end
    end

    test "swing is small at this resolution and never absurd" do
      for style <- Profiles.names() do
        assert abs(Profiles.swing(style)) <= 0.5,
               "#{style} swing #{Profiles.swing(style)} is outside the envelope"
      end
    end

    # A lane with too few source files borrows the pooled statistic, and says so
    # rather than publishing noise. `dance` is the thin one: 7 files.
    test "a small-sample lane records that it fell back" do
      {:ok, dance} = Profiles.fetch("dance")
      assert dance["fallback_lanes"] != []

      {:ok, rock} = Profiles.fetch("rock")
      assert rock["fallback_lanes"] == []
    end
  end

  describe "lane_for/2" do
    test "maps the General MIDI drum pitches onto their lanes" do
      assert {:ok, "kick", _values} = Profiles.lane_for("rock", 36)
      assert {:ok, "snare", _values} = Profiles.lane_for("rock", 38)
      assert {:ok, "closed_hat", _values} = Profiles.lane_for("rock", 42)
      assert {:ok, "open_hat", _values} = Profiles.lane_for("rock", 46)
      assert {:ok, "ride", _values} = Profiles.lane_for("rock", 51)
      assert {:ok, "crash", _values} = Profiles.lane_for("rock", 49)
    end

    # A kit that maps its pads elsewhere is not something any address can read
    # back (FORK_GAPS.md), so an unknown pitch takes the middle-of-the-road lane
    # rather than refusing a legitimate request.
    test "an unmapped pitch falls back to the snare rather than failing" do
      assert Profiles.lane_for_pitch(3) == "snare"
      assert {:ok, "snare", _values} = Profiles.lane_for("rock", 3)
    end
  end

  describe "bass_lane/1" do
    # GMD is a drum dataset, so the bass profile is derived and says so in the
    # module doc — the test pins that it is derived *from the kick*, which is
    # what "a bass player locks to the kick" means numerically.
    test "borrows the kick's timing and tightens it" do
      {:ok, _lane, kick} = Profiles.lane_for("funk", 36)
      bass = Profiles.bass_lane("funk")

      assert bass["timing_mean"] == kick["timing_mean"]
      assert bass["timing_sd"] < kick["timing_sd"]
    end

    test "carries its own velocities, ordered, and no ghost chance" do
      bass = Profiles.bass_lane("rock")

      assert bass["velocity"]["accent"]["mean"] > bass["velocity"]["hit"]["mean"]
      assert bass["velocity"]["hit"]["mean"] > bass["velocity"]["ghost"]["mean"]
      assert bass["ghost_probability"] == 1.0
    end

    test "an unknown style yields a flat lane rather than raising" do
      bass = Profiles.bass_lane("drum-and-bass")
      assert bass["timing_mean"] == 0.0
    end
  end

  defp lanes do
    for style <- Profiles.names(),
        {:ok, profile} = Profiles.fetch(style),
        {lane, values} <- profile["lanes"] do
      {style, lane, values}
    end
  end
end
