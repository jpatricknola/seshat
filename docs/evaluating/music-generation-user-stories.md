# Music generation — user stories and product acceptance

_Product-intent document · 27 Aug 2026 · informs the audio and MIDI decision
experiments; it is not an implementation plan or a backend recommendation._

## Product promise

A producer can describe new musical material in ordinary language and have it
land in the open Ableton Live set as usable tracks and clips. Generated parts
must respond to one another and to relevant existing material; sharing only a
tempo, key, or style label is not enough. The result should play immediately,
remain editable when MIDI was requested, and leave existing work untouched.

This document uses **part** for one musical role, such as kick, hi-hat, snare,
or bass. Each MIDI part normally lands on its own track. “Stem” is reserved for
rendered audio, where the term is unambiguous.

## Product decisions that shape the first release

- **One request is one reversible action.** A request that creates several
  related tracks is one high-level generation operation and one Ableton undo
  step. It must not be implemented as a loose conversation-time chain of
  independently undoable track, device, and note mutations.
- **MIDI is the default output.** It is the editable form and the feature's
  main differentiator. An explicit audio request selects audio; the response
  always names the form that was created.
- **Session View first.** “This section” means an explicitly named or selected
  Session scene and its clips. If no target is unambiguous, Seshat asks. Writing
  or conditioning against Arrangement ranges is outside the first release.
- **Readable MIDI is the first contextual input.** The first release may
  condition on notes read from existing MIDI clips. An existing audio clip is
  not silently treated as understood: conditioning on user audio requires a
  separate transcription/analysis path and must be described as unsupported
  until that path is measured.

## What “intelligently related” means

Related parts should sound like one performance split across tracks, not
several unrelated generations placed on the same grid. The relationship is
audible in several dimensions:

- **Form:** every part agrees on length, downbeat, phrase boundaries, and
  meaningful moments of repetition or change.
- **Rhythm:** parts deliberately interlock. For example, bass may reinforce
  selected kick hits while leaving space around the snare; hats establish a
  subdivision and swing that the rest of the beat recognizes.
- **Harmony:** pitched parts fit the detected or stated key, chords, and
  harmonic rhythm. “In key” alone is insufficient if the notes fight the
  current chord.
- **Style and feel:** density, velocity shape, microtiming, articulation, and
  register support the same brief. A dusty lo-fi request should not combine a
  lazy kick with rigid, maximal hats and a glossy bass unless requested.
- **Musical hierarchy:** parts have distinct jobs and leave room for one
  another. Coherence does not mean duplicating the same rhythm everywhere.

These are listening requirements on the final clips in Live. Model metrics,
note counts, shared prompt text, and common metadata are not substitutes.

## Core user stories

### 1. Build a beat from a blank project

**Moment:** The open set is blank. The user says, “Make me a dusty lo-fi beat,
four bars, with kick, hi-hat, and snare, as MIDI.”

**Expected result:**

- Three named MIDI tracks and aligned four-bar clips are created: kick,
  hi-hat, and snare. Each track contains only its requested part.
- Compatible instruments or sounds are loaded so the result is immediately
  audible; the user is not left with silent MIDI tracks.
- The three parts form one coherent beat according to the relationship
  criteria above. They are not three independent prompt results that happen
  to share BPM.
- The clips start together, loop cleanly, and preserve performance feel
  through velocity and timing variation.
- One undo removes the generated result without disturbing work that existed
  before the request.

### 2. Build an interacting rhythm section from a blank project

**Moment:** The user says, “Give me a dusty lo-fi beat with kick, snare, hats,
and a bassline.”

**Expected result:**

- Each requested role lands on its own named, immediately audible track and
  aligned clip.
- The bassline is harmonically sensible and interacts with the actual drum
  performance—not merely with the requested BPM. Its rhythm may lock to,
  answer, or deliberately avoid kick events as the style calls for.
- All parts share a recognizable phrase shape and loop boundary while retaining
  enough independence to be edited, muted, replaced, or mixed separately.

### 3. Add a bassline to an existing section

**Moment:** The set already contains drums and other instruments. The user
says, “Add a sparse dub bassline to this section,” optionally adding “as MIDI”
or “as audio.”

**Expected result:**

- A new bass track and clip are created for the relevant section. Existing
  tracks and clips are not rewritten.
- Generation considers the musical contents of the relevant existing clips,
  not only global tempo and key metadata. The bass follows the section’s
  harmony, phrase boundaries, groove, and density while occupying a sensible
  register.
- If MIDI is requested, the result is an editable MIDI clip on a compatible
  instrument. If audio is requested, it is a correctly aligned audio clip on
  an audio track. The response states which form was created.
- If the target section or intended reference tracks cannot be determined
  safely, Seshat asks a focused question instead of conditioning on arbitrary
  material.

