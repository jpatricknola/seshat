defmodule Seshat.Test.FakeGenerationBackend do
  @moduledoc """
  A scripted stand-in for `Seshat.Generation.StableAudio`.

  `config/test.exs` points `:generation_backend` at this module, so the whole
  `Seshat.Generation.AudioClip` workflow — session read, duration arithmetic,
  target guards, filename reservation, import, read-back, steering — runs for
  real without a subprocess, model weights, or the user's runtime.

  Every call is forwarded to the installing process as `{:generate, spec}`, so a
  test can assert what was asked for as well as what came back, and can prove
  that a refusal happened *before* generation by asserting nothing arrived.

  By default the fake behaves like a successful render: it writes a few bytes to
  `spec.out_path` (the workflow checks the file, not the backend's word) and
  reports the spec's own seed. `install/1` overrides that with a fixed reply or
  a function of the spec.
  """

  @behaviour Seshat.Generation.Backend

  @doc """
  Point the fake at a reply for the duration of the test.

  `response` is `{:ok, result}`, `{:error, message}`, or a one-argument function
  taking the `Seshat.Generation.Spec` — the function form is how a test makes
  the fake write a symlink, an empty file, or nothing at all.
  """
  @spec install(term()) :: :ok
  def install(response \\ nil) do
    Application.put_env(:seshat, :fake_generation, %{owner: self(), response: response})

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:seshat, :fake_generation) end)

    :ok
  end

  @impl true
  def generate(spec) do
    config = Application.get_env(:seshat, :fake_generation, %{})

    if owner = config[:owner], do: send(owner, {:generate, spec})

    case config[:response] do
      nil -> default_render(spec)
      fun when is_function(fun, 1) -> fun.(spec)
      response -> response
    end
  end

  defp default_render(spec) do
    File.write!(spec.out_path, "RIFF fake wav")

    {:ok, %{path: spec.out_path, seed: spec.seed, wall_ms: 1_100}}
  end
end
