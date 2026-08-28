defmodule Seshat.Eval.Client do
  @moduledoc """
  Builds the headless-client invocation for one trial: the MCP config the client
  reads, and the executable, argv and environment it is launched with.

  Pure — it starts nothing. Executing the invocation is
  `Mix.Tasks.Routing.Eval.Runner`'s job, and it lives under `lib/mix/tasks/`
  because Seshat's standing invariant is that `Seshat.AX.Client` is the only
  module under `lib/seshat/` allowed to start a process
  (`test/seshat/ax/client_test.exs` greps for it). Splitting the module this way
  keeps the invariant intact *and* keeps the flag list testable without ever
  spawning the CLI.

  ## The flags are the contract

  Every one of them was measured on 2026-08-28 against Claude Code 2.1.220:

    * `--setting-sources ""` is **mandatory**. Without it the run inherits the
      developer's own settings — on this machine a `SessionStart` hook that
      rewrites the model's register fired inside the eval.
    * `--tools ""` plus `--strict-mcp-config` plus an `--allowedTools` glob
      leaves exactly the recorder's tools visible and auto-approved, with no
      permission prompts and no built-ins to fall back on.
    * `--mcp-config` names a file, never an inline blob, and the file names the
      committed wrapper by absolute path.
    * `ANTHROPIC_API_KEY` is stripped so the run uses subscription auth. The
      stream's `apiKeySource` is checked afterwards
      (`Seshat.Eval.Stream.void_reason/2`) rather than trusted.
    * The working directory is a fresh temp directory, never the repo: the CLI
      auto-discovers `CLAUDE.md`, and Seshat's own is 300 lines about how Seshat
      is built.

  ## The lane

  `system_prompt/0` is the whole system prompt. This is the *surface-contract*
  lane: everything else the model knows about Seshat has to arrive through the
  recorder — the snapshot's `instructions` and tool descriptions — so a
  base/head difference is a difference in the contract and nothing else. A
  client-realism lane (Claude Code's own default prompt) is deliberately out of
  scope for this slice.
  """

  alias Seshat.Eval.Recorder

  @system_prompt "You are Seshat, an assistant that controls the user's Ableton Live set " <>
                   "through the tools provided. Carry out the request with the tools, then " <>
                   "reply in one or two sentences."

  @default_command ["claude"]

  @doc "The fixed lane prompt every trial runs under."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc "A short stable hash of the lane prompt, for the report header."
  @spec system_prompt_hash() :: String.t()
  def system_prompt_hash do
    :sha256
    |> :crypto.hash(@system_prompt)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @doc """
  The command the CLI is launched as: executable plus any argv prefix.

  Configurable so `mix test` can substitute a capture-replay script — the real
  CLI is never started by the suite.
  """
  @spec command() :: [String.t()]
  def command, do: Application.get_env(:seshat, :routing_eval_command, @default_command)

  @doc """
  The `--mcp-config` contents naming the recorder for one trial.

  `recorder_path` must be the committed wrapper's absolute path, resolved by the
  caller from `File.cwd!()` — **never** `Application.app_dir/2`, which in dev
  points at `_build/dev/lib/seshat/priv`, a symlink whose parent chain is not
  the repository.
  """
  @spec mcp_config(keyword()) :: map()
  def mcp_config(opts) do
    %{
      "mcpServers" => %{
        Recorder.server_name() => %{
          "type" => "stdio",
          "command" => Keyword.fetch!(opts, :recorder_path),
          "args" => [
            "--surface",
            Keyword.fetch!(opts, :surface_path),
            "--fixture",
            Keyword.fetch!(opts, :fixture_path),
            "--trace",
            Keyword.fetch!(opts, :trace_path)
          ]
        }
      }
    }
  end

  @doc """
  The full invocation: `%{executable: …, argv: […], env: […], cwd: …}`.

  `env` is in the shape the Erlang port API expects — a list of
  `{charlist, charlist | false}` — where `false` unsets the variable. (Named
  indirectly on purpose: `Seshat.AX.ClientTest` greps `lib/**/*.ex` for the
  process-starting functions by literal name, and this module must stay off
  that list. It builds the invocation; `Mix.Tasks.Routing.Eval.Runner` runs
  it.)
  """
  @spec invocation(keyword()) :: map()
  def invocation(opts) do
    [executable | prefix] = command()

    argv =
      prefix ++
        [
          "-p",
          Keyword.fetch!(opts, :prompt),
          "--output-format",
          "stream-json",
          "--verbose",
          "--model",
          Keyword.fetch!(opts, :model),
          "--setting-sources",
          "",
          "--system-prompt",
          system_prompt(),
          "--tools",
          "",
          "--mcp-config",
          Keyword.fetch!(opts, :config_path),
          "--strict-mcp-config",
          "--allowedTools",
          Seshat.Eval.Stream.tool_prefix() <> "*",
          "--disable-slash-commands",
          "--no-session-persistence"
        ]

    %{
      executable: executable,
      argv: argv,
      env: [{~c"ANTHROPIC_API_KEY", false}],
      cwd: Keyword.fetch!(opts, :cwd)
    }
  end
end
