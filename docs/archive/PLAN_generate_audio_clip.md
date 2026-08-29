# Plan — Generate audio onto a track (MVP)

> **Archived 2026-08-30 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ (see the PR for the
> implementer's per-item report, the review's verdict and nits, and the
> assumptions carried through the run). The feature lives in
> `lib/seshat/generation/` (`spec.ex`, `backend.ex`, `stable_audio.ex`,
> `audio_clip.ex`, `result.ex`), the `generate_audio` tool in
> `Seshat.Tools.Definitions`/`Handlers`, and the roadmap's "Generate audio
> onto a track — Stable Audio 3, imported as a clip" entry is removed. Two
> defects the review found were left non-blocking and are now their own
> roadmap items: "`variation_of` refuses a managed take when `~/.seshat` is a
> symlink" and "Bounded generation diagnostics can drop the newest chunk
> entirely on overflow." **None of this plan's four `## Live verification`
> citations demonstrate the shipped feature yet**: both `auto/generation.md`
> checks still read `*Last run: —*`; the manual `conversation.md` check is
> unrun and needs a person; and `auto/mcp-surface.md`'s only recorded run
> (2026-08-28, 52 tools) predates this tool's addition to the surface (now
> 53), so it does not actually cover the `variation_of` object-typed schema
> the citation was added for. Run `/smoke-test generation` and
> `/smoke-test mcp-surface`, plus the manual conversation check, before
> trusting this feature's live behaviour.

Roadmap item **“Generate audio onto a track — Stable Audio 3, imported as a
clip.”** Add one MCP tool, `generate_audio`, that renders short audio locally
with the installed Stable Audio 3 MLX runtime, keeps every take in Seshat's
managed folder, and imports it into a Session slot through the fork address
`/live/clip_slot/create_audio_clip`, which wraps Live's
`ClipSlot.create_audio_clip(path)`.

This is deliberately the first of **two** PRs. It proves the generation/import
workflow and preserves honest observability. It does **not** analyze rhythmic
phase, repair loop seams, alter warp or loop markers, or offer a second quality
lane. Those audio-polish concerns are planned separately in
[PLAN_generate_audio_polish.md](../PLAN_generate_audio_polish.md), which is
sequenced **after** the roadmap's MIDI generation item and finalised against the
fixtures this PR produces.

The fork half of the work is **already done**: `/live/clip_slot/create_audio_clip`
and the shared import-path rule are merged on the fork's `origin/master`
(`fe6730e`). This PR bumps Seshat's gitlink to it and installs the bridge; it
writes no Python.

**Acceptance is user-perceived.** With Live, Seshat, the runtime, and the
installed bridge at the pin Part 0 sets, “give me a four-bar dusty lo-fi drum part
on a new track” takes one tool call and leaves a named audio clip in slot 0,
selected and shown in Clip view. The generated WAV has exactly the requested
duration to the sample frame. The reply names the audio form, file, track and
slot and reports Live's observed clip length, looping and warping state; it
never claims grid alignment, a clean loop seam, or successful import without
read-back. “Another take, darker” lands in the next empty slot without touching
the kept take.

## Context

- The local runtime is already installed at
  `~/.seshat/stable-audio-3/optimized/mlx`. The 2026-08-25 spike measured the
  `sm-music`/`same-s` lane at 1.0–1.1 seconds for four bars after warm-up and
  confirmed that its 44.1 kHz stereo PCM output is trimmed to exactly the
  requested `--seconds` value. This MVP uses that one measured lane.
- Raw generations are not reliably performance-ready loops. Measured drum
  outputs begin 174–488 ms after the file boundary in several cases and often
  fade near the end. That evidence motivates the follow-up PR; it is not a
  reason to make the first generation/import PR solve DSP, downbeat inference,
  looping and warping together.
- The runtime CLI requires explicit `--prompt`, `--dit` and `--decoder` to
  avoid interactive input. It accepts `--negative-prompt`, `--seconds`,
  `--seed`, `--init-audio`, `--init-noise-level`, `--cfg` and `--out`.
  `--init-noise-level` is refused below `0.01`. The adapter must preflight
  weights because an absent weight otherwise starts an in-call download.
