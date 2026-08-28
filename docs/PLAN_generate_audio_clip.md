# Plan — Generate audio onto a track (Stable Audio 3, imported as a clip)

Roadmap item **"Generate audio onto a track — Stable Audio 3, imported as a
clip."** One new MCP tool, `generate_audio`, that turns "a dusty four-bar drum
loop on a new track" into a bar-exact WAV rendered locally by the installed
Stable Audio 3 MLX runtime and imported into a named Session slot through one
new fork address wrapping `ClipSlot.create_audio_clip(path)`. The reply names
the form (audio), the file, the track and slot, and what it read back — never
"done" for a clip that did not import.

**Acceptance is user-perceived.** With Live, Seshat and the runtime installed,
a fresh local MCP conversation asking for "a four-bar dusty lo-fi drum loop on
a new track" must, in one tool call, leave a new audio track with a clip in
slot 0 whose length reads back as 16.0 beats at the set's 4/4 tempo, selected
and shown in the clip view, in under ten seconds end to end (the generation
itself is measured at 1.0–1.1 s for `sm-music`, 2.6–3.8 s for `medium`). "Another
take, darker" must land in the next empty slot on the same track without
touching the one kept.

## Context

Seshat can write MIDI notes, record audio, load devices and shape clips, but it
cannot *produce* audio material, and it has no way to put a file into a clip
slot at all. The generative-features research
([audio-generation-options.md](evaluating/generative%20features/audio-generation-options.md),
[one-model-or-two.md](evaluating/generative%20features/one-model-or-two.md))
settled the direction before this plan: local-only Stable Audio 3 via the
official MLX runtime, the model size as the only escalation surface, the import
done through the Live Object Model rather than through browser indexing. The
facts this plan rests on, all measured or read rather than assumed:

- **The runtime is installed and spiked.** `~/.seshat/stable-audio-3/optimized/mlx`
  holds the MLX port; `./sa3` is a bash wrapper that `exec`s
  `.venv/bin/python scripts/sa3_mlx.py`. Weights (~7.7 GB) live in the Hugging
  Face cache at `~/.cache/huggingface/hub/models--stabilityai--stable-audio-3-optimized`,
  symlinked into `models/mlx/*.npz`. The 2026-08-25 slate in
  `~/.seshat/audio-spike/` (24 generations, `timings.csv`, `run_slate.sh`)
  measured 1.0–1.1 s per four-bar clip for `sm-music` after cache warm-up
  (4.1 s on the first-ever call), 2.6–3.8 s for `medium`, every exit 0, every
  duration bar-exact to one 44.1 kHz sample frame. **No client-side trim
  exists.**
