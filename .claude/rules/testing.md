---
paths:
  - "test/**"
---

# Testing rules

## Seshat-specific

- **Never write tests that reach `Transport.query/3`** — they need a live
  Ableton and will time out (5s default, 15s browsing, 30s device loading).
  Test the pure layer instead: OSC encoding, definitions, handler dispatch
  shape, catalog merge/search.
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
