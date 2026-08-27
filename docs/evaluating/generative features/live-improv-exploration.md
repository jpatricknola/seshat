# Live improvisation — an AI collaborator that plays along in Ableton

_Exploration doc · 27 Aug 2026 · product + engineering handoff for a
realtime collaboration mode · technical-spike candidate; decides nothing by
itself and is not on [ROADMAP.md](../../ROADMAP.md)._

**Pre-spike.** Nothing in this document is measured; every model figure is
"reported" from docs, model cards and papers (verified 2026-08-27) and every
Ableton figure is read out of Seshat's own code and
[abletonosc-api-docs.md](../../abletonosc-api-docs.md). Sibling docs in this
folder separate "measured" from "reported" — this one has no "measured"
column yet, and §12's Spike A1 is what starts filling it. It must not reach
the roadmap before that spike has run.

**Recommended generator:** Magenta RealTime 2 — open weights, runs locally on
Apple Silicon, ~200 ms control latency, MIDI-conditioned (§4). Google's
Lyria RealTime was the starting assumption and is kept in §5.1 with the
reasons it was set aside. The architecture stays provider-agnostic
regardless (§6).

> **One-sentence concept.** A musician plays or produces normally in Ableton
> while Seshat continuously understands project state, constrains a realtime
> generative music model running on the same machine, and turns its output
> into a beat-aligned, musically responsive improvising collaborator.

---

## 1. Executive summary

**The opportunity:** add a mode in which Seshat behaves less like a command
assistant and more like a bandmate. The user should be able to ask for an
improvised part or backing texture, keep playing in Ableton, steer the
collaborator conversationally, and capture useful moments into the project
without leaving the creative flow.

**The architectural principle:** the generative model should not be
responsible for understanding the DAW. Seshat owns project state, transport,
musical analysis, quantization, buffering, interaction history, and
recording. The generator owns only realtime musical synthesis under
constraints.

**Why now:** until June 2026 the only continuous, steerable music model was a
cloud service (Lyria RealTime) with a two-second control latency, a
mandatory watermark, an API key and no way to hear the user. Magenta
RealTime 2 (released 2026-06-04) is the same lineage as open weights,
running natively on Apple Silicon at ~200 ms control latency, accepting
per-frame MIDI pitch conditioning, and shipping as an AUv3 instrument and a
Max external. That changes the feature from "a steerable backing track that
happens to play in Live" to something that can react to what the user plays
within a beat, with nothing leaving the machine. Seshat's differentiator is
the layer around it: knowing the session, keeping the stream on the grid,
scheduling intent at musical boundaries, and capturing takes. [7]

> **Product thesis.** Do not build "AI generates music in Ableton." Build
> "Seshat lets an AI musician understand enough of the session to improvise
> with you, stay out of the way, and hand you editable/capturable material at
> musically meaningful boundaries."

---

## 2. Core user story

> **Primary user story.** As a musician working in an Ableton Live project, I
> want to ask Seshat to improvise with me inside the project's musical
> constraints, so that I can discover parts, textures, counter-lines, grooves,
> and transitions through realtime collaboration instead of prompting for
> finished songs.

The desired experience is conversational but musically quantized. A
representative session:

1. The user is playing a project at 92 BPM in D minor. Seshat knows the
   tempo, the key box, and the transport, and has enough harmonic context to
   understand the section.
2. The user says: "Give me something sparse underneath this — no drums,
   mostly Rhodes and strange analog texture."
3. The collaborator begins at the next bar boundary rather than immediately
   in the middle of beat three.
4. The user plays a chord change on the keys. The collaborator follows it
   within the beat — it is being fed the notes.
5. While playing, the user says: "More tension over the next four bars,"
   then, "Back off when the chorus hits." Seshat schedules those changes at
   bar boundaries and ramps generator parameters rather than replacing the
   stream.
6. The user says: "That. Keep the next eight bars." Seshat captures the output
   into Ableton as a clip aligned to the project grid.
7. The user keeps the audio, chops it, warps it, resamples it, or asks for
   another take.

---

## 3. What "improvise with me" must mean

This feature should not claim collaboration merely because generated audio
is playing next to the user. The minimum credible definition has four
layers:

| Layer | Responsibility | MVP expectation |
|---|---|---|
| **Temporal** | Stay aligned enough to Ableton's tempo, bars, beats, and section boundaries to feel intentional | Required |
| **Harmonic** | Respect the project key/scale; follow the notes the user plays; eventually track chord regions in existing clips | Key and live-MIDI following required; clip analysis stretch goal |
| **Textural** | Respond to desired instrumentation, density, brightness, register, rhythmic role, and absence constraints | Required |
| **Interactive** | Accept steering during playback and schedule those changes musically | Required |

### 3.1 Two loops, two latencies

"Improvise with me" is two control loops, and they run at speeds three
orders of magnitude apart. Conflating them is how a backing-track service
gets mistaken for a bandmate.

| Loop | Signal | Path | Latency that counts | Who has it |
|---|---|---|---|---|
| **Fast** — *react to what I play* | The user's MIDI (or audio) as it happens | Live MIDI track → generator, **no LLM in the path**; Seshat only wires it | Must be under a beat: ~200 ms feels like a partner, 2 s feels like a delay pedal | MRT2 (MIDI conditioning, ~200 ms), Notochord (<10 ms). Lyria and Stable Audio 3 have no fast loop at all |
| **Slow** — *do what I ask* | Spoken or typed direction | Utterance → Claude → MCP tool → provider params | Seconds, bar-quantized by design; §7.4 | Every candidate |

