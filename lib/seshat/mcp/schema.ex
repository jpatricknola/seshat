defmodule Seshat.MCP.Schema do
  @moduledoc """
  Converts the JSON Schema stored in `Seshat.Tools.Definitions` into the two
  forms the MCP layer needs, both derived from that one source.

  `to_anubis/1` builds what Anubis *validates* against — native Peri types, with
  descriptions carried in `{:meta, type, opts}` wrappers. `to_json_schema/1`
  builds what the server *publishes* — the definition itself, string-keyed.

  They are deliberately separate, and the wire no longer comes from Peri's own
  encoder. That encoder renders an `integer | float` union as a `oneOf`, which
  carries no top-level `type`. Some MCP clients rely on that discriminator to
  decide how to serialise an argument: in the reported 2026-08-01 failure, a
  pan value shown as numeric in the model's call reached `Handlers` as the
  string `"-0.9"` and was rejected. The transformation was not independently
  observed on the wire, but publishing the definition verbatim avoids the
  ambiguous shape and keeps validator internals off the wire.

  Both run at compile time from `Seshat.MCP.Tools`, keeping the MCP surface
  derived from the format-agnostic definitions rather than hand-maintained.
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

  @doc """
  Returns the definition schema in the string-keyed form MCP publishes.

  This stays separate from `to_anubis/1`: Peri needs an `integer | float`
  union to accept integer-shaped values for an unbounded JSON Schema number,
  but publishing that implementation detail as `oneOf` drops the top-level
  `type` discriminator some MCP clients rely on.
  """
  def to_json_schema(schema), do: stringify_keys(schema)

  # Enum first: an enum spec also carries a `:type`, and the enum is the
  # tighter constraint.
  defp peri_type(%{enum: values}), do: {:enum, values}

  defp peri_type(%{type: "string"}), do: :string
  defp peri_type(%{type: "boolean"}), do: :boolean
  defp peri_type(%{type: "integer"} = spec), do: with_range(:integer, spec)

  # Peri's numeric bound clauses accept both integers and floats, so a bounded
  # float already implements JSON Schema's `number` semantics. Bare `:float`
  # rejects integers, though, so the one deliberately unbounded number keeps
  # the union internally. `to_json_schema/1` prevents that validator detail
  # from leaking onto the MCP wire as a typeless `oneOf`.
  defp peri_type(%{type: "number"} = spec) do
    if Map.has_key?(spec, :minimum) or Map.has_key?(spec, :maximum) do
      with_range(:float, spec)
    else
      {:either, {:float, :integer}}
    end
  end

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

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {stringify_key(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: key
end
