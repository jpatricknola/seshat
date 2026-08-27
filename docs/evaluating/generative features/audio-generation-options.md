# Audio generation for single-track material — provider evidence

Researched 2026-08-25. Evidence behind a prospective "generate audio onto a
track" feature: user describes material for one track (drum loop, bassline,
pad bed, texture, one-shot), Seshat generates it and imports the WAV into
Live at the target track/slot. **Not full songs** — that constraint decided
most of what follows.

The broader product behavior, including adding context-aware audio to an
existing set, is defined in
[music-generation-user-stories.md](music-generation-user-stories.md).

Updated after the local spike recorded below: SA3 small and medium both run
locally inside the latency budget, their runtime returns bar-exact files
without a client trim, and SA3's experimental Ableton integration demonstrates
that direct `ClipSlot.create_audio_clip(path)` import can make browser indexing
unnecessary. **Seshat does not expose that LOM method today.**

## The Suno question, settled

Suno has **no official public API** (July 2026: partner-program intake form
only, no timeline). Every "Suno API" on the web is a third-party reseller
proxying account pools, or a self-hosted cookie scraper — all breach Suno's
ToS somewhere in the chain. Moot anyway: Suno's product is full mixed songs,
the wrong shape for this feature. Udio identical (their own help center:
no public API).

## Shortlist

| Option | Where | Cost | Latency | BPM control | Key control | Loop support | License |
|---|---|---|---|---|---|---|---|
| **Stable Audio 3 small** (433M, May 2026) | Local, official MLX | Free below the Community License revenue threshold | **1.0–1.1 s measured** per four-bar clip after first cache warm-up | Prompt-text; adherence still needs the ear/grid gate | Soft prior, unmeasured | Runtime output measured bar-exact to one sample frame | Community License: commercial use below $1M annual revenue; Enterprise terms required above |
| **Stable Audio 2.5 API** | `api.stability.ai` `/v2beta/audio/stable-audio-2/*` | $0.20/gen flat (any duration) | ~5–20s, sync HTTP | Prompt-text, evaluated in ARC paper | Soft prior, unmeasured | Same trim practice | API output commercially usable |
| **ElevenLabs SFX API** | `/v1/sound-generation` | ~40 credits/sec (~$0.03–0.09 per 8s) | Sync, fast (unmeasured) | Prompt-text, **unverified** for SFX model | Unverified | **Explicit `loop: true` param**, 0.5–30s exact duration | Commercial from Starter tier |
| **ElevenLabs Music API** | `/v1/music` | $0.15/min | ~21s measured for 90s | Docs claim precise hold; one review corroborates | Docs claim; thin evidence | Docs teach bar-count loop prompting; 3s floor | Licensed training data (Merlin/Kobalt); self-serve tier excludes film/TV/games |

Ruled out: Lyria 3 Pro (song-shaped; Lyria RealTime has typed `bpm`/`scale`
params but streams a continuous performance — capture-and-cut, wrong shape);
Mubert/Loudly/Soundraw/Beatoven/Soundverse (soundtrack services, 15–30s
minimums, full arrangements, volume pricing); Splice/Audialab (no APIs);
ACE-Step 1.5 (best open *song* model, MIT, runs on MPS but 25s–10min per
clip on non-Max M-series and song-oriented); MusicGen (2023 baseline, 32kHz,
no official MPS).

## Local SA3 spike — measured 2026-08-25

The runtime was installed at `~/.seshat/stable-audio-3` with
`optimized/mlx/install.sh -y --download sm-music,medium` (~8 GB of weights).
A 24-generation slate covered drum loop, bassline, pad, and texture prompts
at 90, 124, and 170 BPM on both models, seed 42 and eight inference steps.
Files and `timings.csv` live in `~/.seshat/audio-spike/`.

- All 24 generations exited successfully.
- **Per-CLI-call wall clock, including model load:** `sm-music` took
  1.0–1.1 s after the OS cache was warm and 4.1 s on the first-ever call;
  `medium` took 2.6–3.8 s. CLI-per-generation is therefore sufficient; a
  persistent sidecar has no measured justification.
- **Durations were bar-exact to one sample frame.** Requested durations were
  10.667, 7.742, and 5.647 s; measured results were 10.667007, 7.741995, and
  5.647007 s at 44.1 kHz. No client-side trim step is required.
- The local runtime accepts `--negative-prompt`, useful for isolated material
  intended for transcription.
