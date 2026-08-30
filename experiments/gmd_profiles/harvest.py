#!/usr/bin/env python3
"""Harvest per-style drum feel statistics from the Groove MIDI Dataset.

Development-only. Nothing in `lib/` runs this, imports it, or reads the
dataset: the *output* — `priv/midi_generation/style_profiles.json` — is
committed, and that file is the only thing Seshat ever loads. Re-run this
script when the profiles need rebuilding, then commit the JSON it writes.

    python3 experiments/gmd_profiles/harvest.py [--zip PATH] [--out PATH]

Standard library only, deliberately: a committed dev script that needs
`pip install mido` is a script nobody re-runs. The MIDI reader below handles
exactly what GMD ships (format-0/1 files, note-on/note-off, no SMPTE
timebase), and raises rather than guessing on anything else.

The dataset (Gillick et al., "Learning to Groove with Inverse Sequence
Transformations", ICML 2019) is CC-BY 4.0. It is *not* vendored: only derived
statistics are, with attribution in the JSON header and in
priv/midi_generation/ATTRIBUTION.md.
"""

import argparse
import csv
import hashlib
import io
import json
import math
import statistics
import struct
import sys
import urllib.request
import zipfile
from collections import defaultdict
from datetime import datetime, timezone

DATASET_URL = (
    "https://storage.googleapis.com/magentadata/datasets/groove/"
    "groove-v1.0.0-midionly.zip"
)

# Measured 2026-08-30 on the file this script was written against. A mismatch
# is reported and the harvest continues — the dataset is versioned in its URL,
# so a changed hash means the mirror changed, which is worth seeing rather than
# worth failing on.
DATASET_SHA256 = "651cbc524ffb891be1a3e46d89dc82a1cecb09a57c748c7b45b844c4841dcc1e"

# Roland TD-11 pitches, as documented with the dataset. Everything GMD records
# comes from this kit, so an unmapped pitch is a real surprise and is counted
# rather than silently dropped.
LANE_BY_PITCH = {
    36: "kick",
    38: "snare",
    40: "snare",
    37: "snare",
    48: "tom",
    50: "tom",
    45: "tom",
    47: "tom",
    43: "tom",
    58: "tom",
    46: "open_hat",
    26: "open_hat",
    42: "closed_hat",
    22: "closed_hat",
    44: "closed_hat",
    49: "crash",
    55: "crash",
    57: "crash",
    52: "crash",
    51: "ride",
    59: "ride",
    53: "ride",
}

LANES = ["kick", "snare", "closed_hat", "open_hat", "tom", "ride", "crash"]

# Styles harvested from GMD's own labels. Anything else in the dataset (soul,
# afrobeat, …) is pooled into the all-styles fallback but not published as a
# profile: the tool's `style` enum is what these have to line up with.
HARVESTED_STYLES = ["rock", "funk", "jazz", "latin", "hiphop", "dance"]

# Below this many contributing files a lane's statistics are noise, so the
# pooled all-styles figure stands in and the substitution is recorded in the
# JSON. Open question 3 in the plan doc: 30 hiphop and 7 dance files are thin,
# and this is the answer that does not need re-planning.
MIN_FILES_PER_LANE = 8

# Authored profiles: styles GMD carries no label for at all. Each names its
# donor and the deltas applied, so nothing here can be mistaken for a
# measurement. `timing` shifts the donor's mean lane offsets (in fractions of a
# 16th), `timing_sd` and `velocity_sd` scale the donor's spreads, `swing`
# replaces the donor's swing outright when present.
AUTHORED = {
    "lofi": {
        "from": "hiphop",
        "note": "hiphop, dragged further behind the grid and looser, with fewer ghosts",
        "timing": 0.06,
        "timing_sd": 1.35,
        "velocity_sd": 1.1,
        "ghost_probability": 0.75,
    },
    "boom_bap": {
        "from": "hiphop",
        "note": "hiphop, tighter and harder-hitting",
        "timing": 0.0,
        "timing_sd": 0.7,
        "velocity_sd": 1.0,
        "ghost_probability": 1.0,
    },
    "house": {
        "from": "dance",
        "note": "dance, straight 16ths and tighter still",
        "timing": 0.0,
        "timing_sd": 0.5,
        "velocity_sd": 0.85,
        "ghost_probability": 0.9,
        "swing": 0.0,
    },
    "techno": {
        "from": "dance",
        "note": "dance, machine-tight and straight",
        "timing": 0.0,
        "timing_sd": 0.3,
        "velocity_sd": 0.7,
        "ghost_probability": 0.8,
        "swing": 0.0,
    },
    "trap": {
        "from": "dance",
        "note": "dance timing with a half-time accent contour",
        "timing": 0.0,
        "timing_sd": 0.6,
        "velocity_sd": 0.95,
        "ghost_probability": 1.0,
        "swing": 0.0,
    },
}


