# Plan: consume the AbletonOSC dispatch-boundary merge

> **Archived 2026-08-27 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. It is a backfill doc: the
> work landed on `main` in `8955aed` (PR
> [jpatricknola/seshat#66](https://github.com/jpatricknola/seshat/pull/66)) —
> the submodule pin bump, the `/live/error` dispatch clause in
> [../../lib/seshat/osc/transport.ex](../../lib/seshat/osc/transport.ex), the
> commit-naming rework of
> [../../lib/mix/tasks/abletonosc.install.ex](../../lib/mix/tasks/abletonosc.install.ex),
> and the payload-shape regex in
> [../../test/seshat/osc/vendored_addresses_test.exs](../../test/seshat/osc/vendored_addresses_test.exs).
> The one follow-up it surfaced — using the correlated *setter* failure
> envelope, which `Transport.send_message/2` still throws away — is a planner
> note under the verify-before-mutate item in
> [../ROADMAP.md](../ROADMAP.md), not carried here.

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

  *PR review, 2026-08-05 — passed.* `/live/*/get/tempo` with no arguments
  produced exactly one reply, `OSC in: /live/song/get/tempo [120.0]`, and no
  `/live/error` of either shape. That also settles the in-memory question for
  every result below: the pre-merge bridge emits `["log", "…list index out of
  range"]` behind that same reply, and none appeared.

- `smoke_tests/auto/bridge.md § A wildcard fan-out answers every applicable
  match` — **new.** The fan-out contract: skipped endpoints send nothing and
  the ones after them still answer.

  *PR review, 2026-08-05 — passed.* `/live/clip/get/* 0 0` against a
  scratch MIDI clip returned **36** replies in one burst (16:21:42.15–.19),
  one per registered clip getter on its own concrete address, and **zero**
  `/live/error`. The audio-only four came back present-with-`nil`
  (`/live/clip/get/gain [0, 0, nil]`, and likewise `gain_display_string`,
  `warp_mode`, `warping`), independently reproducing the correction this
  branch made to the reference doc.

- `smoke_tests/auto/bridge.md § A failing generic method names the request that
  failed` — **new.** Case 2, via `/live/song/delete_scene` with no arguments.

  *PR review, 2026-08-05 — passed.* Exactly one datagram: `/live/error
  ["request", "/live/song/delete_scene", "Python argument types in
  Song.delete_scene(Song) did not match C++ signature: delete_scene(TPyHandle
  <ASong>, int)", 0]` — `"request"` tag, the address, `arg_count` 0 — and
  **zero** `"log"`-tagged copies. `get_clip_slots` reported 8 scenes before
  and 8 after, so nothing was deleted. Second independent live confirmation
  of case 2.

- `smoke_tests/auto/bridge.md § One rejection, one error datagram` — the
  duplicate-suppression invariant, which every widened case now also has to
  respect; corrected on 2026-08-05 to count per raise rather than per tool call.

  *PR review, 2026-08-05 — passed.* One `get_track_devices` on track 99
  produced exactly **three** `"request"`-tagged datagrams past the baseline
  offset — `/live/track/get/devices/name`, `/live/track/get/devices/type`,
  `/live/track/get/devices/class_name`, each carrying `"Index out of range",
  1, 99` — inside 1ms (16:22:10.567–.568), and **zero** `"log"`-tagged
  copies. Per-raise, not per-tool-call, exactly as the corrected wording says.

- `smoke_tests/auto/bridge.md § A rejected query fails fast, and says rejected`
  — case 1's direct half, the pre-existing coverage this widens.

  *PR review, 2026-08-05 — passed.* `get_track_devices` track 99 answered in
  **189ms** whole `mcp_call.py` round trip (Python startup and HTTP handshake
  included) against a 5,000ms query timeout, with `isError: true` and "Index
  out of range. Nothing further was sent — check get_session_state for the
  indices that actually exist." Live's own reason, not the guard-timeout
  wording. The "Ableton rejected the request:" prefix was correctly absent, as
  this test now instructs.

- `smoke_tests/auto/bridge.md § A bad index errors immediately, not after ~2s` —
  the vendored envelope handlers, unchanged by the merge but the standard
  stale-install detector whenever `priv/AbletonOSC` moves.

  *PR review, 2026-08-05 — passed at every depth, every reply naming the real
  count, all 0.175–0.231s.* `get_track_devices` return 99 → "this set has 0
  return track(s)"; `get_device_parameters` device 5 on the master → "the
  chain holds 0 device(s)"; `bypass_device` device 99 on the master →
  likewise; `bypass_device` device 99 on a regular track → "Index out of
  range". Against a scratch return carrying a Reverb: `set_device_parameter`
  device 99 → "the chain holds 1 device(s)", and parameter 999 → "there is no
  parameter 999 — 'Reverb' has 33 parameter(s)", echoing the value actually
  asked for, so the historical `-1` echo is still gone.

- `smoke_tests/auto/bridge.md § Live's Log.txt stays clean during ordinary work`
  — the merge changes what reaches the log on every failing request; rescoped
  2026-08-05 after it failed on a mirror-rebuild race unrelated to this change.

  *PR review, 2026-08-05 — passed on the load-bearing half; the accepted
  exception did not recur.* `write_midi_notes`, `duplicate_clip`,
  `get_clip_slots` and two `delete_clip`s produced **zero** ERROR lines past
  the baseline offset — that is where the upstream `RemoteScriptError`
  regression would show. The `create_track` → `delete_track` pair then
  produced no `IndexError` burst at all this run (zero ERROR lines in
  `Log.txt`, zero `/live/error` of either shape in `log/dev.log`), where the
  2026-08-05 run saw seven. Per this test's own timing-dependence note, a
  quiet run is not evidence either way about the rebuild race; the clip half
  is what passed.

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
