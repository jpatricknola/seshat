# Semantic Instrument & Preset Selection for Seshat

## Objective

Replace Seshat's relatively basic instrument/preset selection with a system capable of answering requests such as:

- "Give me a synth like the one Depeche Mode uses on *Enjoy the Silence*."
- "I want a cold, mechanical bass."
- "Something like an old sampler but darker."
- "A synth that sounds like it's melting."
- "Warm analog pad, but not too retro."
- "Something halfway between strings and a synth."
- "Find something like this sound."
- "Give me something darker than the current instrument."

The user should not need to know which Native Instruments product, Kontakt library, synthesis method, or preset is appropriate.

Seshat should bridge:

**musician's description → sonic intent → best sounds actually available**

Assumption for initial development:

> Every instrument/library in Native Instruments Komplete Collector's Edition is available.

The preferred output is generally **3–5 ranked sounds**, rather than one blindly selected instrument.

---

## 1. Current Seshat approach

The existing architecture already provides useful infrastructure.

Seshat's library/catalog code:

- exports Ableton's browser catalog,
- reads Ableton's private metadata database,
- associates browser items with tags and descriptions,
- supports category/tag/name searching,
- tracks usage,
- applies ranking bonuses,
- provides results to the planning layer.

This should **not** be discarded.

The problem is that the semantic bridge is weak.

Conceptually the current path is approximately:

```text
User
  ↓
LLM interprets request
  ↓
LLM guesses useful search terms/tags
  ↓
Catalog lexical/tag search
  ↓
Preset/instrument
```

This works well for:

> "Load an electric piano."

It becomes unreliable for:

> "Give me a cold, slightly unstable synth that sounds like early Depeche Mode."

The catalog does not really understand *cold*, *unstable*, *Depeche Mode*, or the relationship between those ideas and the actual sound produced by a preset.

The existing catalog should therefore become the **candidate/catalog layer**, while a new system supplies **semantic sound intelligence**.

---

## 2. Important distinction: instrument selection vs sound selection

Seshat should not fundamentally solve:

> Which instrument should I load?

It should solve:

> Which available sound best satisfies the musical intention?

These are different.

"Massive X" is an instrument.

"Monark" is an instrument.

"Kontakt" is effectively an instrument host.

But a musician usually wants:

> dark mono bass

not:

> Massive X

The real retrieval object should eventually be:

```text
Instrument
   +
Library/bank
   +
Preset
   +
possibly articulation/state
```

Therefore the canonical searchable object should be a **SoundCandidate**, not an Instrument.

Example:

```text
SoundCandidate

product: Massive X
bank: Factory
preset: Cold Circuit

sound_type:
  Synth > Bass

character:
  Dark
  Synthetic
  Monophonic

metadata_embedding: [...]

audio_embedding: [...]

audio_features:
  brightness: .31
  attack: .18
  movement: .63
  noise: .27
```

This distinction should influence the architecture from the beginning.

---

## 3. Native Instruments already gives us useful structure: NKS

Before inventing a taxonomy from scratch, Seshat should exploit Native Instruments' NKS metadata.

Native Instruments describes NKS presets using:

### Sound Type

Hierarchical classification such as:

```text
Synth
  Bass

Keyboard
  Electric Piano
```

### Character

Independent descriptive properties shared across products.

Native Instruments explicitly designed these tags so users can discover sounds across different instruments with similar sonic functions and characteristics.

Komplete Kontrol additionally provides audio auditioning of presets before loading them.

This makes NKS potentially much more useful to Seshat than treating NI presets only as Ableton browser entries.

### Recommendation

Investigate direct ingestion of:

```text
NKS preset
NKS Sound Type
NKS Subtype
NKS Character
Product
Bank
Preset name
Preview audio
```

and merge this data with the existing Ableton catalog.

Do **not** replace the Ableton catalog.

Create something closer to:

```text
Ableton metadata
        \
         \
          → unified SoundCandidate
         /
NKS metadata
```

---

## 4. Strategy A — Semantic metadata retrieval

This is the easiest major improvement and should become one experimental baseline.

Instead of matching the user's words against literal tags, create a rich textual document for every preset.

Example:

