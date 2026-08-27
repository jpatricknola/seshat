defmodule Seshat.Tools.NoteEdit do
  @moduledoc """
  The pure arithmetic behind `edit_notes`: given the notes a window matched and
  the changes asked for, produce the notes to write back — or a refusal.

  It exists so the interesting half of `edit_notes` can be unit-tested without a
  transport. `Seshat.Tools.Handlers` owns the OSC: the guards, the read, the
  remove/add pair, the read-back. Everything between those — what each matched
  note becomes, and whether the request is coherent at all — is here.

  Two rules every refusal's wording depends on:

    * **A result outside Live's range refuses the whole call**, it does not
      clamp. Clamping pitch would silently pile a transposed chord onto G9 or
      C-2, and a refusal costs the model one retry with a smaller interval.
      Same for a start dragged before beat 0 by `shift`.
    * **`velocity_delta` is the exception**: clamping to 1–127 *is* the musical
      intent of "make everything a bit louder", so it clamps, and the caller
      reports how many notes hit a bound.
  """

  alias Seshat.Music.Pitch

  @change_keys ~w(transpose velocity velocity_delta duration shift delete)

  @min_pitch 0
  @max_pitch 127
  @min_velocity 1
  @max_velocity 127

  @doc """
  The change keys `edit_notes` understands.
  """
  @spec change_keys() :: [String.t()]
  def change_keys, do: @change_keys

  @doc """
  Picks the changes out of a params map, discarding the window and indices.
  """
  @spec changes(map()) :: map()
  def changes(params), do: Map.take(params, @change_keys)

  @doc """
  Rejects an incoherent set of changes before anything is read or sent.

  Returns `:ok`, or `{:error, message}` addressed to the model.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(changes) when map_size(changes) == 0 do
    {:error,
     "Nothing to change — pass at least one of transpose, velocity, velocity_delta, " <>
       "duration, shift, or delete: true. To only look at the notes, use get_clip_notes. " <>
       "Nothing was changed."}
  end

  def validate(changes) do
    cond do
      Map.has_key?(changes, "velocity") and Map.has_key?(changes, "velocity_delta") ->
        {:error,
         "velocity and velocity_delta set the same field two different ways — pass velocity " <>
           "for an absolute value or velocity_delta for a relative one, not both. Nothing " <>
           "was changed."}

      truthy?(Map.get(changes, "delete")) and map_size(changes) > 1 ->
        other = changes |> Map.delete("delete") |> Map.keys() |> Enum.sort() |> Enum.join(", ")

        {:error,
         "delete: true removes the matched notes, so it cannot be combined with #{other} — " <>
           "delete them or edit them, in separate calls. Nothing was changed."}

      map_size(changes) == 1 and Map.has_key?(changes, "delete") and
          not truthy?(Map.get(changes, "delete")) ->
        {:error,
         "delete: false asks for nothing — pass delete: true to remove the matched notes, " <>
           "or one of transpose, velocity, velocity_delta, duration or shift to edit them. " <>
           "Nothing was changed."}

      true ->
        :ok
    end
  end

  @doc """
  True when these changes mean "remove the matched notes".
  """
  @spec delete?(map()) :: boolean()
  def delete?(changes), do: truthy?(Map.get(changes, "delete"))

  @doc """
  Applies the changes to every matched note.

  `notes` are `Seshat.Tools.Handlers.parse_clip_notes/1` maps (`:pitch`,
  `:start_time`, `:duration`, `:velocity`, `:mute`). Returns `{:ok, edited,
  clamped}` — `edited` in the input order, `clamped` the number of notes whose
  velocity hit 1 or 127 — or `{:error, message}` when a result would leave
  Live's range.

  Never called for `delete: true`: there is nothing to write back.
  """
  @spec apply([map()], map()) :: {:ok, [map()], non_neg_integer()} | {:error, String.t()}
  def apply(notes, changes) do
    with :ok <- check_pitches(notes, changes),
         :ok <- check_starts(notes, changes) do
      {edited, clamped} =
        Enum.map_reduce(notes, 0, fn note, clamped ->
          {velocity, hit?} = new_velocity(note, changes)

          edited = %{
            pitch: new_pitch(note, changes),
            start_time: new_start(note, changes),
            duration: new_duration(note, changes),
            velocity: velocity,
            mute: note.mute
          }

          {edited, clamped + if(hit?, do: 1, else: 0)}
        end)

      {:ok, edited, clamped}
    end
  end

  # Refusals name the direction and the count, because that is what tells the
  # model which smaller interval to retry with.
  defp check_pitches(notes, %{"transpose" => transpose}) when is_number(transpose) do
    pitches = Enum.map(notes, &(trunc(&1.pitch) + trunc(transpose)))
    above = Enum.count(pitches, &(&1 > @max_pitch))
    below = Enum.count(pitches, &(&1 < @min_pitch))

    cond do
      above > 0 ->
        {:error,
         "Transposing #{signed(transpose)} would push #{count(above)} above " <>
           "#{Pitch.note_name(@max_pitch)} (MIDI #{@max_pitch}), which Live cannot hold — " <>
           "nothing was changed. Try a smaller interval, or narrow the pitch window."}

      below > 0 ->
        {:error,
         "Transposing #{signed(transpose)} would push #{count(below)} below " <>
           "#{Pitch.note_name(@min_pitch)} (MIDI #{@min_pitch}), which Live cannot hold — " <>
           "nothing was changed. Try a smaller interval, or narrow the pitch window."}

      true ->
        :ok
    end
  end

  defp check_pitches(_notes, _changes), do: :ok

  defp check_starts(notes, %{"shift" => shift}) when is_number(shift) do
    early = Enum.count(notes, &(&1.start_time / 1.0 + shift / 1.0 < 0.0))

    if early > 0 do
      {:error,
       "Shifting by #{signed(shift)} beats would start #{count(early)} before the clip's " <>
         "beat 0, which Live cannot hold — nothing was changed. Try a smaller shift, or " <>
         "narrow the time window."}
    else
      :ok
    end
  end

  defp check_starts(_notes, _changes), do: :ok

  defp new_pitch(note, %{"transpose" => transpose}) when is_number(transpose),
    do: trunc(note.pitch) + trunc(transpose)

  defp new_pitch(note, _changes), do: trunc(note.pitch)

  defp new_start(note, %{"shift" => shift}) when is_number(shift),
    do: note.start_time / 1.0 + shift / 1.0

  defp new_start(note, _changes), do: note.start_time / 1.0

  defp new_duration(_note, %{"duration" => duration}) when is_number(duration),
    do: duration / 1.0

  defp new_duration(note, _changes), do: note.duration / 1.0

  # Rounded here rather than at the wire: `/live/clip/get/notes` answers with
  # velocity as a float (`100.0`) and `/live/clip/add/notes` wants an integer,
  # so the conversion belongs wherever the value is decided.
  defp new_velocity(_note, %{"velocity" => velocity}) when is_number(velocity),
    do: {round(velocity), false}

  defp new_velocity(note, %{"velocity_delta" => delta}) when is_number(delta) do
    raw = round(note.velocity) + round(delta)
    clamped = raw |> max(@min_velocity) |> min(@max_velocity)
    {clamped, clamped != raw}
  end

  defp new_velocity(note, _changes), do: {round(note.velocity), false}

  defp count(1), do: "1 note"
  defp count(n), do: "#{n} notes"

  defp signed(value) when is_integer(value) and value >= 0, do: "+#{value}"
  defp signed(value) when is_integer(value), do: "#{value}"
  defp signed(value) when value >= 0, do: "+#{Float.round(value / 1.0, 4)}"
  defp signed(value), do: "#{Float.round(value / 1.0, 4)}"

  defp truthy?(true), do: true
  defp truthy?(value) when is_number(value), do: value != 0
  defp truthy?(_value), do: false
end