# --- A very small MIDI reader ------------------------------------------------


def read_varlen(data, i):
    value = 0
    while True:
        byte = data[i]
        i += 1
        value = (value << 7) | (byte & 0x7F)
        if not byte & 0x80:
            return value, i


def parse_midi(data):
    """Returns (ticks_per_quarter, [(tick, pitch, velocity), ...]) for note-ons."""
    if data[:4] != b"MThd":
        raise ValueError("not a MIDI file")
    (header_len,) = struct.unpack(">I", data[4:8])
    fmt, ntracks, division = struct.unpack(">HHH", data[8:14])
    if fmt not in (0, 1):
        raise ValueError("unsupported MIDI format %d" % fmt)
    if division & 0x8000:
        raise ValueError("SMPTE timebase is not supported")

    notes = []
    i = 8 + header_len
    for _ in range(ntracks):
        if data[i : i + 4] != b"MTrk":
            raise ValueError("expected MTrk")
        (length,) = struct.unpack(">I", data[i + 4 : i + 8])
        i += 8
        end = i + length
        tick = 0
        status = None
        while i < end:
            delta, i = read_varlen(data, i)
            tick += delta
            byte = data[i]
            if byte & 0x80:
                status = byte
                i += 1
            if status == 0xFF:
                _kind = data[i]
                i += 1
                length_meta, i = read_varlen(data, i)
                i += length_meta
                continue
            if status in (0xF0, 0xF7):
                length_sysex, i = read_varlen(data, i)
                i += length_sysex
                continue
            high = status & 0xF0
            if high in (0x80, 0x90, 0xA0, 0xB0, 0xE0):
                a, b = data[i], data[i + 1]
                i += 2
                if high == 0x90 and b > 0:
                    notes.append((tick, a, b))
            elif high in (0xC0, 0xD0):
                i += 1
            else:
                raise ValueError("unexpected status byte 0x%02X" % status)
        i = end

    return division, notes


# --- Statistics --------------------------------------------------------------


def mean(values):
    return statistics.fmean(values) if values else 0.0


def sd(values):
    return statistics.pstdev(values) if len(values) > 1 else 0.0


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return float(ordered[low])
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def round_to(value, digits=4):
    return round(float(value), digits)


class LaneAccumulator:
    def __init__(self):
        self.offsets = []
        self.velocities = []
        self.by_class = {"accent": [], "hit": [], "ghost": []}
        self.ghosts = 0
        self.hits = 0
        self.files = set()
        self.density = []


