defmodule Seshat.Eval.StreamTest do
  @moduledoc """
  The committed capture is the tripwire for a CLI upgrade. When Claude Code
  moves a field, these fail on the fixture — loudly, offline — instead of a live
  run silently scoring every trial at zero tool calls.
  """

  use ExUnit.Case, async: true

  alias Seshat.Eval.Stream, as: EvalStream

  @capture Path.expand("../../fixtures/routing/stream-2.1.220.jsonl", __DIR__)

  setup do
    {:ok, trial} = @capture |> File.read!() |> EvalStream.parse()

    {:ok,
     trial: trial,
     tools: trial.init |> Map.fetch!("tools") |> Enum.map(&EvalStream.strip_prefix/1)}
  end

  describe "parse/1 against the 2.1.220 capture" do
    test "reads the three calls the mixer prompt produced, with their arguments", %{trial: trial} do
      assert [first, second, third] = trial.calls

      assert first.name == "get_session_state"
      assert first.input == %{}

      assert second.name == "set_mixer"
      assert second.input == %{"target" => "master", "volume" => 0.78}

      assert third.name == "set_mixer"
      assert third.input == %{"target" => "return", "track" => 0, "mute" => true}
    end

    test "correlates each tool result to its call", %{trial: trial} do
      assert Enum.map(trial.results, & &1.tool_use_id) == Enum.map(trial.calls, & &1.id)
      assert Enum.all?(trial.results, &(&1.is_error == false))
    end

    test "keeps the init and result events and the final text", %{trial: trial} do
      assert trial.init["claude_code_version"] == "2.1.220"
      assert trial.init["model"] == "claude-sonnet-5"
      assert trial.init["apiKeySource"] == "none"
      assert trial.init["permissionMode"] == "default"
      assert trial.init["plugins"] == []
      assert trial.init["mcp_servers"] == [%{"name" => "seshat_eval", "status" => "connected"}]

      assert trial.result["subtype"] == "success"
      assert trial.result["is_error"] == false
      assert trial.result["permission_denials"] == []
      assert trial.final_text =~ "muted the Reverb return"
    end

    # Never written to disk, so a run directory can never contain them.
    test "drops thinking blocks", %{trial: trial} do
      refute Enum.any?(trial.calls, &(&1.name == nil))
      refute inspect(trial) =~ "thinking"
    end

    test "an every-turn allowed rate-limit event is not a block", %{trial: trial} do
      assert trial.rate_limits != []
      assert EvalStream.blocking_rate_limit(trial) == nil
    end

    test "a line that is not JSON fails the whole parse" do
      assert {:error, reason} = EvalStream.parse(["{\"type\":\"system\"}", "not json"])
      assert reason =~ "not a JSON object"
    end
  end

  describe "void_reason/2" do
    test "the captured run is not void", %{trial: trial, tools: tools} do
      assert EvalStream.void_reason(trial, tools) == nil
    end

    test "a hook event voids the trial", %{trial: trial, tools: tools} do
      leaked = %{trial | hook_events: [%{"type" => "system", "subtype" => "hook_started"}]}

      assert EvalStream.void_reason(leaked, tools) =~ "settings leaked"
      assert EvalStream.void_reason(leaked, tools) =~ "hook event"
    end

    test "a non-empty plugins list voids the trial", %{trial: trial, tools: tools} do
      leaked = %{trial | init: Map.put(trial.init, "plugins", [%{"name" => "register-rewriter"}])}

      assert EvalStream.void_reason(leaked, tools) =~ "plugins"
    end

    test "a missing tool voids the trial against the expected surface", %{
      trial: trial,
      tools: tools
    } do
      reason = EvalStream.void_reason(trial, ["set_mixer", "a_tool_that_never_existed"] ++ tools)

      assert reason =~ "not the surface under test"
      assert reason =~ "a_tool_that_never_existed"
    end

    test "a tool the surface does not publish voids the trial", %{trial: trial} do
      reason = EvalStream.void_reason(trial, ["get_session_state"])

      assert reason =~ "unexpected"
      assert reason =~ "set_mixer"
    end

    test "a foreign or disconnected MCP server voids the trial", %{trial: trial, tools: tools} do
      other = %{
        trial
        | init:
            Map.put(trial.init, "mcp_servers", [
              %{"name" => "seshat_eval", "status" => "connected"},
              %{"name" => "atlassian", "status" => "connected"}
            ])
      }

      assert EvalStream.void_reason(other, tools) =~ "exactly the connected recorder"
    end

    test "API-key auth voids the trial", %{trial: trial, tools: tools} do
      keyed = %{trial | init: Map.put(trial.init, "apiKeySource", "ANTHROPIC_API_KEY")}

      assert EvalStream.void_reason(keyed, tools) =~ "not the subscription"
    end

    test "a permission denial voids the trial", %{trial: trial, tools: tools} do
      denied = %{
        trial
        | result: Map.put(trial.result, "permission_denials", [%{"tool" => "Bash"}])
      }

      assert EvalStream.void_reason(denied, tools) =~ "denied a tool call"
    end

    test "a non-allowed rate-limit event voids the trial and is reported as a block", %{
      trial: trial,
      tools: tools
    } do
      limited = %{
        trial
        | rate_limits: [
            %{
              "type" => "rate_limit_event",
              "rate_limit_info" => %{"status" => "rejected", "resetsAt" => 1_787_926_800}
            }
          ]
      }

      assert EvalStream.void_reason(limited, tools) =~ "rate limited"
      assert EvalStream.blocking_rate_limit(limited)["status"] == "rejected"
    end

    test "a stream with no init or no result is void", %{tools: tools} do
      assert EvalStream.void_reason(%Seshat.Eval.Trial{}, tools) =~ "no system/init event"
    end
  end

  describe "cross_check/2" do
    test "agreeing sides pass", %{trial: trial} do
      trace = Enum.map(trial.calls, &%{"name" => &1.name})

      assert EvalStream.cross_check(trial, trace) == :ok
    end

    test "a disagreement names both sides", %{trial: trial} do
      assert {:error, reason} = EvalStream.cross_check(trial, [%{"name" => "get_session_state"}])

      assert reason =~ "disagree"
      assert reason =~ "set_mixer"
    end
  end
end