The fast loop is what makes it improvisation. It bypasses Seshat's reasoning
entirely: the generator listens to the track, and Seshat's job is to set
that route up, set the constraints, and hold the slow loop. A generator
without a fast loop can still be a steerable texture player — a real
feature — but this document does not call it a collaborator.

**Not required for the first version:** the generator hearing the master bus
and understanding everything the user plays as *audio*. MIDI is the fast
loop's signal for now; audio-in accompaniment models exist in the literature
but none has shipped weights (§5.4).

---

## 4. Recommended generator: Magenta RealTime 2

Magenta RealTime 2 (MRT2) is Google's open-weights live music model,
released 2026-06-04, version 2.0.3 on 2026-07-30, last pushed 2026-08-24
(1.7k stars, 33 open issues). It is the open sibling of Lyria RealTime —
same research group, same "live music model" design — with the controls and
constraints below. [7]

### 4.1 What it is

| Property | Reported |
|---|---|
| Output | 48 kHz stereo, generated one 40 ms frame at a time (25 Hz) |
| Context | Windowed attention over its own recent output; ~20 s effective receptive field |
| Sizes | `mrt2_small` 230M params; `mrt2_base` 2.4B params |
| Realtime hardware | Apple Silicon only. `small` on any M-series (Air included); `base` needs M3 Pro / M2 Max or better. Offline inference also on NVIDIA via JAX |
| Control latency | ~200 ms end-to-end (announcement); the Max external defaults to an 8192-sample buffer, ≈170 ms at 48 kHz |
| Memory | ~1 GB per instance (Max external) |
| Training data | ~71k hours of stock music, mostly instrumental |
| Known limits | Genre coverage; occasional non-lexical vocalisation; evaluation numbers deferred to a forthcoming technical report |

### 4.2 Controls — what ramps, what steps, what is missing

| Control | Applies | Musical consequence |
|---|---|---|
| Up to 6 weighted text prompts | In place, ~200 ms | Ramps. "Build over four bars" is a weight ramp between prompt slots |
| Audio style reference (16 kHz mono, embedded once) | Set at start | A timbre/style anchor, not live input |
| **MIDI pitch state per frame** — 128-way vector, each pitch *off / sustain / onset / model-decides* | Every frame | **The fast loop.** The user's notes are handed to the generator; it plays around them. Also carries a drums on/off gate in the Jam app |
| CFG scale, temperature, top-k | In place | Character and risk; schedule at bars, not continuously |
| **Tempo** | **Prompt text only** ("92 BPM") | No `bpm` field, no clock in. Adherence unmeasured — Spike A1's first question |
| **Key / scale** | **Prompt text, plus whatever the MIDI conditioning implies** | No typed scale. The MIDI channel is the stronger lever: feed the chord bed and the key follows |

Whether a prompt change needs a context reset (as Lyria's tempo/key changes
do) is not documented on the pages read; it has to be learned from the code
and measured.

### 4.3 Licence and terms — checked at selection

[CLAUDE.md](../../CLAUDE.md) requires a dependency's rights to be checked
when it is chosen. MRT2 is the cleanest of the three generators surveyed:

- **Code:** Apache-2.0. Ship it; keep the notice.
- **Weights:** Creative Commons Attribution 4.0. Commercial use permitted;
  the one obligation is attribution — credit Google / Magenta RealTime 2
  and link the licence in the product. Verify on first download whether
  the Hugging Face repo is gated behind a click-through; that would be a
  one-time step, not a licence change.
- **Output:** the model card says Google retains no rights to generated
  audio. No watermark is mentioned. What the user captures is theirs.
- **No key, no vendor, no bill.** Nothing about the user's session leaves
  the machine. Seshat's "MCP needs no API key" posture is untouched.
- **Provenance of training data** ("stock music from multiple sources") is
  Google's exposure, not Seshat's, and is the same question any generative
  model carries.

### 4.4 Integration surface — it already lives in a DAW

The repository ships, besides the Python library (JAX / MLX backends) and a
C++ core (`magentart::core`):

- an **AUv3 instrument** with Ableton Live setup steps in its docs;
- a **`mrt2~` Max external** — stereo out, six text-prompt slots, MIDI in,
  temperature / top-k / CFG / mute as Max messages; macOS only, 48 kHz
  hardcoded. Audio prompts and the prefill API are not yet exposed there;
- Pure Data and SuperCollider externals; a standalone app; "Jam" (note
  control) and "Collider" (prompt space) example apps.

The Max external is a Max for Live device away from running on a Live track
with the user's MIDI feeding it directly — the fast loop with nothing
between the keys and the model but Live's own routing. §9 lays out the two
topologies this opens.

### 4.5 What it costs against the alternatives

- **No typed tempo or clock.** Tempo is prompt text. Lyria's typed `bpm` is
  also only guidance (§5.1), so the gap may be small, but §7's whole sync
  strategy rests on how well MRT2 holds a stated tempo and that is
  unmeasured.
- **Quality unpublished.** The v1 paper's claim was "outperforms other
  open-weights music generation models with fewer parameters" — a
  comparison against open models, not against Lyria. Ears decide.
