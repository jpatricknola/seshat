# Plan — Coalesce mirror refreshes: one burst, one refresh

> **Archived 2026-08-01 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The scheduler lives in
> `Seshat.Session.State` (`@refresh_debounce_ms`, `schedule_refresh/1`,
> `finalize_reconciliations/3`); the seven deleted scalar-setter refreshes
> were in `Seshat.Tools.Handlers`. The one open follow-up — automated test
> coverage for the cross-key structural loop brake — is its own entry in
> [ROADMAP.md](../ROADMAP.md), "Unit coverage for the mirror-refresh
> cross-key loop brake".

Roadmap item "Coalesce mirror refreshes — one burst of tool calls, one
refresh". This is an Elixir-only scheduling change: remove seven redundant
full refreshes after scalar return/master writes, then bound the remaining
asynchronous full-refresh backlog to one running rebuild plus one trailing
rebuild inside `Seshat.Session.State`. Requests arriving within the same
one-second quiet window coalesce into that one trailing rebuild.

## Context

`Seshat.Session.State` is both the in-memory mirror and the process that rebuilds
it. A full `do_refresh/1` serially queries eight song values, five values for
every regular track, five for every return, and three for the master, then
re-subscribes every listener. Measured against Live 12.4.3 on 2026-07-31, that
takes roughly 1.0–1.8 seconds on a ten-track set. Because it runs inside the
GenServer, reads queue behind it.

The public `refresh/0` is a cast, but it is not cheap or coalesced: each cast
currently calls `do_refresh/1`. A model turn can issue many tools, so twenty
creates enqueue at least twenty refresh casts through `Handlers`/`Registry`.
The structure listeners can also request refreshes as their pushed name lists
change. Enough queued refreshes put `get_session_state`'s four ordinary
five-second `GenServer.call`s behind more work than their timeout and produce a
false "session mirror did not answer" diagnosis while Ableton is healthy.

That work also occupies `Seshat.OSC.Transport`, which serializes every query in
one app-wide FIFO. A redundant mirror refresh therefore delays more than state
reads: a tool's guard query (`set_track_send`, `load_device`, and the other
query-before-write handlers) can wait behind an in-flight or already-queued
refresh query. `do_refresh/1` waits for each reply before issuing its next query,
so another caller can interleave between those individual reads—the refresh
does **not** reserve Transport for its entire song/track sequence. Redundant
rebuilds still add dozens of requests to that shared pipeline, so bounding them
frees capacity in both GenServers rather than moving the same contention
elsewhere.

Seven scalar handlers make the queue worse for no state-consistency benefit:
the four return mixer setters (volume, pan, mute, solo) and three master setters
(volume, pan, cue volume) each call `State.refresh/0`, although all seven values
already have listeners that push the accepted value into the mirror. Their
regular-track equivalents already rely on those pushes and do not refresh.
An independent live check confirmed three of those push paths directly: a
regular-track volume write updated the mirror without a refresh; a master-volume
write and a subsequent `undo` — which calls no refresh at all — both arrived by
listener push; and undoing a newly created return removed it from the mirror
through `song_structure.py` alone. The set was restored afterwards.

The four **return-track scalar** listeners were not measured, and that is a
deliberate gap rather than an oversight. Every route to a discriminating test
was blocked: Live folds changes to a newly created return into the create, so
`undo` removes the whole return instead of reverting one value, and solo turns
out not to be exclusive across the track/return boundary, so a non-refreshing
`set_track_solo` cannot knock a soloed return loose either. They therefore rest
on inference — the same `AbletonOSCHandler._start_listen` machinery as the
master listeners that *were* measured, in the same `return_track.py`, with all
five registered there and matching `handle_info` clauses in `Session.State`.
Part 6 check 1 is the direct measurement, and it runs first for that reason: if
those four pushes do not arrive, the finding is that check failing, and the fix
is to restore those four `State.refresh/0` calls and leave the other three
deleted.

The scheduling constraint is not merely "once per second." One refresh can
take longer than a one-second rate-limit interval, so a leading-edge throttle
can still accumulate work. The required behavior is a **trailing-edge
debounce**: each asynchronous request moves one timer to one second after the
latest request. A token on the timer message makes a cancelled timer harmless
if its message has already reached the mailbox. Once the timer fires, one
refresh runs; requests received while that refresh is blocking the GenServer
remain in its mailbox and schedule exactly one new trailing refresh when the
callback returns. The last mutation is therefore never discarded.

