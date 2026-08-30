# Vocal Performance → Expressive MIDI

An evolutionary architecture for Seshat using Ableton Live’s Convert Melody to MIDI as the MVP transcription layer

> **Core idea.**  Do not replace the MVP. Let Ableton determine the note skeleton, preserve the original vocal recording, then add an optional Seshat expression pass that interprets how the user performed those notes and writes richer MIDI/MPE and instrument-specific articulations.

**Status**

**Proposed architecture / implementation handoff**

**Scope**

Voice-to-MIDI creation, performance-expression enrichment, and instrument-aware rendering inside an Ableton Live workflow

# 1. Executive Summary

Seshat’s MVP can use Ableton Live’s **Convert Melody to New MIDI Track** command to turn a user’s sung monophonic idea into editable MIDI notes. That already satisfies the essential user story: “I will sing the bass part; make it MIDI.”

The limitation is not transcription; it is expression. A sung performance contains continuous pitch movement, attack strength, dynamics, vibrato, connected phrasing, and other gestures that ordinary note extraction largely collapses into discrete note events. The proposed architecture preserves Ableton’s generated MIDI as the note skeleton, then analyzes the original vocal audio and enriches the MIDI with performance information.

> **Design principle.**  Transcription answers “what notes?” Expression interpretation answers “how were those notes performed?” Instrument rendering answers “what does that performance mean on a bass, guitar, saxophone, synth, etc.?”

# 2. Product Goal

Keep the user interaction stable while allowing the musical result to become progressively more expressive over time.
```
User: “I’m going to sing the bass part.”

MVP result:          correct editable notes
Later result:        correct notes + dynamics
Later result:        correct notes + pitch phrasing
Later result:        correct notes + legato / slides / vibrato
Mature result:       a bass performance that resembles the phrasing the user imagined
```

The user should not need to invoke a separate “expression analysis” workflow. The same high-level Seshat action can become more sophisticated internally without changing the user story.

# 3. MVP Workflow

1. Seshat creates or selects an audio track and arms it for recording.
2. The user sings or hums a monophonic part while the project plays.
3. Seshat stops recording and retains a reference to the original vocal audio clip.
4. Through AX/UI automation, Seshat invokes Ableton Live’s Convert Melody to New MIDI Track command on the recorded clip.
5. Ableton creates a MIDI track containing the detected melody.
6. Seshat loads or assigns an appropriate target instrument (for example, electric bass).

Ableton explicitly supports using Convert Melody on recordings of singing, whistling, or solo instruments, and describes the command as identifying pitches in monophonic audio and placing them in a new MIDI clip. Ableton also notes that transient markers help determine divisions between notes in converted MIDI.

# 4. Evolutionary Architecture
```
ORIGINAL VOCAL AUDIO
                                  │
                ┌─────────────────┴─────────────────┐
                │                                   │
                ▼                                   ▼
      Ableton Convert Melody                Expression Analyzer
            to MIDI                         pitch / dynamics /
                │                           attacks / transitions
                ▼                                   │
         MIDI NOTE SKELETON                         │
                └─────────────────┬─────────────────┘
                                  ▼
                     PERFORMANCE REPRESENTATION
                                  │
                                  ▼
                       INSTRUMENT INTERPRETER
                         (“electric bass”)
                                  │
                 ┌────────────────┴───────────────┐
                 ▼                                ▼
          note/velocity edits              MPE / articulations
                 └────────────────┬───────────────┘
                                  ▼
                            ABLETON MIDI CLIP
                                  │
                                  ▼
                           TARGET INSTRUMENT
```

## 4.1 Transcription Layer

Responsibility: determine the discrete musical note skeleton: pitch, onset, duration, and whatever velocity information is available. In the MVP, Ableton Live is the transcription engine.

- Treat the transcription backend as replaceable. A future implementation could use another transcription model without changing the expression or instrument layers.
- Do not ask the expression analyzer to redetect the melody unless needed for local alignment. Ableton’s generated notes are the authoritative skeleton for this workflow.
- Preserve the original audio clip and the mapping between its timeline and the generated MIDI clip.

## 4.2 Expression Analysis Layer

Responsibility: inspect the original performance at higher temporal resolution and describe what happened inside and between the discrete notes.

