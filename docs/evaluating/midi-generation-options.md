# MIDI generation — from a described part to notes that feel played

_Research & options doc · 26–27 Aug 2026 · answers
[midi-generation-research-brief.md](midi-generation-research-brief.md) · may
feed [ROADMAP.md](../ROADMAP.md) after the listening gate; decides nothing by
itself._

The product-level outcomes and acceptance criteria are in
[music-generation-user-stories.md](music-generation-user-stories.md). This
document evaluates ways to achieve them; it does not redefine them around a
candidate's limitations.

The product document also settles four boundaries this research previously
left open: one multi-part request is one high-level tool and one undo step;
separate MIDI parts are the default; MIDI is the default output; and the first
context-aware release reads Session-view MIDI clips rather than claiming to
understand existing audio or Arrangement material.

The brief's premise, settled 2026-08-25 and not relitigated here: Claude
composing notes directly through `write_midi_notes` failed on **feel** —
uniform velocities, grid-locked timing, pitch-guessing against instruments it
cannot hear. This doc asks who should compose instead, and grounds the answer
in **measurements taken on this Mac on 2026-08-26**, not in demo pages.

Everything below marked "measured" was run here, in throwaway environments
under the session scratchpad, against the four SA3 spike WAVs already in
`~/.seshat/audio-spike/`. Everything marked "reported" comes from a paper or
a repo and was not reproduced. Where a spike failed, the failure is reported
as a failure — a one-hour spike is not a verdict on a model, and each such
case says what would settle it.

The document received a source and reasoning audit on 2026-08-27. It added
MIDILM, MetaScore, Agogic, and PerTok; ran GrooVAE locally; identified the
absent ADTOF-pytorch licence; and expanded the use case from isolated parts
to interacting multi-part requests. The current framing separates two
choices that earlier drafts conflated: the backend that produces each part
and the wiring between parts. Measurements establish feasibility and
constraints, not which final MIDI sounds best.

---

## Verdict up front

**No route has earned a product recommendation yet.** Note counts, pitch
ranges, onset offsets, and latency prove that plumbing is plausible; they do
not prove that the resulting MIDI sounds good. The product output is MIDI in
Live, so the deciding comparison must be the final rendered MIDI—not source
audio, model architecture, or proxy statistics.

That is why there is no generation implementation epic on the roadmap yet.
The roadmap now tracks only the independently real large-datagram defect; the
listening gate must select a product route before implementation is ranked.

### The design space is two axes, not a list of routes

Earlier versions of this document listed competing "routes" and then
competing "arms." That conflated two decisions and obscured the experiment.
There are two independent choices:

**Axis 1 — backend per part.** Where does each part's material come from?
Drums: Route D retrieval (GMD), Route D generative (GrooVAE), or Route C
(SA3 → drum transcription). Bass: Route C (SA3 → Basic Pitch), or a rule
engine driven by Claude's harmonic choices.

**Axis 2 — wiring.** How do the parts of one multi-part request relate?

| Wiring | Mechanism | Verdict |
|---|---|---|
| **Independent** | Parts share tempo, key and a style brief; neither sees the other's notes | **Required baseline.** It has no direct interlock mechanism, but establishes whether the added conditioning complexity produces an audible improvement |
| **Conditioned** (§E) | Drums generated first — symbolic from every backend — then the bass responds to the actual kick and snare positions | **Untested hypothesis.** Cheap and compatible with any drum backend, but it may sound mechanically aligned rather than jointly played |
| **Joint, then separated** | One SA3 render containing both parts, then source separation and two transcription passes | **Live hypothesis, unmeasured.** Highest possible interaction ceiling, because the model authors the interplay; the risk is losing it in extraction, and it needs a separator this survey never spiked |

One cheap conditioned candidate combines **Route D retrieval for drums with
a rule-derived bass rhythm**. Retrieval supplies exact human kick positions
rather than estimated onsets, but the musical quality of the derived bass is
unmeasured and its pitch, velocity, and articulation rules are a separate
backend choice. It is an experiment arm, not a recommendation. See §E.

| Route | What the evidence establishes | What remains unknown |
|---|---|---|
| **Route C** (SA3 → transcription) | Bass and chord transcription run locally within budget and produce structurally plausible notes; an ADTOF proof of concept produced GM drum notes in 0.14 s | Musical correctness and feel; IDM's local behavior; whether joint generation survives separation |
| **Route D** (GMD retrieval / GrooVAE) | GrooVAE has published drummer-comparison listening evidence; GMD is exact human performance, 3.11 MB, CC-BY-4.0; measured local timing and dynamics | Free-text fidelity — whether a finite genre vocabulary can serve requests like "dusty lo-fi" |
| **Route A** | Three runnable candidates missed the brief's quality/latency needs; the most relevant new candidates have no released weights | Whether Agogic or MIDILM becomes viable when artifacts appear |
| **Route B** | No qualifying supported self-serve MIDI-generation API was found | Whether a suitable service appears later |

The decision work has two layers: controlled comparisons that change one
factor where possible, and a product bake-off between complete pipelines.
Those complete pipelines necessarily change more than wiring, so their
results decide what to ship but cannot by themselves explain why it won.
Route C must not be ranked below Route D before the test — its joint lane may
produce the most musical interaction, or may lose it in extraction. Both
remain unmeasured.

**Route A (local symbolic models) is not ready for this job today.** Three
candidates were installed and run here. All three produced material that
would fail the same ear test Claude-composition failed, at latencies of
1–48 s. The two strongest new papers cannot be run: MIDILM requires a
checkpoint its repo does not provide, and Agogic explicitly lists its
tokenizer and checkpoints as not yet released. Details in §A.

**Route B (a service API) is a non-route.** As of today no product exposes
MIDI *generation* over a self-serve API — AIVA, Staccato and Lemonaide are
GUI/plugin products, and the only APIs in this space transcribe audio rather
than compose. Nothing to weigh against the no-API-key posture, so the posture
is not even tested. §B.

**Route C is a finalist for bass, harmony, drums, and jointly generated
parts—not yet a ship decision.** Its ceiling is SA3's musical quality, which
nobody has judged by ear yet. The local spike left exactly that question open
([audio-generation-options.md](audio-generation-options.md) — "Still open,
ears required"). Route C inherits it wholesale: transcription is
demonstrably cheap and structurally plausible, but correctness and retained
groove are not established; it
cannot rescue material that doesn't groove. **The prerequisite spikes plus
one blinded listening slate can settle both the audio and MIDI decisions** — that is the
highest-value next action in this document. The measured `ADTOF-pytorch`
port carries no licence and is not a
shipping candidate. **Inverse Drum Machine (IDM; Apache-2.0 repository with
bundled weights) is the preferred permissive candidate**, but it must pass a
small local spike before any Route C drum candidate enters the decision
experiment. See §C.1.

---

## What Route C actually is, end to end

```
"dark garage bassline, four bars, sparse"
        │  Claude translates intent → SA3 prompt idiom + bar count
        ▼
Stable Audio 3 (already installed, ~/.seshat/stable-audio-3)   1.0–3.8 s
        │  bar-exact WAV (measured to the sample in the audio evidence)
        ▼
transcriber:  IDM (drums; unmeasured locally) | Basic Pitch (bass/chords) 0.06 s
        │  note list: pitch, onset (s), duration, + confidence/amplitude
        ▼
velocity mapping: IDM native velocities | Basic Pitch amplitude
        │  seconds → beats using Session.State tempo
        ▼
write_midi_notes  →  clip in Live
```

**Measured pitched-material total: 1.1–3.9 s of model compute**, against the
roughly 10-second compute budget: 1.0–3.8 s for SA3 plus 0.06 s for Basic
Pitch. This is not an end-to-end product latency measurement: track creation,
catalog search, device loading, clip writing, and verification in Live were
not timed, and a multi-part plan must measure them together. The earlier
ADTOF drum proof of concept took 0.14–0.76 s, but no end-to-end drum total is
claimed for IDM until it is run locally. Basic Pitch's ONNX model is
**225 KB**; IDM is reported as ~100× smaller than supervised baselines, but
its installed footprint is also unmeasured here.

And the route inherits, for free, the two things the brief says matter most:
SA3's proven free-text conditioning (nothing to translate into a knob
vocabulary), and whatever groove the audio model actually has.

