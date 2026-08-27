# Track sends

`set_track_send` and `get_track_sends` — the send levels on regular tracks.
This is the one mixer value with **no listener and no mirror entry**: nothing
in `mix test` reaches any of it, and until these tests were written nothing
live-checked it either, so assume zero prior coverage. `/live/track/get|set/send`
are upstream addresses (no reinstall precondition), but `get_track_sends` and
the set-up below also touch `/live/return_track/get/name`, which is vendored —
a set with no reachable return names points at [bridge.md](bridge.md) first.

Set-up: at least one regular track and one return track. If the set has no
return, create one with `create_track track_type: "return"`, note that you did,
and delete it at the end with `delete_track target: "return"`.

## A send set is confirmed by its own read-back

*Last run: 2026-08-05 (re-run against the merged bridge; previously
2026-08-04) — all five sets confirmed. 0.37, 1.0, 0.0, then 0.37 twice; every
reply read "confirmed by reading it back" and named the right "was"
(0.0 → 0.37 → 1.0 → 0.0 → 0.37, the idempotent repeat reporting "was 0.37").
`get_track_sends` agreed at 0.37 afterwards. No reply ever said "did
not land" or "did not confirm it", so at microsecond spacing AbletonOSC does
process set-then-get in arrival order, and the 4-decimal comparison absorbs the
float32 widening (0.37 → 0.3700000047683716).*

`set_track_send` reads `/live/track/get/send` back after the silent set and
only reports success it observed. The in-process read-back follows the set by
microseconds — likely inside one AbletonOSC tick — so every confirmed reply is
also evidence that AbletonOSC really processes the two datagrams in arrival
order at that spacing, which no pure test can show.

Record the send's current level with `get_track_sends`. Then, each as its own
call: set the send to `0.37` (not exactly representable in a 32-bit OSC
float), then to `1.0`, then to `0.0`, then to `0.37` twice in a row (the
repeat is idempotent and must still confirm). Every reply must state the level
was confirmed by reading it back — not merely "Set send A…" — and name the
correct "was" value. After the batch, `get_track_sends` must agree with the
last value set. Restore the level you found (or delete the probe return).

A reply saying the set "did not land" or "did not confirm it" on a healthy
loopback means the read-back raced the set inside AbletonOSC or the
comparison is rejecting the wire's float32 widening — check the 4-decimal
comparison and the in-order-processing assumption in the `set_track_send`
clause ([lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)).
A reply that asserts success with no confirmation wording means the read-back
is gone.

## Reading a track's sends labels each return correctly

*Last run: 2026-08-05 — passed, and this is the first live run of this check.
With returns "A-Alpha" and "B-Beta" and track 0's sends confirmed at 0.2 and
0.8, one `get_track_sends` produced `send 0 (A) -> "A-Alpha": 0.2` and
`send 1 (B) -> "B-Beta": 0.8`. The wire shows why that matters: after the
`/live/return_track/get/count [2]` reply, all five remaining entries came back
inside the **same millisecond** (15:49:40.898) — `2N+1` with N=2, one tick —
and two of them were `/live/return_track/get/name` and two were
`/live/track/get/send`, i.e. two pairs sharing an address and distinguished
only by echoed index. The echo-prefix matching had real work to do and got it
right. `track: 99` answered in 291ms with Live's own "Index out of range",
having produced three per-entry structured errors (`/live/track/get/name` argc
1, and `/live/track/get/send` argc 2 twice, echoing 99 with send 0 and 1)
alongside the two return-name replies that legitimately succeeded — so
per-entry `/live/error` correlation does reach batch entries. Float32 widening
was visible and absorbed: 0.2 arrived as 0.20000000298023224, 0.8 as
0.800000011920929.*

`get_track_sends` reads every send's return name and level in one batched
tick (`query_batch` — one datagram burst of `2N + 1`, replies matched by
echoed index inside `Seshat.OSC.Transport`). The hazard the batch must
preserve against is mispairing: return A's name over return B's level, or one
track's send answered with another's.

Set-up on top of the file's: a **second** return track (create it, note that
you did, delete it at the end), so a swapped label is detectable at all.

Set send A and send B on one track to distinct, confirmed levels (`0.2` and
`0.8`). Then call `get_track_sends` once: both sends must appear, each named
with the right return's name and carrying the level just confirmed, the last
send index present. Then call it with a track index the set doesn't have
(`track: 99`): expect an immediate error (well under a second, Live's own
"Index out of range" rendered generically), never a multi-second stall.

A right-level-wrong-name pairing means the batch's echo-prefix matching (or
the caller's decode zip) is broken — worse than a timeout, because it reads
as an answer. A stall on the bad track index means the per-entry
`/live/error` correlation is not reaching batch entries.

## A bad send index is refused before the set

*Last run: 2026-08-05 (re-run against the merged bridge; previously
2026-08-04) — refused fast. `send: 9` against two returns returned "Index out
of range. Nothing further was sent…" in 177ms over a full HTTP handshake,
nowhere near the ~2s guard timeout, and `get_track_sends` afterwards still read
0.2 and 0.8 — nothing mutated. The rejection arrives as `result` with
`isError: true`, not a bare protocol error. Live's log
recorded the raise on `/live/track/get/send` — the guard address, not the
setter — and `get_track_sends` still read 0.37, so nothing mutated. The
rejection arrives as `result` with `isError: true`, not a bare protocol
error.*

The pre-set guard reads the send first, so an index Live doesn't have is
rejected in Live's own words with nothing mutated — and since the `/live/error`
correlation it is rejected *fast*.

On a set with one return track, call `set_track_send` with `send: 9`. Expect
an immediate error (well under a second, not a ~2s guard timeout) carrying
Live's own rejection ("Index out of range") and stating nothing further was
sent. `get_track_sends` afterwards must show send A unchanged.

A ~2s stall means the structured `/live/error` correlation is not matching the
guard query (see `Seshat.OSC.Transport`'s "Failed-query correlation"); a
success reply means the guard has been lost from the clause.
