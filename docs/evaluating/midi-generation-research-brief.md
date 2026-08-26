# Research brief — MIDI generation that doesn't suck

Handoff document for the agent that will research this. Written 2026-08-25,
after the decision it rests on was made the same day. Deliverable: an
evidence doc in this folder in the style of
[audio-generation-options.md](audio-generation-options.md) — provider/model
comparison with sources, a recommended architecture, and the open questions
a `/plan` would need. Read this whole brief before searching; the
constraints section rules out entire categories in advance.

The product behavior this research must serve is defined separately in
[music-generation-user-stories.md](music-generation-user-stories.md).

## Goal

Seshat should expose a tool that generates *good* MIDI onto a track from a
natural-language description — "dark garage bassline, four bars, sparse" —
making Seshat responsible for note quality instead of the conversation
model. Claude composing notes directly through `write_midi_notes` was
tested on a simple task (a beat across 3 MIDI drum instruments) on
2026-08-25 and judged **too poor to be usable**, with no path to more
complex requests. That verdict is settled; do not relitigate it. The
failure was feel, not structure: uniform velocities, grid-locked timing,
pitch-guessing against instruments it cannot hear.

The new division of labor: Claude translates user intent into whatever
interface the generator exposes (translation is an LLM strength;
composition was the misassignment), the generator produces the notes, and
the existing `write_midi_notes` machinery lands them in a clip.

The core request may name **several interacting parts at once** — for example,
"a dusty lo-fi beat with a bassline." Evaluate both where each part comes
from and how the parts relate. Shared tempo and key are not evidence of
musical interaction; compare independent, conditioned, and jointly generated
material rather than assuming one wiring wins.

## Context you need

- Seshat is a local-first Elixir MCP server driving Ableton Live over OSC.
  Read [CLAUDE.md](../../CLAUDE.md) first. No database, no API keys
  anywhere today — the user's Claude subscription covers reasoning and
  everything else runs on this Apple Silicon Mac. Preserving the
  no-external-services posture is a strong preference, not an absolute.
- `write_midi_notes` (see `Seshat.Tools.Definitions` for the exact note
  schema — pitch/start/duration/velocity per note) is the mechanical
  writer any option feeds. `Seshat.Session.State` mirrors project tempo,
  time signature, and key/scale for prompt/parameter injection.
  `set_swing_amount` and `quantize_clip` exist downstream.
- The sibling audio evidence
  ([audio-generation-options.md](audio-generation-options.md)) records
  **Stable Audio 3 small/medium on this machine** — already
  installed at `~/.seshat/stable-audio-3` (MLX runtime), measured at
  1.0–1.1s per four-bar clip for `sm-music`, 2.6–3.8s for `medium`,
  bar-exact durations, excellent free-text conditioning, local
  `--negative-prompt` support. Option C below builds on it.
- Latency budget: a generation tool call should land in ~10 seconds.
- Target material, in priority order: drum patterns (multi-instrument),
  basslines, chord progressions/pads, melodies. Loops of 1–16 bars.
- Eventual distribution is a design constraint now. Check code, weights, and
  datasets separately; no licence, non-commercial terms, or research-only
  artifacts disqualify a dependency unless the design obtains suitable
  rights or excludes it from distribution. Attribution and revenue-limited
  licences require an explicit product story rather than a generic "clean"
  label.

## Evaluate all three routes — and propose a fourth

For each route: name concrete candidates, find *non-marketing* quality
evidence (papers with listening tests, producer/dev reports, demo audio),
pin down the conditioning interface precisely, measure the local story
(Apple Silicon, CPU/MPS, install weight, speed), license, and ecosystem
health (maintained? abandoned research code?). Flag everything
unverifiable. End with a recommendation only where the evidence supports
one; otherwise specify the smallest decision experiment that would settle it.

### Route A — specialized symbolic model, run locally

MIDI is token sequences, but current models range from small CPU-class
systems to billion-parameter language models. Treat Apple-local latency and
memory as candidate-specific questions alongside quality and interface:

1. What open text-conditioned MIDI models exist as of now (late 2026)?
   Known lineage to check and go beyond: text2midi / the MidiCaps-trained
   family, MusicLang, Stanford's Anticipatory Music Transformer,
   Microsoft Muzic (GETMusic etc.), SkyTNT's midi-model, NotaGen,
   Google Magenta's symbolic models. Anything newer?
2. **Conditioning interface is the crux.** Free text through a real text
   encoder, or a closed token vocabulary (genre/density/instrument
   knobs), or continuation-only? A knob model is not disqualified —
   Claude can translate intent to knobs — but the knobs bound the
   ceiling; say exactly what each candidate's interface can and cannot
   express.
