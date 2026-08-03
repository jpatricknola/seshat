# Track sends

`set_track_send` and `get_track_sends` — the send levels on regular tracks.
This is the one mixer value with **no listener and no mirror entry**: nothing
in `mix test` reaches any of it, and until these tests were written nothing
live-checked it either, so assume zero prior coverage. `/live/track/get|set/send`
are upstream addresses (no reinstall precondition), but `get_track_sends` and
the set-up below also touch `/live/return_track/get/name`, which is vendored —
a set with no reachable return names points at [bridge.md](bridge.md) first.

Set-up: at least one regular track and one return track. If the set has no
return, create one with `create_return_track`, note that you did, and delete it
at the end.

## A send set is confirmed by its own read-back

*Last run: 2026-08-04 — all five sets confirmed. 0.37, 1.0, 0.0, then 0.37
twice; every reply read "confirmed by reading it back" and named the right
"was" (0.0 → 0.37 → 1.0 → 0.0 → 0.37, the idempotent repeat reporting "was
0.37"). `get_track_sends` agreed at 0.37 afterwards. No reply ever said "did
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

## A bad send index is refused before the set

*Last run: 2026-08-04 — refused fast. `send: 9` against one return returned
"Index out of range. Nothing further was sent…"; timed over a full HTTP
handshake at 0.144s total, nowhere near the ~2s guard timeout. Live's log
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
