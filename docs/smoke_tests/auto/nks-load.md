# NKS load path

The Spike L mechanism: a `.adv` synthesized from an NKS preset's plugin state
chunk landing through `reindex_library` → `load_device`
([../../PLAN_nks_load_path.md](../../PLAN_nks_load_path.md) while the spike is
open; the archived plan after). The synthesized files come from
`experiments/nks_load/write_adv.py`; nothing under `lib/` is involved.

**Machine gate:** the synthesized-preset checks need Massive X (VST3)
installed locally with its factory presets
(`/Library/Application Support/Native Instruments/Massive X/Presets/`). On a
machine without it, run only the first check and record the others as skipped
for that reason — a skip is not a pass.

⚠️ **Never wrap the synthesized `<PluginDevice>` inside a rack `.adg`.**
Measured 2026-09-01: substituting it for the native device inside a real Core
Library Instrument Rack produced a file Live indexed happily and then
**segfaulted on** (`EXC_BAD_ACCESS` in `AEditableDeviceChain`, crash report
`~/Library/Logs/DiagnosticReports/Live-2026-09-01-133424.ips`), taking the
session down and leaving Live parked on a crash-recovery modal that only a
person can dismiss. The finding is worth having — it is the only evidence that
Live's deserializer reads this XML at all — but it is recorded here so nobody
pays for it twice.

**Method, for every check here.** Two oracles, cheap one first:

1. **Browser-index oracle** (`experiments/nks_load/index_probe.py`) — Live's
   own browser database records the device identity its metadata extractor
   derived from each file. A synthesized preset with an **empty `device_id`**
   is one Live's browser will list and `load_item` will silently decline to
   instantiate, so this answers "is it even a candidate?" in seconds, with no
   `reindex_library`, no track and no mutation. Live's indexer notices a User
   Library write on its own within a few seconds (`Indexer.txt` beside Live's
   `Log.txt` logs each scan, and logs `Exception while extracting metadata
   from file "…"` for a file that fails to parse at all). Caveat: the probe
   marks `Indexer.txt`'s size at its own startup, which is necessarily after
   `write_adv.py` has already run — a very fast extraction could log its
   exception before the probe starts watching. None was observed across the
   eleven variants below, but that absence is weaker evidence than "no
   exception in the whole run"; start tailing `Indexer.txt` before writing
   the file if that distinction ever matters.
2. **Load oracle** — only worth running once the first says the file has a
   device identity. Baseline the byte size of Live's log
   (`~/Library/Preferences/Ableton/Live <version>/Log.txt`) before each load
   and read only the tail past it. Load onto a **freshly created, empty** MIDI
   track, and judge only by `get_track_devices` read-back — the plan records
   the measured reason: a rejected `.adv` is a silent no-op whose
   `load_device` reply still reads as success (and, on an occupied track,
   names the pre-existing device as if it had just landed).

`reindex_library` is still needed before a load, but only to make the new
file's *uri* resolvable — Live's browser caches a folder's children, so a
freshly written file is invisible to `list_browser_items` until the next walk.
Rewriting an existing file's bytes keeps its uri.

## A foreign-written `.adv` is indexed and loadable without a Live restart