---

## Route A — specialized symbolic models, run locally

### A.1 The candidate field

| Model | Interface | Material evidence | Local story | License | Health |
|---|---|---|---|---|---|
| **MIDI-GPT** (Metacreation, AAAI'25) | Attribute knobs + per-track/per-bar infill; 18-genre enum; **`track_type="drum"`** | GigaMIDI-trained (28% drum tracks); no rhythm-section listening test published | **Measured**: pip wheels for py3.10–3.12, 587 MB env, warm load 1.1 s, 4-bar 2-track gen 0.7–8.9 s CPU | Code MIT, **weights CC-BY-NC-4.0** | **Alive** — 0.3.4 published 2026-08-19, six releases since June |
| **text2midi** (AMAAI, AAAI'25) | **Free text** through flan-T5 | MidiCaps = captions of *whole pieces*; reported key accuracy 33.6%, chord match 2.50/7 | **Measured**: 775 MB weights, warm load 1.8 s, **47.5 s for 500 tokens on MPS** | MIT | Static since the paper; 26 commits |
| **MIDI-LLM** (ISMIR'26) | **Free text**, Llama-3.2-1B + AMT MIDI vocab | Reported FAD **0.173 vs text2midi 0.818**, CLAP **22.1 vs 18.7**; no listening study | **Measured**: 2.5 GB weights, warm load 4.7 s, **10.6 s / 512 tokens, 18.5 s / 1024 on MPS**; transformers path needs a logits fix (below) | Llama-3.2 community terms | New (Nov 2025 preprint, ISMIR'26) |
| **MIDILM** (AAAI'26) | **Free text**, GPT-2 encoder + 1.67B dual-path MoE decoder | Best published listening result here: MOS **3.23 vs 2.49** for Text2MIDI-InferAlign on MidiCaps; **3.34 vs 3.30** on free-form prompts. Still whole-piece evaluation, not production loops | CUDA 12 recommended; code requires `--midilm_ckpt`, but the repo links no checkpoint, so Apple inference is presently **unverifiable** | Code MIT; weight licence unavailable because weights are unavailable | 16 commits, 3 stars, no release |
| **Agogic / PMT** (Aug 2026 preprint) | Free-text prefix + optional decode-time instrument/key constraints | The first candidate built around **10 ms microtiming and per-note velocity**; 0.8B PMT beats a 27B beat-grid model on distributional FMD. Authors explicitly say audibility is unproven; human study only pre-registered | Intended 0.8B–27B Qwen3.5 checkpoints; **tokenizer and all checkpoints not yet released**, so local speed and licence are unverifiable | Unstated pending artifact release | One-commit placeholder repo; watch, do not integrate |
| **MetaScore model** (ISMIR'25) | Free text or a fixed tag path (genre, instruments, composer, complexity) | Expert-musician listening test reportedly comparable to Text2MIDI; score corpus and whole-piece target do not establish groove or loop quality | No public inference package or checkpoint found | Only public-domain subset promised for redistribution; remaining data research-only/by request | Dataset/paper contribution, not a deployable dependency |
| **PerTok / Cadenza** (Lemonaide, Oct 2024) | Variation of a supplied musical idea, not free text | Tokenizer models **microtiming and velocity explicitly** (Macro/Micro time split, `MicroTime` token); paper reports objective *and* listening evaluation | **Tokenizer shipped and installable** — `pertok.py` in MidiTok (latest 3.0.6.post1, verified 2026-08-27). The Cadenza models behind it are Lemonaide's product; no public checkpoint found | MidiTok MIT; model weights not published | Tokenizer alive in a maintained library; models closed |
| Anticipatory Music Transformer (Stanford, 2023) | Infill/accompaniment, no text | Lakh MIDI; piano-centric demos | CPU-class; supplies the token vocab MIDI-LLM reuses | Apache-2.0 | Static, but a dependable dependency |
| NotaGen (IJCAI'25) | "period-composer-instrumentation" prompt | **Classical sheet music**; A/B tests vs human compositions | ABC notation, not performance MIDI | — | Alive but wrong material — the brief's cherry-picked-classical trap, exactly |
| MusicLang Predict | Chord-progression templates | LAKH CC0 | pip | — | **Dormant** — last PyPI release 2024-03-20 |
| Muzic (GETMusic / MuseCoco) | Track-role diffusion / text→attributes→music | Research code | Heavy | MIT | Research-grade; MuseCoco's *architecture* is the interesting part (see §D) |
| SkyTNT midi-model | Instrument/tempo/key knobs, MIDI prompt | Community favourite; ONNX builds exist | Apache-2.0 | Apache-2.0 | Alive |
| Magenta (GrooVAE, MusicVAE) | Humanize / drumify | The GrooVAE lineage is still the reference for *feel* | Python repo **archived read-only 2026-01-06**; the magenta.js checkpoints are **still live** (verified: `groovae_2bar_humanize/config.json` → HTTP 200) | Apache-2.0 | Dead in Python, alive in JS |

Two late candidates improve the research outlook without changing today's
build decision. MIDILM's test-set MOS is a real advance, but its free-form
advantage is only 0.045 MOS and it cannot be run without the missing weights.
Agogic attacks the right representation problem and supplies the strongest
reason to revisit Route A: it preserves performance timing rather than
quantizing feel away. It is not, however, *first* to that idea — PerTok
(Oct 2024) encodes microtiming and per-note velocity explicitly, was
evaluated with listening tests, and unlike Agogic has actually shipped, as a
tokenizer inside MidiTok. What Agogic adds is the free-text front end and the
scaling result; the representation insight predates it, and the shipped
tokenizer is available to anyone who ever wants to fine-tune something small
on this axis. Its own paper is admirably explicit that (a) caption
adherence is weak without constraints, (b) published text-to-MIDI models can
reproduce their training distribution almost independently of the caption,
and (c) its FMD gain has not yet been shown audible. It is a watch item, not
evidence to ship.

### A.2 MIDI-GPT — the right interface, and what came out of it

This is the candidate the brief's "knob model is not disqualified" clause was
written for, and the one worth the most words.

**The interface is genuinely expressive** for a Claude-as-translator design.
Discovered at runtime from the installed package:

- Per-track: `track_type` ∈ {`melodic`, `drum`}, GM `instrument`, and a
  checkpoint-dependent attribute set — measured on `expressive_medium`:
  `key_signature` (25 bins), `pitch_range` (128), `silence_proportion` (10),
  `min/max_note_duration` (6 each, labelled `32nd`…`whole`),
  `bar_note_density` (10 quantiles, **drum-typed**),
  `bar_min/max_polyphony` (10), `pitch_class_set` (13), `nomml` (13).
- Piece-level controls: `velocity` on/off, `microtiming` on/off, and
  `genre` — an 18-item enum: `asian, baroque, blues, christian, classical,
  country, dance-electronic, european, folk, hip-hop, jazz, latin, metal,
  pop, punk, renaissance, rock, soundtrack`.
- Bar-level infill, per-bar attribute overrides, autoregressive from-scratch
  generation, an HTTP server, **and an OSC server**.

**What the interface cannot express** matters as much: "dark UK garage" has
to become `dance-electronic`, and "sparse, swung, broken" has to become
density quantiles and a `nomml` bin. That is the ceiling the brief asked to
be stated: this is a *taxonomy* interface, and its taxonomy is GigaMIDI's
genre labels, which are coarse where this project's users are specific.

`nomml` deserves a note — it is GigaMIDI's **note onset median metric level**
heuristic, the same feature the dataset paper uses to split expressively-
performed tracks (31% of the corpus) from non-expressive ones. As a knob it
is, in principle, exactly a "how played does this feel" dial.

**What actually came out (measured, `midigpt` 0.3.4, CPU, seed 42):**

| Run | Result |
|---|---|
| `expressive_medium`, 4 bars, drums + bass, full-AR | 8.9 s; drums 119 notes, bass 25; **every velocity 0**; 84/119 drum notes carried non-zero microtiming deltas |
| Same + `genre` control | 0.7 s; collapses to 14 notes; velocities all 100 |
| Same at `bar_note_density` 2 / 5 / 8 | **Byte-identical output** — the bar-level density attribute had no observable effect on a full-AR track |
| `prism_medium`, 4 bars, drums + bass | 1.5 s; **velocities vary (17 distinct, 14–101)**; but drum pitch histogram is `{51: 37, 40: 5, 36: 3, 52: 1}` — a ride cymbal played 37 times, three kicks, no hats; the bass track's most common pitch is **127** (G9), ten times |
| `prism_medium` + `genre="hip-hop"`, drums | 6.2 s; 72 notes on pitches `{28: 42, 85: 12, 94: 3, …}` — **outside the GM drum map entirely** |
| `expressive_medium` infill: I seeded bar 0 with a real kick/snare/hat pattern at velocities 110/95/90 and asked for bars 1–3 | 0.15 s; bars 1–3 came back with **one note each**; and the context bar I supplied **read back with all velocities 0** |
| `yellow_medium`, 4 bars | 1.1 s; all velocities 121 |

Two of those lines are the whole story. The velocity round-trip losing notes
I supplied myself says the problem is in the pipeline, not in the model's
taste — `expressive_medium`'s vocab does contain a 128-value `VelocityLevel`
domain and `switchable_velocity: true`. And `prism_medium` shows the
opposite half: real velocity variation, no microtiming (its encoder has
`switchable_microtiming: false`), and content that isn't a drum pattern.

**Read this as a historical spike result, not a candidate.** midigpt 0.3.4 is seven days
old; the reference caller is the lab's own MMM Studio, not this script; and
full-AR-from-an-empty-`Score` is the least-travelled path through a package
built for infilling an existing arrangement. Its CC-BY-NC-4.0 weights
disqualify it under Seshat's distribution rule regardless of whether a better
caller improves quality. Revisit only if commercially compatible weights or
rights appear; do not spend another spike while the licence remains unchanged.

### A.3 text2midi and MIDI-LLM — the free-text lane

Both were installed and run here. Both are too slow on this machine, and
both answered a loop request with a full arrangement.

**text2midi** (272 M params), prompted with _"A dark UK garage bassline in F
minor at 130 BPM, sparse, played on electric bass, with a swung 2-step drum
groove."_:

- **47.5 s for 500 tokens** on MPS (≈10 tok/s). The repo's own default is
  2 000 tokens — call it three minutes for a default generation. **5× over
  budget at a quarter of the default length.**
- Output: **8 tracks** (strings, guitars, a piano, a drum kit) at **121.3 BPM
  when asked for 130**, tpq 24. Per-track velocity was constant (99, 99, 99,
  …); only the drum track varied, with 3 distinct values.
- The drum track did land on GM pitches (35–57), which is the one encouraging
  detail.

**MIDI-LLM** (Llama-3.2-1B with 55 030 MIDI tokens grafted on), same prompt:

- **10.6 s / 512 tokens, 18.5 s / 1024 tokens** on MPS at bf16 (≈48 tok/s).
  The paper reports 10.0 s for 2 048 tokens on an L40S; this Mac is ~4×
  slower, which puts a paper-default generation at ~40 s.
- **The shipped `generate_transformers.py` cannot produce a file on this
  path**: it samples over the full Llama vocabulary, so text tokens land in
  the MIDI stream and `anticipation`'s decoder asserts. (The vLLM path masks
  to `allowed_token_ids`; the transformers path doesn't.) With a 20-line
  logits mask added here, the 512-token generation decoded; the 1024-token
  one still failed.
- The one decodable sample: a single drum track, 170 notes, GM pitches 35–76
  — and **every velocity 72**.

The reported quality numbers (FAD 0.173 vs 0.818; CLAP 22.1 vs 18.7) say
MIDI-LLM is the better free-text model, and it probably is. But on this
machine it is a 10–40 s dependency with a decode path that needs patching,
and its one legible output reproduced the uniform-velocity failure this
whole project exists to escape.

### A.4 The trap the brief predicted, confirmed

Captioned-MIDI training data describes **pieces**, so these models generate
**pieces**. Asked for a bassline and a drum groove, text2midi returned eight
tracks of arrangement; MIDI-LLM returned a full kit performance. Nothing in
either interface says "four bars, one part, loopable." Route C gets that for
free, because SA3 takes a duration in seconds and trims to it.

---

## Route B — a service API

Checked: AIVA, Staccato, Lemonaide, Hooktheory, Klangio, and the current crop
of "AI music API" aggregators.

- **AIVA** exports MIDI and has no public developer API — its own site
  advertises MP3/MIDI *downloads* on subscription tiers, and 2026 review
  coverage describes API access as an enterprise conversation, not a
  self-serve product.
- **Staccato** is a DAW plugin plus a web dashboard ("up to 16 tracks and 32
  bars at once", "100% royalty-free"). No API, no automation surface.
- **Lemonaide** is a plugin plus an artist-model marketplace. No API.
- **Klangio** does have a real developer API — for **transcription**
  (audio → MIDI/MusicXML, piano/guitar/bass/vocals, plus a `Drum2Notes`
  product), not generation. It is a paid, cloud version of Route C's second
  stage, and the measured Basic Pitch second stage already runs here in 0.06 s.
- The "AI music API" aggregators sell audio generation (Suno-adjacent
  models, stems, WAV). One advertises audio→MIDI conversion at ~$0.08 a
  generation. None generate symbolic music from text.

**Conclusion: no qualifying self-serve API was found.** That is narrower and
more defensible than claiming no private or enterprise API exists. The
official AIVA surface advertises complete-song generation and MIDI downloads
(€11/month Standard, €33/month Pro when billed annually), not a developer
endpoint. Staccato advertises text-refined MIDI in its DAW plugin
($14.99/month Pro), not an HTTP API. Hooktheory's Aria generates chords and
melodies inside Hookpad and is powered by Anticipatory Music Transformer, but
again exposes no supported automation API. None can sit behind a Seshat tool
without GUI automation or a private commercial agreement, both worse than
the local paths. Re-check if a service appears that takes free text and
returns *one requested part* rather than a complete arrangement.

---

## Route C — generate audio locally, transcribe to MIDI

### C.1 Drum transcription — what the route can do, and which tool does it

**The preferred candidate for this slot is Inverse Drum Machine (IDM), not
`ADTOF-pytorch`.** The measurements in this section were taken with
ADTOF-pytorch because it was already installed. They prove that an
SA3→drum-MIDI pipeline is technically plausible and expose failure modes the
product must handle; they do **not** establish IDM's latency, class coverage,
accuracy, dynamics, or behavior on the same audio.

**Licence disqualifies at selection time.** Seshat intends eventual
distribution, so a component that cannot be redistributed is ruled out when
it is chosen, not when it ships — otherwise the pipeline, its tests and its
tool contract get built around something that has to be removed. CLAUDE.md's
"not in production" rule is about backwards compatibility, not dependencies,
and does not soften this.

Why IDM is the candidate to spike, with no case for shipping the alternative:

- **Licence.** IDM's repository and its bundled checkpoint are both
  Apache-2.0 (verified 2026-08-27). `ADTOF-pytorch` contains no licence file
  and no grant of any kind — not an unclear licence, an absent one — and
  upstream ADTOF is CC-BY-NC-SA-4.0.
- **Velocity is native.** IDM predicts onsets and per-hit velocities jointly,
  where ADTOF hardcodes velocity 100 and needs the STFT workaround below.
  Learned velocities should also be better calibrated than a band-limited
  peak measurement.
- **It does strictly more.** Analysis-by-synthesis gives per-drum stems as a
  byproduct — useful for §C.5's per-instrument tracks.

The arguments for keeping ADTOF-pytorch do not survive inspection: "it is
already measured" argues against re-spiking, not for shipping; "it may
generalise better to degraded lo-fi audio, having trained on real recordings
rather than kit mixtures" is speculation and is an argument for *testing*
IDM; and its lighter dependency footprint is unverified and, for a model this
small, resolvable by extracting a minimal inference path.

**What IDM still has to prove locally:** speed and install weight on this machine, its
class vocabulary and GM mapping, and above all its behaviour on SA3's
deliberately degraded material — its own README warns that out-of-distribution
loops transcribe poorly, which is the same failure already measured below.
Its evaluation code is a stated TODO, so its published figures cannot be
reproduced here yet.

**Spike IDM before the decision experiment.** Conditioned/C, independent/C,
and joint-C all require a drum transcriber, so the ear gate cannot compare
them honestly using ADTOF measurements or the unlicensed ADTOF artifact. The
spike is intentionally narrow: run the same three drum WAVs below, record
latency/install weight/classes/GM mapping, and render its MIDI beside the
ADTOF proof of concept. If IDM fails, replace it with another permissive
candidate or remove Route C drums before the bake-off.

The measurements below were taken with `ADTOF-pytorch` (a port of ADTOF that
drops the madmom and TensorFlow dependencies down to torch + librosa +
pretty_midi; reported F-measure 88.51 vs the original's 88.74 on
MDBDrums++), on the SA3 spike WAVs:

| Clip | Time | Notes | Pitches | Onset deviation from the 16th grid |
|---|---|---|---|---|
| `drums_124bpm_medium.wav` | **0.14 s** | 60 | hat 42 ×34, snare 38 ×16, kick 35 ×10 | median **4.3 ms**, max 14.5 ms (a 16th = 121 ms) |
| `drums_90bpm_medium.wav` | 0.21 s | 72 | hat ×49, kick ×15, snare ×8 | median 28.2 ms, max 58.7 ms |
| `drums_124bpm_sm-music.wav` | 0.76 s (cold) | **0** | — | **silent failure** |

Three findings, in order of importance:

1. **The transcriber's output mapping is GM by construction.** ADTOF's five classes
   are hardcoded to `[35, 38, 47, 42, 49]` — kick, snare, mid tom, closed
   hat, crash. Output is GM-standard on arrival. (Where it lands on the
   *user's* rack is a separate problem — see the open questions.)
2. **Velocity is constant 100, by construction** — the port writes
   `velocity=100` for every onset. That would reproduce the exact failure
   this project replaces, so I tested whether the dynamics are recoverable
   from the audio the onsets came from: band-limited STFT peak in a ~35 ms
   window at each onset, per drum class, normalised per class. Measured on
   the 124 BPM clip: **27 distinct hi-hat velocities (40–126), 11 snare, 10
   kick**, in well under a second, in about 40 lines. The feel is in the
   WAV; the transcriber just doesn't carry it across.
3. **A clip can transcribe to nothing.** `sm-music`'s 124 BPM drum clip
   produced zero notes. Any tool built on this needs a note-count sanity
   check and a defined behaviour when it fails (re-generate with a different
   seed, escalate to `medium`, or say so) — never a silent empty clip.

On the two deviation figures: 4.3 ms says the *transcribed onsets* in the 124
BPM clip are tight to the grid; it does not establish transcription accuracy.
The 28.2 ms result at 90 BPM is either real looseness in the audio, a downbeat
offset, or transcription error, and **nothing in these numbers separates
groove from error**. That distinction needs a human ear, or ground truth
that does not exist here. It is also the argument for keeping `quantize_clip`
downstream: partial-strength quantise is exactly the "keep some of it" knob.

**Inverse Drum Machine**, the preferred candidate, reported not measured:
TASLP 2026,
joint transcription and one-shot synthesis, frame-level onsets *and*
velocities, ~100× fewer parameters than supervised baselines, Apache-2.0
weights bundled. Its velocities replace the STFT workaround above; its
per-drum stems are a bonus for §C.5.

**Neither ADTOF nor its PyTorch port is a fallback**, and it is worth being
exact about why: the disqualifier is the licence, not the quality. The port
grants nothing at all; upstream ADTOF is CC-BY-NC-SA-4.0. That holds however
well either transcribes SA3's material, so "ADTOF generalises better to
degraded audio" — plausible, since it trained on real recordings rather than
kit mixtures — cannot bring it back. It appears in this document only as the
tool that produced the numbers above, before the licence was checked.

If IDM's spike shows it cannot handle this material, the options are a
different cleanly-licensed transcriber (**Noise-to-Notes**, diffusion ADT,
Sept 2025, is the next one to look at), or dropping Route C drums — which the
ear gate may do anyway.

### C.2 Bass, chords, pads — Basic Pitch

Spotify's Basic Pitch, Apache-2.0, ONNX model **225 KB**. Measured:

| Clip | Time | Notes | Pitch range | Amplitude (velocity proxy) |
|---|---|---|---|---|
| `bass_124bpm_medium.wav` | **0.06 s** | 16 | **29–36** (F1–C2) | 0.38–0.55, 10 distinct |
| `bass_124bpm_sm-music.wav` | 0.06 s | 30 | 29–65 | 0.28–0.43, 14 distinct |
| `pad_124bpm_medium.wav` | 0.06 s | 51 | 50–83 | 0.32–0.75, 28 distinct |
| `drums_124bpm_sm-music.wav` | 0.06 s | 31 | 29–74 — **pitched nonsense** | — |

- **Bass from the `medium` model is the strongest result in this document**:
  16 notes in a two-octave bass register, monophonic in shape, transcribed in
  6/100 of a second. The same prompt on `sm-music` smeared across 29–65,
  picking up harmonics — evidence that model choice matters more for
  transcribability than for listening.
- **Pads transcribe plausibly** but polyphonic voicing accuracy is where
  Basic Pitch is weakest by reputation; snapping to `Session.State`'s
  key/scale is the obvious cleanup and costs nothing.
- **Do not point Basic Pitch at drums.** It reports drum hits as pitched
  notes (45, 48, 29, 65…) — the pitch-mapping trap in its purest form.
- Velocity survives as `amplitude` per note, and it varies. Free dynamics.

Two ecosystem warnings, both hit here: Basic Pitch's last release is
**2024-08-16** and it calls `scipy.signal.gaussian`, **removed in SciPy
1.13** — the install works and then explodes at note-creation time until
scipy is pinned below 1.13. Its TensorFlow pin also excludes Python 3.12, so
pip resolves an older version; the working configuration measured here was
`onnxruntime` + the bundled `nmp.onnx`, which sidesteps TensorFlow entirely
and takes the install from **1.5 GB to ~50 MB**. If this route ships,
vendoring the 225 KB ONNX file and calling onnxruntime directly is likely
better than depending on the package.

### C.3 Prompt implications

The brief asked whether material generated *for transcription* wants
different prompts. The evidence says yes, and cheaply:

- **Isolation beats realism.** The bass prompt that transcribed cleanly was
  the one where bass dominated the mix. Any drum bleed becomes phantom
  pitched notes. "solo bass, DI, dry, no drums, no reverb" is the idiom to
  test — and the local runtime's `--negative-prompt` (which the hosted API
  lacks) exists for precisely this.
- **Reverb and saturation are transcription noise**, not character, at this
  stage — the character can be added by the Live device chain afterwards,
  where it's editable.
- Tempo-in-prompt stays as the audio evidence established it; nothing here
  changes that.

### C.4 Where the WAV goes

Keep it. Use the managed folder and direct import shape proposed in the audio
evidence; a generation that produces both a clip of notes *and* the audio it came from
gives the user an A/B and a fallback when the transcription is wrong. The
cost is disk. Discarding it makes the failure mode ("that's not what I
heard") unrecoverable.

### C.5 One track per drum instrument

Added 2026-08-27, from a use case raised after the audit: _"dusty lo-fi
beat"_ should land as **a MIDI track per kit piece** — kick on one track,
snare on another, hats on a third — not one clip holding all of them.

**The split itself is free, and it is not source separation.** Every drum
transcriber emits *labelled* onsets, so splitting is a group-by on the
label, in about ten lines. Measured on the already-transcribed
`drums_124bpm_medium.wav`, with the velocity pass from §C.1 applied per lane:

| Lane | GM | Notes | Velocity | 16th positions used (of 16 per bar) |
|---|---|---|---|---|
| Closed Hat | 42 | 34 | 40–126, **27 distinct** | 0, 2, 4, 6, 8, 10, 12, 13, 14, 15 |
| Snare | 38 | 16 | 40–126, **11 distinct** | 4, 7, 9, 12 |
| Kick | 35 | 10 | 40–126, **10 distinct** | 0, 6, 10, 13 |

That table is also the first evidence in this document that the transcribed
material has *musical structure* and not just plausible statistics: the
snare sits on 4 and 12 (the backbeat) with ghost placements at 7 and 9; the
hats run straight 8ths and then break into 16ths at 13–15, at the turnaround.
Per-lane velocity recovery is what makes each of those tracks playable on its
own — a hat track at a single velocity is unusable in a way a mixed clip can
partly hide.

**The ceiling is the transcriber's class vocabulary, and it binds here.**

- **Route C transcription gives few lanes** — the vocabulary measured here
  was five (kick 35, snare 38, tom 47, closed hat 42, crash 49), and this
  clip produced three. Open hat, rim, clap, shaker, ride and percussion had
  nowhere to go: they fold into a neighbouring class or vanish. For lo-fi
  specifically that is a real loss, since open hat and shaker/perc are
  load-bearing in the genre. **How many lanes IDM emits is unverified** and
  is one of the things its spike must establish — a wider vocabulary would
  narrow this gap, though not close it against GMD's nine canonical lanes.
- **Route D / the Groove MIDI Dataset gives more** — Magenta's published
  mapping lists **22 recorded source pitches**, reduced to nine canonical
  lanes: kick, snare, high tom, low-mid tom, **high floor tom**, closed hat,
  open hat, crash, and ride. The MIDI-only download is **3.11 MB**. Do not
  confuse the measured 27 distinct *velocity values* in the Closed Hat row
  above with a pitch count.

This gives Route D a concrete **editability and lane-coverage advantage** in
the comparison: retrieval hands back more lanes than the measured Route C
transcriber, with human velocity and microtiming already attached, and the
split is the same group-by. It does not establish that Route D sounds better
as part of a bass-and-drums performance. Joint Route C may create better
interplay before transcription; only the final-render comparison can show
whether that advantage survives extraction.

**What this costs on the Live side, and it is not nothing.** N lanes means N
tracks, each needing its own sound selected, instrument loaded, notes written,
and result verified. Exposing those stages as ordinary MCP calls would produce
N × (`create_track` → `search_library` → `load_device` →
`write_midi_notes`) and N × the undo steps. The product contract rejects that
shape: one high-level generation tool must orchestrate the entire request
inside one undo boundary. That does not remove the work or latency; it makes
them one atomic product operation. Two implementation requirements follow:

- **Pitch normalisation per lane.** A per-instrument track usually holds a
  one-shot sampler, which answers to a single playable pitch, not to GM 38.
  Splitting therefore also means *rewriting* each lane's pitches to whatever
  its loaded instrument expects — which is a different problem from the Drum
  Rack pad-mapping gap in the open questions, and slightly easier. That pitch
  must be read back or set explicitly, not assumed: Simpler's root follows the
  sample's original pitch, and `load_device` reports nothing about it.
- **Sound selection per lane.** “Dusty lo-fi” has to influence which kick,
  snare, hat, and bass devices or samples are loaded, not just the notes. The
  existing catalog can supply candidates, but neither this research nor the
  model spikes evaluated contextual preset selection.

Separate per-instrument tracks are the first-release default because that is
the product story being evaluated. A one-Drum-Rack representation can remain a
later option; it should not weaken the split-track acceptance test.

---

## Route D — the fourth shape: groove-first constrained generation

Route D is deliberately narrower than a general MIDI composer: solve drums
well by making **feel the primitive**, then leave pitch-centric material to a
different route. It has two lanes behind one attribute contract.

### D.1 Retrieval lane — human performance with no inference

Magenta's **Groove MIDI Dataset (GMD)** contains 1,150 MIDI files, 13.6
hours, about 22,000 measures, and 10 drummers (80%+ of the duration from hired
professionals) playing to a click. Each performance carries genre, tempo,
beat/fill, time signature, velocity, and microtiming; the MIDI-only download
is 3.11 MB under **CC-BY-4.0**. Its 18 top-level genres include dance,
hip-hop, funk, jazz, pop, reggae, rock, soul, and several world styles.

Claude maps the request into that finite vocabulary plus density and
beat/fill; the engine ranks candidate bars, time-scales the winner, optionally
recombines beat and fill bars, and remaps the Roland TD-11 notes first to GM
and then to the target rack. The source dataset documents several Roland/GM
pitch differences, so "already GM" would be wrong. This lane has near-zero
latency, exact reproducibility, and literal human feel. Its limit is equally
clear: retrieval cannot synthesize a genuinely new garage-specific pattern
from a corpus whose nearest label is `dance`; transformations must earn their
quality in the ear test.

### D.2 Generative lane — tap/pattern skeleton → GrooVAE

GrooVAE was trained on GMD using inverse sequence transformations: strip a
real drum performance down to a quantized/constant-velocity pattern or a
single-drum tap rhythm, then learn to reconstruct the instruments, velocity,
and microtiming. The ICML paper's blind pairwise tests found its Seq2Seq
humanizer preferred over a nearest-neighbour baseline and its Humanize,
Tap2Drum, and infill outputs competitive with held-out real performances.
That is the most directly relevant non-marketing quality evidence found in
this survey.

For Seshat, Claude does not write a finished beat. It translates the request
to a bounded schema (`style`, `density`, `syncopation`, `kick_weight`,
`snare_backbeat`, `hat_activity`, `fill`, `variation`, bars), and a small
deterministic layer turns those controls into either a quantized drum skeleton
or one tapped rhythm. GrooVAE's Humanize model supplies performance; its
Tap2Drum model can also supply kit orchestration. The public checkpoints cover
1–4 bar Tap2Drum and 2-bar humanization, which can be tiled with controlled
variation for the brief's 1–16 bar range.

**Measured here on 2026-08-27:** `@magenta/music` 1.23.1, pure TensorFlow.js
CPU, 4-bar Tap2Drum, 16 constant-velocity eighth-note taps. Two fresh Node
processes loaded the remotely hosted 15.6 MB checkpoint in **3.89–4.03 s**
and decoded in **0.411–0.413 s**. The result had 35 notes, 30 distinct
velocities, and all 35 starts off the exact 16th grid. This proves the local
runtime, latency, dynamics, and microtiming path; it is not a listening test
and the toy input says nothing about prompt fidelity.

The dependency is not ship-ready unchanged. `@magenta/music` installed 170
packages / 254 MB and `npm audit --omit=dev` reported nine production
advisories (four critical, five high), including unresolved advisories in
`protobufjs` and the `static-eval` chain. The old Python repo is archived. A
plan must either extract/port the minimal MusicVAE inference path, update the
dependency tree, or sandbox a pinned runner; it must also verify an explicit
licence for the hosted checkpoint rather than assuming the code's Apache-2.0
licence covers weights. GMD itself is clearly CC-BY-4.0.

### D.3 What Route D does not solve

Do not transfer a drummer's velocity curve mechanically onto bass or keys and
call that human performance; the articulation and phrase hierarchy are
different. Route D is a strong drum finalist, not an overall winner. Bass and
harmony remain Route C experiments; a bounded rule-derived bass is an
additional baseline, not a proven replacement. A performance-aware symbolic
model such as Agogic may add another option when it becomes runnable, while
combined bass-and-drums generation requires the comparison below.

There is a design precedent worth keeping: Microsoft's **MuseCoco** performs
text → musical attributes → music as two explicit stages. Whatever backend
ships, the **attribute layer in the middle** should be the stable seam. It lets
Claude translate language without making Claude compose, and it lets GMD,
GrooVAE, Route C, or a future Agogic checkpoint sit behind the same tool
contract.

---

## E — Multi-part requests: ordering as a design primitive

Every version of this document before this one answered the question "which
backend for which material," and none answered "what happens when one request
names two parts." That framing came from the brief's per-material priority
list and survived three revisions unchallenged. It is the wrong default:
**"a dusty lo-fi beat with a bassline" is the main case, not an edge case**,
and a per-material recommendation says nothing about it.

**Grid alignment is not interlock.** Two parts generated independently will
share a tempo, start on the same downbeat, and land on the same grid — every
route here guarantees that much. None of that makes a bass sit *with* a kick.
Interaction between the rhythm-section parts is most of what makes a beat
sound authored rather than assembled, and it is precisely what independent
generation cannot produce: SA3 rendering a bassline has never heard the drum
part, and GMD retrieval has never heard the bass.

**The asymmetry that makes sequencing cheap:** whichever backend produces the
drums, the drums come out *symbolic* — GMD retrieval returns notes, and Route
C returns notes after transcription. By the time the second part is
generated, the first part's kick placement is already machine-readable data.
No audio analysis, no separator, no extra model. This is why drums-first is
the natural order rather than an arbitrary one, and it holds across every
backend in this document.

Three ways to spend that information, in increasing order of control:

1. **Prompt-level.** Describe the kick pattern in the SA3 prompt. Cheapest,
   and almost certainly the weakest — nothing in the audio evidence
   suggests SA3 follows rhythmic instructions at that precision, and no test
   here measured it.
2. **Post-hoc snapping.** Generate the bass independently, transcribe it, then
   snap or nudge its onsets toward the kick positions (and away from them
   where the style wants syncopation). Deterministic, a few lines, no new
   dependency. The risk is audible over-correction: a bass welded to the kick
   reads as mechanical, which is the failure mode this project started with.
3. **Derived rhythm.** Take the placement from the drum part directly — bass
   follows the kick, with passing notes where the harmony asks — and let
   Claude propose a bounded pitch plan. Most control; the cost is that the
   "generator" for bass rhythm is now a rule, not a model.

**This is not the transfer §D.3 warns against.** That warning is about
copying a drummer's *velocity curve and articulation* onto a bass line, where
the physical gesture doesn't transfer. Rhythmic placement is a different
object: bass locking to a kick is standard practice in every genre this tool
targets, not a borrowed performance.

### E.1 A cheap conditioned baseline: D retrieval + derived bass

Conditioning is a wiring choice, so it composes with any backend. GMD
retrieval plus a rule-derived bass is the cheapest conditioned arm to test,
not an established musical winner:

**Retrieval gives a ground-truth skeleton; transcription gives an estimate.**
GMD hands over an exact human performance, so the kick and snare positions
the bass locks to are the drummer's actual placements. Route C drums hand
over a transcription carrying the 4.3–28.2 ms of grid deviation measured in
§C.1, which nobody has yet split into groove versus error. Conditioning
amplifies whatever the skeleton contains: lock a bass to estimated onsets and
you propagate the estimation error into a second part.

The full design, for a request naming drums and bass:

1. **Drums** — retrieve a GMD performance matching style, tempo and density.
   Human velocity and microtiming arrive attached. Remap TD-11 pitches to GM
   and then to the target rack.
2. **Harmonic plan** — Claude proposes root motion per bar from the request
   plus `Session.State`'s key/scale, constrained to a small schema the engine
   can validate. Whether that produces useful bass movement is part of the
   test, not an established strength.
3. **Relationship** — Claude picks *one* strategy: lock to the kick, answer
   between kicks, or sustain through them. One musical judgment, not sixty
   note placements.
4. **Placement and articulation** — the engine derives bass onsets from the
   kick positions according to that strategy. A bass-specific phrase rule
   supplies velocity and duration; it must not copy the drummer's velocity
   contour or articulation mechanically.

**What drops out of the pipeline is the point.** No SA3 render for the bass,
no Basic Pitch, no octave errors, no transcription failure mode, no
separator — and no meaningful latency, since retrieval and rule evaluation
are both sub-millisecond. The dependency surface for a full bass-and-drums
request collapses to a 3.11 MB CC-BY-4.0 dataset and arithmetic.

**It narrows the original failure without proving it solved.** Claude no
longer writes every onset, duration, and velocity, but it still proposes root
motion—the pitch-related part of the original failure. The engine must bound
that proposal to the mirrored key/scale and a small validated harmonic
schema, and the ear test must judge the result. Human drum timing does not by
itself make the bass line feel human.

**What must still be proven by ear:** whether a derived bass reads as *played
with* the drums or merely *aligned to* them, and whether GMD's finite genre
vocabulary can serve a request like "dusty lo-fi" at all. Both are ear-gate
questions, not measurement questions.

**What ordering costs.** Parts can no longer be prepared in parallel. The
GMD+derived-bass arm remains sub-second, while a conditioned arm using two
worst-case measured SA3 generations could cost ~3.8 s + ~3.8 s and still fit
the budget. The tool
contract has to express dependency — "this part follows that one" — which is
a real schema decision, not an implementation detail. The high-level
generation tool owns the whole sequence and one undo boundary. A failed first
part invalidates the second, so the operation needs an atomic failure policy
as well as sequential generation.

**What it does not solve.** Harmonic coherence still needs a validated plan
derived from `Session.State`'s key/scale—sequencing fixes rhythm, not notes.
A third part conditioned on two predecessors compounds both the latency and
the question of *which* predecessor it should follow.

**The cheap measurement.** This arm needs no new model dependency to test:
take a drum part that already exists, derive the bass, and compare it with an
independently generated Route C bass in the product bake-off. Separately,
compare the same Route C bass MIDI before and after a post-hoc conditioning
pass to measure whether conditioning itself helps without changing the bass
backend. The rule-derived arm tests a complete product candidate; it does not
isolate the effect of wiring.

### E.2 Existing-project context is a separate conditioning problem

Everything above conditions parts created inside one request. The first
release also asks for a new part that follows existing Session clips. Seshat
can read MIDI notes with `get_clip_notes`, so the experiment must include an
existing-MIDI arm and define who derives chord changes, phrase boundaries,
density, and rhythmic accents from those notes. Reading only
`Session.State`'s tempo, key, and scale does not meet the user story, and
letting Claude guess unconstrained root motion repeats part of the original
pitch failure.

Existing audio is a different input. Seshat cannot currently inspect its
musical content, and Basic Pitch has only been measured on isolated generated
bass and pad files—not arbitrary user mixes. Existing-audio conditioning is
therefore outside the first-release claim until an input path, source
assumptions, transcription quality, and latency are measured explicitly.

---

## Recommendation: run the decision experiment

The research supports a shortlist, not a backend choice. Prepare the missing
components, run controlled subtests to understand the mechanisms, and then
run a blinded product bake-off:

1. **Choose 8–12 representative prompts before generating anything.** Include
   drum-only, bass-only, and combined bass-and-drums requests across likely
   styles, plus bass added against existing Session-view MIDI. Fix bar count,
   tempo, target instruments, alternate-take rules, and loudness matching.
2. **Clear the prerequisites.** Spike IDM on the existing SA3 drum slate and
   choose a permissively licensed separator for joint C. Record latency,
   install footprint, class mapping, missed/phantom hits, bleed, and onset
   damage. Remove any candidate that cannot produce evaluable final MIDI; do
   not substitute ADTOF silently. Verify the separator's weights independently
   from its code licence—Demucs's code is MIT, but the rights to its
   pretrained weights are unresolved upstream (issue #327; training data
   includes non-commercial MUSDB), so treat them as unlicensed until clarified
   and do not assume Demucs is the answer.
3. **Run controlled subtests where one-factor comparison is possible.** For
   the same drum and bass MIDI, compare independent placement with a post-hoc
   conditioned version. For the same derived-bass algorithm, compare a GMD
   skeleton with an SA3→IDM skeleton. These tests estimate the value of
   conditioning and the effect of skeleton source separately; they do not
   turn transcription error into a directly observable variable.
4. **Run the multi-part product bake-off between complete candidates:** **independent C**
   (separate SA3 drum and bass generations), **conditioned/D** (GMD drums plus
   bounded rule-derived bass), **conditioned/C** (SA3→IDM drums plus the same
   bounded bass engine), and **joint C** (one rhythm-section render → source
   separation → two transcription passes). These arms change several factors;
   their ranking answers what to ship, not why one won.
   For single-part prompts, compare only the applicable backends separately:
   GMD retrieval, GrooVAE (if cleared), and SA3→IDM for drums; Route C for
   bass and harmony. Do not infer a single-part winner from the
   rhythm-section result.
5. **Judge only the product output in the primary round.** Render final MIDI
   through the same Ableton instruments and settings, hide route identity,
   and rate prompt match, groove, bass/drum cohesion, part correctness, and
   editability. Use source WAVs only in a second diagnostic round to locate
   loss from generation, separation, or transcription.
6. **Choose by final-MIDI quality.** If one candidate wins clearly, recommend
   it subject to its shipping gates. When quality is materially tied, prefer
   the simpler, licence-compatible, easier-to-operate combination. Do not
   infer a backend winner from proxy metrics or a wiring winner from the
   product bake-off alone.
7. **Resolve distribution obligations before implementation.** ADTOF remains
   excluded. Verify IDM and separator artifacts, document SA3's Community
   License and revenue threshold, and design attribution for direct GMD
   retrieval. GrooVAE remains unavailable for selection until its hosted
   checkpoint terms and dependency strategy are resolved.
8. **Continue to watch Agogic and MIDILM; defer Route B and melody.** Re-spike
   the symbolic candidates when runnable artifacts appear. No supported
   self-serve generation API was found, and melody has the weakest combined
   generator/transcriber evidence.

---

## Open work for the decision experiment and eventual `/plan`

- **Which separator makes joint Route C testable and shippable?** This audit
  measured isolated SA3 outputs, not separation of a jointly generated rhythm
  section. Compare candidate separators on bass/drum bleed, onset damage,
  local latency, licence, and Apple deployment before treating joint C as an
  implemented route. Inspect both code and checkpoint terms: popular
  separators commonly license those artifacts differently.
- **How does the one high-level tool enforce atomicity?** The product decision
  is settled: one request creates all related tracks in one undo step. The plan
  must define rollback or cleanup for a failed later part, how the second stage
  receives the first part's symbolic notes, and how one result reports partial
  generation without leaving a misleading half-success in Live.
- **Which pads does an optional Drum Rack output use?** The first-release
  split-track shape can normalise every one-shot lane to its loaded sampler's
  playable pitch. A future one-rack output instead needs the actual pad map;
  a Drum Rack may map arbitrary notes. Seshat cannot currently read that
  layout — there is no
  `/live/device/...` drum-pad address in the fork or in
  [abletonosc-api-docs.md](../abletonosc-api-docs.md). Treat a pad-read address
  as a prerequisite only if the plan brings rack output into scope.
- **Large note batches already need chunking.** `Seshat.Commands.Registry`
  sends all notes in one `/live/clip/add/notes` datagram, while the public
  schema sets no maximum. That is an existing `write_midi_notes` defect rather
  than generation-specific plan work; it is now tracked independently in
  [ROADMAP.md](../ROADMAP.md). The generation plan depends on that fix for
  dense or long clips.
- **What is the full Live-side latency?** Measure one complete single-part and
  multi-part request, including catalog lookup, track creation, every
  `load_device`, clip writes, verification, and follow-cam work. The measured
  1.1–3.9 seconds covers model compute only; `load_device` has a 30-second
  failure timeout but no representative wall-clock measurement here.
- **How is existing MIDI interpreted?** Define the selected Session scene,
  relevant reference tracks, and a bounded representation of chord changes,
  phrase boundaries, density, and accents. Validate harmonic output against
  those observations; mirrored key/scale plus unconstrained Claude root motion
  is not sufficient. Reading the selection is itself a prerequisite: Seshat
  can *set* the selected scene but has no tool or mirror that reads
  `/live/view/get/selected_scene` or `.../selected_clip`, so "the selected
  scene" cannot be resolved today. Existing-audio conditioning stays outside
  the first release until separately measured.
- **Where are hard constraints enforced?** Length, placement, output form, and
  rules such as “no note on beat one” require validation or deterministic
  post-processing before notes reach Live. Prompting a generator is not proof
  that a contract was obeyed.
- **How are alternatives varied and placed?** Define seed or retrieval
  variation so “another take” cannot repeat a deterministic result, and place
  the alternative in the next suitable empty Session scene without overwriting
  accepted material.
- **How are sounds chosen?** The final listening slate needs fixed comparison
  instruments, while the product needs catalog-driven selection that responds
  to requests such as “dusty lo-fi.” Measure device-loading time and judge the
  loaded sounds separately from note quality.
- **Where is beat zero?** Transcribers return seconds. Converting to beats
  needs the tempo (mirrored) *and* the assumption that the clip starts on
  the downbeat. The audio spike proved SA3's durations are bar-exact; nobody
  has checked that the first hit lands on the one. The measured nearest-grid
  offsets partly describe internal timing but do not establish the downbeat or
  loop-boundary alignment; measure both on the existing WAV slate now.
- **Quantise policy.** Raw transcription, or `quantize_clip` at partial
  strength by default? The 4.3 ms vs 28.2 ms spread above says the answer
  is material-dependent, which argues for a tool parameter with an honest
  default rather than a hidden constant.
- **Velocity calibration.** Per-class normalisation (as demoed) makes the
  loudest hat 126 even in a quiet pattern. Absolute scaling preserves the
  performance's dynamics but risks a whole clip at velocity 45. Probably
  per-class with a floor, but it should be an explicit decision.
- **Which failure does the tool report, and how?** Zero-note transcription,
  a bass line that transcribed into the wrong octave, a drum clip with no
  kick — the house honesty rules mean the reply must distinguish "written
  and verified" from "generated, transcribed, not verified". Route C has
  more failure modes than direct audio import does.
- **Dependency shape.** Vendor Basic Pitch's 225 KB ONNX + onnxruntime, or
  depend on the package (1.5 GB with TensorFlow, and a SciPy pin)? For drums,
  ADTOF-pytorch is not a candidate (no licence). Measure IDM's install weight
  during experiment preparation and decide between depending on the repo and
  extracting its inference path if Route C drums win.
- **Licence is a selection criterion now, not a pre-release checklist.**
  Seshat intends to be distributed eventually, so a component that cannot be
  redistributed is disqualified at the moment it is chosen — not at the
  moment it ships. Building the pipeline, tests, tool contract and reply
  wording around such a component means tearing all of it out later. Note
  that CLAUDE.md's "not in production" rule does **not** license this
  shortcut: it governs backwards compatibility (no migration shims, no compat
  paths), and says nothing about dependencies. An earlier round of this
  document got that wrong and treated the ADTOF licence as a
  someday-problem.
  Current standing: ADTOF upstream is CC-BY-NC-SA-4.0 and ADTOF-pytorch has
  no licence at all — both excluded. MIDI-GPT's weights are CC-BY-NC-4.0 —
  excluded on the same rule if it ever becomes a candidate. Basic Pitch and
  the IDM repository are Apache-2.0. GMD is CC-BY-4.0: commercially usable,
  but direct retrieval needs an attribution strategy for the resulting
  product experience. SA3 weights use the Stability AI Community License,
  free for commercial use only below its stated revenue threshold; the audio
  evidence's eventual plan must define installation and entitlement above that
  threshold.
  **GrooVAE is an open case**: its code is Apache-2.0, but the hosted
  checkpoint's terms are unverified, and under this rule that has to be
  settled *before* the generative lane is built on it, not after.

---

## Reproducing the measurements

All spikes ran in throwaway virtualenvs under the session scratchpad
(`uv venv --python 3.12`), against `~/.seshat/audio-spike/*.wav`:

| Spike | Install | Note |
|---|---|---|
| MIDI-GPT | `pip install "midigpt[inference]"` | 587 MB env; checkpoints (~1 GB) cached in `~/.cache/huggingface` |
| text2midi | clone + `torch transformers sentencepiece miditok==3.0.3 jsonlines st-moe-pytorch accelerate` | **`miditok` must be pinned to 3.0.3** — the pickled REMI tokenizer fails on newer versions (`use_velocities`) |
| MIDI-LLM | clone + `torch transformers mido anticipation@git` | `.to(device="cuda")` is hardcoded; needs an MPS edit plus a logits mask to the MIDI vocab range |
| Basic Pitch | `basic-pitch onnxruntime "scipy<1.13" "setuptools<82"` | Use the bundled `saved_models/icassp_2022/nmp.onnx` |
| ADTOF-pytorch | clone + `pip install --no-deps -e .` (torch, librosa, pretty_midi) | Weights bundled. **Used for the §C.1 measurements only** — no licence, not a candidate; IDM takes the slot and is unspiked |
| GrooVAE | `npm install @magenta/music@1.23.1`; `MusicVAE` with `groovae/tap2drum_4bar` | Pure tfjs CPU; 16 eighth-note taps at 120 BPM; checkpoint fetched anew by each measured process |

~4 GB of model weights were downloaded into `~/.cache/huggingface` for the
Route A spikes (MIDI-GPT ~1 GB, text2midi 775 MB, MIDI-LLM ~2.5 GB). They are
independent of the SA3 weights already there and can be deleted freely.

---

## Sources

- [text2midi (GitHub)](https://github.com/amaai-lab/text2midi) ·
  [paper](https://arxiv.org/abs/2412.16526) ·
  [model card](https://huggingface.co/amaai-lab/text2midi) ·
  [Text2midi-InferAlign](https://arxiv.org/abs/2505.12669)
- [MIDI-GPT (GitHub)](https://github.com/Metacreation-Lab/MIDI-GPT) ·
  [model card](https://huggingface.co/Metacreation/MIDI-GPT) ·
  [paper](https://arxiv.org/abs/2501.17011) ·
  [GigaMIDI dataset paper](https://arxiv.org/abs/2502.17726)
- [MIDI-LLM (GitHub)](https://github.com/slSeanWU/MIDI-LLM) ·
  [weights](https://huggingface.co/slseanwu/MIDI-LLM_Llama-3.2-1B) ·
  [paper](https://arxiv.org/abs/2511.03942)
- [MIDILM paper](https://ojs.aaai.org/index.php/AAAI/article/view/39483) ·
  [code](https://github.com/Large-Multimodal-Model-Lab/MIDILM) ·
  [Agogic paper](https://arxiv.org/abs/2608.03999) ·
  [Agogic artifact status](https://github.com/SparcAI-Inc/Agogic) ·
  [MetaScore / ISMIR 2025](https://ismir2025program.ismir.net/poster_32.html)
- [PerTok paper](https://arxiv.org/abs/2410.02060) ·
  [PerTok in MidiTok](https://github.com/Natooz/MidiTok/blob/main/src/miditok/tokenizations/pertok.py)
- [Anticipatory Music Transformer](https://arxiv.org/abs/2306.08620) ·
  [NotaGen](https://arxiv.org/abs/2502.18008) ·
  [MusicLang Predict](https://github.com/MusicLang/musiclang_predict) ·
  [Muzic](https://github.com/microsoft/muzic) ·
  [SkyTNT midi-model](https://github.com/SkyTNT/midi-model)
- [Magenta (archived)](https://github.com/magenta/magenta) ·
  [GrooVAE](https://magenta.tensorflow.org/groovae) ·
  [GrooVAE paper and listening tests](https://storage.googleapis.com/magentadata/papers/groovae/groove_icml2019.pdf) ·
  [GrooVAE checkpoint index](https://github.com/magenta/magenta-js/blob/master/music/checkpoints/checkpoints.json) ·
  [Groove MIDI Dataset](https://magenta.tensorflow.org/datasets/groove)
- [Basic Pitch](https://github.com/spotify/basic-pitch) ·
  [ADTOF](https://github.com/MZehren/ADTOF) ·
  [ADTOF-pytorch](https://github.com/xavriley/ADTOF-pytorch) ·
  [Inverse Drum Machine](https://arxiv.org/abs/2505.03337) ·
  [Apache-2.0 implementation](https://github.com/bernardo-torres/inverse-drum-machine) ·
  [Noise-to-Notes](https://arxiv.org/pdf/2509.21739)
- [Demucs pretrained-weight licence discussion](https://github.com/facebookresearch/demucs/issues/327)
- [AIVA pricing/MIDI rights](https://www.aiva.ai/pricing) ·
  [Staccato pricing and plugin surface](https://staccato.ai/pricing) ·
  [Hooktheory Aria terms](https://www.hooktheory.com/hookpad/aria-tos) ·
  [Klangio API](https://klang.io/api/)
