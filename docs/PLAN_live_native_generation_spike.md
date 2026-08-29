# Plan — Live-native generation spike: can AX drive the Create menu?

Roadmap item **"Live-native generation spike — can AX drive the Create
menu?"** A spike with a written result, not a tool. It answers, by
measurement against the running Live, whether Seshat can invoke Live's own
generation commands — **Separate Stems to New Audio Tracks**, **Convert
Drums / Melody / Harmony to New MIDI Track**, **Slice to New MIDI Track**,
**Extract Groove(s)**, **Bounce Track in Place / Bounce to New Track** —
through the named-AX rung, and what a *bounded* helper command for them would
look like. The deliverable is a "Measured" section replacing §4 of
[live-native-options.md](evaluating/generative%20features/live-native-options.md),
a per-command verdict of route / not-a-route / needs-its-own-item, and the
sketch of the command shape. Nothing ships to `lib/`, `native/seshat_ax/main.m`
or the fork.

**Acceptance.** The result section records, for Live 12.4.5 Suite on macOS
15.7.4: which of the eight commands were pressed and what each produced (tracks,
clips, notes, grooves), how long each took, whether any raised a dialog and
which mechanism saw it, how the structural push and `num_tracks` reported
completion, and whether one `undo` reverts the whole result. Every unpressed
command carries the reason. "Could not tell" is an acceptable per-command
answer; a section that reads as complete while a command went unmeasured is
not.

## Context

The generation research
([midi-generation-options.md](evaluating/generative%20features/midi-generation-options.md),
[live-native-options.md](evaluating/generative%20features/live-native-options.md))
spent a week surveying separators and transcribers before noticing Live Suite
ships both. Five of those commands are UI-only — absent from Live 12.4.3's
`_MxDCore/LomTypes.pyc` at any spelling, and still absent from the fork's
`application.py` — so the only route is the macOS Accessibility rung, which
has been validated once (the Audio Settings popup, 2026-08-03) and never
against a menu command. Until it is measured, the MIDI decision experiment
(roadmap #3) cannot fix its arms: joint Route C "uses Live Stem Separation or
does not run", and Convert Drums is the zero-licence floor for drum
transcription. This item is the gate.

**What planning measured today (2026-08-28, Live 12.4.5 Suite, macOS 15.7.4,
Seshat stopped, UDP 11001 free).** These close half the roadmap entry's
questions before the spike runs; the rest need a press, which this run did
not do.

- **Every target command is in the menu bar, enumerable by name, with
  `AXPress` advertised.** A read-only AX walk of Live's `AXMenuBar` (the
  trusted 2026-08-03 `_build/ax-spike/ax-probe --dump-menu`, then a fresh
  scratch probe) found, under **Create**: `Slice to New MIDI Track`,
  `Convert Harmony to New MIDI Track`, `Convert Melody to New MIDI Track`,
  `Convert Drums to New MIDI Track`, `Separate Stems to New Audio Tracks`
  (the menu title — not "Stem Separation"); under **Edit**: `Freeze Track`,
  `Bounce Track in Place`, `Bounce to New Track`, `Paste Bounced Audio`,
  `Extract Groove(s)`. Each is an `AXMenuItem` with `identifier=
  menuItemWasSelected:` and actions `AXCancel, AXPress, AXPick`. **The clip
  context menu is therefore not needed** and the spike does not open one
  unless a menu-bar press fails to act.
- **`AXEnabled` reads correctly, and reads while Live is *inactive*.** The
  menu bar is exposed with Live behind another application (`active=false`,
  zero AX windows, menu bar AX error 0), and enabled state tracks the
  selection: with nothing selected, all five Create commands, `Extract
  Groove(s)`, `Bounce to New Track` and `Consolidate` read `enabled=false`
  while `Bounce Track in Place` and `Freeze Track` read `true` (a track is
  always selected).
- **Selection set over OSC flips the enabled state, with Live still
  inactive.** Creating a 4-beat MIDI clip at slot (0, 0) via
  `/live/clip_slot/create_clip 0 0 4.0` and selecting it with
  `/live/view/set/selected_clip 0 0` turned `Extract Groove(s)` and `Bounce
  to New Track` to `enabled=true`; `Slice`, the three `Convert`s and
  `Separate Stems` stayed `false` — they want an *audio* clip. The clip was
  deleted afterwards and the set read back as found (one track, `1-MIDI`,
  slot empty). So the spike's mechanism is settled: **select over OSC, read
  enabled over AX, press over AX, observe completion over OSC.**
