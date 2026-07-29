defmodule Seshat.MCP.LogFilter do
  @moduledoc """
  Silences the warnings Anubis emits when an MCP client hangs up.

  Not an MCP component — nothing here is generated, and it has no bearing on
  the tool surface. It exists purely to keep a normal connect quiet.

  A client going away is routine. `mcp-remote` alone opens two throwaway probe
  streams on every connect (one bare SSE GET, one `mcp-remote-fallback-test`
  handshake) purely to discover which transport the server speaks, then drops
  the losers. Any client closing, sleeping, or reloading its config does the
  same. Anubis writes a keepalive every five seconds and only discovers the
  dead socket when that write fails, at which point it logs
  `sse_keepalive_failed` at `:warning` — so a completely healthy connect prints
  a stack of warnings that read like a fault.

  The level is passed as metadata at the call site rather than read from
  config (`Anubis.SSE.Streaming.continue/7`), and metadata takes precedence
  over `config :anubis_mcp, logging: [...]`, so the level cannot be lowered.
  The only supported lever, `log: false`, would take every Anubis log with it.
  Hence a filter.

  ## Nothing is lost

  A failed keepalive is reported as two consecutive log events — an event line
  naming it, then a detail line carrying `reason:`. Only the second knows
  whether the socket merely closed, so the pair has to be judged together:
  `sse_keepalive_failed` sets a flag in the process dictionary (both lines are
  logged back to back from the same process, so the pairing is exact), and the
  detail line that follows decides.

  - `reason: :closed` — the peer hung up, the handler gets reaped, there is
    nothing to act on. Both lines are dropped.
  - Any other reason (`:enotconn`, `:einval`, a timeout) is a real transport
    fault. The detail line is rewritten to carry the event name that was
    withheld and logged at its original level, so the failure arrives whole,
    on one line instead of two.

  Every other Anubis log passes through untouched, including `sse_send_failed`
  — a server-initiated message that never reached its stream is a delivery
  failure worth seeing, whatever the reason underneath it.
  """

  @pending :seshat_mcp_log_filter_pending_keepalive_failure

  @event_prefix "MCP transport event: "
  @details_prefix "MCP transport details: "
  @keepalive_failed "sse_keepalive_failed"

  @doc """
  A `:logger` primary filter.

  Returns `:stop` to drop the event, the event unchanged to keep it, or a
  rewritten event to replace it.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(%{msg: {:string, message}} = event, _opts) do
    message |> IO.iodata_to_binary() |> judge(event)
  end

  def filter(event, _opts), do: event

  defp judge(@event_prefix <> @keepalive_failed <> _rest, _event) do
    Process.put(@pending, true)
    :stop
  end

  defp judge(@details_prefix <> details, event) do
    cond do
      not pending_keepalive_failure?() -> event
      String.contains?(details, "reason: :closed") -> :stop
      true -> %{event | msg: {:string, @event_prefix <> @keepalive_failed <> " " <> details}}
    end
  end

  defp judge(_message, event) do
    Process.delete(@pending)
    event
  end

  defp pending_keepalive_failure?, do: Process.delete(@pending) == true
end
