# OSC network boundary

The command socket binds `127.0.0.1:11000` only, and `process()` does not
retarget its default reply destination to the last sender. Upstream's defaults
are reasonable for driving Live from a phone on the LAN and wrong here — every
OSC address controls Live and nothing on the wire authenticates. `browser.py`'s
`/live/browser/export` likewise chooses its own file under
`~/.seshat/browser-exports/` instead of opening a caller-supplied path with
Live's privileges.

All of it lives in the fork, so [bridge.md](bridge.md)'s reinstall precondition
applies before anything below means anything.

## The bind is loopback-only

*Run mode: agent*
*Last run: —*

`lsof -nP -iUDP:11000`. The only AbletonOSC line must read `127.0.0.1:11000`;
`*:11000` or `0.0.0.0:11000` is exactly the regression this exists to close.

## The default reply route is fixed, not last-sender

*Run mode: user — requires stopping and restarting the Seshat server*
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

## Callback replies and listener pushes both land on 11001

*Run mode: user — requires changing a control by hand in Live*
*Last run: —*

`get_session_state(refresh: true)`, then change tempo or a track's volume **by
hand in Live**, then `get_session_state` again and confirm it sees the change.
The first call is a direct reply; the second depends on a listener push reaching
the fixed `127.0.0.1:11001` with no incoming datagram to retarget it — both are
exactly what moved.

## The obsolete path-taking export form is rejected

*Run mode: agent*
*Last run: —*

`/live/browser/export` takes no argument. Send the old form with

```bash
python3 .claude/skills/smoke-test/scripts/osc_send.py \
  /live/browser/export /tmp/seshat-should-not-exist.json
```

and confirm the file was never created and `Log.txt` shows `browser.py`'s clean
"export takes no arguments" line rather than a traceback. The reply goes to the
fixed response port, never to the sending client, so the log line is the only
observable outcome — by design, since nothing else confirms the obsolete form was
*rejected* rather than ignored.

## Stale-export cleanup, with real fixtures

*Run mode: agent*
*Last run: —*

Before running `reindex_library`, plant two files in `~/.seshat/browser-exports/`
matching `seshat-browser-export-*.json`: one with a modification time more than
ten minutes old (backdate it — `touch -A` / `os.utime`), one fresh. Reindex must
succeed, remove the stale fixture, leave the fresh one alone, and clean up only
the export it just created (`Catalog.consume_export/3`'s `after` block deletes
nothing but the path Python replied with, and only once it has validated it).

Remove the fresh fixture by hand once you've confirmed it survived — nothing in
this system will ever do that for you.

## The Elixir listener and decoder accept real traffic

*Run mode: user — requires a manual rename and Live restart*
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