- **Young.** Two months old; the streaming API's shape (state between
  calls, reset semantics) is undocumented on the pages read.
- **Apple Silicon only for realtime.** Matches where Live-plus-Seshat lives
  today; it is a hard boundary for any future Windows story.

---

## 5. Alternatives surveyed — 2026-08-27

The survey asked one question of every candidate: can it be the
**performer** behind §6's provider seam — a continuous, steerable stream
that Seshat can keep on the grid, ideally with a fast loop — and can Seshat
ship it? Licence was checked at selection, and two candidates fell on it.

| Candidate | Shape | Runs | Fast loop | Steering | Reported latency | Licence | Verdict |
|---|---|---|---|---|---|---|---|
| **Magenta RealTime 2** | Continuous 48 kHz stereo | **Local, Apple Silicon** | **Yes** — MIDI conditioning | Weighted prompts, audio ref, CFG, temperature, top-k. No BPM/scale/clock | ~200 ms | Apache-2.0 / **CC-BY-4.0** | **Recommended** (§4) |
| **Lyria RealTime** | Continuous 48 kHz stereo | Cloud, Gemini API key | **No** | Weighted prompts, **typed `bpm` and `scale`** (reset on change), density, brightness, mutes | ≤2 s | API terms; SynthID watermark; unpublished price | **Rejected as collaborator** (§5.1); comparison arm for quality only |
| **Notochord** | **Symbolic**: MIDI in → MIDI out | Local, CPU | **Yes** — harmonises live MIDI | Sub-event interventions; OSC server; no text | <10 ms | **MIT** | **Second spike, different product** (§5.2) |
| **Stable Audio 3 small** (installed) | Bar-ahead chunks via continuation | Local, measured 1.0–1.1 s per four bars | No | Free text per chunk | One bar, by construction | Stability Community License | Zero-install spike; texture player at best (§5.3) |
| **ReaLchords / ReaLJam / GAPT** | Symbolic: melody → chords, online | Local; MLX backend listed | Yes, chords only | RL-tuned for coherence | Not stated | **MIT**; training-data terms unchecked | Harmonic-layer component. Watch |
| **LiveBand** (Sony CSL / QMUL, 2026-06) | Audio in → accompaniment audio, causal | RTX 3090, 2.1× realtime | Yes, audio | Follows the live mix | 43.6 ms per 93 ms frame | **No code or weights released** | Watch. The most interesting shape, unobtainable |
| **StreamMUSE** (RTAS 2026) | Symbolic: melody → piano | CUDA, 16 GB | Yes | Frame-synchronous LM against an external clock | Not stated | Not stated | Not on Apple Silicon. Watch the clock-sync design |
| Latent-diffusion co-performance + Max/MSP (2026-04) | Audio in → accompaniment audio | Python server + Max over OSC | Yes | Consistency-distilled diffusion | "Real-time" | Code not located | Watch; same Max + OSC topology as §9 |
| **RAVE / nn~** (IRCAM) | Timbre transfer | Local, Max/PD/VST | — | Latent, not text | Realtime | **CC-BY-NC-4.0** | **Disqualified** — non-commercial; a synthesiser, not a composer |
| **VampNet** (Descript) | Masked token generation over loops | GPU + Max "unloop" | No | Mask variation | Not realtime | Code MIT, **weights CC-BY-NC-SA-4.0** | **Disqualified** on weights |
| **Mubert API** | Streamed generative music | Cloud, $49–$499/month | No | Genre/mood taxonomy, intensity, BPM field | "Sub-second" | Royalty-free output | Wrong shape — a soundtrack service. Not pursued |
| Magenta Studio (M4L) | Offline MIDI Continue / Generate | Inside Live | No | Clip in, clip out | Not realtime | Apache-2.0 | Not a collaborator; the only Google MIDI tool already in Live |

### 5.1 Lyria RealTime — how it would have been used, and why it was set aside

Lyria RealTime (`models/lyria-realtime-exp`) was this document's original
assumption. It is an experimental Gemini API model for continuously steered
instrumental music: a persistent bidirectional WebSocket, raw 16-bit 48 kHz
stereo PCM out, and in-flight updates to weighted text prompts, BPM
(60–200), scale, density, brightness, bass/drum mutes, guidance,
temperature, top-k and generation mode. BPM or scale changes require a
context reset — a hard cut; everything else updates in place with a stated
control latency of up to 2 s. Google recommends robust client-side
buffering. Its Infinite Crate VST (Apache-2.0) feeds it into a DAW as a
practice partner and sampling source, describes BPM as "imprecise" even
when read from the DAW, and ships a DAW-transport class that is currently
unused. [1][2][3][4][5]

**How it would have been used.** Exactly as §6 describes for any provider:
Seshat holds the WebSocket, sets `bpm` and `scale` once at start from the
mirror, translates intents into prompt-weight ramps and density/brightness
steps scheduled at bars, streams the PCM into Live through a virtual audio
device, and warps captured takes to the grid. The typed `bpm` and `scale`
fields would have been the one advantage over MRT2, and the reset-on-change
rule would have made tempo and key session constants.

**Why it was set aside**, in order of weight:

