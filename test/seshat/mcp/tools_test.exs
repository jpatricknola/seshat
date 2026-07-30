defmodule Seshat.MCP.ToolsTest do
  @moduledoc """
  Guards the invariant that MCP mode and API-key mode expose the same tools.

  Before these were generated, the MCP server listed components by hand and had
  drifted to 7 of 32 tools.
  """

  use ExUnit.Case, async: true

  alias Seshat.MCP.Tools
  alias Seshat.Tools.Definitions

  describe "generated components" do
    test "every tool definition has a component registered on the server" do
      registered = Enum.map(Seshat.MCP.Server.__components__(:tool), & &1.name)
      defined = Enum.map(Definitions.all(), & &1.name)

      assert Enum.sort(registered) == Enum.sort(defined)
    end

    test "every component's wire name round-trips to its module" do
      for %{name: name} <- Definitions.all() do
        module = Tools.module_for(name)
        assert Code.ensure_loaded?(module), "#{name} has no generated module"

        derived = module |> Module.split() |> List.last() |> Macro.underscore()
        assert derived == name
      end
    end

    test "component descriptions come from the definitions" do
      by_name = Map.new(Definitions.all(), &{&1.name, &1})

      for component <- Seshat.MCP.Server.__components__(:tool) do
        assert component.description == by_name[component.name].description
      end
    end
  end

  describe "generated input schemas" do
    test "required fields match the definitions" do
      by_name = Map.new(Definitions.all(), &{&1.name, &1})

      for component <- Seshat.MCP.Server.__components__(:tool) do
        expected = by_name[component.name].parameters |> Map.get(:required, []) |> Enum.sort()
        actual = component.input_schema |> Map.get("required", []) |> Enum.sort()

        assert actual == expected, "required mismatch for #{component.name}"
      end
    end

    test "property names match the definitions" do
      by_name = Map.new(Definitions.all(), &{&1.name, &1})

      for component <- Seshat.MCP.Server.__components__(:tool) do
        expected =
          by_name[component.name].parameters
          |> Map.get(:properties, %{})
          |> Map.keys()
          |> Enum.sort()

        actual = component.input_schema |> Map.get("properties", %{}) |> Map.keys() |> Enum.sort()

        assert actual == expected, "properties mismatch for #{component.name}"
      end
    end
  end

  describe "input validation" do
    defp validate(tool_name, params) do
      Seshat.MCP.Server.__components__(:tool)
      |> Enum.find(&(&1.name == tool_name))
      |> then(& &1.validate_input.(params))
    end

    test "accepts integers where the schema says number" do
      # Models routinely emit `1` rather than `1.0`; Peri's :float alone
      # would reject it.
      assert {:ok, _} = validate("set_track_pan", %{"track" => 0, "value" => 1})
      assert {:ok, _} = validate("set_track_pan", %{"track" => 0, "value" => -0.5})
    end

    test "rejects missing required params" do
      assert {:error, _} = validate("set_track_pan", %{"track" => 0})
    end

    test "enforces enums" do
      assert {:ok, _} = validate("create_track", %{"track_type" => "midi", "name" => "Drums"})
      assert {:error, _} = validate("create_track", %{"track_type" => "banjo", "name" => "Drums"})
    end

    test "validates nested arrays of objects" do
      notes = [%{"pitch" => 60, "start_beat" => 0, "duration" => 1.0, "velocity" => 100}]
      assert {:ok, _} = validate("write_midi_notes", %{"track" => 0, "notes" => notes})

      bad_notes = [%{"pitch" => 999, "start_beat" => 0, "duration" => 1.0, "velocity" => 100}]
      assert {:error, _} = validate("write_midi_notes", %{"track" => 0, "notes" => bad_notes})
    end

    # Peri used to convert every `number` to an unconstrained
    # `{:either, {:float, :integer}}`, so a declared maximum of 1.0 accepted
    # 2.0 at the wire. The authoritative check is `Seshat.Tools.Validation`;
    # this is the wire agreeing with it rather than contradicting it.
    test "enforces declared ranges on numbers" do
      assert {:error, _} = validate("set_track_pan", %{"track" => 0, "value" => 2.0})
      assert {:error, _} = validate("set_track_pan", %{"track" => 0, "value" => -1.5})
      assert {:ok, _} = validate("set_track_pan", %{"track" => 0, "value" => 1.0})
    end

    test "enforces declared ranges on integers" do
      assert {:error, _} = validate("set_track_pan", %{"track" => -1, "value" => 0.0})
    end

    test "a non-numeric value on a bounded number errors rather than crashing" do
      assert {:error, _} = validate("set_track_pan", %{"track" => 0, "value" => "loud"})
    end
  end

  describe "advertised input schema" do
    # Runtime Peri validation does not prove the encoder kept the bounds —
    # they are separate code paths in Peri, and the wire advertisement is the
    # whole deliverable: a client that never sees `minimum`/`maximum` cannot
    # steer the model away from an out-of-range call in the first place.
    test "a bounded number carries its range into both oneOf branches" do
      component =
        Enum.find(Seshat.MCP.Server.__components__(:tool), &(&1.name == "set_track_pan"))

      value = component.input_schema["properties"]["value"]

      assert %{"oneOf" => branches} = value
      assert %{"type" => "number", "minimum" => -1.0, "maximum" => 1.0} in branches
      assert %{"type" => "integer", "minimum" => -1.0, "maximum" => 1.0} in branches

      # The description stays at property level, outside the oneOf.
      assert value["description"] =~ "Pan position"
    end

    test "a bounded integer carries its minimum" do
      component =
        Enum.find(Seshat.MCP.Server.__components__(:tool), &(&1.name == "set_track_pan"))

      assert %{"type" => "integer", "minimum" => 0} =
               Map.take(component.input_schema["properties"]["track"], ["type", "minimum"])
    end

    test "an unbounded number keeps its bare oneOf shape" do
      component =
        Enum.find(Seshat.MCP.Server.__components__(:tool), &(&1.name == "set_device_parameter"))

      # set_device_parameter.value is deliberately unbounded — its legal range
      # is per-parameter, reported by get_device_parameters.
      assert %{"oneOf" => branches} = component.input_schema["properties"]["value"]
      assert %{"type" => "number"} in branches
      assert %{"type" => "integer"} in branches
    end
  end
end
