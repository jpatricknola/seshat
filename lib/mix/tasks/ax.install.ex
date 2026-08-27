defmodule Mix.Tasks.Ax.Install do
  @moduledoc """
  Builds and installs `seshat-ax`, Seshat's macOS Accessibility helper.

  Seshat reaches Ableton Live over OSC. Live's application-wide audio *device*
  preference is not in the Live Object Model, so the two audio-output tools go
  through the macOS Accessibility API instead — and the BEAM cannot call it. This
  task compiles `native/seshat_ax/main.m` and installs the result at a stable
  path, which is the whole reason the path is stable: macOS attaches
  Accessibility trust to the executable, and a helper that moved would have to be
  re-approved every time.

  ## Usage

      mix ax.install                              # build, install, prompt for permission
      mix ax.install --no-prompt                  # build and install, never open System Settings
      mix ax.install --destination /tmp/seshat-ax # build somewhere else (CI, verification)

  macOS only. It is deliberately *not* part of `mix compile` or the Linux CI job:
  ordinary Elixir compilation stays cross-platform and must never make a privacy
  prompt appear.

  ## Permission is one-time onboarding

  Granting Accessibility access needs neither a Live restart nor a Seshat
  restart (measured 2026-08-03). Run this task once, approve `seshat-ax` under
  System Settings > Privacy & Security > Accessibility, and the audio-output
  tools work from then on. Until then they fail immediately with an instruction
  naming this task — they never open System Settings behind your back.

  The spike observed trust surviving repeated recompiles at one stable path, but
  this task does not assume it: after replacing the executable it asks the helper
  whether it is still trusted and tells you if it is not.

  ## Building is atomic

  Compilation writes a sibling temporary file and renames it over the installed
  helper only on success, so a failed build leaves the working helper — and its
  granted permission — exactly where they were.
  """

  use Mix.Task

  @shortdoc "Build and install Seshat's macOS Accessibility helper"

  @source Path.join(["native", "seshat_ax", "main.m"])
  @default_destination "~/.seshat/bin/seshat-ax"

  # The same warnings-as-errors command the macOS CI job runs. ARC because the
  # helper mixes Objective-C objects with CoreFoundation AX references, and the
  # two frameworks because that is the whole of its dependency surface — no
  # Swift toolchain (the installed Swift compiler and SDK were mismatched during
  # the spike while clang compiled the same API without complaint).
  @clang_flags ~w(-fobjc-arc -Wall -Wextra -Werror -O2)
  @frameworks ~w(-framework AppKit -framework ApplicationServices)

  @switches [prompt: :boolean, destination: :string]

  @impl Mix.Task
  def run(args) do
    {options, _rest} = OptionParser.parse!(args, strict: @switches)

    ensure_macos!()

    source = Path.expand(@source, File.cwd!())
    unless File.regular?(source), do: Mix.raise("Cannot find the helper source at #{source}.")

    destination = Path.expand(options[:destination] || @default_destination)
    File.mkdir_p!(Path.dirname(destination))

    compile!(source, destination)
    Mix.shell().info("Installed #{destination}")

    report_permission(destination, Keyword.get(options, :prompt, true))
  end

  defp ensure_macos! do
    unless match?({:unix, :darwin}, :os.type()) do
      Mix.raise("""
      mix ax.install is macOS-only — it builds an Accessibility helper against AppKit.

      Seshat itself is cross-platform to compile and test; only the two
      audio-output tools need this helper, and only macOS has the API they use.
      """)
    end
  end

  defp compile!(source, destination) do
    temporary = destination <> ".build-#{System.unique_integer([:positive])}"

    arguments = @clang_flags ++ @frameworks ++ ["-o", temporary, source]

    Mix.shell().info("Compiling #{source}")

    case System.cmd("/usr/bin/clang", arguments, stderr_to_stdout: true) do
      {_output, 0} ->
        # Rename over the installed helper only now: a failed build must leave
        # the working, already-authorised executable untouched.
        File.rename!(temporary, destination)

      {output, status} ->
        File.rm(temporary)

        Mix.raise("""
        clang failed (exit #{status}) and nothing was installed:

        #{output}
        """)
    end
  end

  defp report_permission(destination, prompt?) do
    arguments = if prompt?, do: ["permission", "--prompt"], else: ["permission"]

    {output, _status} = System.cmd(destination, arguments, stderr_to_stdout: true)

    if trusted?(output) do
      Mix.shell().info("macOS trusts this helper for Accessibility control - nothing else to do.")
    else
      Mix.shell().info("""

      This helper is not yet trusted for Accessibility control.

      Open System Settings, choose Privacy & Security, then Accessibility, and
      turn on the entry for:

          #{destination}

      Neither Ableton Live nor Seshat needs restarting afterwards. Until it is
      granted, get_audio_outputs and set_audio_output fail immediately saying so.
      """)
    end
  end

  # The helper answers `permission` in the same JSON protocol everything else
  # uses, so this reads the flag rather than the exit status.
  defp trusted?(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"trusted" => trusted}} -> trusted == true
      _ -> false
    end
  end
end
