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
*Last run: 2026-08-03 — passed. `get_session_state` printed `Return 0 "A-Smoke
Return" (send A): volume=0.85, pan=0.0` and the master line with pan and cue
volume; no "Return/master state unavailable".*

`get_session_state` prints return tracks and master volume when `return_track.py`
is loaded, and a single "Return/master state unavailable" line when it isn't. A
whole feature reading as broken usually means a skipped `mix abletonosc.install`
and Live restart — check this before diagnosing anything else.

## A bad index errors immediately, not after ~2s

*Run mode: agent*
*Last run: 2026-08-03 — passed at all three depths, every reply naming the real
count, all ≤0.20s (whole `mcp_call.py` round trip, Python startup included):
`get_track_devices` return 99 → "this set has 1 return track(s)";
`set_device_parameter`/`bypass_device` device 99 on a valid return → "the chain
holds 1 device(s)"; `get_device_parameters` device 5 on the master → "the chain
holds 0 device(s)". The historical `-1` parameter echo is gone —
`set_device_parameter` parameter 999 replied "there is no parameter 999 —
'Reverb' has 33 parameter(s)", echoing the value actually asked for.*

These handlers always reply, including on an out-of-range index, and the reply
names the real count. A ~2s timeout instead means the installed copy is stale.
That distinction is the entire point of the reply envelope, and it is the
cheapest stale-install detector there is.

Try it at every depth, not just the track: a bad *device* index on
`set_device_parameter` or `bypass_device` against a valid return must error the
same way — that case once came back as a false "try again" timeout because the
parameter index was echoed as `-1` instead of the value actually asked for.

## A stale install is distinguishable from a broken tool

*Run mode: user — only reachable against a stale Remote Scripts copy, which the agent sweep must never create and skips fork-dependent tests when it finds*
*Last run: —*

*Retagged 2026-08-03: this was marked `agent` and can never pass in a sweep.
Either the install matches the repo and the state is unreachable, or it differs
and the sweep is required to skip fork-dependent tests. Its natural window is
mid-implementation, before `mix abletonosc.install` — cite it from a plan's
`## Live verification`, not from the sweep.*

Before reinstalling during implementation — or against an older Remote Scripts
copy — every vendored tool must fail with the `mix abletonosc.install` hint
rather than a bare timeout or a regular-track error message. If the new copy is
already installed, report this as **not reproduced**; never downgrade and restart
Live just to manufacture it. A raw `Transport.query` is not a substitute: it
bypasses the handler wording this test exists to verify.

## Live's `Log.txt` stays clean during ordinary work

*Run mode: agent*
*Last run: 2026-08-03 — passed. Create track, write notes, get_clip_slots,
duplicate_clip, ranged get_clip_notes, delete_clip ×2, delete_track produced
zero tracebacks and zero ERROR lines past the baseline offset.*

Baseline its byte size before the run and read only the tail. Upstream raised a
`RemoteScriptError` on every clip-slot operation, so a traceback during
`write_midi_notes`, `delete_clip`, `duplicate_clip` or `get_clip_slots` means an
old AbletonOSC is still installed.
(`~/Library/Preferences/Ableton/Live <version>/Log.txt`.)

## A rejected query fails fast, and says rejected

*Run mode: agent*
*Last run: 2026-08-03 — passed. `get_track_devices` track 99 answered in 212ms
(whole `mcp_call.py` round trip, Python startup and HTTP handshake included)
with "Ableton rejected the request: Index out of range". The float-tail step
was found unreachable and removed — see below.*

The reinstall-and-restart precondition at the top of this file applies — the
structured `/live/error` payload exists only in the fork commit this test
guards. Call a tool that queries an upstream indexed getter with a track index
far past the set — `get_track_devices` on track 99 — and time the reply. It
must come back in milliseconds, not seconds (its queries otherwise wait out
the 5-second default query timeout), and read as a rejection
("Ableton rejected" in the message), not as the guard-timeout wording ("Timed
out checking…").

**The matcher's float tail cannot be provoked from the tool surface, and this
test no longer asks you to try.** It once said to repeat with `get_clip_notes`
on track 99 and a fractional `start_time`, on the reasoning that
`/live/clip/get/notes` carries floats 32-bit OSC cannot represent exactly. It
does — but `get_clip_notes` gates on `ensure_clip` and then `ensure_midi_clip`
first, and both probe with integers only, so a bad index is always rejected
*before* the ranged query goes out (measured 2026-08-03: Live's log named
`/live/clip_slot/get/has_clip` as the raising address, not
`/live/clip/get/notes`). With valid indices Live does not raise, and the one
case that would raise on a valid index — a notes read of an *audio* clip — is
refused by `ensure_midi_clip` before it reaches the wire. Running the old step
tests the integer path a second time while reading as float coverage, which is
worse than not running it. The 32-bit round-trip is covered by the pure
`transport_test.exs` cases; reinstate a live step here only if a float-carrying
query ever becomes reachable with an index Live rejects.

A timeout instead of a rejection means the structured error never arrived or
never matched. Check Live's `Log.txt` for the per-address
"Error handling OSC message /live/…" line (Python raised and caught it), then
the Seshat server's `OSC in: /live/error` debug line (the payload reached
Elixir): the first missing means a stale install, the second missing means the
send, the payload shape, or the Transport matcher.

## One rejection, one error datagram

*Run mode: user — the count of `OSC in: /live/error` lines is only visible in the Seshat server's debug log, which goes to the server's own terminal*
*Last run: 2026-08-03 — passed. One rejection produced exactly one
`OSC in: /live/error ["request", "/live/track/get/devices/name",
"Index out of range", 1, 99]` and no `"log"`-tagged copy.*

*Retagged 2026-08-03: it was marked `agent` while its own stamp conceded an
agent "must ask" for the tty. Same reason as the log-read tests in
[mirror.md](mirror.md).*

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
*Last run: 2026-08-03 — passed. `get_track_devices` 99 and 0 issued in one
model response: the first rejected fast, the second returned track 0's real
(empty) chain, so the FIFO advanced immediately and the matcher did not
correlate on address alone.*

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
