# Plan — Serialize OSC queries and clean up timed-out callers

> **Archived 2026-07-30 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. `Seshat.OSC.Transport` now
> queues queries behind a single in-flight request (`in_flight`/`queue` state,
> `lib/seshat/osc/transport.ex`), with a client-computed absolute deadline, a
> per-request timer that drops a timed-out caller without replying, and a
> cancel-timer race closed by matching the timer message against the in-flight
> ref. The two residual collision classes the moduledoc now names explicitly
> are unchanged from what this plan predicted. `REPOSITORY_REVIEW.md` finding
> #1 is left as written — a dated record of the defect before the fix, not
> current documentation. No open follow-ups; the roadmap item is removed.

Roadmap item "Serialize OSC queries and clean up timed-out callers".
Evidence: finding #1 in
[../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md), whose reviewer response
narrows the fix to an **Elixir-side queue only** — request identifiers on the
AbletonOSC wire are declined, permanently, as a protocol divergence carried
against upstream forever to solve what a queue already solves.

## Context

`Seshat.OSC.Transport` holds a single `pending` slot
([transport.ex:154-164](../lib/seshat/osc/transport.ex#L154)): a query stores
`{from, address}` and returns `{:noreply, ...}`, so the GenServer accepts the
next query immediately, and the next query *overwrites* the slot. Replies
correlate by OSC address alone ([transport.ex:205-215](../lib/seshat/osc/transport.ex#L205)).
Two overlapping queries therefore interact three bad ways:

- The overwritten caller waits out its full timeout for a reply that will be
  handed to someone else.
- Two overlapping queries to the *same* address with different arguments —
  the realistic trigger is `Session.State` re-reading every track name when
  the structure listener fires, asynchronously, from a different process than
  whatever tool call is in flight — hand caller B caller A's data. Caller-side
  echo checks (`Handlers.query_echoed/5`, `Session.State`'s query helpers,
  `Registry.ensure_clip/4`) catch the indexed cases, but only by *rejecting*
  the answer; the observed "replies running one index behind after an
  abandoned timeout" cascade in `Session.State.reconcile/4`'s comment is this
  defect wearing its most confusing coat.
- A timed-out caller's abandoned `{from, address}` lingers until the next
  query overwrites it. The `query/3` doc
  ([transport.ex:68-71](../lib/seshat/osc/transport.ex#L68)) explicitly
  reasons that "nothing needs cleaning up" — sound for sequential callers,
  unsound the moment two overlap. The roadmap asks for that reasoning to be
  rewritten with the fix.

The fix is entirely inside `Transport`: one query in flight at a time, a FIFO
queue behind it, an absolute per-request deadline that bounds queue time as
well as flight time, replies matched against the in-flight request only, and
the next request dequeued only on completion (reply or expiry). **No caller
changes**: `query/3`'s public contract — including
exit-on-timeout `GenServer.call/3` semantics that ~20 `catch :exit` sites in
`Handlers`, `Registry`, `Catalog` and `Session.State` are written against —
is preserved exactly, with one deliberate narrowing (`:infinity` leaves the
`@spec`; see Decisions). That compatibility is a deliberate decision, not an
accident, and it also keeps
[PLAN_stop_fabricating_session_state.md](PLAN_stop_fabricating_session_state.md)
(planned in this same run) true as written: its `probe/4`
catch-exit path, its timeout arithmetic, and its smoke-test timings all
survive this change unmodified.

What serialization does *not* fix — and this plan documents rather than
hides — is that correlation stays address-only, because there is no request
id on the wire and none is coming. Two residual collision classes remain:

1. **Consecutive same-address queries across a timeout.** Query A on address
   X times out; its late reply is still in transit when the queue advances to
   query B on the same X with different args; B consumes A's reply. Strictly
   narrower than today (it now requires a timeout *and* address adjacency
   *and* a straggler landing in the window, where today mere overlap
   suffices). Open question 2 enumerates every call site that can actually
   reach it — all four addresses two processes share are argument-free, and
   the three echo-less callers need a second concurrent client, because a
   timeout exits the caller and kills the `with` chain that would have
   issued the adjacent query.
2. **Listener pushes share the getter's address**
   ([ableton-osc-reference.md:197-201](../.claude/docs/ableton-osc-reference.md#L197)):
   a push on `/live/track/get/volume` can satisfy an in-flight query for the
   same property. Same as today; no queue can remove it.

Both are already defended at the call sites that gate mutations: the echo
checks reject a wrong-index answer and reissue once. And for the mirror,
the system *self-heals by broadcast*: `dispatch/3` broadcasts every datagram
(matched replies included), `Session.State` subscribes, so a genuine reply
that arrives after its query was abandoned still lands in the mirror as a
push.

State the guarantee precisely, because the imprecise version invites the
wrong conclusion. A late reply whose address does **not** match the current
in-flight request is **broadcast only** — no caller ever sees it. A late
reply whose address *does* match is, by construction, indistinguishable from
that request's own fresh reply, so it will be delivered: that is residual
class 1, accepted here as the price of the settled no-request-ID decision,
not a hole to plug. What the queue removes is the *overwrite* case, where
mere overlap was enough. Note also that suppressing unmatched late replies —
as a literal reading of the roadmap's "late replies discarded" might
suggest — would throw away current-value data the mirror puts to use.
"Discarded" here means: discarded as an answer to a query that did not ask
for it.

## OSC contract

**No new addresses, no Python half, no wire change.** This plan changes how
Elixir *correlates* replies with callers, not one byte of what goes on the
wire. Facts the design leans on, verified against
[abletonosc-api-docs.md](abletonosc-api-docs.md) and
[.claude/docs/ableton-osc-reference.md](../.claude/docs/ableton-osc-reference.md):

| Fact | Consequence for this plan |
|---|---|
| No request id exists on the wire, and adding one is declined (review #1 response) | Correlation stays address-only; residuals 1–2 above are accepted, not solved |
| A `get/*` address carries both query replies and listener pushes | The queue cannot distinguish them; caller echo checks remain load-bearing |
| Per-index getters echo the request's leading indices; `/live/song/get/track_data` and bulk replies do not | Transport-side echo matching would need a per-address reply-shape table — rejected (see Out of scope) |
| AbletonOSC replies to fixed port 11001 from its one socket | The queue lives in the one process that owns that socket; nothing else changes |

## Part 1 — `Transport`: one query in flight, FIFO behind it

All in [lib/seshat/osc/transport.ex](../lib/seshat/osc/transport.ex).

1. **Client side**: `query/3` computes an **absolute deadline** —
   `System.monotonic_time(:millisecond) + timeout` — and becomes
   `GenServer.call(__MODULE__, {:query, address, args, deadline}, timeout)`.
   An absolute deadline rather than the raw duration because the caller's
   `GenServer.call/3` timer starts here, on the *client*, while any server
   timer can only start once the message is received; two independent
   relative timers cannot be ordered, and every problem below comes from
   assuming they can. Signature, return type, and exit-on-timeout behaviour
   are unchanged; no call site changes. The `@spec` narrows from `timeout()`
   to `non_neg_integer()` (see Decisions).
2. **State**: replace `pending: nil` with `in_flight: nil` and
   `queue: :queue.new()`. A request is `%{ref, from, address, args, deadline,
   timer}` where `ref` is a `make_ref()` and `timer` the
   `Process.send_after/3` ref for `{:query_timeout, ref}`.
3. **Enqueue** (`handle_call({:query, address, args, deadline}, from, state)`):
   - Deaf clause first, arity updated: still replies
     `{:error, :reply_port_unavailable}` immediately, bypassing the queue.
   - Arm the timer at enqueue for the *remaining* time,
     `max(deadline - now, 0)`, so the server's timer tracks the caller's own
     deadline instead of restarting the clock. The deadline bounds the
     caller's *total* wait (queue time + flight time), matching what
     `GenServer.call/3` already meant to callers. A request queued behind a
     30s `/live/browser/export` with a 5s timeout expires at 5s, unsent.
   - **Check `deadline` against `now` before doing anything else**: already
     past → `{:noreply, state}`, neither sent nor queued, no timer armed, no
     reply. A call can be handled after its own deadline whenever the
     server's mailbox is backed up, and without this check the
     `in_flight == nil` branch below would send the datagram *before* the
     zero-duration timer message could be processed. Same check, same
     reason, as `advance/1`'s in step 6.
   - `in_flight == nil` → encode and `:gen_udp.send/4` now; on `:ok` it
     becomes in-flight (`{:noreply, ...}`), on `{:error, reason}` cancel the
     timer and `{:reply, {:error, reason}, ...}` as today.
   - Otherwise → `:queue.in/2`, `{:noreply, ...}`.
4. **Timer fires** (`handle_info({:query_timeout, ref}, state)`):
   **it never replies to the caller** — see the box below.
   - Matches in-flight → clear in-flight, advance the queue. That is all.
   - Matches a queued entry → remove it. Its datagram is never sent.
   - Matches nothing → ignore; this is the benign race where the reply and
     the timer message crossed (see cancel below).

   > **The internal timer must not `GenServer.reply/2`.** An earlier draft
   > had it send a best-effort `{:error, :timeout}`, reasoning that the
   > caller's own deadline had already fired and the reply was a harmless
   > no-op. That reasoning died with the absolute deadline in step 1: both
   > timers now target the *same instant*, so which one wins is a coin flip.
   > If the server's wins, its reply reaches the caller's selective receive
   > before `GenServer.call/3`'s `after` clause fires, and `query/3` returns
   > `{:error, :timeout}` instead of exiting — bypassing the ~20 `catch
   > :exit` branches this plan promises to preserve and swapping which
   > user-facing message fires in twenty tools. **The caller's own timer is
   > the sole authority on timeout behaviour.** The server's timer exists
   > only to free the pipeline and reclaim the entry.
   >
   > This does not extend to `dispatch/3` (step 5), which still replies.
   > Winning that race delivers `{:ok, _}` — a normal successful return that
   > every caller already handles — where winning this one would deliver an
   > error tuple where an exit was promised. Success arriving a millisecond
   > before the deadline is the system working; an error tuple arriving there
   > is a contract change.
5. **Reply arrives** (`dispatch/3`): match by address against **in-flight
   only**. On match: `Process.cancel_timer(timer)` (a `false` return means
   the `{:query_timeout, ref}` message is already in the mailbox — step 4's
   ignore clause absorbs it), `GenServer.reply(from, {:ok, {address, args}})`,
   broadcast, clear in-flight, advance. On non-match: broadcast only —
   exactly today's handling of pushes and unsolicited traffic, and the fate
   of every late reply that does not collide with the in-flight address.
   **No deadline check here, deliberately**: a reply for the request that is
   genuinely in flight is always delivered and always broadcast. Replying
   past the deadline costs nothing (the caller has exited and
   `GenServer.reply/2` to a departed caller is a no-op), while gating on the
   deadline would create a window where a caller whose own timer has not yet
   fired is denied an answer that arrived for it.
6. **Advance** (new private `advance/1`): pop the queue; empty → in-flight
   `nil`. Otherwise **check the popped request's deadline against
   `System.monotonic_time(:millisecond)` before sending**: already past →
   cancel its timer and pop again without sending and **without replying**
   (step 4's box: the caller's own timer owns that). Not past → encode and
   send: `:ok` → it becomes
   in-flight (its timer has been running since enqueue); `{:error, reason}` →
   cancel its timer, `GenServer.reply(from, {:error, reason})`, pop again.
   Invariant afterwards: `in_flight == nil` implies the queue is empty.

   That deadline check, not the timer arithmetic in step 3, is what makes
   step 4's "its datagram is never sent" true. Two timers in two processes
   can be brought close together but never ordered, and `{:query_timeout,
   ref}` can sit in the mailbox behind the very UDP datagram that completes
   the in-flight query — so `advance/1` can reach an entry that is expired
   but whose timer message has not been processed yet. Without the check it
   would send that datagram; the damage is small (a stray *read* whose reply
   becomes an unmatched broadcast, or worse, feeds residual class 1) but the
   check costs one comparison and keeps the documented contract honest.
7. **`send_message/2` bypasses the queue**, unchanged and deliberate:
   fire-and-forget setters must not wait behind a 30s device load; ordering
   *within* a caller is preserved because callers are sequential (a guard's
   `query` returns before its `send` is issued), and cross-caller UDP
   interleaving exists today. Say this in a comment on the `{:send, ...}`
   clause.
8. **Rewrite the docs the roadmap names.** `query/3`'s doc drops the
   "Nothing needs cleaning up" paragraph for the new contract: one query in
   flight, FIFO order, `timeout` bounds total wait (queue + flight) as an
   absolute deadline, an expired request is never sent — dropped at enqueue,
   removed by its own timer, or dropped at dequeue, whichever comes first —
   the caller learns of a timeout only by exiting on its own deadline and
   never by a `{:error, :timeout}` return, and a reply that does not match
   the in-flight request's address is broadcast without answering anyone. The
   moduledoc gains a short "Query serialization" paragraph stating the two
   residual collision classes from Context — including, in plain words, that
   a straggler *on the in-flight address* is indistinguishable from a fresh
   reply and can therefore answer the wrong query — and pointing at the
   caller-side echo checks as the remaining defense. Neither doc may claim
   that late replies never reach a caller; that is the overclaim this plan
   is careful not to write into the code.

## Part 2 — Tests

In [test/seshat/osc/transport_test.exs](../test/seshat/osc/transport_test.exs),
a new `describe "query serialization"` using the existing harness: sink
started before Transport, `forward_to: self()` so every datagram Transport
sends arrives as `{:osc_out, address, args}` (the synchronisation points —
no `Process.sleep/1`), replies injected with `OSCSink.send_datagram/3`, PubSub
subscribed where broadcast is asserted. Queries run in separate processes
(the caller must not be the test process); timeouts are short (100–200ms).
For tests where the query *succeeds*, `Task.async/1` is fine. For tests 3, 5
and 8, where a query is *expected to time out*, plain `Task.async/1` is a
trap: the `GenServer.call` timeout exits the task, the exit propagates over
the link, and it kills the test process. Use `spawn_monitor/1` (or
`Process.flag(:trap_exit, true)`) for those, and assert the timeout on the
`:DOWN` reason (`{:timeout, {GenServer, :call, _}}`). **That assertion is
load-bearing, not incidental**: a `:DOWN` carrying `:normal` would mean the
transport had replied `{:error, :timeout}` and the caller had returned
instead of exiting — the exact contract break Part 1 step 4's box exists to
prevent. Matching the reason pins it. Sequencing discipline:
never start the second query until the first's `:osc_out` proves it is in
flight, and use `:sys.get_state(Transport)` after issuing a query from a
spawned process when the assertion is "accepted but not yet sent".

1. **Serialization**: query A in flight, query B issued → the sink has *not*
   received B's datagram; reply to A → A's task gets A's reply, then B's
   datagram goes out; reply to B → B's task gets B's reply.
2. **The headline defect, as a regression test**: A =
   `query("/live/track/get/name", [0])`, B = same address `[3]`, B issued
   while A is in flight. Reply `[0, "Drums"]` → A receives it, *then* B's
   datagram appears at the sink; reply `[3, "Bass"]` → B receives
   `{:ok, {_, [3, "Bass"]}}` and never `[0, "Drums"]`.
3. **A timed-out in-flight query frees the pipeline**: A (150ms timeout)
   never answered, B queued behind it. A's task exits with the
   `GenServer.call` timeout (assert via `Process.monitor` on the DOWN
   reason); B's datagram then goes out and its reply reaches B.
4. **A late reply is broadcast, not delivered**: after A times out, inject
   A's reply while B (different address) is in flight → B's task still gets
   only B's reply; the late datagram arrives as `{:osc_message, ...}` via
   PubSub (assert_receive), i.e. it took today's push path.
5. **A queued request's timer removes it unsent**: A slow in flight, B
   queued with a timeout shorter than A's remaining time → B's caller exits
   at B's timeout and B's datagram *never* reaches the sink. The fence must
   be another `:osc_out`, not A's reply: A's reply reaches A's caller on a
   different channel than the sink's forwarding, so `refute_received` right
   after it can pass before a wrongly-sent B datagram has been forwarded.
   Instead: reply to A, then issue query C (any other address) and
   `assert_receive` C's `:osc_out` — Transport would have sent B before C,
   and the sink forwards in receive order, so C arriving without B proves B
   was never sent (`refute_received` B's `:osc_out` after C's fence).
6. **Sends bypass the queue**: A in flight, `send_message/2` → the sink
   receives the send's datagram before A has been answered.
7. **A late reply on the in-flight address *is* delivered** (residual class 1,
   as a characterisation test so the accepted limitation is pinned rather
   than assumed): A on `/live/track/get/name` `[0]` times out; B on the same
   address `[3]` goes in flight; inject A's `[0, "Drums"]` → B receives it.
   Asserting the *known* wrong behaviour is the point: if a future change
   makes B reject it, this test failing is the prompt to update the
   moduledoc's residual-class paragraph, not a bug report.
8. **A request that expires before the server ever handles it is dropped
   unsent** — the enqueue-path deadline check from step 3, and
   deterministically testable via `:sys`: `:sys.suspend(Transport)` first,
   then issue a 100ms query from a spawned process (the call sits in the
   suspended server's mailbox), wait for the caller's `:DOWN` with
   `{:timeout, {GenServer, :call, _}}`, then `:sys.resume(Transport)`. The
   server now handles a call whose deadline is already past. Assert its
   datagram never reaches the sink, using test 5's fence discipline — issue
   query C afterwards, `assert_receive` C's `:osc_out`, then
   `refute_received` the expired one. This is the test that pins "expired
   requests are never sent" at the one place a mailbox backlog can be staged
   on purpose.
9. **Two untested branches, noted so their absence is a decision rather than
   an oversight**: (a) send failure at dequeue time — hard to force
   `:gen_udp.send/4` to fail on loopback, skip rather than mock; the branch
   is three lines and mirrors the already-tested immediate-send failure
   shape. (b) `advance/1`'s expired-entry drop — reaching it needs a
   deadline that passes while `{:query_timeout, ref}` sits unprocessed
   behind a UDP datagram, which is a mailbox race the sink cannot stage
   deterministically. Test 5 covers the same outcome by the ordinary path
   (timer first), test 8 covers the identical check on the enqueue path, and
   the branch itself is one comparison shared with both.

The existing deaf-mode and source-validation tests stand unchanged and must
still pass — the deaf clause and the drop-foreign-datagram clause are
outside the queue.

## Part 3 — Reconcile the comments and docs that describe the old mechanics

No behaviour changes in this part — these sites' *checks all stay* (they
defend the residual collision classes); only prose describing the
overwrite-a-slot mechanics goes stale:

1. [handlers.ex](../lib/seshat/tools/handlers.ex) — `query_echoed/5`'s
   comment (def at ~3307) and `confirm_device_count/2`'s (def at ~2688): drop "consuming
   the stale reply also clears Transport's `pending`" phrasing. Say instead
   that the reissue is still worth making under the queue — it asks the same
   indices, so the straggler's genuine successor usually answers it — while
   being clear that this is **mitigation, not a guarantee**: the genuine
   reply can arrive in the gap after the mismatch is rejected and before the
   reissue is in flight, in which case it is broadcast and the reissue times
   out. The check earns its keep by refusing wrong data, not by reliably
   obtaining right data.
2. [registry.ex](../lib/seshat/commands/registry.ex) — `ensure_clip/4`'s
   comment (~83-89): same adjustment.
3. [state.ex](../lib/seshat/session/state.ex) — the query-helper comment
   (~553-561: "holds one query at a time" described the *old* transport) and
   `reconcile/4`'s one-index-behind narrative (~277-285): note the cascade
   now requires the same-address adjacency residual rather than any overlap,
   and that the brake stays because the residual still exists. **Comment-only
   edits** — the "Stop fabricating session state after OSC failures" plan
   rewrites these helpers' bodies; whichever lands second reconciles the
   prose, and neither plan's code conflicts with the other's.
4. [.claude/docs/ableton-osc-reference.md](../.claude/docs/ableton-osc-reference.md)
   § "Replies are correlated by address alone" (lines 182-201): rewrite the
   first bullet — the abandoned-`from` overwrite story is gone; the section
   now says one-in-flight + absolute per-request deadline, and that a reply
   is matched only against the in-flight request, so an unmatched late reply
   is broadcast-only *while a straggler on the in-flight address still
   answers the wrong query*. Keeps (verbatim) the echo-check guidance and the
   listener-push bullet, both still true and load-bearing — the section's
   title stays accurate, which is the point.
5. [.claude/rules/testing.md](../.claude/rules/testing.md) — the "never
   write tests that reach `Transport.query/3`" rule gains its scoped
   exception: *Transport's own tests* may call `query/3` when `OSCSink`
   plays AbletonOSC and supplies the reply (or the test asserts the timeout
   path with a sub-second timeout). The rule's rationale — needs a live
   Ableton — doesn't apply there, and Part 2 is impossible without the
   exception. Everything above the transport keeps the rule as written.

## Part 4 — What this plan deliberately does not touch

(Verification anchors for `/pr-review` — each of these appearing in the diff
is a plan violation.)

- No file under `priv/AbletonOSC` — no Python, no submodule pin bump, no
  `mix abletonosc.install` burden on the user.
- No change to `Definitions`, `Handlers` dispatch, MCP components, or tool
  count — this is not a tool.
- No functional change outside `transport.ex` — Parts 3.1–3.3 are comments,
  3.4–3.5 are docs/rules prose.
- `Session.State`, `Catalog`, `Registry`, `Agent` behaviour untouched.

## Testing

- **Pure (`mix test`)**: unusually for this codebase, the entire behaviour
  is deterministically testable — Part 2 covers serialization, reply
  routing, timeout cleanup (in-flight and queued), late-reply broadcast, and
  send bypass, all against `OSCSink` with no sleeps. `mix precommit` before
  done.
- **Live Ableton (one-time sanity, not a permanent `/smoke-test` item)**:
  with Live open, run `reindex_library` (a ~30s in-flight
  `/live/browser/export`) and immediately call `get_session_state` with
  `refresh: true` in a second client. Expected: the refresh's queries queue
  and time out honestly (with "Stop fabricating session state after OSC
  failures" landed: unknowns that heal by push; without it: today's
  defaults), the reindex completes with a correct
  summary, and no tool receives another's data. This is **confirmation of a
  derived expectation, not an experiment** — open question 1 establishes from
  AbletonOSC's own source that the bridge answers nobody during the export,
  so the refresh's queries were never going to survive their deadlines
  either way; what this run checks is that the *export* now survives, which
  today it does not. Not added to the smoke-test skill: the logic is covered
  deterministically, and a choreographed two-client race is a poor
  recurring checklist item.

## Out of scope

- **Request identifiers on the wire** — declined in the roadmap entry and
  review #1's response; do not resurrect.
- **Transport-side echo matching** (correlating replies by address *plus*
  echoed leading args): considered and rejected. The echo is not *uniform* —
  `/live/song/get/track_data` and `/live/song/get/track_names` reply with
  bare value lists, `/live/clip/get/notes` echoes only the leading
  track/clip ids and not its range args, `/live/browser/export` has no
  request args to echo, while per-index getters echo their leading indices
  and the browser query addresses (`get/items`, `load_item`) echo their full
  request args ([abletonosc-api-docs.md](abletonosc-api-docs.md) browser
  table) — so it needs either a per-address reply-shape table (an
  abstraction layer over address strings, contra the settled design decision
  in CLAUDE.md) or a per-call-site option threaded through ~30 call sites.
  The caller-side echo checks already hold the reply-shape knowledge and
  already defend every mutation-gating read. Reconsider only if residual
  class 1 or 2 is ever actually observed corrupting a caller that lacks an
  echo check — open question 2 enumerates all three: `track_data` (no echo
  exists to check), `get_clip_notes` (binds the echoed track/slot as
  `_t, _s`), and the browser callers (`list_browser_items` / `load_device`
  pattern-match the echoed `category`/`filter`/`track`/`uri` as `_`-prefixed
  variables without binding them). The cheap first response at all three is
  pinning those matches at the call site — a few lines each, and a roadmap
  entry of its own — not transport machinery.
- **Priority lanes for the queue** (e.g. mirror refresh outranking browser
  walks) — FIFO only; a starved 5s probe times out honestly and the mirror
  self-heals by push. Complexity with no observed need.
- **Caller monitors on queued entries** — the review suggested them;
  per-request deadlines already bound every entry's lifetime at its own
  timeout, which is the same cleanup with less bookkeeping. This is the
  argument that `:infinity` would break (an entry with no deadline and a
  dead caller blocks the queue forever with nothing to clear it), which is
  why the `@spec` excludes it rather than special-casing it — see Decisions.
- **Switching timeouts from caller exits to `{:error, :timeout}` returns**
  — rejected (see Decisions). If a future change wants it, it is a
  codebase-wide error-message migration, not a transport patch.
- **The queue-depth cap** — depth is bounded by concurrent callers (mirror
  refresh + a tool call + maybe the LiveView agent ≈ 3) and every entry
  self-expires; an arbitrary cap adds a failure mode for nothing.
- **`Session.State` fabricated defaults** — planned separately in
  [PLAN_stop_fabricating_session_state.md](PLAN_stop_fabricating_session_state.md);
  this plan neither depends on it nor blocks it.
- **CLAUDE.md "Current focus" paragraph** (which names this defect) —
  `/ship` syncs it when this lands, per its checklist.

## Open questions

Both questions this plan opened turned out to be answerable from the bridge's
own source rather than by observation. Their resolutions are recorded here
because they are the *reason* the design is safe, not merely reassurance.

1. ✅ **Resolved — queue-wait timeouts cost nothing that today's overwrite
   does not already cost, because the bridge cannot answer anyone during a
   long handler anyway.** AbletonOSC has no threads: `manager.py`'s `tick/1`
   is rescheduled every 100ms on Live's UI thread and calls
   `osc_server.process/0`, which drains the socket synchronously
   ([manager.py:118-127](../priv/AbletonOSC/manager.py#L118),
   [osc_server.py:156-165](../priv/AbletonOSC/osc_server.py#L156)), and the
   browser walk explicitly runs on that same UI thread
   ([browser.py:82](../priv/AbletonOSC/abletonosc/browser.py#L82)). While a
   ~30s `/live/browser/export` is walking, no datagram is *read*, let alone
   answered. So a concurrent 5s query cannot be satisfied inside its deadline
   whether or not the queue held it back — the queue does not lose a single
   query that today's transport would have won.

   What the queue does change, in the caller's favour, is two things. Today
   the refresh's first query overwrites `pending` and the export's reply
   therefore matches nothing when it finally lands, so `reindex_library`
   fails at 30s *having done all the work*. And today those ~65 refresh
   datagrams are all sent into the blocked bridge, then answered in one burst
   when the tick resumes — a flood of stragglers of exactly the residual
   class 1 shape, which is what the "one index behind" cascade in
   `Session.State.reconcile/4` is describing. Under the queue the export
   keeps its slot and completes, and the refresh's queries are never sent at
   all, so the flood does not exist. The queued caller's experience is
   identical to today's; everyone else's is better. The live check in Testing
   stays worth doing once, now as confirmation of a derived result rather
   than as a first look at an unknown.
2. ✅ **Narrowed to a two-client scenario, with the exposed call sites
   enumerated.** The set of addresses two processes can queue adjacently is
   small enough to list, and it splits cleanly:
   - **Queried by both `Session.State` and `Handlers`**:
     `/live/song/get/tempo`, `/live/song/get/num_tracks`,
     `/live/return_track/get/count`, `/live/master/get/volume`. Every one
     takes **no arguments**, so a straggler carries the value a fresh reply
     would have carried — there is no index to mismatch. Class 1 on these is
     value-equivalent, not corruption.
   - **Index-carrying getters**: checked on both sides —
     `Session.State`'s `query_string`/`query_float`/`query_int`
     ([state.ex:562-590](../lib/seshat/session/state.ex#L562)) and
     `Handlers.query_echoed/5` ([handlers.ex:3307](../lib/seshat/tools/handlers.ex#L3307))
     both compare the echoed index against the one asked for.
   - **Echo-less callers on index-carrying addresses**, the real exposure:
     `get_clip_notes` binds the echoed track/slot as `_t, _s` without
     checking them ([handlers.ex:1692-1697](../lib/seshat/tools/handlers.ex#L1692)),
     alongside the two the plan already named — `/live/song/get/track_data`
     (a bare value list, no echo possible, which
     [handlers.ex:1505-1508](../lib/seshat/tools/handlers.ex#L1505) already
     cites as the reason clip properties are read one getter at a time) and
     the browser addresses.

   The structural brake is what makes even those hard to reach: `query/3`
   *exits* the caller on timeout, and each of those sites sits in a `with`
   chain whose enclosing `catch :exit` aborts the whole tool call. A single
   client therefore never issues the next same-address query on its own after
   a timeout — the chain is dead. Reaching class 1 needs a second concurrent
   client, or the model retrying the failed tool, which normally retries with
   *identical* arguments and so gets a value-equivalent straggler again.

   This does not change the plan. It sharpens the reconsider-trigger in Out
   of scope: the cheap answer, if it is ever observed, is pinning the echoed
   args at those three call sites (a few lines each), and transport-side echo
   matching stays rejected. Worth its own roadmap entry as a defect in its
   own right — it is a pre-existing hole, not one this plan opens, and
   pinning it here would violate Part 4.

Decisions made rather than left open (recorded per the plan skill):
**exit-on-timeout is preserved, and the server never replies with a
timeout** — callers exit via their own `GenServer.call` deadline and nothing
else, because ~20 crafted `catch :exit` messages across
`Handlers`/`Registry`/`Catalog`/`Session.State` are written against exits,
and rerouting timeouts through generic `{:error, reason}` branches would
silently swap which user-facing message fires in twenty tools — a
message-quality regression this defect fix has no business risking. The
transport's internal timer therefore only reclaims the entry and frees the
pipeline; it sends no `{:error, :timeout}`, because with both timers on the
same absolute deadline it could win the race and hand the caller a return
value where an exit was promised (step 4's box).
**The clock runs from the caller's call, not from the send** — `timeout`
keeps meaning what `GenServer.call/3` made it mean to every existing caller:
total wait. It is carried as an absolute monotonic deadline rather than a
duration because the client's timer and the server's timer start at
different moments and can never be ordered; the deadline is the single
authority both `advance/1` and the timer consult.
**`:infinity` leaves the contract** — the `@spec` narrows from `timeout()`
to `non_neg_integer()`. `Process.send_after/3` raises on `:infinity`, so the
plan as first written would have crashed the transport on a call no site
makes today (all 30 `Transport.query/3` call sites pass the 5s default or a
module attribute). Special-casing it as `deadline: :infinity, timer: nil`
was the alternative and is rejected: an unbounded queue entry whose caller
dies blocks the head of the queue forever, which would force the caller
monitors this plan declines. A query that may wait forever is not a thing
this transport should offer; if one is ever wanted, it arrives with monitors
and its own plan.
**Unmatched late replies broadcast** rather than vanish — the mirror's push
handlers turn them into free freshness, and suppressing them would change
the existing broadcast contract for zero gain. A late reply on the
*in-flight* address is a different matter: it is delivered, unavoidably, and
is documented as residual class 1 rather than papered over. **FIFO, no
priorities; sends bypass the queue** — both argued inline above.
