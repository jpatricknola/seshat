defmodule Seshat.AX.Client do
  @moduledoc """
  The only module in `lib/seshat/` allowed to execute the native Accessibility
  helper — Seshat's one non-OSC path into Ableton Live.

  Everything else Seshat does reaches Live through `Seshat.OSC.Transport` and the
  Live Object Model. A handful of Live's *application-wide* preferences are not
  in the LOM at all — the audio output device is the one this exists for — and
  the only way to reach those is the macOS Accessibility API, which the BEAM
  cannot call. `native/seshat_ax/main.m` makes that call; this module starts it,
  reads its one JSON reply, and turns the result into something a tool handler
  can render.

  ## The boundary is the point

  `Seshat.Tools.Handlers` never spawns anything. Neither does anything else under
  `lib/seshat/`, and `test/seshat/ax/client_test.exs` greps the tree to keep it
  that way: `Port.open`, `:spawn_executable` and `System.cmd` appear here and
  nowhere else. That is the mechanism behind the LOM-first rule — a future tool
  cannot quietly grow a second UI-automation path, because there is one door and
  it is watched, the same way `vendored_addresses_test` watches the fork's
  address surface.

  The helper's protocol is closed for the same reason. It offers audio-output
  listing, audio-output setting, and a permission check. There is no "press this
  element" command to reach for, so adding a UI operation means adding a command
  to the native protocol *and* arguing the LOM-gap case for it.

  ## One process per call

  V1 starts the installed helper once per tool call rather than holding a
  persistent Port. The measured native round trip is well inside the tool budget
  (1.55s for a change-and-restore pair, 0.37s for a single change; 2026-08-03
  spike), while a persistent Port would add restart, protocol-recovery and
  stale-element concerns before startup cost has been shown to matter. Every call
  is timed and logged so that decision stays measurable: promotion to a
  supervised Port needs evidence that process startup eats a meaningful share of
  the 5-second budget, and it would not change the JSON protocol or the tool
  contracts.

  ## Deadlines nest

  The helper owns a 4,000ms action deadline of its own and reports `timeout`
  rather than hanging. This module allows 5,000ms around it, so a helper that
  honours its own budget always answers first and a helper that does not is
  still bounded — failure lands inside the same 5-second acceptance as success
  instead of stalling the conversation.

  Calls are serialised node-wide by a lock of this module's own. Two clients must
  not drive the same Settings popup at once. It is deliberately *not* the OSC
  undo-step lock: an audio-output change is not part of Live's undo history and
  has no reason to queue behind ordinary OSC work (see `Seshat.Tools.Handlers`'s
  `undo_step` opt-out).
  """

  require Logger

  # Must match `kProtocolVersion` in native/seshat_ax/main.m. A helper built from
  # an older checkout answers with its own number and is rejected by name rather
  # than misread.
  @protocol_version 1

  @call_timeout 5_000

  @doc """
  How long a call waits on the helper before giving up, in milliseconds.

  The default is deliberately the same 5 seconds the tool call itself is judged
  against, so a failure lands inside the acceptance budget rather than stalling
  the conversation past it. `:ax_call_timeout` overrides it, which exists so the
  test suite can prove the timeout path without spending five seconds on it —
  the default is asserted separately.
  """
  @spec call_timeout() :: pos_integer()
  def call_timeout, do: Application.get_env(:seshat, :ax_call_timeout, @call_timeout)

  @doc false
  # The node-wide lock every call is taken under. Exposed so the suite can pin
  # the claim that it is *not* `Seshat.Tools.Handlers`'s undo-step lock: a test
  # naming the tuple itself would keep passing after a rename.
  @spec lock_id(pid()) :: {{module(), atom()}, pid()}
  def lock_id(owner \\ self()), do: {{__MODULE__, :helper}, owner}

  # The protocol carries device names, never an AX tree. Anything larger is a
  # helper that has stopped speaking this protocol.
  @max_response_bytes 64 * 1024

  @default_helper_path "~/.seshat/bin/seshat-ax"

  @install_hint "Run `mix ax.install` (macOS only) and approve Seshat's helper under " <>
                  "System Settings > Privacy & Security > Accessibility, then try again."

  @typedoc """
  A failed AX call. `code` is one of the native protocol's codes (plus
  `:helper_missing` and `:version_mismatch`, which are decided here);
  `message` is already user-facing prose. `devices` and `current` are present
  only when the helper could report them — a `:device_not_found` carries the
  names that *do* exist so the caller can offer them without a second round
  trip.
  """
  @type failure :: %{
          code: atom(),
          message: String.t(),
          devices: [String.t()] | nil,
          current: String.t() | nil
        }

  @callback list_outputs() :: {:ok, map()} | {:error, failure()}
  @callback set_output(String.t()) :: {:ok, map()} | {:error, failure()}

  # Native codes are mapped through a fixed table rather than `String.to_atom/1`:
  # the helper's output is external input, and an unrecognised code becomes the
  # generic failure rather than a new atom.
  @codes %{
    "permission_required" => :permission_required,
    "live_not_running" => :live_not_running,
    "settings_unavailable" => :settings_unavailable,
    "device_not_found" => :device_not_found,
    "ax_failure" => :ax_failure,
    "timeout" => :timeout,
    "usage" => :ax_failure
  }

  @doc """
  Where the installed helper lives.

  `:ax_helper_path` overrides it, which is how the test suite points at a
  fixture executable instead of the user's authorised installation.
  """
  @spec helper_path() :: String.t()
  def helper_path do
    Path.expand(Application.get_env(:seshat, :ax_helper_path) || @default_helper_path)
  end

  @doc """
  Live's currently selected audio output and every choice it offers.

  Returns `{:ok, %{current: String.t(), devices: [String.t()], elapsed_ms: integer() | nil}}`.
  """
  @spec list_outputs() :: {:ok, map()} | {:error, failure()}
  def list_outputs do
    with {:ok, payload} <- run(["list-outputs"], :list_outputs) do
      case payload do
        %{current: current, devices: devices}
        when is_binary(current) and is_list(devices) ->
          if Enum.all?(devices, &is_binary/1) do
            {:ok, %{current: current, devices: devices, elapsed_ms: payload[:elapsed_ms]}}
          else
            {:error, malformed()}
          end

        _ ->
          {:error, malformed()}
      end
    end
  end

  @doc """
  Select `device` — an exact name from `list_outputs/0` — as Live's audio output.

  Success means the helper *observed* Live's popup take the new value, not that
  the press returned zero. Returns
  `{:ok, %{previous: String.t(), current: String.t(), elapsed_ms: integer() | nil}}`.
  """
  @spec set_output(String.t()) :: {:ok, map()} | {:error, failure()}
  def set_output(device) when is_binary(device) do
    with {:ok, payload} <- run(["set-output", "--device", device], :set_output) do
      case payload do
        %{previous: previous, current: current} when is_binary(previous) and is_binary(current) ->
          {:ok, %{previous: previous, current: current, elapsed_ms: payload[:elapsed_ms]}}

        _ ->
          {:error, malformed()}
      end
    end
  end

  # --- Execution ---

  defp run(args, operation) do
    started = System.monotonic_time(:millisecond)
    path = helper_path()

    result =
      if File.regular?(path) do
        # A lock of this module's own, node-wide, `self()` as owner so OTP
        # releases it if the caller dies mid-call.
        :global.trans(lock_id(), fn -> execute(path, args) end, [node()])
      else
        {:error,
         failure(
           :helper_missing,
           "Seshat's Accessibility helper isn't installed at #{path}. #{@install_hint}"
         )}
      end

    log(operation, result, System.monotonic_time(:millisecond) - started)

    result
  end

  defp execute(path, args) do
    # `:spawn_executable` with an argv list, never a shell: a device name is
    # user-influenced text and goes to the helper as one argv entry, where no
    # amount of quoting or `;` in it can mean anything.
    port = Port.open({:spawn_executable, path}, [:binary, :exit_status, :hide, args: args])

    collect(port, [], 0, System.monotonic_time(:millisecond) + call_timeout())
  rescue
    error ->
      {:error,
       failure(
         :ax_failure,
         "Seshat's Accessibility helper could not be started (#{Exception.message(error)}). " <>
           @install_hint
       )}
  end

  defp collect(port, chunks, size, deadline) do
    receive do
      {^port, {:data, data}} ->
        size = size + byte_size(data)

        if size > @max_response_bytes do
          close(port)

          {:error,
           failure(
             :ax_failure,
             "Seshat's Accessibility helper returned more data than its protocol allows. " <>
               @install_hint
           )}
        else
          collect(port, [data | chunks], size, deadline)
        end

      # The exit status is required, not optional: it is the second half of the
      # protocol, and a reply whose status disagrees with its own `ok` flag is
      # treated as malformed rather than believed.
      {^port, {:exit_status, status}} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary() |> decode(status)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        close(port)

        {:error,
         failure(
           :timeout,
           "Ableton Live's audio settings did not answer in time, so nothing is known to have " <>
             "changed. Check that Live is running and not showing a dialog, then try again."
         )}
    end
  end

  # Closing the port closes our end; the helper's own 4-second deadline is what
  # ends the process itself, so a hung helper cannot outlive it either way.
  defp close(port) do
    if Port.info(port), do: Port.close(port)

    :ok
  end

  defp decode("", _status), do: {:error, malformed()}

  defp decode(body, status) do
    case Jason.decode(String.trim(body)) do
      {:ok, %{"protocol_version" => @protocol_version} = payload} ->
        interpret(payload, status)

      {:ok, %{"protocol_version" => other}} ->
        {:error,
         failure(
           :version_mismatch,
           "The installed Accessibility helper speaks protocol version #{inspect(other)}, but " <>
             "this version of Seshat expects #{@protocol_version}. Run `mix ax.install` to " <>
             "rebuild it."
         )}

      _ ->
        {:error, malformed()}
    end
  end

  defp interpret(%{"ok" => true} = payload, 0) do
    {:ok,
     %{
       current: payload["current"],
       devices: payload["devices"],
       previous: payload["previous"],
       trusted: payload["trusted"],
       elapsed_ms: payload["elapsed_ms"]
     }}
  end

  defp interpret(%{"ok" => false} = payload, status) when status != 0 do
    code = Map.get(@codes, payload["code"], :ax_failure)

    {:error,
     %{
       code: code,
       message: message(code, payload["message"]),
       devices: strings(payload["devices"]),
       current: string(payload["current"])
     }}
  end

  defp interpret(_payload, _status), do: {:error, malformed()}

  # --- Rendering ---

  # The codes Seshat can say something more useful about than the helper can get
  # their wording here; the rest carry the helper's own sentence, which already
  # names the specific thing that failed (a device, the Settings window).
  defp message(:permission_required, _native) do
    "macOS has not granted Seshat's Accessibility helper permission to control Ableton Live. " <>
      @install_hint
  end

  defp message(:live_not_running, _native) do
    "Ableton Live isn't running, so its audio settings can't be reached. Start Live and try again."
  end

  defp message(:timeout, native) do
    (native || "Ableton Live's audio settings did not respond in time.") <>
      " Nothing is known to have changed."
  end

  defp message(_code, native) when is_binary(native), do: native

  defp message(_code, _native) do
    "Ableton Live's audio settings could not be reached through macOS Accessibility."
  end

  defp malformed do
    failure(
      :ax_failure,
      "Seshat's Accessibility helper gave an unreadable answer. " <> @install_hint
    )
  end

  defp failure(code, message),
    do: %{code: code, message: message, devices: nil, current: nil}

  defp strings(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: values, else: nil
  end

  defp strings(_values), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  # Plumbing timings, at plumbing volume: this is the record that decides
  # whether a persistent Port is ever worth building, and it is deliberately not
  # something the model is invited to read back to the user.
  defp log(operation, {:ok, payload}, elapsed) do
    Logger.info(
      "AX #{operation} ok in #{elapsed}ms (helper reported #{inspect(payload[:elapsed_ms])}ms)"
    )
  end

  defp log(operation, {:error, %{code: code}}, elapsed) do
    Logger.info("AX #{operation} failed with #{code} in #{elapsed}ms")
  end
end
