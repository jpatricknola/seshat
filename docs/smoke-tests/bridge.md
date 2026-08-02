# Bridge integrity

`/live/browser/*`, `/live/return_track/*` and `/live/master/*` are Seshat's own,
served by the fork at [priv/AbletonOSC/](../../priv/AbletonOSC/). `mix test`
greps the submodule in the repo; Live runs the copy in Remote Scripts. Nothing
else in this project can tell you those two agree.

**Precondition for every test in this file, and for anything else that touches
`priv/AbletonOSC`:** run `mix abletonosc.install` and **restart Live** (or toggle
AbletonOSC off and on under Preferences > Link/Tempo/MIDI — `/live/api/reload`
does not pick these up). Without it every result anywhere is right for the wrong
reason.

## The extension is answering at all

*Last run: —*

`get_session_state` prints return tracks and master volume when `return_track.py`
is loaded, and a single "Return/master state unavailable" line when it isn't. A
whole feature reading as broken usually means a skipped `mix abletonosc.install`
and Live restart — check this before diagnosing anything else.

## A bad index errors immediately, not after ~2s

*Last run: —*

These handlers always reply, including on an out-of-range index, and the reply
names the real count. A ~2s timeout instead means the installed copy is stale.
That distinction is the entire point of the reply envelope, and it is the
cheapest stale-install detector there is.

Try it at every depth, not just the track: a bad *device* index on
`set_device_parameter` or `bypass_device` against a valid return must error the
same way — that case once came back as a false "try again" timeout because the
parameter index was echoed as `-1` instead of the value actually asked for.

## A stale install is distinguishable from a broken tool

*Last run: —*

Before reinstalling during implementation — or against an older Remote Scripts
copy — every vendored tool must fail with the `mix abletonosc.install` hint
rather than a bare timeout or a regular-track error message. If the new copy is
already installed, report this as **not reproduced**; never downgrade and restart
Live just to manufacture it. A raw `Transport.query` is not a substitute: it
bypasses the handler wording this test exists to verify.

## Live's `Log.txt` stays clean during ordinary work

*Last run: —*

Baseline its byte size before the run and read only the tail. Upstream raised a
`RemoteScriptError` on every clip-slot operation, so a traceback during
`write_midi_notes`, `delete_clip`, `duplicate_clip` or `get_clip_slots` means an
old AbletonOSC is still installed.
(`~/Library/Preferences/Ableton/Live <version>/Log.txt`.)

## The listener rebind, by hand in Live's UI

*Last run: —*

Delete a track, then rename a *different* one, then `get_session_state`. Every
name must be under the right index.

This guards the fork's fix to `AbletonOSCHandler._stop_listen`, which unbound a
listener from the wrong object once an index had been reused. It is the one fix
whose failure is completely silent — every address still answers — so nothing but
this test finds it. Do it by hand: a tool-driven substitute exercises the same
LOM mutation but proves nothing about UI-originated edits.
