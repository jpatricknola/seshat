# Bridge integrity

`/live/browser/*`, `/live/return_track/*` and `/live/master/*` are Seshat's own,
served by the fork at [priv/AbletonOSC/](../../priv/AbletonOSC/). `mix test`
greps the submodule in the repo; Live runs the copy in Remote Scripts. Nothing
else in this project can tell you those two agree.

**Change-verification precondition for every test in this file, and for anything
else that touches `priv/AbletonOSC`:** run `mix abletonosc.install` and **restart
Live** (or toggle AbletonOSC off and on under Preferences > Link/Tempo/MIDI —
`/live/api/reload` does not pick these up). Without it every result anywhere is
right for the wrong reason. `/smoke-test` never installs or restarts
anything; it compares the installed copy with the repo and skips fork-dependent
tests when they differ, so the reinstall belongs to whoever drives the change.

## The extension is answering at all

*Last run: 2026-08-05 (second run of the day, against the merged bridge) —
passed. `get_session_state` printed `Return 0 "A-Smoke Return" (send A):
volume=0.85, pan=0.0` and `Master (shown as Main in Live 12): volume=0.85,
pan=0.0, cue volume=0.7`; no "Return/master state unavailable". With no returns in the set it prints "No return tracks in this
set" instead, which is also a pass — that line still requires
`/live/return_track/get/count` to have answered.*

`get_session_state` prints return tracks and master volume when `return_track.py`
is loaded, and a single "Return/master state unavailable" line when it isn't. A
whole feature reading as broken usually means a skipped `mix abletonosc.install`
and Live restart — check this before diagnosing anything else.

## A bad index errors immediately, not after ~2s

*Last run: 2026-08-05 (second run of the day, against the merged bridge) —
passed at all three depths, every reply naming the real count, all ≤0.27s
(whole `mcp_call.py` round trip, Python startup included): `get_track_devices`
return 99 → "this set has 1 return track(s)" (266ms); `set_device_parameter`
device 99 on a valid return → "the chain holds 1 device(s)" (245ms);
`bypass_device` device 99 likewise (243ms); `get_device_parameters` device 5 on
the master → "the chain holds 0 device(s)" (249ms). The historical `-1`
parameter echo is still gone — `set_device_parameter` parameter 999 replied
"there is no parameter 999 — 'Reverb' has 33 parameter(s)" (258ms), echoing the
value actually asked for.*

These handlers always reply, including on an out-of-range index, and the reply
names the real count. A ~2s timeout instead means the installed copy is stale.
That distinction is the entire point of the reply envelope, and it is the
cheapest stale-install detector there is.

Try it at every depth, not just the track: a bad *device* index on
`set_device_parameter` or `bypass_device` against a valid return must error the
same way — that case once came back as a false "try again" timeout because the
parameter index was echoed as `-1` instead of the value actually asked for.

## Live's `Log.txt` stays clean during ordinary work

*Last run: 2026-08-05 (second run of the day, against the merged bridge) —
passed as scoped below, after the first version of this check failed on it. The
clip operations were clean. `delete_track` was followed by 7 `IndexError`s on
track index 1 — `/live/track/get/mute`, `get/solo` and the five
`start_listen/*` — all correlated `["request", …]`, all resolved inside 210ms,
after which the mirror's degraded-rebuild brake logged that it was refusing to
merge a half-read list. Expected, and now explicitly scoped out; see below. The
same create-then-delete in isolation produced zero ERROR lines across two
consecutive attempts, so provoking it needs the full sequence.*

Baseline its byte size before the run and read only the tail. Upstream raised a
`RemoteScriptError` on every clip-slot operation, so a traceback during
`write_midi_notes`, `delete_clip`, `duplicate_clip` or `get_clip_slots` means an
old AbletonOSC is still installed.
(`~/Library/Preferences/Ableton/Live <version>/Log.txt`.)

**What must be clean is the clip work, not the whole tail.** Deleting a track
can leave `Seshat.Session.State`'s debounced rebuild reading an index Live has
already renumbered away, and each of those reads raises `IndexError` inside
Live and is logged with its traceback. That is the documented degraded-rebuild
path, not a bridge fault, and it is **timing-dependent** — it did not reproduce
on a bare create-then-delete, so a run without it is not evidence of anything.
Accept those only on `/live/track/get/*` and `/live/track/start_listen/*`
carrying an index that has just been deleted, and only when both hold:

- every one arrives **correlated** (`["request", …]`, not `["log", …]`), and
- the whole burst resolves in well under a second, not N × the 5s query timeout.

A `["log", …]` copy, an address outside those two families, or a burst that
takes seconds is a real finding. Anything at all during the clip operations is
a real finding. This scoping was added 2026-08-05 after the blunt "zero ERROR
lines" version failed on the rebuild race; it must not be widened further
without a reason written down here, because the upstream `RemoteScriptError`
regression it exists to catch shows up in exactly this file.

## A rejected query fails fast, and says rejected

