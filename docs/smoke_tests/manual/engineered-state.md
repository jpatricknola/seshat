# Needs an engineered state

These check what happens when something is *wrong* — Ableton not answering, a
rebuild raced mid-flight, an empty undo history, a stale Remote Scripts copy, a
stopped server, an input routed nowhere. None of those states occur during
ordinary use, and none can be created by a tool call, which is what keeps this
file out of the agent sweep.

Two rules carry more weight here than anywhere else in the suite:

- **A run that never reached the state is not a pass.** Several of these are
  races and may take repeated attempts. A burst that never degraded tested
  nothing; say so rather than ticking it. This is the single easiest place in the
  whole suite to record coverage that doesn't exist.
- **Never manufacture the state destructively.** The stale-install check in
  particular must not be met by downgrading and restarting Live. If the state
  isn't reachable, the honest result is *not reproduced*, with the reason.

**The mirror tests run as one sitting, in order.** Provoking a degraded rebuild
comes first; the recovery check and the brake check both observe what follows it
and cannot be run on their own.

Most of these read the server log (`log/dev.log`, see
[../auto/mirror.md](../auto/mirror.md)) as well as the session — baseline its
byte size before you start and read only the tail.

## A stale install is distinguishable from a broken tool

*Why manual: only reachable against a stale Remote Scripts copy, which the agent sweep must never create and skips fork-dependent tests when it finds*
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

## Nothing is fabricated when Ableton stops answering

*Why manual: requires quitting or disabling Ableton and starting it again*
*Last run: —*

