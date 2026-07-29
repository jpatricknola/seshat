defmodule Seshat.MCP.LogFilterTest do
  use ExUnit.Case, async: true

  alias Seshat.MCP.LogFilter

  defp event(message), do: %{level: :warning, msg: {:string, message}, meta: %{}}

  defp filter(message), do: LogFilter.filter(event(message), [])

  defp details(reason), do: ~s(MCP transport details: %{reason: #{reason}, session_id: "s_abc="})

  describe "a client hanging up" do
    test "drops the pair" do
      assert :stop = filter("MCP transport event: sse_keepalive_failed")
      assert :stop = filter(details(":closed"))
    end
  end

  describe "a keepalive that failed for a real reason" do
    test "reports the failure whole, on the detail line that carries it" do
      assert :stop = filter("MCP transport event: sse_keepalive_failed")

      assert %{level: :warning, msg: {:string, message}} = filter(details(":enotconn"))
      assert message =~ "sse_keepalive_failed"
      assert message =~ "reason: :enotconn"
      assert message =~ ~s(session_id: "s_abc=")
    end
  end

  describe "events that are not a failed keepalive" do
    test "keeps a disconnect detail line that follows something else" do
      assert %{msg: {:string, _}} = filter("MCP transport event: sse_send_failed")

      log_event = event(details(":closed"))
      assert ^log_event = LogFilter.filter(log_event, [])
    end

    test "keeps unrelated transport events" do
      log_event = event("MCP transport event: sse_handler_registered")

      assert ^log_event = LogFilter.filter(log_event, [])
    end

    test "keeps ordinary application logs" do
      log_event = event("OSC Transport listening on UDP port 11001")

      assert ^log_event = LogFilter.filter(log_event, [])
    end

    test "passes through reports it cannot read as a string" do
      log_event = %{level: :warning, msg: {:report, %{what: :ever}}, meta: %{}}

      assert ^log_event = LogFilter.filter(log_event, [])
    end
  end

  describe "the pairing flag" do
    test "does not survive an intervening log from the same process" do
      assert :stop = filter("MCP transport event: sse_keepalive_failed")
      assert %{msg: {:string, _}} = filter("Loaded 1 tracks: 1-MIDI")

      log_event = event(details(":closed"))
      assert ^log_event = LogFilter.filter(log_event, [])
    end

    test "is consumed, so it cannot swallow a later disconnect" do
      assert :stop = filter("MCP transport event: sse_keepalive_failed")
      assert :stop = filter(details(":closed"))

      log_event = event(details(":closed"))
      assert ^log_event = LogFilter.filter(log_event, [])
    end
  end
end
