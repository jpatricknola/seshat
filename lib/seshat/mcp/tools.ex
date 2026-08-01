defmodule Seshat.MCP.Tools do
  @moduledoc """
  Generates one `Anubis.Server.Component` module per entry in
  `Seshat.Tools.Definitions`.

  `"set_track_pan"` becomes `Seshat.MCP.Tools.SetTrackPan`. Anubis derives the
  wire name back from the module name (`Macro.underscore/1` of the last
  segment), so that round trip keeps definitions and wire names in sync.
  `Seshat.MCP.ToolsTest` asserts it.

  **Do not add modules here by hand.** Add the tool to `Definitions` and a
  matching `call/2` clause to `Seshat.Tools.Handlers`; the component appears
  on the next compile. See `.claude/docs/adding-a-tool.md`.
  """

  alias Seshat.MCP.Schema
  alias Seshat.Tools.Definitions

  @doc "The generated component module implementing `tool_name`."
  @spec module_for(String.t()) :: module()
  def module_for(tool_name) when is_binary(tool_name) do
    Module.concat(__MODULE__, Macro.camelize(tool_name))
  end

  @doc "All generated component modules, in definition order."
  @spec all() :: [module()]
  def all, do: Enum.map(Definitions.all(), &module_for(&1.name))

  for tool <- Definitions.all() do
    body =
      quote do
        @moduledoc unquote(tool.description)

        use Anubis.Server.Component, type: :tool
        defoverridable input_schema: 0

        alias Anubis.Server.Response

        schema(do: unquote(Macro.escape(Schema.to_anubis(tool.parameters))))

        @impl true
        def input_schema, do: unquote(Macro.escape(Schema.to_json_schema(tool.parameters)))

        @impl true
        def execute(params, frame) do
          case Seshat.Tools.Handlers.call(unquote(tool.name), params) do
            {:ok, message} ->
              {:reply, Response.text(Response.tool(), message), frame}

            {:error, reason} ->
              {:reply, Response.error(Response.tool(), reason), frame}
          end
        end
      end

    # `module_for/1` isn't callable yet from inside its own module body.
    module = Module.concat(__MODULE__, Macro.camelize(tool.name))
    Module.create(module, body, Macro.Env.location(__ENV__))
  end
end
