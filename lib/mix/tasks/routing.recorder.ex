defmodule Mix.Tasks.Routing.Recorder do
  @shortdoc "Serves one routing-eval MCP session from a surface snapshot"

  @moduledoc """
  The record-only MCP server a routing trial talks to.

      mix routing.recorder --surface <path> --fixture <name-or-path> --trace <path>

  Not meant to be run by hand: `mix routing.eval` writes a `--mcp-config` naming
  `priv/routing_eval/bin/recorder`, and Claude Code spawns one of these per
  trial. It serves the surface snapshot verbatim, answers calls from the fixture,
  writes every call to the trace file, and exits when the client closes stdin.

  `app.config` only — never `app.start`. This process must not bind AbletonOSC's
  reply port: a routing eval is expected to run while the real Seshat is up.
  """

  use Mix.Task

  alias Seshat.Eval.Fixture
  alias Seshat.Eval.Recorder
  alias Seshat.Eval.Surface

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [surface: :string, fixture: :string, trace: :string])

    # Before anything else: `app.config` is what pulls in the compiled modules,
    # and it must not be `app.start` — a routing eval is expected to run while
    # the real Seshat holds AbletonOSC's reply port.
    Mix.Task.run("app.config")

    surface = Surface.load!(fetch!(opts, :surface))
    fixture = load_fixture(fetch!(opts, :fixture))
    trace = fetch!(opts, :trace)

    surface
    |> Recorder.new(fixture)
    |> Recorder.Stdio.serve(trace)
  end

  defp load_fixture(name) do
    if String.ends_with?(name, ".json") do
      name |> File.read!() |> Jason.decode!() |> Fixture.from_map!(Path.basename(name, ".json"))
    else
      Fixture.load!(name)
    end
  end

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Mix.raise("mix routing.recorder requires --#{key}")
    end
  end
end
