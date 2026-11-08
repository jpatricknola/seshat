# Semantic instrument & preset selection — options

_Research & options doc · 31 Aug 2026 · evaluates the handoff brief
[seshat-semantic-instrument-selection-handoff.md](seshat-semantic-instrument-selection-handoff.md)
against what Live, the fork, and this machine actually provide. Decides
nothing by itself; may feed [ROADMAP.md](../ROADMAP.md). Sibling of
[sound-search-options.md](sound-search-options.md) (27 Jul), whose
"embeddings — not planned" stance this doc partly supersedes — that doc has
been edited to point here. All measurements: Live 12.4.5
(2026-08-19 build, confirmed current as of 2026-08-26 release), macOS
(Darwin 24.6.0), Patrick's machine, 2026-08-31 unless dated otherwise._

## Verdict up front

The brief's central question — **how much retrieval quality do actual
preset-audio embeddings add over rich semantic metadata?** — is worth
answering, and it is cheap to answer on this machine: the NKS metadata is
readable SQLite (measured), the NI preview audio already exists on disk
(measured, ~5,000 `.ogg` locally), and a licence-clean music-capable CLAP
exists (`laion/larger_clap_music`, Apache-2.0, reported). Run the brief's
Phase 0–2 substantially as written, with four amendments the brief could not
have known:

1. **The load path is the binding gap, and the brief never mentions it.**
   Measured: Live's browser — and therefore Seshat's catalog and
   `load_device` — contains **zero NKS preset entries**; NI products appear
   as 10 bare plugin devices. A retrieval system that names "Massive X /
   Cold Circuit" cannot currently land it on a track. Gate the whole NKS
   strategy on **Spike L** (below): `.nksf` files carry the raw plugin
   state chunk (`PCHK`, measured on this machine), which may be wrappable
   as a Live `.adv` preset that `load_device` can load. If Spike L fails
   at every fallback, NKS degrades to metadata enrichment of sounds Seshat
   can already load — still useful, much smaller.
2. **The baseline must be the improved catalog, not today's catalog.**
   [sound-search-options.md](sound-search-options.md) levers №1/№2/№4
   (tag axes, proactive vocabulary, widened tied bands) are zero-dependency,
   a few days' work, and attack the same failure modes. Benchmarking
   embeddings against the *unimproved* lexical search over-credits them.
3. **MuQ-MuLan and MERT are disqualified as shipped dependencies** — weights
   CC-BY-NC-4.0 (reported, verified on their model cards 2026-08-31), same
   ruling as the drum transcriber in
   [midi-generation-options.md](generative%20features/midi-generation-options.md).
   They may appear in the offline benchmark as a ceiling reference; the
   shipped audio route is CLAP or nothing.
4. **A Python similarity sidecar is a third native-process door.**
   CLAUDE.md pins exactly two; a third is a design decision argued in the
   commit that adds it. The text-only route (Strategy A) could avoid it
   entirely via Bumblebee in the BEAM (reported); the audio route cannot.

Recommended order: **Spike L → Phase 0 harness (extends roadmap №9) →
Strategy A vs improved-catalog baseline → CLAP-on-previews experiment →
brief's §33 gate (≥20% Best-of-5) before any further audio investment.**
Standardized full-library rendering (Strategy D) stays deferred exactly as
the brief recommends — and the shipping-compatible render routes are worse
than the brief assumes (§ Capability C6).

## Capability frame

| # | Capability | Brief section | Live-native rung (see ladder) |
|---|---|---|---|
| C1 | Interpret request → SoundIntent | §5–6 | N/A — the MCP client LLM, per "the LLM does the resolving" |
| C2 | Resolve cultural references (artist/song/gear → sonic profile) | §14–16 | N/A — LLM world knowledge; graph/web optional later |
| C3 | Unified SoundCandidate corpus (NKS + Ableton metadata) | §2–3 | New read-only SQLite reader beside `AbletonDB` — measured feasible |
| C4 | Text-semantic retrieval (Strategy A) | §4 | None at any rung; zero-dep partial substitute = catalog levers №1/№2/№4 |
| C5 | Audio-semantic retrieval (Strategy C — CLAP on previews) | §7–10 | None at any rung; previews measured on disk |
| C6 | Standardized preset renders (Strategy D) | §11 | Real-time record via Live only (OSC-reachable); no offline render in LOM (tier-1 negative) |
| C7 | DSP features (Strategy E) | §12 | None; librosa (ISC) clean, Essentia (AGPL) disqualified as shipped |
| C8 | Similarity service boundary | §24 | Bumblebee/BEAM for text; Python sidecar (third door) for audio |
| C9 | Audition candidates | §22 | Fork `preview_item` already vendored (browser items, cue bus); NKS preview playback open |
| C10 | Load the winner onto a track | — (absent from brief) | **Gap. Spike L.** |
| C11 | Relative queries ("darker than this") | §18 | Partial: `get_track_devices` + accepted-search memory (lever №8) |
| C12 | Audio-reference queries ("like this") | §17 | Deferred with brief's Phase 5 |
| C13 | Retrieval eval harness | §25–29 | Extends roadmap №9 ("Search eval harness") — do not build twice |