1. **No fast loop.** Lyria has no input for what the user is playing — no
   MIDI, no audio conditioning. It can be told about the session; it cannot
   hear it. Under §3.1 that makes it a steerable texture player, not a
   collaborator, whatever the plugin's "practice partner" framing says.
2. **Two-second control latency.** At 92 BPM a bar is 2.6 s; a "next bar"
   steer has almost no slack, and nothing mid-bar is possible. MRT2's
   ~200 ms is an order of magnitude better on the same axis.
3. **Terms.** A Gemini API key — the first credential Seshat would ever
   require — and a second vendor receiving prompts that describe the user's
   unreleased music. The API terms restrict use to "professional or
   business purposes," and on the unpaid tier Google uses prompts and
   responses to improve its products (the paid tier does not). Google's
   pricing page lists no line for `lyria-realtime-exp`; Infinite Crate says
   usage is currently free; the model is labelled experimental with no
   deprecation policy. [5][6]
4. **Watermark.** Every frame carries a SynthID audio watermark that cannot
   be disabled; anything captured into the set is watermarked material.
5. **Network dependence.** A dropped connection is a dead collaborator
   mid-take.

The user accepted the API-key requirement on 2026-08-27 before the survey
found MRT2; that decision stands as the fallback if MRT2 fails its spike,
in which case: paid tier only, key in `~/.seshat/`, feature absent when the
key is absent. **The earlier rejection in
[audio-generation-options.md](audio-generation-options.md)** (Lyria is the
wrong shape for one-shot clips) is a different verdict for a different job
and is unaffected either way.

Lyria remains the **comparison arm** (Spike A2): if MRT2's quality or tempo
hold falls short, Lyria is the only other continuous model available, and
knowing how far short is worth an afternoon and a key.

### 5.2 Notochord — a different product, worth its own cheap spike

Notochord (Intelligent Instruments Lab, MIT, 2022–, last push 2026-02-26)
is not an MRT2 substitute; it is a second answer to "improvise with me".
Its output is MIDI, played through whatever instrument the user has on the
track, so the take is editable notes rather than a stereo mix — the exact
property [midi-generation-options.md](midi-generation-options.md) wants from
a generator and the reason that document's verdict was "a dedicated model,
not Claude composing". It harmonises a live MIDI input with sub-10 ms
latency on a CPU and exposes an OSC server, which is Seshat's native tongue.
Against it: Lakh MIDI training (General MIDI, uneven quality), no text
steering at all — style comes from what you feed it and from sub-event
interventions — and a small lab project (34 stars). Routing in Live is a
virtual MIDI bus (IAC) into a MIDI track, the only manual step. [8]

The two spikes are complementary: MRT2 is the audio texture player of §17's
demo; Notochord is a counter-line or comping partner on the user's own
sounds. If both feel alive, the product has two roles; if only one does,
that decides which shape to build first.

### 5.3 Stable Audio 3 — the zero-install spike

SA3 small is already installed and measured at 1.0–1.1 s per four-bar clip
([audio-generation-options.md](audio-generation-options.md)); the repo
reports 0.23 s per 5 s with CoreML. It supports continuation and
inpainting, so a bar-ahead loop — generate bar N+1 conditioned on bar N's
tail, steered by the prompt in force — is buildable with nothing new on
disk. It has no fast loop and steers only at bar boundaries, so it can only
ever be the slow-loop texture player. An earlier draft had it running
*first* because it costs nothing, on the theory that a coherent 16-bar
continuation would spare installing a second model for the texture-player
half. That theory does not survive the fast loop: MRT2 is installed for the
collaborator regardless, and a slow-loop-only SA3 texture player is strictly
worse than MRT2's in-place steering. Spike A0 is therefore run only if A1
is blocked ([one-model-or-two.md](one-model-or-two.md) §5–6). [10]

### 5.4 The rest

The audio-in accompaniment models — LiveBand (Sony CSL Paris / QMUL, June
2026: causal transformer in a latent space, 2.1× realtime on an RTX 3090,
follows the live mix), the latent-diffusion Max/MSP co-performance system
(April 2026), and the streaming-accompaniment work behind them — are the
shape §3 called out of reach: a generator that hears the master bus. None
has released code or weights; all are CUDA. They are the ones to re-check
in six months. StreamMUSE and ReaLchords are symbolic and narrow (piano
accompaniment to a melody; chords to a melody) and belong, if anywhere, as
components of the harmonic layer rather than as the collaborator. RAVE and
VampNet fall on non-commercial licences. Mubert is a soundtrack service with
a taxonomy. [9][11][12]

---

## 6. Proposed system boundary

```
User voice / text                       User's MIDI track (Live)
        │                                        │  fast loop, no LLM
        ▼                                        │
  Seshat Planner                                 │
        │                                        │
        ▼                                        ▼
  Collaboration Session  ◀────── Ableton project state
        │  │                       tempo / transport / key
        │  │                       clips / MIDI
        │  │                       scene names
        │  │
        │  └──▶ Musical constraint model
        │
        ├──▶ GenerativeMusic provider ────▶ Magenta RT 2 (local; Lyria as fallback)
        │          ▲                              │
        │          └────── 48 kHz stereo PCM ◀────┘
        ▼
  Sync + capture
        │
        ├──▶ monitored collaborator track
        ├──▶ quantized capture / clip creation
        └──▶ history / "go back to that" state
```

