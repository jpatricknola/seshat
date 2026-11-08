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

*Last run: 2026-11-08 — passed. `lsof -nP -iUDP:11000` returned exactly one line, `Live … UDP 127.0.0.1:11000`. Live 12.4.6, fork 9bd8095.*

`lsof -nP -iUDP:11000`. The only AbletonOSC line must read `127.0.0.1:11000`;
`*:11000` or `0.0.0.0:11000` is exactly the regression this exists to close.

## The obsolete path-taking export form is rejected

*Last run: 2026-11-08 — passed. The file was never created; Log.txt past the baseline carried exactly one line, `Python: ERROR:abletonosc:711 - Browser: export takes no arguments (got 1) — this handler chooses the destination. Nothing was written. …`, no traceback.*

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

*Last run: 2026-11-08 — passed. `~/.seshat/browser-exports/` was empty; with STALE backdated 70 minutes and FRESH at now, reindex_library succeeded in 0.75s (5,798 items, 5,760 tagged, 178 tags) and the directory afterwards held FRESH alone. Fresh fixture removed by hand.*

Before running `reindex_library`, plant two files in `~/.seshat/browser-exports/`
matching `seshat-browser-export-*.json`: one with a modification time more than
ten minutes old (backdate it — `touch -A` / `os.utime`), one fresh. Reindex must
succeed, remove the stale fixture, leave the fresh one alone, and clean up only
the export it just created (`Catalog.consume_export/3`'s `after` block deletes
nothing but the path Python replied with, and only once it has validated it).

Remove the fresh fixture by hand once you've confirmed it survived — nothing in
this system will ever do that for you.

