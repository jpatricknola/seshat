defmodule Seshat.Eval.Report do
  @moduledoc """
  Turns a finished run into `report.md` and `report.json`.

  Pure. The run map it renders is assembled by `mix routing.eval`; nothing here
  reads a file or a clock.

  Two rules shape the output and both are about not overclaiming:

    * **Void trials are listed and excluded from every rate.** A run that threw
      away four of five trials must not read like a run of one.
    * **A case with fewer valid trials than requested on either surface is
      `inconclusive`, not scored.** Comparing three surviving base trials
      against five head trials is exactly the kind of quiet arithmetic this
      whole harness exists to replace.

  The gate is *head must not regress on any model in the panel*, so the table
  is per model and carries a panel row taking the worst model per surface.
  Seshat is meant to work under many models; no single one is the oracle.
  """

  @doc "The run rendered as Markdown."
  @spec markdown(map()) :: String.t()
  def markdown(run) do
    [
      header(run),
      Enum.map_join(cases(run), "\n", &case_section(run, &1)),
      calls_section(run),
      void_section(run)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc "The run rendered as JSON, ready to write beside the Markdown."
  @spec json(map()) :: String.t()
  def json(run), do: Jason.encode!(run, pretty: true)

  defp header(run) do
    surfaces =
      Enum.map_join(run["surfaces"], "\n", fn surface ->
        "- `#{surface["id"]}` — revision `#{surface["revision"]}`, " <>
          "#{surface["tool_count"]} tools, contract sha256 `#{short(surface["digest"])}`"
      end)

    models =
      Enum.map_join(run["models"], "\n", fn model ->
        reported = model["reported"] || model["name"]
        "- `#{model["key"]}` — requested `#{model["name"]}`, reported by init as `#{reported}`"
      end)

    """
    # Routing evaluation — #{run["stamp"]}

    - Claude Code CLI: `#{run["cli_version"]}`
    - Lane prompt hash: `#{run["lane_prompt_hash"]}`
    - Trials requested per case/model/surface: #{run["trials_requested"]}

    ## Surfaces

    #{surfaces}

    ## Model panel

    #{models}
    """
  end

  defp cases(run), do: run["trials"] |> Enum.map(& &1["case"]) |> Enum.uniq() |> Enum.sort()

  defp surface_ids(run), do: Enum.map(run["surfaces"], & &1["id"])

  defp case_section(run, case_id) do
    rows =
      for model <- run["models"], surface_id <- surface_ids(run) do
        row(run, case_id, model, surface_id)
      end

    panel = for surface_id <- surface_ids(run), do: panel_row(rows, surface_id)

    verdict = case_verdict(run, case_id, rows)

    """
    ## Case `#{case_id}` — #{verdict}

    | model | surface | valid trials | void | semantic success | correct target, 1st mutation | 1st call valid | 1st mutation valid | all calls valid | median mutations | tool refusals |
    |---|---|---|---|---|---|---|---|---|---|---|
    #{Enum.map_join(rows ++ panel, "\n", &render_row/1)}
    """
  end

  defp row(run, case_id, model, surface_id) do
    trials =
      Enum.filter(run["trials"], fn trial ->
        trial["case"] == case_id and trial["model_key"] == model["key"] and
          trial["surface"] == surface_id
      end)

    {void, valid} = Enum.split_with(trials, &voided?/1)

    %{
      label: "`#{model["key"]}`",
      surface: surface_id,
      valid: length(valid),
      void: length(void),
      semantic: rate(valid, "semantic_success"),
      target: rate(valid, "correct_target_first_mutation"),
      first_call: rate(valid, "first_call_valid"),
      first_mutation: rate(valid, "first_mutation_valid"),
      all_calls: rate(valid, "all_calls_valid"),
      median_mutations: median(valid, "mutation_count"),
      refusals: sum(valid, "tool_errors")
    }
  end

  # The panel gate: head must not regress on *any* model, so the panel row is the
  # worst observed rate per column, not an average across models.
  defp panel_row(rows, surface_id) do
    same = Enum.filter(rows, &(&1.surface == surface_id))

    %{
      label: "**panel (worst)**",
      surface: surface_id,
      valid: Enum.sum(Enum.map(same, & &1.valid)),
      void: Enum.sum(Enum.map(same, & &1.void)),
      semantic: worst(same, :semantic),
      target: worst(same, :target),
      first_call: worst(same, :first_call),
      first_mutation: worst(same, :first_mutation),
      all_calls: worst(same, :all_calls),
      median_mutations: Enum.max(Enum.map(same, & &1.median_mutations), fn -> nil end),
      refusals: Enum.sum(Enum.map(same, & &1.refusals))
    }
  end

  defp worst(rows, key) do
    rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
  end

  defp render_row(row) do
    "| #{row.label} | `#{row.surface}` | #{row.valid} | #{row.void} | " <>
      "#{percent(row.semantic)} | #{percent(row.target)} | #{percent(row.first_call)} | " <>
      "#{percent(row.first_mutation)} | #{percent(row.all_calls)} | " <>
      "#{number(row.median_mutations)} | #{row.refusals} |"
  end

  defp case_verdict(run, _case_id, rows) do
    requested = run["trials_requested"]
    short = Enum.filter(rows, &(&1.valid < requested))

    if short == [] do
      "scored"
    else
      names = Enum.map_join(short, ", ", &"#{&1.label} on `#{&1.surface}`")
      "**inconclusive** (fewer than #{requested} valid trials: #{names})"
    end
  end

  defp calls_section(run) do
    body =
      run["trials"]
      |> Enum.map_join("\n", fn trial ->
        calls =
          case trial["verdict"]["calls"] do
            [] -> "  (no tool calls)"
            calls -> Enum.map_join(calls, "\n", &"  #{&1["seq"]}. #{call_line(&1)}")
          end

        "- `#{trial["case"]}` / `#{trial["model_key"]}` / `#{trial["surface"]}` / " <>
          "trial #{trial["index"]}#{void_suffix(trial)}\n#{calls}"
      end)

    """

    ## Every observed call

    #{body}
    """
  end

  defp call_line(call) do
    flags =
      [
        if(call["is_error"], do: "error", else: nil),
        if(call["schema_valid"] == false, do: "schema-invalid", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    suffix = if flags == [], do: "", else: " — #{Enum.join(flags, ", ")}"

    "`#{call["name"]}` #{Jason.encode!(call["arguments"])}#{suffix}"
  end

  defp void_suffix(trial) do
    case trial["verdict"]["void_reason"] do
      nil -> ""
      reason -> " — **VOID**: #{reason}"
    end
  end

  defp void_section(run) do
    void = Enum.filter(run["trials"], &voided?/1)

    if void == [] do
      "\n## Void trials\n\nNone — every trial was isolated as the contract requires.\n"
    else
      body =
        Enum.map_join(void, "\n", fn trial ->
          "- `#{trial["case"]}` / `#{trial["model_key"]}` / `#{trial["surface"]}` / " <>
            "trial #{trial["index"]}: #{trial["verdict"]["void_reason"]}"
        end)

      "\n## Void trials\n\n#{body}\n"
    end
  end

  defp voided?(trial), do: not is_nil(trial["verdict"]["void_reason"])

  defp rate([], _key), do: nil

  defp rate(trials, key) do
    Enum.count(trials, & &1["verdict"][key]) / length(trials)
  end

  defp sum(trials, key), do: Enum.sum(Enum.map(trials, &(&1["verdict"][key] || 0)))

  defp median([], _key), do: nil

  defp median(trials, key) do
    sorted = trials |> Enum.map(&(&1["verdict"][key] || 0)) |> Enum.sort()
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp percent(nil), do: "—"

  defp percent(rate) do
    "#{:erlang.float_to_binary(rate * 100, decimals: 0)}%"
  end

  defp number(nil), do: "—"
  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp short(nil), do: "—"
  defp short(digest), do: binary_part(digest, 0, 12)
end
