# The session mirror

`Session.State` answers `nil` — unknown — for anything Ableton didn't answer, and
`get_session_state` renders that as a stated unknown rather than a plausible
number. Every branch that produces a `nil` reaches `Transport.query/3` by design,
so **nothing in `mix test` executes any of it**; the formatters are pure-tested,
the failure path that produces `nil` at all is only reachable here.

Refreshes are also debounced — one trailing timer a second after the latest
request — and state correctness alone cannot see that: one refresh and twenty
redundant ones leave the same mirror. Those tests are read from the **server
log**, where a full rebuild prints a `Song: …` line followed by
`Loaded N tracks: …`.

**How the calls are issued is part of several tests here, not a detail.**
Measured 2026-07-31: tool calls emitted **in one model response** arrive ~0.5s
apart, while calls needing **separate model rounds** arrive ~2.1s apart at the
floor — after the timer has already fired. Where a test says to ask for the whole
sequence in a single instruction, one message per step silently tests nothing and
reports success while doing it.

## Nothing is fabricated when Ableton stops answering

*Run mode: user — requires quitting or disabling Ableton and starting it again*
*Last run: —*

With the Seshat server running, quit Ableton Live (or toggle AbletonOSC off in
Live's MIDI preferences). Steps 1 and 2 are timing-coupled — read both before
starting.

1. `get_session_state` with `refresh: true` → the timeout error from
   `maybe_refresh/1`. The GenServer is still refreshing when that error arrives:
   against a dead Ableton `do_refresh/1` takes roughly 47s (eight song queries at
   5s each, the 5s `num_tracks` probe, the 2s returns probe) while the caller
   gives up at 30s, so about 17s of it remain.
2. **Read again inside those ~17s**, plain, no refresh → "The session mirror did
   not answer — it may be mid-refresh against an unresponsive Ableton. Try again
   shortly". This is the only live exercise of that message, and it must never
   read as an empty session. Miss the window and the call simply succeeds; retry
   from 1 rather than counting that as a pass.
3. **Wait ≥10s, read again**, plain → tempo, time signature, key, playing state,
   groove and swing all reported unknown; the track list reported
   unknown-**not**-empty; the trailing explanation sentence present exactly once.
   **It must not say 120 BPM, 4/4, C Major, or list the previous set's tracks.**
   Those four fabrications are what this behaviour exists to remove, and any of
   them appearing is the whole test failing.
4. **Still with Live closed**, `record_clip bars: 4` → the
   time-signature-unknown error naming `refresh: true`, not an `ArithmeticError`
   from a `nil` numerator and not a generic timeout.
5. **Start Live again.** `/live/startup` fires a refresh on its own; wait, then
   read plain → real values, no unknown remnants, no trailing sentence. Listener
   re-subscription pushes the current value of everything, so anything a lost
   datagram nil'd repopulates without a manual refresh.

## A degraded rebuild is honest

*Run mode: user — requires comparison against Live's visible track headers*
*Last run: —*

Needs Live **running**. Ask for several tracks to be created and then removed
**in one model response** — creates and deletes in the same instruction, so they
land inside one debounce window and race the rebuild. Then read state once,
plainly. Either the list is correct, or it reports the track list unknown — **it
must never name a track that is not in Live's UI**. Compare the reply against
Live's own track headers by eye; that comparison is the check.

The race is timing-dependent and may take several attempts to provoke; a run that
never degrades is **not a pass**, it is a run that did not test this.

The log signature of a degraded rebuild is a `Song: …` line followed by
`the read stopped at index …`, with **no `Loaded N tracks` line between them**:
`Song:` is emitted before every rebuild's `num_tracks` probe, while `Loaded …`
and the stopped-index warning are the two arms of one `case` and can never both
describe the same rebuild. Healthy `Loaded …` lines from neighbouring rebuilds in
the same burst are expected — don't read one as contradicting the degraded read.

## A degraded rebuild recovers without `refresh: true`

*Run mode: user — depends on first provoking and visually confirming a degraded rebuild*
*Last run: —*

After a degraded read, make no further tool call, wait ~3s, then read plainly
again: the list is correct. This is the single retry doing what the narrowed
`refresh: true` no longer lets the model do for itself.

If a structure push was still pending when the rebuild ran, the log shows it as a
second `Song:` / `Loaded …` sequence following the informational `could not read
the track list — retrying once` line, and **exactly one** such retry; if nothing
was pending, recovery instead comes from the re-subscription echo (`Track list
changed in Live — scheduling a session refresh`) and that line never appears.
Either way, the check is the list being correct on the follow-up read.

## A genuine disagreement still brakes

*Run mode: user — can only be observed while running the user-required degraded-rebuild scenario*
*Last run: —*

Not reproducible on demand and not required to pass — but if a `did not reproduce
it` warning appears in the log during any of the above, confirm it is followed by
no further refresh for that list. The brake is what stops the flood, and the
failed/disagreed split must not have loosened it for the disagreed case.

## The settling marker appears and clears

*Run mode: agent*
*Last run: 2026-08-03 — passed, all three clauses. Two `create_track` calls plus
a plain read in one model response: the read carried "A structural change is
still settling…" and showed the pre-create layout (track 0 alone). A plain read
one model round later carried no such sentence and listed both new tracks. A
third create plus `refresh: true` in one model response rebuilt immediately —
the just-created track present, no settling sentence — confirming
`refresh_sync/0` cancels the timer.*

Creates plus a plain read **in one model response** → the reply carries "A
structural change is still settling…". A later plain read, after the window, does
not. `refresh: true` never carries it (`refresh_sync/0` cancels the timer before
rebuilding).

## The scalar mixer setters no longer trigger a refresh

*Run mode: agent*
*Last run: 2026-08-03 — **state half passed, log half not checked.** All seven
setters issued in one model response, then a plain `get_session_state`: it
answered carrying every pushed value — return volume 0.7, pan −0.3, muted,
soloed; master volume 0.8, pan 0.2, cue 0.6. **The four return listener pushes
this test flags as "inferred from the master ones, never measured" are hereby
measured: all four arrive.** The `no Song:/Loaded …` assertion was not checked —
the Seshat server's log goes to its own tty (`/dev/ttys005`), which the agent
cannot read; re-run this half from the terminal running the server.*

Issue the four return mixer setters (volume, pan, mute, solo) and the three
master ones (volume, pan, cue volume) in a burst, then `get_session_state`
**without** `refresh: true`: it answers and carries the pushed final values. The
log shows **no** full-refresh `Song:` / `Loaded …` sequence caused by those
setters.

If the four return values are the ones that don't arrive, the fix is to restore
`State.refresh()` in those four handlers only — their listener pushes were
inferred from the master ones, never measured.

## A burst of creates collapses into one refresh

*Run mode: agent*
*Last run: 2026-08-03 — **blocked, not run.** The check is the log timestamps of
every tool call against every `Song:` / `Loaded …` sequence, and the Seshat
server's log goes to its own tty (`/dev/ttys005`), unreadable by an agent. The
state-visible half was seen incidentally while running the settling-marker test
above (burst of creates → snapshot window → convergence) but proves nothing
about the refresh *count*, which is this test. Re-run from the terminal running
the server.*

On scratch material, create several tracks with a distinct final name, **with the
creates and the read in one model response**. An ordinary read during the quiet
window answers promptly (it may still show the pre-create structure — that
snapshot window is intended); after the window, state includes the final track.

Record the log timestamps of every tool call and every `Song:` / `Loaded …`
sequence: calls closer together than the window must share one trailing refresh,
and calls separated by longer model rounds may form several windows — report the
observed count rather than claiming the whole request was one window. At no point
may finished calls leave a *chain* of refreshes queued; after the last call
exactly one trailing refresh converges the mirror. Delete every scratch track
afterwards.

## `refresh: true` absorbs the pending timer

*Run mode: agent*
*Last run: 2026-08-03 — **blocked, not run.** The "rebuilds immediately" half was
observed (create + `refresh: true` in one model response returned the new track
at once), but the discriminating half — **no duplicate refresh a second later** —
is a log reading, and the server's log goes to its own tty (`/dev/ttys005`).
Re-run from the terminal running the server.*

While an asynchronous refresh is pending, call `get_session_state(refresh: true)`
— issue the mutation and the refreshing read **in one model response**, or the
timer has already fired and nothing is pending when the read lands, which reads
as a pass. It rebuilds immediately, and **no duplicate refresh appears a second
later**.

## The last request is never dropped

*Run mode: agent*
*Last run: 2026-08-03 — **blocked, not run.** Confirming the mutation landed
*mid*-rebuild requires the log timestamps, and the server's log goes to its own
tty (`/dev/ttys005`). Running only the final-state half would not distinguish a
mid-rebuild mutation from the just-after one this test names as the likely
near-miss, so it was not attempted. Re-run from the terminal running the
server.*

Make one more structural mutation while a rebuild is already running (it lasts
1.0–1.8s, so again from the same model response), and confirm one trailing
refresh follows it and the final mutation is present afterwards. Check the log
timestamps to confirm the mutation really landed *mid*-rebuild: arriving just
after one looks identical in the final state and is the likely near-miss.