| **Feature** | **Observed in vocal audio** | **Potential downstream use** |
|---|---|---|
| Dynamics | Amplitude / loudness envelope | Velocity, pressure, filter or timbral intensity |
| Pitch contour | Continuous F0 movement around a note | Bends, scoops, falls, intonation, MPE pitch |
| Vibrato | Periodic pitch modulation | Per-note pitch modulation with measured rate/depth |
| Attack | Onset strength and envelope shape | Picked/plucked vs soft/legato articulation |
| Transition | Re-attack vs continuous movement between notes | Slide, bend, hammer-on/pull-off, portamento |
| Release | Abrupt cutoff vs decaying exit | Mute, sustain, release behavior |

## 4.3 Performance Representation

The analyzer should not output instrument-specific commands such as “guitar bend.” It should output a neutral description of the human performance. This keeps analysis reusable across instruments.
```
{
  "note": 48,
  "start_beats": 2.50,
  "duration_beats": 1.00,
  "attack_strength": 0.82,
  "pitch_contour_cents": [...],
  "dynamic_curve": [...],
  "transition_in": {
    "type": "continuous_rise",
    "interval_cents": 195,
    "duration_ms": 170,
    "reattack_probability": 0.08
  },
  "vibrato": {
    "rate_hz": 5.2,
    "depth_cents": 18
  }
}
```

## 4.4 Instrument Interpretation Layer

Responsibility: convert neutral performance gestures into physically and stylistically plausible actions for the target instrument. The same vocal gesture may map differently depending on the requested instrument.

| **Vocal / abstract gesture** | **Electric bass** | **Electric guitar** | **Synth lead** |
|---|---|---|---|
| Continuous A→C rise | Fret slide or legato shift | Whole-step bend or slide | Portamento |
| No re-attack across notes | Hammer-on / pull-off / slide | Hammer-on / pull-off | Legato envelope |
| Strong attack | Hard pluck / pick | Hard pick | Higher velocity / brighter envelope |
| Measured vibrato | Fret-hand vibrato | String vibrato | Pitch modulation |
| Dynamic swell | Pressure/timbre/sustain mapping | Sustain / gain / pressure | Pressure / filter / amplitude |

# 5. Incremental Delivery Path

The architecture is deliberately incremental. Each phase produces user-visible value and preserves the same workflow.

| **Phase** | **Capability** | **What changes** |
|---|---|---|
| v0 — MVP | Sing → Convert Melody → instrument | Ableton supplies the editable MIDI note skeleton. |
| v0.5 — Dynamics | Transfer performance intensity | Analyze loudness/attack and adjust MIDI velocity or mapped expression. |
| v0.6 — Pitch contour | Preserve bends and scoops | Analyze continuous pitch around each Ableton note and emit pitch expression. |
| v0.7 — Phrasing | Legato vs re-articulation | Use onset/transition evidence to classify connected notes and adjust articulation. |
| v0.8 — Vibrato | Preserve performer vibrato | Estimate vibrato rate/depth and write controlled per-note pitch modulation. |
| v1 — Instrument-aware performance | Slides, bends, legato, target articulations | Render neutral gestures through bass/guitar/etc. interpretation profiles. |

> **Why this matters.**  The MVP is not throwaway work. It establishes the recording, conversion, clip-tracking, instrument-assignment, and note-editing workflow that the expression system later enriches.

# 6. Seshat Implementation Responsibilities

## 6.1 Planner / Coordinator

- Recognize intent such as “I’m going to sing the bass part.”
- Coordinate recording, conversion, analysis, rendering, and instrument assignment as one user-facing action.
- Select an instrument interpretation profile based on the requested target sound.

## 6.2 AX / Ableton Automation

- Create/arm/select the recording track and control the record/stop workflow.
- Select the resulting audio clip and invoke Convert Melody to New MIDI Track.
- Locate/select the generated MIDI clip and target track for subsequent Seshat processing.
- The exact robustness of identifying the newly created MIDI clip should be validated in an implementation spike; avoid coupling the architecture to fragile screen coordinates where semantic UI targeting is available.

## 6.3 Expression Analysis Service

Recommended home: the existing Python/audio-analysis side of Seshat. The initial version does not require a large generative model. Classical DSP and specialized pitch/onset models are suitable for the low-level measurements.

- Inputs: original vocal audio, tempo/timeline metadata, generated Ableton MIDI notes.
- Outputs: neutral per-note and inter-note performance descriptors.
- Use Ableton notes as anchors: analyze pitch/dynamics in windows tied to the generated note boundaries instead of solving unconstrained transcription again.

