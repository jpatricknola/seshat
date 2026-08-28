defmodule Seshat.Eval.CaseTest do
  use ExUnit.Case, async: true

  alias Seshat.Eval.Case, as: EvalCase
  alias Seshat.Eval.Fixture
  alias Seshat.Eval.Surface

  @base_path Path.expand("../../../priv/routing_eval/surfaces/base-c3096d6.json", __DIR__)

  test "both seed cases load with a fixture that exists and an expectation per surface" do
    cases = EvalCase.load_all()

    assert Enum.map(cases, & &1.id) == ["mixer_master_and_return", "note_third_quieter"]

    for eval_case <- cases do
      assert %Fixture{} = Fixture.load!(eval_case.fixture)
      assert Map.keys(eval_case.expect) |> Enum.sort() == ["base", "head"]
      assert eval_case.prompt != ""
    end
  end

  # `base-c3096d6` falls back to `base`, so a second base snapshot at another
  # revision reuses the expectations rather than making every case file grow a
  # near-duplicate key.
  test "a surface id falls back to its family" do
    eval_case = EvalCase.load_all() |> hd()

    assert {"head", head} = EvalCase.expectation(eval_case, "head")
    assert {"base", base} = EvalCase.expectation(eval_case, "base-c3096d6")

    refute head == base
  end

  test "a surface with no expectation raises rather than scoring against nothing" do
    eval_case = EvalCase.load_all() |> hd()

    assert_raise ArgumentError, ~r/no expectation for surface/, fn ->
      EvalCase.expectation(eval_case, "some-other-branch")
    end
  end

  # A case naming a tool its surface never published would silently never match,
  # which reads in the report as the model failing rather than the case being
  # wrong.
  test "every expected tool exists on the surface it is expected on" do
    surfaces = %{"head" => Surface.current("test"), "base" => Surface.load!(@base_path)}

    for eval_case <- EvalCase.load_all(),
        {family, expectation} <- eval_case.expect,
        entry <-
          expectation["calls"] ++ Enum.map(expectation["must_not_call"] || [], &%{"tool" => &1}) do
      surface = Map.fetch!(surfaces, family)

      assert entry["tool"] in Surface.tool_names(surface),
             "#{eval_case.id}/#{family} expects #{entry["tool"]}, which #{surface.id} does not publish"
    end
  end
end