## Live-native ladder results

**2.0 Version.** Installed 12.4.5 (2026-08-19 build); latest release is
12.4.5 (2026-08-26) — current, nothing newer to account for. Live 12's own
similarity search: tier-1 grep of the binary (2026-08-31) finds
`SimilaritySwapping` only as UI/view classes (`NStepDrumRack_SimilaritySwapping`,
`ISimilaritySwappableView`) and menu machinery — no `Live.*` Boost.Python
registration. It is a samples-oriented UI feature, not a LOM capability, and
does not answer natural-language queries; not a substitute for any strategy
here.

**2.1 Tool layer.** `search_library`/`load_device`/`delete_device`/
`bypass_device` give retrieval + hot-swap audition over what Live's browser
indexes. `get_track_devices` names the current device (C11's anchor).
No preview tool exists yet even though the fork address does.

**2.2 Fork.** `/live/browser/preview_item` / `stop_preview` are **already
vendored and documented** in [API.md](../../priv/AbletonOSC/API.md)
(cue-bus routing caveat measured and recorded there). No new fork work was
identified by this evaluation — C9's remaining half is a Seshat tool, and
C10's candidates need no OSC at all.

**2.3 LOM.** Two checks run 2026-08-31:

- `Browser.preview_item` — tier 2 **confirmed**: `Push2/browser_component.pyc`
  and `Push/browser_model.pyc` both call it (already known; re-verified).
- Offline audio render/bounce — tier-1 **negative**: `strings` over the Live
  binary finds Bounce only as menu commands (`Edit>Bounce Track in Place` …)
  and as `push_live_model` flip messages (`Track::Message_bounce`), which is
  Push 3's internal model, not the `import Live` surface. No
  `export_audio`/`render` registration. Faster-than-real-time rendering is
  therefore not reachable over OSC; C6's only OSC route is real-time
  recording (`record_clip`, resampling), ~10s of wall clock per probe.

**2.4 Extensions SDK.** `renderPreFxAudio()` exists there
([extensions-sdk.md](extensions-sdk.md)) but the rung is *deferred*: no beta
access, user-right-click trigger model, Suite-only. Not a plannable route
for C6 today.

**2.5 UI-only.** Live's Bounce commands (tier-1 evidence above) are the
UI-only render route; Komplete Kontrol's own browser is the UI-only load
route (Spike L fallback 2). Both carry the
[ui-scripting-options.md](ui-scripting-options.md) mechanism costs.

## Measured: what this machine actually holds (2026-08-31)

- **NKS metadata is plainly readable.** Per-product SQLite at
  `~/Library/Application Support/Native Instruments/<Product>/komplete.db3`
  plus a unified Komplete Kontrol DB (`Komplete Kontrol/Browser Data/
  komplete.db3`, 6.9 MB, 2,266 rows). The `v_sound_info` view yields
  name / brand / product / bank / **type** (Sound Type hierarchy, e.g.
  `Bass, Bass, Synth`) / **character** (e.g. `Long/Evolving, Synthetic,
  Tempo-synced`) / comment — exactly the brief's §3 ingestion target, no
  file parsing required. Same read-only posture as
  [ableton_db.ex](../../lib/seshat/library/ableton_db.ex).
- **Row counts (raw, overlapping):** Battery 4: 37,373 · Maschine 2:
  25,938 · Kontakt 8: 11,714 · Maschine 3: 6,733 · Massive X: 1,357 ·
  KK unified: 2,266. Much of Battery/Maschine is one-shot samples and
  loops, not instrument presets; dedupe and type-filtering are spike work.
- **Preview audio exists without any rendering:** 3,147 `.ogg` under
  `/Users/Shared/**/.previews` + 1,811 under `/Library/Application
  Support/Native Instruments`, ~130–290 KB each. Convention:
  `<dir>/.previews/<preset filename>.ogg`, confirmed by eye (e.g.
  `Massive X/Presets/.previews/Agonic Drone.nksf.ogg`). **This falsifies
  the 27 Jul claim** in sound-search-options.md that audio embeddings would
  first require loading and rendering every preset.
- **Coverage is partial and uneven:** synth-product presets sampled mostly
  HAVE previews; effects presets (`.nksfx`) and Kontakt-expansion raw
  `.wav`s mostly MISS. Per-product coverage must be counted in the spike,
  not assumed.
- **Most of Collector's Edition is on an unmounted volume — a logistics
  note, not a scope cut.** `k_content_path` points at
  `/Volumes/Instruments/nat_inst/…` (Kontakt libraries, expansions);
  `/Volumes` shows only `Macintosh HD` today. The design corpus stays the
  brief's stated assumption: **everything in Komplete Collector's Edition
  is in scope.** Content absent locally is recoverable — mount the drive,
  or re-download via Native Access — and metadata/previews for the spike
  can come from whichever copy is reachable. Operationally the
  1,000-preset spike corpus starts from internal-disk content; the full
  index waits on the drive, and the indexer must tolerate absent roots
  without dropping the rows.
- **A DB↔disk filename trap:** Massive X's DB records
  `Init_-_Massive_X.nksf` (underscored) where the disk has spaces; only 65
  of the DB's 1,205 nksf rows are present locally (the rest are on the
  unmounted volume / Player library). Mapping row → file → preview needs
  normalization plus an existence check.
