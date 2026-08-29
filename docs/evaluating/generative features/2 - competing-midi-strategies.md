# Seshat: Direct MIDI Generation — Strategy Research

**Target user story:** session has kick / snare / hat / bass on separate MIDI tracks → "compose an 8 bar dark glitchy hip hop beat" → every track populated, coherent with each other, editable.

**Status quo:** Claude writes note events directly through `write_midi_notes`. Results are poor.
**Abandoned:** Stable Audio 3 → audio-to-MIDI transcription (loses per-element control, which is the whole point).

---

## 1. Why LLM-direct MIDI fails (diagnosis before prescription)

This matters because the fix depends on which failure mode dominates. Four distinct ones:

1. **Wrong representation.** The model emits absolute tick/pitch/velocity tuples. Music is *relative and hierarchical* — a hat pattern is "16ths with accents on the offbeats, roll on bar 4," not 128 independent numbers. Every token is an opportunity to break the grid, and there's no structural constraint preventing it.
2. **No microtiming or velocity model.** LLMs default to quantized grids and flat or randomly-jittered velocities. Groove is *systematic* deviation (a consistent late snare, a swing ratio, a velocity contour), not noise. This is the single biggest reason LLM drums sound like a drum machine demo.
3. **No cross-track conditioning.** Generating four tracks in one pass means the model holds all four in working memory as text; generating them sequentially means later tracks see earlier ones as raw numbers, which is nearly unreadable. Either way, "they lock together" is not being optimized for.
4. **Genre vocabulary is shallow.** "Dark glitchy hip hop" has concrete production conventions (tempo band, swing %, hat triplet rolls, kick placement relative to snare, 808 glide). The LLM knows these as *prose*, not as note data, and can't reliably compile prose knowledge into events.

Note that (1)–(3) are fixable with scaffolding. (4) is fixable with retrieval or a trained model. **None of them require abandoning the LLM.**

---

## 2. Four candidate strategies

### Strategy A — LLM emits a music DSL, deterministic compiler emits MIDI ⭐ highest value/effort ratio

Instead of note events, the LLM writes a compact pattern language, and Seshat compiles it. Roughly:

```
tempo 84, swing 58%
kick:  x..x ..x. ...x ..x.        vel 100-118
snare: ..x. ....x. ..x. ....      vel 92,  push +8ms
hat:   xxxxxxxxxxxxxxxx           vel curve accent-8ths, roll bar4 beat4 = 32nd x6 cresc
bass:  root F1 on kick hits, glide to Ab on bar3
```

Why this works:
- The LLM operates in the space it's actually good at — **describing** music — while a deterministic layer handles the parts it's bad at: grid integrity, swing math, velocity contours, humanization.
- Errors become *impossible* rather than *unlikely*. A hat can't land at tick 1237.
- Tracks are described in one compact spec the LLM can hold in view at once, so cross-track coherence is reasoned about in musical terms ("snare on 2 and 4, kick avoids the snare on beat 2") instead of in numbers.
- Iteration is cheap: "make the hats busier" is a two-token edit, not a regeneration of 200 notes.

