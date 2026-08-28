defmodule Seshat.Eval.SchemaCheckTest do
  use ExUnit.Case, async: true

  alias Seshat.Eval.SchemaCheck

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "track" => %{"type" => "integer", "minimum" => 0, "description" => "0-indexed track"},
      "volume" => %{"type" => "number", "minimum" => 0.0, "maximum" => 1.0},
      "target" => %{"type" => "string", "enum" => ["track", "return", "master"]},
      "mute" => %{"type" => "boolean"},
      "notes" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "pitch" => %{"type" => "integer", "minimum" => 0, "maximum" => 127}
          },
          "required" => ["pitch"]
        }
      }
    },
    "required" => ["track"]
  }

  test "a well-formed call has no violations" do
    assert SchemaCheck.violations(@schema, %{"track" => 0, "volume" => 0.5}) == []
  end

  test "a missing required parameter is named" do
    assert ["- track: required but missing" <> _] = SchemaCheck.violations(@schema, %{})
  end

  test "an out-of-range number reads the way production words it" do
    assert ["- volume: must be at most 1.0 (got 2.0)"] =
             SchemaCheck.violations(@schema, %{"track" => 0, "volume" => 2.0})

    assert ["- track: must be at least 0 (got -1)" <> _] =
             SchemaCheck.violations(@schema, %{"track" => -1})
  end

  test "a value outside the enum lists what was allowed" do
    assert ["- target: must be one of \"track\", \"return\", \"master\" (got \"cue\")"] =
             SchemaCheck.violations(@schema, %{"track" => 0, "target" => "cue"})
  end

  test "a wrong type is rejected rather than coerced" do
    assert ["- track: must be an integer (got 1.5)" <> _] =
             SchemaCheck.violations(@schema, %{"track" => 1.5})

    assert ["- mute: must be a boolean (got \"yes\")"] =
             SchemaCheck.violations(@schema, %{"track" => 0, "mute" => "yes"})
  end

  test "an unknown parameter is a violation, not a silent drop" do
    assert ["- muted: unknown parameter — expected one of " <> _] =
             SchemaCheck.violations(@schema, %{"track" => 0, "muted" => true})
  end

  # The base snapshot predates `additionalProperties` in the published schema,
  # but production has always rejected unknown keys. Treating a silent schema as
  # open would hand base a tolerance it never had in Live.
  test "an object with no additionalProperties key is still closed" do
    open_schema = Map.delete(@schema, "additionalProperties")

    assert ["- muted: unknown parameter" <> _] =
             SchemaCheck.violations(open_schema, %{"track" => 0, "muted" => true})
  end

  test "additionalProperties: true opts out" do
    permissive = Map.put(@schema, "additionalProperties", true)

    assert SchemaCheck.violations(permissive, %{"track" => 0, "muted" => true}) == []
  end

  test "array items are checked by index" do
    assert ["- notes[1].pitch: must be at most 127 (got 200)"] =
             SchemaCheck.violations(@schema, %{
               "track" => 0,
               "notes" => [%{"pitch" => 60}, %{"pitch" => 200}]
             })
  end

  test "every violation is collected, not just the first" do
    violations = SchemaCheck.violations(@schema, %{"volume" => 5.0, "target" => "nope"})

    assert length(violations) == 3
  end

  test "the message names the tool and says nothing was sent" do
    message = SchemaCheck.message("set_mixer", ["- volume: must be at most 1.0 (got 2.0)"])

    assert message =~ "Invalid parameters for set_mixer — nothing was sent to Ableton:"
    assert message =~ "must be at most 1.0"
  end
end