- `ClipSlot.create_audio_clip(path)` exists in Live 12.4.5. Stable Audio 3's
  own experimental integration calls it and immediately reads `clip.length`,
  so synchronous import plus read-back is the appropriate contract.
- The import address **has landed in the fork** (`fe6730e` on `origin/master`,
  merged 2026-08-29), documented in `API.md` and `SESHAT.md` in the same work.
  The fork owns the wire facts; this plan cites them. What remains on Seshat's
  side is Part 0 — fast-forward the `priv/AbletonOSC` gitlink to that commit,
  `mix abletonosc.install`, restart Live. No Python is written here.
- **The wire never carries a path.** `abletonosc/path_safety.py` fixes one
  import root, `~/.seshat/generated`, resolves the wire-supplied *name* under
  it with both sides `realpath`ed, and refuses an absolute name, an empty name,
  a null byte, an escape out of the root, and anything that is not a regular
  file. Seshat therefore writes takes into exactly that directory (creating it
  `0700`, as the fork deliberately does not) and sends basenames. A symlink
  inside the root whose target is also inside is accepted — the rule is
  "resolves inside the root", not "is not a symlink".
- This becomes the second process-starting door under `lib/seshat/` after
  `Seshat.AX.Client`. The existing architectural grep test must name both
  allowed files rather than being bypassed.
- `Seshat.Session.State.snapshot/0` already carries tempo, time signature,
  root note and scale name. Generation refuses unknown tempo or signature;
  key is appended as a soft prompt hint and reported as requested, not verified.
- Runtime code is MIT. Weights are governed by the Stability AI Community
  License and the text encoder by Gemma terms. Seshat ships neither runtime nor
  weights; users install them under the applicable terms. Above the Community
  License's $1M annual revenue threshold, using the weights requires a
  Stability AI Enterprise licence — that obligation attaches to the user's own
  installation, and Seshat's distribution position is unchanged because it
  distributes neither runtime nor weights.

### Architectural decisions

- **One producer-facing tool.** `generate_audio` owns generation and import.
  `variation_of` handles “again, but darker”; neither the backend nor the fork
  address becomes a separate MCP tool.
- **Generate first, touch Live second.** Validate the target and reject an
  occupied explicit slot before rendering. Create a new track only after the
  file exists. A generation failure therefore leaves the Live set untouched.
- **Use a behaviour and one CLI process per request.**
  `Seshat.Generation.Backend.generate/1` has the real
  `Seshat.Generation.StableAudio` implementation and a test fake. A 60-second
  timeout bounds a wedged runtime and terminates its exact OS process.
- **Keep every take.** Files under `~/.seshat/generated/` are append-only
  because Live may continue referencing them. The directory is not a Seshat
  choice any more — it is `path_safety.IMPORT_ROOT`, and changing it means
  changing the fork constant too. An atomically reserved lowercase basename
  (`<slug>-<utc-timestamp>-<seed>.wav`) prevents concurrent requests from
  overwriting one another. Cleanup remains a separate roadmap concern.
- **Import the raw duration-exact render.** The runtime writes directly to the
  reserved final path for precisely the requested seconds. The MVP neither
  over-generates nor post-processes it and does not set Live's looping, warping,
  markers or gain. It reads those properties after import and reports them.
- **One quality lane.** The adapter always selects `sm-music` and `same-s`.
  Exposing `fast`/`best` before a listening comparison would grow the contract
  around an unproven distinction.
- **Variation stays in MVP.** A generated audio clip with a regular managed
  file may be passed back through `--init-audio`; strength maps to the runtime's
  noise level. The runtime itself fits the source to the requested duration.

## OSC contract

Existing addresses were checked against
[priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md) at fork pin `fe6730e` on
2026-08-29, the commit Part 0 installs. Implementation must re-check the pin it
actually installs.

### The import address — merged in the fork, consumed here

