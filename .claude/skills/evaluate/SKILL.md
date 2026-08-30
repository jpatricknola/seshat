---
name: evaluate
description: Evaluate how a requested feature or set of user stories could be built — decompose it into capabilities, check what Ableton Live already does for each (tool layer → fork → LOM → Extensions SDK → UI-only via Accessibility) first.  Then survey external models, libraries and services, then write a docs/evaluating/*.md options doc with a verdict or the smallest experiment that would produce one. Use when the user hands over a feature brief, a user-stories doc, or says "research/evaluate how we'd do X".
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
[priv/AbletonOSC/FORK_GAPS.md](priv/AbletonOSC/FORK_GAPS.md) or
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

**2.2 The fork.** [priv/AbletonOSC/API.md](priv/AbletonOSC/API.md)
and `priv/AbletonOSC/abletonosc/*.py` — is there an address? A missing
address is ours to add (the `/plan` skill includes the work); it is not a
capability gap or a candidate disadvantage. **Everything the installed LOM
exposes is 100% fair game for Seshat. Never reject, defer, downgrade, score
down, or rank a feature or approach lower because the fork needs an update.**

**2.3 The LOM.** The LOM is **what `import Live` exposes to a Remote
Script** — that is the surface AbletonOSC runs on, and the only one that
decides feasibility. Four sources, in this order of authority. Do not stop at
the first that answers "no": a negative is only trustworthy from tier 1 or 2.

**Tier 1 — the Live binary's registration table.** `strings -n 5
"/Applications/Ableton Live 12 Suite.app/Contents/MacOS/Live" | grep -n -B12
-A12 "<term>"`. This is ground truth: Boost.Python's own registration, and it
carries **Ableton's docstrings and the declared argument names**, which is
usually the whole contract. Nothing else on this list is authoritative
against it. Module names appear as bare `Live.<Module>` lines, so you can
enumerate the whole surface with `grep -E "^Live\.[A-Z][A-Za-z0-9]*$"`.

**Tier 2 — Live's own shipped Python**, under
`App-Resources/MIDI Remote Scripts` and `Helpers/Push3.app/…/live_model/Live`.
`grep -rl "<term>" "…/MIDI Remote Scripts/"` is the single highest-value
command on this list: Ableton's own Remote Scripts run in **the same
interpreter AbletonOSC does**, so one of them calling the operation is an
existence proof that ends the question. Push and Move scripts also show how
Ableton itself calls things.

**Tier 3 — `_MxDCore/LomTypes.pyc`** (`strings -n 4 … | grep -i <term>`).
⚠️ **This is not the LOM.** It is the *Max for Live property registry* — the
member lists M4L is permitted to see, curated for a different host. It is a
useful cross-check and a bad negative: a member absent here can be fully
present in the LOM. **Never write "verified absent from the LOM" on the
strength of a `LomTypes.pyc` grep alone** — that exact sentence is how
`Live.Conversions` (the entire Convert-to-MIDI feature) was misfiled as
UI-only for a month, and shipped on an Accessibility helper it never needed.

**Tier 4 — the [Cycling '74 LOM apiref](https://docs.cycling74.com/apiref/lom/).**
Third-party and known to drift; it understated `groove_amount`'s range.

**A LOM member need not be a class member.** `Live.Conversions.audio_to_midi_clip`
and `Live.MidiMap.map_midi_cc` are **module-level free functions** on a `Live`
submodule — no object in the session tree owns them. Searching only for
members of `Song` / `Track` / `Clip` / `Device` cannot find them, and neither
can `dump_lom` (see the traps below). When an operation has no obvious owning
object, grep the binary for the **verb**, not for an object's member list.

Something in the LOM but not in the fork is a **fork gap** — plan it as Python, never
as UI scripting. It changes implementation scope, not feasibility, product
merit, or priority. **Record it in the fork's
[priv/AbletonOSC/FORK_GAPS.md](priv/AbletonOSC/FORK_GAPS.md)** (member,
evidence tier, verification source and date, shape to build, consumer) in
the same pass. Never edit the copy under `priv/AbletonOSC`: make and merge the
documentation commit in the standalone fork clone (currently
`/Users/patrick/ableton-osc`), then update the Seshat submodule pin to the
merged `origin/master` commit even though it is doc-only (no install or Live
restart is needed); check that file first so you don't
re-record one. If Live is running, the probe rig under "Measuring the Live
API without building the feature first" in
[priv/AbletonOSC/API.md](priv/AbletonOSC/API.md)
answers behavioural questions in minutes — and
`/live/application/dump_lom` writes the whole reachable surface to JSON in one
call, with no file edits at all, which is usually the cheaper first move.

✅ **Two defects that used to limit both were fixed and merged on 2026-08-30**,
so the guidance here is the post-fix guidance:
`/live/api/reload` aborted on a fresh Live session and still logged
`Reloaded code`; it now names the module it stopped at and reports a partial
reload at `error` level, which reaches the client as `/live/error`, so the
probe rig works as written
([fork #35](https://github.com/jpatricknola/AbletonOSC/issues/35)). And
`dump_lom` recorded only classes, so module-level functions were absent from
it and therefore from `FORK_GAPS.md`; the walk now records them under the
module's qualname and reports classes it walked but could not diff
([fork #36](https://github.com/jpatricknola/AbletonOSC/issues/36)).

**So absence from the gap file is now evidence — tier-1 evidence, and only
that.** Every member in it is a name, kind and docstring read from Live;
nothing has been *called*. Argument order, return shapes, synchronicity and
whether a member raises are all unmeasured until you call it. The worked
example is `Live.Conversions`: the inventory could not have told you that
`audio_to_midi_clip` is asynchronous or that `is_convertible_to_midi` raises
on a MIDI clip. Use the probe rig in the fork's `API.md` § "Measuring the Live
API without building the feature first" before planning against anything the
walk reports but nobody has run.

**2.4 Extensions SDK** (Live 12.4.5+, public beta, Suite). JavaScript/TypeScript
inside Live with clip/track/device/MIDI access, audio-file import, undo
transactions, `renderPreFxAudio()`, Node APIs and network. A second bridge,
not a tool — if a capability lives here and nowhere lower, say so and route
it to a bridge-level evaluation rather than folding it into this doc.
**Read [extensions-sdk.md](docs/evaluating/extensions-sdk.md) before placing
anything on this rung**: Seshat has no beta access, the trigger model is a
user right-clicking (the extension runs once and stops — no listeners, no
programmatic invocation), and it is Suite-only, so a capability landing here
is *deferred*, not scheduled. That doc also records which operations are
confirmed on the Extension Host class versus merely present in Live's Push
document, and which of them the extension ecosystem already ships for free.

**2.5 UI-only.** A feature in Live's menus or context menus with no API at
any rung above.

⚠️ **The bar for "no API at any rung above" is tier 1 or tier 2 evidence, and
a spike that works does not clear it.** Convert-to-MIDI was the canonical
example of a UI-only feature until 2026-08-30, when the Live binary turned out
to register `Live.Conversions.audio_to_midi_clip` all along and Live's own
`Push2/convert.py` turned out to call it. It reached this rung on one
`LomTypes.pyc` grep, and stayed here because the Accessibility spike
*succeeded* — a working mechanism is a powerful stop signal, and it stopped
the search a rung too low. **Before placing anything here, say in the doc
which tier-1 or tier-2 check you ran and what it returned.** Stem Separation
remains a genuine example; it has not been re-checked against tier 1. Evaluate it against the mechanism ladder in
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
- **A negative needs a better source than a positive.** Finding a member
  anywhere proves it exists. Proving one *absent* needs tier 1 (the Live
  binary) or tier 2 (Live's own Remote Scripts). Every other source is a
  filtered view and will produce false negatives — `LomTypes.pyc` is the M4L
  registry and the apiref drifts. `dump_lom` joined tier 1 on 2026-08-30 when
  it stopped dropping module-level members; before that it agreed with
  `LomTypes.pyc` by being blind in the same place, which is how one false
  negative survived a check against two sources.
- **A LOM member need not hang off an object.** `Live.Conversions` and
  `Live.MidiMap` are submodules of free functions with no owning object in the
  session tree. If an operation has no natural owner — "convert this",
  "separate that" — grep the binary for the verb before concluding it is
  absent. `Live.MidiMap.map_midi_cc` had been called by the fork's own
  `manager.py` for the entire time `dump_lom` was failing to report it.
- **A successful spike is not evidence that a lower rung was checked.** The
  ladder decides the mechanism; the spike only proves the mechanism you chose
  works. Re-read §2.1–2.3 before writing "UI-only" in a doc, even when
  something already works.
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
