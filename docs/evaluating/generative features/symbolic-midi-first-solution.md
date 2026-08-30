# Symbolic MIDI — which candidate is the *first* solution, and what it costs

_Decision doc · 30 Aug 2026 · re-evaluates the slate in
[symbolic-midi-strategy-options.md](symbolic-midi-strategy-options.md) with
fresh tier-1 LOM evidence, a measured Groove MIDI Dataset, and a measured
wire probe against running Live 12.4.5 · decides no product backend by
itself, but is written to let ROADMAP #1 be re-scoped from a four-branch
bake-off into one plannable feature._

The earlier [options survey](midi-generation-options.md) remains the evidence
record for models run on this Mac and for the rejected audio-first route; the
[strategy audit](symbolic-midi-strategy-options.md) remains the record of what
the two consultant submissions were worth. This doc answers the one question
neither settles: **of the surviving symbolic candidates, which one does Seshat
build first, and what is genuinely in the way?**

## Verdict up front

**Build the pattern-DSL/procedural lane with a performance layer, and write it
through `/live/clip/add/notes_extended`. Nothing else in the slate is the first
solution.** Three measurements taken today move it from "one of two primary
branches" to "the one":

1. **The feel layer needs no model and no new process.** The pinned fork
   already registers `/live/clip/add/notes_extended` — pitch, start, duration,
   velocity, mute, **probability, velocity deviation, release velocity** — and
   `lib/` has never used it. *Measured 2026-08-30, Live 12.4.5, this Mac:* an
   eight-field write carrying `probability 0.5` and `velocity_deviation 15.0`
   was accepted and both notes landed in the clip (read back through
   `get_clip_notes`). Humanisation is therefore a **tool-layer change**, not a
   fork gap, not a LOM gap, and not a dependency.
2. **GMD cannot be the runtime engine for the prompts this feature exists to
   serve, but it is an excellent offline donor.** *Measured 2026-08-30 (whole
   dataset, this Mac):* 1,150 files, 3.26 MB zipped; 424 `beat` files are ≥ 4
   bars; the style vocabulary is a live-drummer corpus — rock 151, latin 51,
   funk 50, jazz 44, **hiphop 30, dance 7**, and **no lo-fi, trap, house,
   techno, D&B or ambient label at all**. What it *does* carry, at high value:
   human microtiming of **6.7–14.8 % of a 16th note on average** (max ≈ 48 %)
   and velocity spreads of **σ ≈ 28–33 with ghost notes down to velocity 5**.
   That is a style-profile source to harvest once, offline, not a library to
   retrieve from at request time.
3. **Live's own groove machinery cannot be populated by Seshat.** *Tier 1,
   measured 2026-08-30:* `Live.GroovePool` exposes exactly `grooves` and
   `canonical_parent` — **no add, create or import member** — and the tier-1
   `Live.Browser` root list (colors, sounds, drums, instruments, audio_effects,
   midi_effects, max_for_live, plugins, clips, samples, packs, user_library,
   current_project, legacy_libraries, user_folders) has **no grooves root**.
   The 219 `.agr` files shipped in Core Library (137 Swing, 58 Style, 12
   Utility, 12 Percussion — counted on disk, *not* the ~3,000 claimed in
   [live-native-options.md](live-native-options.md), now corrected there) are
   reachable only by a human dragging one into the set. *Measured on the
   running set:* its pool holds exactly one groove, `Swing 16ths 66`.
   `Clip.groove` assignment stays worth having, but it is a **conditional
   garnish on whatever the user happens to have**, never the mechanism the
   feature's feel rests on.

So the performance layer belongs **inside the notes** — explicit per-note
microtiming offsets, velocity contours, ghost notes, and Live's own
`probability` / `velocity_deviation` fields — with GMD supplying the numbers
and CC-BY-4.0 attribution, and a Live groove offered as an optional extra when
the pool has one.

Composer's Assistant 2 and the Anticipatory Music Transformer stay in the
slate, unbuilt, as **specialists gated on hearing the first solution**. Both
would need a third native-process door (`CLAUDE.md` requires that to be argued
in the commit that adds it), and neither addresses the failure this feature is
actually fixing. AMT's licence question is now closed in its favour — see §3 —
which makes it the cheaper of the two to reach for later.

**What this changes for ROADMAP #1:** the item stops being "run a four-branch
bake-off, then plan against the winner" and becomes "ship the DSL plus
performance layer; judge it by ear on a fixed prompt slate; only then decide
whether a neural specialist earns a process door." The bake-off's shared seam
(`BeatPlan`, `SymbolicScore`, validator, fixed slate, blind listening) is not
discarded — it is the first solution's own internal shape and its acceptance
test.

## 1 · Capability frame

Rows are from the [strategy audit](symbolic-midi-strategy-options.md); the
rung column is this pass's finding.

