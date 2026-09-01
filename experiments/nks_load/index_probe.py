#!/usr/bin/env python3
"""Ask Live's own browser database what it made of a synthesized preset file.

Spike tooling for the NKS load path (docs/PLAN_nks_load_path.md). Development
only, standard library only, never imported by `lib/`, read-only on every file
it touches.

This is the fast oracle the spike found on 2026-09-01, and it replaces the
plan's write → `reindex_library` → create track → `load_device` → read-back
loop (a minute of frozen Live UI per attempt, and a mutated set) with a write
→ wait → SELECT loop that takes seconds and touches nothing:

    python3 experiments/nks_load/write_adv.py <nksf> --out "<User Library>/X.adv"
    python3 experiments/nks_load/index_probe.py --wait "X.adv"

Live's browser index lives at
`~/Library/Application Support/Ableton/Live Database/Live-files-<n>.db`, and
its `files` table carries, per file, the identity Live's metadata extractor
derived: `device_id` (e.g. `device:ableton:instr:UltraAnalog`,
`device:vst3:instr:<guid>`), plus `device_type` and `device_arch`. Measured on
this machine: **every** real `.adv`/`.adg` carries a non-empty `device_id`, and
a file with an empty one is one whose device Live did not recognise — which is
exactly what `browser.load_item` then silently declines to instantiate.

Live's indexer picks up a User Library write on its own, within a few seconds
(it is driven by OS file events and logs each scan to `Indexer.txt` beside
Live's `Log.txt`), so no `reindex_library` is needed to get an answer here —
that is only needed to make the file's *uri* resolvable for a real load.

The database is opened read-only through a temporary copy of the db/-wal/-shm
trio, because Live holds it open in WAL mode and an uncommitted extraction
would otherwise be invisible.
"""
import argparse
import glob
import os
import shutil
import sqlite3
import sys
import tempfile
import time

DB_GLOB = os.path.expanduser(
    "~/Library/Application Support/Ableton/Live Database/Live-files-*.db")
INDEXER_LOG_GLOB = os.path.expanduser(
    "~/Library/Preferences/Ableton/Live */Indexer.txt")


def locate_db():
    candidates = sorted(glob.glob(DB_GLOB))
    if not candidates:
        raise SystemExit("no Live browser database under %s" % DB_GLOB)
    return candidates[-1]


def snapshot(db):
    """Copy db + -wal + -shm somewhere private and open the copy read-only."""
    directory = tempfile.mkdtemp(prefix="nks-index-probe-")
    base = os.path.join(directory, os.path.basename(db))
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(db + suffix):
            shutil.copy(db + suffix, base + suffix)
    return sqlite3.connect(base), directory


def rows_for(connection, patterns):
    where = " OR ".join(["name LIKE ?"] * len(patterns))
    return list(connection.execute(
        "SELECT name, device_id, device_type, device_arch, file_size "
        "FROM files WHERE %s ORDER BY name" % where, patterns))


def indexer_exceptions(since):
    """Lines from Live's indexer log that report a failed extraction."""
    logs = sorted(glob.glob(INDEXER_LOG_GLOB))
    if not logs:
        return []
    with open(logs[-1], "rb") as f:
        f.seek(max(0, since))
        tail = f.read().decode("utf-8", "replace")
    return [line for line in tail.splitlines()
            if "Exception while extracting" in line]


def indexer_size():
    logs = sorted(glob.glob(INDEXER_LOG_GLOB))
    return os.path.getsize(logs[-1]) if logs else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pattern", nargs="+",
                        help="SQL LIKE pattern(s) on the file name, e.g. 'Agonic%%'")
    parser.add_argument("--wait", action="store_true",
                        help="poll until every match has a non-empty device_id, "
                             "or --timeout seconds pass")
    parser.add_argument("--timeout", type=int, default=30, metavar="SECONDS",
                        help="how long --wait polls for (default 30)")
    opts = parser.parse_args(argv)

    db = locate_db()
    log_mark = indexer_size()
    deadline = time.time() + (opts.timeout if opts.wait else 0)
    while True:
        connection, directory = snapshot(db)
        try:
            rows = rows_for(connection, opts.pattern)
        finally:
            connection.close()
            shutil.rmtree(directory, ignore_errors=True)
        settled = rows and all(row[1] for row in rows)
        if settled or time.time() >= deadline:
            break
        time.sleep(2)

    if not rows:
        print("no rows matching %s in %s" % (opts.pattern, os.path.basename(db)))
        return 1
    width = max(len(row[0]) for row in rows)
    for name, device_id, device_type, device_arch, size in rows:
        print("%-*s  %-46s type=%-2s arch=%-2s %8d bytes"
              % (width, name, device_id or "<unrecognised>", device_type,
                 device_arch, size))
    failures = indexer_exceptions(log_mark)
    for line in failures:
        print("indexer: %s" % line.strip())
    unrecognised = [row[0] for row in rows if not row[1]]
    if unrecognised:
        print("\n%d file(s) carry no device identity — Live's browser lists them "
              "but load_item has nothing to instantiate, which is the silent "
              "no-op: %s" % (len(unrecognised), ", ".join(unrecognised)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
