# Bridge integrity

`/live/browser/*`, `/live/return_track/*` and `/live/master/*` are Seshat's own,
served by the fork at [priv/AbletonOSC/](../../priv/AbletonOSC/). `mix test`
greps the submodule in the repo; Live runs the copy in Remote Scripts. Nothing
else in this project can tell you those two agree.

**Change-verification precondition for every test in this file, and for anything
else that touches `priv/AbletonOSC`:** run `mix abletonosc.install` and **restart
Live** (or toggle AbletonOSC off and on under Preferences > Link/Tempo/MIDI —
`/live/api/reload` does not pick these up). Without it every result anywhere is
right for the wrong reason. The zero-user `/smoke-test agent` sweep never restarts
Live; it first compares the installed copy with the repo and skips fork-dependent
tests when they differ.

## The extension is answering at all

*Run mode: agent*
*Last run: —*

`get_session_state` prints return tracks and master volume when `return_track.py`
is loaded, and a single "Return/master state unavailable" line when it isn't. A
whole feature reading as broken usually means a skipped `mix abletonosc.install`
and Live restart — check this before diagnosing anything else.

## A bad index errors immediately, not after ~2s

*Run mode: agent*
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

*Run mode: agent*
*Last run: —*

Before reinstalling during implementation — or against an older Remote Scripts
copy — every vendored tool must fail with the `mix abletonosc.install` hint
rather than a bare timeout or a regular-track error message. If the new copy is
already installed, report this as **not reproduced**; never downgrade and restart
Live just to manufacture it. A raw `Transport.query` is not a substitute: it
bypasses the handler wording this test exists to verify.

## Live's `Log.txt` stays clean during ordinary work

*Run mode: agent*
*Last run: —*

Baseline its byte size before the run and read only the tail. Upstream raised a
`RemoteScriptError` on every clip-slot operation, so a traceback during
`write_midi_notes`, `delete_clip`, `duplicate_clip` or `get_clip_slots` means an
old AbletonOSC is still installed.
(`~/Library/Preferences/Ableton/Live <version>/Log.txt`.)

## A rejected query fails fast, and says rejected

*Run mode: agent*
*Last run: —*

The reinstall-and-restart precondition at the top of this file applies — the
structured `/live/error` payload exists only in the fork commit this test
guards. Call a tool that queries an upstream indexed getter with a track index
far past the set — `get_track_devices` on track 99 — and time the reply. It
must come back in milliseconds, not seconds (its queries otherwise wait out
the 5-second default query timeout), and read as a rejection
("Ableton rejected" in the message), not as the guard-timeout wording ("Timed
out checking…"). Then repeat with `get_clip_notes` on track 99 with a
fractional `from_time` of 0.1 — that query carries float arguments 32-bit OSC
cannot represent exactly, so a fast rejection here is the end-to-end proof
that the error's echoed float tail still matches the request after the
round-trip.

A timeout instead of a rejection means the structured error never arrived or
never matched. Check Live's `Log.txt` for the per-address
"Error handling OSC message /live/…" line (Python raised and caught it), then
the Seshat server's `OSC in: /live/error` debug line (the payload reached
Elixir): the first missing means a stale install, the second missing means the
send, the payload shape, or the Transport matcher.

## One rejection, one error datagram

*Run mode: agent*
*Last run: —*

While provoking the rejection above, the Seshat server's debug log shows
exactly **one** `OSC in: /live/error` for it, with a `"request"`-tagged
payload. A second copy tagged `"log"` for the same rejection means the relay
is not skipping marked records — harmless to correlation, since a `"log"`
payload is never matched, but a duplicate per error. The marker *mechanism*
(`extra` reaching a sibling handler's `record` inside Live's embedded Python)
was measured working on 2026-08-03, so a failure here points at the marker
check in `manager.py`'s relay, not at Live's logging and not at the matcher.

## Only the offender fails

*Run mode: agent*
*Last run: —*

Issue the bad-index call and a valid read of the same kind
(`get_track_devices` on a track that exists) **in one model response**, so the
two queries sit adjacent in Transport's FIFO. The bad one is rejected fast;
the valid one succeeds with correct data. The valid call failing with the
rejection message means the matcher correlates too loosely (address without
arguments); both calls timing out means the queue never advanced after the
error.

## The listener rebind, by hand in Live's UI

*Run mode: user — requires deleting and renaming tracks in Live's UI*
*Last run: —*

Delete a track, then rename a *different* one, then `get_session_state`. Every
name must be under the right index.

This guards the fork's fix to `AbletonOSCHandler._stop_listen`, which unbound a
listener from the wrong object once an index had been reused. It is the one fix
whose failure is completely silent — every address still answers — so nothing but
this test finds it. Do it by hand: a tool-driven substitute exercises the same
LOM mutation but proves nothing about UI-originated edits.
