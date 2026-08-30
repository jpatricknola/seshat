defmodule Seshat.Generation.Midi.Bass do
  @moduledoc """
  The bass rules: one root per bar, plus a relationship to what the drums do.

  Pure. Two ways a bass part can be written, kept separate on purpose so the
  question "does conditioning the bass on the actual kick sound better than
  writing it independently?" stays one factor rather than two:

    * an explicit `pattern`, compiled by `Seshat.Generation.Midi.Pattern` and
      pitched by `roots` per bar — the *independent* wiring;
    * a `relationship` derived from the compiled onsets of a drum part in the
      same request — the *conditioned* wiring. Not a mode: it reads the real
      onsets the drum part is about to play, after that part's own pattern was
      compiled, so there is nothing to keep in sync.

  Three relationships:

    * `lock` — a note on every followed onset, rests elsewhere. The default
      reading of "play with the kick". The onsets are shared, but each part is
      then humanized independently on its own RNG stream
      (`Seshat.Generation.Midi.Performance`), so a `lock` bass and its kick
      can land a beat fraction apart after humanization rather than sample-
      exact — measured up to ~0.065 beats (~32ms at 120 BPM) on a real
      request. Whether that still reads as "locked" by ear is for the
      by-ear slate, not this module.
    * `answer` — a note on the 8th *after* each followed onset that is not
      itself answered by another within a beat, so the bass fills the gaps
      rather than doubling a busy kick.
    * `sustain` — one note per bar, held from the bar's first followed onset to
      its last.

  **Drum velocities are never read.** This module consumes onset *positions*
  only; the phrase shape below is its own. Copying a kick's velocity contour on
  to a bass is the shortcut that makes a "conditioned" bass sound like a kick
  with pitch, and the test suite pins the independence by feeding onsets whose
  accents differ and asserting the bass is identical.

  Register is validated (28–43, E1–G2) and nothing else about pitch is: which
  root belongs over which bar is the model's musical decision, made with the
  session's key in hand from `get_session_state`.
  """

  alias Seshat.Generation.Midi.Pattern

  @lowest_root 28
  @highest_root 43

  @relationships ["lock", "answer", "sustain"]

  @doc "The relationships the schema's enum offers."
  @spec relationships() :: [String.t()]
  def relationships, do: @relationships

  @doc "The lowest and highest root the register guard accepts."
  @spec register() :: {integer(), integer()}
  def register, do: {@lowest_root, @highest_root}

  @doc """
  Validate one bass part's roots against the bar count and the register.

  Runs before anything is compiled, so a refusal here costs nothing and touches
  nothing.
  """
  @spec validate_roots(term(), pos_integer(), String.t()) :: :ok | {:error, String.t()}
  def validate_roots(roots, bars, role) when is_list(roots) do
    cond do
      roots == [] ->
        {:error,
         "Bass part \"#{role}\" has no roots. Give one root per bar — MIDI " <>
           "#{@lowest_root}–#{@highest_root} (E1–G2). Nothing was written."}

      length(roots) != bars ->
        {:error,
         "Bass part \"#{role}\" has #{length(roots)} root(s) for #{bars} bar(s) — give exactly " <>
           "one root per bar, repeating it where the harmony does not move. Nothing was written."}

      out = Enum.find(roots, &(not in_register?(&1))) ->
        {:error,
         "Bass part \"#{role}\" has a root of #{inspect(out)}, outside the bass register " <>
           "(MIDI #{@lowest_root}–#{@highest_root}, E1–G2). Transpose it into that range — the " <>
           "octave is yours to choose. Nothing was written."}

      true ->
        :ok
    end
  end

  def validate_roots(_roots, _bars, role) do
    {:error,
     "Bass part \"#{role}\" needs roots: one MIDI pitch per bar, " <>
       "#{@lowest_root}–#{@highest_root}. Nothing was written."}
  end

  defp in_register?(pitch) when is_integer(pitch),
    do: pitch >= @lowest_root and pitch <= @highest_root

  defp in_register?(_pitch), do: false

  @doc """
  Compile a bass part into onsets carrying pitch, duration and accent class.

  `spec` carries `:relationship` (a string) or `:pattern` plus `:resolution`,
  and always `:roots`, `:bars`, `:beats_per_bar`. `followed` is the compiled
  onset list of the drum part this one derives from — ignored entirely when a
  pattern was given.

  Returns onsets in the shape `Seshat.Generation.Midi.Performance.perform/2`
  takes, with `:pitch` and `:duration` already set.
  """
  @spec compile(map(), [map()]) :: {:ok, [map()]} | {:error, String.t()}
  def compile(%{pattern: pattern} = spec, _followed) when is_binary(pattern) do
    with {:ok, onsets} <-
           Pattern.compile(pattern, spec.resolution, spec.bars, spec.beats_per_bar) do
      {:ok, Enum.map(onsets, &pitched(&1, spec))}
    end
  end

  def compile(%{relationship: relationship} = spec, followed)
      when relationship in @relationships do
    beats = spec.beats_per_bar * 1.0
    clip_beats = beats * spec.bars

    onsets =
      case relationship do
        "lock" -> lock(followed)
        "answer" -> answer(followed)
        "sustain" -> sustain(followed, beats, spec.bars)
      end

    {:ok, onsets |> Enum.filter(&(&1.beat < clip_beats)) |> shape(spec, clip_beats)}
  end

  def compile(spec, _followed) do
    {:error,
     "Bass part \"#{spec.role}\" needs either a pattern or a relationship " <>
       "(#{Enum.join(@relationships, ", ")}). Nothing was written."}
  end

  # --- The three relationships ---

  defp lock(followed) do
    followed
    |> Enum.map(& &1.beat)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{beat: &1})
  end

  # One 8th after each onset that has nothing else within a beat of it: the
  # bass answers the isolated hits and stays out of the way of the busy ones.
  defp answer(followed) do
    beats = followed |> Enum.map(& &1.beat) |> Enum.uniq() |> Enum.sort()

    beats
    |> Enum.filter(fn beat ->
      not Enum.any?(beats, fn other -> other > beat and other - beat <= 1.0 end)
    end)
    |> Enum.map(&%{beat: &1 + 0.5})
  end

  # One note per bar, spanning the bar's first followed onset to its last. A bar
  # the drums leave empty gets no bass note: inventing one would be this
  # module's own idea rather than the drummer's.
  defp sustain(followed, beats_per_bar, bars) do
    grouped =
      Enum.group_by(followed, fn onset -> min(trunc(onset.beat / beats_per_bar), bars - 1) end)

    for bar <- 0..(bars - 1)//1,
        onsets = Map.get(grouped, bar, []),
        onsets != [] do
      starts = Enum.map(onsets, & &1.beat)
      first = Enum.min(starts)
      last = Enum.max(starts)
      span = if last > first, do: last - first, else: (bar + 1) * beats_per_bar - first

      %{beat: first, span: span}
    end
  end

  # --- The phrase rule ---

  # Durations run to the next bass note (never past it), and the accent class is
  # positional: the first note of a bar leans in, a note sitting a 16th before
  # the next one is a pickup and is ghosted, everything else is an ordinary hit.
  # Nothing here reads a drum velocity.
  defp shape(onsets, spec, clip_beats) do
    beats = spec.beats_per_bar * 1.0
    sorted = Enum.sort_by(onsets, & &1.beat)
    starts = Enum.map(sorted, & &1.beat)

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {onset, index} ->
      next = Enum.at(starts, index + 1, clip_beats)
      gap = next - onset.beat
      span = Map.get(onset, :span, min(gap, beats))

      accent =
        cond do
          first_in_bar?(onset.beat, starts, beats) -> :accent
          gap <= 0.25 + 1.0e-9 -> :ghost
          true -> :hit
        end

      %{
        beat: onset.beat,
        accent: accent,
        step_beats: min(gap, beats),
        duration: max(min(span, gap) * 0.95, 0.05),
        pitch: root_for(onset.beat, spec)
      }
    end)
  end

  defp first_in_bar?(beat, starts, beats_per_bar) do
    bar = trunc(beat / beats_per_bar)

    starts
    |> Enum.filter(&(trunc(&1 / beats_per_bar) == bar))
    |> Enum.min(fn -> beat end)
    |> Kernel.==(beat)
  end

  defp pitched(onset, spec) do
    Map.merge(onset, %{
      pitch: root_for(onset.beat, spec),
      duration: onset.step_beats * 0.9
    })
  end

  defp root_for(beat, spec) do
    bar = min(trunc(beat / (spec.beats_per_bar * 1.0)), spec.bars - 1)
    Enum.at(spec.roots, bar, List.last(spec.roots))
  end
end
