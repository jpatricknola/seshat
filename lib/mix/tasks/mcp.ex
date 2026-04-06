defmodule Mix.Tasks.Mcp do
  @moduledoc """
  Starts the Seshat MCP server over stdio.

  This is intended to be launched by Claude Desktop or another MCP client.
  It starts the OTP application (including OSC transport and session state)
  and then runs the MCP server over stdin/stdout.

  ## Usage

      mix mcp

  ## Claude Desktop Configuration

  Add to your `claude_desktop_config.json`:

      {
        "mcpServers": {
          "seshat": {
            "command": "mix",
            "args": ["mcp"],
            "cwd": "/path/to/seshat"
          }
        }
      }
  """

  use Mix.Task

  @shortdoc "Start the Seshat MCP server (stdio transport)"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, _pid} =
      Hermes.Server.Supervisor.start_link(Seshat.MCP.Server, transport: :stdio)

    # Keep the process alive
    Process.sleep(:infinity)
  end
end