### 4. Add a drum part that responds to existing music

**Moment:** The set contains a bassline, chords, or both. The user says, “Add
a restrained broken-beat drum part that follows this groove.”

**Expected result:**

- The new drum material aligns with the existing section and reacts to its
  accents, rests, phrase changes, and density.
- Requested drum roles remain separately editable when MIDI is requested.
- Drum notes trigger the intended sounds on the loaded target instrument;
  technically valid notes on the wrong pads do not count as success.
- Existing clips remain unchanged.

### 5. Add several related parts to an existing section

**Moment:** The user says, “Add percussion and bass to this chorus, but keep
it understated.”

**Expected result:**

- Both new parts respond to the existing chorus and to each other.
- The requested section, clip length, and phrase boundaries are shared across
  the new clips. Nothing is added to unrelated Session scenes.
- The result respects “understated” across note density, dynamics,
  articulation, and register rather than treating it as a track-name label.

## Iteration stories

### 6. Revise one generated part without collateral changes

**Moment:** After hearing a generated rhythm section, the user says, “Keep the
drums, but make the bass half as busy and leave more space for the snare.”

**Expected result:** Only the bass is revised. It remains related to the
unchanged drums, and no unrelated clip or track is modified.

### 7. Ask for an alternative safely

**Moment:** The user says, “Give me another take.”

**Expected result:** A genuinely different but still contextually coherent
take is created in the next suitable empty Session scene on the same tracks.
Replacing the prior take requires clear user intent; an accepted take is never
silently overwritten. Retrieval and generative backends must expose an
explicit variation mechanism rather than returning the same deterministic
choice.

### 8. Preserve explicit musical constraints

**Moment:** The user specifies constraints such as “eight bars,” “A minor,”
“no notes on the first beat,” “MIDI only,” or “use this bass instrument.”

**Expected result:** Hard constraints are obeyed or the response says exactly
which one could not be satisfied. Style language remains a creative brief;
explicit length, placement, output form, and preservation instructions are
contracts.

## Cross-story acceptance criteria

Every core story must satisfy all applicable criteria:

| Area | Acceptance condition |
|---|---|
| Project placement | Tracks and clips appear in the requested or unambiguously current section, with correct start, length, and loop settings. |
| Separation | Each requested editable part is independently muteable and editable; no requested role is trapped in a mixed MIDI clip. |
| Immediate playback | Generated tracks have compatible devices or audio routing and make sound without manual repair. |
| Context use | Existing-note rhythm and harmony are considered when the story asks to fit existing music; reading only tempo/key fails this criterion. |
| Cohesion | A blinded listener can hear intentional rhythmic, harmonic, and formal relationships among parts. |
| Feel | Timing and velocities fit the requested style and avoid accidental mechanical uniformity. |
| Safety | Existing material is preserved, the mutation is reversible, and alternatives do not silently overwrite accepted work. |
| Honest result | The response distinguishes MIDI from audio, names what was created, and reports unsupported or unverifiable constraints rather than claiming success. |
| Responsiveness | Generator compute stays within the roughly ten-second model budget. Complete request latency—including track creation, sound selection, device loading, clip writing, and verification—must be measured in Live and assigned a separate product budget before planning. |

## Output-mode expectations

- **MIDI requested:** prioritize editability. Each requested role is a separate
  MIDI part, mapped to a compatible device and preserving useful velocity and
  timing detail.
- **Audio requested:** prioritize sound quality. Create an aligned audio clip
  on a new audio track and retain the generated file while the Live set may
  reference it.
- **No mode stated:** create MIDI and say so. If MIDI cannot represent the
  requested material adequately, explain the limitation and offer audio rather
  than silently changing output form.

## Boundaries

These stories cover short, section-scale material—roughly 1–16 bars—not full
song generation, autonomous arrangement, mixing, or mastering. They do not
require one backend for every material type or output mode. A combination of
generation, retrieval, conditioning, separation, and transcription is valid
if the final result passes the same user-facing criteria.

The first release need not support every story at once. Its claimed scope
must, however, be narrower than this document rather than quietly weakening
“related” to “same BPM and key.”

### First-release candidate slice

The decision experiment should try to earn stories 1–3 first: blank-project
beats, blank-project rhythm sections, and bass added against existing **MIDI**
context in Session View. MIDI is the default output, while explicit audio
output remains eligible once the audio-import path exists. Stories 4–8 remain
the product direction and cannot be claimed until their own context,
constraint, and iteration behavior is tested.

## Product questions still to decide

- Should a later release offer one Drum Rack clip as an alternative to the
  first release's separate-track default?
- Which subset of drum, bass, harmony, and melody stories earns the first
  release through the blinded listening experiment?
- What analysis would let a later release condition safely on existing audio
  clips, and how will it distinguish a solo source from a mixed recording?