The collaboration session exposes Seshat-level intentions rather than
provider-specific fields:

```
collaborator.start(role: "texture", at: NEXT_BAR)
collaborator.set_harmony(key: D_MINOR)
collaborator.follow(track: 2)              # fast loop: feed this track's MIDI
collaborator.set_density(0.25, ramp_bars: 2)
collaborator.add_influence("degraded tape", weight: 0.6)
collaborator.exclude("drums")
collaborator.build_tension(over_bars: 4)
collaborator.capture(bars: 8, destination: "new_audio_track")
collaborator.stop(at: NEXT_SECTION)
```

A provider adapter translates these into MRT2 prompt slots, weights and
MIDI gates today and into a different backend later. Lyria's adapter would
map `set_harmony` to the typed `scale` field and `follow` to nothing — which
is the difference §3.1 is about.

---

## 7. Synchronization strategy

**Goal:** make the collaborator feel grid-aware even though the generator is
not clocked to Ableton — MRT2 has no tempo input beyond prompt text.

### 7.1 Separate tempo from phase

A generator can approximately produce 92 BPM without knowing where Ableton's
beat 1 is. Seshat must solve both problems independently:

- **Tempo:** state the project BPM in the prompt and continuously estimate
  the actual pulse of returned audio.
- **Phase:** align detected generator downbeats to Ableton's transport so
  bar boundaries coincide — or, under Design 1 below, only at capture.

### 7.2 A lookahead buffer, if needed

Let the generator run ahead while Ableton monitors a delayed, corrected
version. A configurable one-bar lookahead is the prototype target if Design
2 is ever built:

```
Generator:     [ bar N+1 ][ bar N+2 ][ bar N+3 ]
                    │ analysis / correction
                    ▼
Ableton hears: [ bar N   ][ bar N+1 ][ bar N+2 ]
```

At 120 BPM in 4/4 one bar is 2.0 s; at 100 BPM, 2.4 s. That latency is
unacceptable on the fast loop — it would put the user's chord change a bar
late — and is the reason Design 1 is preferred: with MRT2's ~200 ms, the
monitor path should carry no added buffer at all.

### 7.3 Drift correction — two designs, the cheaper one first

Because the model's tempo is not exact, long-running audio drifts against
the Ableton grid. There are two places to correct that.

**Design 1 — correct at capture, let the monitor free-run.** Do not
time-stretch the live stream. The monitored collaborator plays as generated,
at the generator's native latency; when the user keeps a take, the captured
clip is warped to the grid inside Live: `set_clip_properties` sets `warping`
and `warp_mode`, and Live's own warp engine (Complex Pro for polyphonic
material) is better than anything a bridge would run in realtime. The drift
heard during a take is whatever tempo error accumulates over one phrase —
Spike A1 measures how much. This costs no realtime DSP, keeps the fast loop
fast, and makes "capture N bars" the only place sync has to be exact.

**Design 2 — correct in the monitor path.** Estimate beat timing and apply
small time-scale corrections before playback (phase vocoder, Rubber Band,
bar-boundary crossfades) behind §7.2's buffer. Right only if Spike A1 shows
drift audible within a phrase, and it costs the fast loop a bar of latency.

Start with Design 1. Build Design 2 only if the free-running monitor fails
the ear test in Spike D.

Success is perceptual **and** numerical. Target under Design 1: the
*captured* clip's first downbeat lands on the grid after warping, and the
free-running monitor's drift over 32 bars stays below a stated tolerance.

### 7.4 Quantized intent scheduling — the slow loop

| Command | Timing semantics |
|---|---|
| "Bring in percussion" | Default to `NEXT_BAR` unless the user says "now" |
| "Build for four bars" | Ramp prompt weights / temperature over an exact four-bar window |
| "Drop out for the chorus" | Schedule on a scene boundary when one is known |
| "Keep the next eight bars" | `record_clip` with `bars: 8`; Live starts on the launch-quantization boundary |
| "Go back to what you were doing" | Restore a saved collaboration-state snapshot, not replay audio |

The fast loop never goes through this table.

---

## 8. Musical constraint model

The generator receives a compact, continuously updated collaboration
context, distinguishing hard constraints, soft guidance, and inferred state.

| Constraint | Examples | Strength | Source |
|---|---|---|---|
| Transport | 92 BPM; 4/4; bar 37 beat 1 | Hard for scheduling; prompt text for the generator | Ableton (mirrored) |
| Harmony | D minor; the chord being played right now | Key: prompt text. Chord: **MIDI conditioning, hard** | Ableton key box (mirrored); live MIDI; `get_clip_notes` |
| Role | "underneath," "counterline," "texture," "backing groove" | Soft but high priority | User / Planner |
| Instrumentation | Rhodes, analog texture; no drums | Prompt slots + drum gate | User |
| Activity | Sparse; build over 4 bars | Continuous: prompt weights, temperature | User / section model |
| Register | Stay above bass; avoid lead register | Soft | Arrangement analysis |
| Section | Verse / chorus / transition | Scheduling + style context | Scene names / inference |

Two rows are inferred today with no new work: `Seshat.Session.State`
mirrors tempo, time signature, `is_playing`, and the key box (`root_note`,
`scale_name`). The MVP reads them and lets the user override by voice. The
harmony row is where MRT2 changes the picture: the chord is not inferred,
it is *fed* — from the track the user is playing, or from a chord bed read
with `get_clip_notes`.