That is the correctness guarantee: the **asynchronous full-refresh work
backlog** cannot grow beyond one active rebuild and one scheduled trailing
rebuild after queued signals are drained. Immediate `refresh_sync/0`, startup,
and initial setup are deliberately outside that bound. It is not a promise that
an entire natural-language request always produces exactly one refresh, and the
measured pacing says which case gets which. Timed on 2026-07-31 with Claude Code
as the MCP client on this machine: tool calls emitted **in one model response**
arrive about 0.5s apart (three spanning 1.13s), comfortably inside the window,
so they coalesce into one rebuild. Tool calls that need **separate model rounds**
arrive about 2.1s apart at the floor — a trivial call with no deliberation —
which is outside the window, so each one gets its own refresh.

That second number is the honest cost of declining a cooldown. At 2.1s spacing
against a 1.0–1.8s rebuild, a multi-round structural burst leaves `do_refresh/1`
generating refresh-query traffic for something like half to four-fifths of the
wall time. Other callers can interleave between those queries, but they still
compete for the same single in-flight slot. The plan declines the cooldown—it is
not what bounds the backlog, and it lengthens structural lag past the requested
quiet window—but that is now a decision made against evidence rather than in
the absence of it. See Open questions for the one part of the measurement that
is still client-dependent.

Structure reconciliation is the non-obvious part. `reconcile/4` currently runs
`do_refresh/1` inline, immediately checks whether the pushed names were
reproduced, and records an `unreconciled` brake if they were not. That brake
prevents a degraded refresh from entering an infinite refresh → re-subscribe →
push → refresh loop. Delaying the refresh requires retaining the latest pushed
names for each structure key and performing that comparison when the scheduled
refresh finishes; wrapping only `handle_cast(:refresh, ...)` in a timer would
leave this second trigger synchronous and would lose the brake's semantics.

Ordinary reads remain GenServer reads. While a refresh is scheduled they answer
from the current push-updated mirror, accepting at most the debounce window of
structural lag. They do not force the scheduled refresh inline. Part 4 combines
`get_session_state`'s four calls into one `snapshot/0` call so one reply cannot
straddle a refresh or four separate timeout windows. It deliberately still
waits behind a refresh that is already running: against genuinely unresponsive
Ableton, the existing mid-refresh error is more honest than silently serving a
stale copy. A caller that requires an authoritative rebuild already has
`get_session_state(refresh: true)`, whose `refresh_sync/0` path stays immediate
and cancels the pending timer.

Research also rejects one roadmap hint: making the delay configurable and
driving it to zero does not make `do_refresh/1` testable—it only reaches the
same live `Transport.query/3` calls sooner. Keep the production choice as a
one-second module constant, unit-test the timer/reconciliation state transitions
without firing the real refresh, and verify the actual coalesced rebuild against
Live.

## OSC contract

**No OSC address, argument, reply shape, Python handler, or listener contract
changes.** There is no `priv/AbletonOSC` commit, pin bump,
`mix abletonosc.install`, or Live restart. This plan only changes when existing
Elixir code requests the existing full read.

The seven refresh calls removed in Part 1 are safe specifically because these
existing setter/listener contracts are already live:

| Address | Args sent | Reply / push |
|---|---|---|
| `/live/return_track/get/volume` | `return_index` | query: `[return_index, "ok", volume]` or `[return_index, "error", message]`; listener push: `[return_index, volume]` |
| `/live/return_track/set/volume` | `return_index, volume` | none; the listener above pushes the accepted value |
| `/live/return_track/get/panning` | `return_index` | query: `[return_index, "ok", pan]` or error envelope; listener push: `[return_index, pan]` |
| `/live/return_track/set/panning` | `return_index, pan` | none; listener push on the matching getter address |
| `/live/return_track/get/mute` | `return_index` | query: `[return_index, "ok", 0\|1]` or error envelope; listener push: `[return_index, muted]` |
| `/live/return_track/set/mute` | `return_index, 0\|1` | none; listener push on the matching getter address |
| `/live/return_track/get/solo` | `return_index` | query: `[return_index, "ok", 0\|1]` or error envelope; listener push: `[return_index, soloed]` |
| `/live/return_track/set/solo` | `return_index, 0\|1` | none; listener push on the matching getter address |
| `/live/master/get/volume` | none | `[volume]` for both query and listener push |
| `/live/master/set/volume` | `volume` | none; listener push on the matching getter address |
| `/live/master/get/panning` | none | `[pan]` for both query and listener push |
| `/live/master/set/panning` | `pan` | none; listener push on the matching getter address |
| `/live/master/get/cue_volume` | none | `[value]` for both query and listener push |
| `/live/master/set/cue_volume` | `value` | none; listener push on the matching getter address |

