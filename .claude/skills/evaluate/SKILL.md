---
name: evaluate
description: Evaluate how a requested feature or set of user stories could be built — decompose it into capabilities, check what Ableton Live already does for each (tool layer → fork → LOM → Extensions SDK → UI-only via Accessibility) before surveying external models, libraries and services, then write a docs/evaluating/*.md options doc with a verdict or the smallest experiment that would produce one. Use when the user hands over a feature brief, a user-stories doc, or says "research/evaluate how we'd do X".
argument-hint: [a feature brief, a user-stories doc path, or a roadmap item]
---

Evaluate solution options for: **$ARGUMENTS**.

You are evaluating, not planning or implementing. The deliverable is an
options doc in [docs/evaluating/](docs/evaluating/) that a `/plan` can later
rest on. It decides nothing by itself; it makes the decision *possible* by
laying out every viable route with its evidence, cost and gates.

**The rule this skill exists to enforce:** for every capability the feature
needs, **look inside Live before looking outside it.** The generation epic
(Aug 2026) surveyed transcription models, source separators and their
licences for a week while Live Suite had shipped native Stem Separation and
had offered Convert Harmony/Melody/Drums to MIDI since Live 9 — nobody
looked, because the research briefs asked "which model do we ship." A survey
framed around external candidates cannot see a built-in. This skill puts the
Live-native check first and makes it a column in every comparison table.

## 1. Frame the capabilities, not the solutions

Read the brief or user-stories doc fully. Decompose it into **capabilities**
— operations the product must perform — each with input, output, and the
constraints the stories impose (one request = one undo step, editable MIDI
by default, latency budget, existing material untouched, honest reporting).
"Add a bassline to this section" is at least five: read the section's
context, generate material, transcribe or convert it, condition it on the
context, land it as an aligned clip on a sounding track.

Write the list down before searching anything. The capabilities are the
rows of every table that follows; candidates are columns. Check
[docs/ROADMAP.md](docs/ROADMAP.md) and [docs/evaluating/](docs/evaluating/)
for prior evidence per row — don't rediscover what
[bridge-options.md](docs/evaluating/bridge-options.md),
[lom-to-fork-gap-audit.md](docs/evaluating/lom-to-fork-gap-audit.md) or
[ui-scripting-options.md](docs/evaluating/ui-scripting-options.md) already
settled, and don't relitigate verdicts recorded in memory or the brief.

## 2. The Live-native ladder — mandatory, per capability, before any external search

"Seshat cannot do X" has four different meanings, and only the last justifies
shipping a dependency. Walk every capability down this ladder and record the
rung it stops at.

**2.0 Pin the Live version first.** Find the **latest released** Live
version and read its release notes since the installed one — search the
web, don't recall. Read the installed version from
`/Applications/Ableton Live 12 Suite.app/Contents/Info.plist`
(`CFBundleShortVersionString`). A capability added last month is exactly the
one a remembered version misses. Note edition gates (Suite / Standard /
Intro) for anything found.

**2.1 Seshat's tool layer.** [lib/seshat/tools/definitions.ex](lib/seshat/tools/definitions.ex)
— does a tool already do it, or nearly?

**2.2 The fork.** [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md)
and `priv/AbletonOSC/abletonosc/*.py` — is there an address? A missing
address is ours to add (the `/plan` skill covers the cost); it is not a
capability gap.

**2.3 The LOM.** Three sources, in order of authority: the installed
`_MxDCore/LomTypes.pyc` (`strings -n 4 … | grep -i <term>`), Live's own
shipped Python under `App-Resources/MIDI Remote Scripts` (Push/Move scripts
show how Ableton itself calls things), then the
[Cycling '74 LOM apiref](https://docs.cycling74.com/apiref/lom/). Something
in the LOM but not in the fork is a **fork gap** — plan it as Python, never
as UI scripting. If Live is running, the probe rig under "Measuring the Live
API without building the feature first" in
[.claude/docs/ableton-osc-reference.md](.claude/docs/ableton-osc-reference.md)
answers behavioural questions in minutes.

**2.4 Extensions SDK** (Live 12.4.5+, public beta, Suite). JavaScript/TypeScript
inside Live with clip/track/device/MIDI access, audio-file import, undo
transactions, `renderPreFxAudio()`, Node APIs and network. A second bridge,
not a tool — if a capability lives here and nowhere lower, say so and route
it to a bridge-level evaluation rather than folding it into this doc.

**2.5 UI-only.** A feature in Live's menus or context menus with no API at
any rung above (Stem Separation and the Convert-to-MIDI commands are the
canonical examples). Evaluate it against the mechanism ladder in
[ui-scripting-options.md](docs/evaluating/ui-scripting-options.md): named
AX element with read-back is the only rung that has been validated. Per
target, answer: menu-bar reachable (enumerable) or context-menu only; what
reads the result back — **prefer OSC-side read-back** (a structural push,
`get_clip_notes`, a count before/after) over AX read-back; any dialog
(`press_current_dialog_button` exists in the LOM); enabled state on the
wrong clip type or edition; run duration and completion detection. If Live
is running, the AX helper at `_build/ax-spike/ax-probe` (source
`tmp/ax_probe.m`, bundle id `com.ableton.live`, Live must be frontmost)
can enumerate the menu bar read-only — do that rather than guessing.

Record the rung for every capability in the doc. A UI-only rung is a
legitimate candidate with a cost (edition gate, focus, a spike), not a
disqualification and not a footnote.

## 3. External survey

Only now: models, libraries, services, plugins. For each candidate:

- **Licence at selection**, checked separately for code, weights and
  training data — [CLAUDE.md](CLAUDE.md)'s distribution rule. No licence,
  non-commercial, or research-only disqualifies unless the design keeps it
  out of the shipped product. Attribution and revenue-gated licences need
  an explicit product story, not a "clean" label.
- **Measured vs reported.** Anything you ran on this machine is *measured*;
  anything from a paper, model card, blog or README is *reported*. Label
  every figure. If a candidate installs in minutes, spike it in a throwaway
  environment under the session scratchpad and measure; a one-hour spike
  that fails is reported as a failure, not a verdict.
- **Local-first posture.** No API key exists anywhere in Seshat today. A
  service must beat local routes by a clear margin, and the doc must state
  the posture cost. (The user has accepted a key for specific features
  before — check memory before treating it as a blocker.)
- **Conditioning interface.** Free text, closed vocabulary, symbolic input,
  audio input — say exactly what each can and cannot express, because that
  bounds what Claude can translate intent into.
- **Ecosystem health.** Maintained or abandoned research code; age; Apple
  Silicon story.

## 4. Compare per capability

One table per capability (or one wide table if the feature is small), with
**Live-native as a column that is always present** — filled with the rung
from §2 and its cost, or "none at any rung" if that is the honest answer.
Criteria, in the order the brief ranks them or, failing that:

quality of the final result in Live › expressiveness of control ›
local-first fit › coverage of the stories › licence / distribution ›
latency against the budget › dependency and edition surface › verification
path (what reads the outcome back) › undo atomicity › ecosystem health.

Then the wiring question, when the feature composes several capabilities:
which routes chain cleanly (a transcriber that takes a WAV on disk vs one
that needs the audio imported and selected first), and where the chain
would break "one request, one undo step."

## 5. Verdict, or the experiment that would produce one

End with a recommendation **only where the evidence supports one**. Where
it doesn't, specify the smallest decision experiment: what to run, on what
fixed slate, judged how (ears, blinded, same instruments), and what result
picks which route. Name the spikes in order, each saying what it can kill.

State what remains unmeasured in one list. A doc that reads as complete is
worse than a short one — it retires the checks nobody wrote.

## 6. Write the doc

`docs/evaluating/<topic>.md` (or a subfolder when the feature is an epic
with several docs), in the house style of the existing ones:

- Italic header line: doc type · date · what it answers · "decides nothing
  by itself" and whether it may feed the roadmap.
- **Verdict up front**, then the capability frame, then the Live-native
  ladder results, then the external survey, then the comparison, then
  the verdict expanded, then open work, then a source index.
- Every claim labelled measured or reported; every measurement dated with
  the Live version and machine.
- Cross-link siblings both ways: if a finding changes what another doc in
  the folder says, **edit that doc** — a footnote in the new one is not
  enough.

Do not add to [docs/ROADMAP.md](docs/ROADMAP.md) unless the verdict is
clear; a roadmap entry is a commitment, and this doc's job is to make the
commitment informed. Do record any *defect* the research exposed in
existing code as a roadmap issue — that is independently real.

## 7. Report

Which capabilities you framed; for each, the Live-native rung it stopped at
and whether that was a surprise; the external shortlist with licence
status; what you measured on this machine and what it changed; the verdict
or the experiment; and what you could not reach (Live not running, no
permission, SDK docs behind a sign-up) — per the `/plan` rule, "needs
Ableton" is not an answer when Ableton is running.

## Traps, recorded so you don't rediscover them

- **A survey framed around external candidates cannot see a built-in.**
  The ladder in §2 runs first for that reason; it is not optional when the
  brief "obviously" needs a model.
- **"Seshat can't" ≠ "Live can't".** Tool gap, fork gap, LOM gap, UI-only:
  four different costs. Name which.
- **Version anchoring.** Capabilities you remember are from a version you
  remember. Live ships point releases with real features (12.3 stems, 12.4.5
  Extensions SDK); check the notes since the installed build.
- **Edition gates are a distribution question.** A Suite-only feature is a
  fine optional path and a bad only path.
- **Weights are licensed separately from code.** MIT code over CC-BY-NC or
  unresolved weights is disqualified; check both, every time.
- **Reported figures drift into "measured" through retelling.** Label at the
  sentence level and keep the labels through every later edit.
- **Reach the product output before judging.** Note counts, onset offsets
  and FAD prove plumbing, not that the result sounds right in Live. If the
  output is MIDI, the comparison is rendered MIDI through the same
  instruments; if audio, the clip on the grid.