```text
Massive X / Cold Circuit

Synth bass.
Dark synthetic character.
Moderate movement.
Modern wavetable synthesizer.
Suitable for bass and lead roles.
NKS types: Synth > Bass.
NKS characters: Dark, Synthetic, Monophonic.
Product: Massive X.
```

Generate a text embedding for each document.

At query time:

```text
"I want a cold mechanical bass that sounds slightly broken"

        ↓ embedding

query vector

        ↓ cosine similarity

preset metadata vectors
```

This allows semantic relationships such as:

```text
mechanical
industrial
metallic
synthetic
cold
robotic
```

to contribute even when the exact query terms are absent.

### Advantages

- Very easy to prototype.
- No audio rendering required.
- Cheap indexing.
- Fast retrieval.
- Compatible with the existing catalog.
- Likely much better than literal tags.

### Weakness

It ultimately searches **descriptions of sounds**, not sounds.

If a badly named or badly tagged preset sounds perfect, semantic metadata retrieval may never discover it.

---

## 5. Strategy B — Structured sonic ontology

Embeddings should not completely replace structured reasoning.

Seshat should define an intermediate representation of sonic intent.

Example:

```json
{
  "role": "bass",
  "source": "synth",
  "synthesis_family": "analog_subtractive",
  "brightness": 0.3,
  "warmth": 0.4,
  "movement": 0.5,
  "attack": 0.2,
  "width": 0.2,
  "distortion": 0.4,
  "vintage": 0.75,
  "industrial": 0.65,
  "polyphony": "mono"
}
```

Potential dimensions:

### Musical role

- bass
- lead
- pad
- keys
- pluck
- texture
- atmosphere
- percussion
- strings
- brass
- vocal
- sound effect

### Source

- acoustic
- sampled
- analog
- digital
- FM
- wavetable
- granular
- physical modeling
- hybrid

### Envelope

- percussive
- plucky
- sustained
- swelling
- evolving

### Timbre

Continuous axes such as:

```text
dark ←→ bright
warm ←→ cold
clean ←→ dirty
smooth ←→ rough
pure ←→ complex
stable ←→ unstable
tonal ←→ noisy
thin ←→ thick
dry ←→ spacious
mono ←→ wide
static ←→ evolving
soft ←→ aggressive
vintage ←→ modern
organic ←→ synthetic
```

The ontology should not become the only search mechanism.

Its purpose is to give Seshat an **interpretable representation of intent**.

---

## 6. LLM's proper role

The LLM should interpret the musician.

It should **not** be responsible for knowing what 20,000 presets sound like.

Example:

```text
User:

"Something like a cold Depeche Mode synth,
but softer and less obviously 80s."
```

LLM:

```json
{
  "role": "synth",
  "reference": {
    "artist": "Depeche Mode"
  },
  "qualities": {
    "cold": 0.75,
    "dark": 0.60,
    "vintage": 0.45,
    "soft": 0.65,
    "synthetic": 0.80
  }
}
```

The retrieval system then finds candidates.

This is a key architectural rule:

> **LLM = query understanding. Retrieval system = sound knowledge.**

Do not ask an LLM to ingest thousands of preset descriptions and choose directly.

---

## 7. Strategy C — Search the actual audio

This is the most important strategy to evaluate.

Native Instruments supplies audio previews for NKS presets so sounds can be auditioned before an instrument is loaded.

If Seshat can reliably map those previews to their presets, it has access to something far more useful than tags:

> **what the preset actually sounds like**

Each preset could therefore contain:

```text
SoundCandidate
├── metadata
├── NKS tags
├── semantic text embedding
├── audio preview
├── audio embedding
└── DSP features
```

---

## 8. CLAP

CLAP — Contrastive Language-Audio Pretraining — is particularly relevant.

CLAP places text and audio into a shared embedding space.

The LAION implementation supports:

```text
text → embedding

audio → embedding
```

and supports audio/text retrieval. Music-specific pretrained checkpoints are also available.

Therefore:

```text
User:

"dark metallic industrial bass"
        ↓
CLAP text encoder
        ↓
vector
        ↓
cosine similarity
        ↓
CLAP vectors of actual preset audio
```

The preset does not need to have been tagged "industrial."

If its audio representation resembles what CLAP associates with the description, it can surface.

This is qualitatively different from semantic metadata search.

---

## 9. Strong evidence that this architecture is practical

