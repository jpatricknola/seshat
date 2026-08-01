# Plan — A degraded rebuild must never become the mirror

> **Archived 2026-08-01 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The fix lives in
> `Seshat.Session.State` (`read_tracks/2`'s `{:degraded, index}` result,
> `do_refresh/1`'s `tracks: nil` branch, `finalize_reconciliations/3`'s
> failed-vs-disagreed split and one retry, the `reconcile/4` echo-loop guard,
> and `snapshot/0`'s `refresh_pending?` flag) plus `Seshat.Tools.Handlers`'
> `format_session_state/5`. This also closes the roadmap's separate "Unit
> coverage for the mirror-refresh cross-key loop brake" entry — Part 3 folds
> that coverage in directly. No follow-ups were opened; see "Out of scope"
> below for what was deliberately left alone, including the entry's declined
> change 3 (re-deriving the track count from the pushed name list) and the
> excluded return/master-track race.

Roadmap item "The mirror goes stale after a burst of structural changes — and
stays stale". Elixir-only, one production file
([lib/seshat/session/state.ex](../../lib/seshat/session/state.ex)) plus one
rendering change in [lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex).
**No OSC address, argument, reply shape or Python change**: no submodule commit,
no pin bump, no `mix abletonosc.install`, no Live restart.

## Context

Measured 2026-08-01 while smoke-testing the undo-granularity branch: three
`create_track` calls, then three `undo` calls that really did remove the tracks
in Live. The second `get_session_state` afterwards reported the deleted Track 1
"Bass" as present, beside a Track 2 whose name, volume, pan and mute were all
unknown. A third read with `refresh: true` was correct. The full evidence is in
PR #54's body under "Live verification".

Naming a deleted track as present is the same class of failure the "no
fabricated values" work removed for the scalar song fields and never closed for
the track list. The unknowns in that reply were rendered honestly; the *presence
of Bass* was not, and nothing in the reply distinguished the two.

### Half of the roadmap entry already shipped — do not rebuild it

Commit 785db9f (2026-08-01) landed the consumer-side contract the entry's
"Scope and coverage" section called for. `get_session_state`'s description now
says to call it once after a whole batch of actions *including several undo
calls*, never after each one; never to retry a read automatically in the same
response, `refresh: true` included; and to tell the user what could not be
verified. `@unknown_explanation` and the mid-refresh error string in `Handlers`
say the same thing. **Nothing in this plan touches that.** The orchestration
acceptance check the entry asks for (three undos followed by exactly one
ordinary state read) is now an instruction that exists, so it becomes a
verification step rather than an implementation part.

That change also **narrowed `refresh: true`** — from "pass it if the state ever
looks wrong" to "only when the user explicitly asks". The model-side workaround
that produced the correct third reading in the measured run is now instructed
away. So the mirror's own honesty and its own recovery are no longer one option
among several; they are the only recovery path. That is what makes Parts 2 and 3
below load-bearing rather than tidy-up.

### The three causes, and which of them this plan attacks

- **The debounce window is shorter than the gap between tool calls.**
  `@refresh_debounce_ms` is 1,000ms while calls issued in separate model rounds
  arrive ~2.1s apart at the floor (measured 2026-07-31, recorded in
  `/smoke-test`). A multi-round burst therefore gets one refresh per call, each
  still in flight when the next mutation lands. **Not addressed here** — the
  entry rules out widening the window, and this plan agrees (see Out of scope).
- **A rebuild racing a structural change comes back degraded.** `do_refresh/1`
  reads `num_tracks`, then five properties per index. A track that disappears in
  between leaves the per-index queries unanswered, and `read_tracks/2`'s echo
  check turns stragglers into `nil`. **Parts 1 and 2** make that outcome
  detectable and honest; **Part 1** also bounds what it costs in wall time.
- **The brake then stops it healing.** `finalize_reconciliations/3` records a
  rebuild that could not reproduce the pushed list as `unreconciled` and
  deliberately never retries — correct as the only defence against an unbounded
  refresh → re-subscribe → push → refresh spin, but it holds a knowingly-wrong
  mirror indefinitely behind one `Logger.warning`. **Part 3** splits "failed"
  from "disagreed" and gives the first exactly one retry.

### What research established

**A bad track index is silent, confirmed from the fork's own source.**
`create_track_callback` in
[priv/AbletonOSC/abletonosc/track.py:14-30](../../priv/AbletonOSC/abletonosc/track.py#L14-L30)
does `track = self.song.tracks[track_index]` with no bounds check. The
`IndexError` propagates out of the callback through
`OSCServer.process_message` — whose exact-address branch
([osc_server.py:96-106](../../priv/AbletonOSC/abletonosc/osc_server.py#L96-L106))
has no `try`/`except` — and is caught by the per-message handler in
`OSCServer.process` at
[osc_server.py:198-200](../../priv/AbletonOSC/abletonosc/osc_server.py#L198-L200),
which logs and moves on. **No reply is sent.** So the entry's arithmetic holds:
five queries per index at `@query_timeout` 5,000ms is 25 seconds of dead waiting
per over-reported track, and the caller cannot tell it from a slow Ableton.

**Change 3 as the entry writes it is now the wrong fix — see Out of scope.**
Using `length(names)` from the structure push instead of re-deriving
`num_tracks` was ranked third with "measure first". The measurement that matters
turns out to be one already in the tree: since refreshes are coalesced, the
pushed name list is by construction up to a debounce window (and one rebuild)
old when the rebuild runs, while `/live/song/get/num_tracks` is issued at
rebuild time. Trusting the pushed length would make the count *staler*, not
fresher, in exactly the burst this item is about. Part 1 takes the same wall-time
win by a different route — short-circuiting the dead index rather than avoiding
it — and keeps the fresh count.

**Live measurements taken for this plan** (2026-08-01, Live 12 Suite running,
four-track set, via the running Seshat server):

1. Three `refresh: true` reads on a healthy idle set returned no unknown field
   at all — no spurious unanswered name in any of them. Small sample, but it is
   the only evidence bearing on whether Part 1's "first unanswered name condemns
   the read" is too aggressive in normal operation. See Open questions.
2. Three `create_track` calls and one plain `get_session_state` emitted **in one
   model response** returned the pre-burst four-track list — omitting three
   tracks that existed at read time, with nothing in the reply saying so. That
   is the intended debounce snapshot window, not the defect in this item:
   nothing was fabricated and it converged on its own a second later. But the
   model has no way to know it is reading inside that window, and the reply
   asserts a session that is three tracks out of date. **Part 4** labels that
   known uncertainty; it is an addition beyond the entry's three changes, kept
   because the same honesty rule applies during the intentional debounce window.
3. The three scratch tracks were removed with explicit `delete_track` calls
   (indices 6, 5, 4, highest first) and a following `refresh: true` read
   confirmed the set restored exactly, Guitar's non-default volume 0.45
   included. Nothing was left behind.

## OSC contract

**Nothing changes.** Every address below already exists, already behaves as
described, and is already used by the code being modified. The table is here
because the plan's correctness rests on two of these behaviours — the silence of
a bad index, and the immediate push on subscription.

| Address | Args sent | Reply / push |
|---|---|---|
| `/live/song/get/num_tracks` | none | `[count]` |
| `/live/track/get/name` | `track_index` | `[track_index, name]`; **no reply at all** for an out-of-range index (verified from `track.py`/`osc_server.py` above) |
| `/live/track/get/volume` | `track_index` | `[track_index, volume]`; silent on a bad index |
| `/live/track/get/panning` | `track_index` | `[track_index, pan]`; silent on a bad index |
| `/live/track/get/mute` | `track_index` | `[track_index, 0\|1]`; silent on a bad index |
| `/live/track/get/solo` | `track_index` | `[track_index, 0\|1]`; silent on a bad index |
| `/live/track/start_listen/name` | `track_index` | no direct reply; pushes `[track_index, name]` on `/live/track/get/name` immediately and on every change. Silent for a bad index |
| `/live/track/start_listen/volume` | `track_index` | no direct reply; pushes `[track_index, volume]` on `/live/track/get/volume` immediately and on every change. Silent for a bad index |
| `/live/track/start_listen/panning` | `track_index` | no direct reply; pushes `[track_index, pan]` on `/live/track/get/panning` immediately and on every change. Silent for a bad index |
| `/live/track/start_listen/mute` | `track_index` | no direct reply; pushes `[track_index, 0\|1]` on `/live/track/get/mute` immediately and on every change. Silent for a bad index |
| `/live/track/start_listen/solo` | `track_index` | no direct reply; pushes `[track_index, 0\|1]` on `/live/track/get/solo` immediately and on every change. Silent for a bad index |
| `/live/song/start_listen/tracks` | none | no direct reply; pushes `/live/song/get/tracks [name0, name1, …]` immediately and on every structural change (fork-only, `song_structure.py`) |
| `/live/song/get/tracks` | — | push-only; never registered as a query |

The "immediately" in the last two rows is what makes a degraded rebuild
self-announce: `do_refresh/1` re-subscribes, `song_structure.py` pushes the
authoritative list straight back, and `stale?(nil, names)` is true against any
list. Part 3 is about not throwing that push away.

## Numbered parts

### 1. `read_tracks/2` reports degradation instead of returning a half-list — `lib/seshat/session/state.ex`

Change `read_tracks/2` to return `{:ok, [track_map]}` or
`{:degraded, stopped_index}`, and to stop at the first index whose **name**
query goes unanswered. The index in the degraded result is what Part 2 logs;
do not discard it at this boundary:

- Read `name` first for each index. If it comes back `nil`, return
  `{:degraded, index}` immediately — do not issue that index's remaining four
  queries, and do not read any further index.
- Otherwise read `volume`, `pan`, `mute`, `solo` as today. A `nil` in any of
  *those* is unchanged behaviour: that field stays unknown and the row is kept.
- `count < 1` still returns `{:ok, []}` — a verified-empty set, not degradation.

Two reasons the name is the marker, and both should be stated in the comment:

- It is the identity field. `stale?/2` compares names and nothing else, so a row
  with `name: nil` can never reconcile against a pushed list — it is guaranteed
  to be recorded as a brake, which is precisely the trap the measured run fell
  into. A `nil` volume has no such consequence.
- `query_string/4`'s echo check rejects a reply whose echoed index isn't the one
  asked for, so a straggler arriving one index behind yields `nil` here too.
  The marker therefore catches the abandoned-reply cascade as well as the dead
  index, which are the same failure seen from two ends.

Aborting the whole read rather than the current index is deliberate: Part 2 is
about to discard the list anyway, so every query after the first unanswered name
is spent on a result that will be thrown away. This is the wall-time half of the
fix — a fully dead read costs one `@query_timeout` (5s) instead of five per
over-reported index — and it replaces the entry's change 3 (see Out of scope).

**Decouple listener subscription from the read result.** `do_refresh/1`
currently calls `subscribe_listeners(tracks)` with the rows it just read. Change
it to subscribe the indices derived from the `num_tracks` reply,
unconditionally, whether the read degraded or not: an empty list for
`count < 1`, otherwise `0..(count - 1)`. Subscribing an index that no longer
exists is harmless — the same silent `IndexError` path, and no listener is
created — while *not* subscribing is how a degraded refresh would go
permanently deaf. `subscribe_listeners/1` takes that index enumerable instead of
the track maps.

### 2. A degraded rebuild never becomes the mirror — `lib/seshat/session/state.ex`

In `do_refresh/1`'s `num_tracks` success branch, act on Part 1's return:

- `{:ok, tracks}` → `%{state | song: song, tracks: tracks}`, as today.
- `{:degraded, stopped_index}` → `%{state | song: song, tracks: nil}`, with a
  `Logger.warning` naming the count that was reported and the index the read
  stopped at.

This is the entry's must-do, and it applies a rule `do_refresh/1` already states
and argues for one branch higher up: when `num_tracks` fails it sets
`tracks: nil` rather than keeping the old list, because *"keeping the old list
serves the previous set's tracks as this set's. Unknown, not stale-but-plausible."*
The half-`nil` list is the case that rule never reached. Extend the existing
comment rather than writing a second one beside it.

`format_track_summary(nil)` already renders this correctly — "The track list
could not be read from Ableton — it is unknown, not empty." — and
`format_session_state/4` already appends `@unknown_explanation` exactly once. No
rendering change is needed for this part. The measured reply becomes "the track
list is unknown" instead of "Bass is present".

One consequence to document in the module doc, because it is not obvious:
`update_track/4`'s `%{tracks: nil}` clause drops incoming scalar pushes, so the
listener re-subscription echo cannot repopulate a nil'd list field by field. The
recovery route is the *structure* push and Part 3's retry, not the scalar
pushes. That is correct — a scalar push carries an index whose meaning is
exactly what the failed read could not establish — but it means Part 3 is not
optional.

### 3. Distinguish "failed" from "disagreed"; allow exactly one retry — `lib/seshat/session/state.ex`

`finalize_reconciliations/3` currently treats two different outcomes
identically: "Live says X and the mirror says Y" (a genuine disagreement, where
retrying is the spin the brake exists to stop) and "the rebuild established
nothing" (a failure, which has not disagreed with anything). Split them.

For each pending key, after the rebuild:

1. **Reconciled** — `stale?/2` false: clear that key's brake. Unchanged.
2. **Failed** — the mirror value for that key is `nil`, and this record has not
   already been retried: keep the pending record with a `retried?: true` marker,
   emit an *informational* log line saying the rebuild could not read the list
   and one retry is scheduled, and call `schedule_refresh/1`. **Do not** record
   an `unreconciled` brake.
3. **Failed again** — the mirror value is `nil` and `retried?` is already true:
   record the brake exactly as today, with the existing warning. Two rebuilds
   per pushed list is the bound; this is not the spin.
4. **Disagreed** — the mirror value is non-`nil` but its names differ: record
   the brake immediately, with the existing warning. No retry. A rebuild that
   read the session successfully and got a different answer is information, not
   a failure, and retrying it is what floods Live.

The retry rides `schedule_refresh/1` (so it lands one debounce window later)
rather than recursing into `do_refresh/1`: a second immediate rebuild against an
Ableton mid-structural-change would be racing the same change that broke the
first one, and the scheduler already exists for exactly this.
`refresh_requested?` stays false, so the retry is a structure-only rebuild and
the cross-key `carried_over` brake in `run_refresh/2` keeps protecting the other
key.

**The retry marker must survive an identical re-push, and this is the subtle
part.** `reconcile/4` currently replaces the pending record and resets the timer
for any stale, disagreeing list. In the degraded state the re-subscription echo
pushes the *same* names back while the mirror is `nil`, so `stale?/2` is true and
the record — retry marker and all — would be replaced with a fresh one on every
echo. That is an unbounded loop, reached only in exactly the state Part 2
creates. Add one branch to `reconcile/4`, above the general case: when the
pending record for this key already holds these exact names, return the state
unchanged — same record, same `retried?`, and **no timer reset**, so repeated
echoes cannot push the trailing edge out indefinitely. A list that genuinely
differs still replaces the record and resets the marker, so a real change is
never ignored, which is the existing brake's guarantee too.

**Make the decision testable.** Promote `finalize_reconciliations/3` to a public
function (documented, not `@doc false` — it is worth explaining), taking and
returning a plain state map. Its third argument must carry the pre-refresh
context as `%{unreconciled: previous_unreconciled, explicit?: boolean}`; move the
`carried_over` calculation out of private `run_refresh/2` and into this public
boundary. `run_refresh/2` captures those inputs before `clear_refresh_schedule/1`
and `do_refresh/1`, then hands them to the finalizer with the pending records.
This detail is load-bearing: merely passing an already-computed `carried_over`
map would test the merge but leave the roadmap's actual explicit-vs-structure
decision unreachable from `mix test`.

The finalizer needs no OSC and must not gain any. This is the fold-in of the
roadmap's "Unit coverage for the mirror-refresh cross-key loop brake": the
carry-over decision and every branch above become ordinary state-transition
tests, and the only thing left behind the live boundary is `do_refresh/1`'s OSC
round trip itself. Do **not** add a mock-transport abstraction or an injected
refresh function; the coalescing plan rejected both as disproportionate and
nothing here changes that.

### 4. Say when a structural refresh is still pending — `state.ex` + `handlers.ex`

*Beyond the entry's three changes, but retained because measurement 2 found a
second way an ordinary reply can state an unverified structure as final.*

A read landing inside the debounce window is served from a mirror that is known
to be behind, and says nothing about it. Add the flag rather than the fix:

- `snapshot/0`'s reply gains `refresh_pending?: state.refresh_timer != nil`.
  The four narrower reads are unchanged.
- `format_session_state/4` becomes `/5`, taking that flag last, and appends one
  sentence when it is true — separate from `@unknown_explanation`, which answers
  a different question and may appear in the same reply. Draft:

  > A structural change is still settling, so this may still show the previous
  > track or return layout: new entries can be absent and deleted entries can
  > still appear. It converges on its own. Do not re-read automatically; tell
  > the user the layout is still settling rather than reporting it as final.

  The last sentence exists because 785db9f's whole point is that the model must
  not turn an uncertain read into a retry loop.
- `serve_session_state/0` passes the new field through.

Note the ordering this creates and keep it: `refresh: true` runs
`refresh_sync/0`, which cancels the timer before rebuilding, so a refreshed read
never carries this sentence. It is a marker for the ordinary read only, which is
the read that had no way to know.

### 5. Unit coverage — `test/seshat/session/state_test.exs`, `test/seshat/tools/handlers_test.exs`

Everything here stays below the OSC boundary. The scheduler assertions call the
callbacks directly, as the existing tests do; they arm real timers, but the
messages land in the short-lived ExUnit process and no `Transport.query/3` is
reached. The fixture in `state_test.exs` already carries every scheduler field
and `pending_reconciliations`, so it needs only the `retried?` marker where a
record is built.

Against `finalize_reconciliations/3` directly (new — this is the folded-in
coverage item):

- a pending record whose key is `nil` in the rebuilt state, not yet retried →
  the record survives with `retried?: true`, a timer is armed, and
  `unreconciled` is **untouched**;
- the same with `retried?: true` already set → `unreconciled` records that exact
  name list, and no new timer is armed;
- a pending record whose key holds a non-`nil` list with different names →
  brake recorded immediately, no retry, no timer;
- a pending record that the rebuild reproduced → that key's brake cleared;
- from the same pre-refresh `unreconciled` map, the public finalizer computes
  that an unrelated key's existing brake survives a structure-only rebuild and
  is dropped by an explicit one — the cross-key loop brake and its
  `carried_over` decision, both previously unreachable from `mix test`.

Against `reconcile/4` via `handle_info/2`, as the existing structure-push tests
do:

- an identical name list re-pushed while a pending record exists leaves the
  record, its `retried?` marker and the timer reference **all unchanged** — the
  echo loop guard;
- a different name list replaces the record and resets `retried?`;
- the existing unreadable-return and exact-`unreconciled` brake tests still
  schedule nothing.

Against the formatter, in `handlers_test.exs`:

- `format_session_state/5` with the flag true appends the settling sentence
  once; with it false, the reply is byte-identical to today's;
- a reply that is both degraded and pending carries both sentences, once each.

**Parts 1 and 2 have no unit coverage and cannot have any.** `read_tracks/2` and
`do_refresh/1` reach `Transport.query/3` by construction, which the testing rules
forbid touching from `mix test`. Their verification is Part 6, and the plan
should not pretend otherwise: what the suite proves is that a `nil` track list
renders honestly (already covered) and that the retry/brake logic behaves given
one (Part 5). That a *real* degraded read produces the `nil` is a live check.

### 6. Live verification — `.claude/skills/smoke-test/SKILL.md`

Extend the existing section "If the change touches `Session.State`'s refresh or
`get_session_state`'s reply" rather than opening a new one — these checks share
its dead-Ableton setup and its warning that nothing in `mix test` executes any
of this. Add, after its step 5:

1. **The degraded rebuild is honest.** With Live running, ask for several tracks
   to be created and then removed **in one model response** (creates and deletes
   in the same instruction, so they land inside one debounce window and race the
   rebuild). Then read state once, plainly. Either the list is correct, or it
   reports the track list unknown — **it must never name a track that is not in
   Live's UI**. Compare the reply against Live's own track headers by eye; that
   comparison is the check. The race is timing-dependent and may take several
   attempts to provoke; a run that never degrades is not a pass, it is a run
   that did not test this. Confirm from the server log that a `Loaded N tracks`
   line was overlapped by a structural change.
2. **It recovers without `refresh: true`.** After a degraded read, make no
   further tool call and wait ~3s, then read plainly again: the list is correct.
   This is the retry in Part 3 doing what the narrowed `refresh: true` no longer
   lets the model do for itself. The log shows the retry as a second
   `Song:` / `Loaded …` sequence following the informational "could not read the
   track list — retrying once" line, and **exactly one** such retry.
3. **A genuine disagreement still brakes.** Not reproducible on demand and not
   required to pass — but if a `did not reproduce it` warning appears in the log
   during any of this, confirm it is followed by no further refresh for that
   list. The brake is what stops the flood, and Part 3 must not have loosened it
   for the disagreed case.
4. **The settling marker appears and clears** (Part 4). Creates plus a plain
   read in one model response → the reply carries the settling sentence. A later
   plain read, after the window, does not. `refresh: true` never carries it.
5. **The orchestration check the roadmap entry asks for.** In Claude Desktop,
   create three tracks in one request, then say "undo that". The trace must be
   exactly three `undo` calls followed by **one** ordinary `get_session_state` —
   no read between undos, no second read after. This verifies 785db9f's shipped
   description rather than anything in this plan, and it is the check that
   failed on 2026-08-01. Run it last, since it is the end-to-end statement of
   the whole item.

## Testing and verification

1. `mix test test/seshat/session/state_test.exs test/seshat/tools/handlers_test.exs`
2. `mix precommit`
3. With Ableton Live open, `/smoke-test` scoped to the refresh section, running
   Part 6's five checks.

The suite proves the retry/brake state machine, the echo-loop guard, the
cross-key carry-over and both rendering paths. Only Live can prove that a real
degraded read is detected as one, that the retry converges, and that the
measured reproduction no longer names a deleted track.

## Out of scope

- **Change 3 as the entry writes it — `length(names)` instead of `num_tracks`.**
  Declined on the reasoning in Context: with refreshes coalesced, the pushed name
  list is older than a fresh `num_tracks` query by a debounce window plus any
  rebuild in front of it, so trusting its length would make the count staler in
  the exact burst this item is about. Part 1 buys the same wall-time win by
  short-circuiting the dead index. The entry's own framing — "narrows the race
  rather than closing it" — applies to this substitute too; neither closes it.
  **Reconsider if** Part 6 check 1 shows rebuilds still eating multiple
  `@query_timeout`s per burst after Part 1.
- **Raising `@refresh_debounce_ms`.** The entry rules it out and this plan
  agrees: it would coalesce multi-round bursts, at the price of widening the
  interval in which every read is served stale. Part 4 makes that window
  *visible* instead of longer.
- **`undo`/`redo` calling `State.refresh/0`.** Also ruled out by the entry, and
  the reason stands: the identical race reproduces from hand-edits in Live with
  no tool call involved, so refreshing on the one trigger that happened to be
  measured papers over the mechanism.
- **`undo` reporting success it never observed.** Its own roadmap item, ranked
  directly below this one. This plan makes the *verification read* honest; it
  does not touch what `undo` claims.
- **Return tracks and master.** The analogous race exists in
  `read_return_tracks/2`, but its wire failure is different: the vendored getter
  returns an error envelope promptly for a dead index rather than timing out,
  and `return_tracks` has no `nil` sentinel (`[]` plus `returns_readable?`
  currently carries "unavailable"). A row with an unknown name can still assert
  an index that disappeared after the count was read, so do not describe that as
  intrinsically honest; it is excluded because that symptom has not been
  measured and fixing it needs a separate representation decision.
  **Reconsider if** the same stale-presence symptom is observed on a return.
- **Moving refresh work out of the GenServer** — the monitored refresh worker,
  already recorded under "Deliberately not planned" as deferred until the
  blocking window is actually observed.
- **Any Python change.** Every address and push shape this plan depends on is
  already in the fork and already documented.

## Open questions

None. Two choices that were tentative in the first draft are resolved here:

- The first unanswered name condemns the whole read. A false positive costs one
  bounded extra rebuild; softening the rule would knowingly allow a row whose
  identity was not established and reopen the defect. The three healthy live
  reads are limited evidence, so unexpected retries during ordinary use should
  be recorded as a follow-up rather than changing this implementation ad hoc.
- Part 4's settling sentence stays. The live reproduction showed an ordinary
  read can knowingly expose the previous structure during the debounce window,
  and labeling that uncertainty is consistent with the roadmap's honesty
  requirement. The corrected draft explicitly covers both omissions and deleted
  entries that can still appear.