---

## 9. Ableton integration responsibilities

Much of what the Ableton side needs exists; the table says which.

| Need | Status today |
|---|---|
| BPM, time signature, transport state | **Mirrored** in `Seshat.Session.State`, pushed by listeners |
| Key/scale | **Mirrored** (`root_note`, `scale_name`) |
| Song position / next bar boundary | **Not mirrored.** `/live/song/get/current_song_time` is a query (≈100 ms AbletonOSC tick); `/live/song/start_listen/beat` pushes a beat number every beat — the right primitive, unused so far |
| Create an audio track | `create_track` (`type: "audio"`) |
| Arm / record into a slot | `set_track_arm`, `record_clip`, `stop_recording` — Live starts and stops a Session take on the global launch-quantization boundary (1 bar by default), so "capture the next eight bars" is `record_clip` with `bars: 8` |
| Route generated audio into that track | **Nothing.** Seshat can neither set nor read a track's input routing (`record_clip`'s description already says so) |
| Route the user's MIDI to the generator (fast loop) | **Nothing** in Seshat; in Live it is a track's MIDI To / a device on the track — the M4L topology below makes it a device drop |
| Clip naming and metadata | `set_clip_name` |
| Warp the captured clip | `set_clip_properties` (`warping`, `warp_mode`) |
| MIDI/clip inspection for chord context | `get_clip_notes` |
| Section markers | **Nothing.** Arrangement locators are not in the fork; scene names are the nearest stand-in |

Two gaps matter.

**Where the generator runs, and how audio reaches Live.** Two topologies:

- *Generator inside Live* — **preferred with MRT2.** The `mrt2~` Max
  external wrapped in a Max for Live device on the collaborator track (or
  the AUv3 instrument). Audio originates on the track; Live's plugin delay
  compensation applies; the user's MIDI reaches the model through ordinary
  Live routing, which is the fast loop with nothing in between. Seshat
  steers the device rather than a process: the M4L wrapper listens on a UDP
  port for the OSC Seshat already speaks, so the provider adapter sends
  `prompt`, `weight`, `temperature`, `drums` messages to the device. The
  cost is owning a Max device; the payoff is that the whole feature is one
  device drop plus Seshat.
- *Generator outside Live* — for Lyria, SA3, or MRT2's Python engine. A
  virtual audio device (BlackHole on macOS, GPL-3.0, user-installed, never
  bundled) that the bridge plays into and the collaborator track takes as
  input; one manual routing step in Live. The fast loop then needs MIDI out
  of Live too (an IAC bus), which is a second manual step.

Spike C tries the outside topology first only because it works for every
generator and needs no Max; the M4L path is what gets built if MRT2 wins
Spike A1.

**Knowing where beat one is.** `NEXT_BAR` scheduling needs phase, and
Seshat has never needed phase. The beat listener gives it with the jitter
of one AbletonOSC tick plus a loopback datagram — call it ±100 ms until
measured. That is fine for scheduling a slow-loop steer and for issuing
`record_clip` (Live quantizes the punch-in itself); it is not good enough to
align a free-running stream in the monitor path, which is one more argument
for Design 1. In the M4L topology the device has the host clock directly
and Seshat need not know phase at all for the fast loop.

---

## 10. Interaction model

The user should not operate a separate "AI music generator" UI.
Collaboration is controlled through the same Seshat language layer, with
the fast loop running silently underneath.

| Intent | Example phrasings |
|---|---|
| Start / role | "Play something underneath this." / "Give me a percussion-free texture for this verse." |
| Follow | "Listen to the keys." / "Follow what I'm playing on track two." |
| Steer | "Half as busy." / "More unstable." / "Stay out of the vocal range." / "Make it feel like it is breathing." |
| Structure | "Build for four bars." / "Come in at the next chorus." / "Drop out after eight." |
| Capture | "Keep that." / "Record the next eight bars." / "Save this version and give me another." |
| Recall | "Go back to the darker one from a minute ago." / "Same idea, but without the piano." |

> **Important UX principle.** Immediate conversational response does not
> require immediate musical mutation. "Got it — changing at the next bar" is
> often the correct behavior. Quantization is part of the intelligence. The
> exception is the fast loop, which is never conversational.

---

## 11. MVP proposal

The first useful prototype should prove one thing: a locally generated
stream can feel like a musically synchronized participant that reacts to
what the user plays.

**MVP scope:**

- One collaborator instance, `mrt2_base` where the chip allows, `mrt2_small`
  otherwise.
- Project BPM, time signature and key/scale read from the mirror; key/scale
  overridable by voice.
- Fast loop: one MIDI track's output fed to the generator's MIDI
  conditioning.
- Slow loop: prompt-slot steering for role, instrumentation, density,
  drums on/off; `NEXT_BAR` and `N_BARS` scheduling primitives.
- Free-running monitor (M4L device or virtual audio device); grid alignment
  at capture via Live's warp (Design 1).
- Quantized capture of generated audio into an Ableton clip.
- Voice/text commands: start, stop, follow, less/more busy, add/remove
  influence, build over N bars, capture N bars.

**Explicitly out of scope for MVP:**

