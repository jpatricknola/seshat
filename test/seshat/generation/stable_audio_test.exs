defmodule Seshat.Generation.StableAudioTest do
  @moduledoc """
  The adapter, against a throwaway runtime the test writes itself.

  Nothing here needs the user's Stable Audio installation, model weights or a
  network: the point of the file is the *protocol* between Seshat and a local
  CLI — the exact argv, the preflight that stops a download starting inside a
  tool call, and the disposal of a process that will not stop on its own.
  """

  use ExUnit.Case, async: false

  alias Seshat.Generation.Spec
  alias Seshat.Generation.StableAudio

  @weights [
    "models/mlx/t5gemma_f16.npz",
    "models/mlx/dit_sm-music_f16.npz",
    "models/mlx/same_s_decoder_f32.npz",
    "models/mlx/same_s_encoder_f32.npz"
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "seshat-sa3-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "scripts"))
    File.mkdir_p!(Path.join(root, ".venv/bin"))
    File.mkdir_p!(Path.join(root, "models/mlx"))
    File.mkdir_p!(Path.join(root, "out"))

    File.write!(Path.join(root, "scripts/sa3_mlx.py"), "# stand-in\n")
    write_executable(Path.join(root, ".venv/bin/python"), "#!/bin/sh\nexit 0\n")

    for weight <- @weights, do: File.write!(Path.join(root, weight), "weights")

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  defp write_executable(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  # A stand-in for `sa3`: records its own argv, writes the file it was told to
  # write, and exits with the status the test asked for.
  defp install_runtime(root, opts \\ []) do
    argv_log = Path.join(root, "argv.txt")
    status = Keyword.get(opts, :status, 0)
    body = Keyword.get(opts, :body, "RIFF....WAVEfmt ")
    noise = Keyword.get(opts, :noise, "SA3 -> MLX text-to-audio\\n")
    write_file? = Keyword.get(opts, :write_file?, true)

    script = """
    #!/bin/sh
    : > #{argv_log}
    out=""
    prev=""
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> #{argv_log}
      if [ "$prev" = "--out" ]; then out="$arg"; fi
      prev="$arg"
    done
    printf '#{noise}'
    if [ "#{write_file?}" = "true" ] && [ -n "$out" ]; then
      printf '#{body}' > "$out"
    fi
    exit #{status}
    """

    path = Path.join(root, "sa3")
    write_executable(path, script)

    Application.put_env(:seshat, :generation_executable, path)
    Application.put_env(:seshat, :generation_model_root, root)

    on_exit(fn ->
      Application.delete_env(:seshat, :generation_executable)
      Application.delete_env(:seshat, :generation_model_root)
      Application.delete_env(:seshat, :generation_timeout)
      Application.delete_env(:seshat, :generation_max_output_bytes)
    end)

    argv_log
  end

  defp spec(root, overrides \\ []) do
    defaults = [
      prompt: "dusty breakbeat. 124 BPM, 4/4 time.",
      seconds: 7.741935483870968,
      seed: 1842,
      out_path: Path.join(root, "out/take.wav")
    ]

    struct!(Spec, Keyword.merge(defaults, overrides))
  end

  defp recorded_argv(log), do: log |> File.read!() |> String.split("\n", trim: true)

  describe "argv/1" do
    test "always pins the lane, the duration, the seed and the destination", %{root: root} do
      argv = StableAudio.argv(spec(root))

      assert "--dit" in argv and "sm-music" in argv
      assert "--decoder" in argv and "same-s" in argv

      # Omitting either would drop the runtime into its interactive arrow-key
      # picker, which inside a tool call means a hang, not a prompt.
      assert Enum.find_index(argv, &(&1 == "--dit")) + 1 ==
               Enum.find_index(argv, &(&1 == "sm-music"))

      assert value_after(argv, "--seed") == "1842"
      assert value_after(argv, "--out") == Path.join(root, "out/take.wav")
      assert value_after(argv, "--prompt") == "dusty breakbeat. 124 BPM, 4/4 time."
    end

    # The whole duration claim rests on this: Python reconstructs the double
    # from this text and trims to int(round(seconds * 44100)).
    test "serialises seconds without losing a bit of the double", %{root: root} do
      argv = StableAudio.argv(spec(root, seconds: 7.741935483870968))

      assert value_after(argv, "--seconds") == "7.741935483870968"
      assert String.to_float(value_after(argv, "--seconds")) == 7.741935483870968
    end

    test "a whole number of seconds still serialises as a float", %{root: root} do
      argv = StableAudio.argv(spec(root, seconds: 8.0))

      assert value_after(argv, "--seconds") == "8.0"
    end

    test "a negative prompt brings CFG with it", %{root: root} do
      argv = StableAudio.argv(spec(root, negative_prompt: "vocals"))

      assert value_after(argv, "--negative-prompt") == "vocals"

      # Without this the runtime's default CFG of 1.0 leaves guidance off, and
      # the negative branch — the only thing a negative prompt can influence —
      # is never evaluated.
      assert value_after(argv, "--cfg") == "3.0"
    end

    test "no negative prompt means no --cfg and no init flags", %{root: root} do
      argv = StableAudio.argv(spec(root))

      refute "--cfg" in argv
      refute "--negative-prompt" in argv
      refute "--init-audio" in argv
      refute "--init-noise-level" in argv
    end

    test "a variation carries both init flags", %{root: root} do
      source = Path.join(root, "out/source.wav")

      argv = StableAudio.argv(spec(root, init_audio: source, init_noise_level: 0.55))

      assert value_after(argv, "--init-audio") == source
      assert value_after(argv, "--init-noise-level") == "0.55"
    end

    # Prompts are model- and user-written text. They reach the runtime as one
    # argv entry each, so nothing in them can be a second argument, let alone a
    # shell construct.
    test "shell metacharacters in a prompt stay inside one argument", %{root: root} do
      hostile = "drums\"; rm -rf / #$(whoami)`id`"

      argv = StableAudio.argv(spec(root, prompt: hostile))

      assert value_after(argv, "--prompt") == hostile
      assert Enum.count(argv, &(&1 == hostile)) == 1
    end
  end

  describe "preflight" do
    test "refuses a runtime that is not installed", %{root: root} do
      install_runtime(root)
      Application.put_env(:seshat, :generation_executable, Path.join(root, "absent"))

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "not installed"
      assert message =~ "Nothing is downloaded during a tool call."
    end

    test "refuses a runtime that is present but not executable", %{root: root} do
      install_runtime(root)
      File.chmod!(Path.join(root, "sa3"), 0o644)

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "not executable"
    end

    # The wrapper offers to run install.sh when .venv is missing. Inside a tool
    # call that is an interactive prompt nobody can answer, so it is closed here.
    test "refuses when the runtime's own interpreter is missing", %{root: root} do
      install_runtime(root)
      File.rm!(Path.join(root, ".venv/bin/python"))

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "incomplete"
    end

    test "refuses when the runtime script is missing", %{root: root} do
      install_runtime(root)
      File.rm!(Path.join(root, "scripts/sa3_mlx.py"))

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "the runtime script"
    end

    # An absent weight makes the runtime's own preflight start a multi-gigabyte
    # download. Refusing by name is the whole reason this check exists.
    test "names the missing weight rather than letting the runtime fetch it", %{root: root} do
      log = install_runtime(root)
      File.rm!(Path.join(root, "models/mlx/dit_sm-music_f16.npz"))

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "the sm-music DiT"
      assert message =~ "dit_sm-music_f16.npz"
      refute File.exists?(log), "the runtime was started despite a missing weight"
    end

    # Only a variation reads the encoder, so its absence must not refuse an
    # ordinary text-to-audio render.
    test "the variation encoder is required only for a variation", %{root: root} do
      install_runtime(root)
      File.rm!(Path.join(root, "models/mlx/same_s_encoder_f32.npz"))

      assert {:ok, _} = StableAudio.generate(spec(root))

      source = Path.join(root, "out/source.wav")
      File.write!(source, "source")

      assert {:error, message} =
               StableAudio.generate(
                 spec(root,
                   out_path: Path.join(root, "out/varied.wav"),
                   init_audio: source,
                   init_noise_level: 0.55
                 )
               )

      assert message =~ "same-s encoder"
    end
  end

  describe "running the runtime" do
    test "passes the built argv through and reports the render", %{root: root} do
      log = install_runtime(root)

      assert {:ok, %{path: path, seed: 1842, wall_ms: wall_ms}} = StableAudio.generate(spec(root))

      assert path == Path.join(root, "out/take.wav")
      assert File.regular?(path)
      assert is_integer(wall_ms) and wall_ms >= 0

      assert recorded_argv(log) == StableAudio.argv(spec(root))
    end

    test "a non-zero exit is reported with the runtime's last output", %{root: root} do
      install_runtime(root, status: 3, noise: "mlx: out of memory\\n", write_file?: false)

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "exited with status 3"
      assert message =~ "nothing was imported"
      assert message =~ "out of memory"
    end

    test "success with no file written is not success", %{root: root} do
      install_runtime(root, write_file?: false)

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "wrote no file"
    end

    test "success with an empty file is not success", %{root: root} do
      install_runtime(root, body: "")

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "empty file"
    end

    # `lstat`, so a link left at the reserved name is refused rather than
    # followed to whatever it points at.
    test "a symlink at the output path is refused", %{root: root} do
      install_runtime(root, write_file?: false)

      target = Path.join(root, "out/elsewhere.wav")
      File.write!(target, "not ours")
      File.ln_s!(target, Path.join(root, "out/take.wav"))

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "not a regular file"
    end

    # The guarantee is "the last `cap` bytes", not "the newest chunks that
    # happen to fit". Asserting a mere 100 bytes hid a real defect and made this
    # test load-dependent: a port splits one write arbitrarily (`[40000]`,
    # `[19456, 20544]` and `[38912, 1088]` all measured for the same 40,000-byte
    # write), and when the newest chunk was small, `trim/3` dropped everything
    # older and retained only that — 64 bytes of a 1,000-byte budget on the run
    # that caught it. So this asserts the full cap, which is chunk-independent.
    test "retained diagnostics are bounded", %{root: root} do
      install_runtime(root, status: 1, noise: String.duplicate("x", 40_000), write_file?: false)
      Application.put_env(:seshat, :generation_max_output_bytes, 1_000)

      assert {:error, message} = StableAudio.generate(spec(root))
      assert byte_size(message) < 4_000
      assert message =~ "The runtime's last output was:"
      assert message =~ String.duplicate("x", 1_000)
    end

    # The same boundary with a deliberately small trailing write, which is the
    # shape a real runtime produces: a traceback, then a short closing line.
    # Before the split, this retained the closing line alone.
    test "a small final write does not discard the output before it", %{root: root} do
      install_runtime(root,
        status: 1,
        noise: String.duplicate("x", 40_000) <> "\\ndone\\n",
        write_file?: false
      )

      Application.put_env(:seshat, :generation_max_output_bytes, 1_000)

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "done"
      assert message =~ String.duplicate("x", 900)
    end
  end

  describe "the timeout" do
    # The property that matters is not "the call returns" — it is that the
    # runtime process is *gone*. A wedged MLX render left behind would keep a
    # machine's GPU busy with work nobody is waiting for.
    test "terminates the exact runtime process it started", %{root: root} do
      pidfile = Path.join(root, "runtime.pid")

      script = """
      #!/bin/sh
      echo $$ > #{pidfile}
      exec sleep 30
      """

      write_executable(Path.join(root, "sa3"), script)
      Application.put_env(:seshat, :generation_executable, Path.join(root, "sa3"))
      Application.put_env(:seshat, :generation_model_root, root)
      Application.put_env(:seshat, :generation_timeout, 400)

      on_exit(fn ->
        Application.delete_env(:seshat, :generation_executable)
        Application.delete_env(:seshat, :generation_model_root)
        Application.delete_env(:seshat, :generation_timeout)
      end)

      assert {:error, message} = StableAudio.generate(spec(root))
      assert message =~ "did not finish"
      assert message =~ "nothing was imported"

      pid = pidfile |> File.read!() |> String.trim()
      refute alive?(pid), "the timed-out runtime (pid #{pid}) is still running"
    end
  end

  defp value_after(argv, flag) do
    case Enum.find_index(argv, &(&1 == flag)) do
      nil -> nil
      index -> Enum.at(argv, index + 1)
    end
  end

  # `kill -0` asks the kernel whether the pid exists without signalling it.
  # Given a moment: SIGTERM delivery and reaping are not instantaneous.
  defp alive?(pid, attempts \\ 20) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} when attempts > 0 ->
        Process.sleep(50)
        alive?(pid, attempts - 1)

      {_output, 0} ->
        true

      _ ->
        false
    end
  end
end
