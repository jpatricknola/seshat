defmodule Seshat.Eval.Trial do
  @moduledoc """
  One headless model run, parsed out of the client's `stream-json` output.

  A trial is the unit everything downstream counts: `Seshat.Eval.Judge` scores
  it, `Seshat.Eval.Report` aggregates it. It deliberately keeps the raw `init`
  and `result` events rather than a digest of them, because the isolation checks
  (`Seshat.Eval.Stream.void_reason/2`) read fields no scoring rule cares about,
  and a run whose isolation cannot be re-checked from what was written down is a
  run nobody can defend later.

  `thinking` blocks are never stored: they are dropped in the parser, before
  anything writes to disk.
  """

  defstruct init: nil,
            result: nil,
            final_text: nil,
            calls: [],
            results: [],
            hook_events: [],
            rate_limits: []

  @type call :: %{id: String.t() | nil, name: String.t(), input: map()}

  @type t :: %__MODULE__{
          init: map() | nil,
          result: map() | nil,
          final_text: String.t() | nil,
          calls: [call()],
          results: [map()],
          hook_events: [map()],
          rate_limits: [map()]
        }
end