The asynchronous structure trigger retains its existing push-only contract:

| Address | Args sent | Reply / push |
|---|---|---|
| `/live/song/start_listen/tracks` | none | no direct reply; immediately and on change pushes `/live/song/get/tracks [name0, name1, …]` |
| `/live/song/start_listen/return_tracks` | none | no direct reply; immediately and on change pushes `/live/song/get/return_tracks [name0, name1, …]` |

The scheduled `do_refresh/1` continues to issue the same reads and subscriptions:

- Eight index-less `/live/song/get/<property>` queries for `tempo`,
  `signature_numerator`, `signature_denominator`, `is_playing`, `root_note`,
  `scale_name`, `groove_amount`, and `swing_amount`, each replying `[value]`;
  `/live/song/get/num_tracks []` replies `[count]`. Each matching
  `/live/song/start_listen/<property> []` sends no direct reply and immediately
  pushes `[value]` on its getter address.
- For every regular track, `/live/track/get/{name,volume,panning,mute,solo}
  [track_index]` replies `[track_index, value]`, and the matching
  `/live/track/start_listen/<property> [track_index]` sends no direct reply but
  immediately pushes on its getter address.
- `/live/return_track/get/count []` replies `[count]`. For every return,
  `/live/return_track/get/{name,volume,panning,mute,solo} [return_index]` uses
  the `return_index, "ok"|"error", value|message` query envelope; its matching
  `start_listen` address pushes the bare `[return_index, value]` shape.
- `/live/master/get/{volume,panning,cue_volume} []` replies with the bare
  `[value]`; each matching index-less `start_listen` address immediately pushes
  the same shape.

## Numbered parts

### 1. Remove redundant scalar refreshes — `lib/seshat/tools/handlers.ex`

Delete the trailing `State.refresh()` from exactly these seven successful
setter paths:

1. `set_return_track_volume`
2. `set_return_track_pan`
3. `set_return_track_mute`
4. `set_return_track_solo`
5. `set_master_volume`
6. `set_master_pan`
7. `set_cue_volume`

Keep each pre-write getter, validation/error path, OSC setter, old/new-value
reply, and `return_track_label/1` lookup unchanged. Remove the volume handler's
now-obsolete "label first, refresh second" comment. Do not optimistically write
the new scalar into `Session.State`; the listener push remains the single update
path, matching the regular-track setters and preserving Live's accepted value
as the source of truth.

Keep every structural `State.refresh()` call in `Handlers` and `Registry`.
Creates, deletes, and duplicates change index meanings and which Live objects
listeners are bound to; Part 2 makes those calls cheap to repeat without
weakening their eventual authoritative rebuild.

### 2. Add one tokenized trailing-edge scheduler — `lib/seshat/session/state.ex`

Add a one-second `@refresh_debounce_ms` and extend the GenServer state with:

- the active timer reference and an opaque timer token;
- `refresh_requested?`, distinguishing an explicit `refresh/0` from a timer
  scheduled only for structure reconciliation; and
- `pending_reconciliations`, keyed by `:tracks` / `:return_tracks`, carrying
  the latest pushed name list and its log label.

Implement a private `schedule_refresh/2` path with these checkable semantics:

1. Cancel the old timer when present, mint a new token, and schedule
   `{:refresh, token}` for one second later. Store both the timer reference and
   token. `Process.cancel_timer/1` alone is not the correctness guard: a due
   message can already be queued, so a `handle_info` whose token is not current
   must be a no-op.
2. `handle_cast(:refresh, state)` marks `refresh_requested?: true` and uses the
   scheduler instead of calling `do_refresh/1`.
3. A current timer message snapshots the pending reconciliation records, clears
   the timer/request metadata, runs exactly one `do_refresh/1`, then finalizes
   those records as Part 3 specifies. A stale timer token performs no work.