*Last run: 2026-08-05 (second run of the day, against the merged bridge) —
passed. The wording criterion was corrected as stale earlier the same day (see
below). `get_track_devices` track 99 answered in 198ms
(whole `mcp_call.py` round trip, Python startup and HTTP handshake included)
with "Index out of range. Nothing further was sent — check get_session_state
for the indices that actually exist." The float-tail step was found unreachable
on 2026-08-03 and removed — see below.*

The reinstall-and-restart precondition at the top of this file applies — the
structured `/live/error` payload exists only in the fork commit this test
guards. Call a tool that queries an upstream indexed getter with a track index
far past the set — `get_track_devices` on track 99 — and time the reply. It
must come back in **milliseconds, not seconds** (its queries otherwise wait out
the 5-second default query timeout), and it must read as a *rejection*: Live's
own reason ("Index out of range") in the message, and **not** the guard-timeout
wording ("Timed out checking…"). The timing and the timeout wording are the
load-bearing halves; either one alone can be faked by the other's absence.

**Do not assert the "Ableton rejected the request:" prefix.** This test used to,
and the batched-reads work of 2026-08-04 falsified it without breaking anything:
`get_track_devices` now reads through `Transport.query_batch/2`, whose per-entry
error path renders through `Handlers.remote_error/1` (Live's message plus "check
get_session_state for the indices that actually exist") rather than through
`Transport.describe_error/1`, which is what produces the "Ableton rejected the
request:" prefix and still does on the unbatched paths. Both are rejections and
both are correct; a test that pins one renderer fails the day a read is batched,
which is a refactor this codebase is actively doing.

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

*Last run: 2026-08-05 (second run of the day, against the merged bridge) —
passed, confirmed by reading the log rather than asking for it; the "exactly
one" count was corrected as stale earlier the same day (see below). One
`get_track_devices` on track 99 produced exactly **three** `"request"`-tagged
datagrams past the baseline offset — one per entry of its batch, on
`/live/track/get/devices/name`, `/live/track/get/devices/type` and
`/live/track/get/devices/class_name`, each carrying `"Index out of range", 1,
99` — and **zero** `"log"`-tagged copies. This is the first live confirmation
of the per-entry `/live/error` correlation shipped 2026-08-04, which until now
had never touched a real wire.*

*This is readable because `config :seshat, :logger` mirrors the dev log to
`log/dev.log` — see [mirror.md](mirror.md)'s preamble. Baseline its byte size
first and read only the tail, exactly as with Live's own `Log.txt` above.*

While provoking the rejection above, the Seshat server's debug log shows one
`"request"`-tagged `OSC in: /live/error` **per OSC request that raised**, and
**zero** `"log"`-tagged copies. Count requests, not tool calls: a tool reading
through `Transport.query_batch/2` sends N getters in one tick, each raises
independently in Live, and N structured errors is correct — `get_track_devices`
on a bad index produces three, one per address in its batch. What a failure
looks like is a `"log"`-tagged copy *alongside* a `"request"` one for the same
raise, which means the relay is not skipping marked records — harmless to
correlation, since a `"log"` payload is never matched, but a duplicate per
error.

(This test asked for "exactly one" until 2026-08-05. That was written when
every read was serial, and the batched-reads work of 2026-08-04 made it wrong
without making anything fail — the duplicate-suppression property it exists to
guard is per-raise, not per-tool-call.)

The marker *mechanism*
(`extra` reaching a sibling handler's `record` inside Live's embedded Python)
was measured working on 2026-08-03, so a failure here points at the marker
check in `manager.py`'s relay, not at Live's logging and not at the matcher.

## Only the offender fails

*Last run: 2026-08-05 (second run of the day, against the merged bridge) —
passed. `get_track_devices` 99 and 0, fired concurrently, landed 99ms apart on
the wire (15:42:00.926 → 15:42:01.025) — one AbletonOSC tick, so the error
batch really did resolve and release the FIFO for the next one. An earlier run
the same day needed a second attempt after issuing them too far apart to
provoke anything; see the adjacency warning below. The bad call was rejected fast, the valid one
returned track 0's real (empty) chain. Both batches queried the **same three
addresses** with different arguments, which is the strongest form of this
check: correlating on address alone would have failed the valid call.*

Issue the bad-index call and a valid read of the same kind
(`get_track_devices` on a track that exists) so the two queries sit adjacent in
Transport's FIFO. The bad one is rejected fast; the valid one succeeds with
correct data. The valid call failing with the rejection message means the
matcher correlates too loosely (address without arguments); both calls timing
out means the queue never advanced after the error.

**Adjacency is the whole test, and it is easy to miss silently.** Issuing the
two as separate `mcp_call.py` invocations in one model response is *not* enough
— each pays its own HTTP handshake, and a 2026-08-05 run measured them landing
**2 seconds apart**, far enough that the queue had long since drained and the
run proved nothing while looking green. Fire them concurrently (background both
and `wait`), then **confirm from the wire log** that the two batches are within
a few hundred milliseconds of each other before recording a pass. If they are
seconds apart, the condition was not provoked — rerun rather than tick it.

