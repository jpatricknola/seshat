defmodule Seshat.Tools.DefinitionsTest do
  use ExUnit.Case, async: true

  alias Seshat.Tools.Definitions

  describe "all/0" do
    test "returns a list of tool definitions" do
      tools = Definitions.all()
      assert is_list(tools)
      assert length(tools) == 60
    end

    test "each tool has required fields" do
      for tool <- Definitions.all() do
        assert is_binary(tool.name), "tool missing name"
        assert is_binary(tool.description), "tool #{tool.name} missing description"
        assert is_map(tool.parameters), "tool #{tool.name} missing parameters"
        assert tool.parameters.type == "object", "tool #{tool.name} parameters not an object"
      end
    end

    test "includes all expected tool names" do
      expected = ~w(
        set_track_pan set_track_volume set_track_mute set_track_solo
        create_track write_midi_notes
        delete_track duplicate_track set_track_name
        set_tempo set_time_signature set_swing_amount set_groove_amount
        start_playing stop_playing set_metronome set_track_arm
        undo redo
        fire_clip stop_clip delete_clip duplicate_clip set_clip_name
        fire_scene create_scene delete_scene duplicate_scene set_scene_name
        set_loop show_view hide_view get_view_state
        select_track select_scene remove_notes get_clip_notes
        search_library reindex_library
        list_browser_items load_device
        get_track_devices get_device_parameters set_device_parameter
        delete_device bypass_device
        get_session_state get_clip_slots
        set_track_send get_track_sends
        create_return_track delete_return_track
        set_return_track_volume set_master_volume
        record_clip stop_recording capture_midi
        get_clip_properties set_clip_properties quantize_clip
      )

      names = Enum.map(Definitions.all(), & &1.name)

      for tool <- expected do
        assert tool in names, "missing tool: #{tool}"
      end
    end
  end

  describe "declared bounds" do
    # `Seshat.Tools.Validation` enforces whatever the schemas declare, so a new
    # tool that forgets to declare anything is enforced into nothing. These three
    # are the tripwires for that — an index that reaches AbletonOSC's Python
    # negative selects from the *end* of Live's collection, Python-style.
    @index_properties ~w(
      track clip_slot target_track target_clip_slot
      scene device parameter send return_track
    )

    test "every index-shaped property declares minimum: 0" do
      for {tool, path, name, spec} <- all_properties(),
          name in @index_properties do
        assert Map.get(spec, :minimum) == 0,
               "#{tool}.#{path} must declare minimum: 0 — a negative index selects from the " <>
                 "end of the collection in AbletonOSC's Python"
      end
    end

    test "every integer property declares an enum or a minimum" do
      for {tool, path, _name, spec} <- all_properties(),
          spec[:type] == "integer" do
        assert Map.has_key?(spec, :enum) or Map.has_key?(spec, :minimum),
               "#{tool}.#{path} is an unbounded integer — declare an enum or a minimum " <>
                 "(create_scene's index uses -1, AbletonOSC's append convention)"
      end
    end

    # `Validation` walks `properties` and consults `required` per-property, so a
    # name listed in `required` that matches no property is never checked — and
    # the call then falls through to `do_call/2`'s catch-all and reports
    # "Unknown tool", the misleading message this validator exists to replace.
    test "every required name is a declared property" do
      for {tool, path, schema} <- all_schemas(),
          name <- Map.get(schema, :required, []) do
        assert Map.has_key?(Map.get(schema, :properties, %{}), name),
               "#{tool}#{path} requires #{inspect(name)} but declares no such property — " <>
                 "Validation would silently not enforce it"
      end
    end

    # Flattens every property in the surface to {tool_name, dotted_path,
    # property_name, spec}, descending into arrays of objects and nested
    # objects.
    defp all_properties do
      Enum.flat_map(Definitions.all(), fn %{name: tool, parameters: schema} ->
        Enum.map(properties_of(schema), fn {path, name, spec} -> {tool, path, name, spec} end)
      end)
    end

    defp properties_of(schema, prefix \\ "") do
      schema
      |> Map.get(:properties, %{})
      |> Enum.flat_map(fn {name, spec} ->
        path = if prefix == "", do: name, else: "#{prefix}.#{name}"
        [{path, name, spec} | descend(spec, path)]
      end)
    end

    defp descend(%{type: "array", items: %{type: "object"} = items}, path),
      do: properties_of(items, path <> "[]")

    defp descend(%{type: "object"} = spec, path), do: properties_of(spec, path)
    defp descend(_spec, _path), do: []

    # The same walk, but yielding each object schema itself rather than its
    # properties — `required` lives on the schema, not on the property.
    defp all_schemas do
      Enum.flat_map(Definitions.all(), fn %{name: tool, parameters: schema} ->
        Enum.map(schemas_of(schema), fn {path, spec} -> {tool, path, spec} end)
      end)
    end

    defp schemas_of(schema, prefix \\ "") do
      nested =
        schema
        |> Map.get(:properties, %{})
        |> Enum.flat_map(fn {name, spec} ->
          descend_schema(spec, "#{prefix}.#{name}")
        end)

      [{prefix, schema} | nested]
    end

    defp descend_schema(%{type: "array", items: %{type: "object"} = items}, path),
      do: schemas_of(items, path <> "[]")

    defp descend_schema(%{type: "object"} = spec, path), do: schemas_of(spec, path)
    defp descend_schema(_spec, _path), do: []
  end

  describe "to_anthropic_tools/0" do
    test "returns tools in Anthropic API format" do
      tools = Definitions.to_anthropic_tools()

      for tool <- tools do
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :description)
        assert Map.has_key?(tool, :input_schema)
        # Anthropic uses input_schema, not parameters
        refute Map.has_key?(tool, :parameters)
      end
    end

    test "input_schema matches parameters from all/0" do
      all_tools = Definitions.all() |> Map.new(&{&1.name, &1})
      api_tools = Definitions.to_anthropic_tools() |> Map.new(&{&1.name, &1})

      for {name, api_tool} <- api_tools do
        assert api_tool.input_schema == all_tools[name].parameters
      end
    end
  end
end
