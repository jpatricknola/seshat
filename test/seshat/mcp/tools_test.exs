defmodule Seshat.MCP.ToolsTest do
  @moduledoc """
  Guards the invariant that every definition is exposed over MCP.

  Before these were generated, the MCP server listed components by hand and had
  drifted to 7 of 32 tools.
  """

  use ExUnit.Case, async: true

  alias Seshat.MCP.Tools
  alias Seshat.MCP.Schema
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

    test "published schemas exactly match the definitions" do
      by_name = Map.new(Definitions.all(), &{&1.name, &1})

      for component <- Seshat.MCP.Server.__components__(:tool) do
        expected = Schema.to_json_schema(by_name[component.name].parameters)

        assert component.input_schema == expected,
               "published schema drift for #{component.name}"
      end
    end

    # The drift test above pins the published schema against `Definitions`;
    # this pins `Definitions` against being under-specified in the first place.
    # A property declaring only a description publishes typeless, Peri falls
    # back to `:any`, and clients that rely on a top-level discriminator may
    # serialise the value incorrectly. Nested properties are walked because
    # numeric note fields inside write_midi_notes' array had the same typeless
    # `oneOf` shape as pan.
    test "every published property declares a type, nested ones included" do
      for component <- Seshat.MCP.Server.__components__(:tool),
          {path, spec} <- published_properties(component.input_schema, component.name) do
        assert Map.has_key?(spec, "type"), "#{path} publishes no type"
      end
    end
  end

  defp published_properties(%{"properties" => properties}, path) do
    Enum.flat_map(properties, fn {name, spec} ->
      [{"#{path}.#{name}", spec} | published_properties(spec, "#{path}.#{name}")]
    end)
  end

  defp published_properties(%{"items" => items}, path),
    do: published_properties(items, path <> "[]")

  defp published_properties(_spec, _path), do: []

  describe "input validation" do
    defp validate(tool_name, params) do
      Seshat.MCP.Server.__components__(:tool)
      |> Enum.find(&(&1.name == tool_name))
      |> then(& &1.validate_input.(params))
    end

    test "accepts integers where the schema says number" do
      # Models routinely emit `1` rather than `1.0`; Peri's :float alone
      # would reject it.
      assert {:ok, _} = validate("set_mixer", %{"track" => 0, "pan" => 1})
      assert {:ok, _} = validate("set_mixer", %{"track" => 0, "pan" => -0.5})

      assert {:ok, _} =
               validate("set_device_parameter", %{
                 "track" => 0,
                 "device" => 0,
                 "parameter" => 1,
                 "value" => 1
               })
    end

    test "rejects missing required params" do
      assert {:error, _} = validate("set_scene_name", %{"scene" => 0})
    end

    test "enforces enums" do
      assert {:ok, _} = validate("create_track", %{"track_type" => "midi", "name" => "Drums"})
      assert {:ok, _} = validate("create_track", %{"track_type" => "return", "name" => "Verb"})
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
      assert {:error, _} = validate("set_mixer", %{"track" => 0, "pan" => 2.0})
      assert {:error, _} = validate("set_mixer", %{"track" => 0, "pan" => -1.5})
      assert {:ok, _} = validate("set_mixer", %{"track" => 0, "pan" => 1.0})
    end

    test "enforces declared ranges on integers" do
      assert {:error, _} = validate("set_mixer", %{"track" => -1, "pan" => 0.0})
    end

    test "a non-numeric value on a bounded number errors rather than crashing" do
      assert {:error, _} = validate("set_mixer", %{"track" => 0, "pan" => "loud"})
    end

    # `target` is the first *optional* enum shared across six tools, so a
    # converter that dropped optionality would break all six at once, and one
    # that dropped the enum would let "send" through to a do_call clause that
    # doesn't exist. Optional enums already exist elsewhere
    # (set_clip_properties' launch_mode / warp_mode) — this is the regression
    # assertion for the six schemas this change touched, not new converter
    # behaviour.
    test "the device tools' optional target enum is enforced at the wire" do
      params = %{"track" => 0, "device" => 0}

      assert {:ok, _} = validate("get_device_parameters", params)
      assert {:ok, _} = validate("get_device_parameters", Map.put(params, "target", "return"))
      assert {:ok, _} = validate("get_device_parameters", Map.put(params, "target", "master"))
      assert {:error, _} = validate("get_device_parameters", Map.put(params, "target", "send"))
    end

    # `set_mixer` is the first mutating tool with nothing required, which is
    # what makes `required: []` worth pinning at the wire rather than only in
    # `Definitions`: a converter that emitted no `required` key at all, or that
    # invented one, would be invisible everywhere else.
    test "set_mixer advertises its own four-value target and requires nothing" do
      component = Enum.find(Seshat.MCP.Server.__components__(:tool), &(&1.name == "set_mixer"))

      assert component.input_schema["properties"]["target"]["enum"] ==
               ["track", "return", "master", "cue"]

      assert Map.get(component.input_schema, "required", []) == []

      assert {:ok, _} = validate("set_mixer", %{"target" => "master", "volume" => 0.85})
      assert {:error, _} = validate("set_mixer", %{"target" => "aux", "volume" => 0.85})
    end

    test "every device tool advertises the same target enum" do
      for tool <- ~w(load_device get_track_devices get_device_parameters
                     set_device_parameter delete_device bypass_device) do
        component = Enum.find(Seshat.MCP.Server.__components__(:tool), &(&1.name == tool))
        target = component.input_schema["properties"]["target"]

        assert target["enum"] == ["return", "master"], "#{tool} advertises #{inspect(target)}"
        refute tool in Map.get(component.input_schema, "required", [])
      end
    end
  end

  describe "advertised input schema" do
    # Runtime Peri validation does not prove the encoder kept the bounds —
    # they are separate code paths in Peri, and the wire advertisement is the
    # whole deliverable: a client that never sees `minimum`/`maximum` cannot
    # steer the model away from an out-of-range call in the first place.
    test "a bounded number has a top-level type and range" do
      component =
        Enum.find(Seshat.MCP.Server.__components__(:tool), &(&1.name == "set_mixer"))

      value = component.input_schema["properties"]["pan"]

      assert value["type"] == "number"
      assert value["minimum"] == -1.0
      assert value["maximum"] == 1.0
      assert value["description"] =~ "hard left"
      refute Map.has_key?(value, "oneOf")
    end

    test "a bounded integer carries its minimum" do
      component =
        Enum.find(Seshat.MCP.Server.__components__(:tool), &(&1.name == "set_mixer"))

      assert %{"type" => "integer", "minimum" => 0} =
               Map.take(component.input_schema["properties"]["track"], ["type", "minimum"])
    end

    test "an unbounded number still has a top-level type" do
      component =
        Enum.find(Seshat.MCP.Server.__components__(:tool), &(&1.name == "set_device_parameter"))

      # set_device_parameter.value is deliberately unbounded — its legal range
      # is per-parameter, reported by get_device_parameters.
      value = component.input_schema["properties"]["value"]

      assert value["type"] == "number"
      refute Map.has_key?(value, "minimum")
      refute Map.has_key?(value, "maximum")
      refute Map.has_key?(value, "oneOf")
    end
  end
end