3. Does it produce *feel* — velocity variation, micro-timing, ghost
   notes — or quantized uniform output (which would reproduce the exact
   failure this replaces)?
4. Multi-instrument drum patterns specifically: can it target a drum
   map / separate instruments, or single-stream melodic only?
5. Special case worth its own look: Magenta's GrooVAE lineage
   ("humanize"/"drumify" — adds feel to stiff patterns). Even if no
   generator wins, a local humanizer that post-processes rule-built or
   Claude-built patterns could combine with Route D.

### Route B — a service API

1. Who actually offers MIDI generation over an API in 2026? Check at
   least: AIVA (exports MIDI; verify whether it has a supported API),
   Lemonaide, Staccato,
   Hooktheory's data products, anything newer. Most "AI MIDI" products
   are GUI plugins (Captain, Orb, Scaler) — confirm whether any grew an
   API.
2. Per candidate: text conditioning or parameters? One-track parts or
   full arrangements only? Stems/per-instrument MIDI? Pricing, ToS,
   commercial rights.
3. Weigh honestly against the no-API-key posture: a service must beat
   the local routes on quality by a clear margin to justify being
   Seshat's first external dependency. Note the posture cost explicitly
   in the recommendation.

### Route C — generate audio locally, transcribe to MIDI

The route that inherits SA3's language interface and whatever musical
quality its audio contains, at the cost of separation/transcription loss.
Do not call that quality or groove preserved until the final rendered MIDI
has been heard:

1. Transcription models, per material: Spotify **Basic Pitch** (open
   source, tiny, polyphonic) for melodic/bass; for drums, find the
   current best automatic drum transcription — Magenta's e-gmd-era
   models, madmom, Omnizart, anything newer. All local-capable? Speed?
2. Where does transcription hold up and where does it fall apart:
   monophonic bass (probably strong), multi-instrument drum loops
   (map to which drum lanes?), chords/pads (polyphony accuracy),
   velocity/timing fidelity — does the extracted MIDI actually retain
   the groove that motivates this route?
3. End-to-end sketch: SA3 prompt idiom (already proven) → WAV →
   transcriber → note list → `write_midi_notes`. Total latency vs the
   10s budget. Where does the audio artifact go — keep both audio and
   MIDI, or discard the WAV?
4. Prompt implications: does material generated *for transcription*
   want different prompts (e.g. "solo bass, dry, no effects" to help
   the transcriber)?
5. For multi-part requests, compare isolated generation, generation of one
   part conditioned on another, and one joint render followed by source
   separation. Judge final MIDI through the same Ableton instruments; use
   source audio only to diagnose where quality was lost.

### Route D — your proposal

If you see a fourth shape, present it with the same rigor. Directions
deliberately not pre-chewed — algorithmic/rule-based engines driven by
Claude-chosen parameters, retrieval from licensed MIDI pattern libraries,
fine-tuning something small, hybrids of the above — but don't limit
yourself to these. A route earns inclusion by beating at least one of
A–C on some axis that matters here.

## Evaluation axes for the final ranking

Quality of the **final rendered MIDI** (including feel and multi-part
cohesion) >
expressiveness of the conditioning interface > local-first fit >
material coverage (drums/bass/chords/melody) > licence compatibility >
latency/cost >
ecosystem health. A route may win per-material — e.g. C for drums, A for
chords — a split recommendation is acceptable if the evidence points
there.

## Traps, recorded so you don't rediscover them

- Text↔MIDI paired training data is scarce (captioned-MIDI datasets only
  appeared ~2024); expect most symbolic models to be continuation- or
  token-conditioned, and expect "text-to-MIDI" marketing to overstate.
- Symbolic-model demos cherry-pick classical piano continuation; demand
  evidence on *rhythm-section* material.
- The MIDI pitch-mapping trap from the original failure: generated drum
  MIDI must land on the right pads (GM mapping vs arbitrary racks).
  Whatever route wins, the plan will need a story for knowing the target
  instrument's mapping — note per candidate whether output is
  GM-standard.
- Suno/Udio have no APIs (verified 2026-08-25;
  [audio-generation-options.md](audio-generation-options.md)) — don't
  re-research them; neither returns MIDI anyway.

## Memory anchors

Project memory `midi-composition-verdict` records the decision this brief
implements. The audio provider research and local spike measurements live in
[audio-generation-options.md](audio-generation-options.md); spike WAVs live
in `~/.seshat/audio-spike/`.
