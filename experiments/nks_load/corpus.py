#!/usr/bin/env python3
"""Pick a spike corpus of NKS presets that are actually present on this disk.

Spike tooling for the NKS load path (docs/PLAN_nks_load_path.md). Development
only, standard library only, never imported by `lib/`, read-only on every file
it touches — the same posture as lib/seshat/library/ableton_db.ex has toward
Ableton's own browser database.

    python3 experiments/nks_load/corpus.py --product "Massive X" --limit 5
    python3 experiments/nks_load/corpus.py --product "Massive X" --tsv

Native Instruments keeps a per-product SQLite at
`~/Library/Application Support/Native Instruments/<Product>/komplete.db3`,
whose `v_sound_info` view carries name / author / brand / product / bank /
type / character / comment / file_name. Two traps this script exists to
absorb, both measured 2026-08-31:

  * **The DB spells filenames with underscores where the disk has spaces**
    (`Init_-_Massive_X.nksf` vs `Init - Massive X.nksf`), so every row needs
    normalisation plus an existence check before it can be called corpus.
  * **Most of Collector's Edition lives on an unmounted volume**, so a large
    majority of rows resolve to nothing on this machine and must be dropped
    rather than emitted as phantom corpus.

Preview audio, where it exists, is `<dir>/.previews/<preset filename>.ogg`;
the spike's by-ear acceptance listens to exactly that file.
"""
import argparse
import csv
import json
import os
import sqlite3
import sys

NI_ROOT = os.path.expanduser("~/Library/Application Support/Native Instruments")


def db_path(product):
    return os.path.join(NI_ROOT, product, "komplete.db3")


def resolve_file(recorded):
    """The on-disk path for a DB `file_name`, or None if nothing is there.

    Tries the recorded path first, then the same path with underscores in the
    basename turned back into spaces. Never guesses beyond those two.
    """
    if not recorded:
        return None
    candidates = [recorded]
    directory, base = os.path.split(recorded)
    if "_" in base:
        candidates.append(os.path.join(directory, base.replace("_", " ")))
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    return None


def preview_for(path):
    directory, base = os.path.split(path)
    candidate = os.path.join(directory, ".previews", base + ".ogg")
    return candidate if os.path.isfile(candidate) else None


def rows(product, extension):
    path = db_path(product)
    if not os.path.isfile(path):
        print("no database for %r at %s — skipping" % (product, path),
              file=sys.stderr)
        return []
    connection = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        cursor = connection.execute(
            "SELECT name, author, brand, product, bank, type, character, "
            "comment, file_name FROM v_sound_info WHERE file_ext = ? "
            "ORDER BY name", (extension,))
        columns = [d[0] for d in cursor.description]
        return [dict(zip(columns, row)) for row in cursor]
    finally:
        connection.close()


def build(product, extension, require_preview, must_include):
    total = 0
    present = []
    for row in rows(product, extension):
        total += 1
        path = resolve_file(row["file_name"])
        if not path:
            continue
        row["path"] = path
        row["preview"] = preview_for(path)
        if require_preview and not row["preview"]:
            continue
        present.append(row)
    # Named presets first, so a slate always contains the ones the plan and
    # the smoke tests refer to by name, then the rest in DB order.
    wanted = [name.lower() for name in must_include]
    present.sort(key=lambda r: (wanted.index(r["name"].lower())
                                if r["name"].lower() in wanted else len(wanted)))
    return total, present


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--product", default="Massive X")
    parser.add_argument("--ext", default="nksf", help="file_ext to select")
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument("--any-preview", action="store_true",
                        help="keep rows without a preview .ogg too")
    parser.add_argument("--include", action="append", default=["Agonic Drone"],
                        help="preset names to sort to the front of the slate")
    parser.add_argument("--tsv", action="store_true",
                        help="tab-separated rows instead of JSON")
    opts = parser.parse_args(argv)

    total, present = build(opts.product, opts.ext, not opts.any_preview,
                           opts.include)
    slate = present[:opts.limit] if opts.limit > 0 else present
    print("%s: %d rows in the database, %d present on this disk%s, %d emitted"
          % (opts.product, total, len(present),
             " with a preview" if not opts.any_preview else "", len(slate)),
          file=sys.stderr)
    if not slate:
        return 1
    if opts.tsv:
        writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
        writer.writerow(["name", "type", "character", "path", "preview"])
        for row in slate:
            writer.writerow([row["name"], row["type"], row["character"],
                             row["path"], row["preview"] or ""])
    else:
        json.dump(slate, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