- **The Edit menu's first item names the top of Live's undo history**
  (`Undo Change "Track Panning"`; after `/live/song/begin_undo_step`, `Undo
  Custom Action`). A free AX read of what one `undo` would revert — a side
  finding worth its own roadmap note, not this item's.
- **A scratch, never-approved probe built to the scratchpad reported
  `AXIsProcessTrusted() == true`** from this terminal — the fourth
  observation of README's open question about what macOS keys the grant on.
  `~/.seshat/bin/seshat-ax` is *not* installed on this machine (the
  directory does not exist); the spike does not need it.
- **Every command that produces tracks lands as a structural push.** The
  fork's `song_structure.py` pushes `/live/song/get/tracks` (the ordered name
  tuple) on every add/delete/reorder, and `num_tracks` is queryable; that is
  the completion signal, no AX polling of a progress bar.
- **The dialog members are a fork gap, not a Live limit.**
  `Application.open_dialog_count`, `current_dialog_message`,
  `current_dialog_button_count`, `press_current_dialog_button` are in the
  installed LOM and in no fork handler (`FORK_GAPS.md` § Application dialog
  members). The spike reads them through the temporary probe-handler rig
  rather than adding them to the fork.

Two facts about the material: the SA3 slate at `~/.seshat/audio-spike/`
holds 24 bar-exact renders (`drums_124bpm_sm-music.wav` et al., ~1.3 MB,
2026-08-25) plus `interlock/B_joint_seed42.wav` — the joint rhythm-section
render that is exactly Stem Separation's input. And the set currently open
in Live is a scratch set (one MIDI track), so the spike can run in it.

### Architectural decisions

- **A spike, not a tool, and not a helper change.** `main.m` stays a closed
  four-command protocol. The probe is a separate, read-mostly program whose
  *only* mutating verb presses one of an allowlisted set of menu titles. It
  is built by hand to `_build/ax-spike/`, never installed, never called from
  `lib/`. Its source is committed at `native/seshat_ax/probe/menu_probe.m`
  so the measurement is reproducible — the 2026-08-03 `ax-probe`'s source
  was never kept, and only its binary survives.
- **Import by hand, not through the audio plan.**
  [PLAN_generate_audio_clip.md](archive/PLAN_generate_audio_clip.md) Part 1 adds
  `/live/clip_slot/create_audio_clip`, which would import the render over
  OSC. The spike does not depend on it: dragging a WAV from Finder into a
  slot is a ten-second action, and gating a one-afternoon spike on a fork
  commit and a Live restart inverts the priorities. If Part 1 has landed by
  then, use it — it is also how the eventual feature will import — and say so
  in the result.
- **Completion is OSC-side, never AX-side.** A press returns immediately;
  the result is read from `num_tracks`, the `tracks` push, `get_clip_notes`
  on the new track, and Live's `Log.txt`. The spike never polls a progress
  bar or a window title.
- **Dialogs are read through the LOM, pressed through the LOM, and only
  for the commands' own mode choosers.** `press_current_dialog_button` is
  reached through the probe-handler rig, and only after
  `current_dialog_message` has been logged and read by a person or agent.
  Never on a file-lifecycle dialog.
- **Every press is bracketed by a count and an undo step.** Track count
  before, `/live/song/begin_undo_step`, press, wait for the count to rise,
  read, `end_undo_step`, then one `/live/song/undo` and a second count —
  measuring both the result and whether a UI-originated command folds into
  Seshat's undo step at all.
- **Route verdicts are decided by three properties, stated up front:**
  reachable (press acts, result appears), observable (completion and content
  readable over OSC), and bounded (no dialog, or a dialog the LOM can drive
  by button index). A command missing any one is "needs-its-own-item"; a
  command whose press does nothing from the menu bar is "not-a-route".

## OSC contract

Every address checked against [priv/AbletonOSC/API.md](../priv/AbletonOSC/API.md)
at fork pin `bc171b7` on 2026-08-28. No address is new; nothing here changes
the fork. Sent from a plain UDP socket bound to `127.0.0.1:11001` (Seshat
stopped — the spike must not share the reply port with a running server;
`lsof -nP -i :11001` first).

