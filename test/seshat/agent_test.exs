defmodule Seshat.AgentTest do
  use ExUnit.Case, async: false

  alias Seshat.Agent

  setup_all do
    start_supervised!(Seshat.OSC.Transport)
    :ok
  end

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "simple tool call (end_turn after one tool)" do
    test "executes a pan command and returns response" do
      # First call: Claude responds with a tool_use
      Req.Test.expect(Seshat.Agent, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "tool_use",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "set_track_pan",
              "input" => %{"track" => 0, "value" => -1.0}
            }
          ]
        })
      end)

      # Second call: after tool result, Claude responds with text
      Req.Test.expect(Seshat.Agent, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_2",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [
            %{"type" => "text", "text" => "Done! I've panned track 1 to the left."}
          ]
        })
      end)

      assert {:ok, result} = Agent.run("pan track 1 to the left")
      assert result.response == "Done! I've panned track 1 to the left."
      assert length(result.commands_executed) == 1

      [cmd] = result.commands_executed
      assert cmd.tool == "set_track_pan"
      assert cmd.input == %{"track" => 0, "value" => -1.0}
      assert cmd.error == false
    end
  end

  describe "text-only response (no tool calls)" do
    test "returns text when Claude responds without tools" do
      Req.Test.expect(Seshat.Agent, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [
            %{"type" => "text", "text" => "I can help you with mixing. What would you like to do?"}
          ]
        })
      end)

      assert {:ok, result} = Agent.run("hello")
      assert result.response =~ "help you with mixing"
      assert result.commands_executed == []
    end
  end

  describe "multiple tool calls in one response" do
    test "executes multiple tools when Claude returns several tool_use blocks" do
      # Claude responds with two tool calls at once
      Req.Test.expect(Seshat.Agent, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "tool_use",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "set_track_mute",
              "input" => %{"track" => 0, "muted" => true}
            },
            %{
              "type" => "tool_use",
              "id" => "toolu_2",
              "name" => "set_track_mute",
              "input" => %{"track" => 1, "muted" => true}
            }
          ]
        })
      end)

      # After tool results, Claude finishes
      Req.Test.expect(Seshat.Agent, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_2",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [
            %{"type" => "text", "text" => "Muted tracks 1 and 2."}
          ]
        })
      end)

      assert {:ok, result} = Agent.run("mute tracks 1 and 2")
      assert result.response == "Muted tracks 1 and 2."
      assert length(result.commands_executed) == 2
    end
  end

  describe "multi-step tool use (query then act)" do
    test "Claude queries state then executes a command" do
      # Step 1: Claude calls get_session_state
      Req.Test.expect(Seshat.Agent, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "tool_use",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "get_session_state",
              "input" => %{}
            }
          ]
        })
      end)

      # Step 2: after seeing state, Claude pans a track
      Req.Test.expect(Seshat.Agent, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_2",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "tool_use",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_2",
              "name" => "set_track_pan",
              "input" => %{"track" => 0, "value" => 0.5}
            }
          ]
        })
      end)

      # Step 3: done
      Req.Test.expect(Seshat.Agent, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_3",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [
            %{"type" => "text", "text" => "Panned the drums slightly right."}
          ]
        })
      end)

      assert {:ok, result} = Agent.run("pan the drums slightly right")
      assert length(result.commands_executed) == 2
      assert Enum.any?(result.commands_executed, &(&1.tool == "get_session_state"))
      assert Enum.any?(result.commands_executed, &(&1.tool == "set_track_pan"))
    end
  end

  describe "API error handling" do
    test "returns error on non-200 response" do
      Req.Test.expect(Seshat.Agent, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "Invalid API key"}})
      end)

      assert {:error, msg} = Agent.run("pan track 1 left")
      assert msg =~ "API error"
      assert msg =~ "401"
    end
  end

  describe "conversation history" do
    test "passes history to subsequent calls" do
      # Build up a history from a previous interaction
      previous_messages = [
        %{role: "user", content: "pan track 1 left"},
        %{role: "assistant", content: [%{"type" => "text", "text" => "Done!"}]}
      ]

      Req.Test.expect(Seshat.Agent, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        # Verify history is included
        messages = request["messages"]
        assert length(messages) == 3
        assert Enum.at(messages, 0)["content"] == "pan track 1 left"

        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [
            %{"type" => "text", "text" => "Track 1 is already panned left."}
          ]
        })
      end)

      assert {:ok, result} = Agent.run("where is track 1 panned?", previous_messages)
      assert result.response =~ "panned left"
    end
  end
end