A particularly relevant existing project is:

**sas-patch-service**

It implements essentially the experiment Seshat needs:

> natural-language → synthesizer patch retrieval

over thousands of Surge XT patches.

Its pipeline is:

```text
synth patches
    ↓
deterministic MIDI probes
    ↓
render audio
    ↓
LAION-CLAP audio embeddings
    ↓
vector index

natural-language query
    ↓
CLAP text embedding
    ↓
nearest patches
```

It uses multiple deterministic MIDI probes, including:

- low-register rhythmic material,
- sustained low note,
- mid-register phrase,
- held chord.

The key observation is important:

A synth preset is not merely a static audio recording. It is a sound generator whose identity depends partly on how it is played.

This is strong evidence that the same architecture is worth evaluating for Seshat.

Another relevant project is **synth-setter**, which also explores CLAP-conditioned synthesizer-patch search and matching.

---

## 10. Preview audio vs standardized rendering

There are two approaches.

### Option 1 — NI preview audio

Use the existing NKS previews.

#### Advantages

- Already generated.
- Almost zero indexing cost.
- Represents how NI intends the sound to be presented.
- Potentially available for enormous numbers of presets.

#### Problem

The musical input is not standardized.

Imagine:

```text
Preset A:
C1 bass riff

Preset B:
C4 chord

Preset C:
melodic sequence
```

CLAP may partly respond to:

- pitch,
- harmony,
- rhythm,
- register,

rather than pure timbre.

That introduces noise.

---

## 11. Strategy D — Standardized preset renders

A stronger long-term approach is to make Seshat **listen to every preset under controlled conditions**.

For example:

### Bass

```text
C1 sustained
C2 sustained
short bass riff
velocity sweep
```

### Lead

```text
C3 sustained
C4 sustained
monophonic phrase
```

### Pad

```text
C3 sustained
C-minor chord
C-major-7 chord
```

### Pluck

```text
velocity-varied repeated notes
short phrase
```

### Drum

```text
individual hits
velocity sweep
```

Render these through Live automatically.

Then:

```text
preset
   ↓
controlled MIDI probes
   ↓
rendered audio
   ↓
audio embedding(s)
```

The preset representation could be either:

```text
mean(probe embeddings)
```

or retain multiple vectors:

```text
bass_low
bass_phrase
sustain
chord
etc.
```

The latter is likely better.

### Recommendation

**Do not build the full renderer first.**

Evaluate:

1. NI previews.
2. Standardized renders.

If previews perform almost as well, use them.

If standardized probes materially improve ranking, automate rendering later.

---

## 12. Strategy E — DSP/acoustic features

CLAP embeddings are powerful but opaque.

Add conventional audio measurements.

Useful descriptors include:

```text
spectral centroid
spectral rolloff
spectral spread
spectral flatness
spectral flux
attack time
decay profile
RMS envelope
dynamic range
zero-crossing rate
stereo width
pitch stability
harmonicity
noise ratio
modulation rate
```

This gives Seshat deterministic interpretation of requests such as:

> darker

> brighter

> shorter attack

> wider

> noisier

> less dynamic

Embedding similarity might retrieve candidates first.

DSP features can rerank them.

---

## 13. Alternative music representation models

CLAP should be the first audio/text model evaluated, but it should not be treated as guaranteed best.

### MERT

MERT is specifically trained for acoustic music understanding and performs strongly across numerous music-information tasks.

However, MERT is primarily useful for **audio representation**, not natural-language ↔ audio retrieval.

It may eventually be useful for:

```text
"more like this preset"
```

or audio-to-audio similarity.

### MuQ / MuQ-MuLan

MuQ is a newer music-specific representation model.

MuQ-MuLan provides joint music/text representations and is therefore a legitimate candidate to benchmark against CLAP.

### Recommendation

Initial benchmark:

```text
LAION CLAP music checkpoint
vs
MuQ-MuLan
```

Do not assume a general-purpose CLAP checkpoint is optimal for synthesizer timbre.

---

## 14. Strategy F — reference-song intelligence

Requests such as:

> "the synth from Enjoy the Silence"

are not ordinary semantic queries.

They contain an external cultural reference.

Seshat needs a `ReferenceResolver`.

Conceptually:

```text
"bass like Enjoy the Silence"
        ↓
identify reference
        ↓
resolve musical component
        ↓
production knowledge
        ↓
sonic description
        ↓
normal sound retrieval
```

Example output:

```json
{
  "reference_type": "recording",
  "artist": "Depeche Mode",
  "song": "Enjoy the Silence",
  "role": "bass",
  "properties": {
    "analog": 0.9,
    "subtractive": 0.9,
    "mono": 0.9,
    "dark": 0.65,
    "punchy": 0.75,
    "vintage": 0.85
  }
}
```

Then the normal retrieval system takes over.

---

## 15. Production/gear knowledge graph

Reference resolution would benefit from a relatively small knowledge layer describing historically important sound sources.

Example:

```text
Minimoog
├── analog
├── subtractive
├── mono
├── bass
├── lead
├── thick
└── vintage

DX7
├── digital
├── FM
├── metallic
├── glassy
├── electric piano
└── 1980s

Juno
├── analog
├── polyphonic
├── chorus
├── pad
├── warm
└── vintage

Fairlight / Emulator
├── sampler
├── early digital
├── grainy
├── vintage
└── sample-based
```

Then:

```text
artist/song
    ↓
historical gear / technique
    ↓
sonic properties
    ↓
available NI equivalents
```

Seshat does not need the original hardware.

It needs the closest **sonic function available locally**.

The graph could initially cover perhaps:

- ~100 historically important synths,
- samplers,
- drum machines,
- keyboards,
- production techniques.

An LLM can reason over this graph extremely well.

---

## 16. Web research as a reference resolver fallback

It would be unrealistic to manually encode every recording.

For obscure references:

```text
"the synth on track X by artist Y"
```

Seshat could perform targeted research.

Potential evidence:

- artist interviews,
- producer interviews,
- studio documentation,
- credible gear sites,
- liner notes,
- fan research where nothing better exists.

The output should be **sonic intent**, not necessarily a declaration that one exact synthesizer was used.

Gear information is frequently contradictory.

Therefore:

```text
ReferenceEvidence {
    possible_sources: [...]
    confidence: ...
    derived_sound_profile: ...
}
```

is preferable to:

```text
instrument = Minimoog
```

---

## 17. Strategy G — audio reference search

This should eventually become a first-class interaction:

> "Find something like this."

Sources could include:

- selected audio clip,
- imported reference recording,
- resampled track section,
- microphone input,
- user's vocal imitation,
- current instrument.

Pipeline:

```text
reference audio
      ↓
audio embedding
      ↓
preset audio index
      ↓
nearest neighbors
```

This removes the language bottleneck entirely.

Modern embeddings make this relatively straightforward once the preset audio index exists.

---

## 18. Relative queries

Once presets have embeddings and interpretable properties, another powerful UX becomes possible:

> darker

> warmer

> less aggressive

> more organic

> more like this but wider

> same idea, but vintage

These should not start a search from scratch.

Suppose:

```text
current_sound_embedding = S
```

and user asks:

> darker

Seshat can search locally around `S` while applying a direction or constraint corresponding to darkness.

Conceptually:

```text
similarity(candidate, current_sound)
+
darkness(candidate)
```

This is likely much more musically useful than asking for a new description each time.

---

## 19. Arrangement-aware retrieval

Eventually, the best sound should not merely match the description.

It should fit the project.

Imagine:

```text
Request:
"give me a dark pad"
```

Candidate A may be the world's best dark pad.

But if it occupies the same spectrum as:

```text
vocals
guitars
existing synth
```

it may be the wrong production decision.

Seshat can eventually consider:

```text
frequency occupancy
stereo occupancy
transient density
register
existing timbral redundancy
arrangement role
```

Final scoring could become:

```text
score =

semantic_match
+ audio_text_match
+ reference_match
+ role_match
+ arrangement_fit
+ user_preference
- redundancy
```

This should **not** be part of the first prototype.

But the architecture should allow it.

---

## 20. Personal preference learning

Seshat already tracks usage.

Expand this eventually to implicit preference signals:

```text
candidate shown
candidate auditioned
candidate selected
candidate rejected
candidate replaced immediately
candidate still present after 10 minutes
candidate still present next session
candidate favorited
```

Then the system learns things such as:

```text
user strongly prefers darker basses
user tends to choose Monark over Massive X
user dislikes highly animated pads
user likes noisy sampled keyboards
```

Preference should be a reranker, not the primary retrieval mechanism.

Otherwise Seshat will repeatedly recommend the same sounds.

---

## 21. Diversified top 3–5

Do not simply return the five nearest vectors.

Nearest-neighbor results frequently cluster.

Instead, deliberately diversify.

Example:

> "dark Depeche Mode-style bass"

Could return:

```text
1. Monark preset
   Closest historically styled analog interpretation.

2. Massive X preset
   Similar character but more modern and controlled.

3. Reaktor preset
   Rougher/modular interpretation.

4. Kontakt sampled synth
   More recorded/sample-based interpretation.
```

Use something like Maximum Marginal Relevance:

```text
selection_score =
    relevance_to_query
    -
    λ * similarity_to_already_selected_candidates
```

This makes multiple suggestions useful instead of redundant.

---

## 22. Proposed architecture

```text
                         USER REQUEST
                              │
                              ▼
                     Intent Interpreter
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
      sound terms       reference resolver     constraints
                                                  │
          └───────────────────┼───────────────────┘
                              ▼
                         SoundIntent
                              │
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
        NKS/tags        metadata vector     audio vector
        retrieval         retrieval          retrieval
            │                 │                 │
            └─────────────────┼─────────────────┘
                              ▼
                        Candidate Pool
                           ~25–100
                              │
                              ▼
                           Reranker
                              │
               ┌──────────────┼──────────────┐
               ▼              ▼              ▼
           DSP match      project fit     user taste
               │              │              │
               └──────────────┼──────────────┘
                              ▼
                       Diversity Reranker
                              │
                              ▼
                         Top 3–5 Sounds
                              │
                              ▼
                            Audition
                              │
                              ▼
                         User selection
                              │
                              ▼
                       preference history
```

---

## 23. Important engineering choice: don't start with a vector database

The corpus is small.

Even if Collector's Edition gives us:

```text
10,000
20,000
50,000
```

presets, this is trivial by modern vector-search standards.

For example:

```text
20,000 presets
×
512 float32 dimensions
×
4 bytes

≈ 41 MB
```

Even several vectors per preset remain perfectly manageable locally.

For the first implementation:

```text
SQLite metadata
+
flat embedding file / SQLite blobs / ETS
+
NumPy/Python similarity service
```

is enough.

Do not introduce Pinecone, Weaviate, Milvus, etc. unless scale actually requires it.

Local execution is especially attractive for Seshat.

---

## 24. Model/service boundary

Seshat is Elixir.

Most audio ML tooling is Python.

Do not attempt to port CLAP into Elixir.

Recommended architecture:

```text
Seshat / Elixir
       │
       │ local request
       ▼
Sound Intelligence Service / Python
       │
       ├ CLAP
       ├ MuQ experiments
       ├ DSP analysis
       └ vector similarity
```

This service could eventually be packaged with Seshat.

The user query path should remain extremely fast because preset audio embeddings are precomputed.

Only the query text needs encoding at runtime.

---

## 25. Recommended experiments

Do **not** immediately build the complete system.

Build a benchmark.

### Corpus

Start with approximately:

```text
500–1,000 presets
```

covering:

- Massive X
- Monark
- Kontakt synth libraries
- Reaktor
- FM/digital sounds
- acoustic keyboards
- orchestral sounds
- unusual textures

Make the corpus deliberately diverse.

---

## 26. Retrieval systems to compare

### Baseline A — Current Seshat

Existing tag/name/catalog search.

### Baseline B — Semantic metadata

NKS + Ableton metadata converted to textual descriptions and embedded.

### System C — CLAP + NI preview audio

Natural language encoded through CLAP and compared directly with NKS preview audio embeddings.

### System D — CLAP + standardized renders

Render each preset using controlled MIDI probes and embed those.

### System E — Hybrid

Candidate score derived from:

```text
semantic metadata similarity
+
CLAP audio similarity
+
NKS tag match
+
DSP feature match
```

This is currently the strongest architectural hypothesis.

---

## 27. Benchmark queries

Create at least ~100 human-written queries.

They should intentionally include difficult cases.

### Straightforward