4. A refresh cast or structure push processed after `do_refresh/1` began cannot
   be handled until that callback returns; when it is handled, it creates/resets
   the next timer. After the queued signals are drained, they represent one
   future refresh rather than one rebuild each. This mailbox ordering is the
   bounded-backlog and trailing guarantee: no scheduling policy may consume the
   final request.

The one-second value is a module constant, not application configuration. No
runtime setting has a product use, and reducing the delay cannot make the OSC
refresh safe for unit tests. Do not add a minimum-between-refreshes cooldown in
this implementation: it is not required to bound the backlog, and it would
extend structural staleness beyond the requested quiet window. The measured
pacing above says a cooldown would collapse the multi-round case that the
one-second window does not; that is a real gain, and it is deliberately left to
the follow-up recorded in Out of scope rather than folded in here.

### 3. Defer structure reconciliation without losing its brake — `lib/seshat/session/state.ex`

Change the stale branch of `reconcile/4` from an inline `do_refresh/1` to the
same scheduler, recording the latest pushed names under that structure key.
Preserve all current gates:

- a name list matching the mirror clears that key's pending reconciliation and
  `unreconciled` brake;
- an exact list already recorded in `unreconciled` remains ignored;
- a disagreeing return list remains ignored while `returns_readable?` is false;
  and
- a newer differing list replaces the older pending list and resets the timer.

When a scheduled refresh completes, compare the rebuilt mirror with every
pending name list:

- on agreement, clear that key's brake;
- on disagreement, emit the existing warning and record that exact list in
  `unreconciled`, preventing the re-subscription echo from scheduling an
  infinite retry; and
- for a structure-only refresh, preserve existing failure records for keys not
  involved in this refresh. This is the current cross-key loop brake.

An explicit `refresh/0` or `refresh_sync/0` continues to lift old brakes by
starting from an empty `unreconciled` map, then records only pending lists that
the new rebuild still cannot reproduce. **That explicit precedence also governs
the combined case:** if one timer carries `refresh_requested?: true` and one or
both pending structure records, discard every old brake before rebuilding,
then compare the rebuilt mirror with those pending records and re-add only the
ones still not reproduced. Do not preserve an unrelated old failure record in
that combined case; the explicit request is a forced retry of all of them.

If a pending structure list becomes equal to the push-updated mirror before the
timer fires, remove it; cancel the timer only when there is no pending structure
work and no explicit refresh request.

### 4. Keep immediate refresh paths immediate — `lib/seshat/session/state.ex`

Factor timer cancellation/metadata clearing so the three non-debounced paths
are explicit:

- `handle_continue(:setup, ...)` performs the initial `do_refresh/1` directly;
- `/live/startup` cancels and discards pending work from the old song, then
  refreshes immediately so listeners are rebound to the new song object; and
- `refresh_sync/0` cancels the timer, consumes any pending structure records in
  the same immediate refresh, and returns only after rebuilding. No cancelled
  timer may cause a second refresh later.

Add `State.snapshot/0` and `handle_call(:snapshot, ...)`, returning one map with
the current `song`, `tracks`, `return_tracks`, and `master` values from the same
GenServer turn. Change `serve_session_state/0` in
`lib/seshat/tools/handlers.ex` to make that single call and pass its four fields
to `format_session_state/4`.

Keep the four narrower public reads for their existing callers. A snapshot or
narrow read that reaches the GenServer while a timer is pending replies from
the current mirror; it neither cancels nor flushes the timer. A call landing
behind an already-running refresh still gets the existing five-second timeout
and `serve_session_state/0` still catches it as "the session mirror did not
answer." The single snapshot removes the current four chances to race a refresh
between calls and guarantees one reply cannot combine, for example,
song-before-refresh with tracks-after-refresh. Leave `@refresh_sync_timeout`
and the ordinary five-second timeout unchanged.

Update the module/API comments that currently say every `refresh/0` immediately
re-queries Ableton or that `reconcile/4` refreshes inline. They must describe
eventual, coalesced refresh and the intentional structural snapshot window.

### 5. Unit coverage for scheduling and reconciliation — `test/seshat/session/state_test.exs`

Extend the state fixture with every scheduler field; the existing whole-map
equality assertions depend on those fields being present. Keep this test module
transport-free. Exercise callbacks directly. `Process.send_after(self(), ...)`
targets the bare ExUnit test process in this callback-level pattern, so an
unhandled due message is inert and disappears with the process; tests do not
need timer teardown:

- one `handle_cast(:refresh, ...)` creates one timer and marks an explicit
  request; a second cast replaces its token rather than representing a second
  runnable refresh;
- the first token's late `handle_info` is ignored after replacement;
- a stale track-list push schedules reconciliation instead of entering
  `do_refresh/1`, making the previously live-only disagreement branch unit
  testable up to the timer boundary;
- successive track lists retain only the latest names, while simultaneous track
  and return changes retain one pending record for each under one timer;
- a matching list clears its pending record, and cancels the timer only when no
  explicit request or other structure record remains;
- the existing unreadable-return and exact-`unreconciled` brake tests continue
  to schedule nothing—assert their timer/token and pending records remain empty,
  rather than relying only on their previous mirror-value assertions;
- `handle_call(:snapshot, ...)` returns all four mirror sections from one state,
  and both the snapshot and narrower read callbacks reply unchanged while a
  timer is pending;
- a cancelled/stale timer message cannot erase pending work or mutate the
  mirror.

Do not unit-test the current-token timer branch through `do_refresh/1`: it calls
`Transport.query/3`, needs live Ableton, and remains the smoke-test boundary.
Driving a configurable delay to zero would violate the same rule, not close the
coverage gap. No new test-only transport abstraction or injected refresh
function is proportionate for a scheduler whose pure state transitions are
already directly callable.

Moving the stale disagreement branch out of inline `do_refresh/1` is a net
coverage gain: scheduling, latest-list replacement, cross-key accumulation, and
the no-refresh brakes become pure callback tests. Only the final authoritative
OSC rebuild and its post-refresh comparison remain live-only.

### 6. Document the live regression check — `.claude/skills/smoke-test/SKILL.md`

Add a focused subsection for mirror-refresh coalescing so future `/smoke-test`
runs do not silently fall back to checking only scalar push freshness.

**How the calls are issued is part of each check, not a detail.** Checks 2, 3
and 4 all need a second call to land *inside* the one-second quiet window, and
the pacing measured in Context says a call typed as its own conversational turn
arrives about 2.1s later — after the timer has already fired. Those three checks
therefore require the burst and the read to be **emitted as several tool calls
in one model response** (measured ~0.5s apart), which means asking for the whole
sequence in a single instruction rather than one message per step. Written into
the checklist explicitly because the failure is silent: run turn by turn, every
one of them reports success while never entering the state it exists to test.
Check 1 is exempt — it asserts that a refresh does *not* happen, so spacing
cannot fake a pass.

1. Issue the seven return/master scalar setters in a burst, then immediately
   call unrefreshed `get_session_state`; it answers and contains the pushed final
   values. The server log shows no full-refresh `Song:` / `Loaded ...` sequence
   caused by those setters.
2. On scratch material, create a burst of tracks with a distinct final name,
   **with the creates and the read in one model response** so they fall inside
   one window. An ordinary state read during that quiet window answers promptly
   (it may show the documented structural snapshot); after the window, state
   includes the final track. Record the server-log timestamps for every tool
   call and every full-refresh `Song:` / `Loaded ...` sequence. Calls separated
   by less than the quiet window must share one trailing refresh. Calls separated
   by longer model rounds may form multiple quiet windows; report that observed
   count rather than asserting the whole natural-language request was one
   window. At no point may completed signals leave a chain of full refreshes
   queued—after the final call, exactly one final trailing refresh converges the
   mirror. Clean up every scratch track.
3. While an asynchronous refresh is pending, call `get_session_state(refresh:
   true)`. It performs the immediate rebuild and no cancelled trailing timer
   produces a duplicate refresh one second later. Issue the mutation and the
   refreshing read **in one model response**; as separate turns the timer has
   already fired and nothing is pending by the time the read lands, which reads
   as a pass.
4. Make one more structural mutation while a refresh is already running; after
   it finishes, confirm one trailing refresh occurs and the final mutation is
   present. This is the live proof that requests received during the blocking
   callback are not discarded. The rebuild lasts 1.0–1.8s, so the follow-up
   mutation must again come from the same model response rather than a separate
   turn; confirm against the server log that it really did arrive mid-refresh,
   since landing just after one is the likely near-miss and looks identical in
   the final state.
5. Confirm the revised `get_session_state` snapshot preserves the honest dead-
   Ableton behavior already required later in this checklist: force a refresh
   with Live unavailable, then make a plain read while it is still running. The
   single snapshot call must still return "the session mirror did not answer,"
   never stale state or an empty session.

