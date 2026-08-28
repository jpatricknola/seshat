defmodule Seshat.Eval.SchemaCheck do
  @moduledoc """
  Validates a recorded tool call against the **published** JSON Schema of the
  surface being evaluated.

  Deliberately not `Seshat.Tools.Validation`, which reads the *current*
  `Seshat.Tools.Definitions` at compile time. That is exactly right in
  production and useless here: half the calls the recorder has to judge are made
  against the 67-tool base snapshot, whose tools no longer exist in
  `Definitions` at all. So this reads the schema out of the snapshot, keys and
  all, and knows nothing about any particular tool.

  The wording deliberately matches `Validation`'s ("`pan`: must be at most 1.0
  (got 2.0)"), because the recorded rejection is what the model under test reads
  — if it read differently from production's, the trial would be measuring the
  harness rather than the contract.

  ## Closed by default

  An object rejects unknown keys unless it says `"additionalProperties": true`.
  The head surface writes `"additionalProperties": false` explicitly and the
  base surface (captured before `Seshat.MCP.Schema` emitted the key) writes
  nothing — but `Validation` has always rejected unknown keys on both, so
  treating a silent schema as open would let base pass calls production would
  refuse and hand it an advantage it never had in Live.

  Pure: no process, no OSC, no `Definitions`.
  """

  @doc """
  Every way `arguments` violates `schema`, in a stable order. `[]` means valid.
  """
  @spec violations(map(), map()) :: [String.t()]
  def violations(schema, arguments) when is_map(schema) and is_map(arguments) do
    object_violations(schema, arguments, "")
  end

  defp object_violations(%{"properties" => properties} = schema, params, path)
       when is_map(params) do
    required = Map.get(schema, "required", [])
    allowed = properties |> Map.keys() |> Enum.sort()

    unknown =
      if Map.get(schema, "additionalProperties", false) == true do
        []
      else
        params
        |> Map.keys()
        |> Enum.reject(&Map.has_key?(properties, &1))
        |> Enum.sort()
        |> Enum.map(&unknown_violation(join(path, &1), allowed))
      end

    known =
      properties
      |> Enum.sort_by(fn {name, _spec} -> name end)
      |> Enum.flat_map(fn {name, spec} ->
        case Map.fetch(params, name) do
          {:ok, value} -> check(spec, value, join(path, name))
          :error -> missing(name in required, spec, join(path, name))
        end
      end)

    unknown ++ known
  end

  # A schema with no `properties` (or arguments that aren't an object) constrains
  # nothing this checker can act on.
  defp object_violations(_schema, _params, _path), do: []

  defp missing(true, spec, path), do: [violation(path, "required but missing", spec)]
  defp missing(false, _spec, _path), do: []

  # Enum first, matching `Validation`: it is the tighter constraint and subsumes
  # the declared type.
  defp check(%{"enum" => values} = spec, value, path) do
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

  # `is_integer/1`, not "a float that happens to be whole": `Validation` rejects
  # 1.0 for an integer parameter too, and Jason decodes a JSON `1` as an integer,
  # so a model writing `track: 1` is never caught by the strictness.
  defp type_ok?(%{"type" => "integer"}, value), do: is_integer(value)
  defp type_ok?(%{"type" => "number"}, value), do: is_number(value)
  defp type_ok?(%{"type" => "string"}, value), do: is_binary(value)
  defp type_ok?(%{"type" => "boolean"}, value), do: is_boolean(value)
  defp type_ok?(%{"type" => "array"}, value), do: is_list(value)
  defp type_ok?(%{"type" => "object"}, value), do: is_map(value) and not is_struct(value)
  defp type_ok?(_spec, _value), do: true

  defp type_name(%{"type" => "integer"}), do: "an integer"
  defp type_name(%{"type" => "number"}), do: "a number"
  defp type_name(%{"type" => "string"}), do: "a string"
  defp type_name(%{"type" => "boolean"}), do: "a boolean"
  defp type_name(%{"type" => "array"}), do: "an array"
  defp type_name(%{"type" => "object"}), do: "an object"
  defp type_name(_spec), do: "the declared type"

  defp bounds(spec, value, path) when is_number(value) do
    below =
      case Map.fetch(spec, "minimum") do
        {:ok, min} when value < min ->
          [violation(path, "must be at least #{inspect(min)} (got #{inspect(value)})", spec)]

        _ ->
          []
      end

    above =
      case Map.fetch(spec, "maximum") do
        {:ok, max} when value > max ->
          [violation(path, "must be at most #{inspect(max)} (got #{inspect(value)})", spec)]

        _ ->
          []
      end

    below ++ above
  end

  defp bounds(_spec, _value, _path), do: []

  defp nested(%{"type" => "array", "items" => items}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> check(items, item, "#{path}[#{index}]") end)
  end

  defp nested(%{"type" => "object"} = spec, value, path),
    do: object_violations(spec, value, path)

  defp nested(_spec, _value, _path), do: []

  defp violation(path, text, spec) do
    case Map.get(spec, "description") do
      nil -> "- #{path}: #{text}"
      description -> "- #{path}: #{text} — #{description}"
    end
  end

  defp unknown_violation(path, []), do: "- #{path}: unknown parameter — expected no parameters"

  defp unknown_violation(path, allowed) do
    "- #{path}: unknown parameter — expected one of " <>
      Enum.map_join(allowed, ", ", &inspect/1)
  end

  defp join("", name), do: name
  defp join(path, name), do: "#{path}.#{name}"

  @doc """
  The rejection text a tool call gets back, worded as production words it.
  """
  @spec message(String.t(), [String.t()]) :: String.t()
  def message(tool_name, violations) do
    "Invalid parameters for #{tool_name} — nothing was sent to Ableton:\n" <>
      Enum.join(violations, "\n")
  end
end
