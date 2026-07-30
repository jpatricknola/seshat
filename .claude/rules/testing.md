---
paths:
  - "test/**"
---

# Testing rules

## Seshat-specific

- **Never let a test send OSC to a real Ableton.** The suite must be safe to
  run with Live open and unsaved work. In `MIX_ENV=test`, `Transport` sends to
  `config :seshat, :osc_send_port` and binds `:osc_reply_port`
  ([config/test.exs](../../config/test.exs)) — deliberately not AbletonOSC's
  11000/11001 — so any test that starts `Seshat.OSC.Transport` reaches a
  test-local socket. Don't hardcode 11000 or 11001 in a test, don't override
  those config keys, and start
  [`Seshat.Test.OSCSink`](../../test/support/osc_sink.ex) alongside Transport
  so mutations are asserted at the wire (`assert_receive {:osc_out, address,
  args}`) rather than only through the handler's reply string.
- **Never write tests that reach `Transport.query/3`** — they need a live
  Ableton and will time out (5s default, 15s browsing, 30s device loading).
  Test the pure layer instead: OSC encoding, definitions, handler dispatch
  shape, catalog merge/search.
  - **One scoped exception: `Transport`'s own tests**
    ([test/seshat/osc/transport_test.exs](../../test/seshat/osc/transport_test.exs)).
    There `OSCSink` plays AbletonOSC and supplies the reply, or the test is
    deliberately asserting the timeout path with a sub-second timeout — the
    rule's rationale, "needs a live Ableton", doesn't apply, and the query
    queue can't be tested at all without calling `query/3`. Everything above
    the transport keeps the rule as written.
- `Seshat.Agent` is tested with `Req.Test` — no real Anthropic calls.
- MCP components are tested for **parity with `Seshat.Tools.Definitions`**
  (`Seshat.MCP.ToolsTest`); adding a tool means bumping the tool count in
  [test/seshat/tools/definitions_test.exs](../../test/seshat/tools/definitions_test.exs).
- `Seshat.Library.AbletonDB` tests run against a miniature SQLite fixture the
  test builds itself — follow that pattern for anything touching Ableton's DB.
- `mix precommit` (compile --warnings-as-errors, unused-dep check, format,
  test) is the bar before declaring work done.

## General ExUnit rules

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
