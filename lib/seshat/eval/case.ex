defmodule Seshat.Eval.Case do
  @moduledoc """
  One routing case: a fixture, a prompt, and what a good trace looks like — per
  surface.

  Cases are **data** (`priv/routing_eval/cases/*.json`) so the second slice can
  add twenty of them without touching the runner. Expectations are keyed by
  surface because the base surface *cannot* express the head intention in one
  call: `edit_notes` has no equivalent at `c3096d6`, and pretending otherwise
  with a shared abstract expectation would hide the very asymmetry the
  experiment exists to measure.
  """

  alias Seshat.Eval.Fixture

  @enforce_keys [:id, :fixture, :prompt, :expect]
  defstruct [:id, :fixture, :prompt, :expect]

  @type t :: %__MODULE__{
          id: String.t(),
          fixture: String.t(),
          prompt: String.t(),
          expect: %{String.t() => map()}
        }

  @doc "Every case under `priv/routing_eval/cases/`, sorted by id."
  @spec load_all() :: [t()]
  def load_all do
    "routing_eval/cases/*.json"
    |> Fixture.path()
    |> Path.wildcard()
    |> Enum.map(&load!/1)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Loads one case file."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    map = path |> File.read!() |> Jason.decode!()

    %__MODULE__{
      id: map["id"] || Path.basename(path, ".json"),
      fixture: Map.fetch!(map, "fixture"),
      prompt: Map.fetch!(map, "prompt"),
      expect: Map.fetch!(map, "expect")
    }
  end

  @doc """
  The expectation for a surface id, and the key it was found under.

  `"head"` matches directly; `"base-c3096d6"` falls back to `"base"`, so a
  second base snapshot at another revision reuses the same expectations without
  every case file being edited.
  """
  @spec expectation(t(), String.t()) :: {String.t(), map()}
  def expectation(%__MODULE__{expect: expect, id: id}, surface_id) do
    family = surface_id |> String.split("-") |> List.first()

    cond do
      Map.has_key?(expect, surface_id) -> {surface_id, expect[surface_id]}
      Map.has_key?(expect, family) -> {family, expect[family]}
      true -> raise ArgumentError, "case #{id} has no expectation for surface #{surface_id}"
    end
  end
end
