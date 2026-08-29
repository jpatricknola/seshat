defmodule Seshat.Generation.Backend do
  @moduledoc """
  The boundary between Seshat's audio-generation workflow and whatever renders
  the audio.

  `Seshat.Generation.AudioClip` owns everything that touches Live: the session
  read, the duration arithmetic, the target guards, the reserved filename, the
  import and the read-back. A backend owns one job — turn a
  `Seshat.Generation.Spec` into a finished file at `spec.out_path` — and it is
  the only part of the feature that has to be replaced to change model, runtime
  or provider.

  That split is why the workflow is testable at all: `mix test` installs
  `Seshat.Test.FakeGenerationBackend` and never starts a subprocess, never
  loads model weights and never needs the user's runtime, while
  `Seshat.Generation.StableAudio` gets its own tests against a throwaway
  executable that plays the runtime's part.

  ## Selection is compile-time, configuration is not

  `impl/0` reads `:generation_backend` through `Application.compile_env/3`: the
  implementation is a structural choice, fixed per environment, and a module
  swapped at runtime would let one test's fake leak into another's real
  adapter. Paths and timeouts are read at runtime instead
  (`Seshat.Generation.StableAudio`), because a test legitimately does need to
  point the adapter at a fixture and shorten its deadline.
  """

  alias Seshat.Generation.Spec

  @impl_module Application.compile_env(
                 :seshat,
                 :generation_backend,
                 Seshat.Generation.StableAudio
               )

  @typedoc """
  What a finished render reports back.

  `path` is `spec.out_path` — restated rather than assumed, so a backend that
  wrote somewhere else is caught by the caller instead of silently importing
  nothing. `seed` is the seed actually used, and `wall_ms` is how long the
  render took, which the tool reply names so a user can tell a cold start from
  a warm one.
  """
  @type result :: %{path: String.t(), seed: integer(), wall_ms: non_neg_integer()}

  @doc """
  Render `spec` to `spec.out_path`.

  `{:error, message}` carries a sentence a tool reply can show as-is: the
  backend is the only layer that knows whether a runtime is missing, a weight
  is absent, or a render exited non-zero.
  """
  @callback generate(Spec.t()) :: {:ok, result()} | {:error, String.t()}

  @doc """
  The configured backend module.
  """
  @spec impl() :: module()
  def impl, do: @impl_module
end
