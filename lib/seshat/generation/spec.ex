defmodule Seshat.Generation.Spec do
  @moduledoc """
  One audio-generation request, as the backend boundary sees it.

  Everything musical has already been decided by the time a `Spec` exists:
  `Seshat.Generation.AudioClip` has read the session, turned bars into seconds,
  folded tempo/signature/key into `prompt`, and reserved `out_path` inside the
  managed root. A backend renders exactly what it is given and writes exactly
  where it is told — it never consults `Seshat.Session.State`, never picks a
  filename, and never decides how long the audio is.

  `seed` is deliberately not optional. The adapter always passes it to the
  runtime, so the take's seed is known here rather than scraped back out of the
  runtime's stdout, and the reply can name it without parsing anything.

  `init_audio` and `init_noise_level` travel together: both `nil` for a
  text-to-audio render, both set for a variation of an existing take.
  """

  @type t :: %__MODULE__{
          prompt: String.t(),
          negative_prompt: String.t() | nil,
          seconds: float(),
          seed: integer(),
          init_audio: String.t() | nil,
          init_noise_level: float() | nil,
          out_path: String.t()
        }

  @enforce_keys [:prompt, :seconds, :seed, :out_path]
  defstruct prompt: nil,
            negative_prompt: nil,
            seconds: nil,
            seed: nil,
            init_audio: nil,
            init_noise_level: nil,
            out_path: nil

  @doc """
  True when this spec asks the runtime to vary an existing recording.

  One predicate rather than two `nil` checks at each site: the variation lane
  needs a different encoder weight preflighted and two extra flags, and both
  decisions have to agree.
  """
  @spec variation?(t()) :: boolean()
  def variation?(%__MODULE__{init_audio: nil}), do: false
  def variation?(%__MODULE__{init_audio: path}) when is_binary(path), do: true
end
