defmodule Seshat.Generation.Midi.Profiles do
  @moduledoc """
  The committed style profiles: how each style's drummer sits against the grid.

  `priv/midi_generation/style_profiles.json` is *data*, harvested offline by
  `experiments/gmd_profiles/harvest.py` from the Groove MIDI Dataset (CC-BY 4.0,
  attributed in `priv/midi_generation/ATTRIBUTION.md`) and committed. Nothing
  here downloads, reads or ships a dataset file at run time, and there is no
  model: a profile is a few dozen numbers per style.

  It is read **at compile time** rather than on each request. That makes
  `Seshat.Generation.Midi.Performance` a pure function of its arguments — no
  file IO on a hot path, no "the profiles were missing" failure mode reachable
  from a tool call — and `@external_resource` means a re-harvest recompiles the
  module rather than being silently ignored.

  Six profiles are harvested (`rock`, `funk`, `jazz`, `latin`, `hiphop`,
  `dance`); five are **authored** from those, since GMD carries no label for
  them at all (`lofi`, `boom_bap`, `house`, `techno`, `trap`). Each authored
  profile names its donor in `authored_from`, and `harvested?/1` is the honest
  discriminator — the reply says which kind it used rather than implying every
  number was measured.

  Lanes are classes, not pitches: the model sends a MIDI `pitch` for a drum
  part, and `lane_for_pitch/1` maps it onto the class whose statistics apply.
  General MIDI is the assumption there, as it is in the tool's description; a
  kit that maps its pads elsewhere is the model's problem to solve by choosing
  a different `pitch`, and no address exists to read a kit's pad map back
  (`FORK_GAPS.md`).
  """

  @profiles_path Path.join(:code.priv_dir(:seshat), "midi_generation/style_profiles.json")
  @external_resource @profiles_path

  @document @profiles_path |> File.read!() |> Jason.decode!()
  @styles Map.fetch!(@document, "styles")
  @names @styles |> Map.keys() |> Enum.sort()

  @lanes ["kick", "snare", "closed_hat", "open_hat", "tom", "ride", "crash"]

  # General MIDI percussion, which is what Live's own Drum Racks follow. Only
  # the pitches a producer actually reaches for are listed; anything else falls
  # back to the snare's statistics, the middle-of-the-road lane — a wrong lane
  # changes the feel slightly, where refusing would stop a legitimate request
  # over a pad number nothing can verify anyway.
  @lane_by_pitch %{
    35 => "kick",
    36 => "kick",
    37 => "snare",
    38 => "snare",
    39 => "snare",
    40 => "snare",
    41 => "tom",
    42 => "closed_hat",
    43 => "tom",
    44 => "closed_hat",
    45 => "tom",
    46 => "open_hat",
    47 => "tom",
    48 => "tom",
    49 => "crash",
    50 => "tom",
    51 => "ride",
    52 => "crash",
    53 => "ride",
    54 => "closed_hat",
    55 => "crash",
    56 => "closed_hat",
    57 => "crash",
    58 => "crash",
    59 => "ride",
    69 => "closed_hat",
    70 => "closed_hat"
  }

  @doc "Every style name the profiles carry, sorted — the `style` enum's source of truth."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Every lane class a profile carries."
  @spec lanes() :: [String.t()]
  def lanes, do: @lanes

  @doc "The whole decoded document, attribution header included. For tests and diagnostics."
  @spec document() :: map()
  def document, do: @document

  @doc """
  One style's profile, or `:error` for a name that has none.

  Never falls back to another style: a missing profile means the `style` enum
  and the committed JSON have drifted apart, which the profiles test catches at
  build time rather than a request papering over.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(style) when is_binary(style), do: Map.fetch(@styles, style)

  @doc "Whether this style's numbers were harvested (`true`) or authored from a donor."
  @spec harvested?(String.t()) :: boolean()
  def harvested?(style) do
    case fetch(style) do
      {:ok, profile} -> Map.get(profile, "harvested", false)
      :error -> false
    end
  end

  @doc "The donor an authored profile was derived from, or `nil` for a harvested one."
  @spec authored_from(String.t()) :: String.t() | nil
  def authored_from(style) do
    case fetch(style) do
      {:ok, profile} -> Map.get(profile, "authored_from")
      :error -> nil
    end
  end

  @doc """
  The lane statistics one drum pitch should be performed with.

  `{:ok, lane_name, lane_profile}`, or `:error` when the style itself is
  unknown. An unrecognised pitch resolves to `"snare"` rather than failing.
  """
  @spec lane_for(String.t(), integer()) :: {:ok, String.t(), map()} | :error
  def lane_for(style, pitch) when is_integer(pitch) do
    with {:ok, profile} <- fetch(style) do
      lane = lane_for_pitch(pitch)
      {:ok, lane, Map.fetch!(profile["lanes"], lane)}
    end
  end

  @doc "The lane class a General MIDI drum pitch belongs to."
  @spec lane_for_pitch(integer()) :: String.t()
  def lane_for_pitch(pitch) when is_integer(pitch), do: Map.get(@lane_by_pitch, pitch, "snare")

  @doc """
  The swing a style carries, as a signed fraction of a 16th applied to off-8ths.

  `0.0` for an unknown style — the caller has already validated the enum, and a
  missing profile must not become an invented feel.
  """
  @spec swing(String.t()) :: float()
  def swing(style) do
    case fetch(style) do
      {:ok, profile} -> profile["swing"] * 1.0
      :error -> 0.0
    end
  end

  @doc """
  The bass lane's statistics: how a bass player sits against the grid.

  Bass is not a drum lane and GMD is a drum dataset, so this is deliberately
  *derived* rather than harvested — the kick's timing (a bass player locks to
  the kick) with a tighter spread, and velocities of its own. Stated here rather
  than buried in `Bass` so the one place feel numbers live is this module.
  """
  @spec bass_lane(String.t()) :: map()
  def bass_lane(style) do
    kick =
      case fetch(style) do
        {:ok, profile} -> Map.fetch!(profile["lanes"], "kick")
        :error -> %{"timing_mean" => 0.0, "timing_sd" => 0.0}
      end

    %{
      "timing_mean" => kick["timing_mean"],
      "timing_sd" => kick["timing_sd"] * 0.6,
      "velocity_sd" => 8.0,
      "ghost_probability" => 1.0,
      "velocity" => %{
        "accent" => %{"mean" => 108.0, "sd" => 6.0},
        "hit" => %{"mean" => 92.0, "sd" => 6.0},
        "ghost" => %{"mean" => 45.0, "sd" => 5.0}
      }
    }
  end
end
