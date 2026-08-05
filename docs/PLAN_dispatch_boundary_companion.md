# Plan: consume the AbletonOSC dispatch-boundary merge

> **Backfill.** This branch skipped `/plan` — the work began as a review of
> [jpatricknola/AbletonOSC#1](https://github.com/jpatricknola/AbletonOSC/pull/1)
> and became the companion update once that PR merged. The doc exists so the
> live verification below has somewhere to live and somewhere for `/smoke-test`
> to write its results, which is what `/ship` archives. PR:
> [jpatricknola/seshat#66](https://github.com/jpatricknola/seshat/pull/66).

## Context

The fork PR funnels both branches of `process_message` through one
`OSCServer._dispatch` and widens the correlated `/live/error` envelope from a
single case — a direct callback raised — to four:

1. an uncaught exception in an ordinary callback, direct **or** wildcard;
2. an exception in the generic `_call_method` path;
3. an exception in the generic `_set_property` path;
4. a handler returning something that is neither a tuple nor `None`.

It also fixes wildcard matching (escaped and anchored with `fullmatch`, where
upstream built a regex from the raw address and matched with `re.match`),
isolates wildcard fan-out failures so one bad match cannot silence the rest,
and replaces the reply-type `assert` — stripped under `python -O` — with an
explicit `TypeError` raised inside the boundary.

The Seshat side is a pin bump plus documentation and one test guard: no tool,
schema, or handler behaviour changes. `vendored_addresses_test` grepped
`osc_server.py` for the literal `("request", message.address, detail,`, which
the refactor renamed to `error_address`; that assertion is now a regex over the
payload shape. Three prose claims the merge falsified were corrected —
wildcard failures are no longer uncorrelated, `_set_property` no longer
swallows Live rejections, and the per-entry correlation is no longer unverified.

Separately, this branch fixes `mix abletonosc.install`, which copied
`priv/AbletonOSC` verbatim with no notion of which commit that was. That is
what let a merged PR be installed, restarted around, and smoke-tested against
without anyone noticing it was two-day-old Python.

## Live verification

Nothing in `mix test` reaches any of this — the suite greps the submodule in
the repo, while Live runs the copy in Remote Scripts, and the whole envelope
contract is built inside Live. Assume **zero** prior coverage for the three
new cases: before this branch, only case 1's direct half had ever been
exercised live. Run the automated half with `/smoke-test bridge`.

**Install the fork and restart Live first.** `/smoke-test` never does either,
and against a stale copy every result below is right for the wrong reason. As
of 2026-08-05 `mix abletonosc.install` fast-forwards the submodule and prints
the commit it deployed, but it still cannot restart Live, and Remote Scripts
load at startup.

- `smoke_tests/auto/bridge.md § A wildcard matches complete addresses only` —
  **new.** The escaped/anchored matching, and the cheapest non-mutating probe
  for which bridge Live actually has in memory.
- `smoke_tests/auto/bridge.md § A wildcard fan-out answers every applicable
  match` — **new.** The fan-out contract: skipped endpoints send nothing and
  the ones after them still answer.
- `smoke_tests/auto/bridge.md § A failing generic method names the request that
  failed` — **new.** Case 2, via `/live/song/delete_scene` with no arguments.
- `smoke_tests/auto/bridge.md § One rejection, one error datagram` — the
  duplicate-suppression invariant, which every widened case now also has to
  respect; corrected on 2026-08-05 to count per raise rather than per tool call.
- `smoke_tests/auto/bridge.md § A rejected query fails fast, and says rejected`
  — case 1's direct half, the pre-existing coverage this widens.
- `smoke_tests/auto/bridge.md § A bad index errors immediately, not after ~2s` —
  the vendored envelope handlers, unchanged by the merge but the standard
  stale-install detector whenever `priv/AbletonOSC` moves.
- `smoke_tests/auto/bridge.md § Live's Log.txt stays clean during ordinary work`
  — the merge changes what reaches the log on every failing request; rescoped
  2026-08-05 after it failed on a mirror-rebuild race unrelated to this change.

**Uncovered, and why:**

- **Wildcard fan-out isolation for exceptions outside the skip set** ⚠️
  unmeasured. The fix only changes behaviour for exceptions other than
  `ValueError`/`AttributeError`/`IndexError`, which upstream already skipped.
  The one pattern that reliably raises `TypeError` mid-fan-out is
  `/live/song/*`, which matches every generic song method and would fire
  `start_playing`, `delete_track` and `undo` on the user's set — not a test,
  a wrecking ball. Covered in the fork's `tests_unit/test_osc_server.py`.
- **Case 3, generic `_set_property` failures** ⚠️ unmeasured. No generic setter
  has been found that Live rejects by raising; measured 2026-08-05,
  `/live/song/set/signature_denominator 3` is ignored silently with no
  exception and no datagram. The path is shared with case 2, which *is*
  covered.
- **Case 4, invalid handler return values.** Not reachable from outside at all:
  no registered handler returns a non-tuple, which is the point of a defensive
  check. Provoking it requires editing Python, so its only honest home is
  `tests_unit/`.
- **Whether a correlated setter failure could ever help a user.** It cannot
  today — `Transport.send_message/2` returns before the error lands, so it is
  broadcast and answers nobody. That is a design question tracked as a planner
  note under ROADMAP #4, not something a smoke test can answer.
