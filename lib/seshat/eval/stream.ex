defmodule Seshat.Eval.Stream do
  @moduledoc """
  Parses the Claude Code CLI's `--output-format stream-json` output into a
  `Seshat.Eval.Trial`, and decides whether the trial was isolated enough to
  count.

  Pure, and pinned by a committed capture
  (`test/fixtures/routing/stream-2.1.220.jsonl`). That fixture is the tripwire:
  a CLI upgrade that moves a field fails `Seshat.Eval.StreamTest` loudly instead
  of quietly scoring every future run at zero tool calls.

  ## Why isolation is checked at all

  Measured 2026-08-28: a naive `claude -p` run fired this machine's own
  `SessionStart` hook — a plugin that rewrites the model's register — *inside*
  the eval. A routing result produced under someone's personal configuration
  measures their configuration. `--setting-sources ""` removes it, and
  `void_reason/2` refuses to count a trial whose `init` event does not prove it
  was removed: no plugins, no hook events, exactly the recorder connected,
  exactly the snapshot's tools visible, and subscription auth rather than an API
  key.

  A void trial is reported and excluded from the rates. It is never silently
  retried: a run whose isolation broke halfway is a fact about the run.

  Isolation proof fails **closed**: a missing `plugins` field, a missing
  `apiKeySource` field, or a `rate_limit_event` whose `rate_limit_info.status`
  is absent all void the trial by name, rather than being treated as the
  clean value they'd collapse to under a bare pattern match. A CLI upgrade
  that renames or drops one of those fields must show up as a wave of void
  trials, not a silent pass.
  """

  alias Seshat.Eval.Trial

  @tool_prefix "mcp__seshat_eval__"

  @doc "The `mcp__<server>__` prefix the CLI puts on this server's tool names."
  @spec tool_prefix() :: String.t()
  def tool_prefix, do: @tool_prefix

  @doc """
  Parses newline-delimited stream JSON — a list of lines, or one blob.
  """
  @spec parse(String.t() | [String.t()]) :: {:ok, Trial.t()} | {:error, String.t()}
  def parse(blob) when is_binary(blob), do: blob |> String.split("\n") |> parse()

  def parse(lines) when is_list(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, %Trial{}}, fn line, {:ok, trial} ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> {:cont, {:ok, absorb(trial, event)}}
        _ -> {:halt, {:error, "stream line was not a JSON object: #{preview(line)}"}}
      end
    end)
    |> case do
      {:ok, trial} -> {:ok, finish(trial)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish(%Trial{} = trial) do
    %{trial | calls: Enum.reverse(trial.calls), results: Enum.reverse(trial.results)}
    |> then(&%{&1 | hook_events: Enum.reverse(&1.hook_events)})
    |> then(&%{&1 | rate_limits: Enum.reverse(&1.rate_limits)})
  end

  defp absorb(trial, %{"type" => "system", "subtype" => "init"} = event) do
    %{trial | init: event}
  end

  defp absorb(trial, %{"type" => "system", "subtype" => subtype} = event)
       when subtype in ["hook_started", "hook_response"] do
    %{trial | hook_events: [event | trial.hook_events]}
  end

  defp absorb(trial, %{"type" => "rate_limit_event"} = event) do
    %{trial | rate_limits: [event | trial.rate_limits]}
  end

  defp absorb(trial, %{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.reduce(content, trial, &absorb_block/2)
  end

  defp absorb(trial, %{"type" => "user", "message" => %{"content" => content}})
       when is_list(content) do
    results =
      content
      |> Enum.filter(&match?(%{"type" => "tool_result"}, &1))
      |> Enum.map(fn block ->
        %{
          tool_use_id: block["tool_use_id"],
          is_error: block["is_error"] == true,
          content: block["content"]
        }
      end)

    %{trial | results: Enum.reverse(results) ++ trial.results}
  end

  defp absorb(trial, %{"type" => "result"} = event) do
    %{trial | result: event, final_text: text_of(event["result"])}
  end

  defp absorb(trial, _event), do: trial

  # `thinking` is dropped here, before the trial struct exists — nothing
  # downstream can write it to a run directory because nothing downstream ever
  # sees it.
  defp absorb_block(%{"type" => "tool_use"} = block, trial) do
    call = %{
      id: block["id"],
      name: strip_prefix(block["name"]),
      input: block["input"] || %{}
    }

    %{trial | calls: [call | trial.calls]}
  end

  defp absorb_block(_block, trial), do: trial

  defp text_of(value) when is_binary(value), do: value
  defp text_of(_value), do: nil

  @doc """
  Strips the `mcp__seshat_eval__` prefix the client adds to MCP tool names.
  """
  @spec strip_prefix(String.t() | nil) :: String.t() | nil
  def strip_prefix(nil), do: nil

  def strip_prefix(name) do
    case name do
      @tool_prefix <> rest -> rest
      other -> other
    end
  end

  @doc """
  The first reason this trial must not be counted, or `nil`.

  `expected_tool_names` are the *unprefixed* names of the surface under test:
  the init event has to show exactly those, so a trial that saw a stale surface
  or a leaked built-in tool is thrown out rather than scored.
  """
  @spec void_reason(Trial.t(), [String.t()]) :: String.t() | nil
  def void_reason(%Trial{init: nil}, _expected), do: "no system/init event in the stream"

  def void_reason(%Trial{init: init} = trial, expected) do
    Enum.find_value(
      [
        plugins_reason(init),
        hooks_reason(trial),
        servers_reason(init),
        tools_reason(init, expected),
        auth_reason(init),
        rate_limit_status_reason(trial),
        rate_limit_reason(trial),
        denials_reason(trial),
        result_reason(trial)
      ],
      & &1
    )
  end

  defp plugins_reason(init) do
    case Map.fetch(init, "plugins") do
      :error -> "isolation unproven: init has no plugins field"
      {:ok, []} -> nil
      {:ok, other} -> "settings leaked: init reported plugins #{inspect(other)}"
    end
  end

  defp hooks_reason(%Trial{hook_events: []}), do: nil

  defp hooks_reason(%Trial{hook_events: events}) do
    "settings leaked: #{length(events)} hook event(s) fired during the trial"
  end

  defp servers_reason(init) do
    case init["mcp_servers"] do
      [%{"name" => "seshat_eval", "status" => "connected"}] ->
        nil

      other ->
        "expected exactly the connected recorder, got #{inspect(other)}"
    end
  end

  defp tools_reason(init, expected) do
    seen = init |> Map.get("tools", []) |> Enum.map(&strip_prefix/1) |> MapSet.new()
    want = MapSet.new(expected)

    if MapSet.equal?(seen, want) do
      nil
    else
      missing = want |> MapSet.difference(seen) |> Enum.sort()
      extra = seen |> MapSet.difference(want) |> Enum.sort()

      "the visible tools were not the surface under test" <>
        if(missing == [], do: "", else: " (missing #{Enum.join(missing, ", ")})") <>
        if(extra == [], do: "", else: " (unexpected #{Enum.join(extra, ", ")})")
    end
  end

  # Subscription auth is part of the contract: an API key would bill differently
  # and could route to a different serving stack.
  defp auth_reason(init) do
    case Map.fetch(init, "apiKeySource") do
      :error -> "isolation unproven: init has no apiKeySource field"
      {:ok, "none"} -> nil
      {:ok, other} -> "auth was not the subscription: apiKeySource #{inspect(other)}"
    end
  end

  defp denials_reason(%Trial{result: %{"permission_denials" => denials}})
       when denials not in [nil, []] do
    "the client denied a tool call: #{inspect(denials)}"
  end

  defp denials_reason(_trial), do: nil

  defp result_reason(%Trial{result: nil}), do: "the stream ended without a result event"
  defp result_reason(_trial), do: nil

  defp rate_limit_reason(trial) do
    case blocking_rate_limit(trial) do
      nil -> nil
      info -> "rate limited: #{inspect(info)}"
    end
  end

  # A missing `status` is a distinct failure from a present, non-"allowed"
  # one: it means the event's shape can no longer be trusted, not that the
  # account is rate limited. It voids the trial but must never reach
  # `blocking_rate_limit/1`'s stop-the-run path, which treats an absent
  # status as the harmless "allowed" case on purpose — see its doc.
  defp rate_limit_status_reason(%Trial{rate_limits: events}) do
    Enum.find_value(events, fn event ->
      info = event["rate_limit_info"] || %{}

      if Map.has_key?(info, "status") do
        nil
      else
        "isolation unproven: rate_limit_event has no rate_limit_info.status field"
      end
    end)
  end

  @doc """
  The first `rate_limit_event` whose status is not `"allowed"`, or `nil`.

  `status: "allowed"` is emitted every turn and is normal. Anything else means
  the account's window is exhausted — measured on this account as an outright
  failure rather than billed overage — so the runner stops the whole run and
  reports `resetsAt` instead of grinding out void trials.

  A missing `status` is deliberately treated the same as `"allowed"` *here* —
  it must never stop the whole run on its own — because `void_reason/2`
  already voids that trial by name via `rate_limit_status_reason/1`. Only a
  present, non-`"allowed"` status is grounds to stop everything behind it.
  """
  @spec blocking_rate_limit(Trial.t()) :: map() | nil
  def blocking_rate_limit(%Trial{rate_limits: events}) do
    Enum.find_value(events, fn event ->
      info = event["rate_limit_info"] || %{}
      if info["status"] in [nil, "allowed"], do: nil, else: info
    end)
  end

  @doc """
  Cross-checks the client's `tool_use` blocks against the recorder's own trace.

  Both sides see the same calls or one of them has a parsing bug; saying which
  is worth more than either alone. Returns `:ok` or `{:error, reason}`.
  """
  @spec cross_check(Trial.t(), [map()]) :: :ok | {:error, String.t()}
  def cross_check(%Trial{calls: calls}, trace) when is_list(trace) do
    from_stream = Enum.map(calls, & &1.name)
    from_trace = Enum.map(trace, & &1["name"])

    if from_stream == from_trace do
      :ok
    else
      {:error,
       "the client stream and the recorder trace disagree — " <>
         "stream #{inspect(from_stream)}, trace #{inspect(from_trace)}"}
    end
  end

  defp preview(line) when byte_size(line) <= 120, do: line
  defp preview(line), do: binary_part(line, 0, 120) <> "…"
end