With the Seshat server running, quit Ableton Live (or toggle AbletonOSC off in
Live's MIDI preferences). Steps 1 and 2 are timing-coupled — read both before
starting.

1. `get_session_state` with `refresh: true` → the timeout error from
   `maybe_refresh/1`. The GenServer is still refreshing when that error arrives:
   against a dead Ableton `do_refresh/1` takes roughly 47s (eight song queries at
   5s each, the 5s `num_tracks` probe, the 2s returns probe) while the caller
   gives up at 30s, so about 17s of it remain.
2. **Read again inside those ~17s**, plain, no refresh → "The session mirror did
   not answer — it may be mid-refresh against an unresponsive Ableton. Try again
   shortly". This is the only live exercise of that message, and it must never
   read as an empty session. Miss the window and the call simply succeeds; retry
   from 1 rather than counting that as a pass.
3. **Wait ≥10s, read again**, plain → tempo, time signature, key, playing state,
   groove and swing all reported unknown; the track list reported
   unknown-**not**-empty; the trailing explanation sentence present exactly once.
   **It must not say 120 BPM, 4/4, C Major, or list the previous set's tracks.**
   Those four fabrications are what this behaviour exists to remove, and any of
   them appearing is the whole test failing.
4. **Still with Live closed**, `record_clip bars: 4` → the
   time-signature-unknown error naming `refresh: true`, not an `ArithmeticError`
   from a `nil` numerator and not a generic timeout.
5. **Start Live again.** `/live/startup` fires a refresh on its own; wait, then
   read plain → real values, no unknown remnants, no trailing sentence. Listener
   re-subscription pushes the current value of everything, so anything a lost
   datagram nil'd repopulates without a manual refresh.

## An unchanged library stays fresh across a Live restart

*Why manual: requires quitting and restarting Live while ensuring no Pack, plugin or preset is installed or saved*
*Last run: —*

Build the catalog with `reindex_library`, then run one ordinary
`search_library` and confirm it carries no catalog-freshness notice. Record the
mtimes of `catalog.json`, the selected `Live-files-*.db`, and its `-wal` sibling.

Without installing a Pack or plugin, saving a preset, or otherwise changing the
browser library, quit Live normally and start it again. Wait for Live and its
browser indexer to settle, then run the same `search_library` again. It must not
warn that the catalog is stale. Record the three mtimes again.

A stale warning after this content-neutral restart is a failure: ordinary
SQLite checkpoint/startup activity is touching the signal, so comparing mtimes
cannot distinguish a library change and must not ship as an automatic prompt.
If an actual library change occurred during the window, report the run as not
provoked rather than passed.

## A degraded rebuild is honest

*Why manual: requires comparison against Live's visible track headers*
*Last run: —*

Needs Live **running**. Ask for several tracks to be created and then removed
**in one model response** — creates and deletes in the same instruction, so they
land inside one debounce window and race the rebuild. Then read state once,
plainly. Either the list is correct, or it reports the track list unknown — **it
must never name a track that is not in Live's UI**. Compare the reply against
Live's own track headers by eye; that comparison is the check.

The race is timing-dependent and may take several attempts to provoke; a run that
never degrades is **not a pass**, it is a run that did not test this.

The log signature of a degraded rebuild is a `Song: …` line followed by
`the read stopped at index …`, with **no `Loaded N tracks` line between them**:
`Song:` is emitted before every rebuild's `num_tracks` probe, while `Loaded …`
and the stopped-index warning are the two arms of one `case` and can never both
describe the same rebuild. Healthy `Loaded …` lines from neighbouring rebuilds in
the same burst are expected — don't read one as contradicting the degraded read.

## A degraded rebuild recovers without `refresh: true`

*Why manual: depends on first provoking and visually confirming a degraded rebuild*
*Last run: —*

After a degraded read, make no further tool call, wait ~3s, then read plainly
again: the list is correct. This is the single retry doing what the narrowed
`refresh: true` no longer lets the model do for itself.

If a structure push was still pending when the rebuild ran, the log shows it as a
second `Song:` / `Loaded …` sequence following the informational `could not read
the track list — retrying once` line, and **exactly one** such retry; if nothing
was pending, recovery instead comes from the re-subscription echo (`Track list
changed in Live — scheduling a session refresh`) and that line never appears.
Either way, the check is the list being correct on the follow-up read.

## A genuine disagreement still brakes

*Why manual: can only be observed while running the user-required degraded-rebuild scenario*
*Last run: —*

Not reproducible on demand and not required to pass — but if a `did not reproduce
it` warning appears in the log during any of the above, confirm it is followed by
no further refresh for that list. The brake is what stops the flood, and the
failed/disagreed split must not have loosened it for the disagreed case.

## The default reply route is fixed, not last-sender

*Why manual: requires stopping and restarting the Seshat server*
*Last run: —*

`manager.py`'s `test_callback` replies with a bare `self.osc_server.send(...)`
rather than a tuple through `process_message`, so `/live/test` is the one call
that exercises the removed last-sender rewrite directly — everything else only
proves the per-message reply path still works. No tool sends it, and the reply
goes to the fixed 11001 that a running Seshat already owns, so **stop Seshat for
the length of this check** (`[Errno 48] Address already in use` on the bind means
you didn't):

```bash
python3 -c '
import socket, sys; sys.path.insert(0, "priv/AbletonOSC")
from pythonosc.udp_client import SimpleUDPClient
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 11001)); s.settimeout(5)
SimpleUDPClient("127.0.0.1", 11000).send_message("/live/test", [])
print(s.recvfrom(1024))
'
```

Expect a datagram carrying `/live/test` and `ok`. Live also flashes "Received OSC
OK" in its status bar — that only proves the callback *ran*, so it is not a
substitute for receiving the reply. A timeout is the failure this exists to
catch, and nothing else here would catch it. If stopping Seshat isn't practical,
the listener push below travels the same `osc_server.send` default route — record
that you substituted it rather than reporting this as run.

## The Elixir listener and decoder accept real traffic

*Why manual: requires a manual rename and Live restart*
*Last run: —*

`@socket_opts` binds the reply port loopback-only, `handle_info/2` accepts a
datagram only from `127.0.0.1:<send_port>`, and `Message.decode/1` logs and drops
anything it can't parse rather than crashing the transport. All pure-tested
(`message_test.exs`, `transport_test.exs`), none of it against real AbletonOSC
traffic.

Run a normal session pass — `get_session_state(refresh: true)`, a large
`search_library` reply, `get_clip_slots` on a track with several clips (the
`N`-tag path), a track rename by hand, and a Live restart (`/live/startup`) —
then read **Seshat's own Elixir log**, not Ableton's `Log.txt`. Expect **zero**
occurrences of `Dropped OSC datagram from unexpected source` and
`Dropped malformed OSC datagram`. Either firing during ordinary use means the
source check or the strict decoder is rejecting a legitimate reply shape; the log
line carries the reason and a byte preview, which is what would need loosening.

## Each guard produces its own error with nothing fired

*Why manual: includes a group track and input-routing state no tool can create*
*Last run: —*

An occupied slot (names `delete_clip`), a group track (`can_be_armed` false), and
an armable track whose `will_record_on_start` stays false (unroute its input —
needs a routing no tool can create).

## `can_undo=False` is reachable at an empty history

*Why manual: requires creating a new Live Set with a keyboard shortcut*
*Last run: — ⚠️ unmeasured*

File → New Live Set (hold Command and press N), touch nothing, then call `undo`.
Expect the error — "Live reported no undo step available, so no undo was sent" —
and **not** a success string.

This is the one reading the 2026-08-02 probe could not reach without discarding
the open set. What *was* measured about both properties — plain `bool` attributes,
not hardwired true, tracking availability independently in both directions — is in
[../../../priv/AbletonOSC/API.md](../../../priv/AbletonOSC/API.md#song-getters), and the redo
guard stands on it either way. If `undo` reports the request as sent instead,
`can_undo` alone is always true, and the finding is that the **undo guard should
be dropped rather than widened**; say so in the report, and fold the reading into
the API docs.

## An audio clip's audio-only properties still read

*Why manual: needs an audio clip in a Session slot, which no tool can create —
recording one needs routed input hardware, so it takes a person dragging a
sample into a slot*
*Last run: —*

The audio arm of `get_clip_properties` — `gain`, `gain_display_string`,
`warp_mode`, `warping` — is a second batched read that only ever runs against
an audio clip, so the agent sweep's MIDI-clip test
([../auto/clips.md](../auto/clips.md) § Clip properties read in one breath,
and read true) never exercises it.

Drag any sample from Live's browser into a Session slot. `get_clip_properties`
on that slot must report it as an audio clip, include a gain with its dB
display string and a warp mode matching what the clip's own view shows, and
omit nothing the MIDI arm would have shown (name, length, loop settings).
Then read a MIDI clip and confirm the audio-only fields are absent rather
than zeroed.

A timeout here with MIDI clips reading fine means the audio batch is sending
a property an audio clip doesn't carry (or vice versa — the
`@clip_audio_only_properties` guard drifting from Live's reality).

## An open Settings window survives an audio-output read

*Why manual: requires opening Settings by hand to a chosen page — a state no
tool can create — and eyes on the window afterwards*
*Last run: —*

Open Live's Settings by hand and select a non-Audio page (Display & Input,
say). Call `get_audio_outputs` once. The reply must carry the same devices and
current value as the Settings-closed read
([../auto/audio-output.md](../auto/audio-output.md) § The available outputs
and current selection agree with Live), and afterwards Settings must still be
open with your chosen page selected again — the helper may visit the Audio
page mid-read, but it must put back the page it found and must not close a
window it did not open.

Settings closed afterwards means the helper cannot tell a window it opened
from one it found already open. Settings left on the Audio page means the
selected-page restore step was skipped.

## A blocked Settings window still gives focus back

*Why manual: requires Live showing a modal dialog when the call is made — a
state no tool can create and no automated test can reach without a live Live*
*Last run: —*

PR review (2026-08-27) found that `native/seshat_ax/main.m`'s
`AudioOutputTransaction` used to `return` early, skipping its own cleanup
block, on the one path where Live's Settings window never opens at all — and
that early return never restored the frontmost application. Fixed in the same
round by routing that path through the shared cleanup instead (see
`kCleanupBudget` and the comment above the `settings == NULL` branch), but
nothing in `mix test` can drive real AX against a real modal, so this is the
live check that closes the loop.

Provoke a modal in Live that blocks the `Settings...` menu item — closing the
last open Live Set with unsaved changes is a reliable one — and, with a
non-Live application frontmost, call `get_audio_outputs` (or `set_audio_output`
with any device name) while the dialog is still up. The call must fail —
`settings_unavailable`, or `timeout` if the three retries run out the clock
first — and the application that was frontmost before the call must be
frontmost again afterwards. Live's dialog is allowed to have come to the front
while the helper tried the menu; the helper must not leave it there.

Live (or its dialog) left frontmost after the call means the fix regressed:
the early exit on a Settings window that never opened is skipping the shared
restore again. Dismiss the dialog before running anything else against Live.

The same round also fixed a narrower defect only reachable by an actual
timeout mid-selection — a switched Settings page failing to restore because
the restore search itself respected the already-expired action deadline
(`kCleanupBudget` is the fix). That path needs Live to genuinely miss its
window while under load and isn't reliably reproducible by hand; there is no
check for it here beyond the mechanism reasoning above and the compile-time
proof that `kCleanupBudget` extends `gDeadline` before any restore search
runs.

## A groove from the pool lands on a clip, and an empty pool is told plainly

*Why manual: the Groove Pool can only be stocked by a person — no LOM member
adds a groove and the browser has no grooves root (measured 2026-08-30), so
the state this check needs cannot be created by any tool*
*Last run: —*

With the pool **empty** (a fresh set): `get_session_state` says the pool is
empty rather than omitting the subject, and `set_clip_properties` with a
`groove` index on any MIDI clip refuses immediately, saying plainly that the
pool has no grooves and that one must be dragged in from Live's browser — not
a bare index error.

Then drag one groove (e.g. Core Library's `Swing 16ths 66`) into the Groove
Pool by hand. `get_session_state` now names it. Assign it:
`set_clip_properties` with `groove: 0` on a MIDI clip, verified through
`get_clip_properties` reading the index back (the setter is fire-and-forget;
the read-back is the check). An out-of-range index (`groove: 5`) errors
immediately, naming the pool's real size, and the clip's read-back is
unchanged. Note the one-way contract: the tool cannot un-assign a groove —
confirm the reply says so if un-assignment is attempted, rather than
pretending to clear it.
