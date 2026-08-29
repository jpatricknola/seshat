# Plan — Generated-audio alignment, warping and quality polish (PR 2)

Roadmap item **“Generated-audio alignment, warping and quality polish.”** The
second half of the audio-generation story, split out from
[PLAN_generate_audio_clip.md](PLAN_generate_audio_clip.md) on 2026-08-29 and
deliberately sequenced **after** the roadmap's MIDI generation item.

The first PR gets a duration-exact render into the right slot on the right
track and reports what Live observed. This one decides how that clip *sits* —
where the first hit lands against the grid, whether the loop seam clicks,
whether warping and looping are set or merely observed, what happens when the
set tempo changes afterwards, and whether a second quality lane is worth its
contract surface.

**This plan is intentionally unfinished, and that is its design.** Every
question below is answered by measuring real material, and the material does
not exist until `generate_audio` ships and gets used. Writing prescriptive
implementation parts now would be guessing at DSP for failures nobody has
measured — the same trap the split exists to avoid. Part 0 is therefore a
measurement pass, and the implementation parts are written after it, against
its numbers.

## Preconditions

- **“Generate audio onto a track”** has shipped, including its Part 0 fork pin
  bump and `mix abletonosc.install`.
- The MVP's fixtures are retained: raw renders under `~/.seshat/generated/` and
  the clips they became in Live, across at least drums, bass and pad material,
  several tempos, and both 4/4 and one other signature.
- **The MIDI work landed first.** That is the sequencing decision, not a
  technical gate: a producer gets more from generated MIDI parts than from a
  better-aligned audio loop, so this waits.

## What the MVP leaves open

Carried forward verbatim from the first plan's *Out of scope*, because these
are exactly this PR's subject:

- Rhythmic phase and downbeat detection, over-generation and cropping.
- Silence/fade analysis, seam repair, crossfades and click removal.
- Setting warp mode, warping, looping and start/loop markers, and behaviour
  after a set-tempo change.
- A `best`/`medium` quality lane or model-choice parameter.

## Evidence already in hand

- The 2026-08-25 spike measured several drum renders beginning **174–488 ms**
  after the file boundary, and many fading near the file end. Exact duration is
  not the same as a musical loop.
- The `sm-music`/`same-s` lane runs 1.0–1.1 s for four bars after warm-up;
  `medium` runs 2.6–3.8 s. Whether that 3× latency buys anything audible is
  **unmeasured** — it is a listening question, not a benchmark question.
- Live's own looping and warping defaults on an imported file are **observed,
  never set**, by the MVP. What they actually are, and whether they vary with
  content or with the user's preferences, is what Part 0 finds out.

## Part 0 — Measure before designing

No production code. Produce a written measurement note (in
`docs/evaluating/generative features/`) covering:

1. **Grid phase.** For each retained fixture, the offset of the first
   transient from the file boundary, and where the imported clip's first hit
   lands against Live's metronome at the set tempo.
2. **Live's import defaults.** `looping`, `warping`, warp mode, start/end and
   loop markers as read back immediately after import, across fixture types and
   across at least two Live preference states.
3. **Tempo following.** What the imported clip does when the set tempo changes,
   under each observed warp state.
4. **Seams.** Whether looping the clip clicks, and whether the click is the
   file's fade, the phase offset, or the warp state.
5. **Quality lanes.** A blind by-ear comparison of `sm-music` against `medium`
   on the same prompts and seeds.

The note ends with a ranked list of the failures actually observed. Anything
not on that list is out of scope for the implementation parts.

## Parts 1..n — written after Part 0

Sketch only, to be replaced by numbered parts once the measurements rank the
work. The candidate levers, in the order they would probably be reached for:

- **Set what Live leaves to chance.** If the defaults are inconsistent, the fix
  may be as small as setting `looping` and `warping` explicitly and reading
  them back — Seshat already has both addresses, and the MVP's honest
  read-back reply becomes an honest *assertion* reply. Cheapest lever, and it
  may retire the seam complaint on its own by letting Live warp.
- **Over-generate and crop.** Render longer than asked, detect the grid phase
  sub-beat, crop to an exact bar count. Costs latency, touches no OSC, and must
  preserve a pickup rather than shaving it off as leading silence.
- **Seam repair.** Fade/crossfade at the loop point, click removal. Only if the
  seam survives correct warping.
- **A second quality lane.** Exposed only if Part 0's blind comparison says
  `medium` wins audibly. If it does not, the lane is declined here and recorded
  in the roadmap's *Deliberately not planned*.

Each lever ships with its read-back, and none of them may make the reply claim
something it did not observe — the MVP's honesty rule holds unchanged.

## Live verification

By-ear checks in `docs/smoke_tests/manual/by-ear.md` — grid placement, seam
quality, pickup and rest preservation, behaviour across a tempo change, and
close-versus-loose variation strength. These need a person and a pair of
speakers by definition; `/smoke-write` picks the final set once the parts are
written, and the automated `auto/generation.md` checks from the MVP must still
pass unchanged.

## Out of scope

- Anything the MVP already owns: generation, the managed folder, import, the
  tool schema's shape, take preservation.
- Stems, inpainting, full songs, cloud providers, persistent model servers.
- Any fork or Python change, unless Part 0 measures a failure that has no
  Elixir-side fix — in which case it is a fork commit in the standalone clone
  first, and this plan says so explicitly rather than editing the submodule.

## Open questions

1. Does correct warping make phase correction unnecessary for most material,
   or does Live's warp engine need a clean downbeat to latch onto? Part 0
   answers this, and the answer decides whether the DSP work happens at all.
2. Is grid phase a property of the model (fixable with prompt or seed strategy)
   or of the render (fixable only by cropping)?
3. Does a producer want a pickup preserved or trimmed? These conflict, and the
   answer is a default plus wording in the tool description, not an algorithm.
