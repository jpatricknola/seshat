# Seshat Handoff: Generate Harmony from Selected MIDI

---

## Status against the codebase — updated 2026-08-30, after PR #84

**Nothing in this brief is built.** But `generate_midi` (PR #84, "MIDI
generation — the first solution, composed symbolically") shipped the same day
and paid down most of the *plumbing* under steps 9–11 of the MVP pipeline. The
harmony **engine** — steps 1–8 — is untouched. Read this section before
planning: it changes what the work is, not whether it is needed.

The companion evaluation is
[harmony-from-a-melody-options.md](generative%20features/harmony-from-a-melody-options.md),
which reaches the same architectural verdict this brief does (deterministic
rules in Elixir, no model for the MVP) and records what was measured live.
**There is still no `docs/ROADMAP.md` entry for this feature.**

### Already built and reusable

| This brief's step | What exists now | Where |
|---|---|---|
| 9–11 · write generated notes into Live | Chunked writes through `/live/clip/add/notes_extended` (200 notes per datagram) with a **windowed read-back** that tolerates float32 wire truncation and reports honestly when a clip cannot be confirmed | `lib/seshat/generation/midi_parts.ex` |
| §Key Design Principle · carry the source's expression | `probability`, `velocity_deviation` and `release_velocity` now go out on the wire — and were **measured persisting as sent** on Live 12.4.5, 2026-08-30, the first read-back ever. A harmony voice can inherit the melody's expression, not just its pitch and timing | same, plus `priv/AbletonOSC/API.md` |
| 7 · new adjacent MIDI track, 10 · aligned clip | The multi-part workflow spine: compile everything pure → guards → create tracks → load instrument → write → read back → honest partial reply. Track creation, naming, and view-follow are all in it | `midi_parts.ex`, `Seshat.Commands.Registry` |
| §Output · one editable, undoable result | The whole call sits inside one Live undo step by construction — the brief's "user can delete it" is one `undo` | `Seshat.Tools.Handlers` undo bracket |
| 1 · selection resolution (partial) | `get_view_state` now reports the **selected scene** | `lib/seshat/tools/handlers.ex` |
| §Deterministic engine · velocity behaviour | The scale-and-clamp machinery for velocities (bands, per-class ordering) exists and is tested — the brief's `velocity ≈ source × 0.85` is a parameter, not new code | `lib/seshat/generation/midi/performance.ex` |

### Still needed — all of it harmony-specific

1. **Selection resolution (step 1).** No tool reads Live's note selection.
   `/live/clip/get/selected_notes_extended` and
   `/live/view/get/highlighted_clip_slot` are **registered in the fork and
   unused by `lib/`** — a tool-layer gap, not a fork gap, not a Live limit.
2. **Harmonic context (step 2) — the brief is right that this is the biggest
   dependency.** Seshat mirrors only `root_note` and `scale_name`
   (`Seshat.Session.State`). Nothing infers a chord progression, and
   `/live/song/get/scale_intervals` — the address that gives Live's *actual*
   degree table rather than a hardcoded one — is registered and unused.
   Clip-level scale is absent from the LOM entirely (a Live limit, recorded in
   the options doc).
3. **The engine itself (steps 4–8).** Candidate pitch generation, scoring,
   and the phrase-level voice-leading optimiser do not exist in any form.
   `generate_midi`'s bass lane is **not** a precedent: it takes roots Claude
   supplies and follows the kick's onsets — it never chooses a pitch against a
   chord (`lib/seshat/generation/midi/bass.ex`).
4. **A tool surface.** `generate_midi` composes from step patterns and explicit
   roots; its schema cannot express "harmonise this clip". This needs its own
   tool (the options doc argues for one `harmonize_melody` call, because
   composing it from six existing calls would be six undo steps and fail the
   brief's editability story).
5. **The brief's own naming and alternatives** — `<source track> Harmony`,
   A/B/C variants, density below 100 % — none of it exists.

### What this changes about sequencing

The MVP is now smaller than this brief assumed: the write-back half is a
solved, tested, live-verified path to reuse rather than build. What remains is
almost entirely **pure Elixir with no Ableton in the loop** — pitch choice,
scoring, voice leading — which is the half that can be unit-tested without
Live running at all.

---

## Summary

Add a Seshat command that takes a user-selected MIDI melody in Ableton and generates a musically sensible harmony part aligned to the original notes.

Example user commands:

- “Generate a harmony for this.”
- “Add a harmony below this.”
- “Give me a high harmony.”
- “Make this a close vocal harmony.”
- “Mostly thirds, but make it fit the chords.”

This feature should **not** be implemented as unconstrained MIDI generation. The selected MIDI already provides the rhythmic performance. Seshat should preserve the source timing and primarily generate the **harmony pitches and phrase-level harmony decisions**.

The MVP should use the existing Ableton/LOM integration rather than Ableton Extensions.

---

## Product Goal

Let the user select a monophonic MIDI melody and ask Seshat to create an editable MIDI harmony part that:

- preserves the original note timing,
- makes harmonic sense against the song,
- uses smooth voice leading,
- respects a requested upper/lower register,
- and can later support stylistic instructions such as “dreamy,” “gospel,” “sparse,” or “strange.”

The result should feel like an arranged harmony part rather than a fixed pitch-shift.

---

## Core User Story

1. User selects a MIDI clip or selected MIDI notes in Ableton.
2. User says:

   > “Generate a harmony below this.”

3. Seshat reads the selected MIDI and relevant project context.
4. Seshat determines the harmonic context.
5. Seshat generates a harmony pitch for each source note.
6. Seshat creates a new MIDI clip aligned with the source.
7. Seshat places it on a new adjacent MIDI track, for example:

   `Lead Vocal Harmony`

8. User can immediately audition, edit, mute, regenerate, or delete it.

---

## Non-Goal

This is **not** initially:

- free-form accompaniment generation,
- a complete arrangement model,
- audio vocal harmonization,
- realtime harmonization,
- chord-generation from scratch,
- or arbitrary multitrack composition.

The first version should solve a tightly constrained problem well:

> Given an existing melody and harmonic context, create a second MIDI voice that fits it.

---

## Key Design Principle

Separate **rhythm** from **pitch generation**.

The selected MIDI already contains:

- note onsets,
- note durations,
- rhythmic phrasing,
- velocity,
- clip position.

The harmony generator should normally preserve:

```text
source.start == harmony.start
source.duration == harmony.duration
```

The primary generated value is:

```text
harmony.pitch
```

Later versions may also decide:

- whether a source note should receive harmony at all,
- whether the harmony should temporarily move to unison,
- octave/register,
- phrase-level entrances and exits,
- velocity differences,
- slightly altered note lengths.

This constrained formulation should make the feature considerably more reliable than generic MIDI generation.

---

## Example

### Input

Chord progression:

```text
Am       F        C        G
```

Melody:

```text
C E E    C A      G E      D B
```

### Possible output

```text
Melody:   C  E  E | C  A | G  E | D  B
Harmony:  A  C  C | A  F | E  C | B  G
```

The source rhythm remains unchanged.

The harmony notes change according to the underlying harmony and voice-leading context.

---

# Proposed Architecture

```text
User command
    ↓
Seshat Planner
    ↓
Resolve selected MIDI
    ↓
Read musical/project context
    ↓
Harmony Intent
    ↓
Harmony Generator
    ↓
Validation / voice-leading pass
    ↓
Generated MIDI notes
    ↓
LOM write-back
    ↓
New harmony clip/track
```

---

## 1. Selection Resolution

Seshat should use the existing Ableton/LOM integration to identify the selected MIDI source.

Required source data:

```text
clip
track
note pitch
note start
note duration
note velocity
clip start/end
```

For MVP, assume the selected material is primarily monophonic.

If the selected MIDI is polyphonic, possible initial behaviors are:

1. reject with a clear message,
2. use the highest note as the melody,
3. infer a melody line.

Recommendation for MVP:

> Require or strongly prefer monophonic source MIDI.

---

## 2. Musical Context Acquisition

The quality of the harmony depends heavily on knowing the harmony underneath the melody.

Preferred context sources, in priority order:

1. Explicit chord data already known to Seshat.
2. Dedicated chord track / chord annotations.
3. Existing MIDI accompaniment around the selected range.
4. Seshat harmonic analysis of surrounding MIDI.
5. Song key only.
6. Melody-only fallback.

Useful context:

```text
key
mode
chord progression
tempo
time signature
bar positions
neighboring MIDI notes
bass notes
existing harmony parts
```

### Important

The same melody pitch can require a different harmony depending on the current chord.

Example: melody note `C`.

Over `Am`:

```text
Melody:  C
Harmony: A
```

Over `F`:

```text
Melody:  C
Harmony: F
```

Over `C`:

```text
Melody:  C
Harmony: E
```

Therefore the implementation should **not** simply transpose the melody by a fixed interval.

---

## 3. Intent Parsing

The planner should convert natural-language instructions into structured harmony constraints.

Example:

> “Give this a high dreamy harmony.”

Possible internal representation:

```json
{
  "direction": "above",
  "register": "high",
  "density": 0.7,
  "style": "dreamy",
  "preferred_intervals": ["third", "sixth"],
  "allow_unison": true,
  "preserve_rhythm": true
}
```

### MVP intent schema

For the first version, keep this small:

```text
direction:
  above
  below
  auto

preserve_rhythm:
  true

density:
  1.0
```

Supported MVP commands:

- “Generate harmony.”
- “Generate harmony above.”
- “Generate harmony below.”

---

# Harmony Generation

## 4. Candidate Pitch Generation

For every melody note, generate a set of plausible harmony pitches based on:

- current chord,
- current key/scale,
- requested direction,
- requested register,
- reasonable interval range.

Example:

```text
Chord: C major
Melody: E4

Possible harmony candidates:

C4
G4
C5
G3
```

Candidates should initially favor:

- chord tones,
- consonant scale tones,
- thirds,
- sixths,
- occasional fourths/fifths where stylistically appropriate,
- unison when permitted.

---

## 5. Candidate Scoring

Each candidate should receive a score.

Possible scoring components:

```text
harmonic_fit
voice_leading
interval_preference
register_fit
direction_fit
style_fit
```

Possible penalties:

```text
voice_crossing
large_leap
non-chord dissonance
out_of_range
awkward repeated intervals
unwanted parallel motion
```

Conceptually:

```text
score =
    harmonic_fit
  + voice_leading
  + interval_preference
  + register_fit
  - penalties
```

The highest-scoring note is not necessarily chosen independently for each event.

The system should optimize the **whole phrase** when practical.

---

## 6. Voice Leading

The harmony should behave like a musical line, not a sequence of locally valid notes.

The generator should prefer:

- stepwise motion,
- small leaps,
- sensible resolutions,
- stable register,
- avoiding unnecessary voice crossing,
- avoiding sudden octave jumps.

A simple dynamic-programming/Viterbi-style optimizer is a good fit:

```text
note 1 candidates
      ↓
note 2 candidates
      ↓
note 3 candidates
      ↓

find highest-scoring path across the phrase
```

This lets the system optimize both:

- harmony against the current chord,
- motion from the previous harmony note.

---

# Deterministic vs AI Responsibilities

## 7. Deterministic Harmony Engine

The deterministic layer should own musical correctness.

Responsibilities:

- preserve timing,
- determine legal candidate pitches,
- chord compatibility,
- scale compatibility,
- register limits,
- direction constraints,
- voice crossing,
- basic voice leading,
- pitch range,
- final validation.

This layer should make it difficult for an LLM or generative model to produce obviously invalid harmony.

---

## 8. AI / Interpretation Layer

AI should initially handle the subjective decisions rather than low-level pitch validity.

Examples:

- should harmony enter immediately or later?
- how dense should it be?
- thirds vs sixths?
- should cadences resolve to unison?
- should the harmony be smooth or more angular?
- should it answer only phrase endings?
- what does “dreamy,” “gospel,” or “creepy” mean in terms of constraints?

Example:

User:

> “Give me a sparse upper harmony that feels dreamy.”

Interpretation layer:

```text
direction = above
density = 0.55
prefer sixths on sustained notes
allow thirds
avoid harmonizing pickup notes
enter mostly at phrase endings
allow occasional unison resolution
```

The deterministic harmony engine then finds the actual pitches.

---

# Phrase-Level Behavior

## 9. Harmony Density

A strong future version should not necessarily harmonize every note.

Example:

```text
Melody:   ████████████████████████
Harmony:       ██████     ████████
```

Possible phrase decisions:

```text
phrase 1 → melody alone
phrase 2 → harmony enters on final three notes
phrase 3 → full harmony
phrase 4 → resolve to unison
```

This is an important distinction between:

```text
mechanical pitch shift
```

and:

```text
arranged harmony part
```

For MVP, density can remain 100%.

---

# Ableton Write-Back

## 10. Output Behavior

Recommended MVP output:

```text
Source:
Lead Vocal MIDI

Generated:
Lead Vocal Harmony
```

Create:

- a new adjacent MIDI track,
- a new MIDI clip aligned to the source,
- identical clip/range length,
- generated notes at the corresponding positions.

The user should be able to:

- mute the harmony,
- edit individual notes,
- delete it,
- regenerate it,
- compare alternatives.

Avoid modifying the original clip by default.

---

## 11. Suggested Track Naming

Default:

```text
<source track name> Harmony
```

Examples:

```text
Lead Vocal Harmony
Synth Lead Harmony
Hook Harmony
```

For multiple candidates:

```text
Lead Vocal Harmony A
Lead Vocal Harmony B
Lead Vocal Harmony C
```

---

# MVP

## 12. MVP Command

Example:

> “Generate a harmony below this.”

### MVP pipeline

```text
1. Resolve selected monophonic MIDI.
2. Read source notes.
3. Determine key/chord context.
4. Copy note onset and duration.
5. Generate candidate pitches below the melody.
6. Score candidates for harmonic fit.
7. Optimize for smooth voice leading.
8. Validate result.
9. Create a new MIDI track.
10. Create aligned MIDI clip.
11. Write generated notes into Live.
```

### MVP constraints

- monophonic source,
- one generated harmony voice,
- preserve rhythm exactly,
- 100% harmony density,
- `above`, `below`, or `auto`,
- prioritize chord tones,
- favor thirds/sixths,
- simple voice-leading optimization,
- deterministic output acceptable initially.

### MVP does not require

- MIDI-GPT,
- Composer's Assistant,
- an external music-generation model,
- Ableton Extensions,
- audio generation,
- realtime processing.

A rule-based/algorithmic harmony engine should be enough to validate the product behavior.

---

# Version 2

Add natural-language interpretation:

- “Give me a high harmony.”
- “Make it dreamy.”
- “Mostly thirds.”
- “Use more sixths.”
- “Keep it close to the lead.”
- “Make it more dramatic.”
- “Only harmonize the ends of phrases.”

Add:

- density control,
- phrase detection,
- unison decisions,
- register profiles,
- interval profiles,
- stylistic presets,
- multiple generated alternatives.

---

# Version 3

More advanced requests:

- “Give me three harmony options.”
- “Make it sound like two actual singers.”
- “Start in unison and gradually split apart.”
- “Make the harmony increasingly dissonant.”
- “Add a low male harmony.”
- “Write a three-part harmony.”
- “Turn this into SATB.”
- “Only add harmony where it improves the melody.”
- “Make the second voice move in contrary motion.”
- “Use a Beach House-like dreamy harmony approach.”

Potential output:

```text
Selected melody
       ↓
Seshat
       ↓
Harmony A — safe
Harmony B — expressive
Harmony C — strange
```

---

# Potential Model Integration

A dedicated generative model is **not required for MVP**.

Later, models such as MIDI-GPT or Composer's Assistant-style symbolic infilling could be used to propose phrase-level harmony candidates.

However, a generative model should probably not own the entire operation.

Recommended architecture:

```text
Natural-language request
        ↓
LLM / interpretation
        ↓
structured harmony strategy
        ↓
candidate generator
        ↓
deterministic harmony constraints
        ↓
voice-leading optimizer
        ↓
optional model ranking / variation
        ↓
validated MIDI
```

The model should contribute creativity while deterministic constraints protect musical validity.

---

# Suggested Internal Interface

Example request:

```json
{
  "source_notes": [
    {
      "pitch": 64,
      "start": 0.0,
      "duration": 0.5,
      "velocity": 88
    }
  ],
  "harmony_context": [
    {
      "start": 0.0,
      "end": 4.0,
      "chord": "Cmaj"
    }
  ],
  "key": "C major",
  "constraints": {
    "direction": "below",
    "density": 1.0,
    "preserve_rhythm": true,
    "preferred_intervals": ["third", "sixth"]
  }
}
```

Example response:

```json
{
  "notes": [
    {
      "pitch": 60,
      "start": 0.0,
      "duration": 0.5,
      "velocity": 78,
      "source_note_index": 0
    }
  ]
}
```

Keeping `source_note_index` or an equivalent mapping will make debugging and future editing easier.

---

# Open Questions

## Harmonic context

How does Seshat currently represent or infer chord progressions?

This is likely the biggest dependency.

Potential approaches:

- explicit chord objects in Seshat's project model,
- analysis of MIDI accompaniment,
- bass + chord-track inference,
- user-provided chord progression,
- key-only fallback.

---

## Selection semantics

What exactly should count as the source when:

- an entire clip is selected,
- only some notes are selected,
- multiple clips are selected,
- multiple tracks are selected?

Recommended initial rule:

> Generate from the selected notes when note selection exists; otherwise use the selected MIDI clip.

---

## Velocity behavior

MVP options:

1. copy source velocity exactly,
2. reduce harmony velocity by a fixed amount,
3. scale velocity proportionally.

Recommendation:

```text
harmony velocity ≈ source velocity * 0.85
```

with min/max bounds.

This makes the harmony naturally subordinate while preserving source dynamics.

---

## Chord tones vs passing tones

A melody may contain:

- suspensions,
- passing tones,
- neighbor tones,
- chromatic notes.

The harmonizer should not force every note into a vertically consonant chord tone if doing so destroys melodic continuity.

A future scoring model should consider:

```text
vertical harmony
+
horizontal voice leading
+
metrical importance
```

Strong beats can receive stricter harmonic weighting than short passing notes.

---

## Polyphonic source handling

Possible future behavior:

- identify highest voice as melody,
- let user say “harmonize the top line,”
- infer the salient melodic voice,
- harmonize an entire chordal part as parallel voicings.

Do not block the MVP on this.

---

# Success Criteria

The MVP is successful if a user can:

1. create or select a melody in Ableton,
2. say “generate a harmony below this,”
3. receive a new aligned MIDI harmony track,
4. play both parts together,
5. hear a result that is consistently harmonically plausible,
6. manually edit the result like any other MIDI clip.

The initial bar should be:

> useful enough that the generated harmony is faster to edit than writing the harmony manually.

It does not need to consistently produce a final-record-quality vocal arrangement on the first generation.

---

# Why This Fits Seshat

The feature matches Seshat's core interaction pattern:

```text
select musical material
        +
state musical intention
        ↓
Seshat interprets project context
        ↓
Seshat performs an editable DAW transformation
```

It also offers a clean boundary between deterministic and generative intelligence:

```text
Deterministic:
timing
harmonic validity
voice leading
range
constraints

AI:
style
density
phrase behavior
creative interval choices
interpretation of language
```

That makes **Generate Harmony** a strong near-term Seshat feature: narrow enough to implement reliably, musically useful, easy to demonstrate, and extensible into richer arrangement behavior later.
