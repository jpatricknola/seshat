# One model or two — Stable Audio 3 vs Magenta RealTime 2 across every audio feature

_Decision doc · 27 Aug 2026 · answers one question the sibling docs each
assumed: [audio-generation-options.md](audio-generation-options.md)
recommends Stable Audio 3 for clip generation and
[live-improv-exploration.md](live-improv-exploration.md) recommends Magenta
RealTime 2 for live improvisation — should Seshat carry both, or can one
model do all of it? Decides nothing by itself; names the spikes that would._

**Verdict up front.** The split is right *for the features as currently
defined*, but the sibling docs close the "MRT2 for clips" question too
early — MRT2 is the only local candidate with symbolic conditioning, which
is exactly what the context-aware user stories need and Stable Audio 3 lacks.
Carrying two models is justified once live improvisation is being built at
all, because nothing about the fast loop is achievable with Stable Audio 3;
until then only one model is installed and the question is moot. **If forced
to pick one model for every audio task, pick Magenta RealTime 2** — it
covers the whole feature set at a cost (speed, bar-exact output, license
maturity) that spikes can bound, whereas Stable Audio 3 cannot cover live
improvisation at any cost. §7 argues this in full.

Everything marked **measured** was run on this Mac (M3 Max, 36 GB); everything
marked **reported** comes from a repo, model card, paper or review, checked
2026-08-27. The imbalance matters: Stable Audio 3 has a measured column,
MRT2 does not.

---

## 1. The features being served

Three product surfaces, from three sibling docs, share one generator seam:

| Feature | Doc | What the generator must do |
|---|---|---|
| **Clip generation** — "drum loop, four bars, onto this track" | [audio-generation-options.md](audio-generation-options.md) | Render N bars at the mirrored tempo, bar-exact, fast enough to iterate, as a file Live can import |
| **MIDI generation via transcription** (Route C) | [midi-generation-options.md](midi-generation-options.md) | Same as above, but isolated material that transcribes cleanly; the audio is intermediate |
| **Context-aware generation** — "add a bassline to *this section*" | [music-generation-user-stories.md](music-generation-user-stories.md) stories 3–5 | Condition on existing project material, not only tempo/key text |
| **Live improvisation** | [live-improv-exploration.md](live-improv-exploration.md) | Continuous stream, steerable in place, reacting to the user's MIDI within a beat |

The first two are one job (render a clip); the third is a harder version of
it; the fourth is a different job. The question is which models can do which
jobs, and what each costs where it is second-best.

---

## 2. Stable Audio 3 — strengths and weaknesses

### 2.1 What it is

Latent diffusion over a 44.1 kHz stereo autoencoder (SAME, 256-dim latents at
10.76 Hz), flow-matching pre-training then adversarial post-training, 8
ping-pong sampling steps, no classifier-free guidance at inference. Three
sizes: small-music / small-sfx (433M in the paper; the MLX runtime's DiT is
listed as 50M), medium (1.4B), large (2.7B, API only). Trained on 1,278,902
recordings — 806,284 licensed from AudioSparx and 472,618 Creative Commons
from Freesound. Reported.

### 2.2 Strengths

- **Bar-exact output, measured.** Requested 10.667 / 7.742 / 5.647 s came back
  10.667007 / 7.741995 / 5.647007 s. No trim, no downbeat detection needed
  for length — the clip *is* the requested duration.
- **Far faster than realtime, measured.** `sm-music` 1.0–1.1 s per four-bar
  clip after cache warm-up, `medium` 2.6–3.8 s — all-in CLI wall clock,
  model load included. Reported ~10× realtime for small and ~2× for medium on
  an M1 8 GB; this machine is well above that. Iteration ("again, darker") is
  the real usage pattern and this speed is the feature.
- **Editing primitives the other model lacks.** `--negative-prompt`
  (isolated material for transcription), `--init-audio` audio-to-audio with
  `--init-noise-level` (variations of an existing clip — *the local MLX
  runtime has this*, correcting the sibling doc's note that only the 2.5 API
  does), inpainting of one or several regions, and continuation. That is the
  whole "variation of this clip" story with nothing new on disk.
- **Free-text conditioning through a real text encoder** (T5Gemma). Nothing
  to translate into a knob vocabulary; Claude's translation job is prompt
  idiom, which the audio spike already exercised.