- **`.nksf` internals confirmed:** RIFF/`NIKS` container; `NISI` chunk =
  msgpack metadata (bankchain, author, `modes` = Character, deviceType);
  `PLID` = plugin id; **`PCHK` = 30 KB raw plugin state** (measured on
  `Agonic Drone.nksf`). This is Spike L's raw material.
- **Live browser holds no NKS presets:** the dev catalog (5,796 entries)
  contains exactly 10 NI-related rows, all bare plugin devices
  (`query:Plugins#AUv2:Native Instruments:Massive`, Kontakt 7/8, …). No
  preset children. C10 is real.

## External survey

| Candidate | Role | Code licence | Weights licence | Status | Notes |
|---|---|---|---|---|---|
| LAION-CLAP (`laion_clap` pkg) | text↔audio embedding | CC0-1.0 (reported, repo) | `.pt` checkpoints: unstated on repo (reported) | maintained | Use the HF releases instead |
| `laion/larger_clap_music` (HF, transformers) | text↔audio embedding | — | **Apache-2.0** (reported, model card 2026-08-31) | maintained | **The clean shipped route.** Music-tuned |
| MuQ-MuLan (OpenMuQ / Tencent AI Lab) | music↔text embedding | MIT | **CC-BY-NC-4.0 — disqualified as shipped** | active | Benchmark-only ceiling reference |
| MERT-v1 (m-a-p) | audio representation | — | **CC-BY-NC-4.0 — disqualified as shipped** | active | Only relevant to audio↔audio later anyway |
| sas-patch-service | prior art (Surge XT + CLAP) | MIT (repo; bundles GPL-3 Surge content if distributed) | n/a | active (shipped Jul 2026) | Evidence the architecture works; nothing to import — Surge-specific |
| synth-setter | prior art | not checked | n/a | not checked | Secondary; read before the CLAP spike, nothing depends on it |
| librosa / numpy / soundfile | DSP features (C7) | ISC/BSD | n/a | healthy | Already blessed in ROADMAP №5's separator note |
| Essentia | DSP features | **AGPL-3.0 — disqualified as shipped** | n/a | healthy | librosa suffices |
| sentence-transformers MiniLM-class model | text embedding (C4) | Apache-2.0 | Apache-2.0 (typical; pin exact model in plan) | healthy | Runnable via Bumblebee (Elixir, Apache-2.0) — no sidecar for text-only |
| pedalboard / DawDreamer | offline plugin host (C6) | **GPL-3.0** | n/a | healthy | Shipping a GPL renderer is a real (if survivable) cost; defer with Strategy D |
| Komplete Kontrol MIDI control | load path candidate | n/a | n/a | — | **Rejected**: only next/prev-preset CC, no jump-to-preset (reported, NI docs + community 2026-08-31) |