| Capability | Lowest useful rung, today | Cost |
|---|---|---|
| Interpret intent → plan | Claude + a pure Elixir plan struct | None; no tool, no wire |
| Read context (existing clips) | **2.1 tool layer** — `get_clip_notes` (5 of 9 fields) | Widen to `get/notes_extended` (registered, unused) when expression matters |
| Compose jointly (multi-lane) | **Seshat code** — no Live rung exists (§2) | The feature's real work |
| Perform (velocity + microtiming) | **2.1 tool-layer gap** — `add/notes_extended` registered, unused; **measured accepted today** | One handler/tool change; profiles harvested from GMD |
| Feel via Live grooves | **2.3 LOM ceiling** — pool is read-only for content | Optional garnish; refuse honestly when the pool is empty |
| Validate before writing | **Seshat code** — pure, pre-wire | Ordinary |
| Revise surgically | **2.1** — `edit_notes`, plus re-compiling the stored pattern | Keep plan + pattern beside the clip |
| Land parts, one undo step | **2.1/2.2 — shipped** — `create_track`, `write_midi_notes`, per-call undo bracketing | One handler-owned multi-part workflow; watch the 367-note datagram ceiling |

## 2 · Live-native ladder (re-run, tier 1 and 2)

**Version.** Installed **12.4.5** (`CFBundleShortVersionString`
`12.4.5 (2026-08-19_225ce5e356)`, read 2026-08-30); latest released is 12.4.5.

| Question | Rung reached | Evidence |
|---|---|---|
| Does Live expose a symbolic *generator* to a Remote Script? | **2.5 UI-only** | **Tier 1:** the only binary string in the family is `midi_transformations_and_generators_support`, and it sits inside the **`LicenseServices`** member block beside `has_live_12_intro_license` — an edition flag, not an entry point. No `Live.MidiTool*` module in the tier-1 module list. **Tier 2:** no shipped Remote Script references a MIDI tool or generator (matches are control-element factories). Rhythm/Seed/Shape/Stacks remain clip-editor UI. |
| Can Seshat write expression (probability, velocity deviation, release velocity)? | **2.1 tool gap** | Fork registers `add/notes_extended`; **measured accepted on the wire today** (see Verdict §1). |
| Can Seshat add a groove to the Groove Pool? | **No rung — LOM ceiling** | **Tier 1:** `Live.GroovePool` = `grooves`, `canonical_parent`. `Live.Groove` is read/write for name, `quantization_amount`, `timing_amount`, `random_amount`, velocity amount and base grid — i.e. you may *tune* a groove that exists, never *create* one. **Tier 1 + measured:** no `grooves` browser root; `list_browser_items user_library filter:"groove"` returns nothing. |
| Can Seshat assign an existing groove to a clip? | **2.2 fork — shipped, tool missing** | `/live/clip/get|set/groove` by pool index; *measured:* the running set's pool = 1 groove (`Swing 16ths 66`). |
| Extract Groove from a clip (feel transfer) | **2.5 UI-only** | Unchanged; re-checked against the fixed tier-1 walk on 2026-08-30 in [live-native-options.md](live-native-options.md). |

The honest reading: **Live owns execution and garnish, not composition.** That
is not a surprise, but the two ceilings above are new and they decide the
design — feel has to be *authored into the notes*, because the one native feel
mechanism cannot be stocked programmatically.

## 3 · External survey (delta since the 30 Aug audit)

| Candidate | Licence — code / weights / data | Status this pass |
|---|---|---|
| **Groove MIDI Dataset** | **CC-BY-4.0** (LICENSE file in the archive) | **Measured today** (see Verdict §2). Demoted from runtime retrieval engine to **offline profile source**; attribution obligation is a product line, not a blocker |
| **Composer's Assistant 2** | MIT code · author grants output use · training data documented permissive (*reported*, re-checked 30 Aug) | Unchanged. **Still unmeasured on this Mac:** Apple-Silicon latency, blank-project drum quality, extraction from REAPER. Needs a third native door |
| **Anticipatory Music Transformer** | Apache-2.0 code · **weights Apache-2.0** (*reported*, HF model card `stanford-crfm/music-medium-800k`, checked 30 Aug) | **Closes an unmeasured item** from the audit — the hosted-weight terms are selection-compatible. Caveat: trained on Lakh MIDI, whose underlying compositions are scraped; the weights carry no NC clause. Bass/accompaniment only, no text conditioning |
| **Magenta Studio 2.0 / GrooVAE** | Apache-2.0 (*reported*); magenta-js hosted checkpoints still carry no explicit licence in their index | Unchanged verdict. Worth noting it is a **Max for Live device**, i.e. it humanises a clip *inside Live* — but it is UI-triggered, so it is a listening reference, not a backend |
| **MIDI-GPT** | MIT code · **CC-BY-NC-4.0 weights** · GigaMIDI NC terms | Unchanged: benchmark only, never a shipped backend |
| Field sweep for new 2026 permissive symbolic releases | — | **Nothing new.** Searches surface the same tools (Magenta Studio, MIDI Agent, commercial plugins); no new open-weights symbolic drum model has appeared since the audit |

## 4 · Comparison, against the drum story

