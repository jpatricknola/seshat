defmodule Seshat.Eval.ReportTest do
  use ExUnit.Case, async: true

  alias Seshat.Eval.Report

  defp verdict(overrides) do
    Map.merge(
      %{
        "semantic_success" => true,
        "correct_target_first_mutation" => true,
        "first_call_valid" => true,
        "first_mutation_valid" => true,
        "all_calls_valid" => true,
        "mutation_count" => 2,
        "read_count" => 1,
        "view_count" => 0,
        "tool_errors" => 0,
        "void_reason" => nil,
        "calls" => [
          %{
            "seq" => 1,
            "name" => "set_mixer",
            "arguments" => %{"target" => "master"},
            "is_error" => false,
            "schema_valid" => true
          }
        ]
      },
      overrides
    )
  end

  defp trial(surface, index, overrides \\ %{}, model \\ "m01") do
    %{
      "case" => "mixer_master_and_return",
      "model_key" => model,
      "model" => "claude-sonnet-5",
      "surface" => surface,
      "index" => index,
      "verdict" => verdict(overrides)
    }
  end

  defp run(trials, requested \\ 2) do
    %{
      "stamp" => "2026-08-28T12:00:00Z",
      "cli_version" => "2.1.220 (Claude Code)",
      "lane_prompt_hash" => "abcdef123456",
      "trials_requested" => requested,
      "surfaces" => [
        %{
          "id" => "head",
          "revision" => "3d3329e",
          "tool_count" => 52,
          "digest" => String.duplicate("a", 64)
        },
        %{
          "id" => "base-c3096d6",
          "revision" => "c3096d6",
          "tool_count" => 67,
          "digest" => String.duplicate("b", 64)
        }
      ],
      "models" => [
        %{"key" => "m01", "name" => "claude-sonnet-5", "reported" => "claude-sonnet-5"}
      ],
      "trials" => trials
    }
  end

  test "the header names the CLI, the lane and every surface's contract" do
    markdown = Report.markdown(run([trial("head", 1), trial("base-c3096d6", 1)], 1))

    assert markdown =~ "Claude Code CLI: `2.1.220 (Claude Code)`"
    assert markdown =~ "Lane prompt hash: `abcdef123456`"
    assert markdown =~ "`head` — revision `3d3329e`, 52 tools, contract sha256 `aaaaaaaaaaaa`"
    assert markdown =~ "`base-c3096d6` — revision `c3096d6`, 67 tools"
    assert markdown =~ "requested `claude-sonnet-5`, reported by init as `claude-sonnet-5`"
  end

  test "rates are computed over the valid trials only" do
    trials = [
      trial("head", 1),
      trial("head", 2, %{"semantic_success" => false}),
      trial("base-c3096d6", 1),
      trial("base-c3096d6", 2)
    ]

    markdown = Report.markdown(run(trials))

    assert markdown =~ "| `m01` | `head` | 2 | 0 | 50% |"
    assert markdown =~ "| `m01` | `base-c3096d6` | 2 | 0 | 100% |"
  end

  # A run that threw away trials must not read like a run of the ones that
  # survived.
  test "void trials are excluded from the rates, listed, and make the case inconclusive" do
    trials = [
      trial("head", 1),
      trial("head", 2, %{"void_reason" => "settings leaked: init reported plugins"}),
      trial("base-c3096d6", 1),
      trial("base-c3096d6", 2)
    ]

    markdown = Report.markdown(run(trials))

    assert markdown =~ "| `m01` | `head` | 1 | 1 |"
    assert markdown =~ "**inconclusive** (fewer than 2 valid trials: `m01` on `head`)"
    assert markdown =~ "## Void trials"
    assert markdown =~ "settings leaked"
  end

  test "a fully valid run is marked scored and reports no void trials" do
    markdown = Report.markdown(run([trial("head", 1), trial("base-c3096d6", 1)], 1))

    assert markdown =~ "## Case `mixer_master_and_return` — scored"
    assert markdown =~ "None — every trial was isolated as the contract requires."
  end

  # The gate is "head must not regress on any model", so the panel row takes the
  # worst model rather than the average.
  test "the panel row is the worst model, not the mean" do
    trials = [
      trial("head", 1, %{}, "m01"),
      trial("head", 1, %{"semantic_success" => false}, "m02")
    ]

    run =
      run(trials, 1)
      |> Map.put("models", [
        %{"key" => "m01", "name" => "claude-sonnet-5"},
        %{"key" => "m02", "name" => "claude-opus-5"}
      ])

    markdown = Report.markdown(run)

    assert markdown =~ "| **panel (worst)** | `head` | 2 | 0 | 0% |"
  end

  test "every observed call is listed with its arguments and its flags" do
    trials = [
      trial("head", 1, %{
        "calls" => [
          %{
            "seq" => 1,
            "name" => "set_mixer",
            "arguments" => %{"target" => "master", "volume" => 2.0},
            "is_error" => true,
            "schema_valid" => false
          }
        ]
      })
    ]

    markdown = Report.markdown(run(trials, 1))

    assert markdown =~ "## Every observed call"
    assert markdown =~ ~s(`set_mixer` {"target":"master","volume":2.0})
    assert markdown =~ "error, schema-invalid"
  end

  test "a trial with no calls says so rather than rendering an empty list" do
    markdown = Report.markdown(run([trial("head", 1, %{"calls" => []})], 1))

    assert markdown =~ "(no tool calls)"
  end

  test "json/1 round trips the run" do
    run = run([trial("head", 1)], 1)

    assert Jason.decode!(Report.json(run)) == run
  end
end