| Address | Request | Reply | Used for |
|---|---|---|---|
| `/live/song/get/num_tracks` | — | `num_tracks` | Count before and after every press; the completion poll |
| `/live/song/get/track_names` | `[index_min, index_max]` (optional) | `name0, name1, …` | What the command created, by name |
| `/live/song/start_listen/tracks` | — | pushes `/live/song/get/tracks` `name0, …` on every structural change | The push a tool would use as its completion signal; the spike records how many pushes one command produces and how long after the press |
| `/live/song/stop_listen/tracks` | — | — | Unsubscribe at the end (Seshat is not running, so this is the spike's own subscription) |
| `/live/clip_slot/get/has_clip` | `track_index, clip_index` | `track_index, clip_index, has_clip` | Where the imported clip and the results landed |
| `/live/clip/get/is_audio_clip` | `track_id, clip_id` | `track_id, clip_id, is_audio_clip` | Result clip kind (stems are audio; converts are MIDI) |
| `/live/clip/get/length`, `/live/clip/get/name`, `/live/clip/get/file_path` | `track_id, clip_id` | `track_id, clip_id, value` | Result clip identity; `file_path` on a stem tells where Live wrote it |
| `/live/clip/get/notes` | `track_id, clip_id` (the four range args are optional and all-or-nothing; the spike sends none) | `track_id, clip_id, (pitch, start, duration, velocity, mute)*` | Convert Drums' lane count (distinct pitches) and velocity spread |
| `/live/track/get/devices/name` | `track_id` | `track_id, name*` | The rack Live put on a converted track |
| `/live/song/set/tempo` | `tempo_bpm` | — | Set-up only: 124 so the imported renders read as 4 bars |
| `/live/view/set/selected_clip` | `track_index, scene_index` | — | Arm the command (measured: flips `AXEnabled` while Live is inactive) |
| `/live/view/set/selected_track` | `track_index` | — | Arm the track-scoped commands (`Bounce Track in Place`, `Freeze Track`) |
| `/live/view/get/selected_clip` | — | `track_index, scene_index` | Restore the selection afterwards |
| `/live/song/begin_undo_step`, `/live/song/end_undo_step` | — | — | ⚠️ Seshat fork additions. Bracket each press to measure whether a UI command folds into an explicit step |
| `/live/song/undo` | — | — | The one-undo test; `num_tracks` afterwards says whether the whole result went |
| `/live/song/get/can_undo` | — | `can_undo` | Guard the undo, as the `undo` tool does |
| `/live/api/reload` | — | — | Load the temporary dialog probe handler (rig, `API.md` § Measuring the Live API) |

Dialog members (`open_dialog_count`, `current_dialog_message`,
`current_dialog_button_count`, `press_current_dialog_button`) have **no
address** — they are read by the temporary probe handler and logged to
`Log.txt`, exactly as the rig prescribes. If the spike finds them
load-bearing, the follow-up is the fork gap entry, not this plan.

## AX contract

The probe's bounded path, all measured today except the press:

1. `NSRunningApplication` by bundle identifier `com.ableton.live`; remember
   the previous frontmost application.
2. `AXMenuBar` of the application element — readable while Live is inactive.
3. Locate `AXMenuBarItem` titled `Create` (or `Edit`), then the `AXMenuItem`
   whose `AXTitle` equals the requested title exactly; depth 4, no sibling
   order, no coordinates.
4. Read `AXEnabled`. A `false` is a refusal with the title and the current
   selection in the reply — never a press.
5. **For a press only:** activate Live and wait for `NSRunningApplication.active`
   *on a runloop* (the 2026-08-27 lesson — sleeping never sees the
   notification), re-locate the item, `AXUIElementPerformAction(kAXPressAction)`,
   record the `AXError`, restore the previously frontmost application, and
   wait for that restore before returning.
6. Additionally record, once per press, `AXWindows` after ~200 ms — whether a
   dialog appears as an AX window, and its title, so the result can say which
   mechanism (LOM count or AX window) sees a mode chooser first.

Titles are the English Live 12.4.5 labels above. `Separate Stems to New Audio
Tracks` is the menu title; the doc's "Stem Separation" is the marketing name.

## Numbered parts

### 1. The probe — `native/seshat_ax/probe/menu_probe.m`

One Objective-C file, compiled by hand:

```
/usr/bin/clang -fobjc-arc -Wall -Wextra -Werror -O2 \
  -framework AppKit -framework ApplicationServices \
  -o _build/ax-spike/menu-probe native/seshat_ax/probe/menu_probe.m
```

Commands, all printing plain text (this is a probe, not the JSON protocol):

- `menu-probe list` — the Create and Edit menus with `title | enabled |
  shortcut | submenu-count` per item, plus `AXWindows` and the focused
  element. Read-only; what planning ran today.
- `menu-probe press "<title>"` — steps 4–6 above. The title must be one of
  the eight allowlisted strings compiled into the program (`Separate Stems to
  New Audio Tracks`, the three `Convert … to New MIDI Track`, `Slice to New
  MIDI Track`, `Extract Groove(s)`, `Bounce Track in Place`, `Bounce to New
  Track`); anything else exits 2 without touching AX. A disabled item exits 3
  and prints `disabled`. Prints the press `AXError`, elapsed ms, and the
  window list 200 ms later.

Not in the probe: `--dump` of the whole tree, keystrokes, coordinates, a
generic press. The `mix ax.install` task and the CI build ignore
`native/seshat_ax/probe/`; a comment at the top says so and points at this
plan. `test/seshat/ax/client_test.exs`'s grep is over `lib/`, so a file under
`native/` needs no exemption.

### 2. The dialog rig — temporary handler in the installed `return_track.py`

Per `API.md` § Measuring the Live API. Add to
`~/Music/Ableton/User Library/Remote Scripts/AbletonOSC/abletonosc/return_track.py`
(never the repo) three probe addresses:

- `/live/probe/dialog` — logs `open_dialog_count`,
  `current_dialog_message`, `current_dialog_button_count` under one greppable
  prefix, each in its own `try`/`except`.
- `/live/probe/dialog/press <index>` — calls
  `press_current_dialog_button(index)` **only if** `open_dialog_count > 0`
  and `current_dialog_message` does not contain `save`, `Save`, `discard` or
  `Discard`; logs what it pressed.
- `/live/probe/undo_top` — nothing in the LOM names the undo top; skip. (The
  AX `Edit > Undo …` title is the read, recorded in Part 3.)

`/live/api/reload` after editing; `mix abletonosc.install --no-pull` and a
second reload afterwards; confirm `/live/probe/dialog` then logs `Unknown OSC
address`. `API.md` § "Don't reach for `/live/api/reload`" records the
failure mode: if the re-import raises, every address answers `Unknown OSC
address` and reload has unregistered itself — recovery is toggling AbletonOSC
off and on under Preferences > Link/Tempo/MIDI > Control Surface, or a Live
restart. Check `/live/song/get/num_tracks` answers after each reload before
continuing. Record `wc -l Log.txt` before starting (5,761 lines at planning
time) so only the run's lines are read.

### 3. The run — one command at a time, in this order

Set-up: Seshat stopped; scratch set open; transport stopped;
`~/.seshat/audio-spike/drums_124bpm_sm-music.wav` dragged into slot (1, 0)
of a new audio track by hand (or imported via
`/live/clip_slot/create_audio_clip` if archive/PLAN_generate_audio_clip.md Part 1 has
landed), and `interlock/B_joint_seed42.wav` into slot (1, 1). Set tempo to
124 so the clips read as 4 bars. Subscribe with `start_listen/tracks` and
keep the receiving socket printing timestamps for the whole run.

For each command: select the input clip over OSC → `menu-probe list`
(record enabled) → `num_tracks` → `begin_undo_step` → `menu-probe press` →
poll `num_tracks` at 250 ms and log the `tracks` pushes until the count is
stable for 2 s or 5 min elapse → `/live/probe/dialog` at +0.5 s and on every
poll while the count has not moved → read the result → `end_undo_step` →
`can_undo` → `undo` → `num_tracks` → restore selection.

1. **`Convert Drums to New MIDI Track`** on the drums render. Read: track
   names, the new track's `devices/name` (expect a Drum Rack), `get/notes` on
   its slot — distinct pitches (lane count; the doc's ceiling claim is
   three), velocity min/max/distinct count (does it vary on SA3 material?),
   note count vs. the render's audible hits, elapsed to first and last push.
2. **`Convert Melody to New MIDI Track`** on `bass_124bpm_sm-music.wav`
   (import it into slot (1, 2) first). Note count and pitch range against
   Basic Pitch's 16 clean notes on the `medium` render.
3. **`Convert Harmony to New MIDI Track`** on `pad_124bpm_sm-music.wav`. The
   one A/B the doc asked for; polyphony (max simultaneous notes) is the
   number.
4. **`Slice to New MIDI Track`** on the drums render. **Expect a dialog**
   (slice-by, preset) — this is where the dialog rig earns its keep: log
   message and button count, press the default (index 0) only after the
   message is read. Result: slice count (`devices/name` shows a Drum Rack;
   `get/notes` count on the MIDI clip = slices).
5. **`Separate Stems to New Audio Tracks`** on the interlock render. Suite
   only — record `Licensing: BaseProduct=02, IsUnlocked?=true` from
   `Log.txt` as the edition evidence. Expect the longest run and possibly a
   dialog (stem selection / merge). Record wall time to the *last* push, how
   many tracks appeared and their names, whether the source track was muted,
   each stem clip's `file_path`, and whether Live's UI was blocked (a
   `num_tracks` query answered during the run says the Remote Script tick
   still runs). Then `Convert Drums` on the drum stem, in place, to prove the
   chain the doc calls joint C.
6. **`Extract Groove(s)`** on the drums render. No push expected — the groove
   goes to the Groove Pool, which has no address. Result is read by eye
   (pool entry name) and by `Edit > Undo …`'s title; the LOM gap
   (`Song.groove_pool.grooves`) is what a tool would read, and the result
   records that the *only* current read is visual.
7. **`Bounce to New Track`** on a MIDI clip (write four notes with
   `/live/clip/add/notes` onto `1-MIDI`'s slot 0, load an instrument by hand
   if the track has none). Expect a dialog or a render pass; record the new
   audio track and its clip's `file_path` — this is the render prerequisite
   §2.6 names.
8. **`Bounce Track in Place`** — read-only check of enabled state and the
   dialog, pressed only if 7 produced no dialog.

If the first press (step 1) does **nothing** — `AXError 0`, no push, no
dialog, count unchanged after 10 s — stop and diagnose before continuing:
re-run with Live already frontmost and the clip clicked by hand; then try
`AXPick`; then open the clip's context menu once (right-click by hand,
`menu-probe list` extended to `AXWindows` → `AXMenu`) to see whether the
context copy is a different element. That, and only that, is when the
context menu enters the spike.