| Criterion | **DSL + procedural + harvested performance** | GMD retrieval at runtime | CA2 | AMT |
|---|---|---|---|---|
| Prompt coverage ("dusty lo-fi") | Authored grammar — **the whole point of the bet** | **Measured thin**: 30 hiphop, 7 dance, zero lo-fi/trap/house beats ≥ 4 bars | No text conditioning at all | No text conditioning |
| Feel | GMD-derived offsets + Live's own probability/velocity-deviation fields, **measured writable today** | Native (it *is* a performance) | Weak by construction (24 ppq grid, no velocity model) | Weak |
| Surgical edit ("keep the snare") | **Best** — recompile the stored pattern | Lane-local transforms only | **Strong interface**, unmeasured quality | Infill only |
| Dependency / doors | **None** — pure Elixir | A 3.26 MB data file + attribution | Third native door + PyTorch | Third native door + PyTorch |
| Licence | Seshat-owned; CC-BY-4.0 attribution for harvested profiles | CC-BY-4.0 attribution, *per returned performance* | Clean (reported) | Clean (reported) |
| Latency | Instant | Instant | Unmeasured; kill above ~10 s | Unmeasured |
| Main risk | **"Correct but corny"** — unmeasured until heard | Sameness; no coverage for the target styles | Blank-project drums; packaging | Register/harmony repair dominating |
| Role | **First solution** | **Offline donor** to the first solution | Later specialist (infill/revision) | Later specialist (bass) |

Wiring: the DSL lane chains cleanly into the existing path —
`create_track` → device from the catalog → one `add/notes_extended` per lane,
all inside one handler-owned undo step. Neither neural candidate breaks that,
but both add a process, a deadline and a failure mode between plan and write.

## 5 · The experiment that could still overturn this

The verdict rests on capability and licence evidence, which is settled. What is
**not** settled is whether an authored grammar sounds idiomatic. That is one
by-ear check, and it belongs inside the first solution's own delivery rather
than ahead of it:

- **Slate:** 8 prompts fixed before generation, across four styles, at 4 and 8
  bars, one requiring a fill and one a dropout; three takes each.
- **Judged:** blind, in Live, through the same instruments, on keep/delete
  preference, groove, prompt match and edit compliance.
- **Controlled A/B on the same skeleton:** raw grid vs. harvested performance
  layer vs. an assigned Live groove — this is the measurement that says whether
  feel comes from composition, post-processing, or both.
- **Overturns the verdict if:** the grammar compiles reliably but listeners
  consistently call it mechanical *and* the performance layer does not close
  the gap. Then, and only then, a neural specialist earns its process door,
  with CA2's contextual-infill arm first and AMT for bass.

## 6 · What remains unmeasured

- Whether Claude emits the grammar reliably across the fixed slate.
- Whether the harvested profiles sound idiomatic transplanted onto composed
  patterns (the by-ear check above).
- **Whether Live *persists* `probability` / `velocity_deviation` /
  `release_velocity` as sent** — today's probe proves the eight-field write is
  *accepted* and that the notes land; reading the values back needs
  `get/notes_extended` through a tool, which does not exist yet. `API.md`
  already carries this as a ⚠️.
- GMD's Roland TD-11 pitch map → Live drum-rack mapping (documented upstream;
  a small chore, not a risk).
- CA2 on Apple Silicon: latency, blank drums, REAPER extraction.
- Whether an assigned Live groove improves or homogenises the result.
- Multi-listener agreement; one listener ranks personal usefulness only.

## 7 · Fork-side follow-up this pass generated

- `API.md`'s ⚠️ on `add/notes_extended` can be narrowed: an eight-field write
  with non-default `probability` and `velocity_deviation` was **accepted and
  landed** on Live 12.4.5, 2026-08-30. Wire facts belong to the fork — record
  it there, not here.
- The tier-1 finding that `Live.GroovePool` has **no member that adds a
  groove**, and that the tier-1 `Live.Browser` root list has no grooves root,
  is a `FORK_GAPS.md`-shaped fact about a **Live ceiling** rather than a fork
  gap. Worth stating there so nobody plans "load a groove from the browser"
  again.

## Sources

- Local, measured 2026-08-30 on this Mac against Live 12.4.5: tier-1 strings
  from `Live` binary; `Core Library/Grooves` file counts; running-set groove
  pool via `/live/song/get/groove_pool`; eight-field `add/notes_extended`
  probe; GMD statistics over `info.csv` and a minimal SMF parser.
- [Groove MIDI Dataset](https://magenta.tensorflow.org/datasets/groove) (CC-BY-4.0)
- [Composer's Assistant 2](https://github.com/m-malandro/composers-assistant-REAPER)
- [Anticipatory Music Transformer](https://github.com/jthickstun/anticipation) ·
  [weights](https://huggingface.co/stanford-crfm/music-medium-800k)
- [Magenta Studio](https://magenta.withgoogle.com/studio/)
- Siblings: [symbolic-midi-strategy-options.md](symbolic-midi-strategy-options.md) ·
  [midi-generation-options.md](midi-generation-options.md) ·
  [live-native-options.md](live-native-options.md) ·
  [music-generation-user-stories.md](music-generation-user-stories.md)
