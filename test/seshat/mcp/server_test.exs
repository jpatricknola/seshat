defmodule Seshat.MCP.ServerTest do
  @moduledoc """
  Guards two invariants of the MCP server module.

  First, that the MCP server sends exactly the shared instructions — same spirit as
  `Seshat.MCP.ToolsTest`'s parity guard: the server must not grow its own copy
  of session-level guidance. Deliberately says nothing about what the text
  *is* — that is prose, edited in `Seshat.Instructions` alone.

  Second, that an invalid `tools/call` for a *known* tool comes back as a tool
  result carrying `Seshat.Tools.Validation`'s message rather than a JSON-RPC
  `-32602` a client swallows. `handle_request/2` is a plain function — request
  map in, reply tuple out — so the whole rejection channel is testable purely.
  These cases double as the Anubis-upgrade tripwire: if a future version
  changes the error reason, the injected-default mechanics, or
  `Handlers.handle/3`, they fail loudly instead of the feature silently
  reverting to protocol errors.
  """

  # Not async: the valid-call case binds the fixed test OSC ports, like every
  # other wire-reaching module.
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Seshat.MCP.Server

  defp call(name, arguments) do
    Server.handle_request(
      %{
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      %Frame{}
    )
  end

  defp rejection_text(reply) do
    assert {:reply, %{"isError" => true, "content" => [%{"text" => text}]}, _frame} = reply
    text
  end

  describe "server_instructions/0" do
    test "sends the shared instructions verbatim" do
      assert Server.server_instructions() == Seshat.Instructions.text()
    end

    test "is a public zero-arity function, which is what Anubis calls" do
      Code.ensure_loaded!(Server)
      assert function_exported?(Server, :server_instructions, 0)
    end
  end

  describe "invalid tools/call rejections" do
    test "the seam is real: Anubis itself still rejects these calls before the component" do
      # Without this, every case below could pass through the component's own
      # `Validation` call and the interception could be gone unnoticed.
      request = %{
        "method" => "tools/call",
        "params" => %{"name" => "set_track_pan", "arguments" => %{"track" => 0, "value" => 2.0}}
      }

      assert {:error, %Anubis.MCP.Error{reason: :invalid_params}, _frame} =
               Anubis.Server.Handlers.handle(request, Server, %Frame{})
    end

    test "an out-of-range number names the bound, the value and the parameter's own description" do
      text = rejection_text(call("set_track_pan", %{"track" => 0, "value" => 2.0}))

      assert text =~ "Invalid parameters for set_track_pan"
      assert text =~ "must be at most 1.0"
      assert text =~ "(got 2.0)"
      assert text =~ "-1.0 = full left"

      # Peri's internals must be gone, not merely wrapped.
      refute text =~ "{:float,"
    end

    test "a bad value inside a nested array names its index and field" do
      notes = [
        %{"pitch" => 60, "start_beat" => 0.0, "duration" => 1.0, "velocity" => 200},
        %{"pitch" => 64, "start_beat" => 1.0, "duration" => 1.0, "velocity" => 100}
      ]

      text = rejection_text(call("write_midi_notes", %{"track" => 0, "notes" => notes}))

      assert text =~ "notes[0].velocity"
      assert text =~ "127"
    end

    test "a missing required parameter says so" do
      text = rejection_text(call("set_track_pan", %{"value" => 0.5}))

      assert text =~ "track: required but missing"
      assert text =~ "0-indexed track number"
    end

    test "a string where an integer belongs is named as a type error" do
      text = rejection_text(call("set_track_pan", %{"track" => "zero", "value" => 0.0}))

      assert text =~ "track: must be an integer (got \"zero\")"
    end

    test "an absent arguments key is treated as empty arguments" do
      reply =
        Server.handle_request(
          %{"method" => "tools/call", "params" => %{"name" => "set_track_pan"}},
          %Frame{}
        )

      text = rejection_text(reply)

      assert text =~ "track: required but missing"
      assert text =~ "value: required but missing"
    end

    test "non-map arguments fall back to Peri's own text, framed as a tool result" do
      text = rejection_text(call("set_track_pan", ["track", 0]))

      assert text =~ "Invalid parameters for set_track_pan — nothing was sent to Ableton:"
      assert String.contains?(text, "\n- ")
    end

    test "an unknown tool keeps its protocol error" do
      assert {:error, %Anubis.MCP.Error{reason: :invalid_params} = error, _frame} =
               call("no_such_tool", %{"track" => 0})

      assert error.data[:message] =~ "Tool not found"
    end
  end

  describe "requests the interception must not touch" do
    test "a valid call reaches the handler and sends OSC" do
      sink = start_supervised!({Seshat.Test.OSCSink, forward_to: self()})

      start_supervised!(
        {Seshat.OSC.Transport, send_port: Seshat.Test.OSCSink.port(sink), reply_port: 0}
      )

      assert {:reply, %{"isError" => false}, _frame} = call("set_metronome", %{"enabled" => true})

      assert_receive {:osc_out, "/live/song/set/metronome", [1]}
    end

    test "tools/list still answers through the generated Anubis default" do
      assert {:reply, %{"tools" => tools}, _frame} =
               Server.handle_request(%{"method" => "tools/list", "params" => %{}}, %Frame{})

      assert length(tools) == length(Seshat.Tools.Definitions.all())

      pan = Enum.find(tools, &(&1.name == "set_track_pan"))
      value = pan.input_schema["properties"]["value"]

      assert value["type"] == "number"
      assert value["minimum"] == -1.0
      assert value["maximum"] == 1.0
      refute Map.has_key?(value, "oneOf")
    end
  end
end
