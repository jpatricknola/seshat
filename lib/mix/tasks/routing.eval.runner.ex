defmodule Mix.Tasks.Routing.Eval.Runner do
  @moduledoc """
  Executes one routing trial: spawn the headless client, collect its stream,
  clean up after it.

  Despite the namespace this is **not** a Mix task — it has no `run/1`. It lives
  under `lib/mix/tasks/` on purpose: `Seshat.AX.Client` is the only module under
  `lib/seshat/` allowed to start a process, an invariant
  `test/seshat/ax/client_test.exs` greps for, and that grep deliberately exempts
  `lib/mix/tasks/`, where a human-invoked task is expected to run a subprocess.
  The decision of *what* to run is `Seshat.Eval.Client`'s and is pure; only the
  running is here.

  `mix test` never starts the real CLI: `:routing_eval_command` points the
  suite at a capture-replay script.

  ## Why the launch goes through a wrapper

  `Port.open/2` cannot redirect stdin, and the CLI waits three seconds for piped
  input when stdin is a pipe nothing writes to — which is exactly what a port
  looks like. `priv/routing_eval/bin/closed-stdin` redirects from `/dev/null`
  and `exec`s the rest of its arguments positionally. This is direct argv
  execution throughout: no `/bin/sh -c`, no interpolated command string.
  """

  alias Seshat.Eval.Client

  @default_timeout_ms 120_000

  @type result :: %{
          output: String.t(),
          exit_status: integer() | nil,
          duration_ms: non_neg_integer(),
          config_path: Path.t(),
          cwd: Path.t()
        }

  @doc """
  Runs one trial and returns the client's stdout.

  Required options: `:prompt`, `:model`, `:surface_path`, `:fixture_path`,
  `:trace_path`. Optional: `:timeout_ms` (default 120s), `:keep_cwd?` (leave the
  temp directory in place for debugging).
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts) do
    cwd = make_cwd()

    try do
      do_run(cwd, opts)
    after
      unless Keyword.get(opts, :keep_cwd?, false), do: File.rm_rf!(cwd)
    end
  end

  defp do_run(cwd, opts) do
    config_path = Path.join(cwd, "mcp-config.json")

    config =
      Client.mcp_config(
        recorder_path: recorder_path(),
        surface_path: Keyword.fetch!(opts, :surface_path),
        fixture_path: Keyword.fetch!(opts, :fixture_path),
        trace_path: Keyword.fetch!(opts, :trace_path)
      )

    File.write!(config_path, Jason.encode!(config))

    invocation =
      Client.invocation(
        prompt: Keyword.fetch!(opts, :prompt),
        model: Keyword.fetch!(opts, :model),
        config_path: config_path,
        cwd: cwd
      )

    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    started = System.monotonic_time(:millisecond)

    case execute(invocation, timeout) do
      {:ok, output, status} ->
        {:ok,
         %{
           output: output,
           exit_status: status,
           duration_ms: System.monotonic_time(:millisecond) - started,
           config_path: config_path,
           cwd: cwd
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(invocation, timeout) do
    port =
      Port.open({:spawn_executable, closed_stdin_path()}, [
        :binary,
        :exit_status,
        :hide,
        args: [invocation.executable | invocation.argv],
        cd: invocation.cwd,
        env: invocation.env
      ])

    collect(port, [], System.monotonic_time(:millisecond) + timeout)
  end

  defp collect(port, chunks, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [data | chunks], deadline)

      {^port, {:exit_status, status}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining ->
        kill(port)
        {:error, {:timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}}
    end
  end

  # Closing the port only closes the pipes; the CLI can outlive that and keep
  # burning quota, so the OS process is killed by pid first.
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    # Port.info/1 followed by Port.close/1 is a check-then-act race: the port
    # can finish closing itself (the OS process it drives just died) in the gap
    # between the two calls, and Port.close/1 raises ArgumentError on a port
    # that is already gone. That must void one trial, not crash the whole run.
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    # Drain whatever the port already queued so the mailbox does not leak into
    # the next trial.
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      500 -> :ok
    end
  end

  @doc """
  The committed recorder wrapper's absolute path.

  Resolved from `File.cwd!()`, which the eval task pins to the repository root.
  Never `Application.app_dir/2`: in dev that is `_build/dev/lib/seshat/priv`, a
  symlink whose parent chain is not the repository, and the wrapper walks up
  three levels to find the repo.
  """
  @spec recorder_path() :: Path.t()
  def recorder_path, do: Path.expand("priv/routing_eval/bin/recorder", File.cwd!())

  @doc "The committed stdin-closing wrapper's absolute path."
  @spec closed_stdin_path() :: Path.t()
  def closed_stdin_path, do: Path.expand("priv/routing_eval/bin/closed-stdin", File.cwd!())

  defp make_cwd do
    dir =
      Path.join(
        System.tmp_dir!(),
        "seshat-routing-eval-#{System.unique_integer([:positive])}-#{System.os_time(:millisecond)}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
