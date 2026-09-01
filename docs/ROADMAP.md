# Roadmap

The single living list of what to do next — features, defects, and security
work in one ranked queue. The top item is the biggest win, work top to
bottom. 

**Adding an issue to the roadmap**
An issue must state its goal and why it's worth building. Where the value is user-visible, include user stories — concrete moments that show the feature earning its place. Internal plumbing items wont usually have a user story. An issue must also include context for the plan author — a roadmap entry is **not** an implementation plan. Plans get written per issue (the `/plan` skill) when the work is picked up.  

Ranking criteria is **impact-per-effort**, mission impact weighed against cost. A medium-impact quick win outranks a high-impact slog.  Place the new issue in the appropriate order for its priority.  

Every issue carries its scores on the line under its heading — **impact** (1-10,
user-visible value: how much better the producer's experience gets) and **lift**
(1-10, work required: 1 is a quick PR), with the quotient. The whole queue was
scored and reordered on 2026-08-27. Score a new issue the same way and insert it
at its quotient.

**Bridge work is cited, never described.** Where an issue depends on a change to
[the AbletonOSC fork](https://github.com/jpatricknola/AbletonOSC) — a missing
address, a bridge defect, a wrong `API.md` row — that change is filed as an
issue on the fork and this entry **links it and states whether the item is
blocked without it, or merely degraded and how**. That distinction is what
decides where the item sits: blocked means the quotient is meaningless until the
fork moves, while degraded is ready work today with a named rough edge. A linked
issue with no such sentence reads as blocked by default, which parks buildable
work at the top of the queue.
Do not restate the handler, the reply shape or the Python here: the fork's
issue holds every detail of the change, this file holds the Seshat work that
consumes it, and a description in two places is a description that goes stale in
one. The same rule governs plan docs. Format and boundary:
[.claude/docs/filing-fork-work.md](../.claude/docs/filing-fork-work.md).

**Dependencies outrank the quotient.** The quotient orders work that is *ready*;
it never places an issue above something that has to land first. Where an issue
is gated, it says so under its scores and its gate sits above it — which is why
"Search eval harness" sits near the top at a quotient of 0.67, ahead of six
catalog levers that score better and cannot start until it exists. Sort
prerequisites first, then rank the ready work by quotient inside that. A related
trap: impact scores *user-visible* value, so pure plumbing scores low however
necessary it is. Read a low quotient near the top as "cheap thing that unblocks
expensive things," not as a mis-rank.

**Removing an issue from the roadmap**
Issue numbers are ranks, not stable identifiers - when something ships, delete all trace of it from the roadmap and let the rest renumber (the `/ship` skill handles this). If a shipped issue had a detailed plan doc, move that doc to [archive/](archive/) with a status banner. Nothing else about a ship stays here — this file documents future work only, and ship history lives in git, CLAUDE.md's Current focus, and [archive/](archive/). A shipped issue is mentioned below only where an *open* item needs it as context.  **Cite an issue by its title, never by its rank**
A rank is correct only until the next ship, and a stale one doesn't look stale — it silently points at a different item. Any cross-reference written by rank will quickly become wrong, trust me, its happened a lot.

**[Deliberately not planned](#deliberately-not-planned)**
The section at the end of this file records ideas that were weighed and
declined, each with the condition that would reopen it. Check it before
proposing or re-proposing work. Add to the list when rejecting a proposed issue.  


---

## #1 · NKS load path — prove a Collector's Edition preset can land on a track (Spike L)

**Impact 3 · Lift 2 · 1.50 impact-per-effort**

Sits at #1 by decision (2026-09-01): it is the go/no-go gate for the whole
semantic sound-selection arc evaluated in
[evaluating/semantic-sound-selection-options.md](evaluating/semantic-sound-selection-options.md),
it is days-cheap, and per this file's dependency rule a gate sorts above the
work it unblocks. Impact is scored as the plumbing it is — the arc it
unlocks is scored when its own items are queued.

Plan: [PLAN_nks_load_path.md](PLAN_nks_load_path.md) — planning ran much of
the spike against live Ableton on 2026-09-01: the reindex→load chain is
proven end to end for a foreign-written `.adv`, rejection is a measured
silent no-op with a false-success reply, a real Live-written VST3 reference
framing was recovered, and one fixture-faithful candidate (attempt D) is
built and untested. Read its "What planning measured" section before
re-measuring anything.

**Goal:** answer, with Live running on this machine, whether a Native
Instruments NKS preset that retrieval names — e.g. "Massive X / Agonic
Drone" — can be landed on a track programmatically. The candidate
mechanism: parse the `.nksf` file's `PLID` (plugin id) and `PCHK` (raw
plugin state chunk, ~30 KB, already parsed successfully on this machine),
wrap that state as a Live `.adv` device preset in the User Library, then
load it through the existing `reindex_library` → `load_device` flow and
verify the instrument opens carrying *that preset's* sound. Record the
outcome — and, on failure, which named fallback is chosen — in the options
doc. This is the single measurement the evaluation could not make without
writing code.

**Why:** the 2026-08-31 evaluation of the semantic instrument-selection
brief found the binding gap is not retrieval but loading: Live's browser
(measured: dev catalog, 5,796 entries) holds **zero** NKS preset entries —
NI products appear only as 10 bare plugin devices — so even a perfect
"cold mechanical bass" ranking currently names presets Seshat cannot load.
Every strategy in the brief (semantic metadata, CLAP-on-previews, hybrid)
chains through this one answer, and its outcome sizes the entire arc:
success means the full Collector's Edition corpus (the brief's stated
assumption) is in play; failure of every fallback shrinks NKS to metadata
enrichment of sounds Live already loads. Cheapest possible de-risk of the
largest open feature area.

**Eventual user story (not this PR's deliverable):** "give me a cold,
slightly unstable synth like early Depeche Mode" ends with ranked real
candidates *loaded and sounding*, not just named. This PR proves or
disproves the last step of that chain.

**In scope — one PR:**
- A bounded `.nksf` reader (RIFF walk: `NISI` msgpack metadata, `PLID`,
  `PCHK`) and a `.adv` writer for the spike only. Product-shaped code only
  if it earns it; otherwise it lands beside
  [../experiments/gmd_profiles/](../experiments/gmd_profiles/) as a spike
  script with the same status.
- Reading spike-corpus rows from the NKS SQLite (`v_sound_info` — paths
  and schema in the options doc). Read-only, same posture as
  `Seshat.Library.AbletonDB`; no new process door, no new tool, no
  `Definitions` change, no fork change.
- Synthesis + load verified for at least Massive X (local factory presets,
  60 with previews), ideally one VST3 and one AU wrapping each.
- Verification: preset file placed in the User Library, `reindex_library`,
  `load_device`, then `get_track_devices` read-back plus listening — does
  it sound like the preset's own `.previews` ogg?
- The live check cited per `/smoke-write` (likely a new
  `docs/smoke_tests/` entry; the whole point needs Ableton).
- The measured outcome written into
  [evaluating/semantic-sound-selection-options.md](evaluating/semantic-sound-selection-options.md)
  § "What remains unmeasured", either way it goes.

**Out of scope, deliberately:** embeddings of any kind, CLAP, the Python
sidecar, the eval harness (that is "Search eval harness — numbers before
opinions" below), new MCP tools, full-library indexing, mounting or
re-downloading the absent external-volume content, and *building* the AX
fallback (failure of the `.adv` route only *names* the fallback, per the
ladder in the options doc).

**Planner notes:**
- All measured evidence (DB paths, `v_sound_info` columns, the parsed
  `Agonic Drone.nksf` chunk layout, the DB-underscores-vs-disk-spaces
  filename trap, the unmounted `/Volumes/Instruments` roots) is in the
  options doc — read it first, don't re-measure.
- The `.adv` format is the spike's actual unknown: gzipped XML carrying a
  plugin-state blob (`VstPluginInfo`/`AuPluginInfo` framing, VST3 vs AU
  differ). Nothing anywhere confirms Live accepts a foreign-written blob;
  that is precisely the question. Reference-diff a `.adv` Live itself saves
  for the same plugin+preset before writing the generator.
- Fallback ladder on failure, in order: per-format chunk-framing surgery;
  AX-scripting Komplete Kontrol's search field
  ([evaluating/ui-scripting-options.md](evaluating/ui-scripting-options.md)
  mechanism costs apply); corpus restriction to Live-loadable items. The
  PR records which rung was reached and why it stopped there.
- A failed spike still merges: the parser knowledge, the reference diffs
  and the recorded verdict are the deliverable. Success is not license to
  scope-creep into indexing — the next items in this arc get queued
  separately once "Search eval harness" numbers exist.
- Needs Live running for the load half; no Live restart, no
  `mix abletonosc.install`.


## #2 · Soften the velocity-class clamp in symbolic MIDI generation

**Impact 5 · Lift 2 · 2.50 impact-per-effort**

**Goal:** replace the hard `min`/`max` clamp in `keep_class_order/3`
(`lib/seshat/generation/midi/performance.ex:146-156`) with a soft compression
(reflect, tanh, or a truncated normal draw) that keeps the same guarantee —
a ghost, hit or accent never crosses into a neighbouring class's velocity
band — without piling draws up on the exact band edge.

**Why:** raised as a non-blocking quality finding in the 2026-08-30 PR review
of "MIDI generation — the first solution, composed symbolically", with
live evidence: on Live 12.4.5, the rock `closed_hat` band `[55.55, 88.7]`
against a hit σ of 19.2 sent the dense all-`x` 1/16 hat lane back with 8 of
15 sampled notes at exactly one of the two band edges (53%), and the funk
kick lane 6 of 24 at exactly one of its two edges (25%). The whole point of
the performance layer (`Performance`'s moduledoc: "answers the 2026-08-25
failure") is to kill uniform, machine-sounding velocities; a hard clamp
manufacturing its own repeated identical values on the densest, most
audible lanes undercuts that on exactly the material most likely to be
judged by ear. Worth fixing before the by-ear listening slate this feature's
plan defers to, so that slate measures the composition, not this artifact.

**Planner notes:**
- `class_room/2` (immediately below `keep_class_order/3` in the same file)
  computes the same class boundaries for `velocity_deviation`'s ceiling —
  reuse rather than re-derive them.
- Keep the ordering guarantee exact (a ghost must never sound louder than a
  hit); only the *distribution within* a class's legal band should change
  from "pinned at the boundary" to "soft-landed near it."
- `test/seshat/generation/midi/performance_test.exs` presumably already
  asserts on `keep_class_order/3`'s clamping behaviour directly or through
  `perform/2`'s output — update those expectations alongside the fix rather
  than loosening them to pass.

## #3 · `record_clip` reports where the take actually started

**Impact 7 · Lift 4 · 1.75 impact-per-effort**

**Goal:** make a take recorded over a playing loop placeable afterwards. At
the moment the punch-in actually happens, read the position and report it in
`record_clip`'s (and `stop_recording`'s) reply, so extracted material can be
rotated back into the loop's frame deterministically instead of guessed.

**Why:** raised from real use, 2026-08-31. A 2-bar MIDI loop was playing; the
user recorded a 2-bar audio take on another track, performing in time with it.
Launch quantization was 1 bar, so the take punched in at a boundary that may or
may not have been the loop's top, and the take's own timeline starts at zero
regardless. After `convert_audio_to_midi` the extracted notes could not be
mapped back into the loop: if the punch-in was mid-loop everything is rotated
by a bar and **nothing in the reply distinguishes the two cases**. The model
guessed a rotation, guessed wrong, reverted, and ended up asking the user to
dictate note positions by ear — the exact failure the tool exists to prevent.
This is the same class of defect as the `fire_clip` phase gap fixed by
description on 2026-08-31: Live's global grid is not the loop's phase.

**User story:** "Record me two bars of humming over that loop" → the take is
converted and the notes land where they were sung, without the user checking
by ear or being asked where the bar line was.

**Planner notes:**
- **The requested number is not the right one.** The report asked for
  `current_song_time` at punch-in, with `loop-relative offset = start mod loop
  length`. That formula assumes the reference loop started at a song time that
  is a multiple of its own length, which is exactly what is not guaranteed —
  the loop was itself launched at a 1-bar boundary. The correct measurement is
  `/live/clip/get/playing_position` **on the reference clip**, which is already
  loop-relative by construction. Report `current_song_time` too if it is cheap,
  but do not build the mapping on it.
- Both addresses exist upstream (`priv/AbletonOSC/API.md`) — no fork change.
- The punch-in is asynchronous: `record_echo/3` in
  `lib/seshat/tools/handlers.ex` already distinguishes recording from queued,
  and a queued take can wait up to a full bar. So the position read has to
  follow a poll for `is_recording`, in the shape
  `convert_audio_to_midi` established (bounded polls, honest reply when the
  deadline passes) rather than a single read.
- **Precision is sufficient and worth stating in the reply.** A poll interval
  plus a round trip is ~100–200ms, ≈0.2–0.4 beats at 120bpm. The ambiguity
  being resolved is *whole bars*, so that error never changes the answer —
  but the reply should give the position as measured, not imply sample
  accuracy.
- Which clip is "the reference" has to come from somewhere: an optional
  parameter naming the track whose clip the take is played against is the
  cheapest honest answer; falling back to "report the position of every
  currently playing clip" is defensible but noisier.
- The report also asked for **an option to quantize the punch-in** to a chosen
  interval (2 bars, the playing scene's length). Weigh it, but note two
  things before committing: the only lever is the *song* property
  `clip_trigger_quantization` (the clip property `launch_quantization` cannot
  be set on a clip that does not exist yet), so it means mutating and
  restoring global state — over the enum-offset trap `API.md` documents under
  "`clip_trigger_quantization` is not the `launch_quantization` enum" — and it
  **still does not guarantee loop phase**, because a coarser global boundary is
  still a global boundary. `fire_scene` on a shared row is the free version of
  this and is already in `record_clip`'s description as of 2026-08-31.
- Live verification: this cannot be judged from `mix test`. It needs a real
  loop playing and a take punched in deliberately off its top —
  `docs/smoke_tests/manual/engineered-state.md` is the folder that fits.

## #4 · Generated-audio alignment, warping and quality polish

**Impact 7 · Lift 5 · 1.40 impact-per-effort**

**Blocked in front by a usage finding, 2026-08-30:** across ordinary use since
the tool shipped, **no generation has produced material judged good or
usable** — not a scored slate, but a consistent report. Reading the generation
path while recording it found a likely cause that has to be ruled out before
any alignment work is worth doing: the shipped lane renders with
**classifier-free guidance off**. `Seshat.Generation.StableAudio.argv/1`
passes `--cfg` only alongside a negative prompt, and the runtime's `--cfg`
default is `1.0`, which its own flag table defines as guidance off — so an
ordinary call, which carries no negative prompt, steers toward nothing in the
prompt at all, including the appended tempo and time signature this item is
about. Test that first (`--cfg 3.0`, then `medium`, against the same prompts);
it may be a one-line argv change, and it may also move the grid-adherence
measurements below. If guided renders on the bigger model are still unusable,
the question stops being alignment and becomes whether SA3 is the right
generator, which belongs in
[audio-generation-options.md](evaluating/generative%20features/audio-generation-options.md)'s
provider table rather than here. Polishing the grid placement of material
nobody wants to keep is the wrong order.

**`generate_audio` has shipped** (archived at
[PLAN_generate_audio_clip.md](archive/PLAN_generate_audio_clip.md)), producing
the real imported fixtures this item measures — though its own live checks
have not run yet (see the archived plan's banner), so confirm those before
treating the fixtures as settled. **Deliberately sequenced after "MIDI
generation — the first solution, composed symbolically" by decision on 2026-08-29** — the audio
story was split into two PRs, and the MIDI half is worth more than polishing
audio that already lands in the right slot.

Plan: [PLAN_generate_audio_polish.md](PLAN_generate_audio_polish.md) — written
as the deferred half of the generation plan, and finalised against the MVP's
measurements rather than ahead of them.

**Goal:** turn the raw, duration-exact clips established by `generate_audio`
into performance-ready loop material where the evidence supports it, without
holding the first generation/import PR hostage to DSP and listening details.

**Why:** the spike already shows that exact file duration is not the same as a
musical loop: several drum renders begin between grid lines and many fade near
the file end. The cause was named on 2026-08-30, the day the tool shipped:
Stable Audio's text conditioning is semantic, not symbolic — it has no notion
of "exactly two beats" or "a half note", so the appended "120 BPM, 4/4 time"
steers loosely and nothing in the prompt can lock the content inside a
duration-exact file to the grid. That is the same finding that demoted
audio→MIDI transcription as the primary MIDI strategy (see "MIDI generation —
the first solution, composed symbolically"), and it points at the lever this
item should reach for first: **audio conditioning**, already wired as
`variation_of` (`--init-audio` / `--init-noise-level`) — a click or rhythmic
skeleton at the session tempo as the init signal is a far stronger grid
constraint than any wording. Reading back the warp tempo Live detects on
import against the session tempo is the cheap measurement. Live may also choose looping and warping defaults that vary with
content or preferences. The MVP produces real imported fixtures and reports
those observations; this follow-up then solves the measured failures instead of
guessing at them in the initial tool contract.

**User stories:**
- As a producer who asked for a four-bar loop, the pattern's intended phase
  lands on the grid — including a requested pickup or rest — and the clip loops
  without a click or gap at the seam.
- As a producer who changes the set tempo after generating, the clip follows
  it — or Seshat says plainly that it will not.
- As a producer chasing a better take, a higher-quality lane exists only
  because it audibly beat the default, not because the model has one.

**Scope:**
- Measure raw and imported clips against the metronome, including Live's
  looping/warping defaults and behaviour after the set tempo changes.
- Evaluate over-generation, sub-beat grid-phase detection, exact cropping,
  silence/fade handling and seam repair while preserving pickups and rests.
- Set and read back warping, looping and loop markers only where the resulting
  playback contract is demonstrably reliable.
- Compare `medium` against `sm-music` by ear and expose a `best` lane only if it
  audibly earns the extra model weight, latency and contract surface.
- Add durable by-ear smoke coverage for grid placement, seam quality, pickup/
  rest preservation, tempo changes and close-versus-loose variations.

Keep any model/runtime or OSC additions in this PR proportionate to the
specific failing measurements.

## #5 · `convert_audio_to_midi` reports its own artifact notes

**Impact 4 · Lift 3 · 1.33 impact-per-effort**

**Goal:** stop Live's drum conversion handing back near-silent classification
failures as if they were played material — either filter them out of the
converted clip, or name them in the reply so the model does not build on them.

**Why:** raised from real use, 2026-08-31. Converting a drum take, Live emits
notes at velocity ≈ 1 on the closed-hat pitch where its classifier fails to
place a hit. They are inaudible, so nothing warns the user, but they read back
through `get_clip_notes` as ordinary notes and were mistaken for real material
during the same session that produced "`record_clip` reports where the take
actually started". A conversion whose reply says nothing about them is a
conversion the model cannot reason about honestly.

**Planner notes:**
- Measure before choosing a rule. "velocity ≈ 1 on the closed-hat pitch" is one
  user's observation of one take, not a characterised behaviour: confirm the
  velocity actually emitted, whether the pitch is always 42, and whether Melody
  and Harmony conversions do anything comparable. The measurement belongs in
  `priv/AbletonOSC/API.md` or the fork's docs if it turns out to be a stable
  property of Live's converter.
- **Flagging is the safe default, filtering is a deletion.** The converted clip
  is the user's material; silently removing notes from it is the kind of
  destructive step "Verify destructive mutations before reporting success"
  exists about. If filtering is offered at all it should be opt-in, and the
  reply should say how many notes went.
- The conversion already resolves the new track by name divergence
  (`lib/seshat/tools/handlers.ex`), so the clip is addressable for a note
  read-back without new plumbing; `edit_notes`' delete path already exists if
  filtering is chosen.

## #6 · Generated material lands one instrument per track

**Impact 9 · Lift 8 · 1.12 impact-per-effort**

**The render and import half this splits has shipped** as `generate_audio`
(archived at [PLAN_generate_audio_clip.md](archive/PLAN_generate_audio_clip.md)),
and the MIDI half of this item's own goal has shipped too: "MIDI generation —
the first solution, composed symbolically" (archived at
[PLAN_midi_generation_symbolic.md](archive/PLAN_midi_generation_symbolic.md))
delivered `generate_midi`, which already lands one named MIDI track per part
in one call under one undo step — a multi-part *MIDI* request is done, and
this item is no longer gated on it. **Ranked directly under the generation
items by decision on 2026-08-29**: a generated result with more than one
instrument in it is not finished until each instrument has its own track, so
this was the second half of the generation feature, not an enhancement to
it. **What remains is audio-only:** a joint audio render (`generate_audio`)
split into per-instrument audio tracks, which is where the separators and the
"Live-native generation spike" (Stem Separation) still apply; the
transcription lanes below (Convert Drums, Inverse Drum Machine, Basic Pitch)
are no longer the expected route to that split either, since audio→MIDI is
rejected as the primary MIDI strategy.

**Goal:** when a generated *audio* result contains more than one instrument —
a drum kit is the main case: kick, snare, hats, toms, percussion — each
instrument lands on its own track, the way a producer lays out a kit
(an eight-track drum kit, not one stereo loop on one track). One request,
one undo step, tracks named by instrument, playing together exactly as the
joint render did. "Instrument" means a musical role the producer would mix
separately, which is the user-stories doc's **part**.

**Why:** a single stereo loop is a sketch; a kit split across tracks is
material — the kick can be swapped, the hats sidechained, the snare sent to
a reverb, one hit nudged, and all of that is what the producer does next.
Everything downstream of generation (mixer, sends, devices, `edit_notes`)
works per track, so a joint render on one track leaves the rest of Seshat's
surface unable to touch the parts. The user-stories doc already settles
"separate parts per track, MIDI the default"; this item is where that
promise meets an audio render.

**User stories:**
- As a producer who asked for "a dusty lo-fi beat", I get a Kick, Snare,
  Hats and Perc track, not a "Beat" track, and can say "swap the kick for
  something rounder" without touching the rest.
- As a producer who asked for "a beat with a bassline", the bass is its own
  track from the start, and "undo that" removes the whole set of tracks in
  one step.
- As a producer who wanted the loop as-is, I can ask for it kept as one audio
  track and get exactly that — splitting is the default for a kit, never a
  surprise.

**Context for the plan author:**
- **Per-drum audio separation exists; the repo's survey never covered it,
  and licence is the selection criterion.** Live's own *Separate Stems to
  New Audio Tracks* is four stems (vocals / drums / bass / other) with the
  whole kit as one, and the separators surveyed in
  [live-native-options.md](evaluating/generative%20features/live-native-options.md)
  are the same four — but a second tier splits a *drum stem* into kit
  pieces (checked 2026-08-29):
  - **LarsNet** (polimi-ispl, five stems kick / snare / toms / hi-hat /
    cymbals, faster than real time, parallel U-Nets): weights **CC BY-NC
    4.0** — disqualified as shipped, the same NC wall that excluded ADTOF.
    Its training set **StemGMD is CC-BY 4.0**, so a permissively licensed
    retrain is possible; that is a spike with a GPU bill, not a dependency.
  - **inagoy "drumsep"** (Hybrid-Demucs fine-tune, kick / snare / toms /
    cymbals): licence **unknown** on every mirror — disqualified until the
    author states one.
  - **jarredou / MDX23C drum separator** (six stems incl. crash and ride
    separately): trained on a private dataset, licence unstated — same.
  - **Side Brain "DrumSep" Live extension** (Extensions SDK, June 2025
    beta, wraps MDX23C, local CPU, pay-what-you-want): a *user-installed*
    product that lands stems on tracks Live's own way. Reachable, if at
    all, only as the AX spike reaches Live's own commands — and it keeps
    the model outside Seshat, the SA3 precedent for restricted weights.
  - **cukas/drumsep** (MIT, no model: HPSS + frequency masking + transient
    gating; numpy/librosa/soundfile, ~50 MB): zero licence surface, honest
    caveats (adjacent-stem bleed, designed for isolated drum stems — which a
    generated drum loop *is*). The only candidate selectable today; quality
    on SA3 material unmeasured.
  Generated loops are a friendlier input than records: no room, no bleed,
  no vocals to strip first. So a separation arm belongs in the plan, and
  the by-ear gate decides whether a masked split is material or mud.
- **Read [extensions-sdk.md](evaluating/extensions-sdk.md) before weighing
  that list again** (researched 2026-08-30). The Side Brain entry above is no
  longer the lone extension: the ecosystem now lists ~334 extensions
  including an **Audio Separator** and **Basic Pitch** (MIT wrapper, offline,
  one drag) — the same lanes this survey went licence-hunting for. That does
  not make them selectable *for us*: Extensions are Live 12 Suite only and
  need beta access Seshat does not have, and they run only when a user
  right-clicks. What it argues against is narrower than it first looks:
  **owning a separator or transcriber to serve the generation pipeline** —
  this item's own purpose — is what the free lanes undercut, because whatever
  produces the stems or the notes, the result is ordinary clips and Seshat's
  edit surface is the part that has to be good. It says nothing against
  transcription as a *user-asked-for feature*: `convert_audio_to_midi` ships
  exactly that, on human performance rather than generated audio, and the
  2026-08-30 ruling was scoped to Route C, never to transcription in
  general.
- The routes that do exist, each with a known ceiling on lane count:
  *Convert Drums to New MIDI Track* — kick / snare / hat, three lanes, onto
  one Drum Rack on one track, so Seshat still has to split lanes across
  tracks afterwards (extra mutations, and the Drum Rack pad map is a fork
  gap — `DrumChain.in_note`, `RackDevice.insert_chain`); a transcriber over
  the render — Inverse Drum Machine (Apache-2.0, class count unverified), a
  specific-case lane only since the 2026-08-30 ruling; GMD retrieval — nine lanes, but it
  replaces the render rather than splitting it. Per-lane MIDI then lands
  through `write_midi_notes` onto per-track instruments chosen from the
  catalog — sound selection per lane is its own question and should be
  scored separately from the split.
- The other shape is *generate per part*: one render per instrument with
  the joint render as `variation_of` at low strength, or the decision
  experiment's conditioned wiring (drums first, the next part responds to
  the actual kick). Independent renders are measured not to interlock; the
  conditioned form is unmeasured. This is the only route to per-instrument
  *audio* tracks that needs no separator, and it should be an arm of the
  plan beside the separation arm, not assumed away.
- Deciding *how many* instruments a render holds is itself unsolved: the
  request text ("kick, snare, hats") is the cheapest signal and the one the
  model already has; a transcriber's non-empty lanes are the second.
- One request is one undo step across N created tracks — the undo-step
  bracketing exists, but `create_track` per lane inside one `Handlers` call
  needs the multi-step `Registry` path, and a partial failure (three tracks
  made, transcription failed) must be reported as such, never as done.
- Bass and melodic parts through Basic Pitch (measured 0.06 s, clean on
  bass) are the same shape with a different transcriber; the plan should
  say whether v1 is drums-only.

## #7 · Live-native generation spike — can AX drive the Create menu?

**Impact 3 · Lift 2 · 1.50 impact-per-effort**

**Narrowed again 2026-08-30 (third time), and its central premise was wrong.**
This item said of its five commands: *"Every one is UI-only (absent from
`_MxDCore/LomTypes.pyc` at any spelling)."* That is tier-3 evidence, which
[CLAUDE.md](../CLAUDE.md) says is safe as a positive and unsafe as a negative,
and it produced a **false negative on two of the five**: Convert
Harmony/Melody/Drums *and* Slice to New MIDI Track are `Live.Conversions`
module-level free functions, and both now have OSC addresses (`API.md` §
"Conversions"). They were never UI-only. Neither belongs to this spike, and
neither is evidence for what the remaining commands can do.

**What is left is two commands: Stem Separation and Extract Groove.** Both are
absent from the regenerated tier-1 inventory — 134 classes and 7 modules
walked, with module-level members now recorded and previously-dropped classes
reported rather than silently filtered — so unlike the Convert case, their
absence is a real negative rather than a blind spot. Scores drop with the
scope: two commands, no transcription lane to decide, and the impact is
whatever Stem Separation is worth to the audio items alone.

**Un-pinned 2026-08-30.** It was ranked above its quotient on 2026-08-28 as
the gate for the MIDI decision experiment, because it decided which of
Live's transcription commands could be an arm. Audio→MIDI transcription has
since been rejected as the primary MIDI strategy (see "MIDI generation — the
first solution, composed symbolically"), so nothing in that item waits on
this. It stays in the generation block at its own quotient for what it still
serves: *Stem Separation* and *Extract Groove* for the audio side ("Generated-
audio alignment, warping and quality polish" and the audio-split half of
"Generated material lands one instrument per track"), and *Convert Drums /
Harmony* as the zero-dependency transcription lane for whatever specific case
audio→MIDI may later earn — reachable or not is still worth one afternoon's
measurement, just not first.

**Narrowed 2026-08-30, then resolved by "Sing it back as MIDI — a sung take,
converted, on the instrument you meant"** (shipped): that item needed the
Convert *Melody* press as a shipping gate, measured it first using this
plan's rig, and it worked — with one correction to the mechanism assumed
below: the command item fires on `AXPick`, not `AXPress` (`AXPress` only
opens the containing menu; `AXEnabled` reads meaningless until the menu is
opened). This spike inherits that proven press, that correction, and the
committed probe, and shrinks to the commands it still owns: Stem Separation,
Extract Groove, and Convert Drums / Harmony.

Plan: [PLAN_live_native_generation_spike.md](PLAN_live_native_generation_spike.md)
— a committed read-mostly probe (`native/seshat_ax/probe/menu_probe.m`,
allowlisted press only), the dialog members read through the temporary
probe-handler rig, one press per command bracketed by track counts and an
undo step, and the result written as §4 "Measured" of
`live-native-options.md`. Planning already measured (2026-08-28, Live 12.4.5
Suite) that every target command sits in the menu bar, that `AXEnabled` reads
while Live is inactive, and that a clip selected over OSC flips that state —
so the mechanism is select-over-OSC, press-over-AX, observe-over-OSC (open
the menu with `AXPress`, fire the command with `AXPick`), and the context
menu is out unless a menu-bar press fails.

**Goal:** one measured answer to whether Seshat can invoke Live's Create-menu
and clip-context-menu commands through the named-AX rung, recorded in
[live-native-options.md](evaluating/generative%20features/live-native-options.md)
§4 "Unmeasured". Not a tool. A spike with a written result.

**Why:** the 2026-08-27 native pass found Live already ships the pieces the
generation research had been surveying dependencies for — **Stem
Separation** (12.3, Suite), **Convert Drums / Melody / Harmony to New MIDI
Track**, **Slice to New MIDI Track**, **Extract Groove**, and **Bounce**. It
then called all five UI-only on a `LomTypes.pyc` grep, and two of them were
not; see the correction above. For **Stem Separation** and **Extract Groove**
the finding stands, on better evidence than it originally had: they are absent
from the tier-1 LOM walk as well, so the Accessibility helper really is the
only rung left. That rung has now been validated twice — the Settings window
(2026-08-03) and the Convert Melody press that shipped "Sing it back as MIDI"
(2026-08-30) — so the open question is no longer *can AX press a menu command
at all*, which is answered, but whether these two particular commands behave
under it: both spawn a job rather than returning, and Stem Separation may
raise a mode dialog. Live's separator is the zero-dependency, zero-licence
path to per-instrument audio. Whether that is real is a one-afternoon question
that has not been asked.

**Context for the plan author:**
- Read [ui-scripting-options.md](evaluating/ui-scripting-options.md) for
  the mechanism ladder and safety model, and its 2026-08-27 production-
  helper measurement. `native/seshat_ax/main.m` is deliberately a closed
  protocol with no generic press command — four commands today, down from
  five now that "`convert_audio_to_midi` drops the Accessibility helper" has
  landed. The spike may use a scratch build or `ax-probe`, but the result
  should say what a *bounded* new command would look like, not add a generic
  one.
- Procedure the doc already names, minus the commands that left: enumerate
  Live's Create menu and a clip's context menu; import one SA3 render from
  `~/.seshat/audio-spike/` by hand; run **Stem Separation and Extract Groove**
  once each; record menu reachability, any mode dialog, duration, and what
  `Session.State` sees — the track-count push is the natural completion
  signal. Note the dialog question has a fork-side answer already: the fork
  **declined** `Application.press_current_dialog_button` on the grounds that a
  dialog may be guarding unsaved work and pressing it blind is unrecoverable
  (`FORK_GAPS.md`), so a command that raises a modal is AX-or-nothing by
  policy, not by Live's limits. If Stem Separation raises one, say so — that
  is the finding.
- Also worth one check each while there: whether a `.agr` groove loads into
  the pool through `Browser.load_item`; Stem Separation's behaviour on a short
  loop. **Dropped from this list:** Convert Drums' lane count and whether its
  velocities vary on SA3 material. That is still a real question, but it is
  now answerable over OSC through `/live/clip/audio_to_midi` with no AX and no
  spike, so it belongs to whatever item revisits drum transcription — not
  here.
- Output is a result section in `live-native-options.md` plus, for each
  command, a verdict of route / not-a-route / needs-its-own-item. If the
  menu is unreachable, say so; that is a valid outcome, and nothing on the
  MIDI side changes either way.
- Suite gate: Stem Separation is Suite-only. Acceptable for an optional
  arm; the result must record which edition it ran on.

## #8 · `mix abletonosc.install` is not atomic and reports unverified success

**Impact 3 · Lift 2 · 1.50 impact-per-effort**

**Goal:** an interrupted `mix abletonosc.install` leaves the previous install
intact rather than a half-written one, a partial copy fails the command
instead of printing `Done.`, and the task can repair its own damaged output
instead of refusing to touch it.

**Why:** `replace!/2` does `File.rm_rf!` then per-entry `File.cp_r!` in
`File.ls!` order, so any interruption — Ctrl-C, crash, timeout, sleep — leaves
a directory that exists, looks populated, and is missing an arbitrary tail.
`pythonosc/` and `manager.py` are copied *last* and are exactly what the
Remote Script cannot start without, so the failure window is nearly the whole
copy and it takes out the two files that matter most. Nothing verifies the
result (`Enum.each` returns `:ok` whether it ran three entries or
twenty-three), and the guard that decides whether a directory is an
AbletonOSC install tests for `manager.py` — the very file a truncated run is
missing — so the task then refuses to replace what it broke.

This happened on 2026-08-30: about an hour, three Live restarts and a wrong
diagnosis. Full forensics, including the recovered copy order and the exact
eleven-entry prefix that survived, are in
[seshat#83](https://github.com/jpatricknola/seshat/issues/83).

**User stories:**
- As a producer whose install got interrupted, Live still starts the bridge
  from the copy I had before, and the command tells me it failed — instead of
  leaving me with a `NameError` in Live's log and a Mix task that refuses to
  fix it.

**Planner notes:**
- Three separable defects, in decreasing order of value: the non-atomic copy
  (fix alone removes the failure mode), the unverified `Done.` (stops a
  partial deploy being invisible), and the guard (stops the tool blocking its
  own recovery). All three live in
  [lib/mix/tasks/abletonosc.install.ex](../lib/mix/tasks/abletonosc.install.ex).
- **Atomic swap:** copy into a sibling temp directory, then `File.rename/2`
  into place — atomic within a filesystem. The sibling matters: the install
  target is under `~/Music/Ableton/User Library/Remote Scripts/`, and a
  `rename` across filesystems is not atomic and may not be permitted at all.
  Keep the delete-then-copy *semantics* the current `replace!/2` comment
  argues for — a stale `track_listeners.py` carried forward from the
  patch-in-place era must not survive — which a swap gives for free, since
  the new tree is built from scratch.
- **Verify before reporting:** after the swap, assert `manager.py` and
  `abletonosc/handler.py` exist in the target and that the entry count matches
  what was enumerated, and print `Done.` only then. This is the same principle
  the task already applies to *which commit* it deployed — it is careful to
  name it, and the moduledoc explains at length why misreporting is worse than
  refusing — extended to *whether the deploy landed*.
- **Distinguish damaged from foreign:** `abletonosc_install?/1` is used by both
  `locate!/1` branches and is a single boolean where three states exist. A
  directory holding `abletonosc/handler.py` but no `manager.py` is a broken
  AbletonOSC install, not somebody else's directory: treat it as repairable and
  say so, keep the existing refusal for a directory with neither. Note the
  no-argument branch is wrong in the same way from the other side — it skips a
  half-full install and prints "No existing AbletonOSC found - installing
  fresh." about a directory that plainly exists. It does recover; it describes
  the situation wrongly.
- **Not blocked by, but degraded without, the fork half.** The bridge's
  `__init__.py` wraps its import in a bare `except ImportError: pass`, so a
  missing `manager.py` and a missing vendored `pythonosc/` produce the
  identical six-word `NameError: name 'Manager' is not defined` — which is why
  neither was found from the error, only by diffing the install against the
  fork checkout. That is the fork's item ("Stop masking Remote Script import
  failures", on the fork's own roadmap), and this one is worth doing without
  it: an install that cannot truncate silently never puts anyone in front of
  that error. Landing both means the diagnosis is cheap on the day something
  else truncates the tree.
- No OSC, no `Definitions`, no fork Python. Live verification is the natural
  check but there is no `auto/` home for a Mix task — interrupt a run and
  confirm the previous install still starts the bridge, by hand.

## #9 · Catalog vocabulary — read tag axes, teach the menu proactively

**Impact 8 · Lift 4 · 2.00 impact-per-effort**

**Goal:** read the tag *axes* (Character, Genres, Type, …) and the
preset→device relation out of Ableton's database, and surface the real
vocabulary proactively in tool replies — so the model sees the menu before
ordering, instead of guessing tags and learning only from failures.

**Why:** this is levers №1+№2 of
[sound-search-options.md](evaluating/sound-search-options.md) — read that doc before
planning; it grounds every claim in measurements. The top of the search
funnel leaks first-attempt vocabulary misses ("warm" isn't a tag here, `Soft`
is), and the axes fix real traps the flat tag list creates (`Distortion` the
device tag vs. `Distorted` the character tag). Highest certain win left in
the catalog area, at Low/Low-Med effort. №2 also enables future levers, which
is why they ship together.

**User stories:**
- As a producer asking for "a warm pad," the first slate is right because
  Seshat already knows this library's word for it is `Soft` — it sees the
  menu before ordering instead of guessing and learning from misses.
- As a producer asking for "something distorted," I get presets with a
  distorted *character*, not everything touched by the Distortion *device* —
  the axes keep those apart.

**Planner notes:**
- The axis lives in `files.parent_id`, which
  `Seshat.Library.AbletonDB.read_tags/1` currently discards; the
  preset→device map is the `file_devices` table (4,535 rows on the dev
  machine).
- Vocabulary is per-machine (depends on installed Packs) — it must flow
  through replies/catalog data, never be hardcoded in a tool description.
  That rule already governs `search_library`'s design.
- Requires a catalog rebuild (`reindex_library`) — fine, just say so; no
  migration shims (see CLAUDE.md).

## #10 · Search eval harness — numbers before opinions

**Impact 2 · Lift 3 · 0.67 impact-per-effort**

**Goal:** a repeatable harness that scores `search_library` relevance against
a fixed set of realistic "describe a sound" queries, so every further catalog
lever gets measured instead of argued.

**Why:** lever №9 of [sound-search-options.md](evaluating/sound-search-options.md),
estimated at a morning's work. It exists to **gate the six catalog levers**:
"Widen the search slate at tied score bands", "Browser preview audition",
"Opt-in `samples` index", "Accepted-search memory", "User XMP tags" and "LLM
enrichment at reindex". After "Catalog vocabulary" lands, the eval decides
whether any of them is still worth buying. "Catalog vocabulary" itself is not
gated — it is a certain win with or without numbers.

**Its quotient understates it, and its rank corrects for that.** Impact 2 scores
the *user-visible* value, which is zero — nobody hears a harness. All six gated
levers score better, so on quotient alone this would sit near the bottom of the
queue with every item that depends on it above it. It ranks second instead
because the dependency wins: this and "Catalog vocabulary" are the only two
issues in the catalog block that can be started today.

**Planner notes:** the result-quality work already used a six-query/77-slot
benchmark informally (see
[archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md));
formalize that rather than inventing a new one. Runs offline against the
catalog — no Ableton needed.

## #11 · Widen the search slate at tied score bands

**Impact 5 · Lift 2 · 2.50 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** when the score band straddling the result cut is large (the ~46
identical-tag `E-Piano *` presets), show more of the band rather than
pretending rank means something inside it.

**Why:** lever №4 — a presentation fix for ranking headroom that scoring
provably can't close (a graded per-term variant measured +1 slot across six
queries and was rejected). Hours of work, honest fix.

**User stories:**
- As a producer choosing an e-piano, when dozens of presets score
  identically, I see the honest breadth of the tie — not an arbitrary top
  five pretending rank means something inside it.

## #12 · A rejected index says which index, and what to call next

**Impact 5 · Lift 2 · 2.50 impact-per-effort**

**Goal:** a tool call Live rejects for a bad index tells the model which index
was bad and which `get_*` tool resolves it, instead of the bare "Ableton
rejected the request: Index out of range".

**Partly solved already, by accident — re-scope before planning this.** Measured
2026-08-05 (`/smoke-test bridge`): `get_track_devices` on track 99 now replies
"Index out of range. Nothing further was sent — check get_session_state for the
indices that actually exist." The batched-reads work of 2026-08-04 routed the
converted reads through `Handlers.remote_error/1` instead of
`Transport.describe_error/1`, and `remote_error/1` already carries the
what-to-call-next half of this item's goal. So the goal now holds on the four
batched read sites and not on the rest, which still render the bare
`describe_error/1` string — and on the regular-track `set_device_parameter`
read-back, whose own item shipped 2026-08-27 with a bespoke what-to-call-next
sentence rather than `remote_error/1`'s, so the surface is now three renderings
wide, not two. The inconsistency is arguably worse than the
uniform gap this item was written against. What is still missing everywhere,
including the batched paths, is the *which index* half: the reply says to check
`get_session_state` but never names 99. Both are in the `/live/error` payload
already (`address`, `arg_count`, the args), so this is still only rendering.

**Why:** found running the never-run agent smoke tests on 2026-08-03
([smoke_tests/auto/devices.md](smoke_tests/auto/devices.md) § Device error paths are
errors, not stalls). The guidance was never deleted — it was stranded. The
helpful wording ("Check both indices with `get_track_devices` first") lives on
`do_call`'s `catch :exit` timeout branch
([handlers.ex:2886](../lib/seshat/tools/handlers.ex#L2886) and siblings), and
the `/live/error` correlation shipped the same day made that branch unreachable
for a bad index: Live's rejection now arrives in ~0.19s and renders through
`Transport.describe_error/1`, which knows only the message Python sent. The
fast-fail is the right behaviour and is not in question; the regression is that
the model went from a slow, actionable message to a fast, generic one, on
exactly the path a model is most likely to hit by guessing an index.

**User stories:**
- As a producer, when I name a track that isn't there, Seshat re-checks and
  corrects itself in the same breath instead of telling me Ableton rejected
  something and stopping.

**Planner notes:**
- The information is present at the rejection site — `/live/error`'s structured
  payload carries `address`, `arg_count` and the request args (see
  `Seshat.OSC.Transport`'s "Failed-query correlation"), so the offending index is
  in hand; only the rendering drops it.
- Decide where the hint belongs. `describe_error/1` is deliberately the one
  place a caller renders the message, but it is tool-agnostic — a per-tool hint
  probably wants to travel with the `{:error, reason}` the handler clause
  already matches, not be pattern-matched onto message strings inside Transport.
- Audit the other `catch :exit` hints for the same stranding while in there;
  this is unlikely to be the only one the fast-fail bypassed.
- Settle the rendering *once* while here. There are three shapes in the tree
  now — `describe_error/1` bare, `remote_error/1`'s "check get_session_state",
  and `set_device_parameter`'s regular-track sentence — and the last was added
  knowing this item would unify them, not to pre-empt it.
- Small effort. The pure layer can cover it: `transport_test.exs` already
  constructs `/live/error` payloads, so the rendering is testable without Live.

## #13 · Browser preview audition

**Impact 7 · Lift 3 · 2.33 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** play a preset's browser preview instead of loading it, so the agent
can flip through ten candidates in the time one heavy preset takes to
instantiate.

**Why:** lever №6 — the lighter cousin of the shipped audition loop
(`delete_device`/`bypass_device`). Metadata will never distinguish two `Soft`
pads as well as ten seconds of audio. Gated on the eval above rather than
sequenced after it: better search may make this unnecessary, and the eval is
what decides.

**User stories:**
- As a producer torn between two `Soft` pads the tags can't tell apart, we
  flip through their browser previews and pick by ear — ten candidates
  auditioned in the time one heavy preset takes to load.

**Planner notes:** the fork already ships `/live/browser/preview_item` and
`/live/browser/stop_preview`; what remains here is the Elixir tool. The
preview plays through Live's cue channel — the tool description must
surface that audibility depends on cue routing.

## #14 · `start_new_project` — the setup wizard, and prompt budget back

**Impact 6 · Lift 3 · 2.00 impact-per-effort**

**Goal:** a tool that catches "let's start a new project" / "start fresh" and
runs the opening of a session: report what's in the open set, name any empty
leftover track, and gather the one-line brief (genre, tempo, mood, reference)
its reply asks for. It **reads and guides; it does not mutate** — the actual
work stays with `create_track` / `delete_track`, with the model in the loop.

**Why:** two wins at once. It fixes finding #1 of the 2026-07-28 validation
run ("start a new project" only appended tracks, leaving the default set's
leftovers behind), and it moves that rule off the *instructions* budget,
which is hard-capped — see below. A tool description routes a user utterance
far more reliably than a bullet in a block that gets truncated from the
bottom, and a reply can name the empty track it actually found instead of
asserting a cleanup unconditionally and hoping the model checks.

**User stories:**
- As a producer saying "let's start something fresh," I get a quick read of
  what's in the open set and one question — genre, tempo, mood, reference —
  so the session starts from my idea, not from leftovers.
- As a producer, the default set's empty leftover track gets noticed and put
  to use, instead of new tracks silently piling up beside it.

**Planner notes:**
- **The 2,048-character ceiling is the point.** Claude Desktop truncates
  server `instructions` mid-sentence at 2,048 characters and says nothing
  (measured 2026-07-29; see the comment above `@text` in
  [lib/seshat/instructions.ex](../lib/seshat/instructions.ex)). Tool schemas
  have no such cap — ~36KB ships every request. So moving a rule from the
  instructions into a tool description or reply costs nothing in total
  context and buys room on the one budget that silently drops content.
- **The "New project" bullet is already gone from `Seshat.Instructions`**
  (removed 2026-07-29, ~230 characters back). Nothing states replace-not-append
  until this ships — the model will append tracks, as it did before that rule
  was written. That gap is deliberate: the rule was bought back as budget on
  the assumption this tool follows.
- **No file operations, ever.** Opening or saving a set is a human step —
  Live's save dialog swallows keystrokes and no code should discard a user's
  work. That is settled; see
  [archive/create-project-removal.md](archive/create-project-removal.md).
- **Read-only is what keeps it from repeating history.** Every failure of the
  removed `create_project` came from fire-and-forget mutation through Live's
  post-load settling window. A tool that only reads `Session.State` and
  returns guidance cannot reproduce any of it.
- The default set is now a single blank MIDI track, so "leftovers" is at most
  one track — the reply should say what it found, not describe a mess.
- Trigger phrasing carries the whole routing job now, so the description has
  to cover the ways the intent is actually spoken. Standard `/add-tool`
  discipline, load-bearing here.
- **Nothing is broken while this is missing.** The cost is one awkward
  session opening the model can be steered through by hand — that is what
  holds its impact score to 6 rather than higher. It earns its rank on being
  small and on freeing instructions budget that "Producer personas" will
  want, so prefer building it before that item even though ratio separates
  them.

## #15 · `write_midi_notes` must chunk large note batches

**Impact 6 · Lift 3 · 2.00 impact-per-effort**

**Goal:** dense and long MIDI clips are written in bounded OSC messages instead
of one unbounded UDP datagram.

**Why:** `Seshat.Commands.Registry.add_notes/3` currently flattens every note
into one `/live/clip/add/notes` message, while the public schema places no
maximum on the notes array. This machine's `net.inet.udp.maxdgram` is 9,216
bytes, so a sufficiently dense request can exceed the transport ceiling even
though it passed validation. This is an existing `write_midi_notes` defect,
not work that should remain buried inside the prospective music-generation
plan; generated 8–16 bar drums merely make it easier to hit. The generation
work in [docs/evaluating/generative features/midi-generation-options.md](evaluating/generative%20features/midi-generation-options.md)
depends on this fix for dense or long clips. "MIDI generation — the
first solution, composed symbolically" has since shipped (`generate_midi`)
without waiting on this item — its own measurement found per-lane writes
stay under the ceiling — so this was never a gate for it, only a defect a
dense request can still hit. Land it when the first dense clip does.

**User stories:**
- As a producer writing a dense or long MIDI clip, all requested notes land in
  Live instead of the whole write disappearing because its UDP packet was too
  large.

**Planner notes:**
- Keep clip creation and all note chunks inside the existing single
  `write_midi_notes` command and undo step. Repeated
  `/live/clip/add/notes` calls append, so create once and batch only the add.
- Derive a conservative chunk size from encoded OSC payload size, not an
  undocumented note-count guess. Each wire note adds pitch, start, duration,
  velocity, and mute arguments; track and slot are message-level arguments.
- Add pure tests at, below, and above the chosen boundary, including a long
  dense clip and preservation of note order. The OS limit is the failure
  mechanism, but the test should not send to Live or depend on this Mac's
  current sysctl value.
- Do not “fix” this only with schema `maxItems`: the public 1–16 bar feature
  surface needs valid dense clips to work, not become validation errors.

## #16 · `set_clip_properties` reads the loop pair before the `looping` toggle lands

**Impact 4 · Lift 2 · 2.00 impact-per-effort**

**Goal:** setting `looping` *and* the loop points in one call produces the
intended brace on a clip whose stored loop points differ from its play markers.

**Why:** recorded as a known wart by the 07/2026 review of the clip property
tools, and carried since then as a caveat inside the smoke-test checklist —
which is the wrong home for a defect, since a checklist item that says "if it
misbehaves, the fix is…" is a bug report nobody triaged. With looping off,
Live aliases the loop points onto the play markers. `set_clip_properties`
reads that pair *before* the `looping` toggle goes out, so on such a clip both
the write ordering and the single-sided validation can run against stale
values, and the resulting brace is not the one asked for.

**Planner notes:**
- The fix is stated in the original review: send `looping` first, then read the
  pair context, then order the loop-point writes. Confirm the read really is
  ordered before the toggle in `Seshat.Tools.Handlers` before assuming it.
- Ordering logic is pure-testable — the existing write-ordering tests in
  `handlers_test.exs` are the place. What is not pure-testable is whether Live
  aliases as described; that is a measurement, and it belongs in
  [../priv/AbletonOSC/API.md](../priv/AbletonOSC/API.md) once made.
- The live check already exists as
  `smoke_tests/auto/clips.md § The loop pair with looping off`, where a failure is
  currently the *expected* result. Cite it from the plan, and when this ships,
  rewrite that test so a failure means a regression again.

## #17 · Routing evals — general corpus and client-realism lane

**Impact 5 · Lift 3 · 1.67 impact-per-effort**

**Goal:** widen the routing-eval corpus past the two decision-experiment
cases to the ~20-case general corpus (paraphrases, cue/return/master
coverage) the first slice deferred, and decide whether to add a
client-realism lane (Claude Code's default system prompt) plus a direct-API
model adapter. The harness itself — `mix routing.eval`, `Seshat.Eval.*`,
committed base/head surface snapshots — already exists; this item is corpus
and lane work on top of it, not new plumbing.

**Why:** the first slice's decision run (`mix routing.eval`, 2026-08-28, 40
trials, zero void) found both the pre- and post-consolidation tool surfaces
routed *correctly* in every trial on both seed cases — full detail in
CLAUDE.md's Current focus and the archived
[PLAN_routing_evals.md](archive/PLAN_routing_evals.md). That result is honest
but narrow: both seed cases are exactly the ones consolidation was designed
for, and five trials per cell cannot separate 100% from 95%. The general
corpus — paraphrased requests, cue/return/master targets the seed cases
never touch — is where the same-verb-different-target base surface would be
expected to struggle if it struggles anywhere; only running it turns "we
didn't observe a difference" into "there isn't one, on this evidence."

**Planner notes:**
- The archived plan's `Out of scope` section is the authoritative list of
  what this covers: the general corpus, the client-realism lane, and a
  direct-API model adapter (options doc B in
  [automated-conversation-routing-evals.md](evaluating/automated-conversation-routing-evals.md)).
  A prose/LLM judge for "replies speak music" was declined outright, not
  deferred — the manual conversation-check residue stays as the check for
  that; don't rebuild it here.
- Reuse `Seshat.Eval.Case`'s JSON shape and `Seshat.Eval.Judge`'s predicate
  vocabulary; new cases are data, not code, per the harness's own design goal.
- Two open nits from the first slice's review bear on any new cases: "Routing
  eval report should self-identify which case expectations it scored
  against" and "Routing eval: an exploratory read on a fixture with no data
  for it should not fail `no_tool_errors`" — the second is likely to
  actually bite once cue/return/master reads widen the discovery surface,
  unlike in the two-case corpus where it never fired.
- `mix routing.eval` is on-demand only, never in `mix precommit` — keep it
  that way; it is externally metered and stochastic.
- "MIDI generation — the first solution, composed symbolically" ran
  `mix routing.eval` on 2026-08-30 (`priv/routing_eval/runs/2026-08-30T190814Z/`)
  expecting it to probe the new `generate_midi`/`generate_audio` near-neighbour
  boundary and the MIDI-default flip; both cells came back inconclusive
  (fewer than 2 valid trials) and the committed corpus (mixer, note-edit) never
  actually exercises that boundary anyway. Add a case that asks for musical
  material with no form named, to pin the MIDI-default routing decision, and a
  paraphrase case that could plausibly go to either tool, when this item's
  corpus work is picked up.

## #18 · `screenshot_live` — let Seshat see the screen

**Impact 6 · Lift 4 · 1.50 impact-per-effort**

**Goal:** capture Live's window (macOS `screencapture` targeted by window
ID) and return the image in the MCP tool result, so the client model —
already vision-capable — can look at the actual UI when the user asks about
it.

**Why:** 2026-07-28 validation run: "why can't I see the notes?" — OSC is
blind to presentation. The mirror knows session *state*, never what's on
screen (focused view, open dialogs, browser panes), so UI questions today
get guesses. Trigger is user UI questions, not routine post-action use —
the follow cam (shipped 2026-07-29) covers that.

**User stories:**
- As a producer asking "why can't I see the notes?", Seshat looks at my
  actual screen and answers — instead of guessing from mirrored state that
  can't see a dialog, a collapsed pane, or where focus went.

**Planner notes:**
- Verify Anubis supports image content in tool results (the MCP spec does).
- Downscale before returning — full-res screenshots are token-expensive.
- One-time macOS Screen Recording permission for the BEAM process; capture
  works occluded but not minimized.

## #19 · Opt-in `samples` index

**Impact 6 · Lift 4 · 1.50 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** index the `samples` category (3,567 items) into the catalog,
returned **only** when `category: samples` is explicitly requested.

**Why:** lever №7, the only category still invisible — "a vinyl crackle" is
unfindable while `Crackle Vinyl Pop.wav` sits in the browser. Sample uris
carry FileIds, so tag-awareness comes free.

**User stories:**
- As a producer asking for "a vinyl crackle," the sample that's sitting
  right there in Live's browser is actually findable — today no search can
  reach it.

**Planner notes:** samples is why `EXPORT_CATEGORIES` excludes it and the
20k-node scan cap exists — measure the walk cost first. Keeping samples out
of default results is a hard requirement so the preset slate stays clean.

## #20 · Accepted-search memory

**Impact 6 · Lift 5 · 1.20 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** remember what a description resolved to — "this request led to this
accepted preset" — and let it bias future rankings.

**Why:** lever №8. `use_count`/recency already bias rankings, but the
description→preset association is thrown away today. Compounds over time; a
personal tool can afford a personal memory.

**User stories:**
- As a producer who settled on a particular preset for "dusty keys" last
  week, the same request surfaces it first this week — my accepted picks
  teach the search what my words mean.

**Planner notes:** this is the one catalog feature that wants a write-side
store. Keep it out of the read-only catalog file — a separate small file
under `~/.seshat/` — and it is still not a database (see CLAUDE.md).

## #21 · Producer personas — switchable musical taste

**Impact 7 · Lift 6 · 1.17 impact-per-effort**

**Goal:** layer a *persona* onto the base session instructions. 
Personas live one per file in [priv/producers/](../priv/producers/)
(five placeholder stubs exist; `mona_dust.md` is the default); a `load_producer` tool (plus
`list_producers`) loads one into the conversation mid-session:
"load me Volt Kessler" changes the session's whole aesthetic.

**Why:** The feel of colloborating with different styles of producer is valuable to the user.
Also different songs might benefit from a different producer. Personas should carry aesthetic taste: sonic palette, genre instincts. Maybe other fun details like stylistic language differences in the responses.

**User stories:**
- As a producer, "load me Volt Kessler" changes what every following pick
  reaches for — a different palette, same tools, no re-explaining a whole
  aesthetic in every prompt.
- As a producer with a direction of my own, my stated taste still leads; the
  persona only fills in where I haven't said anything yet.

**Planner notes:**
- the base text([lib/seshat/instructions.ex](../lib/seshat/instructions.ex) 
  is delivered via the instrucions.  We could put the persona here but there are 2 VERY BAD limitations. 
  Its only loaded at the start of the session, which precedes the first user command, so a user has no way to select the producer being loaded. 
  Also there is a strict 2048 character limit on this field, and the base text needs to use most of it, not much room for the producer persona. 
- Because of these limitations, the planner should explore out of the box creative solutions to loading a producer. 
  Even resorting to asking a user to manual input a file or text somewhere in the desktop client. 
  Consider all possible avenues and angles for getting the mcp consumer to respond with a desired persona. 
  so we are unfortunately quite limited with the space that can be given to a persona if using this delivery method. 
- **The taste hierarchy:  the user's communicated taste
  always leads; the persona is the *default* — the prior that fills in when
  the user hasn't said yet.** 
- The stubbed out personas are placeholders and need to be edited manually,
  continuous iteration is expected as we can only guess and check while using.

## #22 · Verify destructive mutations before reporting success

**Impact 8 · Lift 7 · 1.14 impact-per-effort**

**Goal:** destructive and structural operations check their target before
mutating and confirm the result afterward, instead of returning success as soon
as `:gen_udp.send/4` returns.

**Why:** a rejected delete and a dropped packet are indistinguishable from a
successful one, because nothing waits on a setter — and the follow cam then
steers to a destination that may not exist. The reachable trigger is a stale
model-held index. (The original framing, "Python catches Live API exceptions
and only logs them," is half obsolete: the fork now sends a correlated error
for a rejected setter. Seshat still discards it — see the third planner note
below — so the symptom is unchanged, but the fix has a cheaper option than it
did.)

**User stories:**
- As a producer, when a delete never actually happened in Live, Seshat says
  so — instead of confirming success and steering my view toward a track
  that doesn't exist.

**Planner notes:**
- **Keep ordinary parameter setters fire-and-forget.** The review's headline
  recommendation — structured acknowledgements from every mutation endpoint —
  is rejected: it reverses the settled rule in
  [.claude/rules/osc.md](../.claude/rules/osc.md) ("Setters stay silent — each
  is guarded by its getter first, and nothing waits on one"), and adds a
  round-trip to every mutation, adding load to the query queue that now
  serializes every OSC request.
- The pattern already exists: `delete_device` bounds-checks then verifies by
  re-count, `set_clip_properties` verifies each write by re-read. Extend that to
  the remaining destructive operations and stop.
- Ranked here rather than higher because the surface is broad — this is the
  slog of the correctness items.
- From the 2026-07-29 external review; the verify-before-mutate half accepted,
  structured setter acknowledgements rejected above.
- **Fold in the `remove_notes` footgun fix** (2026-07-31 external tool
  audit): with no range given it silently deletes every note in the clip. Require an explicit range or `all: true`
  before a full wipe — the same principle (destructive intent must be
  explicit), a few lines in `Definitions` + `Handlers`, and small enough to
  ride along here (or as a drive-by before this item is picked up) rather
  than rank on its own.
- **A third option exists now, cheaper than a read-back: the correlated
  setter failure.** The fork's dispatch-boundary rework stopped
  `_call_method`/`_set_property` swallowing exceptions, so a rejected setter
  or generic method now sends `/live/error ["request", <its own address>,
  message, argc, *args]` — the same envelope a failing *query* gets, naming
  the request and its arguments. Today Seshat throws that away:
  `Transport.send_message/2` has already returned `:ok`, and the error is
  broadcast on `"osc:in"` and answers nobody. The lever is a short grace
  window after a silent setter — hold the tool step open for roughly one
  AbletonOSC tick (~100ms, and 212ms was the measured client-call-to-result
  figure for a rejection) and report the rejection if one arrives, rather
  than paying a full read-back round trip. That is not the round-trip-per-
  mutation design rejected above: nothing is *queried*, the wait is bounded
  by a tick rather than by `@query_timeout`, and a clean setter costs
  nothing extra. Weigh it against the read-back on a per-setter basis —
  read-back proves the value landed, the envelope only proves it wasn't
  refused — and note it needs a Transport-side subscription to unmatched
  `"request"` errors, which does not exist yet. Requires the fork's
  `_dispatch` commit installed; verify with `mix abletonosc.install` first.
- **Two more Tier-A setters named by the 2026-08-03 integration review**
  ([abletonosc-integration-review.md](evaluating/abletonosc-integration-review.md),
  §4 item 6): `set_track_arm` returns "Armed track N" unverified while
  `record_clip`'s internal `arm_track/1` exists precisely because Live can
  refuse to arm, and `set_time_signature` fires two independent messages and
  can report a plain error with the signature half-applied. Both belong to
  this item's surface. (`set_track_send` from the same review shipped
  separately, with a read-back rather than a wording hedge — see
  [CLAUDE.md](../CLAUDE.md)'s Current focus.)

## #23 · User XMP tags

**Impact 3 · Lift 3 · 1.00 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** read the user's own tags from
`User Library/Ableton Folder Info/12/`.

**Why:** user-authored tags are the highest-precision signal a personal
library can have; currently ignored. Small, but only matters once the user
actually tags things — hence the low rank.

**User stories:**
- As a producer who has tagged parts of my own library, those tags count in
  search — they're the most precise signal about my sounds that exists.

## #24 · Small OSC breadth — grab bag

**Impact 3 · Lift 3 · 1.00 impact-per-effort**

Individually tiny, none blocking a workflow; pick up opportunistically:

- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low
  value for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groups · output routing · automation** — grouping tracks, output routing,
  automation envelopes. (*Input* routing and monitoring shipped on
  `set_mixer` 2026-08-30, so only output-side routing remains here.)
- **Sends on return tracks** (return→return routing, feedback sends) —
  niche, needs Live's "sends only" awareness, no named workflow yet.

## #25 · Pin the wording of `edit_notes`' partial-failure message

**Impact 2 · Lift 2 · 1.00 impact-per-effort**

**Goal:** get test coverage on the message `add_edited_notes/3`
(`lib/seshat/tools/handlers.ex`) returns when the remove half of an
`edit_notes` call succeeds but the add half fails — "The matched notes were
removed but the edited replacements could not be sent … Call undo
immediately to put them back." Nothing in the suite pins its wording today.
"MIDI generation — the first solution, composed symbolically" (2026-08-30)
hit the identical gap on its own honesty path — `write_failure/3` and
`created_so_far/1` in `lib/seshat/generation/midi_parts.ex` render "tracks
created before this failure are still there and empty … one undo removes
the whole request" on a partial write failure, and nothing exercises either
branch either. Whatever mocking strategy this item settles on should cover
both modules' bare error-message helpers in one pass, not just `Handlers`'.

**Why:** flagged in the 2026-08-28 review of "Consolidate the tool surface"
as the single most consequential error path in the note-editing feature —
notes already gone, replacements never sent, and the only way back is an
immediate `undo` — with no test protecting the sentence a model would act on
in that moment. It was left as a non-blocking nit rather than fixed inline
because the failure can't be provoked through the existing harness:
`Transport.send_message/2` goes out over loopback UDP via `:gen_udp.send/4`,
which does not return `{:error, _}` in practice, so `Seshat.Test.OSCSink`
has nothing to hook to drive this branch through the full call path — the
same constraint that leaves every other bare error-message helper in
`Handlers` (`extension_missing_error/2`, `mixer_partial_error/5`,
`stale_reply_error/2`, and siblings) untested directly today, by consistent
convention across the module.

**Planner notes:**
- Fixing this for real means solving it for the whole family, not just this
  one message — either give `Transport.send_message/2` a way to be
  injected with a failure in tests (a behaviour/mock swap, or a test-only
  send path), or accept breaking the module's current privacy convention by
  exporting one pure formatting function and decide whether that's worth
  the inconsistency it introduces.
- Low lift once the mocking question is settled — the message itself is
  already correct and doesn't need to change, only get pinned.

## #26 · `edit_notes`' description states a reason that is no longer true

**Impact 3 · Lift 1 · 3.00 impact-per-effort**

**Goal:** correct one clause in model-facing text.
`lib/seshat/tools/definitions.ex` tells the model that probability, velocity
deviation and release velocity "are reset to defaults on edited notes (the
wire cannot carry them)". Since 2026-08-29 the wire carries all three, and
PR #84 measured Live 12.4.5 persisting `probability` and `velocity_deviation`
exactly as sent. The *behaviour* is still accurate — `edit_notes` composes a
remove and a re-add through the five-field addresses, so the expression fields
really are lost — but the stated reason is wrong, and it is wrong in the one
place a model reads before deciding whether an edit is safe.

**Why:** a false capability claim in a tool description is worse than a
missing one: it teaches the model that Seshat *cannot* carry expression, so a
future feature that depends on carrying it (harmony inheriting a melody's
feel — see
[docs/evaluating/generative features/harmony-from-a-melody-options.md](evaluating/generative%20features/harmony-from-a-melody-options.md)
§8) reads as impossible from the surface alone. Surfaced by the 2026-08-30
harmony research and confirmed still present 2026-08-31.

**Planner notes:**
- The honest replacement names the real reason: `edit_notes` uses the
  five-field remove/add path, while `/live/clip/apply_note_modifications`
  could edit in place without disturbing the expression fields. Whether to
  *fix* that (move `edit_notes` onto note ids) is a separate, larger item —
  this one is only the sentence.
- It is a `Definitions` change, so `mix routing.eval` applies.

## #27 · Routing eval report should self-identify which case expectations it scored against

**Impact 2 · Lift 2 · 1.00 impact-per-effort**

**Goal:** `Seshat.Eval.Report`'s header pins the CLI version, the lane-prompt
hash and each surface's contract digest, but nothing about the case
expectations a run was scored against. Add a digest of each case's `expect`
block (per surface, since head and base can be held to different bars) to
the header or per-case section, so `report.md` is self-contained.

**Why:** flagged in the review of "Automate conversation-routing evaluations"
(`docs/archive/PLAN_routing_evals.md`). The decision run deliberately scores
`note_third_quieter` against different bars per surface — head gets
`max_mutations: 1` plus `must_not_call: ["write_midi_notes"]`, base gets
`max_mutations: 2` with nothing forbidden — and a reader of `report.md` alone
sees "semantic success 100% / 100%" with no signal the two columns measured
different criteria. The plan says so in prose, but `/ship` archives the plan;
`priv/routing_eval/runs/` is gitignored, so the report is the only thing that
travels with a PR. Left as a non-blocking nit rather than fixed inline
because it is a small feature addition (new digest plumbed from the case
loader through the run map `mix routing.eval` assembles, through
`Seshat.Eval.Report`, with new test coverage), not a one-line correction.

**Planner notes:**
- The digest should probably be sha256 of the case's `expect` map for the
  surface actually used, following the pattern `Seshat.Eval.Surface` already
  uses for the contract digest.
- Consider whether the per-case Markdown section should also spell out the
  gate differences in prose (`max_mutations`, `must_not_call`) rather than
  only a hash, since a hash alone still sends a PR reader back to the case
  JSON to see what changed.

## #28 · Routing eval: an exploratory read on a fixture with no data for it should not fail `no_tool_errors`

**Impact 3 · Lift 3 · 1.00 impact-per-effort**

**Goal:** `Seshat.Eval.Fixture`'s "a read the fixture has no data for answers
`isError: true`" behavior currently makes any such read count as a tool
error, and both seed cases set `no_tool_errors: true` in their expectation —
so a model that probes `get_clip_properties`, `get_track_devices`, or
`get_clip_notes` on the wrong track before finding the right one fails
`semantic_success` even when everything it does afterward is correct.
Give the judge a way to tell "the model invented state" apart from
"the model looked in the wrong place and recovered," or exclude exploratory
reads from `no_tool_errors` specifically.

**Why:** flagged in the review of "Automate conversation-routing evaluations"
(`docs/archive/PLAN_routing_evals.md`). It did not bite in the decision run — zero
tool errors across all 40 trials on both seed cases — but the plan's own
Out-of-scope section defers "the general corpus (paraphrases, cue/return/master
coverage, ~20 cases)" to a second slice, and that is exactly the corpus that
would widen the discovery surface and start exploratory reads landing. Left
as a non-blocking nit rather than fixed inline because the second slice
doesn't exist yet — there is no case in this repo the change would currently
affect, and picking the right judge semantics (a new verdict field? a
"forgivable error" allowlist keyed by tool?) is a design call better made
against real second-slice cases than speculatively.

**Planner notes:**
- Revisit this before or alongside building the second-slice corpus
  (`docs/archive/PLAN_routing_evals.md`'s "Out of scope" section), not before.
- The plan's own justification for the `isError: true` reply itself still
  holds ("the model must not proceed on invented state") — this item is only
  about whether that reply should count against `no_tool_errors`.

## #29 · Tighten the process-start grep so it does not shape prose in unrelated modules

**Impact 1 · Lift 1 · 1.00 impact-per-effort**

**Goal:** `test/seshat/ax/client_test.exs`'s grep for `Port.open`,
`:spawn_executable`, `System.cmd`, `System.shell`, `:os.cmd` and
`:erlang.open_port` (the invariant that nothing under `lib/` outside
`Seshat.AX.Client` and `lib/mix/tasks/` starts a process) matches inside
comments and `@moduledoc` bodies, not just executable code. Narrow it to
skip comment lines and doc attributes.

**Why:** flagged in the review of "Automate conversation-routing evaluations"
(`docs/archive/PLAN_routing_evals.md`). `Seshat.Eval.Client`'s moduledoc has to avoid
writing the literal string `Port.open` even in prose, so the grep does not
false-positive on a docstring — the invariant itself is intact, but a test
tripwire is now shaping documentation in an unrelated module. Left as a
non-blocking nit rather than fixed inline because it touches a shared
invariant test outside the routing-evals change's own files, not something
that plan's implementation owns.

## #30 · LLM enrichment at reindex

**Impact 7 · Lift 9 · 0.78 impact-per-effort**

**Gated on "Search eval harness — numbers before opinions"**, which ranks
above it for that reason — buy this only if the eval still shows the miss it
targets once "Catalog vocabulary" has landed.

**Goal:** generate tags/descriptions for untagged and third-party items at
reindex time, using an external model service or an MCP-client-driven tagging
turn.

**Why:** lever №5 — highest ceiling (it attacks the thin-signal problem
directly: ~200 of 5,795 entries say anything real about their sound) and
highest cost. Last resort of the catalog levers: buy only if the search eval
still shows first-slate misses on thin-tagged entries after every other lever
has landed. Concrete evidence from
the 2026-07-28 validation run: for "warm, slightly out-of-tune electric
piano," the character lived only in preset *names* — E-Piano Rusty, Old
School, MKII Old, Cheap were invisible to tag scoring because no warm/aged/
detuned vocabulary exists to carry them.

**User stories:**
- As a producer asking for "a warm, slightly out-of-tune electric piano,"
  the presets whose character lives only in their names — E-Piano Rusty,
  MKII Old — finally rank on their sound instead of their tag luck.

## #31 · Monitored refresh worker for `Session.State`

**Impact 3 · Lift 6 · 0.50 impact-per-effort**

**Goal:** move the mirror rebuild off the GenServer's synchronous path and give
it an overall deadline plus freshness / connection / last-error metadata, so a
slow or unreachable Ableton cannot block every mirror read behind it.

**Why:** this lived in "Deliberately not planned" — the larger half of the
2026-07-29 review's session-refresh finding, deferred rather than declined, with
one stated reopen condition: *"the blocking window is short and has never been
observed. Reconsider if the blocking window is ever actually seen."* **It was
observed on 2026-08-02.** An ordinary undo burst raced a rebuild, and one
rejected index blocked `do_refresh/1` inside the GenServer for a full five
seconds — see "Correlate `/live/error` so a failed query fails fast" for the
measurement. The condition has fired, so this belongs in the queue rather than
in the declined list.

**The gating fix has now shipped.** "Correlate `/live/error` so a failed query
fails fast" cut that same window from ~5,000ms to roughly one AbletonOSC tick
(≤100ms) without restructuring anything, which may have removed this item's
entire motivation. Buy it only if blocking is still observed after
re-measuring against the shipped fix — the same discipline the catalog levers
get from "Search eval harness". Ranked here for that reason: conditional, and
the shipped fix may retire it outright.

**Planner notes:**
- Only the fabricated-defaults half of the original finding shipped (2026-07-30);
  refresh still runs sequential synchronous OSC calls inside the GenServer.
- The OSC query queue changed the contention picture after that review was
  written — re-establish the real blocking behaviour by measurement before
  designing against the review's description of it.
- `@refresh_sync_timeout` already bounds what the *caller* waits, not what the
  refresh costs. That asymmetry is what this item is actually about.
- **If this is ever picked up, reach for `Seshat.OSC.Transport.query_batch/2`
  first**, not a new fork bulk-snapshot endpoint. "Batch the N+1 reads into
  one AbletonOSC tick" (shipped 2026-08-04, archived at
  [archive/PLAN_batched_queries.md](archive/PLAN_batched_queries.md))
  measured the mirror rebuild's own ~73-query cost as the same disease this
  item targets, at ~4.6s; a batched rebuild would cost roughly 3 ticks
  instead, which may shrink the blocking window enough on its own to retire
  this item without a worker. Re-measure against a batched rebuild before
  designing the worker.

## #32 · Device list per track in session state

**Impact 2 · Lift 5 · 0.40 impact-per-effort**

**Goal:** mirror each track's device chain in `Seshat.Session.State`, so the
agent sees loaded devices without a `get_track_devices` round-trip.

**Why:** device-chain reads are frequent (every load/delete/bypass verifies
by re-read), and the session-state mirror is push-fresh for everything else.
Quality-of-life multiplier for the now-complete device workflow — but the
gain is latency and tokens, not user-visible experience, hence the rank.

**Planner notes:** needs device add/remove listeners per track — check what
upstream offers before assuming a new handler is required. The clip-grid
precedent applies (see the "Clip grid in session state" note): query-on-demand
shipped first, promotion to
push state only once usage justified the subscription surface. Usage now
plausibly does; confirm before building. These listeners are index-keyed —
the fork already fixes the wrong-object unbind in the handler base class, so
any listener work here is an ordinary fork commit, no override gymnastics.

## #33 · Adopt MCP `2026-07-28` when Anubis supports it

**Impact 2 · Lift 5 · 0.40 impact-per-effort**

**Goal:** serve MCP's stateless `2026-07-28` protocol over both Streamable HTTP
and stdio while retaining legacy compatibility for as long as clients need it.

**Why:** `2026-07-28` removes the `initialize` / `notifications/initialized`
handshake and `Mcp-Session-Id`, moves version and client capabilities into
per-request `_meta`, adds mandatory `server/discover`, requires
`Mcp-Method` / `Mcp-Name` HTTP headers and `resultType` on results, and makes
list responses cacheable. Claude support began rolling out on 2026-07-28.
Seshat is currently pinned to `anubis_mcp` 1.10.0, whose newest supported
protocol is `2025-11-25`; current dual-era clients can fall back to that legacy
flow, so this is not an active break.

**Planner notes:**
- Wait for an Anubis release with native `2026-07-28` support; do not implement
  the wire protocol inside Seshat. The existing `~> 1.10` constraint may admit
  a later 1.x release, leaving only a lock update plus any new transport option.
- Prefer dual-era operation initially. A modern-only client cannot use the
  current server, while a dual-era client probes `server/discover` and falls
  back to legacy initialization.
- Seshat's application state already lives outside MCP transport sessions:
  tools delegate to `Seshat.Tools.Handlers` and do not use the per-client Anubis
  frame. No tool or OSC redesign should be needed.
- Verify that `Seshat.MCP.Server.server_instructions/0` reaches the
  `server/discover` result. The new protocol retains `instructions`, but today
  Anubis emits them from the legacy initialize response and this guidance is
  load-bearing.
- The SDK should own per-request `_meta`, standard HTTP headers, `resultType`,
  cache fields, version errors and discovery dispatch. Seshat's static tool
  list is already deterministic and does not vary by connection.
- Keep the current GET/SSE path while supporting legacy clients; modern
  `2026-07-28` replaces the standalone GET stream with
  `subscriptions/listen`. Revisit the router comments and
  `Seshat.MCP.LogFilter` after the Anubis upgrade.
- Authorization changes do not apply while Seshat remains unauthenticated and
  loopback-only. Tasks, roots, sampling, elicitation and MCP logging are not
  used here.
- Add wire-level tests for `server/discover`, a direct stateless `tools/list`
  and `tools/call`, required response fields, HTTP headers, instructions, and
  legacy fallback. Existing MCP tests cover component parity and the
  instructions callback, not transport negotiation.
- Primary references:
  [release overview](https://blog.modelcontextprotocol.io/posts/2026-07-28/),
  [key changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
  [discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
  and
  [version compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).

## #34 · Clip grid in session state — only if usage demands it

**Impact 2 · Lift 6 · 0.33 impact-per-effort**

**Goal:** promote the clip grid from on-demand (`get_clip_slots`, shipped)
into push-fresh `Session.State`.

**Why (conditional):** clip-slot listeners are a large subscription surface
(tracks × scenes × properties). The standing decision
([archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) is to
wait for evidence the grid is read constantly. Session record has now shipped
alongside `capture_midi`, so the trigger this item was waiting on has
happened — worth checking whether grid-read frequency actually justifies the
subscription surface before building it. Index-keyed listeners, like the
device-chain mirror's — these are ordinary fork commits on the fixed base class.

---

## Deliberately not planned

- **Deployment-gated security work** — HTTP authentication on `/mcp`,
  production binding, rate limiting, and the multi-user design
  question. Not in this queue by design; see
  [SECURITY_BACKLOG.md](evaluating/SECURITY_BACKLOG.md) for the two triggers that activate
  them. Note that authentication alone does not make Seshat multi-user — one
  transport, one mirror, one Ableton.
- **A PubSub restart would leave `Session.State` permanently unsubscribed.**
  State subscribes only in `init/1`, and it is a `:one_for_one` sibling of
  `Phoenix.PubSub`, so a PubSub restart leaves it registered in a dead registry
  and deaf to OSC broadcasts. The mechanism is real. Declined 2026-07-30 because
  the offered fix is worse than the disease: `:rest_for_one` at
  [application.ex:39](../lib/seshat/application.ex#L39) would, given the current
  child order, restart Transport, Session.State, Catalog, the MCP supervisor
  **and the Phoenix endpoint** on any PubSub blip — a guaranteed heavy failure
  traded for a hypothetical one. `Phoenix.PubSub` crashing is close to unheard
  of. **Reconsider if it is ever actually observed**, and then take the targeted
  option: monitor PubSub and re-subscribe after replacement.
  `get_session_state`'s `refresh: true` is already a manual backstop for a
  mirror that has gone stale for any reason.
- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Device *reordering* (removal & bypass
  shipped — see `delete_device`/`bypass_device`), rack inner chains, parameter
  listeners (live meters/automation following) — revisit if a real workflow
  needs them.
- Embeddings or a semantic index for the catalog — the LLM is already the
  semantic layer and has the musical context.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](evaluating/bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
- **Machinery around the fork's two known soft spots** (recorded 2026-07-28
  with the fork itself): a pre-push guard for an unpushed `priv/AbletonOSC`
  commit behind a bumped pin (today it surfaces only as a confusing CI
  checkout failure), and a mechanical check that the fork's `SESHAT.md` stays
  current (a missing divergence entry is invisible until the next upstream
  merge). Both are covered by prose in `/implement` and `/pr-review`; neither
  is worth automating while upstream is dormant and there is one committer.
  Reopen if a merge actually goes wrong because of one.
- **Audio generation transcribed to MIDI as the primary MIDI strategy**
  (Stable Audio 3 → Stem Separation / Convert Drums / Inverse Drum Machine /
  Basic Pitch → notes). Rejected 2026-08-30, the day `generate_audio`
  shipped: the generator's text conditioning is semantic, not symbolic — no
  notion of "two beats" or "a half note", so a duration-exact file carries
  free-running rhythm inside it, and transcription stacks its own error on
  top of that. It may still earn a place for a specific case (melody and
  harmony have no symbolic candidate today; Convert Drums is a zero-licence
  lane), but it is not the first solution built. The research behind it —
  [midi-generation-options.md](evaluating/generative%20features/midi-generation-options.md)
  §C — stands as evidence, and the two plan docs written for the four-arm
  bake-off carry banners. **Reopen** only for a named case the symbolic path
  cannot serve, or if a generator arrives whose rhythm is grid-locked by
  construction (audio conditioning on a click is the nearest lever; measure
  it under "Generated-audio alignment, warping and quality polish" first).
- Anything related to Windows. It would be nice for this to work on a windows machine,
  but currently we are not focused on this.
