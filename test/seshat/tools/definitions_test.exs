defmodule Seshat.Tools.DefinitionsTest do
  use ExUnit.Case, async: true

  alias Seshat.Tools.Definitions

  describe "all/0" do
    test "returns a list of tool definitions" do
      tools = Definitions.all()
      assert is_list(tools)
      assert length(tools) == 67
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
        set_return_track_volume set_return_track_pan
        set_return_track_mute set_return_track_solo
        set_master_volume set_master_pan set_cue_volume
        record_clip stop_recording capture_midi
        get_clip_properties set_clip_properties quantize_clip
        get_audio_outputs set_audio_output
      )

      names = Enum.map(Definitions.all(), & &1.name)

      for tool <- expected do
        assert tool in names, "missing tool: #{tool}"
      end
    end

    test "get_session_state is one verification read after a batch, not a retry loop" do
      tool = Enum.find(Definitions.all(), &(&1.name == "get_session_state"))

      assert tool.description =~ "call this once after the whole batch"
      assert tool.description =~ "Do not automatically retry"

      assert tool.parameters.properties["refresh"].description =~
               "never as an automatic follow-up"
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
          name in @index_properties,
          # `set_audio_output.device` borrows the name for a display string, not
          # an index into a Live collection. The hazard being pinned here is
          # Python's negative indexing, which only an integer can reach.
          spec[:type] != "string" do
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

  # `Seshat.Tools.Handlers.call/2` makes one tool call exactly one Ableton undo
  # step. That is a wire-level fact the model cannot observe, and Seshat never
  # sees the user's original prompt — only the individual MCP calls — so nothing
  # server-side can reconstruct "that request" from a burst of them. The tool
  # description is therefore the *only* place the repeated-call rule can live,
  # and losing a sentence of it silently degrades "undo that" back to reverting
  # one arbitrary fragment. These pin the load-bearing clauses; the exact wording
  # is free to change around them.
  describe "the undo/redo prompt contract" do
    test "undo says a step is one tool call, not one user message" do
      description = tool("undo").description

      assert description =~ "exactly one Ableton undo step"
      assert description =~ "not each user message"
      assert description =~ "write_midi_notes is still one step"
    end

    test "undo instructs one call per mutating call of a multi-call request" do
      description = tool("undo").description

      assert description =~ "call undo once for every call that changed Live"
      assert description =~ "newest first"
      assert description =~ "do not count read-only"
    end

    # Live's history is a plain last-in-first-out stack with no API for naming,
    # skipping or deleting an older entry, so undoing "through" later work means
    # destroying it. The description has to route that case elsewhere.
    test "undo routes an older reversible action to its domain tool instead" do
      description = tool("undo").description

      assert description =~ "top of Live's undo history"
      assert description =~ "use the relevant domain tool with the prior value"
      assert description =~ "never call undo through unrelated later work"
    end

    # The one non-invertible case worth naming: quantizing again does not restore
    # the original timing, so there is no domain-tool escape hatch here.
    test "undo names quantize_clip as having no exact inverse" do
      assert tool("undo").description =~
               "quantize_clip cannot restore the original note timing by quantizing again"
    end

    test "redo carries the symmetric repeated-call rule" do
      description = tool("redo").description

      assert description =~ "exactly one undone Ableton step"
      assert description =~ "call redo once per step that was undone"
      assert description =~ "in the original order"
    end

    # Neither address replies, so the handler's reply can only ever confirm the
    # request. Without these sentences the model reads "requested" as "done" and
    # keeps calling past a refusal — which is the failure the guard exists to
    # surface, wasted at the last step.
    for name <- ["undo", "redo"] do
      test "#{name} says the reply confirms the request, not that history moved" do
        description = tool(unquote(name)).description

        assert description =~ "confirms the request was sent, not that Live's history moved"
        assert description =~ "Ableton does not acknowledge #{unquote(name)}"
      end

      test "#{name} stops rather than retrying when Live reports no step available" do
        description = tool(unquote(name)).description

        assert description =~ "no #{unquote(name)} step available"
        assert description =~ "stop calling #{unquote(name)} and tell the user"
        assert description =~ "do not retry unless history has changed"
      end

      test "#{name} verifies once after a batch, not after each call" do
        assert tool(unquote(name)).description =~
                 "Verify a batch once at the end with get_session_state, never after each call"
      end

      # The AX-backed audio-output change is not in Live's history at all, so
      # counting it would send the model one undo too many — reverting a real
      # edit the user never asked to lose.
      test "#{name} excludes set_audio_output from the counted steps" do
        description = tool(unquote(name)).description

        assert description =~ "set_audio_output"
        assert description =~ "outside Live's undo history"
      end
    end

    test "undo routes an audio-output change back through its own tool" do
      description = tool("undo").description

      assert description =~ "never count it as a step"
      assert description =~ "reverse it by calling set_audio_output with the previous device"
    end

    test "undo now scopes 'one step per call' to changes in the Live Set" do
      assert tool("undo").description =~ "changes the Live Set creates one step"
    end

    defp tool(name) do
      Enum.find(Definitions.all(), &(&1.name == name)) || flunk("no #{name} tool defined")
    end
  end

  describe "the audio-output tools" do
    test "get_audio_outputs teaches the model to resolve before setting" do
      description = tool("get_audio_outputs").description

      assert description =~ "device names are machine-specific"
      assert description =~ "Resolve the user's wording to one exact returned name"
      # Latency is a user-visible acceptance criterion, and two round trips in
      # one request is the only way it is met — the model must not go back to
      # the user between the read and the set.
      assert description =~ "call set_audio_output in the same request"
      assert description =~ "mix ax.install"
    end

    test "set_audio_output demands an exact name and forbids inventing one" do
      description = tool("set_audio_output").description

      assert description =~ "exact name returned by get_audio_outputs"
      assert description =~ "never invent a device"
      assert description =~ "Use System Device"
      assert description =~ "reads Live's resulting value back"
      assert description =~ "outside Live's undo history"
    end

    test "set_audio_output takes one required string device" do
      tool = tool("set_audio_output")

      assert tool.parameters.required == ["device"]
      assert tool.parameters.properties["device"].type == "string"
      assert tool.parameters.properties["device"].description =~ "Exact display name"
    end

    test "get_audio_outputs takes no parameters" do
      assert tool("get_audio_outputs").parameters == %{
               type: "object",
               properties: %{},
               required: []
             }
    end
  end

  describe "unstepped_names/0" do
    # The undo-step opt-out is what lets a tool dispatch without touching the
    # OSC wire at all. Pinning the exact set is the tripwire: a tool that grows
    # `undo_step: false` for convenience — or a second AX path added quietly —
    # fails here rather than silently escaping Live's undo grouping.
    test "exactly the two Accessibility-backed tools opt out of the undo step" do
      assert Enum.sort(Definitions.unstepped_names()) == ["get_audio_outputs", "set_audio_output"]
    end

    test "every other tool is undo-stepped by default, without saying so" do
      stepped = Definitions.all() |> Enum.reject(&(&1.name in Definitions.unstepped_names()))

      for tool <- stepped do
        refute Map.has_key?(tool, :undo_step),
               "#{tool.name} declares undo_step; the default is the whole point"
      end
    end
  end
end
