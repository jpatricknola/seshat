defmodule Mix.Tasks.Routing.Snapshot do
  @shortdoc "Writes the current MCP surface (instructions + tools) to a JSON snapshot"

  @moduledoc """
  Captures this checkout's model-facing MCP contract as a `Seshat.Eval.Surface`
  snapshot.

      mix routing.snapshot                       # prints to stdout
      mix routing.snapshot --out surface.json    # writes a file

  This is also the no-server way to read the tool surface: unlike
  `.claude/skills/smoke-test/scripts/mcp_call.py`, nothing has to be running and
  no OSC port is bound. `mix routing.eval` calls the same code path for its head
  surface, so what you read here is what the eval serves.

  `app.config` only — never `app.start`. Building the tool list needs the
  compiled components and nothing else, and starting the application would bind
  AbletonOSC's reply port out from under a running Seshat.
  """

  use Mix.Task

  alias Seshat.Eval.Surface

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [out: :string])

    Mix.Task.run("app.config")

    surface = Surface.current(revision())
    json = Surface.dump(surface)

    case opts[:out] do
      nil ->
        Mix.shell().info(json)

      path ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write!(path, json <> "\n")

        Mix.shell().info(
          "Wrote #{length(surface.tools)} tool(s) at revision #{surface.revision} to #{path}"
        )
    end
  end

  # A dirty checkout still gets a revision — the eval task is what refuses to run
  # against one, and printing the surface of a work in progress is legitimate.
  defp revision do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  end
end
