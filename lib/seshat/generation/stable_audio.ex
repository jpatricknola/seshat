defmodule Seshat.Generation.StableAudio do
  @moduledoc """
  The Stable Audio 3 MLX runtime, driven one process per request.

  This is the **second** module under `lib/seshat/` permitted to start a native
  process, after `Seshat.AX.Client`. The architectural grep test in
  `test/seshat/ax/client_test.exs` names exactly these two files, so a third
  door cannot appear quietly — see that test, and `Seshat.AX.Client`'s
  "The boundary is the point".

  ## Nothing user-written reaches a shell

  The prompt, the negative prompt and the output path are all model- or
  user-influenced text. `Port.open/2` is called with `{:spawn_executable, path}`
  and an `args:` list, so each of them is exactly one argv entry: no quoting,
  no `;`, no `$(...)` can mean anything. The `sa3` wrapper is a bash script but
  it is `exec`'d directly rather than through `sh -c`, and it forwards `"$@"`
  unexpanded.

  ## Preflight, because a missing weight would otherwise download

  The runtime's own preflight downloads any absent weight from Hugging Face
  before it starts rendering. Inside a tool call that is the wrong behaviour
  twice over — an unbounded network fetch inside a 60-second budget, and a
  multi-gigabyte download nobody asked for — so every file the run will need is
  checked here first and a missing one is a refusal naming the file. The
  wrapper's other interactive path (`install.sh` when `uv` or `.venv` is
  missing) is closed the same way: `.venv/bin/python` is checked before the
  wrapper can offer to install anything, and stdin is never a TTY here anyway.

  ## One lane

  `--dit sm-music` and `--decoder same-s` are fixed. The 2026-08-25 spike
  measured that pair at 1.0–1.1s for four bars after warm-up, with the final
  WAV trimmed to exactly `--seconds`. `medium`/`same-l` is deliberately not
  exposed: a second quality lane before a listening comparison would grow the
  tool contract around an unproven distinction (see the plan's Out of scope).

  ## The timeout kills the runtime, not a guess

  `Port.close/1` detaches the BEAM's end of the pipes; it does not end the
  external process, which for a wedged MLX render could keep a machine's GPU
  busy indefinitely. So the timeout path reads the exact OS pid out of
  `Port.info/2`, sends it `SIGTERM`, waits a bounded grace period for the port's
  own exit, and escalates to `SIGKILL`. The `sa3` wrapper ends in
  `exec .venv/bin/python`, so that pid *is* the Python runtime rather than a
  bash parent — no process group, no guessed pid, nothing signalled that this
  call did not start.
  """

  @behaviour Seshat.Generation.Backend

  alias Seshat.Generation.Spec

  require Logger

  @default_executable "~/.seshat/stable-audio-3/optimized/mlx/sa3"
  @default_model_root "~/.seshat/stable-audio-3/optimized/mlx"

  @default_timeout 60_000

  # Diagnostics only. The runtime prints a banner and per-stage timings; a
  # failure needs the tail of that, not a transcript, and an unbounded read of a
  # runaway process's output is its own failure mode.
  @default_max_output_bytes 32 * 1024

  # How long SIGTERM is given to end the runtime before SIGKILL, and how often
  # the port is checked in between. Short: by this point the call has already
  # spent its whole budget and the user is waiting on an answer.
  @term_grace_ms 500
  @term_poll_ms 50

  @dit "sm-music"
  @decoder "same-s"

  # Relative to the model root. `sm-music`'s DiT, the `same-s` decoder and the
  # T5Gemma text encoder are needed by every render; the `same-s` *encoder* is
  # needed only to read an `--init-audio` file, so it is preflighted only for a
  # variation. Names checked against DIT_CHOICES / DECODER_CHOICES /
  # ENCODER_CHOICES / T5GEMMA_NPZ_REL in the runtime's scripts/sa3_mlx.py.
  @weights [
    {"models/mlx/t5gemma_f16.npz", "the T5Gemma text encoder"},
    {"models/mlx/dit_sm-music_f16.npz", "the sm-music DiT"},
    {"models/mlx/same_s_decoder_f32.npz", "the same-s decoder"}
  ]

  @variation_weight {"models/mlx/same_s_encoder_f32.npz",
                     "the same-s encoder (needed to read a variation source)"}

  @install_hint "Install the Stable Audio 3 MLX runtime and its weights " <>
                  "(see README.md, \"Generating audio\"), then try again. Nothing is downloaded " <>
                  "during a tool call."

  @doc """
  Where the `sa3` wrapper lives. `:generation_executable` overrides it.
  """
  @spec executable() :: String.t()
  def executable do
    Path.expand(Application.get_env(:seshat, :generation_executable) || @default_executable)
  end

  @doc """
  The runtime checkout that holds `scripts/`, `.venv/` and `models/`.
  `:generation_model_root` overrides it.
  """
  @spec model_root() :: String.t()
  def model_root do
    Path.expand(Application.get_env(:seshat, :generation_model_root) || @default_model_root)
  end

  @doc """
  How long a single render may take before the runtime is terminated, in
  milliseconds. `:generation_timeout` overrides it.
  """
  @spec timeout() :: pos_integer()
  def timeout, do: Application.get_env(:seshat, :generation_timeout, @default_timeout)

  @doc """
  How much runtime output is retained for diagnostics, in bytes.
  `:generation_max_output_bytes` overrides it.
  """
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes do
    Application.get_env(:seshat, :generation_max_output_bytes, @default_max_output_bytes)
  end

  @impl true
  def generate(%Spec{} = spec) do
    with :ok <- preflight(spec) do
      started = System.monotonic_time(:millisecond)

      case run(spec) do
        {:ok, output} ->
          elapsed = System.monotonic_time(:millisecond) - started

          case confirm_output(spec, output) do
            :ok ->
              Logger.info("Generated #{spec.out_path} in #{elapsed}ms (seed #{spec.seed})")
              {:ok, %{path: spec.out_path, seed: spec.seed, wall_ms: elapsed}}

            {:error, message} ->
              {:error, message}
          end

        {:error, message} ->
          {:error, message}
      end
    end
  end

  # --- Preflight ---

  @doc """
  Check the runtime and every weight this spec will need, without running
  anything.

  Public because it is the half of the adapter that can be exercised with no
  subprocess at all, and because a future `mix` task or setup check has the same
  question to ask.
  """
  @spec preflight(Spec.t()) :: :ok | {:error, String.t()}
  def preflight(%Spec{} = spec) do
    root = model_root()

    with :ok <- check_executable(executable(), :wrapper),
         :ok <- check_regular(Path.join(root, "scripts/sa3_mlx.py"), "the runtime script"),
         :ok <- check_executable(Path.join(root, ".venv/bin/python"), :interpreter),
         :ok <- check_weights(root, spec) do
      :ok
    end
  end

  # The wrapper's absence means the runtime was never installed; the
  # interpreter's means it was installed and then something went missing, which
  # is the same class of failure as an absent script or weight. The wordings
  # differ because the two send a user to different places — and because the
  # wrapper would otherwise offer to run `install.sh` interactively, which
  # inside a tool call is a hang rather than a prompt.
  defp check_executable(path, role) do
    cond do
      not File.regular?(path) ->
        {:error, missing_executable_message(role, path)}

      not executable?(path) ->
        {:error,
         "#{path} is not executable, so the Stable Audio runtime cannot be started. " <>
           "#{@install_hint}"}

      true ->
        :ok
    end
  end

  defp missing_executable_message(:wrapper, path),
    do: "The Stable Audio runtime is not installed at #{path}. #{@install_hint}"

  defp missing_executable_message(:interpreter, path) do
    "The Stable Audio runtime is incomplete — its Python interpreter is missing at #{path}. " <>
      @install_hint
  end

  defp check_regular(path, description) do
    if File.regular?(path) do
      :ok
    else
      {:error,
       "The Stable Audio runtime is incomplete — #{description} is missing at #{path}. " <>
         @install_hint}
    end
  end

  defp check_weights(root, spec) do
    needed = if Spec.variation?(spec), do: @weights ++ [@variation_weight], else: @weights

    missing =
      for {relative, description} <- needed,
          not File.regular?(Path.join(root, relative)),
          do: "#{description} (#{relative})"

    case missing do
      [] ->
        :ok

      _ ->
        {:error,
         "The Stable Audio runtime is installed but #{Enum.join(missing, " and ")} " <>
           "#{plural_verb(missing)} missing from #{root}. #{@install_hint}"}
    end
  end

  defp plural_verb([_one]), do: "is"
  defp plural_verb(_many), do: "are"

  # `File.stat/1`'s mode is the raw st_mode; any of the three execute bits is
  # enough, because the BEAM runs as the file's owner or it does not run it at
  # all.
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  # --- Argv ---

  @doc """
  The exact argument list this spec becomes.

  Pure, and public so the tests can pin it without running anything: this is
  where a forgotten `--dit` would drop the runtime into its interactive picker,
  and where a lossy seconds rendering would desynchronise the runtime's frame
  count from the one the workflow reported.

  `--seconds` is serialised with `:erlang.float_to_binary/2`'s `:short` form —
  the shortest decimal that round-trips the double exactly — so Python's
  `float()` reconstructs the identical value and its
  `int(round(seconds * 44100))` agrees with
  `Seshat.Generation.AudioClip.target_frames/1`.
  """
  @spec argv(Spec.t()) :: [String.t()]
  def argv(%Spec{} = spec) do
    base = [
      "--prompt",
      spec.prompt,
      "--dit",
      @dit,
      "--decoder",
      @decoder,
      "--seconds",
      seconds_arg(spec.seconds),
      "--seed",
      Integer.to_string(spec.seed),
      "--out",
      spec.out_path
    ]

    # `--cfg` travels with the negative prompt on purpose: the runtime's default
    # CFG scale is 1.0, which is "guidance off" and makes the unconditional /
    # negative branch unreachable — a negative prompt without it is silently
    # ignored.
    negative =
      case spec.negative_prompt do
        nil -> []
        text -> ["--negative-prompt", text, "--cfg", "3.0"]
      end

    init =
      if Spec.variation?(spec) do
        ["--init-audio", spec.init_audio, "--init-noise-level", float_arg(spec.init_noise_level)]
      else
        []
      end

    base ++ negative ++ init
  end

  defp seconds_arg(seconds), do: float_arg(seconds)

  defp float_arg(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp float_arg(value) when is_integer(value), do: :erlang.float_to_binary(value * 1.0, [:short])

  # --- Execution ---

  defp run(spec) do
    port =
      Port.open({:spawn_executable, executable()}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: argv(spec)
      ])

    collect(port, [], 0, System.monotonic_time(:millisecond) + timeout())
  rescue
    error ->
      {:error,
       "The Stable Audio runtime could not be started (#{Exception.message(error)}). " <>
         @install_hint}
  end

  defp collect(port, chunks, size, deadline) do
    receive do
      {^port, {:data, data}} ->
        {chunks, size} = retain(chunks, size, data)
        collect(port, chunks, size, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, tail(chunks)}

      {^port, {:exit_status, status}} ->
        {:error,
         "The Stable Audio runtime exited with status #{status} and nothing was imported. " <>
           diagnostics(tail(chunks))}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        terminate(port)

        {:error,
         "Generation did not finish within #{div(timeout(), 1000)} seconds, so it was stopped " <>
           "and nothing was imported. A first render after a reboot loads several gigabytes of " <>
           "weights and is much slower than a warm one — try again, or ask for fewer bars. " <>
           diagnostics(tail(chunks))}
    end
  end

  # Keep the *tail*: the runtime's failure message is the last thing it prints,
  # and its banner is the least useful part. Chunks are held newest-first and
  # dropped from the far end once the cap is reached.
  defp retain(chunks, size, data) do
    chunks = [data | chunks]
    size = size + byte_size(data)
    cap = max_output_bytes()

    if size > cap do
      trim(chunks, size, cap)
    else
      {chunks, size}
    end
  end

  defp trim(chunks, size, cap) do
    case List.pop_at(chunks, -1) do
      {nil, _rest} ->
        {chunks, size}

      {oldest, rest} ->
        size = size - byte_size(oldest)

        cond do
          size > cap and rest != [] ->
            trim(rest, size, cap)

          rest == [] and byte_size(oldest) > cap ->
            kept = binary_part(oldest, byte_size(oldest) - cap, cap)
            {[kept], cap}

          true ->
            {rest, size}
        end
    end
  end

  defp tail(chunks) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp diagnostics(""), do: "The runtime printed nothing."

  defp diagnostics(output) do
    "The runtime's last output was: #{output}"
  end

  # Signal the runtime itself, then reap the port. Order matters: the pid has to
  # be read while the port is still open, because `Port.info/2` on a closed port
  # returns nil and there would be nothing left to signal.
  defp terminate(port) do
    os_pid = port_os_pid(port)

    if os_pid, do: signal(os_pid, "-TERM")

    unless awaited_exit?(port, System.monotonic_time(:millisecond) + @term_grace_ms) do
      if os_pid, do: signal(os_pid, "-KILL")
    end

    close(port)
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  # `/bin/kill` with an argv list, never a shell: the pid came from `Port.info/2`
  # and is an integer, but the rule here is the same one the prompt obeys — this
  # module never composes a command line.
  defp signal(os_pid, flag) do
    System.cmd("/bin/kill", [flag, Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    error ->
      Logger.debug("Could not signal generation pid #{os_pid}: #{Exception.message(error)}")
      :ok
  end

  defp awaited_exit?(port, deadline) do
    receive do
      {^port, {:exit_status, _status}} -> true
    after
      min(@term_poll_ms, max(deadline - System.monotonic_time(:millisecond), 0)) ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          awaited_exit?(port, deadline)
        end
    end
  end

  # Detach and drain, for the same reason `Seshat.AX.Client.close/1` does: a
  # `{:data, _}` or `{:exit_status, _}` that arrived in the gap between the
  # `after` firing and this running would otherwise sit in the caller's mailbox,
  # and under `mix mcp` the caller is a long-lived process.
  defp close(port) do
    if Port.info(port), do: Port.close(port)

    drain(port)
  end

  defp drain(port) do
    receive do
      {^port, _message} -> drain(port)
    after
      0 -> :ok
    end
  end

  # --- Output ---

  # Exit 0 is the runtime's claim; this is the check. `lstat` rather than `stat`
  # so a symlink left at the reserved name is refused rather than followed —
  # the workflow reserved a regular file and nothing legitimate replaces it with
  # a link.
  defp confirm_output(spec, output) do
    case File.lstat(spec.out_path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        {:error,
         "The Stable Audio runtime reported success but left an empty file at " <>
           "#{spec.out_path}, so nothing was imported. #{diagnostics(output)}"}

      {:ok, %File.Stat{type: type}} ->
        {:error,
         "The Stable Audio runtime reported success but #{spec.out_path} is a #{type}, not a " <>
           "regular file, so nothing was imported."}

      {:error, reason} ->
        {:error,
         "The Stable Audio runtime reported success but wrote no file at #{spec.out_path} " <>
           "(#{:file.format_error(reason)}), so nothing was imported. #{diagnostics(output)}"}
    end
  end
end
