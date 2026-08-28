defmodule Seshat.Eval.ClientTest do
  @moduledoc """
  The flag list is the contract, so it is asserted flag by flag rather than
  eyeballed — every one of them was measured against Claude Code 2.1.220 on
  2026-08-28, and losing `--setting-sources ""` silently reintroduces the
  developer's own hooks and plugins into the measurement.

  Nothing here starts the real CLI. `:routing_eval_command` points the runner at
  a capture-replay script the test writes itself, the same seam
  `Seshat.AX.Client`'s suite uses for the native helper.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Routing.Eval.Runner
  alias Seshat.Eval.Client

  @stream_line ~s({"type":"system","subtype":"init","tools":[],"plugins":[]})

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        prompt: "Bring the master down a touch.",
        model: "claude-sonnet-5",
        config_path: "/tmp/eval/mcp-config.json",
        cwd: "/tmp/eval/cwd"
      ],
      overrides
    )
  end

  # Writes an executable standing in for `claude`, and points the runner at it.
  defp fake_cli(context, body) do
    path = Path.join(context.tmp_dir, "fake-claude")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)

    Application.put_env(:seshat, :routing_eval_command, [path])
    on_exit(fn -> Application.delete_env(:seshat, :routing_eval_command) end)

    path
  end

  describe "invocation/1" do
    test "carries every flag of the measured contract" do
      argv = Client.invocation(opts()).argv

      assert flag(argv, "-p") == "Bring the master down a touch."
      assert flag(argv, "--output-format") == "stream-json"
      assert "--verbose" in argv
      assert flag(argv, "--model") == "claude-sonnet-5"
      assert flag(argv, "--system-prompt") == Client.system_prompt()
      assert flag(argv, "--mcp-config") == "/tmp/eval/mcp-config.json"
      assert "--strict-mcp-config" in argv
      assert flag(argv, "--allowedTools") == "mcp__seshat_eval__*"
      assert "--disable-slash-commands" in argv
      assert "--no-session-persistence" in argv
      refute "--bare" in argv
    end

    # Mandatory: without it, this machine's own SessionStart hook fired inside
    # the eval and rewrote the model's register.
    test "empties the setting sources and the built-in tools" do
      argv = Client.invocation(opts()).argv

      assert flag(argv, "--setting-sources") == ""
      assert flag(argv, "--tools") == ""
    end

    test "strips ANTHROPIC_API_KEY and runs in the caller's temp cwd" do
      invocation = Client.invocation(opts())

      assert invocation.env == [{~c"ANTHROPIC_API_KEY", false}]
      assert invocation.cwd == "/tmp/eval/cwd"
      assert invocation.executable == "claude"
    end

    test "the executable is configurable so the suite never runs the real CLI" do
      Application.put_env(:seshat, :routing_eval_command, ["/bin/echo", "--prefix"])
      on_exit(fn -> Application.delete_env(:seshat, :routing_eval_command) end)

      invocation = Client.invocation(opts())

      assert invocation.executable == "/bin/echo"
      assert hd(invocation.argv) == "--prefix"
    end

    test "the lane prompt is fixed and hashed for the report" do
      assert Client.system_prompt() =~ "You are Seshat"
      assert Client.system_prompt_hash() =~ ~r/^[0-9a-f]{12}$/
    end
  end

  describe "mcp_config/1" do
    test "names exactly the recorder, by absolute path, with no shell string" do
      config =
        Client.mcp_config(
          recorder_path: "/repo/priv/routing_eval/bin/recorder",
          surface_path: "/run/surface.json",
          fixture_path: "/repo/priv/routing_eval/fixtures/f.json",
          trace_path: "/run/trace.jsonl"
        )

      assert %{"mcpServers" => %{"seshat_eval" => server}} = config
      assert Map.keys(config["mcpServers"]) == ["seshat_eval"]
      assert server["type"] == "stdio"
      assert server["command"] == "/repo/priv/routing_eval/bin/recorder"

      assert server["args"] == [
               "--surface",
               "/run/surface.json",
               "--fixture",
               "/repo/priv/routing_eval/fixtures/f.json",
               "--trace",
               "/run/trace.jsonl"
             ]
    end
  end

  describe "the committed wrappers" do
    test "exist and are executable" do
      for path <- [Runner.recorder_path(), Runner.closed_stdin_path()] do
        assert File.exists?(path), "missing #{path}"
        assert %File.Stat{mode: mode} = File.stat!(path)
        assert Bitwise.band(mode, 0o111) != 0, "#{path} is not executable"
      end
    end

    # Never `Application.app_dir/2`: in dev that resolves inside `_build`, whose
    # parent chain is not the repository the wrapper walks up to find.
    test "are resolved from the repository root, not from _build" do
      refute Runner.recorder_path() =~ "_build"
      assert Runner.recorder_path() == Path.expand("priv/routing_eval/bin/recorder", File.cwd!())
    end
  end

  describe "Runner.run/1" do
    @tag :tmp_dir
    test "returns the client's stdout and removes the temp cwd", context do
      fake_cli(context, "echo '" <> @stream_line <> "'")

      assert {:ok, result} =
               Runner.run(
                 prompt: "hello",
                 model: "claude-sonnet-5",
                 surface_path: "/dev/null",
                 fixture_path: "/dev/null",
                 trace_path: Path.join(context.tmp_dir, "trace.jsonl")
               )

      assert result.output == @stream_line <> "\n"
      assert result.exit_status == 0
      refute File.exists?(result.cwd)
    end

    @tag :tmp_dir
    test "writes the MCP config into the trial's own cwd", context do
      # The runner sets cwd to the trial directory it created, so the config is
      # simply in the working directory.
      fake_cli(context, "cat mcp-config.json")

      assert {:ok, result} =
               Runner.run(
                 prompt: "hello",
                 model: "claude-sonnet-5",
                 surface_path: "/run/surface.json",
                 fixture_path: "/run/fixture.json",
                 trace_path: "/run/trace.jsonl",
                 keep_cwd?: true
               )

      config = result.config_path |> File.read!() |> Jason.decode!()

      assert config["mcpServers"]["seshat_eval"]["command"] == Runner.recorder_path()
      assert result.config_path == Path.join(result.cwd, "mcp-config.json")

      File.rm_rf!(result.cwd)
    end

    # The CLI waits three seconds for piped input and warns when stdin is a pipe
    # nothing writes to — which is exactly what an Erlang port looks like.
    @tag :tmp_dir
    test "runs the client with stdin already closed", context do
      fake_cli(context, "if read -r line; then echo 'SAW INPUT'; else echo EOF; fi")

      assert {:ok, result} =
               Runner.run(
                 prompt: "hello",
                 model: "claude-sonnet-5",
                 surface_path: "/dev/null",
                 fixture_path: "/dev/null",
                 trace_path: "/dev/null"
               )

      assert result.output == "EOF\n"
    end

    @tag :tmp_dir
    test "kills a hanging client at the timeout and still cleans up", context do
      pid_file = Path.join(context.tmp_dir, "child.pid")
      fake_cli(context, "echo $$ > #{pid_file}\nsleep 30")

      before_dirs = routing_eval_temp_dirs()

      # Generous relative to the earlier flag-parsing tests: this one needs the
      # child to have actually forked and written its pid before the deadline
      # fires, not just to still be running, so it gives process startup room
      # to survive a busy `mix test` run rather than racing it at 200ms.
      assert {:error, {:timeout, partial}} =
               Runner.run(
                 prompt: "hello",
                 model: "claude-sonnet-5",
                 surface_path: "/dev/null",
                 fixture_path: "/dev/null",
                 trace_path: "/dev/null",
                 timeout_ms: 1_000
               )

      assert partial == ""

      # The runner's own temp cwd is created and removed inside run/1, with no
      # handle to it on the error path — diff the tmp dir by the runner's own
      # naming prefix instead of reading it off a result that does not exist.
      assert routing_eval_temp_dirs() -- before_dirs == []

      # kill/1 sends SIGKILL by pid before it ever touches the port, so the
      # hanging child must actually be gone, not merely disconnected from Erlang.
      pid = pid_file |> File.read!() |> String.trim()
      {_output, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end
  end

  defp routing_eval_temp_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "seshat-routing-eval-"))
  end

  defp flag(argv, name) do
    case Enum.find_index(argv, &(&1 == name)) do
      nil -> flunk("#{name} is not in #{inspect(argv)}")
      index -> Enum.at(argv, index + 1)
    end
  end
end