- Autonomous full-song arrangement.
- Generating vocals/lyrics.
- Sample-accurate clock lock.
- Realtime harmonic response to arbitrary live *audio*.
- Polyphonic audio-to-chord analysis as a hard dependency.
- Multiple independent AI bandmates.
- Automatic replacement of the user's own musical decisions.

---

## 12. Technical spike plan

Run in order; each can kill or validate the next layer without committing
to the whole feature.

| Spike | Subject | What it measures |
|---|---|---|
| **A0** | SA3 continuation loop (free, installed) — **demoted: run only if A1 is blocked** | 16 bars generated one bar ahead by continuation; coherence and tempo hold by ear and onset grid. Its purpose was to spare installing a second model for the texture-player half; once MRT2 is installed for the fast loop anyway, a slow-loop-only SA3 texture player is strictly worse than MRT2's in-place steering ([one-model-or-two.md §6](one-model-or-two.md)) |
| **A1** | **Magenta RealTime 2** (`uv pip install "magenta-rt[mlx]"`, ~1 GB) | Tempo adherence to prompt text; drift over 32 bars (decides Design 1 vs 2); control latency; time-to-first-audio; whether a prompt change needs a reset. **Then the fast loop:** play a chord sequence in over MIDI, listen for whether the output follows it and how fast. **Then the clip questions** ([one-model-or-two.md §6](one-model-or-two.md)): offline real-time factor of `mrt2_small` and `mrt2_base` via `mrt mlx generate --duration` on this machine — unpublished anywhere, and the number that decides whether MRT2 can render clips at all; whether a pianoroll fed from `get_clip_notes` makes an offline render *follow* the harmony or merely avoid it; and the trim/downbeat cost of turning a `--duration` render into a bar-exact clip |
| **A2** | Lyria RealTime (needs a key) | Same protocol minus the fast loop, as the quality comparison. Run only if A1 falls short — it is the only arm with a vendor, a watermark and a bill |
| **N** | Notochord (pip, CPU) | IAC bus into a Live MIDI track; harmonise a played line; judge whether it feels like a partner. Runs in parallel with A1 |
| **B** | Local bridge | Only for the outside-Live topology: play the stream into a virtual audio device with stable, known latency |
| **C** | Ableton transport + capture | Subscribe to `/live/song/start_listen/beat`, measure jitter; prove `NEXT_BAR` scheduling; prove `record_clip` with `bars: N` captures a take whose downbeat lands where expected after Live's latency compensation |
| **D** | Drift | Run 32–64 bars free-running; measure phase error; decide whether Design 2 is needed at all |
| **E** | Capture workflow | "Capture 8 bars" → a correctly aligned clip whose first downbeat lands where expected |
| **F** | Conversational steering | Map Planner intentions to MRT2 prompt weights; verify that ramps feel coherent at bar boundaries; measure utterance-to-tool latency |
| **M** | Max for Live device | Wrap `mrt2~` in an M4L device with an OSC listener; confirm the user's MIDI reaches it through Live routing and Seshat's messages land |

---

## 13. Acceptance criteria for a convincing prototype

- A user can start the collaborator while a project is playing without
  configuring an external generator UI.
- It enters on a chosen bar boundary and subjectively feels synchronized
  with a simple project groove.
- **It follows a chord change the user plays within one beat.**
- Over a 32-bar test, drift stays low enough that the part does not sound
  like a second unsynchronized drummer.
- "Less busy," "more tension," "remove drums" audibly affect the next
  scheduled musical window.
- "Capture the next 8 bars" creates a clip exactly eight bars long, aligned
  to the grid after warping.
- Stop/restart or another take never corrupts the session.
- Generator failure degrades safely: the collaborator mutes and Seshat says
  why; transport and existing audio continue.

---

## 14. Risks and unknowns

| Risk | Why it matters | Mitigation / test | Severity |
|---|---|---|---|
| Tempo hold from prompt text | MRT2 has no `bpm` field; if it wanders, the free-running monitor drifts audibly within a phrase | Spike A1 measures first; Design 2 is the fallback, at the cost of fast-loop latency | High |
| MRT2 quality unpublished | Model card defers evaluation; genre coverage is a stated limit | A1 judged by ear; A2 (Lyria) as the comparison if it disappoints | Medium |
| Fast loop through the Python engine is slower than through the Max external | The 200 ms figure is the engine's; Python + BlackHole + IAC adds hops | Prefer the M4L topology (Spike M); measure both | Medium |
| Slow-loop steering goes through an LLM turn | Utterance → Claude → tool is seconds before the provider hears it | `NEXT_BAR` as the default, never "now"; measure in Spike F; never route the fast loop this way | High |
| Musical blandness / role collision | Even synchronized output may fight the arrangement | Role/register prompts, drum gate, quick reject/regenerate | High |
| Stereo mix only | Generated instruments are not individually editable | Treat output as resampling material; Notochord for the editable-notes role | Medium |
| Architectural shape | Seshat's tools are stateless; this needs a long-running collaborator process (or a device) and, outside Live, an audio thread | Own OTP supervision subtree; a collaborator crash never takes `Transport` or the mirror down; only captured clips touch undo history | Medium |
| Owning a Max for Live device | A new artefact type in the repo, needing Max to build | Keep it thin: OSC in, `mrt2~` messages out; the Python topology remains the fallback | Medium |
| Apple Silicon only | Realtime MRT2 does not run elsewhere | Accepted for now; matches where Live-plus-Seshat lives | Low |
| Young dependency | Two months old; API shape undocumented | Provider seam; pin the version; watch the changelog | Medium |