def harvest(zip_path):
    archive = zipfile.ZipFile(zip_path)
    info_name = next(n for n in archive.namelist() if n.endswith("info.csv"))
    rows = list(csv.DictReader(io.StringIO(archive.read(info_name).decode())))
    prefix = info_name[: -len("info.csv")]

    lanes = defaultdict(lambda: defaultdict(LaneAccumulator))
    swing_offsets = defaultdict(list)
    style_files = defaultdict(int)
    unmapped = defaultdict(int)
    skipped = 0

    for row in rows:
        if row["beat_type"] != "beat" or row["time_signature"] != "4-4":
            continue
        bpm = float(row["bpm"])
        # Four bars of 4/4 is 16 beats.
        if float(row["duration"]) < 16 * 60 / bpm:
            continue
        style = row["style"].split("/")[0]

        try:
            division, notes = parse_midi(archive.read(prefix + row["midi_filename"]))
        except (KeyError, ValueError) as error:
            skipped += 1
            print("  skipped %s: %s" % (row["midi_filename"], error), file=sys.stderr)
            continue
        if not notes:
            continue

        beats = [(tick / division, pitch, velocity) for tick, pitch, velocity in notes]
        span_bars = max(1.0, (max(b for b, _, _ in beats) + 1.0) / 4.0)

        velocities = sorted(v for _, _, v in beats)
        low = velocities[len(velocities) // 3]
        high = velocities[2 * len(velocities) // 3]

        file_id = row["midi_filename"]
        style_files[style] += 1
        per_lane_hits = defaultdict(int)

        for beat, pitch, velocity in beats:
            lane = LANE_BY_PITCH.get(pitch)
            if lane is None:
                unmapped[pitch] += 1
                continue

            sixteenth = round(beat * 4)
            # As a signed fraction of a 16th: +0.5 is halfway to the next one.
            offset = (beat * 4) - sixteenth
            accumulator = lanes[style][lane]
            accumulator.offsets.append(offset)
            accumulator.velocities.append(velocity)
            accumulator.files.add(file_id)
            accumulator.hits += 1
            per_lane_hits[lane] += 1

            if velocity <= low:
                accumulator.by_class["ghost"].append(velocity)
                accumulator.ghosts += 1
            elif velocity >= high:
                accumulator.by_class["accent"].append(velocity)
            else:
                accumulator.by_class["hit"].append(velocity)

            # Swing is read off the off-8ths — the "and" of each beat, which is
            # every second 16th — and nowhere else.
            if sixteenth % 4 == 2:
                swing_offsets[style].append(offset)

        for lane, count in per_lane_hits.items():
            lanes[style][lane].density.append(count / span_bars)

    return lanes, swing_offsets, style_files, unmapped, skipped


def pooled(lanes, lane_name):
    """One lane's statistics across every style, for the small-sample fallback."""
    merged = LaneAccumulator()
    for style_lanes in lanes.values():
        accumulator = style_lanes.get(lane_name)
        if not accumulator:
            continue
        merged.offsets += accumulator.offsets
        merged.velocities += accumulator.velocities
        for name, values in accumulator.by_class.items():
            merged.by_class[name] += values
        merged.ghosts += accumulator.ghosts
        merged.hits += accumulator.hits
        merged.files |= accumulator.files
        merged.density += accumulator.density
    return merged


def lane_profile(accumulator, baseline=0.0):
    classes = {}
    for name, values in accumulator.by_class.items():
        if values:
            classes[name] = {"mean": round_to(mean(values), 1), "sd": round_to(sd(values), 1)}
        else:
            classes[name] = None

    # A class with no examples borrows the neighbouring one rather than
    # inventing a number: an accent is never quieter than an ordinary hit.
    ordinary = classes["hit"] or classes["accent"] or classes["ghost"] or {"mean": 90.0, "sd": 12.0}
    classes["hit"] = classes["hit"] or ordinary
    classes["accent"] = classes["accent"] or {
        "mean": min(127.0, ordinary["mean"] + 20),
        "sd": ordinary["sd"],
    }
    classes["ghost"] = classes["ghost"] or {
        "mean": max(1.0, ordinary["mean"] - 45),
        "sd": ordinary["sd"],
    }

    return {
        "files": len(accumulator.files),
        "hits": accumulator.hits,
        # `baseline` is the same recording-chain estimate `style_profile`
        # subtracts for `swing` below — every offset in this dataset skews
        # early by a few percent of a 16th, uniformly across lanes, which is a
        # property of GMD's capture chain rather than of any drummer. Left in,
        # every generated note would carry a silent, undocumented rush; this
        # is what makes a lane's timing_mean "how this lane sits *relative to
        # the style's own average onset*" rather than relative to a grid that
        # was never actually measured directly.
        "timing_mean": round_to(mean(accumulator.offsets) - baseline),
        "timing_sd": round_to(sd(accumulator.offsets)),
        "velocity_sd": round_to(sd(accumulator.velocities), 1),
        "velocity": classes,
        "ghost_probability": round_to(
            0.55 + 0.4 * (1 - accumulator.ghosts / max(1, accumulator.hits)), 3
        ),
        "ghost_fraction": round_to(accumulator.ghosts / max(1, accumulator.hits), 3),
        "density": {
            "p10": round_to(percentile(accumulator.density, 0.10), 2),
            "p50": round_to(percentile(accumulator.density, 0.50), 2),
            "p90": round_to(percentile(accumulator.density, 0.90), 2),
        },
    }


def style_profile(lanes, swing_offsets, style, style_files):
    # The same recording-chain estimate backs both `swing` (below) and every
    # lane's `timing_mean` (in `lane_profile`): every offset in this dataset
    # skews slightly early, uniformly across lanes, which is a property of
    # GMD's capture chain rather than of any drummer. A lane whose own file
    # count fell back to the cross-style pool is corrected against the pooled
    # baseline instead, for the same reason `pooled()` supplies it a pooled
    # accumulator in the first place.
    own_baseline = mean([o for a in lanes[style].values() for o in a.offsets])
    pooled_baseline = mean(
        [o for style_lanes in lanes.values() for a in style_lanes.values() for o in a.offsets]
    )

    fallbacks = []
    lane_profiles = {}
    for lane_name in LANES:
        accumulator = lanes[style].get(lane_name) or LaneAccumulator()
        if len(accumulator.files) < MIN_FILES_PER_LANE:
            fallbacks.append(lane_name)
            accumulator = pooled(lanes, lane_name)
            baseline = pooled_baseline
        else:
            baseline = own_baseline
        lane_profiles[lane_name] = lane_profile(accumulator, baseline)

    # Swing rides the same small-sample rule as the lanes: a median taken over a
    # handful of files is a property of those drummers, not of the style.
    #
    # And it is measured *relative to the style's own mean onset offset*, not
    # against the bare grid — the same `own_baseline`/`pooled_baseline` above,
    # which is what leaves swing meaning "the off-beats sit later than the
    # on-beats" rather than carrying the same capture-chain rush timing_mean
    # now also corrects for.
    #
    # Its resolution is a real limit worth knowing: onsets are matched to the
    # nearest 16th, so a hard triplet swing pushes the off-8th past the halfway
    # point and is read as the *next* 16th rather than as a large offset. Jazz
    # therefore harvests a small number here, and a caller who wants a triplet
    # feel passes `swing` explicitly.
    swing_fallback = style_files.get(style, 0) < MIN_FILES_PER_LANE
    if swing_fallback:
        offsets = [o for values in swing_offsets.values() for o in values]
        baseline = pooled_baseline
    else:
        offsets = swing_offsets[style]
        baseline = own_baseline

    swing = round_to((statistics.median(offsets) if offsets else 0.0) - baseline)

    return {
        "harvested": True,
        "swing": swing,
        "swing_pooled": swing_fallback,
        "fallback_lanes": fallbacks,
        "lanes": lane_profiles,
    }


def authored_profile(donor, recipe):
    lane_profiles = {}
    for lane_name, lane in donor["lanes"].items():
        velocity = {
            name: {"mean": values["mean"], "sd": round_to(values["sd"] * recipe["velocity_sd"], 1)}
            for name, values in lane["velocity"].items()
        }
        lane_profiles[lane_name] = dict(
            lane,
            timing_mean=round_to(lane["timing_mean"] + recipe["timing"]),
            timing_sd=round_to(lane["timing_sd"] * recipe["timing_sd"]),
            velocity_sd=round_to(lane["velocity_sd"] * recipe["velocity_sd"], 1),
            velocity=velocity,
            ghost_probability=round_to(
                lane["ghost_probability"] * recipe["ghost_probability"], 3
            ),
        )

    return {
        "harvested": False,
        "authored_from": recipe["from"],
        "authored_note": recipe["note"],
        "swing": recipe.get("swing", donor["swing"]),
        "swing_pooled": donor["swing_pooled"] and "swing" not in recipe,
        "fallback_lanes": donor["fallback_lanes"],
        "lanes": lane_profiles,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", default="groove-v1.0.0-midionly.zip")
    parser.add_argument("--out", default="priv/midi_generation/style_profiles.json")
    args = parser.parse_args()

    try:
        with open(args.zip, "rb") as handle:
            payload = handle.read()
    except FileNotFoundError:
        print("downloading %s" % DATASET_URL, file=sys.stderr)
        payload = urllib.request.urlopen(DATASET_URL, timeout=300).read()
        with open(args.zip, "wb") as handle:
            handle.write(payload)

    digest = hashlib.sha256(payload).hexdigest()
    if digest != DATASET_SHA256:
        print("WARNING: dataset sha256 is %s, expected %s" % (digest, DATASET_SHA256))

    lanes, swing_offsets, style_files, unmapped, skipped = harvest(args.zip)

    print("files per style: %s" % dict(sorted(style_files.items())))
    if unmapped:
        print("unmapped pitches: %s" % dict(sorted(unmapped.items())))
    if skipped:
        print("skipped %d unreadable file(s)" % skipped)

    styles = {}
    for style in HARVESTED_STYLES:
        styles[style] = style_profile(lanes, swing_offsets, style, style_files)
        styles[style]["files"] = style_files.get(style, 0)

    for name, recipe in AUTHORED.items():
        styles[name] = authored_profile(styles[recipe["from"]], recipe)

    document = {
        "attribution": {
            "dataset": "Groove MIDI Dataset (GMD) v1.0.0",
            "citation": (
                "Jon Gillick, Adam Roberts, Jesse Engel, Douglas Eck, David Bamman. "
                "'Learning to Groove with Inverse Sequence Transformations.' "
                "International Conference on Machine Learning (ICML), 2019."
            ),
            "licence": "CC-BY 4.0 (https://creativecommons.org/licenses/by/4.0/)",
            "url": DATASET_URL,
            "sha256": DATASET_SHA256,
            "note": (
                "Derived statistics only. No dataset file is redistributed, and nothing "
                "in Seshat reads the dataset at run time."
            ),
        },
        "generated_by": "experiments/gmd_profiles/harvest.py",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "units": {
            "timing_mean": (
                "signed mean onset offset relative to the style's own average onset (which "
                "removes GMD's capture-chain rush), as a fraction of a 16th note"
            ),
            "timing_sd": "onset offset standard deviation, same units",
            "swing": "median off-8th offset, same units",
            "velocity": "MIDI velocity, 1-127, per accent class",
            "ghost_probability": "Live per-note probability applied to ghost hits",
            "density": "hits per bar for this lane (p10/p50/p90 across source files)",
        },
        "min_files_per_lane": MIN_FILES_PER_LANE,
        "styles": styles,
    }

    with open(args.out, "w") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")

    print("wrote %s" % args.out)


if __name__ == "__main__":
    main()
