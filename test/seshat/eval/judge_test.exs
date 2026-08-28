defmodule Seshat.Eval.JudgeTest do
  use ExUnit.Case, async: true

  alias Seshat.Eval.Case, as: EvalCase
  alias Seshat.Eval.Fixture
  alias Seshat.Eval.Judge
  alias Seshat.Eval.Surface

  @cases Path.expand("../../../priv/routing_eval/cases", __DIR__)
  @base_path Path.expand("../../../priv/routing_eval/surfaces/base-c3096d6.json", __DIR__)

  setup do
    {:ok,
     fixture: Fixture.load!("named_tracks_and_reverb"),
     head: Surface.current("test"),
     base: Surface.load!(@base_path)}
  end

  defp eval_case(id), do: EvalCase.load!(Path.join(@cases, "#{id}.json"))

  defp call(name, arguments, opts \\ []) do
    %{
      "seq" => Keyword.get(opts, :seq, 1),
      "name" => name,
      "arguments" => arguments,
      "is_error" => Keyword.get(opts, :is_error, false),
      "schema_valid" => Keyword.get(opts, :schema_valid, true)
    }
  end

  defp judge(id, surface_key, trace, context) do
    eval_case = eval_case(id)
    {_key, expectation} = EvalCase.expectation(eval_case, surface_key)

    Judge.judge(
      eval_case,
      expectation,
      Map.merge(%{trace: trace, final_text: nil, void_reason: nil}, context)
    )
  end

  describe "mixer_master_and_return on head" do
    test "the ideal trace passes", context do
      trace = [
        call("get_session_state", %{}, seq: 1),
        call("set_mixer", %{"target" => "master", "volume" => 0.78}, seq: 2),
        call("set_mixer", %{"target" => "return", "track" => 0, "mute" => true}, seq: 3)
      ]

      verdict =
        judge("mixer_master_and_return", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      assert verdict["semantic_success"]
      assert verdict["first_call_valid"]
      assert verdict["first_mutation_valid"]
      assert verdict["all_calls_valid"]
      assert verdict["correct_target_first_mutation"]
      assert verdict["read_count"] == 1
      assert verdict["view_count"] == 0
      assert verdict["mutation_count"] == 2
      assert verdict["extra_mutations"] == 0
      assert verdict["tool_errors"] == 0
    end

    test "muting the wrong return fails", context do
      trace = [
        call("set_mixer", %{"target" => "master", "volume" => 0.78}, seq: 1),
        call("set_mixer", %{"target" => "return", "track" => 1, "mute" => true}, seq: 2)
      ]

      verdict =
        judge("mixer_master_and_return", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      refute verdict["semantic_success"]
      # The malformed-vs-misaimed distinction the two columns exist for.
      assert verdict["first_mutation_valid"]
      assert verdict["correct_target_first_mutation"]
    end

    test "a third mutation blows the budget", context do
      trace = [
        call("set_mixer", %{"target" => "master", "volume" => 0.78}, seq: 1),
        call("set_mixer", %{"target" => "return", "track" => 0, "mute" => true}, seq: 2),
        call("set_mixer", %{"target" => "track", "track" => 0, "volume" => 0.5}, seq: 3)
      ]

      verdict =
        judge("mixer_master_and_return", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      refute verdict["semantic_success"]
      assert verdict["extra_mutations"] == 1
    end

    # `Seshat.Instructions` teaches the model to show a pane before a
    # view-specific action, so a `show_view` must never cost it the budget.
    test "a view call is neither a read nor a mutation", context do
      trace = [
        call("show_view", %{"view" => "Session"}, seq: 1),
        call("set_mixer", %{"target" => "master", "volume" => 0.78}, seq: 2),
        call("set_mixer", %{"target" => "return", "track" => 0, "mute" => true}, seq: 3)
      ]

      verdict =
        judge("mixer_master_and_return", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      assert verdict["semantic_success"]
      assert verdict["view_count"] == 1
      assert verdict["mutation_count"] == 2
    end

    test "a volume above the fixture's master is not 'down a touch'", context do
      trace = [
        call("set_mixer", %{"target" => "master", "volume" => 0.9}, seq: 1),
        call("set_mixer", %{"target" => "return", "track" => 0, "mute" => true}, seq: 2)
      ]

      verdict =
        judge("mixer_master_and_return", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      refute verdict["semantic_success"]
      refute verdict["correct_target_first_mutation"]
    end

    test "a refused call fails no_tool_errors", context do
      trace = [
        call("set_mixer", %{"target" => "master", "volume" => 2.0},
          seq: 1,
          is_error: true,
          schema_valid: false
        ),
        call("set_mixer", %{"target" => "master", "volume" => 0.78}, seq: 2),
        call("set_mixer", %{"target" => "return", "track" => 0, "mute" => true}, seq: 3)
      ]

      verdict =
        judge("mixer_master_and_return", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      refute verdict["semantic_success"]
      refute verdict["first_call_valid"]
      refute verdict["first_mutation_valid"]
      refute verdict["all_calls_valid"]
      assert verdict["tool_errors"] == 1
    end
  end

  describe "mixer_master_and_return on base" do
    # Pins the historical parameter names, which is the only remaining record of
    # them once `Definitions` has moved on.
    test "the ideal 67-tool trace passes", context do
      trace = [
        call("get_session_state", %{}, seq: 1),
        call("set_master_volume", %{"value" => 0.78}, seq: 2),
        call("set_return_track_mute", %{"return_track" => 0, "muted" => true}, seq: 3)
      ]

      verdict =
        judge("mixer_master_and_return", "base-c3096d6", trace, %{
          fixture: context.fixture,
          surface: context.base
        })

      assert verdict["semantic_success"]
      assert verdict["correct_target_first_mutation"]
      assert verdict["mutation_count"] == 2
    end

    test "reaching for the head name that does not exist yet fails", context do
      trace = [
        call("set_mixer", %{"target" => "master", "volume" => 0.78},
          seq: 1,
          is_error: true,
          schema_valid: false
        )
      ]

      verdict =
        judge("mixer_master_and_return", "base-c3096d6", trace, %{
          fixture: context.fixture,
          surface: context.base
        })

      refute verdict["semantic_success"]
      assert verdict["tool_errors"] == 1
    end
  end

  describe "note_third_quieter on head" do
    test "one edit_notes windowed onto the third note passes", context do
      trace = [
        call("get_clip_notes", %{"track" => 1}, seq: 1),
        call(
          "edit_notes",
          %{
            "track" => 1,
            "start_pitch" => 39,
            "pitch_span" => 1,
            "start_time" => 2.0,
            "time_span" => 1.0,
            "velocity" => 80
          },
          seq: 2
        )
      ]

      verdict =
        judge("note_third_quieter", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      assert verdict["semantic_success"]
      assert verdict["correct_target_first_mutation"]
      assert verdict["mutation_count"] == 1
    end

    test "a negative velocity_delta counts as quieter too", context do
      trace = [
        call("get_clip_notes", %{"track" => 1}, seq: 1),
        call(
          "edit_notes",
          %{
            "track" => 1,
            "start_time" => 2.0,
            "time_span" => 1.0,
            "velocity_delta" => -20
          },
          seq: 2
        )
      ]

      verdict =
        judge("note_third_quieter", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      assert verdict["semantic_success"]
    end

    # The whole point of the fixture's note layout: the third note is unique by
    # pitch *and* by start, so a sloppy window is detectable.
    test "a window that also catches the fourth note fails", context do
      trace = [
        call("get_clip_notes", %{"track" => 1}, seq: 1),
        call(
          "edit_notes",
          %{"track" => 1, "start_time" => 2.0, "time_span" => 2.0, "velocity" => 80},
          seq: 2
        )
      ]

      verdict =
        judge("note_third_quieter", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      refute verdict["semantic_success"]
      refute verdict["correct_target_first_mutation"]
    end

    test "delete-then-rewrite fails on must_not_call and the mutation budget", context do
      trace = [
        call("get_clip_notes", %{"track" => 1}, seq: 1),
        call(
          "edit_notes",
          %{"track" => 1, "start_time" => 2.0, "time_span" => 1.0, "delete" => true},
          seq: 2
        ),
        call(
          "write_midi_notes",
          %{
            "track" => 1,
            "notes" => [
              %{"pitch" => 39, "start_beat" => 2.0, "duration" => 1.0, "velocity" => 80}
            ]
          },
          seq: 3
        )
      ]

      verdict =
        judge("note_third_quieter", "head", trace, %{
          fixture: context.fixture,
          surface: context.head
        })

      refute verdict["semantic_success"]
      assert verdict["forbidden_calls"] == ["write_midi_notes"]
      assert verdict["extra_mutations"] == 1
    end
  end

  describe "note_third_quieter on base" do
    test "the read-delete-rewrite the 67-tool surface forces passes", context do
      trace = [
        call("get_clip_notes", %{"track" => 1}, seq: 1),
        call(
          "remove_notes",
          %{
            "track" => 1,
            "start_pitch" => 39,
            "pitch_span" => 1,
            "start_time" => 2.0,
            "time_span" => 1.0
          },
          seq: 2
        ),
        call(
          "write_midi_notes",
          %{
            "track" => 1,
            "notes" => [
              %{"pitch" => 39, "start_beat" => 2.0, "duration" => 1.0, "velocity" => 80}
            ]
          },
          seq: 3
        )
      ]

      verdict =
        judge("note_third_quieter", "base-c3096d6", trace, %{
          fixture: context.fixture,
          surface: context.base
        })

      assert verdict["semantic_success"]
      assert verdict["mutation_count"] == 2
    end

    test "rewriting the note louder is not 'quieter'", context do
      trace = [
        call("get_clip_notes", %{"track" => 1}, seq: 1),
        call(
          "remove_notes",
          %{
            "track" => 1,
            "start_pitch" => 39,
            "pitch_span" => 1,
            "start_time" => 2.0,
            "time_span" => 1.0
          },
          seq: 2
        ),
        call(
          "write_midi_notes",
          %{
            "track" => 1,
            "notes" => [
              %{"pitch" => 39, "start_beat" => 2.0, "duration" => 1.0, "velocity" => 120}
            ]
          },
          seq: 3
        )
      ]

      verdict =
        judge("note_third_quieter", "base-c3096d6", trace, %{
          fixture: context.fixture,
          surface: context.base
        })

      refute verdict["semantic_success"]
    end
  end

  describe "reporting flags" do
    test "an empty trace fails everything without raising", context do
      verdict =
        judge("mixer_master_and_return", "head", [], %{
          fixture: context.fixture,
          surface: context.head
        })

      refute verdict["semantic_success"]
      refute verdict["first_call_valid"]
      refute verdict["first_mutation_valid"]
      refute verdict["all_calls_valid"]
      assert verdict["mutation_count"] == 0
    end

    test "claimed inability is a flag, never a fail on its own", context do
      trace = [
        call("set_mixer", %{"target" => "master", "volume" => 0.78}, seq: 1),
        call("set_mixer", %{"target" => "return", "track" => 0, "mute" => true}, seq: 2)
      ]

      verdict =
        judge("mixer_master_and_return", "head", trace, %{
          fixture: context.fixture,
          surface: context.head,
          final_text: "I can't reach the reverb's own dry/wet, but the return is muted."
        })

      assert verdict["claimed_inability"]
      assert verdict["semantic_success"]
    end

    test "the void reason is carried through", context do
      verdict =
        judge("mixer_master_and_return", "head", [], %{
          fixture: context.fixture,
          surface: context.head,
          void_reason: "settings leaked: init reported plugins"
        })

      assert verdict["void_reason"] =~ "settings leaked"
    end
  end

  describe "the matcher vocabulary is closed" do
    test "an unknown operator key raises rather than silently passing", context do
      entry = %{"tool" => "set_mixer", "where" => %{"volume" => %{"lte" => 0.8, "gt" => 0.1}}}

      assert_raise ArgumentError, ~r/mixes matcher operators/, fn ->
        Judge.matches_entry?(
          call("set_mixer", %{"volume" => 0.5}),
          entry,
          context.fixture
        )
      end
    end

    test "a fixture path that does not resolve raises", context do
      entry = %{
        "tool" => "set_mixer",
        "where" => %{"volume" => %{"lt" => %{"fixture" => "master.gain"}}}
      }

      assert_raise ArgumentError, ~r/no key "gain"/, fn ->
        Judge.matches_entry?(call("set_mixer", %{"volume" => 0.5}), entry, context.fixture)
      end
    end

    test "fixture paths reach into clip notes by index", context do
      assert %{"pitch" => 39, "start_time" => 2.0} =
               Judge.deref!(%{"fixture" => "clips.1:0.notes[2]"}, context.fixture)

      assert Judge.deref!(%{"fixture" => "master.volume"}, context.fixture) == 0.85
    end
  end
end
