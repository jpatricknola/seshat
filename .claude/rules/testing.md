---
paths:
  - "test/**"
---

# Testing rules

## Seshat-specific

- **Never let a test send OSC to a real Ableton.** The suite must be safe to
  run with Live open and unsaved work. In `MIX_ENV=test`, the configured ports
  are `0` (the safe OS-assigned fallback). A wire-reaching setup starts
  [`Seshat.Test.OSCSink`](../../test/support/osc_sink.ex) first, reads its
  ephemeral `port/1`, then starts `Seshat.OSC.Transport` with
  `send_port: OSCSink.port(sink), reply_port: 0`. This keeps concurrent test
  BEAMs isolated and cannot reach AbletonOSC's 11000/11001. Assert mutations at
  the wire (`assert_receive {:osc_out, address, args}`), not only through the
  handler's reply string.
- **Never write tests that reach `Transport.query/3`** — they need a live
  Ableton and will time out (5s default, 15s browsing, 30s device loading).
  Test the pure layer instead: OSC encoding, definitions, handler dispatch
  shape, catalog merge/search.
  - **One scoped exception: `Transport`'s own tests**
    ([test/seshat/osc/transport_test.exs](../../test/seshat/osc/transport_test.exs)).
    There `OSCSink` plays AbletonOSC and supplies the reply, or the test is
    deliberately asserting the timeout path with a sub-second timeout — the
    rule's rationale, "needs a live Ableton", doesn't apply, and the query
    queue can't be tested at all without calling `query/3`.
  - **One more, narrower: a handler test whose own `OSCSink` supplies the
    reply.** A guard that reads before it mutates (`hide_view`'s read-back,
    `undo`/`redo`'s `can_undo`/`can_redo` check) *is* the behaviour under test,
    and there is no pure layer underneath it to test instead. Where the test
    starts the sink itself and answers the query with
    `OSCSink.send_datagram/3`, nothing waits on Ableton and nothing times out —
    see the `undo`/`redo` guard tests and the `hide_view` test in
    [test/seshat/tools/handlers_test.exs](../../test/seshat/tools/handlers_test.exs).
    What stays forbidden is the shape the rule was written against: a handler
    test that calls `query/3` and *hopes* something answers, which on a machine
    with Live open is a real Ableton and everywhere else is a timeout.
    Deliberately leaving an attempt unanswered is fine when the timeout path is
    the thing being asserted and the test says so.

  Everything above the transport otherwise keeps the rule as written.
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