### 4. The result — `docs/evaluating/generative features/live-native-options.md`

Replace **§4 "Unmeasured"** with **§4 "Measured — 2026-MM-DD, Live 12.4.5
Suite, macOS 15.7.4"**: the menu-enumeration facts from Context above (they
are already measured and can be written now), then one subsection per
command with elapsed, pushes (Seshat is stopped during the run, so "what
`Session.State` sees" is measured as the raw `/live/song/get/tracks` push the
mirror subscribes to — the result says so), dialog (which mechanism saw it, message,
buttons), result shape, undo behaviour, and the verdict line:

> **Verdict: route / not-a-route / needs-its-own-item** — reason.

Then a **"What a bounded helper command would look like"** subsection: the
shape this plan recommends is `seshat-ax run-command --title "<one of the
allowlist>"`, compiled allowlist, `AXEnabled` pre-check answering
`command_disabled` with the current selection, press, activation restore,
`{ok, title, ax_error, elapsed_ms}` — **and nothing about completion**,
which is the caller's OSC job. Whether the allowlist is one command per
Create item or one `run-command` with an enum is the tool-surface question
[tool-surface-scaling.md](evaluating/tool-surface-scaling.md) answers (one
intention, several targets), and the sketch should say so. Also record: the
dialog members' fork-gap entry becomes a prerequisite of any route that
raised one; `Application`'s dialog listener means the eventual tool can
mirror dialog presence rather than poll.

