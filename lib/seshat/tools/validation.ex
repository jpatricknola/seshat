defmodule Seshat.Tools.Validation do
  @moduledoc """
  Validates tool parameters against the JSON Schema in `Seshat.Tools.Definitions`.

  This is the authoritative bounds check for both entry modes. Neither one
  enforces the schemas on its own: the Anthropic API does not validate tool
  input at all, and Peri (MCP mode) checks a bound without re-checking the base
  type, so `track: 1.5` satisfies `{:integer, {:gte, 0}}`. `Handlers.call/2`
  runs this before dispatch, so a bad value is rejected before any OSC leaves
  the process.

  Rejection, never coercion: a schema saying `integer` means an integer, and
  truncating `1.5` or clamping `2.0` to `1.0` would silently execute something
  the model didn't ask for.

  All violations are collected rather than stopping at the first, so the model
  can fix everything in one retry. Each line ends with the parameter's own
  schema description where it has one — that text is already the model-facing
  teaching material, so it is reused instead of writing a second set of hints.
  """

  alias Seshat.Tools.Definitions

  @schemas Map.new(Definitions.all(), &{&1.name, &1.parameters})

  @doc """
  Checks `params` against the named tool's schema.

  `params` must already be string-keyed (`Handlers.stringify_keys/1` runs
  first). An unknown tool name is `:ok` — `Handlers.do_call/2`'s catch-all owns
  the "Unknown tool" reply.
  """
  @spec validate(String.t(), map()) :: :ok | {:error, String.t()}
  def validate(name, params) when is_binary(name) and is_map(params) do
    case Map.fetch(@schemas, name) do
      :error ->
        :ok

      {:ok, schema} ->
        case object_violations(schema, params, "") do
          [] -> :ok
          violations -> {:error, message(name, violations)}
        end
    end
  end

  defp message(name, violations) do
    lines = Enum.map_join(violations, "\n", &render/1)
    "Invalid parameters for #{name} — nothing was sent to Ableton:\n#{lines}"
  end

  defp render({path, reason, nil}), do: "- #{path}: #{reason}"
  defp render({path, reason, description}), do: "- #{path}: #{reason} — #{description}"

  # Sorted so a multi-violation message reads the same way every time; map key
  # order is not guaranteed.
  defp object_violations(schema, params, prefix) do
    properties = Map.get(schema, :properties, %{})
    required = Map.get(schema, :required, [])

    (Map.keys(properties) ++ required)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      spec = Map.get(properties, name, %{})
      path = prefix <> name

      cond do
        Map.has_key?(params, name) -> value_violations(path, spec, Map.get(params, name))
        name in required -> [{path, "required but missing", Map.get(spec, :description)}]
        true -> []
      end
    end)
  end

  # An enum spec also carries a `:type`, but membership is the tighter check and
  # subsumes it.
  defp value_violations(path, %{enum: values} = spec, value) do
    if value in values do
      []
    else
      allowed = Enum.map_join(values, ", ", &inspect/1)
      [{path, "must be one of #{allowed} (got #{inspect(value)})", Map.get(spec, :description)}]
    end
  end

  defp value_violations(path, spec, value) do
    case type_error(Map.get(spec, :type), value) do
      nil ->
        bounds_violations(path, spec, value) ++ nested_violations(path, spec, value)

      expected ->
        [{path, "must be #{expected} (got #{inspect(value)})", Map.get(spec, :description)}]
    end
  end

  # Returns the expected-type phrase when the value is wrong, or nil when it is
  # acceptable. Type checking is what keeps the bounds comparison honest —
  # Elixir's term ordering would happily conclude `"abc" >= 0`.
  defp type_error("integer", value) when is_integer(value), do: nil
  defp type_error("integer", _value), do: "an integer"
  defp type_error("number", value) when is_number(value), do: nil
  defp type_error("number", _value), do: "a number"
  defp type_error("string", value) when is_binary(value), do: nil
  defp type_error("string", _value), do: "a string"
  defp type_error("boolean", value) when is_boolean(value), do: nil
  defp type_error("boolean", _value), do: "a boolean"
  defp type_error("array", value) when is_list(value), do: nil
  defp type_error("array", _value), do: "an array"
  defp type_error("object", value) when is_map(value), do: nil
  defp type_error("object", _value), do: "an object"
  defp type_error(_type, _value), do: nil

  defp bounds_violations(path, spec, value) when is_number(value) do
    description = Map.get(spec, :description)

    below =
      case Map.fetch(spec, :minimum) do
        {:ok, min} when value < min ->
          [{path, "must be at least #{inspect(min)} (got #{inspect(value)})", description}]

        _ ->
          []
      end

    above =
      case Map.fetch(spec, :maximum) do
        {:ok, max} when value > max ->
          [{path, "must be at most #{inspect(max)} (got #{inspect(value)})", description}]

        _ ->
          []
      end

    below ++ above
  end

  defp bounds_violations(_path, _spec, _value), do: []

  defp nested_violations(path, %{type: "array", items: items}, value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> value_violations("#{path}[#{index}]", items, item) end)
  end

  defp nested_violations(path, %{type: "object"} = spec, value) when is_map(value) do
    object_violations(spec, value, path <> ".")
  end

  defp nested_violations(_path, _spec, _value), do: []
end
