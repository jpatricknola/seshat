defmodule Seshat.Tools.ValidationTest do
  @moduledoc """
  The declared schemas were advisory before `Seshat.Tools.Validation` existed:
  the Anthropic API enforces nothing, and Peri's bound clauses guard on
  `is_numeric/1` rather than the base type. The hand-written cases below pin the
  behaviours that mattered; the boundary sweep at the bottom is the part that
  keeps covering tools nobody has written yet.
  """

  use ExUnit.Case, async: true

  alias Seshat.Tools.Definitions
  alias Seshat.Tools.Validation

  describe "index bounds" do
    test "rejects a negative track index, naming the parameter" do
      assert {:error, message} = Validation.validate("delete_track", %{"track" => -1})
      assert message =~ "Invalid parameters for delete_track"
      assert message =~ "nothing was sent to Ableton"
      assert message =~ "- track: must be at least 0 (got -1)"
    end

    test "the error text carries the parameter's own description" do
      assert {:error, message} = Validation.validate("delete_track", %{"track" => -1})
      assert message =~ "— 0-indexed track number to delete"
    end

    test "accepts index 0" do
      assert :ok = Validation.validate("delete_track", %{"track" => 0})
    end

    test "rejects a non-integer index" do
      assert {:error, message} =
               Validation.validate("set_track_pan", %{"track" => 1.5, "value" => 0.0})

      assert message =~ "- track: must be an integer (got 1.5)"
    end
  end

  describe "numeric ranges" do
    test "rejects a pan above the maximum" do
      assert {:error, message} =
               Validation.validate("set_track_pan", %{"track" => 0, "value" => 2.0})

      assert message =~ "- value: must be at most 1.0 (got 2.0)"
    end

    test "rejects a pan below the minimum" do
      assert {:error, message} =
               Validation.validate("set_track_pan", %{"track" => 0, "value" => -1.5})

      assert message =~ "- value: must be at least -1.0 (got -1.5)"
    end

    test "accepts the exact bounds and an integer where the schema says number" do
      assert :ok = Validation.validate("set_track_pan", %{"track" => 0, "value" => -1.0})
      assert :ok = Validation.validate("set_track_pan", %{"track" => 0, "value" => 1.0})
      assert :ok = Validation.validate("set_track_pan", %{"track" => 0, "value" => 1})
    end
  end

  describe "create_scene's append convention" do
    # -1 is AbletonOSC's own "append at the end" for /live/song/create_scene,
    # so this is the one index in the surface that floors at -1 rather than 0.
    test "accepts -1" do
      assert :ok = Validation.validate("create_scene", %{"index" => -1})
    end

    test "rejects -2" do
      assert {:error, message} = Validation.validate("create_scene", %{"index" => -2})
      assert message =~ "- index: must be at least -1 (got -2)"
    end
  end

  describe "enums" do
    test "rejects a value outside the enum, listing what is allowed" do
      params = %{"track" => 0, "clip_slot" => 0, "warp_mode" => 5}

      assert {:error, message} = Validation.validate("set_clip_properties", params)
      assert message =~ "- warp_mode: must be one of 0, 1, 2, 3, 4, 6 (got 5)"
    end

    test "accepts a value inside the enum" do
      params = %{"track" => 0, "clip_slot" => 0, "warp_mode" => 6}
      assert :ok = Validation.validate("set_clip_properties", params)
    end
  end

  describe "quantize_clip" do
    # "1/2" rather than a triplet value: the triplet grids are real and offered,
    # while a 1/2 grid is both a plausible model guess and a thing Live's
    # GridQuantization enum genuinely cannot do — nothing in its valid range is
    # coarser than a 1/4 note. That is the case worth pinning.
    test "rejects a grid Live has no enum value for" do
      params = %{"track" => 0, "clip_slot" => 0, "grid" => "1/2", "amount" => 0.5}

      assert {:error, message} = Validation.validate("quantize_clip", params)
      assert message =~ "- grid: must be one of"
      assert message =~ ~s(got "1/2")
    end

    test "rejects a strength above 1.0" do
      params = %{"track" => 0, "clip_slot" => 0, "grid" => "1/16", "amount" => 1.5}

      assert {:error, message} = Validation.validate("quantize_clip", params)
      assert message =~ "- amount: must be at most 1.0 (got 1.5)"
    end
  end

  describe "set_time_signature" do
    # AbletonOSC's `_set_property` logs and swallows whatever the Live API
    # rejects, and setters never reply — so a signature Live cannot express is
    # indistinguishable from success on the wire. These three cases are what
    # keeps that hole closed: the refusal happens here, before anything is sent.
    test "rejects a numerator below the minimum" do
      assert {:error, message} =
               Validation.validate("set_time_signature", %{"numerator" => 0, "denominator" => 4})

      assert message =~ "- numerator: must be at least 1 (got 0)"
    end

    test "rejects a denominator Live's own control has no setting for" do
      assert {:error, message} =
               Validation.validate("set_time_signature", %{"numerator" => 3, "denominator" => 3})

      assert message =~ "- denominator: must be one of 1, 2, 4, 8, 16 (got 3)"
    end

    test "rejects a float numerator rather than coercing it" do
      assert {:error, message} =
               Validation.validate("set_time_signature", %{"numerator" => 6.0, "denominator" => 8})

      assert message =~ "- numerator: must be an integer (got 6.0)"
    end

    test "accepts an odd signature inside the bounds" do
      assert :ok =
               Validation.validate("set_time_signature", %{"numerator" => 7, "denominator" => 8})
    end
  end

  # The two amounts look interchangeable and are not: swing tops out at Live's
  # documented 1.0, groove at 1.3 — because Ableton's own Move script clamps
  # `groove_amount` to 1.3125 and renders it as `round(min(x, 1.3) * 100)`%, so
  # the apiref's "0.0 - 1.0" understates the dial rather than bounding it.
  # Harmonising the two at 1.0 would silently cost the top 30% of the range:
  # `_set_property` swallows the rejection, so an over-bound value is a no-op,
  # not an error.
  describe "swing and groove amounts" do
    test "set_swing_amount rejects an amount above 1.0" do
      assert {:error, message} = Validation.validate("set_swing_amount", %{"amount" => 1.5})
      assert message =~ "- amount: must be at most 1.0 (got 1.5)"
    end

    test "set_groove_amount rejects an amount above 1.3" do
      assert {:error, message} = Validation.validate("set_groove_amount", %{"amount" => 1.4})
      assert message =~ "- amount: must be at most 1.3 (got 1.4)"
    end

    # The case that fails if someone later "fixes" groove's maximum to 1.0.
    test "set_groove_amount accepts 1.2, above swing's ceiling" do
      assert :ok = Validation.validate("set_groove_amount", %{"amount" => 1.2})
    end

    test "both reject a negative amount" do
      assert {:error, swing} = Validation.validate("set_swing_amount", %{"amount" => -0.1})
      assert {:error, groove} = Validation.validate("set_groove_amount", %{"amount" => -0.1})
      assert swing =~ "- amount: must be at least 0.0 (got -0.1)"
      assert groove =~ "- amount: must be at least 0.0 (got -0.1)"
    end

    test "both reject a non-number" do
      assert {:error, swing} = Validation.validate("set_swing_amount", %{"amount" => "0.2"})
      assert {:error, groove} = Validation.validate("set_groove_amount", %{"amount" => "0.2"})
      assert swing =~ "- amount: must be a number"
      assert groove =~ "- amount: must be a number"
    end

    test "both accept a value inside their range" do
      assert :ok = Validation.validate("set_swing_amount", %{"amount" => 0.2})
      assert :ok = Validation.validate("set_groove_amount", %{"amount" => 0.0})
    end
  end

  describe "nested structures" do
    test "reports the path into an array of objects" do
      notes = [%{"pitch" => 60, "start_beat" => 0.0, "duration" => 1.0, "velocity" => 0}]

      assert {:error, message} =
               Validation.validate("write_midi_notes", %{"track" => 0, "notes" => notes})

      assert message =~ "- notes[0].velocity: must be at least 1 (got 0)"
    end

    test "indexes the offending element, not the first one" do
      good = %{"pitch" => 60, "start_beat" => 0.0, "duration" => 1.0, "velocity" => 100}
      bad = %{good | "pitch" => 128}

      assert {:error, message} =
               Validation.validate("write_midi_notes", %{
                 "track" => 0,
                 "notes" => [good, good, bad]
               })

      assert message =~ "- notes[2].pitch: must be at most 127 (got 128)"
    end

    test "reports a missing required field inside an array element" do
      notes = [%{"pitch" => 60, "start_beat" => 0.0, "duration" => 1.0}]

      assert {:error, message} =
               Validation.validate("write_midi_notes", %{"track" => 0, "notes" => notes})

      assert message =~ "- notes[0].velocity: required but missing"
    end
  end

  describe "required params" do
    # Before this existed, a known tool called without a required param fell
    # through the pattern-matched do_call/2 clauses to the catch-all and
    # reported "Unknown tool: set_track_pan".
    test "names the missing param rather than blaming the tool" do
      assert {:error, message} = Validation.validate("set_track_pan", %{"track" => 0})
      assert message =~ "- value: required but missing"
      refute message =~ "Unknown tool"
    end

    test "an optional param may be omitted" do
      assert :ok = Validation.validate("get_clip_notes", %{"track" => 0})
    end
  end

  describe "reporting" do
    test "collects every violation instead of stopping at the first" do
      assert {:error, message} =
               Validation.validate("set_device_parameter", %{
                 "track" => -1,
                 "device" => -2,
                 "parameter" => -3,
                 "value" => 0.0
               })

      assert message =~ "- track: must be at least 0 (got -1)"
      assert message =~ "- device: must be at least 0 (got -2)"
      assert message =~ "- parameter: must be at least 0 (got -3)"
    end

    test "an unknown tool name passes through — do_call/2's catch-all owns that reply" do
      assert :ok = Validation.validate("no_such_tool", %{"track" => -1})
    end

    test "params the schema doesn't mention are ignored" do
      assert :ok = Validation.validate("delete_track", %{"track" => 0, "extra" => -99})
    end

    test "a param with no declared bounds is left alone" do
      # set_device_parameter.value is deliberately unbounded: its legal range is
      # per-parameter and Live clamps it.
      params = %{"track" => 0, "device" => 0, "parameter" => 0, "value" => -9999.0}
      assert :ok = Validation.validate("set_device_parameter", params)
    end
  end

  describe "type checking" do
    test "a string where a number is declared is rejected, not compared" do
      # Elixir's term ordering would happily conclude `"loud" >= -1.0`.
      assert {:error, message} =
               Validation.validate("set_track_pan", %{"track" => 0, "value" => "loud"})

      assert message =~ "- value: must be a number (got \"loud\")"
    end

    test "rejects the wrong type for string, boolean and array params" do
      assert {:error, message} =
               Validation.validate("set_track_name", %{"track" => 0, "name" => 7})

      assert message =~ "- name: must be a string (got 7)"

      assert {:error, message} =
               Validation.validate("set_track_mute", %{"track" => 0, "muted" => "yes"})

      assert message =~ "- muted: must be a boolean (got \"yes\")"

      assert {:error, message} =
               Validation.validate("write_midi_notes", %{"track" => 0, "notes" => "none"})

      assert message =~ "- notes: must be an array (got \"none\")"
    end
  end

  # ------------------------------------------------------------------
  # Schema-generated boundary sweep
  #
  # The review asked for "parity tests that submit values immediately outside
  # every declared bound". Hand-writing those would go stale the first time a
  # tool is added, so they are generated from the definitions instead: every
  # bounded property in the whole surface, top-level and nested, probed on both
  # sides of both bounds.
  # ------------------------------------------------------------------

  describe "every tool's synthesized minimal params" do
    test "validate" do
      for %{name: name, parameters: schema} <- Definitions.all() do
        params = synthesize(schema, :required_only)

        assert Validation.validate(name, params) == :ok,
               "minimal params for #{name} were rejected: #{inspect(params)}"
      end
    end
  end

  describe "declared bounds" do
    test "reject values immediately outside them and accept the bounds themselves" do
      for %{name: name, parameters: schema} <- Definitions.all(),
          {path, spec} <- bounded_properties(schema) do
        params = synthesize(schema, :everything)
        step = if spec.type == "integer", do: 1, else: 0.01

        if minimum = Map.get(spec, :minimum) do
          at = put_path(params, path, minimum)

          assert Validation.validate(name, at) == :ok,
                 "#{name} rejected #{label(path)} at its own minimum #{inspect(minimum)}"

          below = put_path(params, path, minimum - step)

          assert {:error, _} = Validation.validate(name, below),
                 "#{name} accepted #{label(path)} below its minimum #{inspect(minimum)}"
        end

        if maximum = Map.get(spec, :maximum) do
          at = put_path(params, path, maximum)

          assert Validation.validate(name, at) == :ok,
                 "#{name} rejected #{label(path)} at its own maximum #{inspect(maximum)}"

          above = put_path(params, path, maximum + step)

          assert {:error, _} = Validation.validate(name, above),
                 "#{name} accepted #{label(path)} above its maximum #{inspect(maximum)}"
        end
      end
    end

    test "the sweep actually covers the surface" do
      covered =
        Enum.flat_map(Definitions.all(), fn %{parameters: schema} ->
          bounded_properties(schema)
        end)

      # A guard against the sweep silently degenerating to nothing if
      # `bounded_properties/1` ever stops matching the definitions' shape.
      assert length(covered) > 40
    end
  end

  # --- sweep helpers ---

  # `:required_only` builds the smallest map that should validate;
  # `:everything` fills in the optional params too, so an optional bounded
  # property has a slot to be probed in.
  defp synthesize(schema, mode) do
    properties = Map.get(schema, :properties, %{})
    required = Map.get(schema, :required, [])

    properties
    |> Enum.filter(fn {name, _spec} -> mode == :everything or name in required end)
    |> Map.new(fn {name, spec} -> {name, sample(spec)} end)
  end

  defp sample(%{enum: [first | _]}), do: first
  defp sample(%{type: "integer"} = spec), do: Map.get(spec, :minimum, 0)
  defp sample(%{type: "number"} = spec), do: Map.get(spec, :minimum, 0) * 1.0
  defp sample(%{type: "string"}), do: "x"
  defp sample(%{type: "boolean"}), do: true
  defp sample(%{type: "array", items: items}), do: [sample(items)]
  defp sample(%{type: "object"} = spec), do: synthesize(spec, :everything)

  # Returns `{path, spec}` for every numeric property carrying a bound, where a
  # path segment is a property name or an array index. Enum properties are
  # excluded: membership, not range, is what constrains them.
  defp bounded_properties(schema, path \\ []) do
    schema
    |> Map.get(:properties, %{})
    |> Enum.sort_by(fn {name, _spec} -> name end)
    |> Enum.flat_map(fn {name, spec} ->
      here = path ++ [name]
      own = if bounded?(spec), do: [{here, spec}], else: []

      own ++ descend(spec, here)
    end)
  end

  defp descend(%{type: "array", items: %{type: "object"} = items}, path) do
    bounded_properties(items, path ++ [0])
  end

  defp descend(%{type: "array", items: items}, path) do
    if bounded?(items), do: [{path ++ [0], items}], else: []
  end

  defp descend(%{type: "object"} = spec, path), do: bounded_properties(spec, path)
  defp descend(_spec, _path), do: []

  defp bounded?(spec) do
    not Map.has_key?(spec, :enum) and
      (Map.has_key?(spec, :minimum) or Map.has_key?(spec, :maximum))
  end

  defp put_path(params, [name], value) when is_binary(name), do: Map.put(params, name, value)

  defp put_path(params, [name | rest], value) when is_binary(name) do
    Map.put(params, name, put_path(Map.fetch!(params, name), rest, value))
  end

  defp put_path(list, [index | rest], value) when is_integer(index) do
    List.update_at(list, index, &put_path(&1, rest, value))
  end

  defp label(path), do: Enum.map_join(path, ".", &to_string/1)
end
