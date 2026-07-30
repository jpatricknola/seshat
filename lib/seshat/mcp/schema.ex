defmodule Seshat.MCP.Schema do
  @moduledoc """
  Converts the JSON Schema stored in `Seshat.Tools.Definitions` into the raw
  schema format Anubis components expect (native Peri types, with descriptions
  carried in `{:meta, type, opts}` wrappers, which Peri turns back into JSON
  Schema for the MCP wire).

  This runs at compile time, from `Seshat.MCP.Tools`. It exists so that both
  entry points — the Anthropic tool-use loop and the MCP server — describe
  their tools from one source of truth.
  """

  @doc """
  Converts a tool's `:parameters` JSON Schema into an Anubis raw schema map.

  Returns `%{}` for tools that take no parameters.
  """
  def to_anubis(%{properties: properties} = schema) do
    required = Map.get(schema, :required, [])

    Map.new(properties, fn {name, spec} ->
      type =
        spec
        |> peri_type()
        |> with_description(Map.get(spec, :description))
        |> maybe_required(name in required)

      {String.to_atom(name), type}
    end)
  end

  def to_anubis(_schema), do: %{}

  # Enum first: an enum spec also carries a `:type`, and the enum is the
  # tighter constraint.
  defp peri_type(%{enum: values}), do: {:enum, values}

  defp peri_type(%{type: "string"}), do: :string
  defp peri_type(%{type: "boolean"}), do: :boolean
  defp peri_type(%{type: "integer"} = spec), do: with_range(:integer, spec)

  # Peri's `:float` rejects integers, and models routinely emit `1` where the
  # schema says number. Accept both rather than failing a well-formed call;
  # the handlers coerce with `value / 1.0` anyway. Both branches carry the
  # declared range, so an in-range integer still satisfies the float branch
  # (Peri's bound clauses guard on `is_numeric/1`) while an out-of-range value
  # fails both and is rejected at the wire. The bounds also survive into the
  # advertised `input_schema`, as `minimum`/`maximum` inside each `oneOf`
  # branch — that advertisement is the point of carrying them here; the
  # authoritative check is `Seshat.Tools.Validation`.
  defp peri_type(%{type: "number"} = spec),
    do: {:either, {with_range(:float, spec), with_range(:integer, spec)}}

  defp peri_type(%{type: "array", items: items}), do: {:list, peri_type(items)}
  defp peri_type(%{type: "object"} = spec), do: to_anubis(spec)
  defp peri_type(_spec), do: :any

  defp with_range(base, %{minimum: min, maximum: max}), do: {base, {:range, {min, max}}}
  defp with_range(base, %{minimum: min}), do: {base, {:gte, min}}
  defp with_range(base, %{maximum: max}), do: {base, {:lte, max}}
  defp with_range(base, _spec), do: base

  defp with_description(type, nil), do: type
  defp with_description(type, description), do: {:meta, type, [description: description]}

  # Required wraps outermost — the shape Peri's encoder and validator expect
  # (`{:required, {:meta, type, opts}}`).
  defp maybe_required(type, true), do: {:required, type}
  defp maybe_required(type, false), do: type
end