```text
warm analog bass
bright acoustic piano
soft orchestral strings
dark synth pad
```

### Subjective

```text
lonely piano
evil bass
dreamy synth
anxious texture
seductive pad
```

### Metaphorical

```text
melting VHS synth
broken children's toy
angry refrigerator bass
underwater piano
a machine slowly dying
```

### Production language

```text
bass that will sit underneath a dense guitar mix
pad without much attack
wide texture with no low end
something dark but not muddy
```

### Historical

```text
Juno-style pad
DX7-style keys
Minimoog bass
Fairlight-ish choir
early digital sampler
```

### Artist references

```text
Depeche Mode bass
Boards of Canada synth
Nine Inch Nails texture
Beach House keyboard
Aphex Twin pad
```

### Song references

Specific recognizable recordings.

### Relative

```text
darker than this
warmer
less synthetic
more unstable
same thing but wider
```

---

## 28. Evaluation method

Do not evaluate by whether the model's cosine similarity looks sensible.

Use human listening.

For every query:

```text
System A → top 5
System B → top 5
System C → top 5
System D → top 5
System E → top 5
```

Blind the source system.

Score:

```text
0 = irrelevant
1 = weak
2 = plausible
3 = good
4 = excellent
```

Also measure:

### Precision@5

How many of the five suggestions are genuinely useful?

### Best-of-5

Does at least one excellent result appear?

This is probably the most important Seshat metric.

### Top-1

Was the first recommendation good enough to load automatically?

### Diversity

Are the choices meaningfully different?

### Semantic robustness

Does performance survive metaphorical and artist-reference language?

### Latency

Target runtime retrieval should ideally feel instant.

---

## 29. Critical experiment: preview vs standardized render

This determines whether a potentially large engineering effort is necessary.

Compare:

```text
NI preview CLAP embedding
```

against:

```text
standardized MIDI probe CLAP embedding
```

If:

```text
preview ≈ standardized
```

use NI previews.

That eliminates a huge indexing problem.

If:

```text
standardized >> preview
```

then automated rendering is justified.

We should measure instead of assuming.

---

## 30. Recommended implementation path

### Phase 0 — Evaluation harness

Build:

```text
preset corpus
query corpus
retrieval interface
blind listening evaluator
metrics
```

This is essential.

Otherwise every architectural decision becomes subjective.

### Phase 1 — NKS + semantic metadata

Implement:

- NKS metadata ingestion,
- unified SoundCandidate,
- SoundIntent schema,
- LLM intent extraction,
- text embeddings,
- semantic retrieval,
- diversified top-N.

This is the lowest-risk production improvement.

### Phase 2 — CLAP preview experiment

Map:

```text
NKS preset ↔ preview audio
```

Generate CLAP embeddings.

Evaluate:

```text
current
vs
metadata
vs
CLAP
vs
hybrid
```

If CLAP provides little benefit, stop here.

If it materially improves results, continue.

### Phase 3 — Standardized render experiment

For a smaller subset:

```text
100–500 presets
```

automatically render deterministic probes.

Compare against NI previews.

Only build full-library rendering if improvement is significant.

### Phase 4 — ReferenceResolver

Add:

```text
artist
song
gear
era
production technique
```

resolution.

Start with a curated gear ontology plus LLM reasoning.

Add web research only as fallback.

### Phase 5 — Audio-to-audio retrieval

Support:

> "Find something like this."

Use selected/current audio as the query.

This becomes straightforward once the preset audio index exists.

### Phase 6 — Contextual producer intelligence

Later:

- arrangement fit,
- spectral competition,
- timbral redundancy,
- user preference learning,
- relative sonic navigation.

---

## 31. Recommendation

Three approaches are worth formally evaluating.

### Recommendation A — Semantic NKS retrieval

**Difficulty:** Low  
**Risk:** Low  
**Expected improvement:** High  
**Should build regardless:** Yes

Use NKS + Ableton metadata + semantic text embeddings.

This should replace pure lexical search as the default retrieval layer.

### Recommendation B — CLAP preset-audio retrieval

**Difficulty:** Medium  
**Risk:** Medium  
**Potential improvement:** Very high  
**Should prototype:** Absolutely

Embed actual NI preset previews with a music-capable CLAP model and search them directly using natural language.

