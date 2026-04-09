defmodule Seshat.Tools.DefinitionsTest do
  use ExUnit.Case, async: true

  alias Seshat.Tools.Definitions

  describe "all/0" do
    test "returns a list of tool definitions" do
      tools = Definitions.all()
      assert is_list(tools)
      assert length(tools) == 32
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
        create_track create_project write_midi_notes
        delete_track duplicate_track set_track_name
        set_tempo start_playing stop_playing set_metronome set_track_arm
        undo redo
        fire_clip stop_clip delete_clip duplicate_clip set_clip_name
        fire_scene create_scene delete_scene duplicate_scene set_scene_name
        set_loop select_track select_scene remove_notes
        get_session_state
      )

      names = Enum.map(Definitions.all(), & &1.name)

      for tool <- expected do
        assert tool in names, "missing tool: #{tool}"
      end
    end
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
