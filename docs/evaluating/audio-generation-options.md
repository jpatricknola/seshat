# Audio generation for single-track material — provider evidence

Researched 2026-08-25. Evidence behind a prospective "generate audio onto a
track" feature: user describes material for one track (drum loop, bassline,
pad bed, texture, one-shot), Seshat generates it and imports the WAV into
Live at the target track/slot. **Not full songs** — that constraint decided
most of what follows.

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
| **Stable Audio 3 small** (433M, May 2026) | Local, official MLX | Free | **~1s** per 10s clip on base M1, 1.6GB RAM | Prompt-text; lineage community-attested "excellent bpm awareness" | Soft prior, unmeasured | Trim to bar length client-side | Community License: free < $1M revenue, auto-terminates above |
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

## Facts that decide the design

1. **Prior art validates the exact pipeline.** gary4live (Max for Live +
   `stable-audio-open-small`) appends Ableton's global BPM to every prompt,
   does bar-length math server-side (bars × beats × 60/BPM), trims to the
   bar boundary, and ships loops that "stack seamlessly without
   post-generation trimming." A working product betting on prompt-BPM
   reliability. <https://github.com/betweentwomidnights/stable-audio-api>
2. **Nobody trusts raw loop points.** Universal practice across every
   source: generate with `loop`/`seamless`/BPM in the prompt, ~1s headroom,
   then **trim client-side to the exact bar length** — deterministic because
   Seshat mirrors tempo *and* time signature in `Session.State`. The trim
   step is mandatory in the design regardless of provider.
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

## Recommended architecture

**Local-first, cloud-escalation, provider-agnostic tool contract.**

- Default lane: **Stable Audio 3 small via MLX**, invoked locally. Free,
  ~1s, offline, covers the bread-and-butter slate (drums, percussion,
  textures, electronic loops).
- Escalation lane: **Stable Audio 2.5 API** for melodic/key-critical
  material or when local quality disappoints ($0.20, sync, no install
  burden). ElevenLabs is the alternative here if licensed-training-data
  provenance ever matters.
- Tool contract stays dumb: `description`, `bars` (or `duration`),
  optional `material` hint. Handler injects mirrored BPM + time signature +
  key/scale, computes duration, trims output to the bar boundary, drops the
  WAV where Live's browser indexes it, loads it via the browser pipeline.
- Ableton import side (provider-independent, needed regardless): new fork
  address to load an audio browser item as a *clip* into a target
  track/slot — existing `_load_onto` verifies `track.devices`, wrong
  read-back for a clip landing. Two-commit fork change.

## Open questions for a plan

- SA3-small on this machine: actual install footprint (Python/MLX sidecar
  next to the BEAM — Port? separate localhost service?), measured quality
  by ear on the target material slate.
- Trim implementation: ffmpeg? sox? pure-Elixir WAV surgery? (Trim at a
  sample boundary of a 44.1kHz stereo WAV is simple arithmetic.)
- File→browser-index latency: how fast does Live's browser see a WAV
  written into User Library, and is it findable by uri immediately.
- Key verification: worth a post-generation pitch check, or ship
  best-effort with honest reply wording (house style: report what was
  observed, not what was requested).
- Blocking vs split tool shape — local ~1s lane makes blocking viable for
  the default path; cloud lane may still want request/poll split.

## Source index

Full agent reports with per-claim URLs live in the session transcript;
primary sources: Stability platform docs + KB + pricing update, arXiv
2605.17991 (Stable Audio 3), arXiv 2505.08175 (ARC), Stability community
license, ElevenLabs API references (music/compose, sound-generation,
stem-separation) + music model terms, gary4live repos, HN thread on SA3
(id 48209105), Google Lyria RealTime docs, Mubert/Loudly/Soundraw/Beatoven
API pages.
