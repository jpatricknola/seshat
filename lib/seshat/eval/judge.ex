defmodule Seshat.Eval.Judge do
  @moduledoc """
  Scores one trial's recorded calls against a case's expectation — without
  anybody reading a transcript.

  That is the whole bet of this slice: if the interesting properties of a
  routing trace can be stated as predicates, routing becomes a thing that can be
  regression-tested; if they can't, the approach dies here. So the matcher
  vocabulary is **closed** and small, and an unrecognised key in a case file
  raises rather than quietly passing — a case that scores everything is worse
  than no case.

  ## The vocabulary

  A `where` key is either an argument name or one of three named predicates.

  Argument matchers:

    * a literal (`"target": "master"`, `"track": 1`, `"mute": true`)
    * `{"lt": v}`, `{"gt": v}`, `{"between": [low, high]}` — inclusive bounds
    * `{"absent_or": v}` — the argument is missing, or equals `v`
    * `{"fixture": path}` — anywhere a value is expected, dereferenced against
      the fixture (`"master.volume"`, `"clips.1:0.notes[2]"`)

  Named predicates:

    * `window_selects_exactly` — the pitch/time window of the call, with the
      schema's defaults applied, selects exactly the given fixture notes out of
      the clip the call names. This is what distinguishes "edited the third
      note" from "edited the whole clip and got lucky".
    * `velocity_down_from` — `velocity` below the given value, or a negative
      `velocity_delta`.
    * `notes_replace_quieter` — the written notes are the given fixture notes at
      a lower velocity, same pitch, same start.

  A `calls` entry may also carry `"after": "<tool name>"`, naming an earlier
  entry in the same `calls` list. The matched call(s) for this entry must all
  have a `seq` greater than the last matching call's `seq` for the named
  entry. This exists because entry matching is otherwise order-blind: a case
  that expects "read, delete, rewrite" is satisfied just as well by "read,
  rewrite, delete" without it — the latter is destructive (the rewrite is
  clobbered by the delete) but scores identically absent an ordering
  constraint. `"after"` is the only ordering primitive; there is no
  list-level `"ordered": true` shortcut, so a case that cares about order
  says so on every entry after the first.

  ## Why `first_mutation_valid` exists beside `first_call_valid`

  The roadmap's literal metric is first-call validity, and both seed cases
  deliberately open with an easy read. Without the mutation-specific twin, a
  malformed first *write* would hide behind a perfectly valid
  `get_session_state`.
  """

  alias Seshat.Eval.Case, as: EvalCase
  alias Seshat.Eval.Fixture
  alias Seshat.Eval.Surface

  @operators ~w(lt gt between absent_or fixture)
  @predicates ~w(window_selects_exactly velocity_down_from notes_replace_quieter)

  @inability_phrases ["can't", "cannot", "not able", "no tool", "unable to", "don't have a tool"]

  @type verdict :: map()

  @doc """
  Judges one trial.

  `context` carries what the trial produced and what it ran against:

      %{trace: [call maps from the recorder],
        final_text: String.t() | nil,
        void_reason: String.t() | nil,
        fixture: %Fixture{},
        surface: %Surface{}}

  A void trial is still returned as a verdict — with `void_reason` set and every
  rate excluded downstream — rather than dropped, because "how many trials were
  thrown away" is itself a result.
  """
  @spec judge(EvalCase.t(), map(), map()) :: verdict()
  def judge(%EvalCase{} = eval_case, expectation, context) do
    trace = Map.fetch!(context, :trace)
    fixture = Map.fetch!(context, :fixture)
    surface = Map.fetch!(context, :surface)

    kinds = Enum.map(trace, &kind(surface, &1))
    mutations = for {call, :mutation} <- Enum.zip(trace, kinds), do: call

    entries = Map.get(expectation, "calls", [])

    matches =
      Enum.map(entries, fn entry ->
        {entry, Enum.filter(trace, &matches_entry?(&1, entry, fixture))}
      end)

    entries_ok? =
      matches
      |> Enum.with_index()
      |> Enum.all?(fn {{entry, found}, index} ->
        count_ok?(entry, length(found)) and ordering_ok?(entry, found, index, matches)
      end)

    max_mutations = Map.get(expectation, "max_mutations")
    must_not_call = Map.get(expectation, "must_not_call", [])
    no_tool_errors? = Map.get(expectation, "no_tool_errors", true)

    tool_errors = Enum.count(trace, & &1["is_error"])
    forbidden = Enum.filter(trace, &(&1["name"] in must_not_call))

    within_budget? = is_nil(max_mutations) or length(mutations) <= max_mutations
    errors_ok? = not no_tool_errors? or tool_errors == 0

    first_mutation = List.first(mutations)

    %{
      "case" => eval_case.id,
      "semantic_success" => entries_ok? and within_budget? and errors_ok? and forbidden == [],
      "first_call_valid" => valid?(List.first(trace)),
      "first_mutation_valid" => valid?(first_mutation),
      "all_calls_valid" => trace != [] and Enum.all?(trace, &valid?/1),
      "correct_target_first_mutation" =>
        correct_first_mutation?(first_mutation, entries, fixture, surface),
      "read_count" => Enum.count(kinds, &(&1 == :read)),
      "view_count" => Enum.count(kinds, &(&1 == :view)),
      "mutation_count" => length(mutations),
      "tool_errors" => tool_errors,
      "extra_mutations" => extra_mutations(max_mutations, length(mutations)),
      "forbidden_calls" => Enum.map(forbidden, & &1["name"]),
      "claimed_inability" => claimed_inability?(context[:final_text]),
      "void_reason" => context[:void_reason],
      "calls" => Enum.map(trace, &summarize/1)
    }
  end

  defp summarize(call) do
    Map.take(call, ["seq", "name", "arguments", "is_error", "schema_valid", "kind"])
  end

  # The recorder already wrote the kind down; the surface is the fallback for a
  # hand-built trace in a test.
  defp kind(surface, call) do
    case call["kind"] do
      nil -> Surface.kind(surface, call["name"])
      other -> String.to_existing_atom(other)
    end
  end

  defp extra_mutations(nil, _count), do: 0
  defp extra_mutations(max, count), do: max(count - max, 0)

  defp valid?(nil), do: false
  defp valid?(call), do: call["schema_valid"] != false and call["is_error"] != true

  defp count_ok?(%{"count" => count}, found), do: found == count
  defp count_ok?(%{"min_count" => min}, found), do: found >= min
  defp count_ok?(_entry, found), do: found >= 1

  # `"after"` names an earlier `calls` entry by tool; the current entry's
  # matched calls must all sort strictly after that entry's last match. With
  # no `"after"` key, ordering is unconstrained (the pre-existing behaviour).
  defp ordering_ok?(%{"after" => nil}, _found, _index, _matches), do: true

  defp ordering_ok?(%{"after" => after_tool}, found, index, matches) do
    matches
    |> Enum.take(index)
    |> Enum.find(fn {earlier_entry, _found} -> earlier_entry["tool"] == after_tool end)
    |> case do
      nil ->
        raise ArgumentError,
              "case file's \"after\": #{inspect(after_tool)} does not name an earlier calls entry"

      {_earlier_entry, earlier_found} ->
        seq_after?(found, earlier_found)
    end
  end

  defp ordering_ok?(_entry, _found, _index, _matches), do: true

  defp seq_after?(found, earlier_found) do
    with earlier_seqs when earlier_seqs != [] <- Enum.map(earlier_found, & &1["seq"]),
         later_seqs when later_seqs != [] <- Enum.map(found, & &1["seq"]) do
      Enum.min(later_seqs) > Enum.max(earlier_seqs)
    else
      _ -> false
    end
  end

  # "Correct target" means the model's first write was one the case expected at
  # all — not merely well-formed. A trial that mutes the wrong return fails here
  # while still reporting `first_mutation_valid: true`, which is the distinction
  # the gate table is for.
  defp correct_first_mutation?(nil, _entries, _fixture, _surface), do: false

  defp correct_first_mutation?(call, entries, fixture, surface) do
    entries
    |> Enum.filter(&(Surface.kind(surface, &1["tool"]) == :mutation))
    |> Enum.any?(&matches_entry?(call, &1, fixture))
  end

  defp claimed_inability?(nil), do: false

  defp claimed_inability?(text) do
    downcased = String.downcase(text)
    Enum.any?(@inability_phrases, &String.contains?(downcased, &1))
  end

  @doc """
  Whether one recorded call satisfies one `calls` entry (tool name plus `where`).
  """
  @spec matches_entry?(map(), map(), Fixture.t()) :: boolean()
  def matches_entry?(call, entry, fixture) do
    call["name"] == entry["tool"] and
      Enum.all?(Map.get(entry, "where", %{}), fn {key, expected} ->
        matches_key?(key, expected, call["arguments"] || %{}, fixture)
      end)
  end

  defp matches_key?("window_selects_exactly", expected, arguments, fixture) do
    notes = deref!(expected, fixture) |> List.wrap()

    case clip_notes(arguments, fixture) do
      nil -> false
      all -> same_notes?(select(all, arguments), notes)
    end
  end

  defp matches_key?("velocity_down_from", expected, arguments, _fixture) do
    velocity = arguments["velocity"]
    delta = arguments["velocity_delta"]

    (is_number(velocity) and velocity < expected) or (is_number(delta) and delta < 0)
  end

  defp matches_key?("notes_replace_quieter", expected, arguments, fixture) do
    wanted = expected |> deref!(fixture) |> List.wrap()
    written = arguments["notes"] || []

    length(written) == length(wanted) and
      Enum.all?(Enum.zip(written, wanted), fn {note, target} ->
        note["pitch"] == target["pitch"] and
          equal_number?(note["start_beat"], target["start_time"]) and
          is_number(note["velocity"]) and note["velocity"] < target["velocity"]
      end)
  end

  defp matches_key?(key, expected, arguments, fixture) when key in @predicates do
    raise ArgumentError, "unhandled predicate #{key} (#{inspect({expected, arguments, fixture})})"
  end

  defp matches_key?(key, expected, arguments, fixture) do
    matches_value?(Map.fetch(arguments, key), expected, fixture)
  end

  defp matches_value?(:error, %{"absent_or" => _}, _fixture), do: true

  defp matches_value?({:ok, value}, %{"absent_or" => expected} = spec, fixture) do
    matches_value?({:ok, value}, Map.delete(spec, "absent_or"), fixture) or
      equal?(value, deref!(expected, fixture))
  end

  defp matches_value?(:error, _expected, _fixture), do: false

  defp matches_value?({:ok, value}, expected, fixture) when is_map(expected) do
    case operator_keys(expected) do
      [] -> equal?(value, expected)
      keys -> Enum.all?(keys, &operator_ok?(&1, expected[&1], value, fixture))
    end
  end

  defp matches_value?({:ok, value}, expected, _fixture), do: equal?(value, expected)

  # A `where` value that is a map is either an operator map or a case-file
  # mistake. Every key has to be recognised: a typo'd `"lte"` would otherwise
  # match nothing and silently pass, which is the failure mode this whole module
  # is written against.
  defp operator_keys(map) do
    keys = Map.keys(map)

    cond do
      Enum.all?(keys, &(&1 in @operators)) ->
        keys

      Enum.any?(keys, &(&1 in @operators)) ->
        raise ArgumentError,
              "case file mixes matcher operators with plain keys: #{inspect(keys)}"

      keys != [] ->
        raise ArgumentError, "case file has unrecognised matcher operator(s): #{inspect(keys)}"

      true ->
        []
    end
  end

  defp operator_ok?("fixture", path, value, fixture), do: equal?(value, deref!(path, fixture))

  defp operator_ok?("lt", bound, value, fixture),
    do: is_number(value) and value < number!(bound, fixture)

  defp operator_ok?("gt", bound, value, fixture),
    do: is_number(value) and value > number!(bound, fixture)

  defp operator_ok?("between", [low, high], value, fixture) do
    is_number(value) and value >= number!(low, fixture) and value <= number!(high, fixture)
  end

  defp operator_ok?(key, _spec, _value, _fixture) do
    raise ArgumentError, "unknown matcher operator #{inspect(key)}"
  end

  defp number!(spec, fixture) do
    case deref!(spec, fixture) do
      value when is_number(value) -> value
      other -> raise ArgumentError, "expected a number bound, got #{inspect(other)}"
    end
  end

  @doc """
  Resolves `{"fixture": path}` against the fixture; anything else is itself.

  Paths are dotted with optional `[index]` steps: `"master.volume"`,
  `"clips.1:0.notes[2]"`. A clip key contains a colon, never a dot, so dotted
  splitting is unambiguous.
  """
  @spec deref!(term(), Fixture.t()) :: term()
  def deref!(%{"fixture" => path}, fixture) when is_binary(path), do: fixture_path!(fixture, path)
  def deref!(value, _fixture), do: value

  defp fixture_path!(fixture, path) do
    path
    |> String.split(".")
    |> Enum.flat_map(&expand_step/1)
    |> Enum.reduce(raw(fixture), &step!(&2, &1, path))
  end

  defp expand_step(segment) do
    case Regex.run(~r/^([^\[]+)\[(\d+)\]$/, segment) do
      [_all, name, index] -> [name, String.to_integer(index)]
      _ -> [segment]
    end
  end

  defp step!(nil, _key, path), do: raise(ArgumentError, "fixture path #{path} ran off the end")

  defp step!(list, index, _path) when is_list(list) and is_integer(index),
    do: Enum.at(list, index)

  defp step!(map, key, path) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "fixture path #{path} has no key #{inspect(key)}"
    end
  end

  defp step!(_other, _key, path),
    do: raise(ArgumentError, "fixture path #{path} is not traversable")

  # The judge dereferences into the fixture's *source* shape (string keys), the
  # same one the case files are written against.
  defp raw(%Fixture{} = fixture) do
    %{
      "master" => stringify(fixture.master),
      "song" => stringify(fixture.song),
      "tracks" => Enum.map(fixture.tracks, &stringify/1),
      "return_tracks" => Enum.map(fixture.return_tracks, &stringify/1),
      "clips" => fixture.clips
    }
  end

  defp stringify(nil), do: %{}
  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  # Clip notes, as the case file's fixture paths see them.
  defp clip_notes(arguments, fixture) do
    key = "#{arguments["track"]}:#{arguments["clip_slot"] || 0}"

    case Map.get(fixture.clips, key) do
      nil -> nil
      clip -> Map.get(clip, "notes", [])
    end
  end

  # `get_clip_notes`/`edit_notes`/`remove_notes` share one window: a pitch range
  # and a time range, each with the schema's documented default when omitted.
  defp select(notes, arguments) do
    start_pitch = arguments["start_pitch"] || 0
    pitch_span = arguments["pitch_span"] || 128
    start_time = number(arguments["start_time"] || 0)
    time_span = arguments["time_span"]

    Enum.filter(notes, fn note ->
      pitch = note["pitch"]
      start = number(note["start_time"])

      pitch >= start_pitch and pitch < start_pitch + pitch_span and
        start >= start_time and
        (is_nil(time_span) or start < start_time + number(time_span))
    end)
  end

  defp same_notes?(selected, wanted) do
    key = fn note -> {note["pitch"], number(note["start_time"])} end

    Enum.sort(Enum.map(selected, key)) == Enum.sort(Enum.map(wanted, key))
  end

  defp equal?(a, b) when is_number(a) and is_number(b), do: equal_number?(a, b)
  defp equal?(a, b), do: a == b

  defp equal_number?(a, b) when is_number(a) and is_number(b), do: abs(a - b) < 1.0e-6
  defp equal_number?(_a, _b), do: false

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_value), do: 0.0
end
