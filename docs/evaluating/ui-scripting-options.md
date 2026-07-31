# UI scripting options: keystrokes vs Accessibility elements

Seshat reaches Ableton through the Live Object Model, over OSC. Some of what a
user asks for provably isn't in the LOM at all — audio preferences, most menu
items, whether a dialog is open — and the recurring idea is to reach it by
scripting the Mac UI instead. This note evaluates that idea so it doesn't get
re-litigated from scratch, and so the next proposal starts from what has
already been measured.

**Current position: no decision to build.** One mechanism (synthetic
keystrokes) is declined outright on evidence Seshat already paid for once. The
other (Accessibility element scripting) is plausible but rests on one unproven
assumption about Live's window; the next step is the [spike](#the-spike-that-decides-it)
below, not a design. No roadmap entry exists yet — per house practice
([sound-search-options.md](sound-search-options.md)), this doc holds the
evidence and the roadmap holds the order, and this one doesn't earn a rank
until the spike says the assumption holds.

## The prior art: Seshat already shipped keystrokes once, and removed them

[archive/create-project-removal.md](../archive/create-project-removal.md)
(2026-07-28) is the controlling precedent. `create_project` drove Live with an
AppleScript Cmd+N, and every failure it records is a property of the
*mechanism*, not of the feature around it:

- **Blind targeting.** A keystroke goes to whatever has focus. The Cmd+N "only
  worked when it was redundant" — when a fresh set was already open.
- **No read-back.** Nothing confirms the keypress did anything. The
  fire-and-forget deletes that followed were lost into a settling window no
  code could see the end of.
- **Modal state is invisible and fatal.** Live's "save changes?" dialog
  swallowed the keystroke and blocked everything, and no code can click *Don't
  Save* on the user's behalf without discarding their work.

Send-and-hope, exactly like a silent OSC setter — but aimed at a target that
moves and with consequences that can include a user's unsaved work. That
removal ended with "everything is OSC," and nothing since has weakened it.

**Synthetic keystrokes are therefore declined as a mechanism, permanently.**
Any future proposal in this area means Accessibility element scripting, which
does not share those properties.

## Why AX element scripting is a different thing

The Accessibility API addresses the UI as a tree of named elements, not as a
focus target for events. The differences are exactly the three failure modes
above, inverted:

| | Keystrokes | AX elements |
|---|---|---|
| Targeting | whatever has focus | a control found by name/role in the tree |
| Verification | none | read the element's value/state back after acting |
| Modal dialogs | invisible; swallow input | visible as elements — a sheet's existence and its button labels can be *read*, and the action refused |

The dialog that defeated `create_project` is precisely the thing AX can see.
That doesn't reopen file operations — see the constraint below — but it means
the mechanism fails safe where the old one failed blind.

## What it would buy — only where the LOM can't go

The candidate uses, in value order:

1. **Audio preferences.** "Switch my audio output to the headphones" is the
   case `Seshat.Instructions` currently handles by rule: *say so plainly and
   name where in Live the setting lives*
   ([lib/seshat/instructions.ex](../../lib/seshat/instructions.ex)). There is
   no LOM path to Preferences, so this hole can never close through the fork.
   It is the strongest single argument for the feature existing.
2. **Menu items with no LOM equivalent.** The long tail of commands Live only
   exposes as menus. (Not the View menu — see the rot rule below.)
3. **Reading dialog and window state.** OSC is structurally blind to
   presentation; the mirror knows session state, never what's on screen. An AX
   read is cheaper and more exact than the `screenshot_live` roadmap item for
   the things it can name — the two are complementary, not competing:
   screenshots answer open-ended "what's wrong with my screen" questions with
   pixels and a vision round-trip; AX answers "is X open / checked / enabled"
   with a boolean.
4. **Self-verifying smoke tests.** The 2026-07-31 `show_view` smoke run needed
   a human's eyes and hands for pane toggling. (The view-specific half of that
   is already better served by the fork — "Read and hide Live's panes" in
   [ROADMAP.md](../ROADMAP.md) — but the general form recurs.)

## What it costs

**The real risk is rot, not safety.** The day this evaluation was written,
`hide_view` needed a fork commit — and if a UI-scripting layer had existed,
the tempting path was to script the View menu instead: fragile,
version-dependent, locale-dependent, and sitting *outside* the stable seam
CLAUDE.md defines (the tool contract in `Definitions`, everything below
`Handlers` reimplementable). A UI backdoor next to a clean LOM path erodes the
architecture one convenience at a time. The rule that keeps it honest:

> **If the LOM exposes it, it goes in the fork. UI scripting is only for what
> the LOM genuinely cannot reach.**

**File open/save stays settled regardless of mechanism.** The
`create_project` removal record is explicit that saving and Cmd+N "stay with
the human — the one step Seshat could never do safely anyway." AX seeing the
save dialog changes the failure mode, not the consequence: discarding unsaved
work is unrecoverable, so no UI-scripting tool touches open, save, or the
dialogs that guard them. This doc does not reopen that question.

**Permissions are real friction, measured 2026-07-31 on this machine:**

- macOS splits the capability across at least three separate grants:
  Accessibility (reading another app's frontmost/window state), sending
  synthetic input, and Screen Recording — observed as three distinct errors
  (`-25211` assistive access; `1002` "not allowed to send keystrokes";
  `-1719`) with Accessibility granted but the others not.
- Grants attach to the *calling process* and demand an app restart to take
  effect. For Seshat that means the BEAM (or a shipped helper binary) needs
  its own grant — a real setup step for every install, of the kind
  `README.md` currently doesn't have.
- Elixir has no AX bindings; the implementation route is a small Swift/ObjC
  helper CLI that Seshat shells out to (the same shape `screenshot_live`
  plans around `screencapture`).

## The unknown that decides it

**Live draws its own interface.** It is not standard AppKit widgetry, and an
app that custom-draws can expose anything from a full semantic AX tree to a
single opaque `AXGroup`. The menu bar is native, so menu items are almost
certainly real elements; the Preferences panel's audio-device dropdown — the
number-one use case — may expose nothing at all. If it doesn't, the only
fallback is clicking at coordinates, which inherits every blindness that got
keystrokes declined, and the correct outcome is to decline the whole feature
and record it here.

This could not be tested on 2026-07-31: element queries died on the
permission granularity above before reaching Live's tree.

## The spike that decides it

A morning, not a plan. Grant Accessibility to a terminal, dump Live's AX tree
(System Events `entire contents`, or a ~50-line Swift `AXUIElement` walker),
and answer four questions:

1. **Menu bar:** are menu items enumerable by name, with checkmark state
   readable? (Expected yes; would have answered the Detail-pane question the
   smoke test left open.)
2. **Preferences:** open it by hand, walk the window — is the audio output
   dropdown a named, stateful element? **This is the go/no-go.**
3. **Dialogs:** with an unsaved set, trigger the save-changes sheet — can its
   existence and button labels be read? (Read only; nothing clicks it.)
4. **Main window:** does the session grid expose anything, or one opaque
   group? (Expected opaque; fine — OSC owns that surface anyway.)

Outcomes: **prefs addressable** → write a roadmap entry scoped to AX-only,
named targets, read-back verification, LOM-first rule stated, file operations
excluded. **Prefs opaque** → decline, record the tree dump's shape here, and
let `screenshot_live` carry the "see the screen" cases alone.

**Reconsider this doc's position if:** the spike runs (either outcome gets
recorded here); an Ableton release materially changes Live's AX exposure; or
Ableton ships an API surface for preferences, which would delete use case #1
and most of the point.
