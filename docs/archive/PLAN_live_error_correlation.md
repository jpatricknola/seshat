# Plan: Correlate `/live/error` so a failed query fails fast

> **Archived 2026-08-03 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. All four parts landed: the
> fork's `osc_server.py` (`process_message`'s exact-match branch) and
> `manager.py` (`LiveOSCErrorLogHandler.emit`) now send a structured
> `/live/error` request-context payload; `Seshat.OSC.Transport` gained the
> `/live/error` `dispatch/3` clause, `failed_request/2`, `wire_args_match?/2`
> and `describe_error/1`; callers in `Seshat.Session.State`,
> `Seshat.Commands.Registry` and `Seshat.Library.Catalog` render the new
> error; and `docs/abletonosc-api-docs.md` plus `vendored_addresses_test`
> cover the new payload shape. No follow-ups were opened — the plan's two
> open questions were both closed (one by measurement at plan time, one
> flagged non-blocking with no test asserting on Live's message text). The
> "Monitored refresh worker for `Session.State`" roadmap item, explicitly
> gated on this fix, is still open pending re-measurement now that the
> blocking window this fix targeted has shipped.

Roadmap item: **"Correlate `/live/error` so a failed query fails fast"**
(shipped 2026-08-03).

## Context

When Live rejects a request — the canonical trigger is an indexed getter whose
index vanished mid-walk — AbletonOSC announces the rejection immediately on
`/live/error`, but Seshat consumes nothing on that address. The in-flight query
then waits out its full `@query_timeout` (5,000ms) to conclude what the error
already said. Measured 2026-08-02 (roadmap entry, reproduced while fixing the
`undo`/`redo` honest-reporting defect):

```
OSC in: /live/track/get/name [1, "Bass"]
OSC in: /live/error ["Error handling OSC message: Index out of range"]
OSC in: /live/song/get/tracks ["1-MIDI"]
```

The cost is not local: `Seshat.OSC.Transport` keeps exactly one query in flight
and queues the rest FIFO, and `Seshat.Session.State.do_refresh/1` runs
synchronously inside its GenServer — so one rejected index stalls every OSC
query in the process, and every mirror read, for five seconds. The structural
race itself is handled correctly (`read_tracks/2` returns `{:degraded, i}` and
refuses the partial list); only the *cost of detection* is wrong.

**Why the payload is the blocker, and why it is ours to fix.** `/live/error`
today carries only a formatted log message. It is emitted by a generic logging
relay in the fork's [manager.py:53-64](../../priv/AbletonOSC/manager.py#L53) — a
`logging.StreamHandler` on the `abletonosc` logger that fires on every
error-level record — and the exception that matters is caught in
[osc_server.py `process()`](../../priv/AbletonOSC/abletonosc/osc_server.py#L190),
*outside* the per-message callback, where the offending address and arguments
are no longer in scope. Correlating on the message string alone is impossible
(no address), and correlating on address alone is unsafe (an error delayed past
a timeout could fail the next query to the same address with different
indices). So the fork gains request context at the callback boundary, where
`message.address` and `message.params` are both in hand.

**Where the exceptions actually flow** (verified against the fork source, not
the installed copy):

- The fork's [handler.py](../../priv/AbletonOSC/abletonosc/handler.py) catches and
  only logs failures *inside* `_call_method` and `_set_property` (upstream
  PR #208, hand-applied), and `_get_property` catches `RuntimeError` and
  replies with a `None` value. None of those raise through to the dispatcher.
- What does raise through the callback is **index resolution**: upstream's
  per-object callbacks index the LOM before calling the generic helper —
  [track.py:21](../../priv/AbletonOSC/abletonosc/track.py#L21)
  (`track = self.song.tracks[track_index]`, no bounds check) and the same
  shape in `clip.py`, `clip_slot.py`, `device.py`, and `song.py`'s
  `song_get_track_data`
  ([song.py:137](../../priv/AbletonOSC/abletonosc/song.py#L137)). Live raises
  ("Index out of range"), the exception unwinds through `process_message` to
  `process()`'s per-datagram catch, gets logged, relayed, and **no reply is
  ever sent**. That is precisely the fast-fail target: every getter Seshat
  queries with a possibly-stale index — the mirror's per-track name walk,
  `query_echoed/5`'s pre-mutation guards, `get_clip_slots`'s `track_data`
  batches — currently pays a full timeout for it.
- Seshat's own handlers (`browser.py`, `return_track.py`,
  `view.py`'s getter) catch internally and reply in the ok/error envelope, so
  they neither need nor produce structured errors. Both mechanisms coexist:
  the envelope answers on the queried address, the structured error answers
  when the callback raised before any reply could be built.

The wire contract (from the roadmap entry, adopted unchanged):

- `/live/error ["request", address, message, arg_count, ...request_args]` — a
  handler failure, carrying the request that produced it.
- `/live/error ["log", message]` — an error with no originating OSC request
  (parse failures, wildcard-branch failures, handler-internal error logs).
  These must remain explicitly uncorrelated, never guessed onto the current
  query.

`arg_count` makes the variable tail explicit and preserves zero-argument
requests without a special case.

## OSC contract

One address, two payload shapes, both **push-only** — nothing registers
`/live/error` as a handler and nothing queries it; AbletonOSC sends it to the
fixed `127.0.0.1:11001` reply destination.

| Address | Payload | Meaning |
|---|---|---|
| `/live/error` | `["request", address (s), message (s), arg_count (i), ...request_args]` | The request `address` + `request_args` raised inside its handler callback; `message` is the exception text. Sent instead of a reply — the request gets no other answer. |
| `/live/error` | `["log", message (s)]` | An AbletonOSC error with no originating request context. Never correlated. |

`request_args` are `message.params` echoed back through pythonosc's
`OscMessageBuilder`, so each element keeps its wire type: OSC `i` stays `i`,
`f` stays `f` (already the 32-bit value after the inbound parse, so re-encoding
is lossless), `s` stays `s`. Seshat's own queries only ever send `i`/`f`/`s`
([message.ex:164-166](../../lib/seshat/osc/message.ex#L164)), so the echoed tail
is always decodable by `Seshat.OSC.Message.decode/1`.

**Float caveat, load-bearing for the matcher:** Elixir floats are 64-bit and
OSC `f` is 32-bit, so a float argument comes back as the 64-bit widening of its
32-bit truncation — `==` against the original Elixir float fails for values not
representable in 32 bits. The Elixir matcher must compare a sent float after a
32-bit round-trip (`<<v::big-float-32>> = <<sent::big-float-32>>`). Float args
do occur in real queries (`/live/clip/get/notes`' time-range arguments).

This is a **fork change**: two commits (one in the `priv/AbletonOSC` submodule,
one bumping the pin here), then `mix abletonosc.install` and a Live restart on
the user. **No test in this repo executes the Python** — its verification lives
entirely in the Live verification section.

## Part 1 — the fork preserves request context at the callback boundary

Files: [priv/AbletonOSC/abletonosc/osc_server.py](../../priv/AbletonOSC/abletonosc/osc_server.py),
[priv/AbletonOSC/manager.py](../../priv/AbletonOSC/manager.py),
[priv/AbletonOSC/SESHAT.md](../../priv/AbletonOSC/SESHAT.md).

**`osc_server.py` — `process_message`, exact-match branch only.** Wrap the
callback invocation in `try`/`except Exception`:

```python
if message.address in self._callbacks:
    callback = self._callbacks[message.address]
    try:
        rv = callback(message.params)
    except Exception as e:
        detail = str(e) or type(e).__name__
        self.logger.error("AbletonOSC: Error handling OSC message %s: %s"
                          % (message.address, detail),
                          extra={"osc_request_error": True})
        self.logger.warning("AbletonOSC: %s" % traceback.format_exc())
        self.send("/live/error",
                  ("request", message.address, detail,
                   len(message.params), *message.params))
        return
    if rv is not None:
        ...unchanged...
```

Decisions inside that shape, each with its reasoning:

- **The structured send goes out directly via `self.send`, not through the log
  relay** — the relay has no request context, and the contract belongs in one
  place. The `extra={"osc_request_error": True}` marker is what stops the
  manager's relay from *also* sending a legacy `/live/error` for the same
  record (Part 1's manager change reads it); the file log keeps its
  error-level line either way, now with the offending address in it.
- **`str(e) or type(e).__name__`** — a bare `Exception()` stringifies empty,
  and an empty message field would render as a blank rejection in a tool
  result.
- **The wildcard branch (`"*" in message.address`) is deliberately left on
  legacy behaviour.** Seshat never sends wildcard queries, the branch already
  swallows `ValueError`/`AttributeError` by design, and a structured error
  would have to choose between the pattern address and the concrete callback
  address — cost with no consumer. A raise there still unwinds to `process()`'s
  per-datagram catch and relays as `["log", …]`.
- **Bundles are covered for free** — `process_bundle` funnels each message
  through `process_message`.
- **`process()`'s outer try/except stays**, guarding parse errors and the
  wildcard branch; callback failures simply no longer reach it.

**`manager.py` — `LiveOSCErrorLogHandler.emit`.** Three edits:

- Skip records marked `osc_request_error` (the structured send already carried
  them).
- Tag the relay payload: `self.osc_server.send("/live/error", ("log", message))`.
- Replace `message[message.index(":") + 2:]` with a `partition`-based strip
  that keeps the whole message when no `": "` is present — the current code
  raises `ValueError` inside `emit` on any colon-free error message (swallowed
  by `logging`, but the relay silently drops that error). In-passing
  robustness fix on a line this change already edits.

**`SESHAT.md`** gains an entry under "Additions to upstream's code" recording
both files' changes, the wire contract, and the merge hazard: losing the
structured send in an upstream merge is invisible — every address still
answers, queries just go back to timing out on rejection. Part 4's grep
tripwire is the mechanical half of that record.

Commit sequence per [.claude/rules/osc.md](../../.claude/rules/osc.md):
`git -C priv/AbletonOSC checkout master` first, commit and push inside the
submodule, `git add priv/AbletonOSC` from the root in the same Seshat commit as
the Elixir side. `mix abletonosc.install` + Live restart before any live
verification — a green `mix test` says nothing about Python Live has never
loaded.

## Part 2 — Transport correlates a structured error with the in-flight query

File: [lib/seshat/osc/transport.ex](../../lib/seshat/osc/transport.ex).

A new `dispatch/3` clause, **ahead of** the existing address-match clause (its
own guard keeps it from shadowing anything: nothing ever queries
`/live/error`, but ordering it first makes that a non-question):

```elixir
defp dispatch("/live/error" = address, args, %{in_flight: request} = state)
     when not is_nil(request) do
  case failed_request(args, request) do
    {:match, message} ->
      Process.cancel_timer(request.timer)
      GenServer.reply(request.from, {:error, {:live_error, message}})
      broadcast(address, args)
      advance(%{state | in_flight: nil})

    :no_match ->
      broadcast(address, args)
      state
  end
end
```

with the matcher:

```elixir
defp failed_request(["request", address, message, arg_count | echoed],
                    %{address: address, args: sent})
     when is_binary(message) and length(echoed) == arg_count do
  if wire_args_match?(echoed, sent), do: {:match, message}, else: :no_match
end

defp failed_request(_args, _request), do: :no_match
```

`wire_args_match?/2` requires equal lengths and per-element, same-type
equality: integers and strings compare with `==`, a sent float compares
against the echo only after the 32-bit round-trip described in the OSC
contract, and any type mismatch (including an echoed `true`/`false`/`nil`,
which Seshat never sends) is a non-match. Strictness is deliberate: a false
negative costs a timeout — exactly today's behaviour — while a false positive
fails the wrong caller's query.

What this makes true, mirroring the dispatch ok-path exactly (timer cancelled,
caller replied, `advance/1` immediately puts the next queued request on the
wire):

- A matching handler error releases the queue **immediately** with
  `{:error, {:live_error, message}}`. `Transport.query/3`'s contract is
  unchanged for every other outcome — timeout still exits, it still never
  returns `nil`.
- Everything else — `["log", …]`, a legacy one-string payload, a structured
  error whose address, arity or arguments differ from the in-flight request,
  and any `/live/error` with no query in flight (falls through to the existing
  broadcast-only clause) — is broadcast and answers nobody, exactly as today.
- Matched or not, the message is still broadcast on PubSub, keeping dispatch's
  uniform "everything decodable is broadcast" behaviour; nothing currently
  subscribes to `/live/error`, and suppressing it would cost observability for
  no gain.

**Moduledoc updates, required, not cosmetic** — two statements the change
falsifies: "A reply whose address does not match the in-flight request is
broadcast and answers nobody" gains the `/live/error` exception, and the
"Query serialization" section gains a third residual class: *a structured
error delayed past a timeout can fail the immediately following query to the
same address with identical arguments* — same shape as residual class 1, but
strictly safer (the caller gets a refusal it can retry, not wrong data that
looks right). Note there too that all knowledge of `/live/error`'s payload
lives in this module; callers see only `{:error, {:live_error, message}}`.

Also add a one-line `describe_error/1` public helper to `Transport`:
`{:live_error, message}` → `"Ableton rejected the request: #{message}"`, any
other reason → `inspect(reason)`. The `{:live_error, _}` term is Transport's
contract, so its default human rendering lives beside it; Handlers, Registry
and Catalog all already depend on Transport, and this is what keeps Part 3
from teaching three modules the term's shape independently.

## Part 3 — callers render the new error, preserving their existing behaviour

The audit below covers **every** `Transport.query/3` call site in `lib/`
(grep: `Transport.query`, plus `Session.State`'s `transport.query` seam). The
rule: each caller's degraded/error path keeps its current *shape*; the only
change is that a raw `{:live_error, …}` tuple must never reach a tool result
via `inspect/1`.

- **`Seshat.Session.State` — no change.** `probe/4`
  ([state.ex:1179-1186](../../lib/seshat/session/state.ex#L1179)) already returns
  `{:error, reason}` for any non-ok query result, and every query helper's
  fall-through turns that into `nil` — so a live error makes `read_tracks/2`
  hit its `{:halt, {:degraded, i}}` branch in milliseconds instead of after
  5s. The roadmap's "the structural race still degrades, never serves a
  partial list" requirement is satisfied by construction; the test in Part 5
  pins it.
- **`Seshat.Tools.Handlers` — `query_echoed/5` and `read_all_notes/3`**
  ([handlers.ex:4838-4858](../../lib/seshat/tools/handlers.ex#L4838)): add a
  `{:error, {:live_error, message}} -> {:error, remote_error(message)}` clause
  ahead of the generic `{:error, reason}` fallback. `remote_error/1` is
  exactly the right rendering: it already serves the vendored envelope's error
  arm ("…Nothing further was sent — check get_session_state for the indices
  that actually exist."), and a live error on a guard query means the same
  thing — the index doesn't exist. Upstream and vendored addresses now fail a
  guard identically, which is the closing of a long-standing asymmetry, not a
  coincidence.
- **`Seshat.Tools.Handlers` — every `{:error, reason} -> {:error,
  inspect(reason)}` fallback, replaced wholesale.** The pattern occurs **51
  times** at time of review (2026-08-03), textually uniform — grep the exact
  string and replace `inspect(reason)` with `Transport.describe_error(reason)`
  at **every** occurrence, rather than working from an enumerated line list.
  (An earlier revision of this plan listed ~15 lines; review found that list
  both incomplete — it missed the query-fed fallbacks in `list_browser_items`
  (~2668), all three `load_device` target clauses (~2714/2748/2789),
  `get_clip_slots`' track-data else (~3205) and `query_vendored_list` (~3996)
  — and padded with send-fed setter fallbacks (886, 1642–1684) that can never
  see a `{:live_error, …}`. Blanket replacement closes the gap and is
  behaviour-preserving by construction: `describe_error` falls back to
  `inspect`, so send-fed sites are unchanged and only `{:live_error, …}` gains
  prose.) The fallbacks inside `query_echoed/5` and `read_all_notes/3` get the
  same replacement *in addition to* the `remote_error/1` clause the previous
  bullet adds ahead of them — after that clause the swept fallback no longer
  sees a live error, so the replacement there is belt-and-braces, not
  double-rendering. Sites that pattern-match specific error shapes without an
  inspect fallback (`follow-cam count`'s `_other -> :error`,
  `history_guard`'s malformed-reply branch) already degrade correctly and are
  listed here as verified-no-change.
- **`Seshat.Commands.Registry`** — three sites pass `{:error, reason}` through
  raw ([registry.ex:98-127](../../lib/seshat/commands/registry.ex#L98),
  `return_track_count/1`, `track_count/1`), relying on Handlers' `is_binary`
  check plus inspect fallback. Same treatment: render via
  `Transport.describe_error/1` at each site so the string that reaches
  Handlers is already prose. `ensure_clip/4`'s live error additionally keeps
  its site's framing ("…so no notes were written") by appending the
  consequence sentence its timeout branch already uses — a rejected slot
  lookup and an unanswered one carry the same "nothing was written" guarantee.
- **`Seshat.Library.Catalog` — `export_browser/0`**
  ([catalog.ex:914-940](../../lib/seshat/library/catalog.ex#L914)): the
  `{:error, reason}` branch passes raw today. Render via
  `Transport.describe_error/1`. Practically unreachable (`/live/browser/export`
  takes no args and catches internally, so only a zero-arg raise before the
  handler's own try could produce a matching structured error), but the branch
  exists and must not leak a tuple.

No tool definitions change, no new tool, no tool-count bump, no
`Seshat.MCP.*` change — the MCP surface is untouched.

## Part 4 — docs and tripwires

- **[docs/abletonosc-api-docs.md](../../docs/abletonosc-api-docs.md)** — the
  `/live/error` row in "Status Messages" gets both payload shapes (the OSC
  contract table above, condensed) and a pointer to SESHAT.md. This file is
  canonical; the fork change does not exist until it is recorded here.
- **[test/seshat/osc/vendored_addresses_test.exs](../../test/seshat/osc/vendored_addresses_test.exs)**
  — a new grep-based describe alongside "the loopback-only network boundary",
  because this divergence has the same failure mode: losing it in an upstream
  merge is invisible (every address still answers; queries just quietly go
  back to timing out on rejection, and `mix test` stays green). Three greps:
  `osc_server.py` still builds the `("request", message.address, …)` payload;
  `manager.py`'s relay still tags `("log", …)` and still checks the
  `osc_request_error` marker; `SESHAT.md` still records the divergence. Note
  `/live/error` itself needs no entry in the address lists — nothing in `lib/`
  *sends* it, so the used→registered sweep never sees the literal in
  `transport.ex` (it matches none of the vendored prefixes or exact lists).

## Testing

All pure, no Ableton. Nothing new tests through `Transport.query/3` against a
real Live — `OSCSink` plays AbletonOSC per
[.claude/rules/testing.md](../../.claude/rules/testing.md).

**[test/seshat/osc/transport_test.exs](../../test/seshat/osc/transport_test.exs)**,
new describe "failed-query correlation" (the sink injects `/live/error`
datagrams with `send_datagram/3`; the existing `encode/2` builds the payloads):

1. A structured error matching the in-flight address and args returns
   `{:error, {:live_error, message}}` well before the query timeout.
2. FIFO advance: query B queued behind erroring query A is sent immediately
   after A's error and still gets its own reply.
3. Mismatched address → broadcast only; the query survives to be answered by
   its real reply (or times out if none comes).
4. Same address, different args (the delayed-straggler case from the roadmap:
   same getter, different index) → not delivered.
5. Same address, same arg values but wrong `arg_count` → not delivered
   (malformed-structured case).
6. Legacy one-string `/live/error ["…"]` and `["log", "…"]` → broadcast only,
   never delivered.
7. `/live/error` with **no query in flight** → broadcast, transport state
   untouched (no crash, next query unaffected).
8. Float-argument matching: a query sent with a float arg not representable in
   32 bits (e.g. `0.1`) is failed by a structured error echoing the 32-bit
   round-tripped value — the case naive `==` gets wrong.
9. A matched error is still broadcast on PubSub (subscribe in the test,
   assert receipt).

**[test/seshat/session/state_test.exs](../../test/seshat/session/state_test.exs)**:
through the existing stub-transport seam, a `read_tracks` walk whose name
query returns `{:error, {:live_error, "Index out of range"}}` yields
`{:degraded, i}` / `tracks: nil` exactly as an unanswered query does — pinning
the roadmap's "existing structural-race path still refuses the partial
mirror".

**[test/seshat/tools/handlers_test.exs](../../test/seshat/tools/handlers_test.exs)**:
one OSCSink-driven case (the narrow allowed shape: the test's own sink answers
the guard query) where a pre-mutation guard receives a structured `/live/error`
for its own request: the tool replies with `remote_error/1`'s wording — assert
the "Nothing further was sent" phrasing and that **no mutation datagram
follows** (`refute_receive` at the wire).

**[test/seshat/osc/vendored_addresses_test.exs](../../test/seshat/osc/vendored_addresses_test.exs)**:
Part 4's greps.

What the suite cannot cover, by construction: that Live's embedded Python
actually emits the new payload (types, ordering, the relay's skip marker).
That is the Live verification below, and it requires `mix abletonosc.install`
plus a Live restart first.

## Live verification

Nothing in `mix test` reaches any of this — every pure test feeds the
structured errors from `OSCSink`, so the suite proves how Seshat reacts to the
payload, never that Live emits it. These checks assume **zero** prior
coverage. All of them require `mix abletonosc.install` and a Live restart
first (bridge.md's change-verification precondition). Run with `/smoke-test`.

- `smoke-tests/bridge.md § A rejected query fails fast, and says rejected` —
  written for this change. The end-to-end fast-fail: a real rejected indexed
  getter answers in milliseconds with the rejection wording, including the
  float-argument variant that exercises the matcher's 32-bit round-trip
  against a real echo.
- `smoke-tests/bridge.md § One rejection, one error datagram` — written for
  this change. The end-to-end check that the relay actually skips
  marked records: a duplicate `"log"`-tagged copy of the same rejection is
  the observable. (The marker *mechanism* was already measured at plan time —
  see Open questions — so a failure here points at the relay edit, not at
  Live's logging.)
- `smoke-tests/bridge.md § Only the offender fails` — written for this change.
  The correlation-strictness check against a real queue: an adjacent valid
  query must be answered normally, and the FIFO must advance immediately after
  the error.
- `smoke-tests/bridge.md § Live's Log.txt stays clean during ordinary work` —
  existing. The fork commit edits the error logging path itself
  (`osc_server.py`'s catch, `manager.py`'s relay); ordinary non-erroring work
  must not gain tracebacks or new noise.
- `smoke-tests/mirror.md § A degraded rebuild is honest` — existing. The
  structural race is this item's original trigger; the degraded path must
  still refuse a partial list, now reaching that refusal in milliseconds.
  Note when running: this change makes the race markedly harder to provoke —
  the vulnerable window per rejected index shrinks from ~5s to ~one AbletonOSC
  tick — so a run that never degrades tests the coalescing, not this.

**Uncovered:** the `["log", …]` arm against real Live — nothing on the tool
surface can provoke an error with no originating request (unknown addresses
and parse errors are unreachable through validated tools), so it is covered
only by the pure OSCSink tests; benign, since a `"log"` payload is never
correlated by construction. The wildcard dispatch branch — Seshat never sends
wildcard queries. Rejection classes other than a bad index (different LOM
raise sites carry different message texts) — display-only, the structure is
identical and nothing matches on the text. A structured error racing a
*timed-out* predecessor with identical arguments — the documented residual
class; not provokable on demand and safe in direction (a refusal, not wrong
data).

## Out of scope

- **The monitored refresh worker** ("Monitored refresh worker for
  `Session.State`", roadmap) — explicitly gated on this item landing first;
  this fix cuts the observed blocking window from ~5,000ms to roughly one
  AbletonOSC tick (≤100ms), which may retire that item entirely. Stays on the
  roadmap.
- **Correlating errors for fire-and-forget sends.** A setter or method that
  raises now produces a structured `/live/error` too, but nothing waits on a
  send, so Transport ignores it beyond the broadcast. Turning it into setter
  acknowledgements was already rejected ("Verify destructive mutations…"
  planner notes); the guard-then-send house pattern stands.
- **A request id on the wire.** Settled when the query queue was built
  (Transport moduledoc: "none is coming"); `address + args` equality is this
  plan's whole correlation strength, and its residual (identical consecutive
  requests) is documented rather than closed.
- **Structured errors from the wildcard dispatch branch** — no consumer,
  see Part 1.
- **`_get_property`'s `RuntimeError` swallow** (replies `None` instead of
  erroring, e.g. inapplicable properties) — upstream behaviour, callers
  already tolerate it, and changing it would alter reply shapes across the
  whole API for no queued need.

## Open questions

1. **Resolved by measurement, 2026-08-03 (Live 12.4.3, embedded Python):**
   Live's embedded `logging` delivers `extra={"osc_request_error": True}` to a
   sibling handler's `record` — a temporary probe in the *installed* copy
   (per the rig in
   [.claude/docs/ableton-osc-reference.md](../../.claude/docs/ableton-osc-reference.md),
   restored with `mix abletonosc.install` and confirmed gone afterwards)
   logged an error with that `extra` and read
   `getattr(record, "osc_request_error", None)` back as `True` from a handler
   on the `abletonosc` logger. The marker mechanism in Part 1 is safe as
   specced. The `smoke-tests/bridge.md § One rejection, one error datagram`
   check remains cited as the end-to-end regression for the relay actually
   *skipping* marked records — the probe measured the mechanism, not the
   edited relay.
2. ⚠️ **Exception text stability.** "Index out of range" was measured
   2026-08-02 for a vanished track index; other rejection classes
   (`clip_slot`, `device`, non-LOM raises) will carry different texts. Nothing
   in the design matches on the message — it is display-only — so this is
   flagged only to stop a future reader from pinning wording in a test.
   *Assumption:* none needed; tests must assert on structure, never on Live's
   message text.

No other question stayed open: the trigger behaviour, error timing relative to
the in-flight query, and the exception's path to `process()` were all either
measured on 2026-08-02 (roadmap entry) or verified against the fork source
directly, and the float-matching hazard is fully resolvable in a unit test.
