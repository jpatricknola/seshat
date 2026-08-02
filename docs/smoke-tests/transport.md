# Transport — tempo, meter, swing and groove

`swing_amount` is fork-only — one `properties_rw` line added to
`priv/AbletonOSC/abletonosc/song.py` — so a Remote Scripts copy predating the fork
pin makes `/live/song/set/swing_amount` silently a no-op, indistinguishable from
success. `groove_amount` is upstream and needs no reinstall. AbletonOSC's
`_set_property` swallows a Live API rejection silently, which is why the time
signature's denominator is a schema enum rather than a bounded integer.

## Groove and swing read as numbers, not unknowns

*Last run: —*

`get_session_state` shows numeric groove *and* swing values, not "unknown". Live
12 Suite has `Song.swing_amount`, so "swing unknown" means the wire, not the
property — almost certainly the fork wasn't reinstalled or Live wasn't restarted.
Fix that before anything else here; every test below depends on it.

## Swing reaches the mirror by push

*Last run: —*

`set_swing_amount 0.25`, then `get_session_state` **without** `refresh: true` —
the mirror shows 0.25 via the listener echo, not a fresh query.

## Swing plus quantize actually swings

*Last run: —*

Set swing, then `quantize_clip` at `"1/8"` on a straight clip — notes land *off*
the straight grid, on swung positions. This is the end-to-end "make it swing".
Judge by ear whether 0.10–0.20 reads as "subtle"; if not, the fix is
`set_swing_amount`'s description, not the code.

## The groove dial reads 130% at 1.3

*Last run: —*

With a groove assigned to a clip **by hand in Live**, `set_groove_amount 0.0`,
then `1.0`, then `1.3` — audible change, and the Groove Pool's Amount dial reads
**100%** at 1.0 and **130%** at 1.3. Anything else means the mapping moved in this
Live version and the schema max needs revisiting.

The 0.0–1.3 bound — read out of Live's own shipped Python, correcting the LOM
apiref's understated 0.0–1.0 — is recorded on the `groove_amount` rows in
[../abletonosc-api-docs.md](../abletonosc-api-docs.md#song-getters).

## Groove with nothing assigned says so

*Last run: —*

`set_groove_amount` with **no** grooves assigned anywhere in the set — nothing
changes audibly, and the model's reply (fed by the tool description) says so
rather than promising swing.

## The time signature lands and pushes

*Last run: —*

`set_time_signature` to 6/8, then `get_session_state` **without** `refresh: true`
already shows 6/8 — the property listener pushes the change without a round trip.
Then a denominator Live rejects: the schema enum (`1, 2, 4, 8, 16`) must refuse it
before it reaches the wire, because `_set_property` would swallow the rejection
and the call would read as a silent success. Restore the original signature
afterwards.