Copy any Core Library instrument-preset `.adv` (e.g. Analog's "Thick Chord
Pad") under a probe name into
`~/Music/Ableton/User Library/Presets/Instruments/<probe folder>/`, run
`reindex_library`, and confirm the probe appears in the catalog under a
`query:UserLibrary#Presets:…` uri. Create an empty MIDI track, `load_device`
with that uri, and confirm via `get_track_devices` that exactly one device
landed, named after the probe file. Clean up: delete the track, remove the
file and its folder, `reindex_library` again — a lingering `FileId_…` row for
the deleted file may survive one rebuild (measured 2026-09-01); that is
Live's browser db lagging, not a failed cleanup, so judge cleanup by the
UserLibrary row being gone.

*Last run: 2026-09-01 — passed (run during `/plan`; the measurement this
check pins). Indexed with no restart, loaded as device 0 named after the
probe, chain read back correctly. Re-affirmed the same day on the index
oracle: a byte-copy, a Python gunzip/re-gzip round trip, and a 254-byte
root-element-only skeleton of the same preset all indexed as
`device:ableton:instr:UltraAnalog` with five metadata rows each — so
Python-written gzip XML is not the obstacle for anything below.*

## A synthesized plugin `.adv` carries a device identity Live recognises

The gate every load check below stands on, and the cheapest one to run.
Generate the Agonic Drone `.adv` (`write_adv.py`, plan-appendix template) into
a User Library folder and run
`python3 experiments/nks_load/index_probe.py --wait "<file name>"`. Pass
requires a **non-empty `device_id`** for the file — for a Massive X VST3
instrument that is exactly
`device:vst3:instr:5653544e-6924-486d-6173-736976652078`, the spelling Live's
own plugin registry uses (`Live-plugins-1.db`, table `plugins`). An empty
`device_id` with `device_type=0, arch=0` is the failure: Live parsed the file
without throwing and declined to give it a device identity, which is the
mechanism behind the silent no-op. Clean up by removing the files.

*Last run: 2026-09-01 — **failed**, on eleven variants: the plan's
fixture-faithful attempt D; `--no-source-context`; `--processor-state skip`;
`--stored-all-parameters false`; `--minor-version 11.0_11300`;
`--device-role audiofx`; skeletons carrying only the `SourceContext`
`BranchDeviceId`, only the `PluginDesc/Vst3PluginInfo`, and both; the same
with a real `Creator`/`Revision` pair copied out of a Live-written file; and
one written uncompressed. All eleven: `device_id` empty, `device_type=0`,
`device_arch=0`, zero rows in the browser db's `metadata` table and no
`file_devices` link, with no `Indexer.txt` extraction exception. The
`BranchDeviceId` string itself was verified byte-identical to the plugin
registry's, so the class id is not the defect.*

*This is the recorded state, not a regression to chase — it flips only once
§ "What would settle it" (the Spike L result in
[semantic-sound-selection-options.md](../../evaluating/semantic-sound-selection-options.md))
is done: a Live-written plugin `.adv` diffed against the template. A full
`/smoke-test` sweep will report this check as failing every time until then;
that is expected.*

## A synthesized NKS `.adv` lands Massive X carrying the preset's state

Only reachable once the check above passes. Generate the Agonic Drone `.adv`
into a User Library folder, `reindex_library` once, create an empty MIDI
track, load by the UserLibrary uri, and allow up to ~15s of polling
`get_track_devices`. Pass requires **all three**: (1) the log tail gained
`VST3: Going to create: Massive X` (and its `plugin processor successfully
loaded … cid: {5653544E-6924-486D-6173-736976652078}` line); (2) the chain
read-back shows exactly one instrument device of a plugin-device class; (3)
the state fingerprint: write a 1-bar held-note MIDI clip, fire it, poll
`output_meter_level` ~10 times over ~4s, and compare the same measurement
taken on a bare-init Massive X
(`query:Plugins#VST3:Native%20Instruments:Massive%20X`) loaded the same way
— the envelopes must differ grossly (Agonic Drone is a slow drone; init is a
plain saw). A device that lands with a matching-shape fingerprint is
reported as "instantiated, state unconfirmed", not as a pass — whether it
*sounds* like the preset is the by-ear check
([../manual/by-ear.md](../manual/by-ear.md) § A synthesized NKS preset
sounds like its own preview). Clean up as in the first check, and stop any
playing clip.

*Last run: — (not reached; the identity check above has never passed. The
two log lines it looks for were captured on 2026-09-01 from a bare
`query:Plugins#VST3:…Massive%20X` load, so the phrasing is verified against
real Live 12.4.5 output even though the synthesized path has never produced
them.)*

## A rejected `.adv` leaves the chain empty and its reply must not be trusted

Generate a deliberately wrong-framed variant (`write_adv.py
--no-source-context` — a shape measured to no-op on 2026-09-01) under a
fresh name, reindex, load it onto an empty MIDI track. Pass requires: the
`load_device` reply *claims* a load (this is the trap being pinned — record
the wording), the chain reads back **empty** after ~5s, the log tail gained
**no** plugin-instantiation line, and no dialog opened in Live. This is the
control that keeps the previous check's read-back honest; if this variant
ever starts genuinely loading, the framing knowledge has changed — update
the plan's variant list rather than deleting the check. Clean up as above.

*Last run: 2026-09-01 — passed, on the plan's attempt D (the strongest
variant, so the control holds a fortiori for the weaker ones). Reply:
`Loaded 'Agonic D.adv' onto track 1 (still instantiating, so it has no device
index yet)`; `get_track_devices` on the freshly created empty track read back
`No devices on track 1` eight seconds later; the log tail past the baseline
contained no `VST3:` line at all; no dialog appeared.*
