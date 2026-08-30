# UI scripting options: LOM, Accessibility elements, and keystrokes

Seshat controls Ableton Live through the Live Object Model (LOM), carried over
OSC. The LOM does not expose every user-facing setting: audio-device selection
is the important current example. This note evaluates whether macOS UI
scripting is worth adding for those gaps.

_Evaluation note · 31 Jul 2026 · decides no roadmap priority by itself._

## Current position

The narrow spike against Live's Audio Settings succeeded on 2026-08-03. A
direct Accessibility (AX) helper found the audio-output chooser, enumerated its
named choices, selected MacBook Pro Speakers, read the new value back, restored
the original system-device selection, and verified that value too. The full
native-helper change-and-restore run took 1.55 seconds; AX is therefore viable
for this target, subject to the constraints recorded below. That is not an
end-to-end conversational measurement: the implementation plan separately
requires the user-visible request to complete within 10 seconds.

Implementation plan: [AX-backed audio-output selection](../archive/PLAN_audio_output.md).

This validates a particular UI-scripting operation, not a general second
control surface. No synthetic keystroke has yet been observed reaching Live
from this machine.

The architectural rule is:

> **Use UI scripting only for a concrete operation absent from the current
> LOM. When the LOM exposes an operation, add it to the fork instead.**

The rule has held up; what failed once was the evidence behind the word
*absent*. See "What counts as evidence that the LOM lacks a target" below
before applying it.

## What is already established

### The LOM reaches more UI state than Seshat currently exposes

Do not equate "Seshat has no tool for it" with "the LOM cannot do it." The
current LOM `Application` object exposes `open_dialog_count`,
`current_dialog_message`, `current_dialog_button_count`, and
`press_current_dialog_button`. Seshat's fork does not currently register those
members, but dialog presence and message text are therefore fork gaps, not AX-
only capabilities. The same check must happen against the installed Live
version before classifying any target as a UI-scripting use case.

Verified against Live 12.4.3's shipped Python on 2026-07-31, the house
evidence standard since the apiref understated `groove_amount`'s range:
`_MxDCore/LomTypes.pyc` lists all four members, and Move's `dialog.pyc`
drives an `_on_dialog_opened` listener off `open_dialog_count` — dialog
presence is listenable, not merely readable, so it could join the push
mirror rather than being polled.