Update the sibling passages the same commit: `ui-scripting-options.md` §
"What UI scripting could buy" item 2 (menu-bar reachability is now
measured; drop "enumerable?"), and `midi-generation-options.md` § Open work's
first bullet (which arms exist). Add the Undo-title finding to `ROADMAP.md`
as a one-paragraph note under "Verify destructive mutations before reporting
success" — an AX read of what `undo` would revert is a cheap guard for that
item. Correct the "Stem Separation" name to the menu title wherever the doc
quotes it as a command.

### 5. Bookkeeping

- `CLAUDE.md` "Current focus": one paragraph — the spike ran, which arms
  exist, where the result lives.
- `ROADMAP.md`: remove this item via `/ship`; re-rank #3 "MIDI generation —
  the decision experiment" with its arm list fixed by the verdicts; file
  "needs-its-own-item" verdicts as new entries (likely: dialog members in the
  fork; `Clip.groove` / groove-pool read; a `run-command` helper verb).
- `priv/AbletonOSC/API.md`: measured facts about the rig that are *wire*
  facts (e.g. how many `tracks` pushes one Convert produces, and whether the
  Remote Script tick keeps answering during a Stem Separation run) go in the
  fork's doc via the standalone clone — doc-only, no pin bump needed.

## Testing

Nothing in `mix test` changes. The probe lives under `native/`, outside the
compile, the CI build, and `client_test.exs`'s `lib/` grep. If Part 1's file
is committed, `mix precommit` must still pass untouched — that is the whole
automated check, and it is deliberately empty.

