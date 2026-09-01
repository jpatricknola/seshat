# PLAN: NKS load path — prove a Collector's Edition preset can land on a track (Spike L)

**Roadmap item:** #1 — the go/no-go gate for the semantic sound-selection arc
([evaluating/semantic-sound-selection-options.md](evaluating/semantic-sound-selection-options.md)).
**Shape:** a spike, not a feature. No new tool, no `Definitions` change, no
fork Python, no process door, nothing under `lib/`. The deliverable is a
measured verdict recorded in the options doc, plus the parser/writer scripts
that produced it and the smoke tests that make it repeatable.

## Context

Retrieval over the NKS corpus can already *name* a preset ("Massive X /
Agonic Drone") — but Live's browser holds **zero** NKS preset entries
(measured: dev catalog, 5,796 entries, NI products appear only as bare plugin
devices), so nothing Seshat has can *load* one. Every strategy in the
semantic-selection brief chains through this one question: can a `.nksf`
preset's raw plugin state chunk (`PCHK`) be wrapped as a Live `.adv` device
preset that `reindex_library` → `load_device` lands on a track, carrying that
preset's sound? Success puts the whole Collector's Edition corpus in play;
failure of every fallback shrinks NKS to metadata enrichment of sounds Live
already loads. Either outcome sizes the largest open feature area, which is
why this sits at #1 despite plumbing-grade impact.

Planning ran a large part of the spike against live Ableton on 2026-09-01
(Live 12.4.5, this machine). **The mechanism chain is proven end to end for a
foreign-written `.adv`; what is still unproven is only the plugin-device XML
framing** — and a real Live-written reference for exactly that framing was
recovered from a public `.als` fixture. The implementer starts at "load
attempt D", not at zero. Everything below reflects those measurements.

## What planning measured (2026-09-01, Live 12.4.5, this machine)

Each of these was observed directly; none is inference. The session was
restored afterwards (probe tracks deleted, probe files removed, catalog
reindexed; the installed Remote Scripts copy was never modified).

- **M1 — the chain works for a foreign-written `.adv`.** A Core Library
  `.adv` (UltraAnalog preset) copied by a script into
  `~/Music/Ableton/User Library/Presets/Instruments/<Folder>/<Name>.adv` was
  seen by the *running* Live's browser with **no restart**, indexed by
  `reindex_library` (two rows: a `query:Synths#Analog:FileId_NNNN` merged row
  and a `query:UserLibrary#Presets:Instruments:<Folder>:<Name>.adv` row), and
  `load_device` with the UserLibrary URI landed it on a track — device named
  after the preset, correct class.
- **M2 — iteration is cheap after first placement.** A freshly written file's
  UserLibrary URI resolves only after the next browser walk
  (`reindex_library`, up to a minute, freezes Live's UI) — but **rewriting the
  bytes of an existing file keeps its URI**, so the write→load→read-back loop
  runs in seconds per attempt with no reindex. (One caveat: content freshness
  across rewrites is not separately proven — see Open question 6.)
- **M3 — a rejected `.adv` is a silent no-op, and the load reply lies.** Three
  wrong-framing plugin `.adv` variants all produced: no modal, no crash, no
  `Log.txt` line, no `/live/error`, no device. With an instrument already on
  the target track, `load_device` replied `Loaded 'Massive X'` — **naming the
  pre-existing device as if it had just landed**. On an *empty* track the
  reply was `Loaded 'X.adv' … (still instantiating, so it has no device index
  yet)` with the chain still empty seconds later. The only honest oracle is a
  `get_track_devices` read-back on a known-empty scratch track.
- **M4 — Live's `.adv` deserializer is lenient about missing elements.** A
  hand-stripped 263-byte skeleton (`<Ableton …><UltraAnalog><LomId/IsExpanded/
  On>` only) **loads fine**. So the plugin attempts are not failing on strict
  schema validation; something specific to plugin-device recognition is
  missing. That, plus the fixture in M7, is what attempt D fixes.
- **M5 — the parameter-diff oracle is dead on Massive X.** The VST3 exposes
  exactly one host parameter to Live (`Device On`); the AU exposes two
  (`Device On`, `Macro 16`). Live's log shows the VST3's internal count is
  2,568, but none are host-visible by default. State verification must come
  from `Log.txt` instantiation lines, an output-meter fingerprint, and ears
  (see Part 4).
- **M6 — the `.nksf` is fully parsed.** RIFF container, magic `RIFF…NIKS`;
  chunks measured on `Agonic Drone.nksf`: `NISI` (300 B msgpack metadata —
  bankchain, author, `modes` = Character tags, `deviceType: INST`), `NICA`
  (896 B, controller assignments), `PLID` (99 B msgpack:
  `{"VST.magic": 0, "VST3.uid": [0x5653544E, 0x6924486D, 0x61737369,
  0x76652078], "pluginName": "Massive X", "pluginVendor": "Native
  Instruments"}`), `PCHK` (30,497 B: three little-endian ints + a
  length field, then a zlib stream — the plugin's own state framing, opaque
  to us and correctly so). The VST3 class id was **confirmed against Live's
  own log**, which prints `cid: {5653544E-6924-486D-6173-736976652078}` when
  the plugin instantiates.
- **M7 — a real Live-written VST3 device XML was recovered.** The roadmap's
  "reference-diff a `.adv` Live itself saves" precondition looked blocked (no
  plugin `.adv` or plugin-bearing `.als` exists anywhere on this machine, and
  Live's LOM has no ordinary save), but a public test fixture supplies it:
  `krfantasy/alsdiff` → `test/data/plugin_device.xml`, a complete Live-written
  `<PluginDevice>` for a VST3 (Ozone 11 Imager), corroborated element-for-
  element by DawVert's Ableton writer. The framing my failed attempts lacked:
  a **`SourceContext / Value / BranchSourceContext`** block carrying
  `BrowserContentPath` (the plugin's own browser URI) and **`BranchDeviceId
  Value="device:vst3:audiofx:<class-id as dashed lowercase gu-id>"`** — almost
  certainly how the loader knows which plugin to instantiate. Also:
  `Vst3PluginInfo` carries `NumAudioInputs/NumAudioOutputs/
  IsPlaceholderDevice`; `Vst3Preset` carries `OverwriteProtectionNumber`,
  `Mpe*`, `StoredAllParameters` (**`true` in the fixture**, alongside a
  populated `ProcessorState`), four `*LomId`s, `Uid` (4 signed int32
  fields), `DeviceType` (1 = instrument, 2 = effect), `ProcessorState` as
  **uppercase hex, 48 bytes (96 chars) per line**, then three trailing
  children: empty `ControllerState`, `Name Value=""`, empty `PresetRef`.
  After `PluginDesc`, `PluginDevice` itself carries `MpeEnabled`,
  `MpeSettings` and a `ParameterList` (107 host-param entries in the
  fixture). The fixture's `BrowserContentPath` is
  `query:Everything#Ozone%2011%20Imager` — a search-results URI, so the
  value looks like provenance metadata rather than something validated;
  the template substitutes the plugin's own `Plugins#VST3` URI. *(Fixture
  re-fetched and the transcription re-derived independently at plan-review,
  2026-09-01; three errors in the original transcription corrected — hex
  line width 96 not 80, `StoredAllParameters` `true` not `false`, and the
  trailing `ControllerState`/`Name`/`PresetRef` + device-level
  `MpeEnabled`/`MpeSettings`/`ParameterList` were omitted. The Appendix
  template now reflects the fixture.)* The full template is in
  the Appendix.
- **M8 — attempt D exists but is untested.** A fixture-faithful `.adv` for
  Agonic Drone (template in the Appendix; `BranchDeviceId
  Value="device:vst3:instr:5653544e-6924-486d-6173-736976652078"`,
  `ProcessorState` = raw `PCHK` bytes) was generated, but this session's
  permission layer began refusing further `load_device` calls before it could
  be loaded. **It is the first thing the implementer runs.** The generator
  script survives at the session scratchpad as `gen_adv.py` and is
  reproduced by Part 1 — **but it predates the plan-review transcription
  corrections (see M7): regenerate from the corrected Appendix template
  rather than running the scratchpad copy as-is.**
- **M9 — binary-strings evidence, for calibration only.** `strings` over the
  Live 12.4.5 binary shows `adv:PluginDevice` (a plugin `.adv` is rooted at
  `PluginDevice` — consistent with M7) and bare `VstPluginInfo` /
  `AuPluginInfo` / `ProcessorState` / `VstPreset` tag strings, but **no bare
  `Vst3PluginInfo`/`Vst3Preset`** even though control tags (e.g.
  `InstrumentImpulse`) all appear exactly twice. The M7 fixture proves those
  tags are real on disk, so treat the strings table as unreliable for
  tag-presence negatives — recorded here so nobody re-runs that dead end.
- **M10 — cleanup caveat.** Deleting a User Library `.adv` removes its
  UserLibrary-URI row at the next reindex immediately, but can leave the
  merged `FileId_NNNN` row dangling until a later browser walk notices.
  Harmless, but the smoke tests' cleanup steps note it so a stale row is not
  misread as a failed cleanup.
- **M11 — a tier-1 route to a local reference exists but is unprobed.**
  `Live.Licensing.PythonLicensingBridge` lists a `save_current_set` method
  (`priv/AbletonOSC/FORK_GAPS.md`, tier-1: name and kind only, nothing
  called). If callable, loading the bare Massive X VST3 over OSC and saving
  the (already-titled) scratch set would yield a Live-12.4.5-written
  reference `.als` with no human — closing any residual doubt the M7 fixture
  (an older Live's output) leaves. This session's permission layer refused to
  write the probe into the installed Remote Scripts copy, so it stays a
  Part 3 step with a stated fallback.

## OSC contract

The spike sends **no new addresses and adds none**. Everything runs through
existing tools; the addresses behind them are cited here only where the spike
depends on their measured behaviour
([priv/AbletonOSC/API.md](../priv/AbletonOSC/API.md) is canonical):

| Address | Used via | What the spike relies on |
|---|---|---|
| `/live/browser/get/items` | `list_browser_items` / `reindex_library` | The walk lists only `is_loadable` items; a synthesized `.adv` appearing at all means Live's scanner accepted it as a browser item (not that it will load) |
| `/live/browser/load_item` `[track_id, uri]` | `load_device` | Reply `[track_id, uri, 'ok', device_name, device_index]` — **on an unparseable `.adv` the load is a silent no-op and the read-back names whatever is already on the track (M3)**. The spike must land this measurement in the fork's `API.md` (Part 5) |
| `/live/track/get/output_meter_level` `[track_id]` | raw (probe rig doc) or a scratch read | The state-fingerprint oracle (Part 4). Upstream address, already documented |
| `/live/song/get/file_path` | probe rig | Guard before any `save_current_set` probe: only probe a set that already has a path |
| `/live/song/begin_undo_step` / `end_undo_step` | automatic per tool call | Every mutation the spike makes is one undo step; cleanup is `delete_track` + file removal, not undo-spam |

## Parts

### Part 1 — spike scripts: `.nksf` reader and `.adv` writer

New directory `experiments/nks_load/` (same status as
[experiments/gmd_profiles/](../experiments/gmd_profiles/): committed spike
tooling, stdlib-only, never imported by `lib/`, no runtime reads):

- **`nksf_read.py`** — RIFF walk (`RIFF`/`NIKS`, chunk id + LE u32 size +
  word padding) plus a bounded msgpack decoder for the handful of types NKS
  actually uses (fixmap/map16, fixstr/str8/str16, fixarray, uint8–64, nil,
  bool — refuse anything else by name). Subcommands: `inspect <file.nksf>`
  (chunk map, decoded `NISI`/`PLID`, `PCHK` size and first bytes) and
  `--self-test` (re-parses a synthesized in-memory container). Rationale for
  hand-rolling: `harvest.py` set the stdlib-only precedent and msgpack's
  subset here is ~60 lines; a pip dependency for a spike is not worth its
  supply-chain surface.
- **`write_adv.py`** — emits the Appendix template with substitutions
  (preset name, dashed guid + `Fields.*` from `PLID`'s `VST3.uid`,
  `DeviceType`, `ProcessorState` hex from `PCHK`, 96-hex-chars-per-line), 
  gzip-compresses to a named output path. Variant knobs as flags, so
  iteration is a flag change, not an edit: `--no-source-context`,
  `--processor-state=raw|skip`, `--minor-version=<str>`,
  `--device-role=instr|audiofx`, `--stored-all-parameters=true|false`
  (default `true`, the fixture's value). `--check` re-reads its own output (gunzip +
  `xml.etree` parse + uid/state round-trip assert).
- **`corpus.py`** — reads spike-corpus rows from the NKS SQLite
  (`~/Library/Application Support/Native Instruments/<Product>/komplete.db3`,
  view `v_sound_info` — columns and the DB-underscores-vs-disk-spaces
  filename trap are in the options doc; normalize and `os.path.exists`-check
  before emitting). Read-only, stdlib `sqlite3`, same posture as
  `Seshat.Library.AbletonDB`. Output: the ≥5-preset Massive X spike slate
  (local file present, preview `.ogg` present, `Agonic Drone` included).

Checkable: the three scripts exist, run offline, and their self-checks pass
with no Live and no network.

### Part 2 — first load: attempt D, then the bounded ladder

Run against live Ableton, using existing tools only, with the Part 4 protocol
for every attempt (empty scratch track, `Log.txt` baseline, read-back — never
the reply):

1. **Attempt D** (Appendix template exactly): place under
   `~/Music/Ableton/User Library/Presets/Instruments/Massive X Spike/`,
   one `reindex_library`, load by UserLibrary URI. If Massive X instantiates
   (`Log.txt`: `VST3: Going to create: Massive X`) and a device lands, go to
   Part 4's state verification.
2. **If D is a silent no-op**, acquire a Live-12.4.5-written reference before
   burning attempts:
   - **Probe `save_current_set`** per the rig in `API.md` § "Measuring the
     Live API without building the feature first": temporary handler in the
     *installed* `return_track.py`, `/live/api/reload`, answers from
     `Log.txt`; guard on `/live/song/get/file_path` being non-empty first;
     restore the installed file from a byte-copy backup (not
     `mix abletonosc.install`, which would also move the installed tree to
     the current pin mid-session) and reload again. Load the bare Massive X
     VST3 (`query:Plugins#VST3:Native%20Instruments:Massive%20X`) on a
     scratch track first so the saved `.als` contains the subtree to diff.
     **This session's permission layer refused writes into the installed
     Remote Scripts copy — the implementer may hit the same wall.** If so:
   - **Attended fallback**, recorded as a manual precondition, not
     approximated: a person drags the loaded Massive X device into the User
     Library (or saves the scratch set); the diff target is whatever file
     that produces. One minute of human time ends all blind iteration.
3. **Only if no reference is obtainable**, the bounded variant matrix — one
   flag per attempt, stop after the list is exhausted: `--minor-version`
   downgraded to a Live 11 string (engages Live's schema-migration path, in
   case 12.4 renamed VST3 elements — M9's string-table asymmetry is weak
   evidence it might have); `--processor-state=skip` (state omitted
   entirely — does *any* Massive X instantiate from our framing?);
   `--stored-all-parameters=false` (in case `true` beside an empty
   `ParameterList` is itself the rejection); `--device-role=audiofx`
   spelling check; `PresetRef` populated vs empty. Each attempt is one file rewrite + one load + one read-back
   (M2), so the whole matrix is minutes.
4. **Stop rule.** No load after the matrix ⇒ the VST3-`.adv` rung fails;
   record which rung of the roadmap's fallback ladder comes next
   (per-format chunk-framing surgery → AX-scripting Komplete Kontrol's
   search → corpus restriction) **without building it**. A failed spike
   still merges: scripts, reference diffs, and the recorded verdict are the
   deliverable.

Checkable: the PR's verdict section names the exact attempt (or matrix
exhaustion) reached, with the `Log.txt` evidence quoted.

### Part 3 — state verification, then the corpus slate

A device landing is not the preset's *sound* landing (a plugin can silently
reject a state blob and open at init — Open question 5). Evidence ladder, in
order of strength available to an agent:

1. **Instantiation:** `Log.txt` gains `VST3: Going to create: Massive X` /
   `VST3: plugin processor successfully loaded … (cid: {5653544E-…})` after
   the load — proves the `.adv` reached plugin instantiation, which no
   rejected attempt ever did (M3).
2. **Chain read-back:** `get_track_devices` shows one instrument device on
   the scratch track; note the class Live reports (a plugin device, not a
   phantom native device) and the device name.
3. **Output-meter fingerprint:** write a 1-bar held-note MIDI clip on the
   scratch track, fire it, poll `output_meter_level` (~10 samples over
   ~4 s). Compare against the same measurement on a bare-init Massive X
   VST3 loaded the same way. Agonic Drone is a slow synthetic drone; init
   is a plain saw — the envelopes differ grossly. Same-shape readings are
   *suspicion* of a defaulted state, not proof either way; say which.
4. **Ears** — the actual acceptance, deliberately manual
   (`manual/by-ear.md`, cited below): does it sound like the preset's own
   `.previews/Agonic Drone.nksf.ogg`?

On a VST3 success, repeat load + evidence 1–3 for the rest of the Part 1
corpus slate (≥5 presets, one command each), and attempt **one AU wrapping**
(`AuPluginDevice`/`AuPluginInfo`/`AuPreset` framing — a different unknown;
`PLID` carries no AU class info, and the AU's `Macro 16` is the one extra
readable parameter). AU is a stretch goal: report reached/not-reached, never
let it block the VST3 verdict.

### Part 4 — record the outcome where each fact belongs

- **The verdict** — success, or the fallback rung reached and why — goes in
  [evaluating/semantic-sound-selection-options.md](evaluating/semantic-sound-selection-options.md)
  § "What remains unmeasured", replacing the Spike L bullet, either way it
  goes. Include the working template (or final failing matrix) by reference
  to `experiments/nks_load/`.
- **The wire measurement** (M3: `browser.load_item` on an unparseable `.adv`
  is a silent no-op whose read-back names the pre-existing device) is a fork
  wire fact: it lands as a doc-only commit in the fork's `API.md` beside the
  existing `load_item` rows, through the standalone clone per the ordinary
  fork workflow (doc-only: no `mix abletonosc.install`, no restart needed).
- **This plan's own M-facts** stay here; the plan is archived by `/ship` as
  the point-in-time record.

### Part 5 — smoke tests

Written at plan time (below, § Live verification):
`docs/smoke_tests/auto/nks-load.md` (three checks + a README table row) and a
new section in `docs/smoke_tests/manual/by-ear.md`. The auto file doubles as
the spike's runbook — deliberately, so "was this verified" and "how do I run
it" stay one document. If the spike's verdict is failure at every rung, the
synthesized-preset checks are retired in the same PR (a test goes when its
guarantee goes) and the file keeps only the chain-control check, which
passed today and guards `reindex_library`/`load_device`'s User Library path
regardless of NKS.

## Testing

Nothing in `lib/` changes, so `mix test` is untouched — there is deliberately
no ExUnit surface here. Pure coverage lives in the scripts themselves and
runs offline: `nksf_read.py --self-test` (RIFF walk + msgpack subset against
a synthesized container), `write_adv.py --check` (gunzip + XML re-parse +
uid/ProcessorState round-trip on its own output), `corpus.py` against the
real local DBs (read-only; skips with a message when a DB is absent).
Anything needing Live is Live verification, below, and is stated as such.

## Live verification

Nothing in `mix test` reaches any of this. Run the automated half with
`/smoke-test nks-load`.

- `smoke_tests/auto/nks-load.md § A foreign-written .adv is indexed and loadable without a Live restart`
  — the chain control (M1), green at plan time; guards the mechanism every
  other check stands on.
- `smoke_tests/auto/nks-load.md § A synthesized plugin .adv carries a device identity Live recognises`
  — the gate every load check below it stands on, and the cheapest to run;
  added after plan time once the browser-index oracle turned out to answer
  this in seconds rather than a load attempt.
- `smoke_tests/auto/nks-load.md § A synthesized NKS .adv lands Massive X carrying the preset's state`
  — the spike's core claim: instantiation in `Log.txt`, chain read-back,
  meter fingerprint vs bare init.
- `smoke_tests/auto/nks-load.md § A rejected .adv leaves the chain empty and its reply must not be trusted`
  — the control that keeps the previous check honest (M3's false-success
  reply, pinned so nobody ever verifies through the reply).
- `smoke_tests/manual/by-ear.md § A synthesized NKS preset sounds like its own preview`
  — the acceptance: ears against the preset's own `.previews` ogg.

**Uncovered, deliberately:** the full Collector's Edition corpus and
everything on the unmounted `/Volumes/Instruments` (logistics, options doc);
the AU lane if Part 3 doesn't reach it; Komplete-Kontrol-wrapped hosting
(out of scope); whether the dangling `FileId` row (M10) ever misleads a
later search (cosmetic; revisit only if it bites); `save_current_set`'s
behaviour if the probe stays permission-blocked (Open question 3).

## Out of scope

Per the roadmap entry, all deliberate: embeddings of any kind, CLAP, the
Python sidecar, the eval harness ("Search eval harness" below it), new MCP
tools or `Definitions` changes, full-library indexing, mounting or
re-downloading the absent external-volume content, and *building* any
fallback rung (failure only *names* the rung reached). Also out: making the
`.nksf` reader product-shaped Elixir (that decision belongs to the arc items
this spike gates), fork Python of any kind, and any change to
`Seshat.Library.Catalog` — the spike consumes `reindex_library` as-is.

## Open questions

1. ⚠️ **Does attempt D load?** The one question the plan phase built
   everything to answer and could not fire: the session's permission layer
   began refusing `load_device` calls (after allowing four) before the
   fixture-faithful, `BranchDeviceId`-bearing variant was tried. Assumed:
   it is the highest-probability candidate and the implementer's first
   command. Everything else in Part 2 is the contingency if it no-ops.
2. ⚠️ **PCHK → ProcessorState mapping.** Attempt D passes the raw `PCHK`
   bytes as the hex buffer. Plan-review re-fetched the M7 fixture and read
   its `ProcessorState` opening bytes directly: four little-endian 32-bit
   fields (`DE8A6800 04000000 95060000 07720000`) followed by a `789C…`
   zlib stream — the *same shape* M6 measured for `PCHK` (three LE ints +
   a length field, then zlib). That is weak-but-real support for raw-first:
   both look like the plugin's own VST3 component-state framing, not a Live
   container. Still unresolvable from one sample each until *some* framing
   loads (then Live's acceptance/rejection of the blob becomes observable
   via Part 3's evidence ladder). Assumed: raw-first, and the reference
   `.als` from Part 2.2 settles it if raw fails.
3. ⚠️ **`save_current_set` reachability.** Tier-1 name only
   (`PythonLicensingBridge`, FORK_GAPS.md); nothing says how the bridge
   instance is obtained, whether it saves silently, or whether an agent's
   permission layer allows writing the probe at all (this session's did
   not). Assumed: probe guarded by `file_path` non-empty, with the attended
   one-minute fallback named in Part 2.2 — the spike never blocks on it.
4. ⚠️ **AU framing.** `AuPluginDevice`/`AuPreset` uses a `Buffer` element
   and AU state is a CFDictionary plist, a genuinely different wrapping
   that `PLID` gives no ids for. Assumed: VST3 primary (that is what `PLID`
   targets), AU a reported stretch.
5. ⚠️ **The "loaded but defaulted" failure mode.** A plugin may accept
   instantiation and silently discard a bad state blob, presenting init.
   With one readable host parameter (M5) no read-back can prove state
   landed. Assumed: meter fingerprint as the agent-grade evidence, ears as
   acceptance — stated as such in the reply the verdict quotes, never
   claimed stronger.
6. ⚠️ **Rewrite freshness.** M2 established the URI survives a rewrite, but
   every rewritten variant no-opped identically, so "Live serves the new
   bytes on the next load" is unproven. Cheap to prove in passing: the
   first *successful* load of a rewritten file with an observable
   difference (e.g. preset name) settles it; until then each matrix attempt
   should use a fresh filename if two attempts ever behave identically in a
   suspicious way.

## Appendix — attempt D template (fixture-faithful, Live 12.4.5 target)

Substitutions: `{GUID}` = dashed lowercase class id from `PLID.VST3.uid`
(`5653544e-6924-486d-6173-736976652078` for Massive X), `{F0}…{F3}` = the
same four fields as **signed int32 decimal** (Live writes signed; identical
to unsigned for this cid, all four below 2³¹), `{NAME}` = preset name,
`{HEX}` = `PCHK` bytes as uppercase hex, **96 chars (48 bytes) per line**
(the fixture's measured width — the original 80 was a transcription error),
each line indented six tabs, buffer opened by a newline. Gzip the whole document; Live accepts Python-written gzip (M4
control). Verbatim structure (whitespace = tabs, as Live writes):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Ableton MajorVersion="5" MinorVersion="12.0_12402" SchemaChangeCount="1" Creator="Ableton Live 12.4.5" Revision="">
	<PluginDevice Id="0">
		<LomId Value="0" />
		<LomIdView Value="0" />
		<IsExpanded Value="true" />
		<BreakoutIsExpanded Value="false" />
		<On>
			<LomId Value="0" />
			<Manual Value="true" />
			<AutomationTarget Id="0">
				<LockEnvelope Value="0" />
			</AutomationTarget>
			<MidiCCOnOffThresholds>
				<Min Value="64" />
				<Max Value="127" />
			</MidiCCOnOffThresholds>
		</On>
		<ModulationSourceCount Value="0" />
		<ParametersListWrapper LomId="0" />
		<Pointee Id="0" />
		<LastSelectedTimeableIndex Value="0" />
		<LastSelectedClipEnvelopeIndex Value="0" />
		<LastPresetRef>
			<Value />
		</LastPresetRef>
		<LockedScripts />
		<IsFolded Value="false" />
		<ShouldShowPresetName Value="true" />
		<UserName Value="" />
		<Annotation Value="" />
		<SourceContext>
			<Value>
				<BranchSourceContext Id="0">
					<OriginalFileRef />
					<BrowserContentPath Value="query:Plugins#VST3:Native%20Instruments:Massive%20X" />
					<LocalFiltersJson Value="" />
					<PresetRef />
					<BranchDeviceId Value="device:vst3:instr:{GUID}" />
				</BranchSourceContext>
			</Value>
		</SourceContext>
		<MpePitchBendUsesTuning Value="true" />
		<PluginDesc>
			<Vst3PluginInfo Id="0">
				<WinPosX Value="100" />
				<WinPosY Value="100" />
				<NumAudioInputs Value="1" />
				<NumAudioOutputs Value="1" />
				<IsPlaceholderDevice Value="false" />
				<Preset>
					<Vst3Preset Id="0">
						<OverwriteProtectionNumber Value="3074" />
						<MpeEnabled Value="0" />
						<MpeSettings>
							<ZoneType Value="0" />
							<FirstNoteChannel Value="1" />
							<LastNoteChannel Value="15" />
						</MpeSettings>
						<ParameterSettings />
						<IsOn Value="true" />
						<PowerMacroControlIndex Value="-1" />
						<PowerMacroMappingRange>
							<Min Value="64" />
							<Max Value="127" />
						</PowerMacroMappingRange>
						<IsFolded Value="false" />
						<StoredAllParameters Value="true" />
						<DeviceLomId Value="0" />
						<DeviceViewLomId Value="0" />
						<IsOnLomId Value="0" />
						<ParametersListWrapperLomId Value="0" />
						<Uid>
							<Fields.0 Value="{F0}" />
							<Fields.1 Value="{F1}" />
							<Fields.2 Value="{F2}" />
							<Fields.3 Value="{F3}" />
						</Uid>
						<DeviceType Value="1" />
						<ProcessorState>{HEX}
						</ProcessorState>
						<ControllerState />
						<Name Value="" />
						<PresetRef />
					</Vst3Preset>
				</Preset>
				<Name Value="{NAME}" />
				<Uid>
					<Fields.0 Value="{F0}" />
					<Fields.1 Value="{F1}" />
					<Fields.2 Value="{F2}" />
					<Fields.3 Value="{F3}" />
				</Uid>
				<DeviceType Value="1" />
			</Vst3PluginInfo>
		</PluginDesc>
		<MpeEnabled Value="0" />
		<MpeSettings>
			<ZoneType Value="0" />
			<FirstNoteChannel Value="1" />
			<LastNoteChannel Value="15" />
		</MpeSettings>
		<ParameterList />
	</PluginDevice>
</Ableton>
```

Variants already tried and **known to silently no-op** (do not re-try
unmodified): (1) minimal `PluginDesc/Vst3PluginInfo` with Uid+Name+
DeviceType only, no SourceContext, no state; (2) DawVert-schema `Vst3Preset`
with all LomIds/StoredAllParameters but empty `<SourceContext><Value /></…>`
and unwrapped single-line hex; (3) as (2) with wrapped hex and Impulse-style
device boilerplate. The untried delta of attempt D over (3) is exactly:
populated `BranchSourceContext` (`BrowserContentPath` + `BranchDeviceId`),
`NumAudioInputs/Outputs`, `IsPlaceholderDevice`, `Mpe*`, `Pointee`,
`BreakoutIsExpanded`, and — added by the plan-review re-derivation —
`StoredAllParameters` flipped to the fixture's `true`, 96-char hex lines,
the trailing `ControllerState`/`Name`/`PresetRef` inside `Vst3Preset`, and
device-level `MpeEnabled`/`MpeSettings`/`ParameterList`.

Deliberate deviations from the fixture, all judged inert: `Id` attributes
and `WinPosX/Y` are arbitrary; `ParameterList` is left empty (the fixture's
107 entries are that plugin's host parameters, unknowable before
instantiation — M4's lenient deserializer is the cover); `BrowserContentPath`
substitutes the plugin's own `Plugins#VST3` URI where the fixture recorded
the `query:Everything#…` search it was loaded from (provenance metadata, per
M7); and the root gains the `<Ableton>` wrapper every measured `.adv`
carries (the fixture is a bare `<PluginDevice>` fragment cut from an
`.als`).