**NKS data/previews legal posture:** Seshat ships no NI content. It reads
databases and plays/embeds preview files the user's own Komplete
installation put on the user's own disk, locally — same posture as reading
Ableton's browser DB. Embedding vectors derived from previews stay in the
local index. Nothing here touches the distribution rule.

**Local-first:** every shipped candidate above runs locally, no API key.
The one posture cost is packaging: a Python sidecar (~CLAP + librosa +
numpy) is hundreds of MB of runtime the distributed product must carry —
same class of dependency as the already-accepted Stable Audio MLX runtime,
but a *new* process door (C8).

## Comparison — where each strategy actually stands

Quality figures are the spike's to produce; this table records structural
facts only. "Improved catalog" = levers №1/№2/№4 of
[sound-search-options.md](sound-search-options.md).

| Criterion | Improved catalog (zero-dep) | A: text embeddings | C: CLAP on previews | D: CLAP on renders | E: hybrid |
|---|---|---|---|---|---|
| Live-native column | entirely — Ableton DB + replies | none (external model) | none | record-through-Live is the only OSC route | mix |
| Searches sound or descriptions? | descriptions | descriptions (denser) | **sound** | sound, controlled | both |
| New runtime deps | none | 1 model (BEAM-hostable) | CLAP + Python sidecar | + renderer (GPL cost) | superset |
| Licence status | clean | clean (Apache) | clean (Apache) | GPL renderer or Live real-time | clean if C is |
| Corpus reach today | Live-loadable items only | + NKS metadata (C3) | NKS presets **with previews** (partial, measured) | anything loadable+renderable | union |
| Load path for what it finds | **works today** | works for catalog items; NKS hits need Spike L | needs Spike L | needs Spike L | mixed |
| Latency shape | instant (ETS) | instant after query-embed | instant after query-embed | same | same |
| Index build cost | none | minutes | ~5k previews × CLAP, one-time, local | days of real-time rendering per 10k presets | superset |
| Killable by | — | harness shows no lift over improved catalog | Spike L failure; §33 gate | brief §29 (previews ≈ renders) | its parts |

The wiring question: only the improved-catalog column chains into the
existing one-request flow today. Every NKS-corpus strategy chains **only
through Spike L**; if Spike L lands, all of them chain identically
(candidate → synthesized/loadable preset → `load_device` → hot-swap loop →
undo step), so the load path is a shared gate, not a per-strategy cost.

## Verdict expanded — the experiments, in order

**Spike L — the load path (go/no-go for the NKS corpus). Run 2026-09-01; read
"Spike L result" below for what it measured and what it did not.** Parse one
`.nksf`'s `PLID`+`PCHK`, wrap the state chunk as a Live `.adv`
(VST3/AU device preset — gzipped XML with a state blob) in the User
Library, `reindex_library`, `load_device`, and listen: does Massive X open
carrying *that preset's* sound? One day. Kills: fallback 1 is per-format
chunk surgery (VST3 vs AU state framing); fallback 2 is AX-scripting
Komplete Kontrol's search field per the
[ui-scripting-options.md](ui-scripting-options.md) ladder (works, ugly,
per-load focus cost); fallback 3 is corpus restriction — NKS
metadata/audio only *reranks and describes* sounds the Live browser can
already load. Even fallback 3 leaves Strategies A/C alive for the
Live-loadable corpus, so no outcome kills the brief outright; the outcome
sizes it.