There's now direct research validation of this direction: **[Decomposer (arXiv 2607.01849, July 2026)](https://arxiv.org/abs/2607.01849)** — CMU/Chris Donahue's group — trains models to translate MIDI into **[Strudel](https://strudel.cc/)** programs, explicitly on the premise that programs are the editable, structured representation of music and note-level transliteration is the failure case. Their released **Strudel-Synth** corpus is 21,174 (Strudel, MIDI) pairs. Strudel/TidalCycles mini-notation is already a battle-tested, LLM-friendly pattern DSL with a well-documented grammar, and there's [documentation specifically curated for LLM-assisted Strudel composition](https://github.com/calvinw/strudel-llm-docs).

**Two sub-options:** invent a minimal Seshat DSL (tighter fit to Ableton's track/clip model, no dependency) or adopt Strudel mini-notation (existing grammar, existing LLM familiarity, existing corpus if you ever fine-tune). Recommend starting with a minimal in-house DSL for drums + a bass/harmony spec, and evaluating Strudel later.

### Strategy B — Groove/humanization post-processing layer (pairs with everything)

Whatever generates the notes, run a final pass that applies **systematic** feel:

- **Swing**: hip-hop sits at ~54–62%; boom-bap deeper, ~40–60% in Ableton's groove terms. ([samplefocus](https://samplefocus.com/blog/swing-shuffle-and-humanization-how-to-program-grooves/), [lockah](https://lockah.net/how-to-program-drum-swing-and-groove-for-natural-sounding-beats/))
- **Velocity contours**, not randomization: accent patterns per instrument, ghost notes on snare, 5–10% jitter *on top of* a contour.
- **Groove templates**: extract timing+velocity from reference grooves and apply as an offset map. Ableton already has a Groove Pool — Seshat can either apply Live's own grooves via the API or bake offsets into the notes.
- **Learned humanization**: Magenta's **GrooVAE / Drumify** (trained on the Groove MIDI Dataset, CC BY 4.0) takes a quantized pattern and predicts human microtiming + velocity. Apache-2.0, tiny, runs on CPU or in JS. The parent Magenta repo was archived Jan 2026, but the checkpoints still work and this is the single most reusable piece of that lineage.

This is the cheapest large quality win available. Most of the gap between "obviously AI" and "usable" for drums is here, not in pattern novelty.

### Strategy C — Purpose-built symbolic models behind the LLM

Let the LLM be a **conductor** that calls specialist generators per track. Verified options:

| Model | Fit | License / status |
|---|---|---|
| **[MIDI-GPT](https://github.com/Metacreation-Lab/MIDI-GPT)** (Metacreation, AAAI'25) | Best drop-in. Track- and bar-level **infilling** with per-track controls: instrument, drum/melodic type, note density, polyphony, duration. Ships an HTTP REST server + OSC server for DAWs. ~20–30M params, CPU/MPS fine. Multi-track coherence comes from conditioning on the rest of the score. | MIT code, v0.2.4 (Jun 2026), actively maintained. Weights on HF. Trained on GigaMIDI (CC BY-NC as a dataset) — flag for legal review. |
| **[Anticipatory Music Transformer](https://github.com/jthickstun/anticipation)** (Stanford) | Accompaniment/infilling: "given these drums, write a bass." 128M–780M. This is what powers Hooktheory's Aria. | Apache 2.0 code **and** weights. Research-frozen but stable. |
| **[MIDI-LLM](https://github.com/slSeanWU/MIDI-LLM)** (ISMIR'26) | Best open **text→multitrack MIDI**. Llama-3.2-1B extended with 55k MIDI tokens. Free-form prompt → full arrangement. Beats text2midi on FAD/CLAP. | Llama Community License derivative — verify weight terms. New, thin track record. |
| **[Composer's Assistant 2](https://github.com/m-malandro/composers-assistant-REAPER)** (ISMIR'24) | Track-measure infilling with density/pitch-range/rhythmic-interest controls. **Trained only on public-domain/permissive MIDI** — cleanest copyright story of the lot. | Separable from REAPER (Python server + socket). Verify license file. |

Notably: **none of these do text conditioning well except MIDI-LLM** — and that's fine, because the LLM supplies the conditioning. The natural split is LLM-as-conductor → per-track attribute vectors → MIDI-GPT infill in score context → GrooVAE humanize.

Also worth knowing what *doesn't* work: **Magenta RealTime is audio-out only** (MIDI is an input control, not an output), so it fails the editable-MIDI constraint the same way Stable Audio did.

### Strategy D — Retrieval + mutation over a curated MIDI library

Tag a library of drum/bass MIDI patterns by genre, mood, tempo, density. LLM selects candidates, combines across tracks, and mutates (rotate, thin, add rolls, swap a hit). This is essentially what **[Playbeat 4](https://audiomodern.com/shop/plugins/playbeat-4/)** does behind its "genre-based AI algorithms" — its "Smart" mode generates new patterns by recombining from a genre-filtered preset pool, not by inference — and it is a well-reviewed product.

Pros: fastest path to *good-sounding* results, zero inference cost, style fidelity guaranteed by the source material. Cons: content acquisition and licensing is the whole problem; less "composed to your prompt" and more "assembled." Best as a **fallback/seed layer**: retrieve a stylistically correct starting point, then let the LLM mutate it via the Strategy A DSL.

Also cheap and underrated: **Euclidean rhythm generation** (Toussaint 2004) as a primitive the LLM can invoke — `E(5,16)` and rotations produce musically valid non-obvious patterns from two integers, which is exactly the kind of structured randomness that suits "glitchy."

---

## 3. Recommended architecture

```
prompt → [LLM: parse to session spec] → tempo, key, swing, bar count,
                                        per-track role + density + register
       → [LLM: emit pattern DSL per track, all tracks in one view]
       → [deterministic compiler: DSL → note events on the grid]
       → [humanizer: swing + velocity contours + GrooVAE microtiming]
       → [optional: MIDI-GPT infill for bass/melodic tracks conditioned
          on the finished drum tracks]
       → write_midi_notes per track
```

Two properties worth protecting:
- **The spec is the artifact.** Persist the session spec + DSL, not just the notes. Every follow-up instruction ("darker," "double-time hats," "move the kick off the one") is then an edit to a small readable object, which is a thing LLMs are excellent at — and it makes regeneration deterministic and diffable.
- **Deterministic layers own everything that can be wrong.** Grid, swing, key/scale conformity, velocity ranges, note collision. The LLM never emits a number that can be out of range.

---

## 4. Suggested build order

1. **Spike the humanizer first** (1–2 days). Take a *hand-written* correct 8-bar dark hip-hop pattern, run it through swing + velocity contour + GrooVAE, A/B it in Live. This calibrates how much of the quality gap is groove vs. pattern, before you build anything expensive. Strongly suspect it's most of it.
2. **Minimal drum DSL + compiler** (kick/snare/hat only). Prompt Claude to emit it. Compare against current `write_midi_notes` output on the same prompts.
3. **Add bass**, conditioned on the compiled drums — either via DSL rules (root notes on kick hits, scale-constrained) or MIDI-GPT infill. Compare.
4. **Genre priors as retrieval**: a small tagged corpus of reference patterns injected into the LLM's context as few-shot examples in DSL form. This is where "dark glitchy" gets real vocabulary, and it's far cheaper than fine-tuning.
5. **Only then** consider training: a ~20–100M param model on REMI+/MMM-tokenized, genre-targeted loops via [miditok](https://miditok.readthedocs.io/) is a single-GPU weekend job — but it's premature until you know steps 1–4 have plateaued.

**Evaluation** needs to exist from step 1: a fixed prompt set, blind A/B against human-made reference beats, plus cheap symbolic checks (grid conformity, velocity variance, kick/snare collision rate, swing consistency). Without this you'll be arguing about vibes.

---

## 5. Licensing notes

- Training-data provenance is the main legal exposure. **GigaMIDI is CC BY-NC** (a Canadian fair-dealing rationale), Lakh and MetaMIDI are scraped with undocumented copyright. Clean corpora: **Groove MIDI / E-GMD** (CC BY 4.0, Google) and Composer's Assistant's public-domain set.
- Model licenses that are commercially safe as-is: MIDI-GPT (MIT), AMT (Apache 2.0), Magenta/GrooVAE (Apache 2.0). Verify MIDI-LLM (Llama derivative) and MusicLang (**GPL-3.0** + "contact us for product use" — avoid).
- Strategy A has essentially no training-data exposure, which is a real strategic advantage.

---

## 6. Competitive context

- **[MIDI Agent](https://www.midiagent.com/)** — VST3/AU/AAX plugin doing exactly LLM-prompt→MIDI, BYO API key (OpenAI/Anthropic/Gemini/local via Ollama). This is your closest prior art and it's shipping. Worth buying and stress-testing on the same prompts — it will tell you empirically how far raw LLM-direct generation gets with good prompting, which is the baseline you need to beat.
- **[Hooktheory Aria](https://www.hooktheory.com/)** — blends the Anticipatory Music Transformer with 50k+ human MIDI transcriptions. Validates the "research model + curated corpus" combination.
- **[Staccato](https://staccato.ai/)** ($11.99–14.99/mo) and **[Lemonaide](https://www.lemonaide.ai/)** ($9.99/mo, melodies/chords, consented training data) — both MIDI-out, both single-element rather than coherent multi-track arrangement. **The coherent multi-track drum-forward beat is the gap in the market**, and it's the one Seshat's Ableton integration is uniquely positioned to fill.

---

## Open questions

- How much does GrooVAE humanization actually close the gap? (step 1 answers this)
- Does Claude write a compact drum DSL reliably enough, or does it need few-shot examples per genre?
- Is MIDI-GPT's musical output good enough for bass/melodic tracks at this scale, or does the DSL approach extend there too?
- Content strategy for genre priors: license a MIDI pack, commission patterns, or derive from permissively-licensed corpora?

---

### Sources

- [Decomposer: Learning to Decompile Symbolic Music to Programs (arXiv 2607.01849)](https://arxiv.org/abs/2607.01849) · [repo](https://github.com/elianakim/Decomposer)
- [MIDI-GPT (Metacreation Lab)](https://github.com/Metacreation-Lab/MIDI-GPT) · [paper](https://arxiv.org/abs/2501.17011)
- [Anticipatory Music Transformer](https://github.com/jthickstun/anticipation) · [weights](https://huggingface.co/stanford-crfm/music-large-800k)
- [MIDI-LLM](https://github.com/slSeanWU/MIDI-LLM) · [weights](https://huggingface.co/slseanwu/MIDI-LLM_Llama-3.2-1B)
- [Composer's Assistant 2](https://github.com/m-malandro/composers-assistant-REAPER) · [paper](https://arxiv.org/pdf/2407.14700)
- [GrooVAE / Magenta](https://magenta.tensorflow.org/groovae) · [Magenta Studio](https://magenta.withgoogle.com/studio/) · [archived repo](https://github.com/magenta/magenta)
- [Groove MIDI Dataset](https://www.tensorflow.org/datasets/catalog/groove) · [E-GMD](https://arxiv.org/pdf/2004.00188) · [GigaMIDI](https://huggingface.co/datasets/Metacreation/GigaMIDI)
- [miditok](https://miditok.readthedocs.io/en/latest/tokenizations.html)
- [Strudel](https://strudel.cc/) · [LLM-oriented Strudel docs](https://github.com/calvinw/strudel-llm-docs)
- [Euclidean rhythm](https://en.wikipedia.org/wiki/Euclidean_rhythm) · [LANDR explainer](https://blog.landr.com/euclidean-rhythms/)
- [Swing, Shuffle and Humanization](https://samplefocus.com/blog/swing-shuffle-and-humanization-how-to-program-grooves/) · [Drum swing & groove guide](https://lockah.net/how-to-program-drum-swing-and-groove-for-natural-sounding-beats/)
- [Playbeat 4](https://audiomodern.com/shop/plugins/playbeat-4/) · [review](https://www.internettattoo.com/blog/playbeat-4-review)
- [MIDI Agent](https://www.midiagent.com/) · [review](https://aiindigo.com/blog/midi-agent-review-bringing-llm-intelligence-into-your-daw)
- [Staccato](https://blog.staccato.ai/leading-ai-midi-tools-2023) · [Lemonaide](https://www.lemonaide.ai/)