Reference: [Live Object Model — Application](https://docs.cycling74.com/apiref/lom/application/).

Audio-device selection is different: no current LOM object exposes Live's
application-wide input or output device preference. That makes "switch my
output to the headphones" the best candidate for a UI-scripting spike, not
proof that UI scripting should become a general second control surface.

### Live 12 has deliberate accessibility support

Live's interface is custom-drawn, but custom drawing does not imply an opaque
AX tree. Ableton says most Live 12 views, controls, and devices work with screen
readers. Its manual specifically says the Audio Settings page can be traversed
with Tab and its options changed with the keyboard. That is positive evidence
that the audio controls have semantic accessibility information, although it
does not prove the exact AX roles, attributes, or actions a helper will see.

Reference: [Accessibility Options in Live](https://www.ableton.com/en/live-manual/12/accessibility-options-in-live/).

### `create_project` did not disprove keystrokes

[The `create_project` removal record](../archive/create-project-removal.md)
describes the only previous UI-driving code in Seshat. Its AppleScript Cmd+N
was removed because the feature was redundant with a stripped default set,
its track-clearing failure was an OSC/load-settling problem, and handling
unsaved work was deliberately left to the user.

It did establish one relevant failure mode: a save-changes dialog intercepted
the shortcut while the code continued without knowing that the requested
operation had not happened. That is evidence against blind, focus-routed
input—not against every possible use of a keystroke.

## Mechanism ladder

Use the highest applicable rung. Rung 1 is Seshat's established control path;
rung 2 is now validated for the specific audio-output target, not generically.

The rungs are mechanism choices, not feasibility scores. **Everything the
installed LOM exposes is fully in scope for Seshat.** A missing AbletonOSC
address is ordinary fork work and carries no negative weight when choosing,
ranking, or scoping a feature; add the address. Only absence from the LOM
allows a target to fall to AX or another mechanism.

1. **LOM via the AbletonOSC fork.** The default for everything the installed
   LOM exposes.
2. **Named AX element with read-back.** For a current LOM gap where the target
   exposes a stable role/name, an appropriate action, and a readable result.
3. **Keystroke with checks and read-back.** Only where a concrete target has no
   usable AX action but its state can be read independently before and after.
4. **Bare keystroke.** Only where misdelivery is harmless and repetition
   converges on the same state. This is expected to be rare in Live.
5. **Screen coordinates.** Unsupported. A missed click acts on a different
   target, and layout changes with window geometry, localization, and Live
   versions.

Falling back a rung requires evidence about the particular target. The
existence of a shortcut is not a reason to skip checking the LOM or AX tree.

### What counts as evidence that the LOM lacks a target

Rung 1 is the default, so **falling below it is a claim that needs a source**,
and the source has to be one that can produce a trustworthy negative:

- **Sufficient:** the operation is absent from the Live binary's Boost.Python
  registration table (`strings -n 5 …/Contents/MacOS/Live`), **and** absent
  from Live's own shipped Remote Scripts
  (`grep -rl "<term>" ".../MIDI Remote Scripts/"`). Ableton's scripts run in
  the same interpreter AbletonOSC does; one of them calling the operation
  settles it in the other direction.
- **Not sufficient:** a `_MxDCore/LomTypes.pyc` grep. That file is the *Max
  for Live property registry*, not the LOM — a member absent there can be
  fully present and callable.
- **Not sufficient:** absence from `FORK_GAPS.md` or `lom_dump.json`.
  `walk_live()` records only classes, so module-level functions never appear
  in either ([fork #36](https://github.com/jpatricknola/AbletonOSC/issues/36)).
- **Not sufficient, and the one that actually bit:** *a UI-scripting spike
  that works.* A working mechanism proves the mechanism works. It says nothing
  about whether a lower rung existed, and it is a powerful stop signal exactly
  when the search should continue.

**The worked failure.** *Convert Harmony/Melody/Drums to New MIDI Track* was
placed at rung 5 in §"What UI scripting could buy" on one `LomTypes.pyc` grep
(2026-08-27), the AX path was then measured working, and
`convert_audio_to_midi` shipped on the Accessibility helper. On 2026-08-30 the
Live binary turned out to register `Live.Conversions.audio_to_midi_clip` —
with Ableton's own docstring — and Live's `Push2/convert.py` turned out to
call it. It was a fork gap the whole time. See the correction in §2 above,
[fork #34](https://github.com/jpatricknola/AbletonOSC/issues/34), and
[.claude/docs/ableton-lom.md](../../.claude/docs/ableton-lom.md) for the tier
table.

An operation with **no natural owning object** — "convert this", "separate
that", "slice this" — is the shape most likely to be a module-level function
and therefore the shape most likely to be misfiled here. Grep the binary for
the verb before writing it down as UI-only.

## Safety model

Neither OSC nor UI scripting is automatically verified.

- **OSC avoids keyboard focus**, and absolute setters such as setting tempo to
  120 are naturally idempotent. But OSC uses silent UDP setters and often
  index-addressed objects. A stale index or concurrent human edit can still
  mutate the wrong Live object. Seshat guards some important operations—for
  example, `create_track` counts before and after and `delete_device` validates
  then re-counts—but verification is not yet universal: see "Verify
  destructive mutations before reporting success" in [ROADMAP.md](../ROADMAP.md).
- **AX actions target an element rather than the current keyboard focus.** If
  Live exposes a stable element, Seshat can inspect its role and value, perform
  a supported action, and read it again. Elements can still disappear or
  become stale, so every action must handle AX errors and verify the resulting
  state. AX is preferable because it removes the focus-routing race, not
  because it is infallible.
- **Keystrokes remain focus-routed.** Checking the frontmost app and modal
  state first reduces uncertainty, and reading the intended state afterward
  detects many failures. It does not make the operation atomic: the user can
  change focus between the check and delivery, and a successful post-check
  cannot prove that no other key was misdelivered. Toggle, selection-relative,
  and plain-character shortcuts therefore remain poor automation targets.

The user and Seshat share the same live session under every mechanism. OSC
removes focus contention; it does not remove concurrent-state races.

## What UI scripting could buy

Candidate uses, ordered by current value:

1. **Audio Settings.** Select a Live-wide audio input or output device by
   name. This is the go/no-go case because it is useful, absent from the
   current LOM, and documented by Ableton as keyboard-accessible.
2. **Named menu commands with no current LOM equivalent.** Each command still
   needs an individual value and safety case. The View menu is not an example:
   `Application.View` already exposes `show_view`, `hide_view`, and
   `is_view_visible`. Two concrete examples, both verified absent from Live
   12.4.3's `LomTypes.pyc` on 2026-08-27: **Stem Separation** (12.3+, Suite
   only; vocals/drums/bass/other onto new tracks) and **Convert
   Harmony/Melody/Drums to New MIDI Track** (Live 9+, Standard and Suite).

   > ⚠️ **Correction, 2026-08-30 — Convert-to-MIDI is very likely NOT
   > UI-only.** The 2026-08-27 check grepped `LomTypes.pyc`, which registers
   > *properties*; it did not look for a service class. On Live 12.4.5:
   > `LomTypes.pyc` **imports `Conversions` from `Live`**;
   > `Push3.app`'s `live_model/Live/Conversions.pyc` declares
   > `audio_to_midi_clip`, `is_convertible_to_midi` and an
   > `AudioToMidiTypeEnum` of `harmony_to_midi` / `melody_to_midi` /
   > `drums_to_midi`; and **Live's own shipped Remote Script**
   > `MIDI Remote Scripts/Push2/convert.pyc` imports `Conversions`, calls
   > `is_convertible_to_midi`, and names `ConvertAudioClipToHarmonyMidi`,
   > `ConvertAudioClipToMelodyMidi` and `ConvertAudioClipToDrumsMidi`.
   > AbletonOSC is a Remote Script and runs in that same embed, so this reads
   > as a **fork gap — a missing address — not a UI-only feature**, and the
   > case for driving `convert_audio_to_midi` through AX rests on a premise
   > that has not survived re-checking.
   >
   > **Settled the same day.** The Live 12.4.5 binary's Boost.Python
   > registration for `Live.Conversions` was read directly: `audio_to_midi_clip`
   > (*"Creates a MIDI clip in a new MIDI track with the notes extracted from
   > the given `audio_clip`"*), `is_convertible_to_midi`, and six siblings, all
   > **module-level free functions** — which is also why the fork's own
   > `dump_lom` never saw them ([fork
   > #36](https://github.com/jpatricknola/AbletonOSC/issues/36)). The
   > `AudioToMidiType` enum was confirmed live in the running Remote Script
   > interpreter. **Convert-to-MIDI is a fork gap, filed as [fork
   > #34](https://github.com/jpatricknola/AbletonOSC/issues/34)**; Seshat's half
   > is ROADMAP #14. The call itself has still not been executed, so its
   > synchronicity is open. Stem
   > Separation was *not* re-checked and its UI-only disposition still stands
   > on the 2026-08-27 evidence. Found while walking the LOM for a
   > harmonisation member; see
   > [generative features/harmony-from-a-melody-options.md §2.6](generative%20features/harmony-from-a-melody-options.md).

   Both are stronger targets than Audio Settings was, because their read-back
   is on the OSC side, not AX: new tracks arrive as structural pushes into
   `Session.State`, converted notes are readable through `get_clip_notes`,
   and a count-before/count-after guard bounds misdelivery the way
   `create_track` already does. The generation epic
   ([generative features/](generative%20features/)) would use them for Route
   C's separate-and-transcribe stages without shipping a separator or
   transcriber. Per-target spike questions: whether each command is reachable
   from the menu bar (enumerable) or only the clip context menu; whether Stem
   Separation raises a mode dialog (`press_current_dialog_button` covers it);
   enabled state on the wrong clip type or edition; and completion detection
   for a run that takes seconds to minutes.
3. **Exact presentation state not present in the LOM.** AX can answer bounded
   questions about exposed controls more cheaply than a screenshot and vision
   round-trip. Dialog count and message text no longer qualify because the LOM
   already exposes them.
4. **Self-verifying smoke tests for otherwise visual behavior.** This is a
   secondary benefit, not enough by itself to justify the implementation.

AX and the roadmap's `screenshot_live` idea are complementary. AX is suitable
for bounded questions about exposed elements; screenshots are suitable for
open-ended questions about pixels. A screenshot does not make coordinate
clicking an acceptable control mechanism.

## Constraints if it is built

### Keep the LOM-first boundary

A UI layer will be easier to extend casually than the fork, but it is more
dependent on labels, localization, and Live's UI structure. Before adding any
target, verify that the installed LOM cannot perform the operation. Keep tool
contracts above the mechanism boundary so a future LOM addition can replace AX
without changing what the model calls.

### Keep file lifecycle operations with the user

This evaluation does not reopen creating, opening, saving, closing, or
discarding Live Sets. In particular, Seshat must never choose to discard
unsaved work. Reading a file-related dialog more reliably does not grant
authority to act on it.

### Treat macOS permissions as an implementation question

The permissions observed on 2026-07-31 prove setup friction, but the original
errors did not cleanly identify one grant per mechanism. The relevant macOS
controls are:

- **Accessibility** for a direct `AXUIElement` client to inspect and control
  another application's accessible elements.
- **Automation / Apple Events** in addition when AppleScript drives an app such
  as System Events. A direct AX helper avoids making Apple Events part of the
  production design.
- **Screen & System Audio Recording** for screenshots. It is relevant to
  `screenshot_live`, not to ordinary AX-tree inspection.

Permission attribution and restart behavior depend on the executable and the
API involved. The spike must record which process macOS asks the user to trust
and whether a restart is actually required; do not assume in advance that the
BEAM, Terminal, and a child helper are interchangeable permission identities.

Seshat has no AX integration or suitable dependency today. A small native
helper process is the likely implementation, but the spike should establish
that shape rather than treating the absence of an Elixir binding as proof of
it.

### Permission result — 3 Aug 2026

A tiny Objective-C command-line helper linked directly against AppKit and
ApplicationServices called `AXIsProcessTrustedWithOptions`, with the prompt
option enabled, from a stable executable at
`_build/ax-spike/ax-probe`. macOS 15.7.4 granted Accessibility access to that
helper as `ax-probe`. Neither Automation / Apple Events nor Screen & System
Audio Recording permission was requested, and neither Live nor the helper
needed a restart.

With Ableton Live 12.4.3 running, the same executable then found the process by
its stable bundle identifier, `com.ableton.live`, and successfully read this
top-level AX excerpt:

```text
AX trusted: true
Live: Live pid=3708 bundle=com.ableton.live
Application role: AXApplication
Application title: Live
Application children: 1
```

The process-discovery detail matters: the installed application's bundle and
executable names are `Live`, not `Ableton Live`; matching the visible product
name falsely reported that Live was not running. Use the bundle identifier in
future helpers.

### Audio-output round trip — 3 Aug 2026

The helper used a bounded path rather than walking Live's full AX tree:

1. Find the running application by bundle identifier `com.ableton.live`.
2. Activate Live, because Live 12.4.3 exposes only its menu bar and reports zero
   AX windows while it is not the active application.
3. Read `AXWindows`, select the `Settings` window, then find the group with
   identifier `audio` and its direct `Audio Output Device` popup child.
4. Press the popup and select a named item from the temporary window whose
   group identifier is `ChooserPopUp`.
5. Read the popup's value after each selection.

The available choices during the run were `No Device`, `Use System Device`,
`MacBook Pro Speakers (0 In, 2 Out)`, and `25 AirPods (0 In, 2 Out)`. The
verified result was:

```text
Original: Use System: 25 AirPods (0 In, 2 Out)
Selected: MacBook Pro Speakers (0 In, 2 Out) (AX error 0)
Changed value: MacBook Pro Speakers (0 In, 2 Out)
Selected: Use System Device (AX error 0)
Restored value: Use System: 25 AirPods (0 In, 2 Out)
real 1.55
```

A targeted current-value lookup completed in 0.95 seconds and enumerating the
already-open popup window took 0.09 seconds. The earlier multi-minute
exploration was caused by repeatedly compiling the probe and recursively
printing more than 2,000 unrelated AX elements; that is not an acceptable or
necessary runtime design. A production helper should use this bounded path,
short messaging timeouts, and value read-back, and should account explicitly
for bringing Live to the foreground.

References: [macOS Privacy & Security settings](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac),
[AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h).

### Production helper — measured 27 Aug 2026

The shipped helper (`native/seshat_ax/main.m`) was exercised directly against
Live 12.4.3 on macOS 15.7.4 while it was being written. These are *native*
measurements — one process invocation, no MCP, no model — and they are not the
feature's acceptance, which is measured through a real client in
[smoke_tests/manual/conversation.md](../smoke_tests/manual/conversation.md).

- `list-outputs` returned `Use System: MacBook Pro Speakers (0 In, 2 Out)` with
  the three installed choices, in 0.33–1.04s wall clock across ten consecutive
  runs, every reply identical.
- `set-output` to an explicit device, an idempotent repeat, and back to
  `Use System Device` all succeeded with the value read back off Live's own
  popup (0.45–0.80s). The `Use System:` prefix verification behaved as the spike
  predicted.
- A nonexistent device name failed in 0.79s carrying the three real names and an
  unchanged current value.
- After every run the previously frontmost application was frontmost again and
  Live held one window — the Settings window the helper opened was closed.

Two defects were found and fixed by these runs, both invisible to any test that
does not drive a real application:

1. **Waiting on `NSRunningApplication.active` hangs.** That flag is updated by a
   workspace notification, so a command-line tool that sleeps rather than running
   its runloop never sees it change. The first version spent its entire deadline
   waiting to activate Live and returned `timeout` having pressed nothing.
2. **Every third back-to-back run failed to open Settings.** Restoring the
   previous application was fire-and-forget, so it landed *during* the next run,
   which then saw Live frontmost, skipped activation, and left the run after that
   pressing a menu Live was not listening to. The helper now waits for the
   restore, re-activates before every attempt at the menu, and retries the press.
   Ten consecutive runs then passed.

The lesson generalises beyond this feature: AX correctness is bound up with
macOS *activation* state, which is asynchronous, notification-delivered, and
shared with whatever else is on the machine. Any future AX operation has to
treat it as a first-class part of the transaction rather than a preamble.

## Spike protocol and result

This evidence-gathering spike is complete; it is not the implementation plan.
It used a tiny direct `AXUIElement` walker rather than System Events so the
result tested AX itself without also testing Apple Events. The protocol remains
here with the preserved tree excerpts, Live version, macOS version, permission
steps, and errors.

Answer these questions:

1. **Menu bar:** Are menu items enumerable by name and role? Can checked or
   enabled state be read, and which actions are advertised?
2. **Audio Settings discovery:** With Settings opened by hand, can the helper
   identify the Audio page, output-device control, current value, and available
   choices without relying on coordinates or sibling order alone?
3. **Audio Settings action—the go/no-go:** With transport stopped and a safe
   fallback device available, can the helper select a different output by
   name, read the new selection back, then restore the original device? Record
   disabled states, device disappearance, and any confirmation dialog. Merely
   finding a named dropdown is not success.
4. **Dialogs:** Compare the LOM's dialog count/message with the AX tree for a
   harmless dialog. This determines which mechanism owns each read; do not
   press any file-lifecycle button.
5. **Main window:** Record how much of the session grid and major views is
   semantic. This is not a go/no-go for Audio Settings, but it prevents future
   proposals from guessing that the whole window is either rich or opaque.
6. **Keystrokes, only if a real gap remains:** Test a synthetic shortcut only
   after identifying a useful operation with readable state but no actionable
   AX element. Separate direct event injection from AppleScript/System Events,
   and record the exact permissions each route requests. A browser-visibility
   toggle is a suitable harmless test once the fork exposes
   `is_view_visible`.

**Question 3 — the go/no-go — is answered, and the first outcome below is the
one that happened.** The complete audio-device round trip succeeded on
2026-08-03, the roadmap entry was written scoped exactly as that outcome
requires, and the implementation is
[PLAN_audio_output.md](../archive/PLAN_audio_output.md): two tools, a bounded native
helper, read-back verification, and the LOM-first rule left in force. Nothing
here validates a second control surface — questions 1, 4, 5 and 6 remain open
research, and each future AX operation still needs its own LOM-gap, safety,
semantic-target and read-back case.

Outcomes:

- **Complete audio-device round trip succeeds:** add a roadmap entry scoped to
  named targets with read-back, the LOM-first rule, explicit permission setup,
  and file-lifecycle operations excluded.
- **The control is readable but not safely actionable:** record the failure.
  Consider a guarded keystroke only if the same state has an independent,
  reliable read and the focus race is acceptable for this target.
- **The control is not semantically exposed:** decline audio-device control.
  Do not replace it with coordinates; keep guiding the user to Live's Audio
  Settings and let `screenshot_live` cover observation separately.

Reconsider the result when the spike runs, when a Live release materially
changes its accessibility exposure, or when the LOM gains application-wide
audio-device preferences.