---

## 15. Recommended architecture decision

> **Recommendation.** Prototype this as a first-class Seshat collaboration
> subsystem on Magenta RealTime 2, running locally, preferably as a Max for
> Live device on the collaborator track that Seshat steers over OSC. Keep
> the generator behind a `GenerativeMusic` provider interface so Lyria (or
> whatever comes next) can be substituted. Build the intent-scheduling,
> constraint and capture layer as Seshat infrastructure; that is the durable
> product value.

A clean ownership split:

| Component | Owns |
|---|---|
| Seshat session coordinator | Lifecycle, state, failure recovery, user intent |
| Planner | Natural language → collaboration intentions and timing (slow loop) |
| Ableton adapter | Transport/project state, track creation, capture, clip naming, warp |
| Constraint engine | Tempo, key, role, exclusions, section context → prompt slots and gates |
| `GenerativeMusic` provider | Model-specific translation; MRT2 first |
| Fast-loop route | Live MIDI routing into the generator; set up once, never reasoned about |
| Sync + capture | Capture-time warp; optional drift correction; crossfades if Design 2 |
| Collaboration history | Parameter snapshots and captured takes for "go back to that" |

---

## 16. Open product questions

- How much slow-loop latency feels acceptable? Floor: ~200 ms generator plus
  one LLM turn plus the wait to the next bar. Spike F measures the middle
  term.
- When the generator's rhythm conflicts with the project, stretch it,
  regenerate it, or mute it? (§7.3 argues: never stretch the monitor;
  regenerate or mute, warp only at capture.)
- What is the first compelling role: atmospheric texture, comping,
  counter-line, groove, bass?
- Which track does the fast loop follow by default — the armed one, the
  selected one, or one the user names?
- Rolling buffer for "keep the last eight bars"? `record_clip` cannot do
  retroactive audio; a rolling buffer plus file import is the only route.
- How should provenance be represented when generated audio enters the
  project? No watermark with MRT2, so this is a product choice, not an
  obligation; the clip name is the minimum.
- Does Seshat ship the M4L device, or install it from the repo on first
  use?

---

## 17. Suggested first demo

Build a deliberately narrow demo rather than a general AI musician:

> **Demo: "AI Texture Player that listens."** Open a 4/4 project at 90–110
> BPM with a key set in Live's key box. Drop the collaborator device on a
> new track. Say "give me a sparse, nocturnal texture, no drums, follow the
> keys." The AI enters on the next bar, stays behind the groove for 16+
> bars, moves with the chords as they are played, responds to "more tense
> over four bars," and captures the next eight bars into a new clip.

If that feels good, the feature has legs. If it does not, more prompts or
more UI will not rescue it. The first question is whether the fast loop plus
the conversational slow loop feels musically alive.

---

## Sources

1. [Google AI for Developers — Real-time music generation using Lyria RealTime](https://ai.google.dev/gemini-api/docs/realtime-music-generation)
2. [Google Magenta — The Infinite Crate (Lyria RealTime VST)](https://magenta.withgoogle.com/infinite-crate)
3. [Magenta GitHub — the-infinite-crate source / architecture](https://github.com/magenta/the-infinite-crate)
4. [Google Magenta — Open-sourcing The Infinite Crate DAW plugin](https://magenta.withgoogle.com/oss-infinite-crate)
5. [Gemini API — Lyria RealTime experimental model page](https://ai.google.dev/gemini-api/docs/models/lyria-realtime-exp)
6. [Gemini API Additional Terms of Service](https://ai.google.dev/gemini-api/terms) · [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
7. [Magenta RealTime 2 — repository](https://github.com/magenta/magenta-realtime) · [model card](https://huggingface.co/google/magenta-realtime-2) · [announcement](https://magenta.withgoogle.com/magenta-realtime-2) · [Live Music Models paper (v1)](https://arxiv.org/abs/2508.04651)
8. [Notochord — repository](https://github.com/Intelligent-Instruments-Lab/notochord) · [paper](https://arxiv.org/abs/2403.12000)
9. [ReaLchords / ReaLJam / GAPT — PyTorch port](https://github.com/lukewys/realchords-pytorch) · [ReaLJam paper](https://arxiv.org/abs/2502.21267)
10. [Stable Audio 3 — repository](https://github.com/Stability-AI/stable-audio-3)
11. [LiveBand](https://arxiv.org/abs/2606.03803) · [StreamMUSE](https://arxiv.org/abs/2606.11886) · [Latent-diffusion co-performance with Max/MSP](https://arxiv.org/abs/2604.07612) · [Streaming generation for music accompaniment](https://arxiv.org/abs/2510.22105)
12. [RAVE](https://github.com/acids-ircam/RAVE) · [VampNet](https://github.com/hugofloresgarcia/vampnet) · [Mubert API](https://mubert.com/api) · [Magenta Studio](https://magenta.withgoogle.com/studio/)

Every model figure above is reported, not measured. Re-check MRT2's
changelog, the Hugging Face gating, and the Max external's exposed messages
before implementation. This handoff intentionally separates durable Seshat
design from model-specific assumptions.