- **Still open, ears required:** BPM adherence on Live's grid, loop-point
  cleanliness, per-material quality, and whether `medium` audibly improves on
  `sm-music`.

## Facts that decide the design

1. **Prior art validates the exact pipeline.** gary4live (Max for Live +
   `stable-audio-open-small`) appends Ableton's global BPM to every prompt,
   does bar-length math server-side (bars × beats × 60/BPM), trims to the
   bar boundary, and ships loops that "stack seamlessly without
   post-generation trimming." A working product betting on prompt-BPM
   reliability. <https://github.com/betweentwomidnights/stable-audio-api>
2. **Exact duration is not the same as a clean loop.** The local SA3 runtime
   returned every requested duration to within one 44.1 kHz sample frame, so
   no client trim is needed. BPM adherence and whether the boundary sounds
   seamless remain human-listening gates.
3. **Key adherence is unmeasured everywhere.** Every provider treats key as
   a soft prior; no published accuracy measurement exists for any of them.
   Design must treat key as best-effort, not contract.
4. **Material-type strengths split cleanly.** Stable Audio lineage: strong
   drums/percussion/electronic/textures, weak exposed melodic realism, no
   vocals ever. ElevenLabs Music: strongest documented prompt adherence for
   melodic/harmonic material. This argues for a router, or at least a
   quality-escalation path.
5. **Per-loop economics favor local.** $0.20 buys a 3-minute 2.5 generation
   or a 4-bar loop — same price. SA3-small makes the loop case free and
   ~instant, and iteration ("again, but darker") is the actual usage
   pattern.
6. **Stable Audio 2.5's audio-to-audio** (`strength` 0.6–0.9) is the one
   capability no local small model matches — "make a variation of this
   clip" later.
7. **Direct clip import can replace browser indexing, but is not implemented
   in Seshat.** Stable Audio 3's
   experimental Ableton integration calls `ClipSlot.create_audio_clip(path)`.
   A new Seshat fork address can wrap that LOM method and verify `has_clip`,
   name, and length; generated WAVs can remain in a managed folder outside the
   User Library. That means a fork change, address documentation and tests,
   `mix abletonosc.install`, and a Live restart before this route can import
   anything.

## Recommended architecture

**Local-only SA3, with the model choice as the escalation surface.**

- Default lane: **Stable Audio 3 small via MLX**, invoked locally. It is
  ~1-second class after cache warm-up and covers the likely drum, percussion,
  texture, and electronic-loop slate.
- Quality lane: **Stable Audio 3 medium**, also local, only if the listening
  gate shows an audible benefit worth its higher latency and memory. Cloud
  providers remain contingencies, not implementation dependencies.
- Tool contract stays small: `description`, `bars`, target track/scene, and
  an optional material/model hint. The handler injects mirrored tempo, time
  signature, and key/scale and computes the exact requested duration.
- Ableton import uses a dedicated fork address around
  `ClipSlot.create_audio_clip(path)`. Generated files live in Seshat's managed
  folder outside the User Library; no browser indexing or URI lookup is
  involved.
- The code repository is MIT, but model weights are governed separately by
  the Stability AI Community License. Distribution needs a documented weight
  installation/entitlement path and an Enterprise-license path for users or
  organizations above its revenue threshold.

## Open questions for a plan

- SA3 quality by ear on the target material slate, BPM adherence on Live's
  grid, loop cleanliness, and whether medium earns an escalation surface.
- Implement and live-test the absent `ClipSlot.create_audio_clip(path)` fork
  address, including verification, address documentation, install/restart
  instructions, and behavior when the target slot is occupied.
- Model-weight installation and licence entitlement: what Seshat distributes,
  what the user downloads separately, and what happens above the Community
  License revenue threshold.
- Key verification: worth a post-generation pitch check, or ship
  best-effort with honest reply wording (house style: report what was
  observed, not what was requested).
- Managed-folder lifecycle while Live sets may still reference generated
  files.

## Source index

Full agent reports with per-claim URLs live in the session transcript;
primary sources: Stability platform docs + KB + pricing update, arXiv
2605.17991 (Stable Audio 3), arXiv 2505.08175 (ARC), Stability community
license, ElevenLabs API references (music/compose, sound-generation,
stem-separation) + music model terms, gary4live repos, HN thread on SA3
(id 48209105), Google Lyria RealTime docs, Mubert/Loudly/Soundraw/Beatoven
API pages.