This is the most important experiment.

### Recommendation C — Hybrid retrieval

**Difficulty:** Medium  
**Risk:** Low after A/B exist  
**Potential quality:** Highest

Combine:

```text
NKS semantics
+
metadata embedding
+
audio embedding
+
DSP descriptors
```

rather than trusting any one representation.

My expectation is that this will ultimately win.

For example:

```text
candidate_score =

0.45 * CLAP_similarity
+
0.25 * metadata_similarity
+
0.20 * structured_intent_match
+
0.10 * DSP_match
```

The numbers are placeholders and should be learned/tuned from the evaluation corpus.

---

## 32. What to build first

The immediate engineering spike should be narrowly scoped:

# Semantic Sound Retrieval Spike

### Dataset

~1,000 Collector's Edition presets.

### Build

For every preset:

```text
preset ID
product
bank
name
NKS type
NKS subtype
NKS character
Ableton metadata
NI preview path
text embedding
CLAP audio embedding
```

### Implement four search commands

```text
search-current "..."
search-semantic "..."
search-audio "..."
search-hybrid "..."
```

### Test corpus

100 difficult musician queries.

### Deliverable

Blind listening comparison.

---

## 33. Go/no-go criteria

Proceed with full audio indexing if CLAP/hybrid retrieval produces something like:

```text
≥20% improvement in human-rated Best-of-5
```

over semantic metadata retrieval.

Proceed with standardized full-library rendering only if it produces a meaningful additional improvement over NI previews.

This prevents Seshat from accumulating a large audio-rendering subsystem for marginal gain.

---

## 34. Longer-term product vision

This work should not be thought of merely as "better instrument selection."

It creates a **Sound Intelligence layer**.

Once Seshat has a perceptual model of every available sound, the same infrastructure enables:

```text
"find me a bass"

"something like this"

"darker"

"more analog"

"the Depeche Mode version of this"

"give me three alternatives"

"replace this synth with something less busy"

"find something that won't fight the vocal"

"make this feel older"

"what do I own that sounds like a Fairlight?"

"find an acoustic instrument with a similar character"

"give me something unexpected but compatible"
```

Those are all variants of one underlying problem:

```text
musical intention
        ↓
sound-space representation
        ↓
retrieval + ranking
```

That infrastructure can later support orchestration, arrangement, automatic sound replacement, project-aware production suggestions, and AI-assisted sound design.

---

# Final Architectural Recommendation

The proposed target is:

```text
                         SOUND INTELLIGENCE

User language ──────► SoundIntent
                          │
Reference knowledge ─────┤
                          │
NKS metadata ─────────────┤
                          ▼
                    candidate retrieval
                          │
             ┌────────────┼────────────┐
             ▼            ▼            ▼
           tags        semantics      AUDIO
                                       │
                                       ▼
                                    CLAP/MuQ
                                       │
             └────────────┬────────────┘
                          ▼
                       reranker
                          │
                    DSP / context
                          │
                     diversification
                          │
                          ▼
                    BEST 3–5 SOUNDS
```

The most important near-term question is **not** which final architecture to choose.

It is:

> **How much additional retrieval quality do actual preset audio embeddings provide over rich semantic NKS metadata?**

That question is inexpensive to answer with a controlled 1,000-preset experiment.

Answer it first.

If audio embeddings perform as expected, Seshat should evolve from a catalog that knows **what presets are called** into a system that has a computational representation of **what every preset actually sounds like**.

That is the foundation to build.

---

## External References

- Native Instruments NKS / Browser documentation:
  https://docs.native-instruments.com/ni-tech-manuals/kontrol-s-mk3-manual/en/the-browser
- Native Instruments Komplete Kontrol browser and preset auditioning:
  https://docs.native-instruments.com/ni-tech-manuals/komplete-kontrol-manual/en/browser-and-presets.html
- LAION CLAP:
  https://github.com/LAION-AI/CLAP
- sas-patch-service:
  https://github.com/shiehn/sas-patch-service
- synth-setter:
  https://github.com/tinaudio/synth-setter
- Essentia:
  https://essentia.upf.edu/
- MERT:
  https://arxiv.org/abs/2306.00107
- MuQ / MuQ-MuLan:
  https://arxiv.org/abs/2501.01108
