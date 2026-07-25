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
            "command": "/bin/sh",
            "args": ["-c", "cd /path/to/seshat && exec env MIX_QUIET=1 mix mcp"]
          }
        }
      }

  `MIX_QUIET=1` keeps Mix's own output (e.g. "Compiling 3 files") off stdout,
  which must carry only JSON-RPC.
  """

  use Mix.Task

  @shortdoc "Start the Seshat MCP server (stdio transport)"

  @impl true
  def run(_args) do
    # stdio transport: stdout must carry only JSON-RPC, so all logs go to
    # stderr. The handler swap covers the pre-boot window; the env var makes
    # runtime.exs re-apply it when the Logger app installs its own handler
    # during app.start.
    System.put_env("SESHAT_MCP_STDIO", "true")
    :logger.remove_handler(:default)

    :logger.add_handler(:default, :logger_std_h, %{
      config: %{type: :standard_error},
      formatter: Logger.Formatter.new()
    })

    Mix.Task.run("app.start")

    {:ok, _pid} =
      Anubis.Server.Supervisor.start_link(Seshat.MCP.Server, transport: :stdio)

    # Keep the process alive
    Process.sleep(:infinity)
  end
end
