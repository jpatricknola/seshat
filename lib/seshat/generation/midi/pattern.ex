defmodule Seshat.Generation.Midi.Pattern do
  @moduledoc """
  The step-pattern compiler: a string Claude writes, to onsets on an exact grid.

  Pure — no OSC, no randomness, no session. One character is one step:

      X  accent      x  hit      g  ghost      -  rest

  `|` and whitespace are ignored, so `"X-x-|X-x-"` and `"X-x- X-x-"` and
  `"X-x-X-x-"` compile identically and a model can lay a pattern out however it
  reads best.

  The grammar is deliberately this small. Every operator it does not have —
  Euclidean spread, every-other-bar variation, probability per step — is
  something the model can compute and write out, and each one added is a thing
  the model has to learn instead of a thing it already knows. Variation in v1 is
  written out bar by bar.

  A pattern shorter than the requested bars **repeats whole**, and only when it
  divides evenly: a 16-step pattern over 4 bars of 4/4 at 1/16 repeats four
  times, while a 12-step pattern over those same bars is a refusal naming both
  lengths rather than a truncation nobody asked for. A pattern longer than the
  clip is refused for the same reason.

  Compiled onsets carry `step_beats`, the grid step's length in beats, because
  the performance layer needs it for note durations and jitter bounds and
  deriving it a second time is how the two drift apart.
  """

  @steps_per_beat %{"1/8" => 2, "1/8T" => 3, "1/16" => 4, "1/16T" => 6, "1/32" => 8}

  @accents %{"X" => :accent, "x" => :hit, "g" => :ghost}

  @doc "The resolutions the grammar accepts, in the order the tool's enum lists them."
  @spec resolutions() :: [String.t()]
  def resolutions, do: ["1/8", "1/8T", "1/16", "1/16T", "1/32"]

  @doc """
  Compile one pattern string into onsets on the grid.

  `beats_per_bar` is Live's own arithmetic — `numerator * 4 / denominator`, so
  4/4 is 4.0 and 6/8 is 3.0 — passed in rather than recomputed here, since the
  caller already read it out of the session mirror.

  Returns `{:ok, [%{beat: float, accent: :accent | :hit | :ghost, step_beats: float}]}`
  in ascending `beat` order, or `{:error, message}` — a finished sentence naming
  the offending character and its position, or the two lengths that would not
  divide.
  """
  @spec compile(String.t(), String.t(), pos_integer(), number()) ::
          {:ok, [map()]} | {:error, String.t()}
  def compile(pattern, resolution, bars, beats_per_bar)
      when is_binary(pattern) and is_binary(resolution) and is_integer(bars) and bars > 0 do
    with {:ok, per_beat} <- steps_per_beat(resolution),
         {:ok, steps_per_bar} <- steps_per_bar(per_beat, beats_per_bar, resolution),
         {:ok, steps} <- parse(pattern),
         {:ok, filled} <- fill(steps, steps_per_bar * bars, steps_per_bar) do
      step_beats = beats_per_bar / steps_per_bar

      onsets =
        filled
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {nil, _index} ->
            []

          {accent, index} ->
            [%{beat: index * step_beats, accent: accent, step_beats: step_beats}]
        end)

      {:ok, onsets}
    end
  end

  @doc """
  How many steps one bar holds at this resolution, or why it cannot be gridded.

  Public because the refusal it produces is about the *session's* time
  signature rather than about the pattern, and the workflow reports the two
  differently.
  """
  @spec steps_per_bar(pos_integer(), number(), String.t()) ::
          {:ok, pos_integer()} | {:error, String.t()}
  def steps_per_bar(per_beat, beats_per_bar, resolution) do
    exact = beats_per_bar * per_beat
    rounded = round(exact)

    if abs(exact - rounded) < 1.0e-9 and rounded > 0 do
      {:ok, rounded}
    else
      {:error,
       "A bar of this session's time signature is #{trim(beats_per_bar)} beats, which does not " <>
         "divide into whole #{resolution} steps. Pick a resolution that fits the bar, or change " <>
         "the time signature with set_time_signature. Nothing was written."}
    end
  end

  defp steps_per_beat(resolution) do
    case Map.fetch(@steps_per_beat, resolution) do
      {:ok, per_beat} ->
        {:ok, per_beat}

      :error ->
        {:error,
         "resolution #{inspect(resolution)} is not one of " <>
           Enum.join(resolutions(), ", ") <> ". Nothing was written."}
    end
  end

  # Positions are counted over the *significant* characters, so the number in a
  # refusal is the step the model wrote rather than the byte offset in a string
  # it laid out with bars and spaces.
  defp parse(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.reject(&(&1 in ["|", " ", "\t", "\n", "\r"]))
    |> Enum.reduce_while({:ok, []}, fn character, {:ok, acc} ->
      cond do
        character == "-" -> {:cont, {:ok, [nil | acc]}}
        Map.has_key?(@accents, character) -> {:cont, {:ok, [@accents[character] | acc]}}
        true -> {:halt, {:error, bad_character(character, length(acc) + 1)}}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error,
         "The pattern has no steps in it. Write one character per step — X accent, x hit, " <>
           "g ghost, - rest. Nothing was written."}

      {:ok, steps} ->
        {:ok, Enum.reverse(steps)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp bad_character(character, position) do
    "The pattern's step #{position} is #{inspect(character)}, which is not a step character. " <>
      "Use X for an accent, x for a hit, g for a ghost and - for a rest; | and spaces are " <>
      "ignored. Nothing was written."
  end

  defp fill(steps, total, steps_per_bar) do
    written = length(steps)

    cond do
      written == total ->
        {:ok, steps}

      written > total ->
        {:error,
         "The pattern is #{written} steps long, but #{total} steps fit in the clip " <>
           "(#{steps_per_bar} per bar). Shorten it, or ask for more bars. Nothing was written."}

      rem(total, written) == 0 ->
        {:ok, steps |> List.duplicate(div(total, written)) |> List.flatten()}

      true ->
        {:error,
         "The pattern is #{written} steps long and the clip holds #{total} " <>
           "(#{steps_per_bar} per bar), which #{written} does not divide into evenly — a short " <>
           "pattern is repeated whole, never cut. Write #{total} steps, or a length that " <>
           "divides #{total}. Nothing was written."}
    end
  end

  defp trim(value) do
    float = value * 1.0
    if float == Float.round(float), do: Integer.to_string(trunc(float)), else: to_string(float)
  end
end
