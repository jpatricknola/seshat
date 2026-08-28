defmodule Mix.Tasks.Routing.Eval do
  @shortdoc "Runs the conversation-routing evaluation against committed surface snapshots"

  @moduledoc """
  Sends each committed case's prompt through a fresh headless Claude Code, once
  per surface, per model, per trial, and scores the resulting traces.

      mix routing.eval
      mix routing.eval --case mixer_master_and_return --trials 3
      mix routing.eval --surface head --model claude-opus-5

  Defaults: both surfaces (`head` plus every snapshot in
  `priv/routing_eval/surfaces/`), every case, five trials, and a model panel of
  `claude-sonnet-5` and `claude-opus-5`. `--model` repeats.

  **On demand only.** It is externally metered, stochastic and takes minutes; it
  is deliberately not in `mix precommit` and not on a schedule. Run it when a
  change touches `Seshat.Tools.Definitions`, a tool description or
  `Seshat.Instructions`, and attach `report.md` to the PR.

  ## Interleaving, and why

  Trials run `for trial <- 1..n, case <- cases, model <- models, surface <-
  surfaces`, so base and head see the same hour of the same model. A run split
  by surface would be comparing two different afternoons.

  ## What it refuses to do

  It refuses on a dirty `lib/` or `priv/routing_eval/` — the head surface is
  generated from the checkout, and a snapshot that cannot be tied to a revision
  is not evidence. It refuses when `ANTHROPIC_API_KEY` is set, because the
  contract is subscription auth. It refuses when the CLI is missing. It stops
  the whole run on a rate-limit event that is not `allowed`, naming `resetsAt`,
  rather than grinding out void trials.

  No OSC. Nothing in the eval tree opens a socket, and a test greps for it.
  """

  use Mix.Task

  alias Mix.Tasks.Routing.Eval.Runner
  alias Seshat.Eval.Case, as: EvalCase
  alias Seshat.Eval.Client
  alias Seshat.Eval.Fixture
  alias Seshat.Eval.Judge
  alias Seshat.Eval.Report
  alias Seshat.Eval.Stream, as: EvalStream
  alias Seshat.Eval.Surface

  @default_models ["claude-sonnet-5", "claude-opus-5"]
  @default_trials 5

  @switches [
    surface: :keep,
    case: :keep,
    model: :keep,
    trials: :integer,
    out: :string,
    timeout: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    cli_version = check_cli!()
    check_env!()
    check_clean!()

    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    out = opts[:out] || Fixture.path("routing_eval/runs/#{String.replace(stamp, ":", "")}")
    File.mkdir_p!(out)

    surfaces = load_surfaces(keep(opts, :surface), out)
    cases = load_cases(keep(opts, :case))
    models = models(keep(opts, :model))
    trials = opts[:trials] || @default_trials

    Mix.shell().info(
      "Routing eval: #{length(cases)} case(s) × #{length(surfaces)} surface(s) × " <>
        "#{length(models)} model(s) × #{trials} trial(s) = " <>
        "#{length(cases) * length(surfaces) * length(models) * trials} run(s)"
    )

    results = run_trials(cases, surfaces, models, trials, out, opts)

    run = %{
      "stamp" => stamp,
      "cli_version" => cli_version,
      "lane_prompt_hash" => Client.system_prompt_hash(),
      "trials_requested" => trials,
      "surfaces" =>
        Enum.map(surfaces, fn surface ->
          %{
            "id" => surface.id,
            "revision" => surface.revision,
            "tool_count" => length(surface.tools),
            "digest" => Surface.contract_digest(surface)
          }
        end),
      "models" => reported(models, results),
      "trials" => results
    }

    rendered = Report.markdown(run)
    File.write!(Path.join(out, "report.md"), rendered)
    File.write!(Path.join(out, "report.json"), Report.json(run))

    Mix.shell().info("\nWrote #{Path.join(out, "report.md")}")
    Mix.shell().info(rendered)
  end

  # The model name the CLI actually served, taken from the first trial that
  # reported one — a report that only echoes what was requested cannot show an
  # alias resolving to something else.
  defp reported(models, results) do
    Enum.map(models, fn model ->
      served =
        Enum.find_value(results, fn result ->
          if result["model_key"] == model["key"], do: result["verdict"]["reported_model"]
        end)

      Map.put(model, "reported", served)
    end)
  end

  defp keep(opts, key), do: for({^key, value} <- opts, do: value)

  defp models([]), do: models(@default_models)

  defp models(names) do
    names
    |> Enum.with_index(1)
    |> Enum.map(fn {name, index} ->
      %{"key" => "m#{String.pad_leading(Integer.to_string(index), 2, "0")}", "name" => name}
    end)
  end

  defp load_cases([]), do: EvalCase.load_all()

  defp load_cases(ids) do
    Enum.map(ids, fn id -> EvalCase.load!(Fixture.path("routing_eval/cases/#{id}.json")) end)
  end

  # `head` is generated into the run directory so the report's revision and the
  # surface the model actually saw cannot drift apart.
  defp load_surfaces([], out), do: load_surfaces(["head"] ++ committed_surface_ids(), out)

  defp load_surfaces(ids, out) do
    Enum.map(ids, fn
      "head" ->
        surface = Surface.current(revision())
        File.write!(Path.join(out, "surface-head.json"), Surface.dump(surface))
        surface

      id ->
        Surface.load!(Fixture.path("routing_eval/surfaces/#{id}.json"))
    end)
  end

  defp committed_surface_ids do
    "routing_eval/surfaces/*.json"
    |> Fixture.path()
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end

  defp run_trials(cases, surfaces, models, trials, out, opts) do
    combinations =
      for index <- 1..trials//1,
          eval_case <- cases,
          model <- models,
          surface <- surfaces,
          do: {index, eval_case, model, surface}

    Enum.reduce_while(combinations, [], fn {index, eval_case, model, surface}, acc ->
      result = one_trial(eval_case, model, surface, index, out, opts)

      case result["verdict"]["rate_limited"] do
        nil -> {:cont, acc ++ [result]}
        info -> {:halt, halt_on_rate_limit(acc ++ [result], info)}
      end
    end)
  end

  defp halt_on_rate_limit(results, info) do
    Mix.shell().error(
      "Rate limited — stopping the run. resetsAt: #{inspect(info["resetsAt"])}, " <>
        "status: #{inspect(info["status"])}"
    )

    results
  end

  defp one_trial(eval_case, model, surface, index, out, opts) do
    dir = Path.join([out, eval_case.id, model["key"], surface.id, Integer.to_string(index)])
    File.mkdir_p!(dir)

    surface_path = Path.join(dir, "surface.json")
    File.write!(surface_path, Surface.dump(surface))

    trace_path = Path.join(dir, "trace.jsonl")
    fixture = Fixture.load!(eval_case.fixture)
    fixture_path = Fixture.path("routing_eval/fixtures/#{eval_case.fixture}.json")

    Mix.shell().info("  #{eval_case.id} / #{model["name"]} / #{surface.id} / trial #{index}…")

    outcome =
      Runner.run(
        prompt: eval_case.prompt,
        model: model["name"],
        surface_path: surface_path,
        fixture_path: fixture_path,
        trace_path: trace_path,
        timeout_ms: opts[:timeout] || 120_000
      )

    {stream, failure} =
      case outcome do
        {:ok, %{output: output}} -> {output, nil}
        {:error, {:timeout, partial}} -> {partial, "the client did not finish before the timeout"}
        {:error, reason} -> {"", "the client could not be run: #{inspect(reason)}"}
      end

    File.write!(Path.join(dir, "stream.jsonl"), stream)

    trace = read_trace(trace_path)
    {_key, expectation} = EvalCase.expectation(eval_case, surface.id)

    verdict = score(eval_case, expectation, surface, fixture, stream, trace, failure)
    File.write!(Path.join(dir, "verdict.json"), Jason.encode!(verdict, pretty: true))

    %{
      "case" => eval_case.id,
      "model_key" => model["key"],
      "model" => model["name"],
      "surface" => surface.id,
      "index" => index,
      "dir" => dir,
      "verdict" => verdict
    }
  end

  defp score(eval_case, expectation, surface, fixture, stream, trace, failure) do
    case EvalStream.parse(stream) do
      {:ok, trial} ->
        void =
          failure || EvalStream.void_reason(trial, Surface.tool_names(surface)) ||
            cross_check(trial, trace)

        eval_case
        |> Judge.judge(expectation, %{
          trace: trace,
          fixture: fixture,
          surface: surface,
          final_text: trial.final_text,
          void_reason: void
        })
        |> Map.put("rate_limited", EvalStream.blocking_rate_limit(trial))
        |> Map.put("final_text", trial.final_text)
        |> Map.put("reported_model", trial.init && trial.init["model"])

      {:error, reason} ->
        eval_case
        |> Judge.judge(expectation, %{
          trace: trace,
          fixture: fixture,
          surface: surface,
          final_text: nil,
          void_reason: failure || "the stream could not be parsed: #{reason}"
        })
        |> Map.put("rate_limited", nil)
        |> Map.put("final_text", nil)
        |> Map.put("reported_model", nil)
    end
  end

  defp cross_check(trial, trace) do
    case EvalStream.cross_check(trial, trace) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp read_trace(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _reason} ->
        []
    end
  end

  defp check_cli! do
    [executable | _rest] = Client.command()

    case System.cmd(executable, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> Mix.raise("#{executable} --version exited #{status}: #{output}")
    end
  rescue
    error in ErlangError ->
      Mix.raise("could not run the headless client: #{Exception.message(error)}")
  end

  defp check_env! do
    if System.get_env("ANTHROPIC_API_KEY") do
      Mix.raise(
        "ANTHROPIC_API_KEY is set. The routing eval's contract is subscription auth — " <>
          "unset it and run again."
      )
    end
  end

  defp check_clean! do
    {output, 0} = System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true)

    dirty =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> String.slice(3..-1//1) |> String.trim()))
      |> Enum.filter(
        &(String.starts_with?(&1, "lib/") or String.starts_with?(&1, "priv/routing_eval/"))
      )

    if dirty != [] do
      Mix.raise(
        "uncommitted changes under lib/ or priv/routing_eval/:\n  " <>
          Enum.join(dirty, "\n  ") <>
          "\n\nThe head surface is captured from the checkout, so a run has to name a revision."
      )
    end
  end

  defp revision do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  end
end
