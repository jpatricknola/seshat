defmodule Seshat.Agent do
  @moduledoc """
  Agentic tool-use loop for API key mode.

  Sends user input to the Anthropic API with tool definitions.
  When Claude responds with tool calls, executes them via the shared
  Handlers module and feeds results back. Loops until Claude responds
  with text (end_turn) or a safety limit is reached.
  """

  alias Seshat.Tools.{Definitions, Handlers}

  require Logger

  @max_iterations 10

  @system_prompt """
  You are an assistant for Ableton Live. You control the DAW using the tools provided.

  Rules:
  - Track indices are 0-based. When the user says "track 1", that's index 0.
  - Use get_session_state to check current values before making relative adjustments like "a bit more" or "turn it down".
  - For ambiguous requests, use your best judgment rather than asking for clarification.
  - You can call multiple tools to fulfill a single request.
  - When the user refers to a track by name (e.g. "the drums"), use get_session_state to find its index.
  """

  @type result :: %{
          response: String.t() | nil,
          commands_executed: [map()]
        }

  @spec run(String.t(), list()) :: {:ok, result()} | {:error, String.t()}
  def run(input, history \\ []) do
    api_key = Application.fetch_env!(:seshat, :anthropic_api_key)
    tools = Definitions.to_anthropic_tools()

    messages = history ++ [%{role: "user", content: input}]

    loop(api_key, tools, messages, [], 0)
  end

  defp loop(_api_key, _tools, _messages, _executed, iteration)
       when iteration >= @max_iterations do
    {:error, "Reached maximum tool-use iterations (#{@max_iterations})"}
  end

  defp loop(api_key, tools, messages, executed, iteration) do
    case call_api(api_key, messages, tools) do
      {:ok, %{status: 200, body: body}} ->
        handle_response(api_key, tools, messages, body, executed, iteration)

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error #{status}: #{inspect(body)}")
        {:error, "API error (HTTP #{status})"}

      {:error, reason} ->
        Logger.error("Anthropic API request failed: #{inspect(reason)}")
        {:error, "API request failed: #{inspect(reason)}"}
    end
  end

  defp handle_response(api_key, tools, messages, body, executed, iteration) do
    stop_reason = body["stop_reason"]
    content = body["content"] || []

    case stop_reason do
      "end_turn" ->
        text = extract_text(content)
        {:ok, %{response: text, commands_executed: executed, messages: messages ++ [assistant_message(content)]}}

      "tool_use" ->
        {tool_results, newly_executed} = execute_tool_calls(content)

        updated_messages =
          messages ++
            [assistant_message(content)] ++
            [%{role: "user", content: tool_results}]

        loop(api_key, tools, updated_messages, executed ++ newly_executed, iteration + 1)

      other ->
        text = extract_text(content)
        {:ok, %{response: text || "Unexpected stop reason: #{other}", commands_executed: executed, messages: messages}}
    end
  end

  defp execute_tool_calls(content) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map_reduce([], fn tool_call, acc ->
      name = tool_call["name"]
      input = tool_call["input"]
      id = tool_call["id"]

      Logger.info("Tool call: #{name}(#{inspect(input)})")

      {result_text, is_error} =
        case Handlers.call(name, input) do
          {:ok, msg} -> {msg, false}
          {:error, reason} -> {reason, true}
        end

      tool_result = %{
        type: "tool_result",
        tool_use_id: id,
        content: result_text,
        is_error: is_error
      }

      executed_entry = %{tool: name, input: input, result: result_text, error: is_error}

      {tool_result, [executed_entry | acc]}
    end)
  end

  defp extract_text(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp assistant_message(content), do: %{role: "assistant", content: content}

  defp call_api(api_key, messages, tools) do
    extra_opts = Application.get_env(:seshat, :agent_req_options, [])

    opts =
      [
        url: "https://api.anthropic.com/v1/messages",
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"}
        ],
        json: %{
          model: "claude-sonnet-4-5-20250514",
          max_tokens: 1024,
          system: @system_prompt,
          tools: tools,
          messages: messages
        }
      ]
      |> Keyword.merge(extra_opts)

    Req.post(opts)
  end
end
