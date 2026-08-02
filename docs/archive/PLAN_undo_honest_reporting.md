# Plan: `undo`/`redo` stop reporting success they never observed

> **Archived 2026-08-02 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. Part 1 and Part 2 both
> landed: the honest reply lives in `Seshat.Tools.Handlers`' `history_move/1`,
> the three-way `can_undo`/`can_redo` guard in `history_guard/2`, and the
> updated `undo`/`redo` descriptions in `Seshat.Tools.Definitions`. No fork
> change — both guard addresses were already upstream. No follow-ups were
> opened; the plan's two open questions (does `can_undo` really report
> `false` at the bottom of the history, and is `undo`'s boundary behaviour
> identical to the measured `redo`) remain unverified against a live Ableton
> and are now a smoke-test check
> ([.claude/skills/smoke-test/SKILL.md](../../.claude/skills/smoke-test/SKILL.md))
> rather than an open item — see that check before trusting Part 2 in a real
> session.

Roadmap item: **"`undo` reports success it never observed"** (currently #1).

## Context

`undo` and `redo` return a hardcoded success string the moment
`:gen_udp.send/4` accepts the datagram:

```elixir
defp do_call("undo", _params) do
  case Transport.send_message("/live/song/undo", []) do
    :ok -> {:ok, "Undone"}
```

`/live/song/undo` never replies, so `:ok` cannot mean anything more than "the
UDP socket accepted these bytes." A dropped datagram, an unexpected step on top
of the history, and reaching the bottom of the history all produce the identical
`"Undone"`.

**Measured 2026-08-02, against a live set.** Three MIDI tracks were created
(Bass, Keys, Drums) and restored with `redo` × 3, leaving the redo stack empty.
One further `redo` returned `"Redone"` while a refreshed `get_session_state`
confirmed Live had not moved — no track added, no track removed. The lie is
reproducible on demand, with no race and no lost packet required.

⚠️ That measurement was taken on `redo`. `undo` past the bottom of the history is
**inferred** to behave identically from the code — the two clauses are the same
shape, both send-only to addresses that never reply — but was not directly
measured, because exhausting the history would have reverted the user's own prior
work in the open set. See Open questions.

**Why it matters now.** `undo`'s description instructs the model to call it once
per mutating tool call when reversing a request. That instruction deliberately
walks the model *toward* the end of the history, and the end of the history is
exactly where the reply stops meaning anything. The failure is silent: the model
reports N successes, the user finds the leftovers.

**Superseded evidence — do not plan against it.** This item originally rested on
a 2026-08-01 measurement in which three undos left the first-created track
standing. That no longer reproduces (re-run 2026-08-02: three creates, three
undos, all three reverted cleanly). It almost certainly raced "One Seshat action,
one undo step" landing the same day. Nothing in this plan addresses that symptom.

## OSC contract

No new addresses, **no fork change, no `mix abletonosc.install`, no Live
restart.** Both guards are upstream properties that already ship.

| Address | Request args | Reply | Source |
|---|---|---|---|
| `/live/song/undo` | *(none)* | **none, ever** | upstream `song.py` generic methods |
| `/live/song/redo` | *(none)* | **none, ever** | upstream `song.py` generic methods |
| `/live/song/get/can_undo` | *(none)* | `/live/song/get/can_undo [bool]` | upstream `song.py` `properties_r` |
| `/live/song/get/can_redo` | *(none)* | `/live/song/get/can_redo [bool]` | upstream `song.py` `properties_r` |

Verified in [docs/abletonosc-api-docs.md](../abletonosc-api-docs.md) lines 84/90
(undo/redo) and 117/118 (can_redo/can_undo), and against the fork source at
[priv/AbletonOSC/abletonosc/song.py:84-95](../../priv/AbletonOSC/abletonosc/song.py#L84-L95),
where `can_redo` and `can_undo` sit in `properties_r` and are registered through
the same `_get_property` loop as `is_playing`. Song properties take no index, so
the reply carries the bare value with no envelope and nothing to echo-check.

**Reply shape is deliberately not pinned to one type.** `_get_property` returns
Live's raw Python value; a bool reaches the wire as OSC `T`/`F`, which
[message.ex:133-134](../../lib/seshat/osc/message.ex#L133-L134) decodes to
`true`/`false`. `Seshat.Session.State.query_song_int/2` nonetheless accepts
`[v] when is_integer(v)` *and* `[true]`/`[false]`, and this plan copies that
tolerance rather than betting on one shape — which makes measuring the exact
encoding unnecessary rather than merely deferred.

## Part 1 — `undo`/`redo` stop asserting

[lib/seshat/tools/handlers.ex:2186-2198](../../lib/seshat/tools/handlers.ex#L2186-L2198).

This is the honest floor and lands independently of Part 2.

Replace the `{:ok, "Undone"}` / `{:ok, "Redone"}` strings with wording that
reports the *request*, not the outcome. Draft:

- undo: `"Undo requested. Ableton does not acknowledge undo, so this confirms the
  request was sent, not that history moved. Verify once after the batch with
  get_session_state."`
- redo: `"Redo requested. Ableton does not acknowledge redo, so this confirms the
  request was sent, not that history moved. Verify once after the batch with
  get_session_state."`

Checkable: no code path may return a string asserting that history moved.

## Part 2 — guard on `can_undo` / `can_redo`

Same two clauses. Before sending, query the matching guard and branch three ways:

| Guard result | Action | Reply |
|---|---|---|
| `false` twice in succession | **do not send** | `{:error, "Live reported no undo step available, so no undo was sent. Do not retry unless history has changed."}` |
| `true` | send | Part 1's wording |
| unanswered / malformed | **send anyway** | Part 1's wording plus `"Ableton did not answer the can_undo check, so whether there was anything to undo is unknown."` |

`redo`'s refusal is the same shape: `{:error, "Live reported no redo step
available, so no redo was sent. Do not retry unless history has changed; any new
edit can clear Live's redo history."}`

Three decisions worth stating, because each had a plausible alternative:

**Guard every call, not once per batch.** The roadmap entry says to check "before
the *first* undo of a batch." Reject that, for two reasons. First, `Handlers` has
no batch: each MCP `tools/call` is independent, so "first of a batch" would have
to be invented as cross-call state, and any such heuristic is guessable-wrong.
Second and decisively, an up-front check is **incorrect for the stated goal** — a
model calling `undo` three times against a two-deep history passes the single
up-front check and the third call still lies. The guard has to sit where the wall
is hit. The entry's supporting note conflates two different costs: what is ruled
out is a *state read* (a full `Session.State` rebuild, dozens of queries) per
call, not one scalar query. A single guarded query before a mutation is already
the house pattern — `delete_device` bounds-checks, `set_clip_properties` re-reads,
`hide_view` reads its pane back — and `@guard_timeout` exists for exactly this.

**Unanswered means proceed, not refuse.** Refusing on an unanswered guard would
turn a dropped datagram into a failed undo, which is a worse regression than the
defect being fixed. The item is about honest reporting, not about blocking; so
the send goes ahead and the reply states the uncertainty.

**Reuse `@guard_timeout` (2,000ms)**, already defined at
[handlers.ex:40](../../lib/seshat/tools/handlers.ex#L40) and used by every other
pre-mutation guard. No new constant.

**The unanswered branch is a `catch :exit`, not an `{:error, _}` clause.**
`Transport.query/3` **exits** the caller on timeout and *never* returns
`{:error, :timeout}` — stated outright at
[transport.ex:113-117](../../lib/seshat/osc/transport.ex#L113-L117), and visible at
[transport.ex:283-284](../../lib/seshat/osc/transport.ex#L283-L284), where the
server's own timer only reclaims the queue entry and deliberately does not
reply. A `case Transport.query(...)` with `{:ok, _}` and `{:error, _}` clauses
therefore does not reach the unanswered row of the table above: the tool call
dies instead, and a dropped datagram becomes an opaque MCP crash — strictly
worse than today, where `undo` at least always sends. Every one of the ~33
`catch :exit, _ ->` sites in `Handlers` exists for this; `query_echoed/5`
([handlers.ex:4825-4826](../../lib/seshat/tools/handlers.ex#L4825-L4826)) is the
guard-shaped one to copy. Checkable: the guard's unanswered path must be a
`catch :exit, _ ->` clause returning the send-anyway branch, and Testing item 4
below is what proves it.

**No echo check is possible, so confirm `false` once.** Song
properties take no index, so there is nothing for a reply to echo — which means
the caller-side defence CLAUDE.md insists is not redundant
(`Transport`'s "Query serialization") is unavailable here, and its two residual
collision classes have to be argued instead. Class 2 (a listener push satisfying
a query on the getter's address) cannot occur: nothing in `lib/` starts a
listener on `can_undo` or `can_redo`. Class 1 (a straggler from a timed-out
query answering the next query on the same address) is not benign in both
directions: a history-changing call between the two queries can make an old
`false` wrong. A stale `true` is safe because it only sends an undo whose reply
asserts nothing. On `false`, immediately query the same guard once more and
refuse only if the second recognized answer is also `false`; a `true` second
answer sends normally, and an unanswered or malformed second answer takes the
uncertain send-anyway path. This is the same reissue-once mitigation used by
the existing echoed guards, not perfect correlation — the wire has no request
id — so the refusal wording reports exactly the evidence Live supplied rather
than asserting the history state as an independently known fact.

**Ordering is load-bearing.** `undo_stepped/2`'s `undo`/`redo` clause sends a
defensive `/live/song/end_undo_step` *before* dispatching
([handlers.ex:282-285](../../lib/seshat/tools/handlers.ex#L282-L285)). The guard
query must stay **after** that send: closing a leaked step can legitimately add
an entry to the history, flipping `can_undo` from false to true, and a guard read
before the close would answer about a history state that no longer exists by the
time we send. Keep the existing clause as the seam and put the guard inside
`do_call/2`.

Both `undo` and `redo` remain outside the `begin`/`end` wrap, and both remain
inside `:global.trans` (`dispatch/2` wraps every known tool name), so the
guard-then-send pair is atomic against another Seshat caller. It is *not* atomic
against the user clicking in Live — accepted, and unfixable from here.

## Part 3 — teach the model what the new replies mean

[lib/seshat/tools/definitions.ex:481-506](../../lib/seshat/tools/definitions.ex#L481-L506).

The strings above are wasted if the model reads a "no step available" error and
keeps calling. Add to `undo`'s description (and the matching sentence to
`redo`):

> The reply confirms the request was sent, not that Live's history moved —
> Ableton does not acknowledge undo. If Live reports no undo step available,
> stop calling undo and tell the user; do not retry unless history has changed.
> Verify a batch once at the end with get_session_state, never after each call.

Keep both descriptions' existing guidance intact; this is an addition. No new
tool, so **no tool-count bump** in `definitions_test.exs`.

## Testing

**Pure (no Ableton), in `test/seshat/tools/handlers_test.exs`:**

1. `can_undo` answered `false` twice → no `/live/song/undo` on the wire,
   `{:error, _}` returned. Assert the absence at the wire with
   `refute_receive`, and pin the observational "Live reported" wording.
2. `can_undo` answered `true` → `/live/song/undo` sent, reply does not assert.
3. First answer `false`, second answer `true` → `/live/song/undo` sent. This is
   the tripwire for the same-address straggler defence.
4. Either guard attempt unanswered or malformed → `/live/song/undo` still
   sent, reply states the uncertainty.
5. Both reply shapes accepted: `[true]`/`[false]` and `[1]`/`[0]`.
6. Existing trace tests at
   [handlers_test.exs:347-360](../../test/seshat/tools/handlers_test.exs#L347-L360)
   must be updated — the expected trace gains the guard query between the
   defensive `end_undo_step` and the `undo`.
7. Same six for `redo`/`can_redo`.

These reach `Transport.query/3`, which
[.claude/rules/testing.md](../../.claude/rules/testing.md) forbids above the
transport layer. The precedent to follow is the `hide_view` test at
[handlers_test.exs:381-419](../../test/seshat/tools/handlers_test.exs#L381-L419),
which does exactly this: `OSCSink` plays AbletonOSC and answers the query by hand
with `OSCSink.send_datagram/3`. The rule's rationale — "needs a live Ableton and
will time out" — does not apply when the sink supplies the reply. Follow that
shape; do not start a real Transport against 11000/11001. Update
[.claude/rules/testing.md](../../.claude/rules/testing.md) in the same change with a
narrow second exception for handler tests whose test-local `OSCSink` supplies
the reply; the current rule names only Transport's own tests even though this
safe handler-test pattern already exists for `hide_view`.

**Prompt contract, in `test/seshat/tools/definitions_test.exs`:** pin that both
descriptions say a successful reply confirms only that the request was sent,
that a no-step-available reply stops retries, and that one verification read is
done after a batch rather than after each call. The tool count remains
unchanged.

**Needs Ableton (`/smoke-test`):**

8. In a **freshly created empty set** (so the history is genuinely empty), call
   `undo`. Expect the "Live reported no undo step available" error, not a
   success string. This is the check that proves `can_undo` actually reports
   `false` at the boundary — see Open questions.
9. Ordinary undo of a real change still works and still reverts exactly one step.

Add both checks to [.claude/skills/smoke-test/SKILL.md](../../.claude/skills/smoke-test/SKILL.md);
the Python/Live property behavior is not covered by the Elixir suite.

## Out of scope

- **A state read per `undo` call, and any retry of the undo/redo mutation.**
  Ruled out when "A degraded mirror rebuild is reported, never served" shipped;
  a batch costs one verification read *after* the batch. The one guard reissue
  after an uncorrelated `false` is only stale-reply mitigation and never repeats
  a mutation.
- **Verifying that the undo actually took effect.** Requires a before/after state
  comparison per call, which is the previous bullet. The reply stays honest about
  this rather than closing it.
- **The broader mutation-verification surface** — stays with "Verify destructive
  mutations before reporting success" on the roadmap.
- **The five-second stall on a rejected query** — stays with "Correlate
  `/live/error` so a failed query fails fast." It shares this item's OSC path and
  would shorten the unanswered-guard case from 2s to ~1ms, but is independent.

## Open questions

1. ⚠️ **Does `Song.can_undo` actually report `false` at the bottom of the
   history?** The whole of Part 2 rests on it. Live's API documents the property
   as undo availability, but the boundary behaviour is unverified here, and if it
   is always `true` the guard buys nothing and Part 2 should be dropped (Part 1
   still stands alone).
   *Why not resolved now:* it needs a Live session whose undo history is
   genuinely exhausted. The open set carries the user's own prior work, and
   reaching the bottom would have destroyed it — the one thing this session was
   not willing to spend.
   *Assumption in the meantime:* it reports `false`, consistent with Live's own
   greyed-out Undo menu item.
   *Cheapest resolution, for the implementer:* a brand-new empty set — test 8
   above is the check, and it should be run **before** building Part 2, not after.
2. ⚠️ **Is `undo`'s bottom-of-history behaviour identical to the measured
   `redo`?** Inferred from identical code shape, not measured, for the same
   reason as above. If test 8 shows the error, this is answered in passing.
   Nothing in the plan changes if it isn't — Part 1 is unaffected either way.

Neither question blocks Part 1, which is why Part 1 is written to land on its own.