## 6.4 MIDI / MPE Rendering Adapter

The renderer converts the interpreted performance into data that Live and the selected instrument can use: note velocity/duration edits, pitch-bend expression, pressure/slide where useful, and instrument-specific articulation messages or keyswitches.

Live 12’s MIDI Tools architecture is relevant here: Ableton documents Transformations that modify existing note properties including MPE data, and supports custom Max for Live MIDI Tools. This makes a small Seshat Max for Live transformation/bridge a plausible path if the normal automation/API layer cannot write the required per-note expression directly.
```
Seshat Python / coordinator
        │
        ├── ordinary note edits ─────→ existing Ableton control path
        │
        └── expression payload ──────→ optional Seshat M4L MIDI Tool
                                          │
                                          └── writes MPE / expression into clip
```

# 7. Suggested Internal Data Contract

Keep three representations distinct. This reduces coupling and makes every stage independently testable.

| **Object** | **Purpose** | **Example fields** |
|---|---|---|
| Transcription | Discrete musical skeleton from Ableton | pitch, start, duration, velocity, clip/note identity |
| PerformanceAnalysis | Instrument-neutral observation of the vocal | pitch curve, loudness curve, onset strength, reattack probability, vibrato |
| RenderedPerformance | Target-instrument instructions | velocity, note-length edits, pitch expression, slide/pressure, articulation/keyswitch |

# 8. Recommended First Experiment

Build the smallest experiment that can prove whether expression enrichment materially improves the musical result over raw Convert Melody output.

1. Record 10–20 seconds of a sung bass or lead line containing clear attacks, a connected interval, a scoop/bend, and a held vibrato note.
2. Use the existing AX workflow to run Convert Melody to MIDI and save that clip as the baseline.
3. Analyze the original audio only for three features: loudness/attack, continuous pitch contour, and legato/re-attack evidence.
4. Apply only three enrichments: velocity, pitch-bend contour, and legato note-length/transition behavior.
5. Render through one known instrument and A/B against the unmodified Ableton conversion.

> **Success criterion.**  A listener should hear the enriched version as preserving recognizable phrasing from the sung performance—not merely the same melody with a different sound.

# 9. Risks and Open Questions

- Alignment: verify that the audio clip and generated MIDI clip maintain a reliable timeline relationship after conversion, warping, or clip movement.
- MPE write path: determine the cleanest supported route for programmatically writing per-note pitch/pressure/slide data into Live clips.
- Instrument contracts: sampled guitar/bass libraries vary widely in keyswitches, articulation conventions, MPE support, and physical modeling.
- Over-interpretation: the system should preserve intentional vocal gestures without converting every pitch imperfection into an instrumental flourish.
- Latency: the initial workflow can be post-recording. Real-time interpretation should be treated as a separate later requirement.
- User control: eventually expose simple interpretation strength/style controls, but do not burden the MVP with them.

# 10. Architectural Decision

> **Recommendation.**  Adopt Ableton Convert Melody to MIDI as the MVP transcription backend, but design the workflow now to preserve the source audio and attach a stable reference to the generated MIDI clip. Define an optional PerformanceInterpretation stage in the pipeline even if its initial implementation is a no-op. This creates the seam needed to add expression without replacing the MVP.

In other words:
```
MVP:       Voice → Ableton transcription → MIDI → instrument

Evolution: Voice → Ableton transcription ─┐
           Voice → expression analysis ───┴→ performance interpretation → expressive MIDI/MPE → instrument
```

This preserves the simplest possible first implementation while creating a credible path from “sing notes into Seshat” to “perform an instrument through your voice.”

# References

- Ableton Live 12 Manual — Converting Audio to MIDI. [ableton.com/en/live-manual/12/converting-audio-to-midi/](https://www.ableton.com/en/live-manual/12/converting-audio-to-midi/)
- Ableton Live 12 Manual — MIDI Tools. [ableton.com/en/live-manual/12/midi-tools/](https://www.ableton.com/en/live-manual/12/midi-tools/)
- Ableton Live 12 Manual — Max for Live Devices / MPE Control. [ableton.com/en/live-manual/12/max-for-live-devices/](https://www.ableton.com/en/live-manual/12/max-for-live-devices/)
