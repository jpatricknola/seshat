# Transport — tempo, meter, swing and groove

`swing_amount` is fork-only — one `properties_rw` line added to
`priv/AbletonOSC/abletonosc/song.py` — so a Remote Scripts copy predating the fork
pin makes `/live/song/set/swing_amount` silently a no-op, indistinguishable from
success. `groove_amount` is upstream and needs no reinstall. AbletonOSC's
`_set_property` swallows a Live API rejection silently, which is why the time
signature's denominator is a schema enum rather than a bounded integer.

## Groove and swing read as numbers, not unknowns

*Run mode: agent*
*Last run: 2026-08-03 — passed. `get_session_state`'s song line read "120.0 BPM,
4/4, stopped, key: C Major, **groove 0.0, swing 0.0**" — both numeric, neither
"unknown", so the fork's `swing_amount` line is live in the installed copy.*

`get_session_state` shows numeric groove *and* swing values, not "unknown". Live
12 Suite has `Song.swing_amount`, so "swing unknown" means the wire, not the
property — almost certainly the fork wasn't reinstalled or Live wasn't restarted.
Fix that before anything else here; every test below depends on it.

## Swing reaches the mirror by push

*Run mode: agent*
*Last run: 2026-08-03 — passed. After `set_swing_amount 0.25`, a plain
`get_session_state` with no `refresh: true` reported "swing 0.25" — the listener
echo, not a fresh query. Restored to 0.0.*

`set_swing_amount 0.25`, then `get_session_state` **without** `refresh: true` —
the mirror shows 0.25 via the listener echo, not a fresh query.

## Swing plus quantize actually swings

*Run mode: user — includes judging the amount of swing by ear*
*Last run: —*

Set swing, then `quantize_clip` at `"1/8"` on a straight clip — notes land *off*
the straight grid, on swung positions. This is the end-to-end "make it swing".
Judge by ear whether 0.10–0.20 reads as "subtle"; if not, the fix is
`set_swing_amount`'s description, not the code.

## The groove dial reads 130% at 1.3

*Run mode: user — requires assigning a groove in Live and reading its dial*
*Last run: —*

With a groove assigned to a clip **by hand in Live**, `set_groove_amount 0.0`,
then `1.0`, then `1.3` — audible change, and the Groove Pool's Amount dial reads
**100%** at 1.0 and **130%** at 1.3. Anything else means the mapping moved in this
Live version and the schema max needs revisiting.

The 0.0–1.3 bound — read out of Live's own shipped Python, correcting the LOM
apiref's understated 0.0–1.0 — is recorded on the `groove_amount` rows in
[../abletonosc-api-docs.md](../abletonosc-api-docs.md#song-getters).

## Groove with nothing assigned says so

*Run mode: user — requires confirming the set has no assigned grooves and judging model wording*
*Last run: —*

`set_groove_amount` with **no** grooves assigned anywhere in the set — nothing
changes audibly, and the model's reply (fed by the tool description) says so
rather than promising swing.

## The time signature lands and pushes

*Run mode: agent*
*Last run: 2026-08-03 — passed, both halves. `set_time_signature 6/8` then a
plain `get_session_state` reported "120.0 BPM, **6/8**" with no round trip. The
schema enum refused both bad shapes before the wire, each reply opening "Invalid
parameters for set_time_signature — nothing was sent to Ableton": denominator 3 →
"must be one of 1, 2, 4, 8, 16 (got 3)", numerator 100 → "must be at most 99 (got
100)". 4/4 restored afterwards.*

`set_time_signature` to 6/8, then `get_session_state` **without** `refresh: true`
already shows 6/8 — the property listener pushes the change without a round trip.
Then a denominator Live rejects: the schema enum (`1, 2, 4, 8, 16`) must refuse it
before it reaches the wire, because `_set_property` would swallow the rejection
and the call would read as a silent success. Restore the original signature
afterwards.