| Address | Request | Reply | Notes |
|---|---|---|---|
| `/live/clip_slot/create_audio_clip` | `track_index, clip_index, name` (`i i s`) | echoed `track_index, clip_index, "ok", length`; or echoed indices, `"error", message` | Seshat extension, always replies. `name` is resolved under the fixed import root `~/.seshat/generated` by `path_safety.resolve_import_path`; an absolute name is refused. The discriminator is always field 2 and the two replies are deliberately different lengths. `"error"` covers a refused name, `has_clip` raising, an **occupied slot** (the fork's own check) and anything Live raised inside `create_audio_clip`, message carried through. A bad `track_index`/`clip_index` comes back as structured `/live/error` instead. `length` is `clip.length` in beats read immediately, `-1.0` if unreadable; whether the returned `Clip` is synchronously readable is **unmeasured**, so read back with `/live/clip/get/file_path` and `/live/clip/get/is_audio_clip` rather than trusting it. No listen pair — it is a method. |

`/live/track/create_audio_clip` (the Arrangement form) landed in the same fork
commit and is **not** used by this PR; Session slots only.

### Existing addresses consumed by the MVP

| Address | Use |
|---|---|
| `/live/clip_slot/get/has_clip` | Refuse an occupied explicit slot and find the first empty slot. |
| `/live/song/get/num_scenes` | Bound slot discovery. |
| `/live/track/get/is_foldable`, `/live/track/get/has_audio_input`, `/live/track/get/has_midi_input` | Refuse group and non-audio target tracks before generation. A regular audio track remains valid when it is nested inside a group. These guards run for both an explicit track and the track inferred by `variation_of`. |
| `/live/song/create_audio_track` | Create an omitted destination track after generation succeeds. The existing Registry verifies the regular-track count rose by exactly one, names the appended track, and refreshes session state. |
| `/live/track/set/name` | Name a newly created track. |
| `/live/clip/set/name` | Name the imported clip. |
| `/live/clip/get/name`, `/live/clip/get/length`, `/live/clip/get/looping`, `/live/clip/get/warping`, `/live/clip/get/file_path` | Verify and report what Live imported. No playback property is changed by this PR. |
| `/live/clip/get/is_audio_clip`, `/live/clip/get/file_path` | Validate a variation source and locate its regular file. |
| `/live/view/set/selected_clip`, `/live/view/set/detail_clip`, `/live/view/show_view` | FollowCam selects the imported slot, puts that exact clip in Detail, and shows `Session` then `Detail/Clip` after verified success only. |

## Numbered implementation parts

## Part 0 — Pin the fork and install the bridge

The fork work is merged; this is the consumption step, and it comes first
because nothing below can be verified against Live without it.

1. Fast-forward `priv/AbletonOSC` to the fork's `origin/master` (`fe6730e`) and
   commit the gitlink from the Seshat repo. Never commit inside the submodule.
2. `mix abletonosc.install` — it names the commit it deployed; check that name
   against the pin.
3. Restart Live so the new Python loads.
4. Re-read the `/live/clip_slot/create_audio_clip` row in
   `priv/AbletonOSC/API.md` at the installed pin before writing Part 2's import
   call, and confirm `path_safety.IMPORT_ROOT` is still `~/.seshat/generated`.

## Part 1 — Add the generation backend boundary and Stable Audio adapter

Create:

- `lib/seshat/generation/backend.ex`
- `lib/seshat/generation/spec.ex`
- `lib/seshat/generation/stable_audio.ex`
- `test/support/generation/fake_backend.ex`
- focused adapter tests under `test/seshat/generation/`

`Spec` contains `prompt`, optional `negative_prompt`, `seconds`, `seed`,
optional `init_audio`, `init_noise_level`, and the reserved absolute
`out_path`. `Backend.generate/1` returns `{:ok, %{path:, seed:, wall_ms:}}` or
`{:error, reason}`.

`StableAudio` must:

1. Resolve the configured `sa3` executable and model directory; preflight the
   wrapper, `scripts/sa3_mlx.py`, and `.venv/bin/python`, rejecting a missing or
   non-executable runtime before the wrapper can enter its interactive install
   path.
2. Preflight the T5Gemma, `sm-music` and `same-s` weight files, plus the
   `same-s` encoder only for variation. Never download during a tool call.
3. Build a pure argv list that always supplies `--prompt`, `--dit sm-music`,
   `--decoder same-s`, `--seconds`, `--seed` and `--out`. Serialize seconds
   with enough precision that the runtime's `round(seconds * 44_100)` equals
   the domain's target frame count. Add `--negative-prompt` and `--cfg 3.0`
   together, and add both init-audio flags only for variation.
4. Start only that executable with `Port.open/2`; pass no user text through a
   shell. Collect bounded output for diagnostics.
5. On exit 0, require the final path to be a regular non-symlink file. On any
   other exit, return the status and bounded stderr/stdout.
6. At 60 seconds, read the exact OS pid from `Port.info(port, :os_pid)`, invoke
   `/bin/kill -TERM <pid>` without a shell, wait a short bounded grace period,
   then `/bin/kill -KILL <pid>` if necessary. The `sa3` wrapper uses `exec`, so
   that pid is the Python runtime rather than a shell parent. Close and reap the
   port before returning timeout; never target a guessed pid or process group.

Update the AX process-door test so exactly `Seshat.AX.Client` and
`Seshat.Generation.StableAudio` may start native processes.

## Part 2 — Add the audio-generation domain workflow

Create `lib/seshat/generation/audio_clip.ex` and focused tests. It owns the
workflow and the small OSC helper equivalents it needs; do not reach into
private `Handler` functions.

The workflow is:

1. Read one state snapshot. Validate `bars` in `1..16`, finite positive tempo,
   and a supported positive time signature. Compute requested beats, seconds
   and `target_frames = round(seconds * 44_100)` once.
2. Build a musical prompt from the user's description plus observed BPM and
   time signature. Append key/scale only when present.
3. Resolve the destination. For an explicit or variation-inferred track, run
   every audio/group guard before generation. For an explicit slot on an
   existing track, refuse if occupied. When slot is omitted on an existing
   track, find the first empty existing scene or fail with an actionable
   message. For a new track, validate a supplied `clip_slot` against the current
   scene count or default it to slot 0; there can be no occupancy check until
   the track exists. Do not create scenes in this PR.
4. For `variation_of`, require an audio clip with a non-empty, regular,
   non-symlink source path. Restrict it to Seshat's managed generated root in
   the MVP. Map public `strength` in `0.01..1.0` directly to init noise level.
5. Create the managed root when absent and explicitly chmod it to `0700` (do
   not rely on the process umask). Atomically reserve a unique safe basename
   inside it using an exclusive create. Never derive a path from arbitrary
   model text.
6. Call the configured backend. On failure, delete only this request's reserved
   or partial output and return without changing Live.
7. If no target track was supplied, create and name an audio track now through
   the Registry's count-verified append path, run the same audio/group guards,
   and use the supplied validated slot or its slot-0 default.
8. Import by basename through `/live/clip_slot/create_audio_clip`. Treat only the echoed
   `"ok"` reply as success; surface its `"error"` reply or structured OSC error.
9. Set the clip name, read back name, length, looping, warping and file path,
   require the read-back path to match the generated file, then apply FollowCam
   selection and show `Clip` view.

Return a result struct containing target indices/names, requested bars/beats/
seconds, observed clip properties, file path, seed, elapsed generation time and
the requested key hint. Preserve the generated file on import failure because
it is a valid take the user may recover; say explicitly that it was not
imported. If track creation occurred first, report the empty track as a partial
effect. Never overwrite or delete a pre-existing clip or generated take.

## Part 3 — Define the `generate_audio` MCP tool

Add one component to `lib/seshat/tools/definitions.ex`:

```text
generate_audio(
  description: required string,
  bars: integer 1..16 = 4,
  track: optional existing track index,
  clip_slot: optional non-negative scene index,
  track_name: optional string for a newly created track,
  variation_of: optional {track, clip_slot},
  strength: number 0.01..1.0 = 0.55,
  negative_prompt: optional string,
  seed: optional integer
)
```

Let the existing schema validator reject types, numeric bounds, invalid indices
and unknown keys. Put cross-field rules in a pure `AudioClip.validate/1` step
that runs before any OSC or backend call: reject `track_name` with an explicit
existing `track`, `strength` without `variation_of`, and conflicting
destination/source shorthand. The same step rejects blank prompt strings and
bounds `description` and `negative_prompt` to 1,000 characters each; the current
schema/validator has no `minLength`/`maxLength` support, so do not imply those
checks come from JSON Schema or widen the generic validator for this tool.

Update `test/seshat/tools/definitions_test.exs`: raise the exact tool count
from 52 to 53 and add `generate_audio` to the expected-name list. The generated
MCP component needs no hand-written module.

The tool description must state that it creates **audio**, needs the separately
installed local runtime, can take several seconds while holding the normal
serialized Ableton tool lock, preserves takes, and imports the raw
duration-exact render unchanged. It must say this MVP does not correct rhythmic
phase, loop seams, warping or later tempo following and that the reply reports
Live's observed state. Suggest MIDI note writing/editing when exact note-grid
control is the actual request; do not name a MIDI-generation tool that has not
shipped yet.

Draft description (prompt text for a model that cannot see the code; adjust
only where implementation proves it inaccurate):

> Generate a short **audio** clip from a text description and import it into a
> Session slot. Renders locally with the separately installed Stable Audio 3
> runtime; if the runtime or its weights are missing the call refuses and says
> so — nothing is downloaded. Tempo, time signature and key are taken from the
> session automatically; put only the musical material in `description` (e.g.
> "dusty lo-fi drum break", "warm pad bed"). Generation takes a few seconds
> and holds the normal serialized Ableton tool lock while it runs. The raw
> duration-exact render is imported unchanged: no rhythmic-phase, loop-seam,
> warp or tempo-following correction is applied, and the reply reports what
> Live observed (clip length, looping, warping) rather than promising grid
> alignment or a seamless loop. Every take is kept on disk and never
> overwritten. Track indices are 0-based. Omit `track` to create a new audio
> track (optionally named with `track_name`); with an existing `track`, omit
> `clip_slot` to use its first empty slot — an occupied explicit slot is
> refused before anything is generated. For "again, but darker" pass
> `variation_of` pointing at a previously generated clip; `strength`
> (0.01–1.0, default 0.55) sets how far the variation departs and is only
> valid with `variation_of`. For exact control of individual notes, write or
> edit MIDI notes instead of generating audio.

## Part 4 — Wire the handler and honest replies

Add the dispatch branch in `lib/seshat/tools/handlers.ex` and delegate to
`AudioClip.generate/1`. The handler only formats the domain result.

Add `generate_audio` to the clip-writing clause in
`Seshat.Tools.FollowCam.calls/2`, using `%{track: track, slot: slot}` so the
existing selected-clip/detail-clip/Session/Detail sequence is reused rather
than reimplemented in the generation module.

A success reply should resemble:

> Generated a 4-bar audio clip (7.742 s requested at 124 BPM in 4/4) and
> imported it to “Gen Drums”, slot 0. Live reads back 16.0 beats, looping on,
> warping on. Imported without rhythmic-grid or loop-seam correction. File:
> `dusty-breakbeat-…-1842.wav`; seed 1842; generation 1.1 s. Key requested: F
> minor (not pitch-verified).

Do not promise that the observed values will always be 16 beats, looping on or
warping on; those are example read-backs. Failure replies identify the failed
stage and observed side effects, including whether a file or new empty track
remains. Occupied-slot refusals name the slot and, when known, the next empty
one, and confirm that generation did not start.

## Part 5 — Configuration and supervision

Add application configuration for the backend module, executable, model root,
managed generated root, generation timeout and bounded diagnostic output. Use
`Application.compile_env/3` only for stable module selection and runtime reads
for paths/timeouts so tests can safely override them. No new supervised process
is needed; generation is synchronous inside the existing tool transaction.

## Part 6 — Automated tests

Add or update tests for:

- schema validation and component discovery;
- duration/frame math across tempo, signature and 1/16-bar boundaries;
- deterministic safe prompt/argv construction, negative prompt and variation;
- weight/runtime preflight, non-interactive invocation, success, non-zero exit,
  timeout/runtime-process termination, missing/partial/symlink output and bounded
  diagnostics using a throwaway executable runtime;
- atomic filename reservation, `0700` creation of the import root, and cleanup
  of only the failed request's file;
- a `vendored_addresses_test` assertion pinning `path_safety.py`'s
  `IMPORT_ROOT` literal, the way that file already pins `browser.py`'s
  `EXPORT_ROOT`, since Seshat re-derives the same root in Elixir;
- target guards, occupied-slot refusal before backend invocation, first-empty
  selection, variation source validation and new-track creation ordering;
- exact import request/reply matching, clip-name/read-back verification,
  preservation on import failure and FollowCam only after verified success;
- success and partial-failure reply wording; and
- the two-file native-process architectural allow-list, including termination
  of the exact fake runtime pid on timeout.

Use an OSC sink and fake backend for domain tests. Unit tests must not require
Live, model weights, network access or the user's runtime.

## Part 7 — Documentation and durable smoke coverage

- Document runtime installation, the `sm-music`/`same-s` weight requirement,
  configured paths, licence boundary, cold-start behavior, managed-file
  permanence, Collect All and Save advice, and the MVP's explicit playback
  limitations in `README.md`.
- Keep the generated-audio automatic smoke workflow in
  `docs/smoke_tests/auto/generation.md` and the conversational routing check in
  `docs/smoke_tests/manual/conversation.md`.
- Update `docs/smoke_tests/manual/README.md` counts.
- Add the generation modules to `CLAUDE.md`'s module map and update its
  process-door description from one permitted module to the two named doors.
- The deferred audio-alignment/warping/quality work is already a separate
  roadmap item with its own plan
  ([PLAN_generate_audio_polish.md](../PLAN_generate_audio_polish.md)); keep the
  MVP's measured raw and imported fixtures rather than discarding them, because
  that plan is finalised against them.

## Testing

During implementation run focused files first, then:

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix test`
4. `mix precommit`

Tests must prove that no generation begins for an occupied/non-audio target,
no Live mutation precedes a successful file, no success is reported before
import read-back, user text never reaches a shell, concurrent names cannot
collide, and timeout cleanup leaves no timed-out runtime process running.

## Live verification

- [`docs/smoke_tests/auto/generation.md` § “A generated clip lands, reads back, and its file is duration-exact”](../smoke_tests/auto/generation.md#a-generated-clip-lands-reads-back-and-its-file-is-duration-exact)
- [`docs/smoke_tests/auto/generation.md` § “An occupied slot is refused before anything is generated”](../smoke_tests/auto/generation.md#an-occupied-slot-is-refused-before-anything-is-generated)
- [`docs/smoke_tests/manual/conversation.md` § “A generation request routes to one call and names the form”](../smoke_tests/manual/conversation.md#a-generation-request-routes-to-one-call-and-names-the-form)
- [`docs/smoke_tests/auto/mcp-surface.md` § “The tool list survives a real handshake”](../smoke_tests/auto/mcp-surface.md#the-tool-list-survives-a-real-handshake)
  — `variation_of` is the first root-level object-typed property on the
  published surface (every earlier one sat inside an array's items), and a
  client that rejects that shape refuses the whole tool list, so this check
  needs to run before trusting the rest of this list.

These checks cover MVP generation, safe import, read-back, take preservation,
boundary duration and conversational routing. By-ear grid phase, downbeat
choice, seam quality, explicit warp/loop correction, tempo changes and medium
model quality are intentionally uncovered here and owned by the follow-up
roadmap item.

## Out of scope

- Rhythmic phase/downbeat detection, over-generation and cropping.
- Silence/fade analysis, seam repair, crossfades and click removal.
- Setting warp mode, warping, looping, start/loop markers or validating behavior
  after a set-tempo change.
- A `best`/`medium` quality lane or model-choice parameter.
- Pitch/key verification, stems, inpainting, full songs, cloud providers,
  persistent model servers, preview/audition and Slice to New MIDI Track.
- Importing arbitrary user paths, generated-file cleanup or project portability
  automation.
- Any fork implementation or fork documentation — that work is merged. The
  gitlink bump, `mix abletonosc.install` and the Live restart are Part 0 of
  *this* PR.
- `/live/track/create_audio_clip` (Arrangement import), which the same fork
  commit exposes.

## Open questions

1. Does a first generation immediately after reboot remain comfortably inside
   60 seconds on the supported machine, or should setup expose an explicit
   warm-up check? This does not change the MVP contract; the timeout remains a
   hard failure boundary.