**Phase 0 — harness first (extends roadmap №9, don't build twice).** The
roadmap's "Search eval harness" item and the brief's §25–29 are one
artifact: fixed corpus (~500–1,000 internal-disk presets), ~100 queries
across the brief's difficulty classes, blind listening, Best-of-5 /
Precision@5. Build it once with pluggable retrieval backends.

**Experiment A — improved catalog vs Strategy A.** Ship levers №1/№2/№4
(they win regardless), then measure text embeddings *over* that baseline.
Text-only can run in the BEAM (Bumblebee) — no third door. If A shows no
lift here, the brief's Phase 1 shrinks to NKS ingestion + intent schema
without the embedding index.

**Experiment C — CLAP on previews (the brief's "most important
experiment").** Embed the ~5k local previews with `larger_clap_music`,
compare against A on the same harness. Gate: the brief's §33 ≥20%
Best-of-5 lift. Only a pass buys the Python sidecar door argument and
full-library indexing (mounted volume).

**Strategy D stays deferred** (brief §11 already says so; the render-route
survey above makes it worse than the brief assumed). **Phases 4–6**
(reference resolver, audio-reference, arrangement fit) ride behind the
gate; note C2 needs no new system for v1 — Claude already translates
"Enjoy the Silence bass" into qualities, which is the brief's §6 division
working as designed.

## Spike L result — measured 2026-09-01 (Live 12.4.5, this machine)

Run under [PLAN_nks_load_path.md](../archive/PLAN_nks_load_path.md) (archived
— the spike's verdict is inconclusive); tooling committed at
[experiments/nks_load/](../../experiments/nks_load/); the repeatable checks
are [smoke_tests/auto/nks-load.md](../smoke_tests/auto/nks-load.md).

**Verdict: the VST3-`.adv` rung is not proven, and the blocker is now located
precisely — one stage earlier than the spike was designed to look.** A
hand-written `.adv` rooted at `<PluginDevice>` never acquires a *device
identity* in Live's browser index, so `browser.load_item` has nothing to
instantiate and declines in silence. This is not a plugin-state problem, nor a
deserializer problem: it is Live's metadata extractor refusing to recognise the
file as a device at all.

The evidence, in the order it settles the question:

- **Live's browser database is the oracle.** `~/Library/Application
  Support/Ableton/Live Database/Live-files-<n>.db`, table `files`, carries per
  file the `device_id` the extractor derived — `device:ableton:instr:UltraAnalog`,
  `device:vst3:instr:<guid>`, and so on. Every one of the ~2,000 real
  `.adv`/`.adg` files on this machine has a non-empty one; the only rows with an
  empty `device_id` were the synthesized ones. `experiments/nks_load/index_probe.py`
  reads it, which turns each attempt into seconds rather than a minute of frozen
  Live UI plus a mutated set.
- **The extractor works fine on foreign-written native files.** A byte-copy of a
  Core Library Analog preset, a Python gunzip/re-gzip round trip of it, and a
  254-byte skeleton carrying nothing but the `<UltraAnalog>` root element all
  index as `device:ableton:instr:UltraAnalog` with five `metadata` rows and a
  `file_devices` link. So the identity comes from the root element name, and
  Python-written gzip XML is not the obstacle.
- **Eleven `<PluginDevice>` variants were refused identically** — `device_id`
  empty, `device_type=0`, `device_arch=0`, zero `metadata` rows, no
  `file_devices` link, and no extraction exception in `Indexer.txt`. The set
  covers the plan's fixture-faithful attempt D, the whole planned flag matrix
  (`--no-source-context`, `--processor-state skip`,
  `--stored-all-parameters false`, a Live 11 `MinorVersion`, `--device-role
  audiofx`), three reduced skeletons isolating `SourceContext` from
  `PluginDesc`, a real `Creator`/`Revision` pair lifted from a Live-written
  file, and one uncompressed document.
- **The class id is not the defect.** Live's plugin registry
  (`Live-plugins-1.db`, table `plugins`) spells Massive X exactly
  `device:vst3:instr:5653544e-6924-486d-6173-736976652078` — byte-identical to
  the `BranchDeviceId` the template writes, and to the `cid:` Live logs when the
  plugin instantiates.
- **Live *does* read this XML, and it crashes on it.** Substituting the
  synthesized `<PluginDevice>` for the native device inside a real Core Library
  Instrument Rack produced an `.adg` that indexed correctly as
  `device:ableton:instr:InstrumentGroupDevice` — and loading it **segfaulted
  Live** (`EXC_BAD_ACCESS`, triggered frame in `AEditableDeviceChain`). That is
  the only evidence anywhere that the deserializer consumes this framing at
  all, and it says the framing is semantically wrong rather than ignored. It
  also makes rack-wrapping unusable as an iteration route; the smoke-test file
  carries the hazard notice.
- **`.nksf` parsing is settled and cheap** (`nksf_read.py`): RIFF/`NIKS`, a
  4-byte little-endian version word ahead of each msgpack chunk (`NISI`, `NICA`,
  `PLID`), and `PCHK` as opaque plugin state whose own header — three
  little-endian ints, a length, then a `78 9C` zlib stream — has the same shape
  as the `ProcessorState` buffer in a Live-written VST3 device.

**What would settle it, and it is small:** one plugin preset written by Live
itself — a person drags a loaded Massive X device into the User Library, or
saves a set containing one — then `index_probe.py` on that file says what
identity Live gave it, and a diff against the template says what the extractor
needed. The blind route is exhausted; this is now a one-minute human artefact,
not a research question. The scripted alternative (`PythonLicensingBridge.
save_current_set`, tier-1 name only) sits on a class that also exposes
`create_new_live_set` and `request_exit`, and was judged not worth probing
unattended against a live session.

**Consequences for the strategy table, unchanged for now.** No fallback rung is
promoted yet, because the rung above it is not refuted — only unproven. If the
Live-written reference shows the extractor needs something unforgeable, the
ladder is the one already written above: per-format chunk-framing surgery →
AX-scripting Komplete Kontrol's search
([ui-scripting-options.md](ui-scripting-options.md)) → corpus restriction to
what Live's browser already loads.

## What remains unmeasured

- Everything on `/Volumes/Instruments` (counts, preview coverage) — drive
  unmounted today.
- Preview coverage per product across the full Collector's Edition, and
  KK-unified vs per-product DB overlap/dedupe rules.
- ~~Whether a `PCHK`-derived `.adv` actually loads (Spike L — the pivotal
  unknown).~~ **Run 2026-09-01 — see "Spike L result" above.** Still open in
  one sentence: nothing hand-written has cleared Live's browser *metadata
  extractor*, and the one artefact that would settle it (a plugin preset
  Live itself wrote) needs about a minute of a person's time.
- CLAP retrieval quality on synth timbre and on the brief's metaphorical
  query classes (the whole point of Experiment C).
- `preview_item` audibility UX with default cue routing on this machine
  (fork API.md records the mechanism; nobody has run it for a
  candidate-slate flow).
- Whether Battery/Maschine sample rows should enter the corpus at all
  (interacts with roadmap's samples-index item).

## Source index

- Measured on this machine 2026-09-01 (Spike L result above): Live's browser
  index `Live-files-12300.db` (`files.device_id` / `metadata` / `file_devices`),
  Live's plugin registry `Live-plugins-1.db`, `Indexer.txt` and `Log.txt`
  tails, eleven synthesized `.adv` variants plus three native controls, one
  rack-wrapped `.adg` that crashed Live, and the `.nksf` chunk-version word.
  Tooling: [experiments/nks_load/](../../experiments/nks_load/).
- Measured on this machine 2026-08-31: NI SQLite DBs (paths above), preview
  `.ogg` census, `.nksf` RIFF parse, dev `catalog.json` NI-entry census,
  tier-1 `strings` greps (SimilaritySwapping, Bounce/export), tier-2
  `preview_item` grep of Push2/Push pycs, `/Volumes` state.
- [seshat-semantic-instrument-selection-handoff.md](seshat-semantic-instrument-selection-handoff.md) — the brief under evaluation.
- [sound-search-options.md](sound-search-options.md) — funnel measurements, levers №1–№9.
- [priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md) — `preview_item` rows and cue-bus caveat.
- [extensions-sdk.md](extensions-sdk.md) — why `renderPreFxAudio()` is a deferred rung.
- [ui-scripting-options.md](ui-scripting-options.md) — mechanism ladder for Spike L fallback 2.
- Reported (fetched 2026-08-31): [Ableton release notes](https://www.ableton.com/en/release-notes/live-12/) (12.4.5 current) · [LAION-AI/CLAP](https://github.com/LAION-AI/CLAP) (CC0 code, checkpoint licence unstated) · [laion/larger_clap_music](https://huggingface.co/laion/larger_clap_music) (Apache-2.0) · [OpenMuQ/MuQ-MuLan-large](https://huggingface.co/OpenMuQ/MuQ-MuLan-large) (CC-BY-NC-4.0 weights) · [m-a-p/MERT-v1-330M](https://huggingface.co/m-a-p/MERT-v1-330M) (CC-BY-NC-4.0) · [sas-patch-service](https://github.com/shiehn/sas-patch-service) (MIT, Surge GPL caveat) · [NI: Switch Plug-in Presets via MIDI Program Change](https://support.native-instruments.com/hc/en-us/articles/209593369) + [NI community](https://community.native-instruments.com/discussion/7900/recalling-presets-in-komplete-kontrol-when-using-midi) (no jump-to-preset).