No bridge reinstall or Live restart is required for this change. Run against a
healthy already-installed AbletonOSC and use the server logs to count rebuilds;
state correctness alone cannot distinguish one refresh from twenty redundant
ones.

## Testing and verification

1. `mix test test/seshat/session/state_test.exs`
2. `mix precommit`
3. With Ableton Live open, run `/smoke-test` focused on mirror-refresh
   coalescing and execute Part 6's five checks.

The unit suite proves timer replacement, stale-token rejection, pending-list
bookkeeping, preserved loop brakes, coherent snapshots, and non-blocking
pending reads. Only Live can prove that the current timer fires one real full
refresh, that listener pushes replace the seven removed setter refreshes end to
end, that the full-refresh backlog stays bounded under real client pacing, and
that a structural request arriving during the blocking refresh schedules the
final trailing rebuild.

## Out of scope

- **Moving refresh work out of the GenServer.** A single refresh can still
  block reads for its own 1.0–1.8-second duration. The roadmap's deliberately
  deferred monitored-worker item owns an overall deadline, background worker,
  and freshness/connection/last-error metadata. Coalescing removes the observed
  multi-refresh queue without taking that larger architectural step.
- **Raising read or refresh timeouts.** This plan removes queued work rather
  than making the false failure slower.
- **Optimistically mutating scalar or structural mirror state in handlers.**
  Listener pushes and the authoritative re-read remain the sources of truth.
- **A conversation-turn or MCP transaction boundary.** MCP exposes individual
  tool calls, not a reliable "user request finished" signal; the quiet window
  is deliberately below both MCP and API-key entry points.
- **A minimum interval/cooldown between completed refreshes.** Unlike a
  trailing-edge throttle, a cooldown preserves the final request — it delays the
  trailing timer rather than dropping it — so the objection that rules out a
  leading-edge throttle does not reach it. The measured ~2.1s multi-round pacing
  says it would collapse rebuilds the one-second window leaves separate. It is
  still deferred: the bounded-backlog scheduler is what fixes the observed
  timeout, and a cooldown lengthens structural lag for every ordinary single
  mutation to buy throughput only during bursts. Reconsider as its own change if
  Part 6's timestamps confirm the same pacing against the production client, and
  size the interval from those numbers rather than from this plan's window.
- **Bulk create/mixer tools.** Existing tools remain composable; the state layer
  absorbs their burst behavior.
- **Any AbletonOSC/Python change.** All required listeners and push shapes are
  already implemented and documented.

## Open questions

1. ⚠️ **Does the production client pace tool calls like the one that was measured?**
   The general question — how much coalescing a real client-driven request gets —
   is answered, and the numbers are in Context: measured on 2026-07-31 with
   Claude Code as the MCP client, calls within one model response land ~0.5s
   apart and coalesce; calls needing separate model rounds land ~2.1s apart at
   the floor and do not. What is *not* settled is whether Claude Desktop on a
   music task paces the same way. It plausibly runs faster — shorter replies,
   less deliberation — and if its multi-round spacing fell under a second, the
   one-second window would coalesce those bursts too and the deferred cooldown
   would lose most of its value.

   One thing blocks closing that last gap, and it is not Ableton and not the
   Seshat server: Claude Desktop is simply a different client from the one that
   did the planning, and its pacing cannot be measured from a Claude Code
   session. Part 6 check 2 already records tool-call and full-refresh
   timestamps; run it from Claude Desktop and the question closes.

   A note for whoever runs that check, learned the hard way during planning:
   this environment cannot see processes or bound ports reliably — `ps` and
   `lsof` both come back empty against a server that is demonstrably running.
   Establish whether the server is up by talking to it (`curl` the `/mcp`
   endpoint from `.mcp.json`, or just make a tool call), never by scanning for
   a `beam.smp` process or for something bound to 4000 or 11001.

   **Nothing in the implementation depends on the answer.** The asynchronous
   bounded-backlog guarantee — at most one active plus one trailing rebuild —
   holds at any pacing, and no cooldown is being added. The answer only sizes
   the follow-up in Out of scope. If Desktop's numbers match Claude Code's, add
   a cooldown as its own change with its interval derived from them; if they
   come in under a second, drop that follow-up rather than stretching this
   plan's window to chase it.
