defmodule Seshat.Tools.Validation do
  @moduledoc """
  Enforces the JSON Schema each tool declares in `Seshat.Tools.Definitions`.

  The schemas were advisory until this module existed. The Anthropic API does
  not enforce tool schemas at all, so API-key mode had no validation layer
  whatsoever; MCP mode had Peri, which checks bounds without re-checking the
  base type (a `{:integer, {:gte, 0}}` guards on `is_numeric/1`), so a bounded
  integer param accepted `1.5`. Both leaks mattered because AbletonOSC's Python
  indexes Live's collections directly — `song.tracks[-1]` is the *last* track,
  so `delete_track` with `track: -1` used to delete a real track and echo
  "track -1" as if that were the target.

  So this is the authoritative check, called from `Seshat.Tools.Handlers.call/2`
  — the single dispatch point both entry modes funnel through — before anything
  reaches `Seshat.OSC.Transport`. Because it reads the schemas rather than
  hand-listing rules, every tool added later is covered by construction.

  Pure: no process, no OSC, no side effects.

  Deliberately *not* here: existence checks ("does track 7 exist?"). Those are
  dynamic session state, not schema, and stay with the guard-getter pattern in
  the handlers. Nothing is coerced, either — a schema saying `integer` rejects
  `1.5` rather than truncating it, because silently executing something the
  model didn't ask for is the defect class this module exists to kill.
  """

  alias Seshat.Tools.Definitions

  @schemas Map.new(Definitions.all(), fn tool -> {tool.name, tool.parameters} end)

  @doc """
  Validates `params` against the named tool's declared schema.

  `params` must already be string-keyed — `Handlers.stringify_keys/1` runs
  first, so the MCP mode's atom keys and the Anthropic API's string keys are
  validated identically.

  Returns `:ok` for an unknown tool name: `do_call/2`'s catch-all owns the
  "Unknown tool" reply, and duplicating it here would only make the two
  disagree later.

  All violations are collected rather than stopping at the first, so a model
  fixing its call gets the whole list in one retry.
  """
  @spec validate(String.t(), map()) :: :ok | {:error, String.t()}
  def validate(name, params) when is_binary(name) and is_map(params) do
    case Map.fetch(@schemas, name) do
      :error ->
        :ok

      {:ok, schema} ->
        case violations(schema, params, "") do
          [] -> :ok
          found -> {:error, message(name, found)}
        end
    end
  end

  defp message(name, found) do
    "Invalid parameters for #{name} — nothing was sent to Ableton:\n" <>
      Enum.join(found, "\n")
  end

  # Params not named in the schema are ignored: handler clauses already ignore
  # unknown keys, and Peri governs the MCP wire.
  defp violations(%{properties: properties} = schema, params, path) when is_map(params) do
    required = Map.get(schema, :required, [])

    properties
    |> Enum.sort_by(fn {name, _spec} -> name end)
    |> Enum.flat_map(fn {name, spec} ->
      case Map.fetch(params, name) do
        {:ok, value} -> check(spec, value, join(path, name))
        :error -> missing(name in required, spec, join(path, name))
      end
    end)
  end

  defp violations(_schema, _params, _path), do: []

  defp missing(true, spec, path), do: [violation(path, "required but missing", spec)]
  defp missing(false, _spec, _path), do: []

  # An enum is the tighter constraint and subsumes the type check, matching
  # `Seshat.MCP.Schema`'s ordering. Otherwise the type is checked first and the
  # bounds only afterwards: Elixir's term ordering would happily conclude
  # `"abc" >= 0`, so an unchecked type makes the bounds comparison meaningless.
  defp check(%{enum: values} = spec, value, path) do
    if value in values do
      []
    else
      allowed = Enum.map_join(values, ", ", &inspect/1)
      [violation(path, "must be one of #{allowed} (got #{inspect(value)})", spec)]
    end
  end

  defp check(spec, value, path) do
    if type_ok?(spec, value) do
      bounds(spec, value, path) ++ nested(spec, value, path)
    else
      [violation(path, "must be #{type_name(spec)} (got #{inspect(value)})", spec)]
    end
  end

  defp type_ok?(%{type: "integer"}, value), do: is_integer(value)
  defp type_ok?(%{type: "number"}, value), do: is_number(value)
  defp type_ok?(%{type: "string"}, value), do: is_binary(value)
  defp type_ok?(%{type: "boolean"}, value), do: is_boolean(value)
  defp type_ok?(%{type: "array"}, value), do: is_list(value)
  defp type_ok?(%{type: "object"}, value), do: is_map(value) and not is_struct(value)
  defp type_ok?(_spec, _value), do: true

  defp type_name(%{type: "integer"}), do: "an integer"
  defp type_name(%{type: "number"}), do: "a number"
  defp type_name(%{type: "string"}), do: "a string"
  defp type_name(%{type: "boolean"}), do: "a boolean"
  defp type_name(%{type: "array"}), do: "an array"
  defp type_name(%{type: "object"}), do: "an object"

  # Inclusive, and only reached once the value is known to be the right type.
  defp bounds(spec, value, path) when is_number(value) do
    below =
      case Map.fetch(spec, :minimum) do
        {:ok, min} when value < min ->
          [violation(path, "must be at least #{inspect(min)} (got #{inspect(value)})", spec)]

        _ ->
          []
      end

    above =
      case Map.fetch(spec, :maximum) do
        {:ok, max} when value > max ->
          [violation(path, "must be at most #{inspect(max)} (got #{inspect(value)})", spec)]

        _ ->
          []
      end

    below ++ above
  end

  defp bounds(_spec, _value, _path), do: []

  defp nested(%{type: "array", items: items}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> check(items, item, "#{path}[#{index}]") end)
  end

  defp nested(%{type: "object"} = spec, value, path), do: violations(spec, value, path)
  defp nested(_spec, _value, _path), do: []

  # The parameter's own description is already the model-facing teaching text,
  # so a violation reuses it rather than inventing a second set of hints.
  defp violation(path, text, spec) do
    case spec && Map.get(spec, :description) do
      nil -> "- #{path}: #{text}"
      description -> "- #{path}: #{text} — #{description}"
    end
  end

  defp join("", name), do: name
  defp join(path, name), do: "#{path}.#{name}"
end