- **Installed, spiked, and already the Route C source.** Every MIDI
  measurement in the sibling doc was taken on its output.
- **Published evaluation.** FAD / CLAP / MOS against ACE-Step 1.5, DiffRhythm
  2, Woosh Flow, TangoFlux; 14-listener MOS. Reported.
- **Ships with an Ableton importer.** `optimized/mlx/ableton/` is a MIDI
  Remote Script listening on a local socket plus a CLI that inserts a WAV at
  the playhead — proof the "generated file → Live track" leg is a one-script
  problem. Seshat would do it through the fork instead, but the LOM path is
  demonstrated.

### 2.3 Weaknesses

- **No fast loop, structurally.** Diffusion renders a whole clip; there is
  no per-frame input for what the user is playing. The best it can do is a
  bar-ahead continuation loop, one bar of latency minimum, steered only at
  bar boundaries — [live-improv-exploration.md §5.3](live-improv-exploration.md#L316)
  correctly calls that a texture player. This is not a spike outcome; it is
  the architecture.
- **No symbolic conditioning.** Text and audio in; no MIDI, no chord bed, no
  "the notes on the other track." Context-aware stories 3–5 get tempo/key
  text and nothing else — exactly what the user-stories doc says fails the
  "context use" criterion.
- **Tempo and key are prompt text.** "124 BPM" is trained-in metadata and
  works in reviews, but adherence on Live's grid is unmeasured here; the
  paper reports no tempo or key metric. Same gap as MRT2, to be fair.
- **Material split.** Reviews and the lineage agree: strong on ambient,
  textural electronic, lo-fi, house-adjacent loops and drums; weak on
  exposed, hooky melodic material and dense arrangements; no vocals.
- **License has a revenue gate.** Code MIT; weights under the Stability AI
  Community License — free commercial use below $1M annual revenue,
  Enterprise license above, license copy must accompany redistributed
  weights, plus Gemma Terms for the T5Gemma encoder. Distributable, but with
  a product story to write ([CLAUDE.md](../../CLAUDE.md)'s rule) and a
  second license on the text encoder.
- **Disk.** ~8.4 GB for small + medium weights.

---

## 3. Magenta RealTime 2 — strengths and weaknesses

### 3.1 What it is

Autoregressive "live music model" over the SpectroStream codec: 48 kHz
stereo generated one 40 ms frame at a time (25 Hz), windowed attention over
its own recent output with a ~20 s effective receptive field, style through
frozen MusicCoCa embeddings (text or audio), plus two conditioning channels
diffusion models do not have — a 128-way per-frame pianoroll and a drums
on/off gate. Two sizes: `mrt2_small` 230M (450 MB download) and `mrt2_base`
2.4B (~2.5 GB). Released 2026-06-04, v2.0.3 on 2026-07-30. Trained on ~71k
hours of stock music, mostly instrumental. Reported.

### 3.2 Strengths

- **The fast loop exists.** Per-frame MIDI conditioning with four states per
  pitch (off / on / onset / model-decides), an "auto-strum" mode where the
  user sets pitches and the model chooses onsets, and a precise mode where
  onsets are the user's. Announced control latency ~200 ms; the Max external
  runs at 8192 samples ≈ 170 ms. This is the one capability that makes
  "improvise with me" a collaborator rather than a texture player, and no
  other shippable model has it.
- **Symbolic conditioning for clips too.** The same pianoroll channel that
  follows a live keyboard can be fed a chord bed read with `get_clip_notes`
  in an offline render — the only local route to "bass that fits *these*
  chords" rather than "bass in D minor." `cfgnotes` and `cfgdrums` guidance
  scales are exposed separately from text guidance.
- **Drum gate.** `drumless 0/1` is a hard structural control, not a negative
  prompt — "no drums" is enforced, not requested.
- **Cleanest license of any candidate.** Code Apache-2.0, weights CC-BY-4.0,
  Google claims no rights in outputs, no watermark mentioned (Lyria's SynthID
  is the cloud sibling's, not this one). One attribution line.
- **Already lives in a DAW.** AUv3 instrument with Ableton setup steps, a
  `mrt2~` Max external (six prompt slots, temperature / top-k / CFG / mute /
  reset / MIDI messages, ~1 GB per instance), Pure Data and SuperCollider
  externals. The Max for Live topology in the improv doc is a wrapper away.
- **Steering in place.** Six weighted prompt slots ramp; temperature, top-k
  and CFG change mid-stream; `reset` is explicit. Clip generation gets a
  side benefit: "build over four bars" is a weight ramp, not a re-render.
- **Prior evaluation exists for v1.** The Live Music Models paper reports
  lower FD (openl3) than MusicGen Large and Stable Audio Open at ~750M
  parameters, and specifically claims stable tempo across long generation —
  a property that matters more for a stream than for a four-bar clip.

### 3.3 Weaknesses

- **Offline speed is unpublished.** `mrt models`, `mrt mlx generate
  --duration` and "offline inference on any Apple Silicon Mac" are
  documented; the real-time factor is not, and `docs/benchmark.md` is a
  build recipe with no numbers. `mrt2_base` needs a Pro/Max chip merely to
  keep up with realtime, which puts its RTF near 1 on this M3 Max: **four
  bars at 92 BPM would take ~10 s to render** if that holds — the entire
  compute budget, before transcription, against SA3's 1 s. `mrt2_small`
  may be several × faster; nobody has measured it. This single number decides
  most of §7.
- **Nothing is bar-exact.** Output is a stream; a clip is a capture of
  `duration` seconds with no notion of a loop boundary or a downbeat. Every
  clip needs a trim policy and a downbeat guess. SA3 gives both for free.
- **Tempo is prompt text, and the fast loop has no clock.** No `bpm` field,
  no transport in; MIDI conditioning carries pitch, not beat. Same
  unmeasured adherence as SA3 for clips; for the stream it is the whole
  sync problem ([live-improv-exploration.md §7](live-improv-exploration.md#L394)).
- **No subtractive or editing primitives.** No negative prompt (only the
  drum gate), no inpainting, no audio-to-audio variation — the audio prompt
  is a style anchor set once, and the Max external does not yet expose it.
  "Variation of this clip" would be a re-render with a lower temperature.
- **Quality unpublished for v2.** Model card defers evaluation to a
  forthcoming report; v1's numbers were against open models only, not
  against the Stable Audio 3 generation. Uneven genre coverage, non-lexical
  vocal artefacts, and ~20 s of memory are stated limits.
- **Young and Apple-only.** Two months old; the streaming API's state and
  reset semantics are learned from code, not docs; realtime only on Apple
  Silicon (offline also on NVIDIA). Matches where Live-plus-Seshat lives
  today and closes a Windows door.
- **No measured column.** Everything above is reported.

---

## 4. Suitability per feature

Scores are the author's reading of the evidence above; **bold** = decisive.

| Feature / criterion | Stable Audio 3 | Magenta RealTime 2 |
|---|---|---|
| **Clip: bar-exact length** | **Measured, to the sample** | Capture + trim, downbeat unknown |
| **Clip: iteration speed** | **1 s / four bars measured** | Unmeasured; ≤10× (small) to ~1× (base) realtime plausible |
| Clip: free-text fidelity | Real text encoder; spiked | MusicCoCa tags-to-sentences; unspiked |
| Clip: loop cleanliness | Unmeasured, ears required | Unmeasured; no loop concept in the model |
| Clip: tempo hold | Prompt text, unmeasured | Prompt text, unmeasured; v1 paper claims stability |
| Clip: variations of an existing clip | **Audio-to-audio + inpainting, local** | Re-render only |
| Route C: isolated material | **Negative prompt** | Drum gate only |
| Route C: drums via transcription | Already the measured source | Unknown |
| **Context-aware: condition on project notes** | None | **Pianoroll channel** — the only local option |
| Context-aware: "no drums" as a contract | Negative prompt, soft | `drumless`, hard |
| **Improv: fast loop (react within a beat)** | **None, by architecture** | **~200 ms MIDI conditioning** |
| Improv: slow-loop steering | Bar-ahead continuation, one-bar latency | In-place prompt-weight ramps |
| Improv: lives on a Live track | No | AUv3 / Max external |
| License for distribution | Community License, $1M gate, plus Gemma terms | **Apache-2.0 / CC-BY-4.0** |
| Disk / RAM | 8.4 GB disk; 1.6–3.8 GB peak RAM | 0.45–2.5 GB disk; ~1 GB per instance |
| Evidence maturity | Measured here + published eval | Reported only; v2 eval pending |

Read across: SA3 wins every clip-generation row that is measured; MRT2 wins
every row that involves *input other than text*. The two feature groups
split on exactly that axis, which is why the sibling docs reached their
recommendations independently and agree.

---

## 5. Is the complexity of two models justified?

What "two models" actually costs, item by item:

| Cost | Size | Notes |
|---|---|---|
| Two installs | ~8.4 GB + ~3 GB disk | Both MLX-based, both `uv`-managed; the install story is one doc section per model |
| Two license stories | Real | Community License needs a revenue-threshold clause and a Gemma notice; MRT2 needs one attribution line. Two paragraphs in a LICENSES file |
| Two runtimes | Small | SA3 is a CLI per generation (measured sufficient); MRT2 is a long-lived process or a device on a track. They never run in the same call path |
| Two prompt idioms | Medium | Claude translates intent into each; the clip idiom is already spiked, the MRT2 idiom is not |
| Two provider adapters | Small | The improv doc's `GenerativeMusic` seam and a clip-generation handler are different interfaces anyway — a stream you steer versus a file you request |

What is **not** duplicated, and is where the engineering actually lives:

- **Import into Live.** `ClipSlot.create_audio_clip(path)` as a fork address,
  managed WAV folder, occupied-slot policy — needed by clip generation, by
  Route C's optional WAV retention, and by improv capture alike. One piece
  of plumbing, model-agnostic.
- **Routing.** Input routing (audio and MIDI) that Seshat can neither set
  nor read today is a gap for improv under either model.
- **Transcription.** Basic Pitch / IDM take a WAV; they do not care who made
  it.
- **Capture and warp.** `record_clip`, `set_clip_properties` warping —
  Live's job, not the generator's.

So the marginal cost of the second model is disk, a license paragraph, and
one more prompt idiom to learn. Against that, the marginal *benefit* of the
second model is the entire live-improvisation feature, which SA3 cannot
deliver at any cost, plus a credible route to the context-aware stories.

**Judgement:** two models is justified — but only at the moment live
improvisation is actually built. Until Spike A1 runs there is one model on
disk and no decision to make. The failure mode to avoid is the opposite one:
installing MRT2 for improv, then *also* wiring it into clip generation "to
be consistent," which would trade a measured 1 s bar-exact path for an
unmeasured trim-and-guess one. Consistency is not a feature here; each job
should keep its measured best tool.

---

## 6. What the sibling docs changed — applied 2026-08-27

All four edits below are in place; this section records why.

1. **Spike A1 gains three measurements** ([live-improv-exploration.md §12](live-improv-exploration.md#L601)):
   offline real-time factor for `mrt2_small` and `mrt2_base` on this
   machine; whether a pianoroll fed from `get_clip_notes` makes an offline
   render *follow* the harmony or merely avoid it; and the downbeat/trim
   cost of turning a `--duration` render into a bar-exact clip. Zero extra
   install; an hour.
2. **The MIDI bake-off gains an arm** ([midi-generation-options.md § Recommendation, step 4](midi-generation-options.md#L826)):
   "MRT2 offline render → transcription," specifically for the
   context-aware prompts (bass against existing Session-view MIDI), where
   SA3 has no conditioning to offer. Not for the blank-project prompts,
   where SA3's measured advantages stand.
3. **[audio-generation-options.md](audio-generation-options.md) corrects one
   fact:** the local MLX runtime *does* have audio-to-audio (`--init-audio`,
   `--init-noise-level`); "the one capability no local small model matches"
   is no longer true and "make a variation of this clip" needs no cloud.
4. **Spike A0 (SA3 continuation loop) is demoted** to "only if A1 is
   blocked." Its purpose was to avoid installing a second model for the
   texture-player half; once MRT2 is installed for the fast loop anyway, a
   slow-loop-only SA3 texture player is strictly worse than MRT2's in-place
   steering and there is nothing left for A0 to save.

---

## 7. If forced to choose one model for every audio task

**Magenta RealTime 2.**

The reasoning is asymmetric, and that asymmetry is the whole answer:

- **SA3's gaps are architectural.** No per-frame input exists in a
  whole-clip diffusion model. Live improvisation under SA3 is a
  bar-ahead continuation loop with one bar of latency and no ear — the
  improv doc's own definition of *not a collaborator*. Context-aware
  generation under SA3 is tempo/key text, which the user-stories doc
  already names as failing the "context use" criterion. No spike changes
  either; they are what the model is.
- **MRT2's gaps are quantitative, and every one has a mitigation.**
  Offline speed: measure it; use `mrt2_small` for iteration and `base` for
  the keeper, exactly as the SA3 doc already plans small/medium. Bar-exact
  length: render `bars × beats × 60/BPM` plus a tail, detect the first
  onset, trim to the bar — the same maths gary4live runs on SA3's lineage
  today. Loop seam: a crossfade at the boundary, or ask Live to warp. No
  negative prompt: `drumless` covers the most common exclusion and the
  pianoroll can *specify* register rather than exclude it. No
  audio-to-audio: a re-render with the previous take as the audio style
  anchor plus lower temperature — cruder, but present. Quality: unknown,
  and the one item a spike could genuinely fail.
- **One model covers the full feature set; the other covers a subset.** A
  product on MRT2 alone ships clip generation slower and with a trim step,
  live improvisation intact, and context-aware generation with a real
  mechanism. A product on SA3 alone ships excellent clips and no
  collaborator, ever.
- **Distribution favours it.** CC-BY-4.0 with no revenue gate and no second
  license on a text encoder is a smaller product story than the Community
  License, and [CLAUDE.md](../../CLAUDE.md) makes that a selection-time
  criterion.

What a single-model choice of MRT2 would *give up*, stated plainly so
nobody mistakes this for a free lunch: the measured 1 s bar-exact clip
path; local inpainting and audio-to-audio; the negative prompt that makes
Route C's transcription material cleaner; and every measurement in the
audio and MIDI docs, which were all taken on SA3 output and would need
re-running. That is a real price. It is why §5 recommends paying for two
models instead — the forced-choice answer is a statement about coverage,
not a recommendation to drop SA3.

**The condition that would flip §7:** Spike A1 finding MRT2's offline render
realtime-bound *and* its clip quality clearly below SA3's by ear. Then the
single model would be SA3, live improvisation would be scoped down to a
steerable texture player, and the collaborator would wait for the next
model that has a fast loop. That is a worse product, so it is worth an
afternoon of measurement to avoid guessing.

---

## Sources

- Stable Audio 3: [repository](https://github.com/Stability-AI/stable-audio-3) ·
  [MLX runtime README](https://github.com/Stability-AI/stable-audio-3/blob/main/optimized/mlx/README.md) ·
  [technical report, arXiv 2605.17991](https://arxiv.org/html/2605.17991v1) ·
  [small-music model card](https://huggingface.co/stabilityai/stable-audio-3-small-music) ·
  [Stability AI Community License](https://stability.ai/license) ·
  [musicproductionwiki review](https://musicproductionwiki.com/articles/stable-audio-3-review) ·
  local install at `~/.seshat/stable-audio-3` (a0b57f5, 2026-08-02):
  `docs/workflows/inference.md`, `docs/guides/prompting.md`,
  `optimized/mlx/ableton/README.md`
- Magenta RealTime 2: [repository](https://github.com/magenta/magenta-realtime) ·
  [model card](https://huggingface.co/google/magenta-realtime-2) ·
  [announcement](https://magenta.withgoogle.com/magenta-realtime-2) ·
  [apps and plugins](https://magenta.withgoogle.com/mrt2) ·
  [`mrt2~` Max external README](https://github.com/magenta/magenta-realtime/blob/main/examples/max/README.md) ·
  [CHANGELOG](https://github.com/magenta/magenta-realtime/blob/main/CHANGELOG.md) ·
  [Live Music Models paper, arXiv 2508.04651](https://arxiv.org/abs/2508.04651) ·
  [Mervin Praison write-up](https://mer.vin/2026/06/magenta-realtime-2-open-live-music-ai-on-mac-with-midi-audio-and-text-control/)
- Sibling docs in this folder, as linked inline.