## Live verification

Nothing in `mix test` reaches any of this; the spike *is* the live work, and
its result section is the record. No `docs/smoke_tests/` citation applies:
the change adds no tool, no address, no listener, no model-facing text and no
schema, so no row of `/smoke-write`'s table trips, and a spike with no
shipped behaviour has no regression surface to write a test for. Two existing
manual tests are worth running *afterwards* only to confirm the rig was
removed cleanly:

- `smoke_tests/manual/engineered-state.md § A stale install is distinguishable
  from a broken tool` — after `mix abletonosc.install --no-pull` restores the
  probe-free handler.
- `smoke_tests/manual/on-screen.md § The listener rebind, by hand in Live's
  UI` — the spike deletes tracks by `undo` under a running `tracks`
  subscription; this confirms the fork's `_stop_listen` fix still holds in
  the set afterwards.

**Uncovered, by design:** anything the verdicts imply — a helper command, a
tool, the dialog fork gap — is verified by its own plan's section, not this
one.

## Out of scope

- **Any shipped command.** No new verb in `main.m`, no `Seshat.AX.Client`
  function, no tool. The sketch in Part 4 is the input to a later `/plan`.
- **The dialog members in the fork.** Read through the rig only; the
  `FORK_GAPS.md` entry stays until a route needs it.
- **Groove Pool reads and `Clip.groove` assignment** — fork gap, its own
  item; the spike records only that Extract Groove(s) is pressable.
- **MIDI Tools (the clip-view Generators/Transformations panel)** — a
  parameter panel, the hardest AX target in the doc; a later spike if a
  verdict here makes AX-driven panels look tractable.
- **The Extensions SDK** as an alternative bridge to the same commands —
  behind a sign-up, unread; a separate `/evaluate`.
- **Localisation.** English labels only, as with the audio-output helper.
- **The MIDI decision experiment itself** (roadmap #3) — this spike fixes its
  arms, nothing more.

## Open questions

Everything the roadmap asked that a *read* could answer was answered today
(see Context). What remains needs a press, and a press creates tracks in the
user's set and, for Stem Separation, takes Live's UI for up to minutes — this
planning run stopped short of that by decision, since the run writes plans
only. Each is answerable by Part 3 in an afternoon; none needs a resource
that does not exist.

1. ⚠️ **Does an `AXPress` on a menu-bar item act when Live was activated
   programmatically?** The only measured menu press is `Settings...`
   (2026-08-03, 2026-08-27), which worked after `ActivateAndWait`. *Plan
   assumes* the Create items behave the same; Part 3's stop-and-diagnose
   rule covers the alternative, and only a failure there brings the context
   menu into scope.
2. ⚠️ **Which commands raise a dialog, and does the LOM see it before AX
   does?** Unknown for all eight. *Plan assumes* Slice and Separate Stems
   do, Convert does not; the rig measures it, and a dialog that
   `press_current_dialog_button` cannot drive by index makes that command
   "needs-its-own-item".
3. ⚠️ **Does a UI-originated command fold into an open
   `begin_undo_step`/`end_undo_step`, and does one `undo` revert all of it?**
   Measured today only that `begin_undo_step` relabels the Undo item
   `Undo Custom Action`, which suggests the step is open for UI actions too.
   *Plan assumes* yes; a "no" means any eventual tool cannot promise one
   call = one undo step for these commands, which the result must say.
4. ⚠️ **Convert Drums' lane count and velocity spread on SA3 material;
   Stem Separation's duration on a 4-bar loop here.** The doc's "three
   lanes" is from the manual. *Plan assumes* nothing; these are the numbers
   the verdicts are built from.
5. ⚠️ **Does the Remote Script tick keep answering during a Stem Separation
   run?** Decides whether a tool could report progress at all or must
   promise only a completion push. *Plan assumes* it stalls (the manual
   describes a modal progress bar); one `num_tracks` query mid-run settles
   it.
6. **Does a `.agr` groove load into the pool through `Browser.load_item`?**
   The roadmap lists it as "worth one check while there"; it needs a groove
   item located in the browser tree. *Plan assumes* the spike tries it once
   with `/live/browser/load_item` on a Core Library groove if
   `list_browser_items` surfaces one, and records the answer either way; it
   decides nothing in this item.
