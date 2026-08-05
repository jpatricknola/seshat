# Transport — tempo, meter, swing and groove

`swing_amount` is fork-only — one `properties_rw` line added to
`priv/AbletonOSC/abletonosc/song.py` — so a Remote Scripts copy predating the fork
pin makes `/live/song/set/swing_amount` silently a no-op, indistinguishable from
success. `groove_amount` is upstream and needs no reinstall. The time signature's
denominator is a schema enum rather than a bounded integer because setters are
sent fire-and-forget: `Transport.send_message/2` has returned before Live could
reject anything, so an out-of-enum value would read as a silent success no
matter what Live does with it.

## Groove and swing read as numbers, not unknowns

*Last run: 2026-08-03 — passed. `get_session_state`'s song line read "120.0 BPM,
4/4, stopped, key: C Major, **groove 0.0, swing 0.0**" — both numeric, neither
"unknown", so the fork's `swing_amount` line is live in the installed copy.*

`get_session_state` shows numeric groove *and* swing values, not "unknown". Live
12 Suite has `Song.swing_amount`, so "swing unknown" means the wire, not the
property — almost certainly the fork wasn't reinstalled or Live wasn't restarted.
Fix that before anything else here; every test below depends on it.

## Swing reaches the mirror by push

*Last run: 2026-08-03 — passed. After `set_swing_amount 0.25`, a plain
`get_session_state` with no `refresh: true` reported "swing 0.25" — the listener
echo, not a fresh query. Restored to 0.0.*

`set_swing_amount 0.25`, then `get_session_state` **without** `refresh: true` —
the mirror shows 0.25 via the listener echo, not a fresh query.

## The time signature lands and pushes

*Last run: 2026-08-03 — passed, both halves. `set_time_signature 6/8` then a
plain `get_session_state` reported "120.0 BPM, **6/8**" with no round trip. The
schema enum refused both bad shapes before the wire, each reply opening "Invalid
parameters for set_time_signature — nothing was sent to Ableton": denominator 3 →
"must be one of 1, 2, 4, 8, 16 (got 3)", numerator 100 → "must be at most 99 (got
100)". 4/4 restored afterwards.*

`set_time_signature` to 6/8, then `get_session_state` **without** `refresh: true`
already shows 6/8 — the property listener pushes the change without a round trip.
Then a denominator Live rejects: the schema enum (`1, 2, 4, 8, 16`) must refuse it
before it reaches the wire, because a setter is fire-and-forget and the call would
otherwise read as a silent success whether Live accepted the value or not.
Restore the original signature afterwards.
