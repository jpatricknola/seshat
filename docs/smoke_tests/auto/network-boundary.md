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

*Last run: 2026-08-03 — passed. `lsof -nP -iUDP:11000` returned exactly one
line, `Live … UDP 127.0.0.1:11000`. No wildcard bind.*

`lsof -nP -iUDP:11000`. The only AbletonOSC line must read `127.0.0.1:11000`;
`*:11000` or `0.0.0.0:11000` is exactly the regression this exists to close.

## The obsolete path-taking export form is rejected

*Last run: 2026-08-03 — passed. The file was never created, and `Log.txt` past
the baseline offset carried exactly one line: `ERROR:abletonosc:777 - Browser:
export takes no arguments (got 1) — this handler chooses the destination.
Nothing was written. Re-run mix abletonosc.install and restart Live.` No
traceback.*

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

*Last run: 2026-08-03 — passed. `~/.seshat/browser-exports/` did not exist and
was created for the run. With `seshat-browser-export-STALE.json` backdated 70
minutes (`touch -A -011000`) and `…-FRESH.json` at now, `reindex_library`
succeeded (5,796 items, 5,760 tagged, 174 tags); afterwards the directory held
`…-FRESH.json` alone — the stale fixture gone and reindex's own export cleaned
up. Fresh fixture removed by hand afterwards, leaving the directory empty.*

Before running `reindex_library`, plant two files in `~/.seshat/browser-exports/`
matching `seshat-browser-export-*.json`: one with a modification time more than
ten minutes old (backdate it — `touch -A` / `os.utime`), one fresh. Reindex must
succeed, remove the stale fixture, leave the fresh one alone, and clean up only
the export it just created (`Catalog.consume_export/3`'s `after` block deletes
nothing but the path Python replied with, and only once it has validated it).

Remove the fresh fixture by hand once you've confirmed it survived — nothing in
this system will ever do that for you.

