defmodule Seshat.Generation.Result do
  @moduledoc """
  What one successful `Seshat.Generation.AudioClip.generate/1` produced.

  Deliberately a record of *observations* rather than intentions. The requested
  half (`bars`, `beats`, `seconds`, `tempo`, the key hint) is what Seshat asked
  for; the `observed` half is what Live said afterwards when the clip was read
  back. `Seshat.Tools.Handlers` renders both and never merges them, because the
  whole honesty claim of this feature is that the raw render's relationship to
  Live's grid is reported, not asserted.

  `key` is the session's key at generation time, folded into the prompt as a
  soft hint. Nothing verifies the audio is in it, so it is reported as
  requested, never as a property of the file.
  """

  @type observed :: %{
          name: String.t() | nil,
          length: number() | nil,
          looping: boolean() | nil,
          warping: boolean() | nil,
          file_path: String.t() | nil
        }

  @type t :: %__MODULE__{
          track: non_neg_integer(),
          track_name: String.t() | nil,
          created_track?: boolean(),
          clip_slot: non_neg_integer(),
          clip_name: String.t(),
          bars: pos_integer(),
          beats: float(),
          seconds: float(),
          target_frames: non_neg_integer(),
          tempo: float(),
          time_sig_numerator: pos_integer(),
          time_sig_denominator: pos_integer(),
          key: String.t() | nil,
          file: String.t(),
          path: String.t(),
          seed: integer(),
          wall_ms: non_neg_integer(),
          variation:
            %{track: non_neg_integer(), clip_slot: non_neg_integer(), strength: float()} | nil,
          observed: observed()
        }

  @enforce_keys [
    :track,
    :clip_slot,
    :clip_name,
    :bars,
    :beats,
    :seconds,
    :target_frames,
    :tempo,
    :time_sig_numerator,
    :time_sig_denominator,
    :file,
    :path,
    :seed,
    :wall_ms,
    :observed
  ]
  defstruct track: nil,
            track_name: nil,
            created_track?: false,
            clip_slot: nil,
            clip_name: nil,
            bars: nil,
            beats: nil,
            seconds: nil,
            target_frames: nil,
            tempo: nil,
            time_sig_numerator: nil,
            time_sig_denominator: nil,
            key: nil,
            file: nil,
            path: nil,
            seed: nil,
            wall_ms: nil,
            variation: nil,
            observed: %{}
end
