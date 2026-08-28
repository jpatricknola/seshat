defmodule Seshat.Eval.Recorder do
  @moduledoc """
  A record-only MCP server: it publishes a frozen `Seshat.Eval.Surface`, answers
  calls from a `Seshat.Eval.Fixture`, and writes down every call it was asked to
  make.

  This is the whole reason a base/head routing comparison is possible. Live
  cannot be in the loop — only one process can bind AbletonOSC's reply port, and
  a real Set would drift between trials — so the model under test talks to this
  instead. Nothing here sends a datagram, and nothing here reads the live
  session mirror; `Seshat.Eval.NoOSCTest` greps the whole eval tree to keep it
  that way.

  The module is pure. `handle/2` takes a decoded JSON-RPC request and returns
  `{reply | nil, state}`; `Seshat.Eval.Recorder.Stdio` owns stdin, stdout and
  the trace file. That split is what lets the entire protocol be tested as a
  list of maps.

  ## What a call is judged on before it is answered

  Arguments are checked against **that surface's own published schema**
  (`Seshat.Eval.SchemaCheck`), not against the current `Definitions`, and a
  violation comes back as an `isError` tool result worded the way production
  words it. The trace records `schema_valid` separately from `is_error` so the
  report can say "the model's first call was malformed" without inferring it
  from reply text.
  """

  alias Seshat.Eval.Fixture
  alias Seshat.Eval.SchemaCheck
  alias Seshat.Eval.Surface

  @server_name "seshat_eval"
  @server_version "0.1.0"
  @default_protocol "2025-06-18"

  @enforce_keys [:surface, :fixture]
  defstruct [:surface, :fixture, seq: 0, trace: []]

  @type t :: %__MODULE__{
          surface: Surface.t(),
          fixture: Fixture.t(),
          seq: non_neg_integer(),
          trace: [map()]
        }

  @doc "The MCP server name the client config must use; tool names carry it."
  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @doc "A fresh recorder over one surface and one fixture."
  @spec new(Surface.t(), Fixture.t()) :: t()
  def new(%Surface{} = surface, %Fixture{} = fixture) do
    %__MODULE__{surface: surface, fixture: fixture}
  end

  @doc """
  Handles one decoded JSON-RPC request.

  Returns `{nil, state}` for a notification — nothing goes back on stdout, which
  is what "notification" means on the wire.
  """
  @spec handle(map(), t()) :: {map() | nil, t()}
  def handle(%{"method" => "initialize"} = request, state) do
    protocol = get_in(request, ["params", "protocolVersion"]) || @default_protocol

    result =
      %{
        "protocolVersion" => protocol,
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => @server_name, "version" => @server_version}
      }
      |> put_instructions(state.surface.instructions)

    {reply(request, result), state}
  end

  def handle(%{"method" => "notifications/" <> _}, state), do: {nil, state}

  def handle(%{"method" => "ping"} = request, state), do: {reply(request, %{}), state}

  def handle(%{"method" => "tools/list"} = request, state) do
    {reply(request, %{"tools" => state.surface.tools}), state}
  end

  def handle(%{"method" => "tools/call"} = request, state) do
    params = request["params"] || %{}
    name = params["name"]
    arguments = params["arguments"] || %{}

    {text, is_error?, schema_valid?} = run(state, name, arguments)

    entry = %{
      "seq" => state.seq + 1,
      "name" => name,
      "arguments" => arguments,
      "is_error" => is_error?,
      "schema_valid" => schema_valid?,
      "kind" => state.surface |> Surface.kind(name) |> Atom.to_string(),
      "result_preview" => preview(text)
    }

    state = %{state | seq: state.seq + 1, trace: state.trace ++ [entry]}

    result = %{
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => is_error?
    }

    {reply(request, result), state}
  end

  def handle(%{"method" => method} = request, state) do
    {error_reply(request, -32_601, "Method not found: #{method}"), state}
  end

  def handle(request, state) do
    {error_reply(request, -32_600, "Invalid request"), state}
  end

  # An unknown tool name is a tool result, not a protocol error: the model has to
  # be able to read it and pick something that exists. That is also the single
  # most interesting failure this harness can record — a model reaching for a
  # name the surface under test removed.
  defp run(state, name, arguments) do
    case Surface.tool(state.surface, name) do
      nil ->
        {"Unknown tool: #{name}. Only the tools listed for this server exist.", true, false}

      tool ->
        case SchemaCheck.violations(tool["inputSchema"] || %{}, arguments) do
          [] ->
            case Fixture.call(state.fixture, name, arguments) do
              {:ok, text} -> {text, false, true}
              {:error, text} -> {text, true, true}
            end

          violations ->
            {SchemaCheck.message(name, violations), true, false}
        end
    end
  end

  # Long enough to tell two replies apart in a report, short enough that a run
  # directory stays readable.
  defp preview(text) when byte_size(text) <= 300, do: text
  defp preview(text), do: binary_part(text, 0, 300) <> "…"

  defp put_instructions(result, nil), do: result
  defp put_instructions(result, ""), do: result
  defp put_instructions(result, text), do: Map.put(result, "instructions", text)

  defp reply(%{"id" => id}, result) when not is_nil(id) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp reply(_request, _result), do: nil

  defp error_reply(%{"id" => id}, code, message) when not is_nil(id) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp error_reply(_request, _code, _message), do: nil
end
