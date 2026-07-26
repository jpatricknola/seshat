defmodule Seshat.Music.Pitch do
  @moduledoc """
  MIDI pitch → note name.

  Shared by `Seshat.Tools.Handlers` (naming the notes in a clip) and
  `Seshat.Session.State` (naming the song's root note). The model does the
  theory; these names exist so it never has to infer an octave from a raw
  number and get it off by twelve.

  Sharps only — Ableton has no key-aware spelling to read here, so guessing
  flats would be inventing information.
  """

  @names {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

  @doc """
  Name of a MIDI note number, with its octave: `60` → `"C4"`, `36` → `"C2"`.

  Middle C (MIDI 60) is C4, matching Ableton's own display.
  """
  @spec note_name(integer()) :: String.t()
  def note_name(pitch) when is_integer(pitch) do
    "#{pitch_class_name(pitch)}#{Integer.floor_div(pitch, 12) - 1}"
  end

  @doc """
  Name of a pitch class, ignoring octave: `0` → `"C"`, `1` → `"C#"`.

  Accepts any integer (a full MIDI note number works too) and falls back to
  the value itself if Live ever reports something that isn't one.
  """
  @spec pitch_class_name(term()) :: String.t()
  def pitch_class_name(pitch) when is_integer(pitch) do
    elem(@names, Integer.mod(pitch, 12))
  end

  def pitch_class_name(other), do: to_string(other)
end
