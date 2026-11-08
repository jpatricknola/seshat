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

**That log is a file, and that is what keeps these tests zero-user.** The server
logs to its terminal *and* to `log/dev.log` (`config :seshat, :logger` in
[config/dev.exs](../../config/dev.exs), added 2026-08-03 for exactly this
reason — before it, an agent sweep could not see a `Song:` line at all, let
alone count them, and four tests here were briefly retagged `user` for want of
one). Baseline its byte size before a run and read only the tail past that
offset, the same discipline [bridge.md](bridge.md) uses for Live's `Log.txt`. It
rotates at 10MB, so a run that spans a rotation would invalidate an offset taken
before it — no smoke run comes close, but that is the failure to look for if a
tail read ever returns nonsense.

**How the calls are issued is part of several tests here, not a detail.**
Measured 2026-07-31: tool calls emitted **in one model response** arrive ~0.5s
apart, while calls needing **separate model rounds** arrive ~2.1s apart at the
floor — after the timer has already fired. Where a test says to ask for the whole
sequence in a single instruction, one message per step silently tests nothing and
reports success while doing it.

## The settling marker appears and clears

*Last run: 2026-11-08 — passed, all three clauses. Two create_track calls plus a plain read ~0.4s apart: the read carried "A structural change is still settling…" and showed track 0 alone. A plain read 4s later listed both. A third create plus refresh: true rebuilt immediately — the new track present, no settling sentence.*

Creates plus a plain read **in one model response** → the reply carries "A
structural change is still settling…". A later plain read, after the window, does
not. `refresh: true` never carries it (`refresh_sync/0` cancels the timer before
rebuilding).

## The scalar mixer setters no longer trigger a refresh

*Last run: 2026-11-08 — passed, both halves. Seven set_mixer calls (return volume 0.7, pan −0.3, mute, solo; master 0.8, pan 0.2; cue 0.6) ~0.17s apart, then a plain get_session_state carrying every pushed value; all four return listener pushes arrived. Past the offset: zero Song:, zero Loaded, zero scheduling lines. Restored afterwards.*

Issue the four return properties (`set_mixer target: "return"` with volume,
pan, mute, solo) and the three master/cue ones (`target: "master"` with volume
and pan, `target: "cue"` with volume) in a burst, then `get_session_state`
**without** `refresh: true`: it answers and carries the pushed final values. The
log shows **no** full-refresh `Song:` / `Loaded …` sequence caused by those
setters.

Baseline the log offset *after* any scratch return you created has settled — a
`create_track track_type: "return"` is itself structural and produces exactly
the sequence this test is looking for the absence of.

If the four return values are the ones that don't arrive, the fix is to restore
`State.refresh()` in `set_mixer`'s return branch only — their listener pushes
were inferred from the master ones, never measured.

## A burst of creates collapses into one refresh

*Last run: 2026-11-08 — passed, count included. Three structural pushes at 13:56:48.416, .832, 49.239, then exactly one rebuild — Song: at 51.132, `Loaded 7 tracks` at 55.544 (a 4.4s rebuild on 7 tracks). In-window read carried the settling sentence; a later plain read listed all seven. The stale-push `did not reproduce` brake fired once afterwards with no further refresh.*

*A `did not reproduce it` warning followed at :36.617 — a stale push carrying
`"4-MIDI"` for the track the rebuild had already recorded as `"Burst Final"`,
because `create_track` names the track after creating it. The brake held: no
further refresh followed, which is the check "A genuine disagreement still
brakes" above asks for.*

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

*Last run: 2026-11-08 — passed. create_track then get_session_state(refresh: true) ~0.4s apart: one scheduling line at 13:56:57.111, one Song: at 58.191, one `Loaded 8 tracks` at 57:03.213 naming the new track; no second rebuild. The reply carried the new track and no settling sentence.*

While an asynchronous refresh is pending, call `get_session_state(refresh: true)`
— issue the mutation and the refreshing read **in one model response**, or the
timer has already fired and nothing is pending when the read lands, which reads
as a pass. It rebuilds immediately, and **no duplicate refresh appears a second
later**.

## The last request is never dropped

*Last run: 2026-11-08 — passed, mid-rebuild condition provoked on the first attempt (8-track set, ~5s rebuild). Debounce fired ~13:57:35.8; six search_library fillers; delete_track replied at 36.34, before the rebuild's Song: line at 36.501 — and that rebuild's own `Loaded 8 tracks` at 41.554 already lacked the deleted track. The delete's push then hit the `did not reproduce` path at 42.473 and exactly one trailing refresh followed (44.321 → 49.333), converging on the correct list.*

**Use a send-only mutation, and do not use `create_track`.** The first two
attempts were the near-miss this test warns about — the mutation scheduled its
refresh ~0.9s *after* the rebuild ended, every time. The cause is structural:
`Transport` serializes queries one-in-flight, `create_track` queries (it counts
tracks before and after), so a create issued during a rebuild queues behind the
rebuild's own queries and cannot execute until it finishes. `delete_track` is
send-only, so its datagram goes straight out and lands mid-rebuild.

Make one more structural mutation while a rebuild is already running, and confirm
one trailing refresh follows it and the final mutation is present afterwards.
Check the log timestamps to confirm the mutation really landed *mid*-rebuild:
arriving just after one looks identical in the final state and is the likely
near-miss.

A rebuild took **4.6s** on a 9-track set measured 2026-08-03 (`Song:` to
`Loaded …`), so the mutation has a wide window — but it must be issued from the
same model response, and the calls before it need to fill roughly a second so
the debounced refresh has actually started. `search_library` is the filler to
reach for: it answers from ETS and never touches `Transport`, so it spends time
without competing for the query queue.