- **The CLI's contract, read from `scripts/sa3_mlx.py` on 2026-08-28:**
  `--prompt`, `--negative-prompt`, `--dit {sm-music,sm-sfx,medium}`,
  `--decoder {same-s,same-l}`, `--seconds FLOAT` (default 30), `--steps INT`
  (default 8), `--seed INT` (random when absent), `--init-audio PATH`,
  `--init-noise-level FLOAT` (σmax; 1.0 = text-to-audio, lower keeps more of
  the source, **refused below 0.01**), `--inpaint-range START,END`, `--cfg`,
  `--out PATH` (absolute used as-is; "always written as 16-bit PCM stereo at
  44.1 kHz, trimmed to exactly `--seconds`"). Two traps for a non-interactive
  caller: **`--dit`/`--decoder` absent → an interactive picker that reads
  stdin** (numeric fallback when stdin is not a TTY, so it blocks on `input()`
  rather than failing), and **`--prompt` absent → `input("Prompt: ")`**. Every
  spawn therefore passes all three. A missing weight file triggers an in-call
  download (`_preflight_download`), which a tool call must never start; the
  adapter checks the needed `.npz` files exist before spawning. On success the
  script prints a `▸ saved <path>` line and exits 0; argparse errors exit 2;
  `sys.exit("error: …")` paths exit 1.
- **`ClipSlot.create_audio_clip(path)` exists in the installed Live.**
  `strings` over Live 12.4.5's `_MxDCore/LomTypes.pyc` lists
  `create_audio_clip`; the fork's own inventory
  ([FORK_GAPS.md](../priv/AbletonOSC/FORK_GAPS.md) § `Live.ClipSlot.ClipSlot`)
  records the signature `create_audio_clip((ClipSlot)arg1, (object)arg2) -> Clip`
  and carries the caution that matters here: it takes an absolute file path, so
  a handler must follow the fork's path-safety rule — the model must not hand
  arbitrary paths to code running with Live's privileges. Stable Audio 3's own
  experimental Ableton integration
  (`optimized/mlx/ableton/AudioInserter/AudioInserter.py`) is the prior art:
  `song.create_audio_track(-1)`, `track.clip_slots[0].create_audio_clip(path)`,
  then reads `slot.clip.length` immediately — so the call is synchronous enough
  that the clip is readable on return. It also copies each WAV to a unique path
  before importing, which is the hint that Live *references* the file rather
  than copying it.
- **Nothing in the fork reaches the method today.** `clip_slot.py` registers
  `fire`, `stop`, `create_clip`, `delete_clip` through the generic
  `_call_method` loop and has one Seshat extension (`get/clip`). The generic
  loop cannot host this one: it would send any string it was given straight to
  Live, and it has no reply, so the import would be fire-and-forget. **The plan
  gains a Python half** — a fork commit in the standalone clone
  (`/Users/patrick/ableton-osc`), `API.md` in the same commit, a pin bump here,
  then `mix abletonosc.install` and a Live restart before anything can import.
  No test in this repo executes that Python; its verification is entirely in
  Live verification below.
- **This is the second process-starting door out of `lib/seshat/`.**
  `test/seshat/ax/client_test.exs` § "only Seshat.AX.Client may start a native
  process" greps all of `lib/` (except `lib/mix/tasks/`) for
  `Port.open|:spawn_executable|System.cmd|System.shell|:os.cmd|:erlang.open_port`
  and allows exactly one file. The roadmap entry asks for it to be widened
  deliberately, not worked around: the allow-list becomes two named files,
  each with the argument for its door written beside it.
- **Session state already carries what the prompt needs.** `Seshat.Session.State`
  mirrors `tempo`, `signature_numerator`/`_denominator`, `root_note` and
  `scale_name` by listener, readable in one call via `State.snapshot/0`; a
  failed refresh leaves them `nil`, never fabricated. The handler computes
  seconds from them and refuses when tempo or signature is unknown.
- **Distribution.** The runtime code is MIT (`LICENSE` in the repo root). The
  weights are under the **Stability AI Community License** — free commercial use
  below $1M annual revenue, Enterprise terms above, licence copy must accompany
  redistributed weights — and the T5Gemma text encoder additionally carries
  Google's Gemma Terms. Per CLAUDE.md this is a selection-time criterion, and
  the selection is: **Seshat ships none of it.** Seshat ships Elixir that looks
  for a runtime at a configured path; the user installs the runtime and
  downloads the weights under their own acceptance of both licences (the
  runtime's `install.sh` does exactly that today); a user or organisation above
  the revenue threshold obtains the Enterprise licence themselves. Part 8 writes
  this down where a user will read it.

### Architectural decisions

- **One tool, named for the producer action.** `generate_audio` — not
  `stable_audio`, not `import_audio_file`. Per
  [adding-a-tool.md](../.claude/docs/adding-a-tool.md) a name is minted only
  when the model must choose a genuinely different workflow, and "make me
  material" is one: no existing verb (write notes, record, load, set) reaches
  it, and the import step is an internal stage a producer never chooses. The
  fork address is deliberately *not* exposed as its own tool — "put this file
  in a slot" has no user story yet, and publishing a path-taking tool is the
  exact thing the path-safety rule exists to prevent. The variation story
  ("again, but darker") is a parameter on the same tool (`variation_of`), not a
  second name.
- **Generate first, touch Live second.** The WAV is rendered before any track
  is created or any slot is written, so a failed generation leaves the set
  untouched and the reply can say so. The one read that precedes generation is
  the occupancy check on an explicitly named slot — refusing a slot the user
  can see is full is cheaper than rendering a clip that cannot land.
- **CLI per generation, through a `Port`, inside the undo lock.** No sidecar
  (roadmap: no measured justification). The whole tool call is one Ableton undo
  step as every tool is, which means the node-wide `:global.trans` lock is held
  for the generation's 1–4 s plus the import. That is the same class of cost a
  slow `load_device` already imposes (30 s budget) and is stated in the tool
  description rather than engineered around; a `@generate_timeout` of 60 s
  bounds the worst case (the roadmap's cold first-ever call was 4.1 s; a
  sixty-second wall means something is wrong, and the port is killed).
- **A behaviour behind the handler, swapped in test.** `Seshat.Generation.Backend`
  (`generate/1`) with one real implementation, `Seshat.Generation.StableAudio`,
  and a test fake — the same shape as `Seshat.AX.Client`'s `FakeAXClient`. The
  handler and the domain module never know a CLI exists, so a cloud
  contingency later is one more module, not a `Definitions` change.
- **The managed folder is `~/.seshat/generated/`, files are never deleted.**
  Live references the file by path, and a set saved with that clip keeps
  referencing it, so the folder is append-only for as long as Seshat cannot
  know which sets reference which files. Names are unique
  (`<slug>-<utc-timestamp>-<seed>.wav`), so a variation never overwrites its
  source. The tool description tells the model to mention *Collect All and Save*
  when the user is about to move or share the project; a cleanup story is out
  of scope and goes to the roadmap.
- **Key is a soft prior, reported as such.** The root note and scale name are
  appended to the prompt as text when the mirror has them, and the reply says
  the key was *requested*, not that it was verified. No pitch check in v1
  (roadmap: "report best-effort, do not contract it").
- **Quality is one enum, not a model name.** `quality: "fast" | "best"` maps to
  `sm-music`/`same-s` and `medium`/`same-l`. `sm-sfx` is not exposed: the
  material this tool serves is musical loops, and the description already
  routes sound-effect requests to `fast` with an explicit prompt. The listening
  gate (Live verification) decides whether `best` stays.

## OSC contract

Every address checked against [priv/AbletonOSC/API.md](../priv/AbletonOSC/API.md)
at fork pin `bc171b7` on 2026-08-28. One address is new and belongs to the fork
commit in Part 1; every other row already exists and is already in use
elsewhere in `Handlers` or `Registry`.

### New — fork extension in `abletonosc/clip_slot.py`

| Address | Request | Reply | Notes |
|---|---|---|---|
| `/live/clip_slot/create_audio_clip` | `track_index, clip_index, path` (`i i s`) | `track_index, clip_index, "ok", length` on success; `track_index, clip_index, "error", message` on a refusal | **Seshat extension.** Imports the WAV at `path` into the slot via `ClipSlot.create_audio_clip`. `length` is `clip.length` in beats read immediately after the call. Refuses, with a message and **without touching Live**, when: `path` is not an absolute path under `IMPORT_ROOT` (`~/.seshat/generated`, derived with `expanduser` + `abspath` exactly as `browser.py`'s `EXPORT_ROOT`, never `realpath`); the file does not exist or is not a regular file; the slot already holds a clip (`clip_slot.has_clip`). A bad track or slot index raises in `create_clip_slot_callback`'s lookup before the callee runs and answers on the structured `/live/error` envelope like every other clip-slot address; Live raising *inside* `create_audio_clip` (unreadable file, unsupported format) is caught and answered as the `"error"` triple carrying `str(exception)` so the reply is ours rather than a bare traceback. |

The ok/error triple is the shape the fork's other Seshat handlers already use
(`/live/return_track/get/*`, `/live/browser/load_item`), chosen over the generic
`_call_method` loop for the two reasons above: the path guard, and a reply.

### Existing — used by the new handler clause, all upstream unless noted

| Address | Request | Reply | Used for |
|---|---|---|---|
| `/live/clip_slot/get/has_clip` | `track_index, clip_index` | `track_index, clip_index, has_clip` (bool or 0/1) | The pre-generation occupancy check on an explicit slot, and the "first empty slot" scan when `clip_slot` is omitted (one `query_batch/2` over slots `0..min(num_scenes, 64)-1`, echo-matched per entry) |
| `/live/song/get/num_scenes` | — | `num_scenes` | Bounds the scan above |
| `/live/track/get/has_midi_input` | `track_id` | `track_id, has_midi_input` | Refuse a MIDI track by name before generating (`ensure_midi_track/1`'s inverse; an audio track is `false`) |
| `/live/track/get/is_foldable` | `track_id` | `track_id, is_foldable` | Refuse a group track — it has no slots of its own (same reason `ensure_not_group_track/1` exists) |
| `/live/song/create_audio_track` | `index` (−1) | — | New-track path, via the existing `Registry` `:create_track` command (count-before/after verified, then `/live/track/set/name`) |
| `/live/track/set/name` | `track_id, name` | — | Same command |
| `/live/clip/set/name` | `track_id, clip_id, name` | — | Names the imported clip (existing `maybe_name_clip/3`) |
| `/live/clip/get/name`, `/live/clip/get/length`, `/live/clip/get/looping`, `/live/clip/get/warping`, `/live/clip/get/file_path` | `track_id, clip_id` | `track_id, clip_id, value` | One `query_batch/2` read-back after the import; the reply is written from these, not from the request |
| `/live/clip/set/looping` | `track_id, clip_id, 1` | — | Only if the read-back shows looping off (⚠️ see Open questions — the default state of an imported clip is unmeasured); followed by a second `get/looping` read so the reply reports what was observed |
| `/live/view/set/selected_clip`, `/live/view/set/detail_clip` | `track_index, clip_index` | — | Follow cam (Seshat view extensions, already used by `write_midi_notes`) — after `generate_audio` joins `FollowCam`'s slot-steering list |

Tempo, time signature, root note and scale name are read from
`Seshat.Session.State.snapshot/0`, not queried — they are listened-to
properties and the mirror is the documented source for them.

## Numbered parts

### 1. Fork half — `/live/clip_slot/create_audio_clip`

Files (in the standalone clone `/Users/patrick/ableton-osc`, **never in
`priv/AbletonOSC`**): `abletonosc/clip_slot.py`, `API.md`, `SESHAT.md`,
`FORK_GAPS.md`.

- In `clip_slot.py`, beside the existing `clip_slot_get_clip` extension, add
  `IMPORT_ROOT = os.path.abspath(os.path.expanduser("~/.seshat/generated"))`
  with the same "not `realpath`" comment `browser.py` carries for
  `EXPORT_ROOT`, and a `create_audio_clip_in_slot(clip_slot, args)` callee
  registered through `create_clip_slot_callback` so index resolution and the
  `(track_index, clip_index, *rv)` echo are inherited. The callee:
  1. takes `path = str(args[0])`; refuses with `("error", "…")` when
     `os.path.abspath(path)` is not under `IMPORT_ROOT + os.sep`, or
     `os.path.isfile(path)` is false — naming the root in the message;
  2. refuses when `clip_slot.has_clip` — message names the slot and says
     nothing was imported;
  3. calls `clip_slot.create_audio_clip(path)` inside `try`/`except Exception`
     → `("error", str(e))`;
  4. returns `("ok", float(clip_slot.clip.length))`.
  Log every branch at `info` with a `clip_slot` prefix like the neighbours, so
  the no-probe log-reading rig in `API.md` can see it.
- `API.md`: a row in the Clip Slot table (the one above, verbatim), plus a note
  under "Object-valued reads"/"Queries that raise" that the path guard is a
  refusal with a reply, not a raise. `SESHAT.md`: add the address to the
  `clip_slot.py` divergence list. `FORK_GAPS.md`: strike
  `ClipSlot.create_audio_clip` from the ClipSlot table (keep `Track.create_audio_clip`
  and `SimplerDevice.replace_sample`, which stay gaps).
- Commit, merge to `origin/master`, then in Seshat advance the gitlink and
  commit the pin bump. `test/seshat/osc/vendored_addresses_test.exs` is the
  tripwire in both directions: the address `lib/` sends must be registered in
  Python and documented in `API.md`.
- **Puts on the user:** `mix abletonosc.install` and a Live restart before
  anything below can import. Say so in the PR.

### 2. Backend behaviour and the Stable Audio adapter — `lib/seshat/generation/`

Files: `lib/seshat/generation/backend.ex` (new), `lib/seshat/generation/spec.ex`
(new), `lib/seshat/generation/stable_audio.ex` (new), `config/config.exs`,
`config/test.exs`, `test/support/fake_generator.ex` (new).

- `Seshat.Generation.Spec`: a struct — `prompt`, `negative_prompt` (nil),
  `seconds` (float), `seed` (int), `quality` (`:fast | :best`), `init_audio`
  (path or nil), `init_noise_level` (float or nil), `out_path`. Pure; carries
  no Live knowledge.
- `Seshat.Generation.Backend`: `@callback generate(Spec.t()) :: {:ok, %{path:
  String.t(), seconds: float(), seed: integer(), wall_ms: non_neg_integer()}} |
  {:error, String.t()}`. The active module comes from
  `Application.get_env(:seshat, :audio_backend, Seshat.Generation.StableAudio)`;
  `config/test.exs` sets `Seshat.Test.FakeGenerator`, which writes an empty
  file at `out_path` and returns ok, or an error when the prompt contains a
  sentinel — the same trick `FakeAXClient` uses.
- `Seshat.Generation.StableAudio`, the **second and last allowed process door**:
  - `runtime_dir/0` from `:sa3_dir` (default
    `~/.seshat/stable-audio-3/optimized/mlx`, `Path.expand/1`);
    `python = Path.join(dir, ".venv/bin/python")`, script
    `scripts/sa3_mlx.py`.
  - `argv/1` (pure, tested): `["scripts/sa3_mlx.py", "--prompt", p, "--dit",
    dit, "--decoder", dec, "--seconds", fmt(seconds), "--steps", "8", "--seed",
    to_string(seed), "--out", out_path]` plus `--negative-prompt`,
    `--init-audio`, `--init-noise-level` when set. `--dit`/`--decoder`/`--prompt`
    are **always** present (the interactive fallbacks above). `fast` →
    `sm-music`/`same-s`, `best` → `medium`/`same-l`.
  - `preflight/1` (pure over `File.exists?`): python binary, script, and the
    weight files the run needs — `models/mlx/t5gemma_f16.npz`, the DiT for the
    quality (`dit_sm-music_f16.npz` / `dit_medium_f16.npz`), the decoder
    (`same_s_decoder_f32.npz` / `same_l_decoder_f32.npz`), plus the matching
    encoder (`same_s_encoder_f32.npz` / `same_l_encoder_f32.npz`) when
    `init_audio` is set. `File.exists?/1` follows the symlinks into the HF
    cache, so a dangling link reads missing. A miss returns an install-hint
    error naming the missing file and the runtime's `install.sh` — a tool call
    never starts an 8 GB download.
  - `generate/1`: `Port.open({:spawn_executable, python}, [:binary,
    :exit_status, :hide, :stderr_to_stdout, {:cd, dir}, {:args, argv}])`, an
    argv list and never a shell (a prompt is user text). Collect output up to a
    64 KiB cap, wait for `{:exit_status, n}` under `@generate_timeout` 60_000
    (overridable via `:audio_generate_timeout` for the suite, as
    `:ax_call_timeout` is). Exit 0 **and** `File.regular?(out_path)` → ok;
    otherwise `{:error, …}` carrying the last ~600 bytes of output, trimmed of
    ANSI escapes (the script colours its output). Timeout → `Port.close/1`
    then `{:error, "…gave up after 60s; nothing was imported"}` — and note that
    the Python child may outlive the port; kill it via the OS pid from
    `Port.info(port, :os_pid)` before closing, since a runaway MLX process
    holding several GB is worse than the timeout.
  - Every call logs wall-clock and quality at `info`, for the same reason
    `AX.Client` does: the CLI-per-call decision stays measurable.
- **Widen the boundary test** in `test/seshat/ax/client_test.exs`: the
  allow-list becomes `["lib/seshat/ax/client.ex",
  "lib/seshat/generation/stable_audio.ex"]`, the failure message names both
  doors and what each is for, and the describe's comment records that the
  second was added on purpose here (date, this plan). Do not move the test.

### 3. Domain operation — `lib/seshat/generation/audio_clip.ex`

File: `lib/seshat/generation/audio_clip.ex` (new). This is where the workflow
lives; `Handlers` validates, dispatches and formats.

`AudioClip.run(params, snapshot)` returns a result struct the handler renders.
Steps, in order, each a named private function so the tests can pin them:

1. **Resolve timing.** From `snapshot`: `tempo`, `signature_numerator`,
   `signature_denominator`. Any `nil` → `{:error, :unknown_timing}` (the handler
   says the tempo or time signature could not be read and routes to
   `get_session_state refresh: true`). `beats = bars * numerator * 4 /
   denominator`; `seconds = beats * 60 / tempo`, rounded to 3 decimals as the
   spike did (10.667 for 4 bars at 90). Pure, tested for 4/4, 3/4, 6/8, 7/8.
2. **Build the prompt.** `"<description>, <tempo rounded to int> BPM, <bars>
   bars, seamless loop"`, plus `", key of <Pitch name of root_note> <scale
   name>"` when both are known — the shape the spike and gary4live use.
   `negative_prompt` passes through. Pure, tested.
3. **Resolve the target.** Three cases:
   - `track` omitted → `{:new_track, name}` where `name` is `track_name` or a
     derivation from the description (first three words, title-cased); the
     slot is 0.
   - `track` given, `clip_slot` given → read `has_clip`; occupied → refuse
     before generating, naming the first empty slot found by the scan below
     (or "no empty slot; create_scene first").
   - `track` given, `clip_slot` omitted → `has_midi_input`/`is_foldable`
     guards, then the `has_clip` scan (one `query_batch/2`); first `false`
     wins; none → the same refusal.
   Every read is echo-checked (`query_echoed/4` or per-entry batch matching)
   and a stale reply reissues once — the `ensure_clip/4` pattern.
4. **Resolve the variation source**, when `variation_of` is given: read
   `/live/clip/get/file_path` and `/live/clip/get/is_audio_clip` for that slot
   in one batch; a MIDI clip or an empty path refuses by name. The path is
   handed to the runtime as `--init-audio` and never to the fork. `strength`
   (0.0–1.0, default 0.6) becomes `init_noise_level = max(0.01, strength)`
   (the runtime's floor).
5. **Generate.** `out_path = Path.join(generated_dir(), "#{slug}-#{ts}-#{seed}.wav")`
   with `generated_dir/0` from `:generated_dir` (default `~/.seshat/generated`,
   created with `File.mkdir_p!/1`), `slug` the first 40 chars of the
   description lower-cased with non-alphanumerics collapsed to `-`, `ts` a
   compact UTC timestamp, `seed` the caller's or `:rand.uniform(2**31 - 1)`.
   Call the backend. Error → return it; nothing in Live has changed.
6. **Create the track** (new-track case) via `Registry.execute(%Command{command:
   :create_track, track_type: :audio, name: name})`, which already verifies the
   count rose by one and names the track.
7. **Import.** `Transport.query("/live/clip_slot/create_audio_clip", [track,
   slot, out_path], @import_timeout)` with `@import_timeout` 15_000 — Live has
   to read and analyse the file; the browser's 15 s is the precedent. Match the
   reply's echoed `[track, slot | _]` (stale → reissue once, as everywhere), then
   `["ok", length]` → continue; `["error", message]` → return the message
   verbatim as the fork's words; `{:error, {:live_error, m}}` → describe.
8. **Name, read back, steer.** `maybe_name_clip/3` with `name` or the slug;
   one `query_batch/2` for `name`, `length`, `looping`, `warping`, `file_path`;
   if `looping` reads false, send `/live/clip/set/looping 1` and read it once
   more; return everything observed. The handler calls
   `FollowCam.steer("generate_audio", %{track: track, slot: slot})` — the
   selected-clip + detail-clip pair shows the waveform.

The result struct carries: `form: :audio`, `track`, `track_created?`, `slot`,
`file`, `seconds`, `bars`, `tempo`, `key_requested` (string or nil),
`observed: %{name, length, looping, warping}` (values or `:unknown` per field),
`seed`, `quality`, `wall_ms`, and a list of `notes` (strings: "looping was off
after import and was switched on", "length read 15.98 beats against 16.0
requested", "warping reads off — the clip will not follow tempo changes").

### 4. Tool definition — `lib/seshat/tools/definitions.ex`

Append to `@tools` (undo-stepped like every OSC tool — the import is a Set
change and one `undo` must remove track and clip together):

```elixir
%{
  name: "generate_audio",
  description:
    "Generate a short audio loop from a description and import it into a Session clip " <>
      "slot in Ableton Live, at the set's current tempo and time signature. This is the " <>
      "way to create audio material — drum loops, basslines, pads, textures, one-shots; " <>
      "1–16 bars of one part, never a whole song. Runs a local model on this Mac (about " <>
      "1–4 seconds; other tool calls wait for it). Omit track to create a new audio track " <>
      "named track_name; give track (0-based) to use an existing audio track — MIDI and " <>
      "group tracks are refused. Omit clip_slot to use the track's first empty slot, so " <>
      "\"another take\" lands beside the one kept, never over it; an occupied slot is " <>
      "refused before anything is generated. For a variation of a clip already in the set " <>
      "(\"again, but darker\") pass variation_of with that clip's track and clip_slot and " <>
      "put the change in description; strength 0.3 keeps most of the source, 0.8 keeps " <>
      "little. The set's key and scale are added to the prompt as a hint when Live has " <>
      "them, but pitch is not verified — say the key was requested, not confirmed. Write " <>
      "description as a sound designer would: material, genre, feel, texture, what to " <>
      "leave out (\"no melody\"). Tempo and bar count are added automatically; do not " <>
      "repeat them. quality \"fast\" is the default and right for iteration; \"best\" is " <>
      "slower and heavier for a keeper. The reply states what was read back from Live " <>
      "(length in beats, looping, warping) and the WAV's path under Seshat's generated " <>
      "folder; the file stays there and the set references it, so mention Live's Collect " <>
      "All and Save before the user moves or shares the project. One call is one undo " <>
      "step — undo removes the clip and, if created here, the track. Use " <>
      "get_session_state first to resolve track names to indices and confirm the tempo.",
  parameters: %{
    type: "object",
    properties: %{
      "description" => %{type: "string", description: "What the loop should sound like — material, genre, feel, texture, exclusions. Tempo, bars and key are appended automatically."},
      "bars" => %{type: "integer", minimum: 1, maximum: 16, description: "Length in bars at the set's time signature. Default 4."},
      "track" => %{type: "integer", minimum: 0, description: "0-indexed existing audio track. Omit to create a new audio track."},
      "track_name" => %{type: "string", description: "Name for the new track when track is omitted (e.g. 'Drums'). Ignored when track is given."},
      "clip_slot" => %{type: "integer", minimum: 0, description: "0-indexed scene/slot on the track. Omit for the first empty slot."},
      "name" => %{type: "string", description: "Clip name. Defaults to a short form of the description."},
      "quality" => %{type: "string", enum: ["fast", "best"], description: "fast (default): ~1s, good for iteration. best: ~3s, higher fidelity."},
      "variation_of" => %{
        type: "object",
        properties: %{
          "track" => %{type: "integer", minimum: 0, description: "Track of the source audio clip"},
          "clip_slot" => %{type: "integer", minimum: 0, description: "Slot of the source audio clip"}
        },
        required: ["track", "clip_slot"],
        description: "An existing audio clip to make a variation of. The new clip still lands in an empty slot."
      },
      "strength" => %{type: "number", minimum: 0.0, maximum: 1.0, description: "How far the variation departs from its source: 0.3 close, 0.6 default, 0.8 loose. Only with variation_of."},
      "seed" => %{type: "integer", minimum: 0, description: "Fix to reproduce a result; omit for a fresh one. The reply reports the seed used."},
      "negative" => %{type: "string", description: "What to avoid (e.g. 'vocals, melody')."}
    },
    required: ["description"]
  }
}
```

Conditional rules JSON Schema cannot carry, preflighted in the handler before
any transport call (the `set_mixer` convention): `strength` without
`variation_of` is rejected by name; `track_name` with `track` is accepted and
ignored with a note; `clip_slot` without `track` is rejected ("a slot needs a
track; omit both to create a track").

Bookkeeping the gate asks for: 52 → 53 tools; add ~2.9 KB to the ~58.7 KB
`tools/list` (measure with `mcp_call.py stats` per
`docs/smoke_tests/auto/mcp-surface.md`); largest schema stays
`set_clip_properties` unless this one's nested `variation_of` pushes it past
3,585 bytes — record either way; near-neighbour names: `record_clip`
(captures live input; the description's first sentence separates them),
`write_midi_notes` (MIDI, not audio), `load_device`. No routing eval case
exists for generation yet — the fresh-conversation check is the
`conversation.md` citation below.

### 5. Handler clause — `lib/seshat/tools/handlers.ex`

- `defp do_call("generate_audio", params)` above the catch-all: preflight the
  conditional rules; `State.snapshot()`; `AudioClip.run(params, snapshot)`;
  render. Rendering is one function, `format_generation/1`, so its wording is
  pinned by tests:
  - ok: `Generated a 4-bar audio loop (7.742s at 124 BPM, 4/4) and imported it
    to track 3 'Drums' (created), clip slot 0, named 'dusty breakbeat'. Live
    reads it back as 16.0 beats, looping on, warping on. Key requested: F
    minor (not verified). File: ~/.seshat/generated/dusty-breakbeat-…-42.wav
    (seed 42, fast, 1.1s).` followed by each `notes` entry as its own sentence.
  - any `observed` field `:unknown` → "could not read back <field>" — never a
    default.
  - error before generation: the refusal, ending "nothing was generated and
    nothing in Live changed."
  - error after generation but before/at import: "The audio was generated
    (<path>) but not imported: <reason>." — the file is kept, the path is
    given, and if a track was created that is said too ("the new track
    'Drums' at index 3 is empty").
- Add `"generate_audio"` to `FollowCam`'s slot-steering tool list
  (`lib/seshat/tools/follow_cam.ex`, the `calls/2` clause that
  `write_midi_notes` uses) and to its test's list.
- Bump `assert length(tools) == 52` to `53` in
  `test/seshat/tools/definitions_test.exs`.

### 6. Configuration — `config/config.exs`, `config/test.exs`, `config/dev.exs`

- `config :seshat, :audio_backend, Seshat.Generation.StableAudio`,
  `:sa3_dir "~/.seshat/stable-audio-3/optimized/mlx"`,
  `:generated_dir "~/.seshat/generated"` in `config.exs` (the AX helper path
  precedent: a default in the module, an override in config).
- `test.exs`: `:audio_backend Seshat.Test.FakeGenerator`, `:generated_dir` a
  path under the test tmp dir (`System.tmp_dir!()`), `:audio_generate_timeout`
  small.
- `dev.exs`: no redirect — unlike the catalog, the generated folder must be
  the same one the fork's `IMPORT_ROOT` allows, in every environment.

### 7. Tests (see Testing)

Files: `test/seshat/generation/spec_test.exs`, `stable_audio_test.exs`,
`audio_clip_test.exs`, additions to `test/seshat/tools/handlers_test.exs`,
`definitions_test.exs`, `follow_cam_test.exs`, `ax/client_test.exs`,
`test/support/fake_generator.ex`.

The fake runtime for `stable_audio_test.exs` is **not a committed fixture
file** — `StableAudio` derives both the interpreter (`.venv/bin/python`) and
the script (`scripts/sa3_mlx.py`) from `:sa3_dir`, so a lone
`test/fixtures/fake_sa3.py` could never be reached by path. Instead each test
builds a throwaway runtime tree under the tmp dir, exactly as
`ax/client_test.exs` writes a shell script and points `:ax_helper_path` at
it: `.venv/bin/python` is an executable shell script standing in for the
interpreter (it ignores `$1`, the script path, writes a file at the `--out`
argument, honours `FAKE_SA3_EXIT` and `FAKE_SA3_SLEEP` env vars for the error
and timeout paths), `scripts/sa3_mlx.py` is an empty file, and
`models/mlx/` holds empty files under the seven weight names so `preflight/1`
passes; `Application.put_env(:seshat, :sa3_dir, tmp)` with `on_exit` cleanup.
(Review correction, 2026-08-28.)

### 8. Documentation and bookkeeping

- `README.md`: a "Generating audio" section — what the user installs
  (`optimized/mlx/install.sh -y --download sm-music,medium` in
  `~/.seshat/stable-audio-3`, ~8 GB), that Seshat ships none of the runtime or
  weights, the two licences (Stability AI Community License with its revenue
  threshold and Enterprise path; Gemma Terms for the text encoder), where the
  WAVs go and that they are never deleted, and that `mix abletonosc.install`
  plus a Live restart are required for the import address.
- `CLAUDE.md`: module map rows for `lib/seshat/generation/`; the "AX client is
  the one door" sentences become "two doors, both pinned by the same grep
  test"; `Seshat.Instructions` is **unchanged** (the guidance is all
  tool-specific, and the 2,048-character cap is scarce).
- The new smoke tests below are written into `docs/smoke_tests/` in this PR
  (this planning run was restricted to plan docs, so their text is in the
  plan; the implementer moves it into the files).
- `docs/ROADMAP.md`: nothing removed until `/ship`; add the follow-ups named
  in Out of scope.

## Testing

Everything here is pure or runs against `Seshat.Test.OSCSink`; nothing reaches
`Transport.query/3` against a live Ableton.

- **`Spec`/prompt/timing arithmetic** — seconds for 4/4, 3/4, 6/8 and 7/8 at
  three tempos (pin `4 bars @ 90 BPM 4/4 = 10.667`, the spike's number);
  prompt assembly with and without key; slug and filename uniqueness (two
  calls in the same second differ by seed).
- **`StableAudio.argv/1`** — always carries `--prompt`, `--dit`, `--decoder`;
  quality mapping; `--init-audio`/`--init-noise-level` only with a source;
  noise-level floor at 0.01; `preflight/1` names the first missing weight and
  never spawns.
- **`StableAudio.generate/1` against the throwaway runtime tree of Part 7**
  (the process door is real here, on purpose): exit 0 with a file → ok with the
  path; exit 1 → error carrying the fixture's stderr, ANSI stripped; exit 0
  with no file → error; sleep past a 200 ms `:audio_generate_timeout` → the
  timeout error, and the child is gone (`os_pid` no longer alive).
- **The boundary test** lists exactly two files and fails on a third (add a
  temporary offender in a tmp `lib/` copy? No — assert the allow-list contents
  and keep the existing offender scan as is).
- **`AudioClip.run/2` with `FakeGenerator` over `OSCSink`**: the happy path's
  wire order (occupancy read, *then* the generator runs, *then*
  `create_audio_track`/`set/name`, `create_audio_clip [t, s, path]`,
  `clip/set/name`, the read-back batch). The `begin_undo_step`/`end_undo_step`
  pair is sent by `Handlers.call/2`, not by `AudioClip.run/2`, so the one
  test that asserts the full bracket drives `Handlers.call("generate_audio",
  …)` and checks the pair is outermost (review correction, 2026-08-28);
  explicit occupied
  slot → refusal and **zero** generator calls (`FakeGenerator` counts);
  omitted slot → first `false` in the scan wins; MIDI/group track refusals;
  `unknown_timing` on a `nil` tempo; the fork's `"error"` triple rendered
  verbatim; a stale `create_audio_clip` echo reissued once then reported;
  `looping` false → `set/looping 1` sent and re-read; generator error → no
  datagram after the occupancy read.
- **`Handlers` rendering** — the six wording cases in Part 5, including the
  "generated but not imported" sentence carrying the path.
- **`Definitions`/`Validation`** — the conditional-rule rejections; `bars`
  bounds; `strength` bounds; the count bump; `MCP.ToolsTest` parity is
  automatic.
- **`FollowCam`** — `calls("generate_audio", %{track: t, slot: s})` equals the
  `write_midi_notes` pair.

## Live verification

Nothing in `mix test` reaches any of this. The fork address must be installed
(`mix abletonosc.install`) and Live restarted **before** `/smoke-test` runs;
against a stale copy every import "fails" with a Transport timeout, which is
the wrong result for the right reason. Write the four new tests into the files
named, then cite:

- `smoke_tests/auto/generation.md § A generated loop lands, reads back, and is
  bar-exact` — **new file, new test.** With Live at a known tempo and 4/4
  (`set_tempo 124`), `generate_audio description: "dusty breakbeat drum loop,
  no melody", bars: 4, track_name: "Gen Drums"` → a new audio track appears
  (`get_session_state`), `get_clip_properties` on its slot 0 reads `length
  16.0`, `looping` on, `is_audio_clip` true, and the reply's file path exists
  on disk with a duration of 7.742 s (`afinfo`). Boundary: `bars: 16` at 60 BPM
  (64 s of audio) still lands. Failure meaning: a length other than 16.0 means
  Live warped the file to something other than the bar count — the fixed-
  length rider in Open questions is needed; a missing track means the create
  ran but the import did not, and the reply must have said so.
- `smoke_tests/auto/generation.md § An occupied slot is refused before
  anything is generated` — **new.** Same track, `clip_slot: 0` again → refusal
  naming slot 1 as empty, the reply ending "nothing was generated"; the
  generated folder's file count is unchanged (`ls | wc -l` before and after).
  Then omit `clip_slot` → the clip lands in slot 1 and slot 0 is untouched
  (`get_clip_properties` name unchanged).
- `smoke_tests/auto/generation.md § The bridge refuses a path outside the
  managed folder` — **new.** `osc_send.py /live/clip_slot/create_audio_clip 0 3
  /etc/hosts` and `… ~/.seshat/audio-spike/drums_124bpm_sm-music.wav` (real WAV,
  wrong root): Live's `Log.txt` shows the refusal line for each, and
  `get_clip_slots` shows slot 3 still empty. Then the same file copied into
  `~/.seshat/generated/` imports. This is the only check of the guard, since
  the tool never sends a foreign path.
- `smoke_tests/auto/bridge.md § A bad index errors immediately, not after ~2s`
  — a new vendored address; run it with `track: 99` on the new address via
  `osc_send.py` and confirm the structured `/live/error` in the log rather than
  silence.
- `smoke_tests/auto/mcp-surface.md § The surface budget is measured, not
  guessed` — 53 tools; record count, bytes and the largest schema.
- `smoke_tests/manual/by-ear.md § A generated loop sits on the grid and seams
  cleanly` — **new, the listening gate the roadmap leaves open.** *Why manual:
  the assertion is a sound.* Generate a four-bar drum loop at 124 BPM on an
  empty set with the metronome on; play it looping. The first hit lands on the
  downbeat with the click; the loop point has no click, gap or doubled hit;
  the same prompt at `quality: "best"` is audibly different in a way worth
  three extra seconds, or it is not and `best` comes off the enum. Repeat for a
  bass loop with the set in F minor and judge whether it sits in key. Failure
  meaning: a late first hit is a prompt-idiom or model problem, not an import
  one — the fix is the prompt template in `AudioClip`, or a downbeat trim the
  roadmap deliberately did not build.
- `smoke_tests/manual/conversation.md § A generation request routes to one
  call and names the form` — **new.** A fresh Claude Desktop conversation: "give
  me a four-bar dusty lo-fi drum loop on a new track" → exactly one
  `generate_audio` call (not `create_track` then something), the reply says
  *audio*, names the track and slot in music terms, and does not read the
  file path aloud unless asked; "another take, darker" → one call with
  `variation_of` or a fresh description on the same track, landing in the next
  slot.

**Uncovered:** what Live does with a set saved while the WAV sits in
`~/.seshat/generated/` after the folder is moved (a person, a second machine);
a `medium` generation on a memory-starved Mac (no such machine here); the
60-second timeout path against the real runtime (cannot be provoked on
demand); tempo changes *after* import following the clip (needs warping on,
which is itself unmeasured — Open questions).

## Out of scope

- **Slice to New MIDI Track / Extract Groove on the result** — UI-only, gated
  on the AX spike ("Live-native generation spike — can AX drive the Create
  menu?"). Its own item once that spike reports.
- **Cloud contingencies** (Stable Audio 2.5 API, ElevenLabs) — the `Backend`
  behaviour leaves the seam; nothing is wired.
- **A file-import tool** ("put this WAV in a slot") — no user story; the fork
  address exists for Seshat's own files only, and its root guard says so.
- **Generated-folder lifecycle** — never deleted in v1. Roadmap: "Managed
  generated-audio folder: reference tracking and cleanup" (needs a way to know
  which sets reference a file; Live's Collect All and Save is the manual
  answer meanwhile).
- **Arrangement placement** — Session-first, per the user-stories doc.
- **Pitch verification of the key hint** — reported as requested, not
  confirmed. Reopen if the listening gate finds key adherence poor enough to
  matter.
- **`sm-sfx` and inpainting** — `--inpaint-range` is a region edit with no
  producer story yet; SFX material is reachable through `fast` with a prompt.
- **A routing-eval case** for generation — belongs to "Routing evals — general
  corpus and client-realism lane"; the conversation check above stands in.

## Open questions

The installed Remote Scripts copy could not be patched from this planning run
(it is outside the repository, and the rig in `API.md` asks before writing
into the user's Remote Scripts), so no probe ran even though Live 12.4.5 was
up. Each question below is answerable in minutes with that rig — a probe
handler in the installed `return_track.py`, `/live/api/reload`, the probe
address over `osc_send.py`, answers in `Log.txt`, then `mix abletonosc.install
--no-pull` to restore. **The implementer should run it before Part 3**, since
three of the five decide a line of code. Seshat was not running at the time
(nothing held UDP 11001), so the rig has the reply port free too.

1. ⚠️ **Does an imported clip come in warped and looping, with `length ==
   bars × beats` at the set's tempo?** Unmeasured. Live's behaviour for a
   short file dropped into a slot is governed by the "Auto-Warp Long Samples"
   preference and its loop detection, neither of which the LOM exposes. *Plan
   assumes* the read-back reports whatever Live did and switches `looping` on
   if it read off; it does **not** set `loop_end` or `warping`. If the probe
   shows `length` ≠ bar count (e.g. the file is un-warped and reads as its
   sample length in beats at the current tempo — which for a bar-exact file at
   the same tempo still equals the bar count, so a mismatch would only show
   after a tempo change), add a rider: `set/warping 1` and `set/loop_end
   beats`, each read back. Measure: log `clip.length`, `looping`, `warping`,
   `loop_end`, `warp_mode` right after `create_audio_clip` at 124 BPM with the
   spike's `drums_124bpm_sm-music.wav`, then again after changing the tempo to
   100.
2. ⚠️ **What does `create_audio_clip` do on an occupied slot — raise or
   replace?** Unmeasured. Moot for the tool (the fork handler refuses on
   `has_clip` first) but the `API.md` row should say which, since it decides
   whether the guard is protecting the user's clip or just the reply. Measure
   in the same probe: call it twice on one slot inside `try`. The LOM
   reference (docs.cycling74.com/apiref/lom/clipslot, read 2026-08-28) names
   only two raise conditions — the slot not on an audio track, and a frozen
   track — and is silent on occupancy, so the probe still decides this.
3. **Does Live reference or copy the file? — Answered 2026-08-28: reference.**
   The LOM reference says `create_audio_clip(path)` "creates an audio clip
   that references the file in the clip slot", and SA3's own AudioInserter
   (`optimized/mlx/ableton/AudioInserter/AudioInserter.py:110–116`) copies to
   a timestamped unique path *before* importing precisely "so each generation
   is preserved independently". The plan's unique names and append-only folder
   stand; the probe's `clip.file_path` read is now confirmation, not a
   decision.
4. **Is the call synchronous for `length`? — Answered from prior art, 2026-08-28:
   yes, with one guard.** AudioInserter reads `slot.clip` on the line after
   `create_audio_clip`, returns an error if it is `None`, then logs
   `clip.length` and `clip.is_session_clip` — a shipped script that would fail
   visibly if either were asynchronous. The fork handler reads inline and
   keeps the same `None` guard (reply `"error", "clip is None after
   create_audio_clip"`).
5. **BPM adherence and loop-seam cleanliness by ear**, and whether `best` earns
   its place — the listening gate. **Partly measured 2026-08-28** (librosa
   onset detection on the twelve drum/bass spike WAVs, no ears): the first
   detected onset sits at 23 ms on every bass file and on two drum files, but
   at **174–488 ms on four of the six drum files** (`drums_124bpm_medium` 221,
   `drums_90bpm_medium` 209, `drums_170bpm_sm-music` 174, `drums_90bpm_sm-music`
   488) — the render is bar-exact in length but the first hit is not
   reliably on the one. And every drum file ends near-silent (RMS over the last
   50 ms 0.000–0.041 against 0.30–0.50 at the start), so a looped drum render
   will show a gap or a dropped hit at the seam rather than a click. Neither
   is a code change in this plan — the description should tell the model the
   downbeat is best-effort, and the by-ear test should listen for the seam
   gap specifically. Needs a person with the set audible;
   `by-ear.md`'s new test is the record. *Plan assumes* both models ship; the
   enum shrinks to one value if `best` does not earn it, which is a one-line
   `Definitions` change and no handler change.
6. **The first-ever run after a reboot.** The spike's 4.1 s was a cold OS file
   cache, not a cold weight download. *Plan assumes* 60 s is a generous bound;
   if a real cold start on a slower disk exceeds it, raise
   `@generate_timeout`, do not add a sidecar.
