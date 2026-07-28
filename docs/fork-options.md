# Fork options: patching AbletonOSC in place vs maintaining a fork

> ## ⚠️ Status: decided, 2026-07-28 — **we forked.**
>
> Two triggers fired together:
>
> - **A second override** (trigger #1 below): upstream PR #213's one-line
>   `clip_slot.py` logger fix, which floods Live's `Log.txt` with a
>   `RemoteScriptError` on every clip operation Seshat performs. No
>   `add_handler` seam exists for it — only the file.
> - **Editing upstream's own files** (trigger #2 below): upstream PR #208's
>   per-message error handling, in the handler base class and the OSC server's
>   `process()` tick. No seam at all, and the bug it fixes truncates exactly the
>   ordered multi-message sequences `Seshat.Commands.Registry` sends.
>
> The fork is [jpatricknola/AbletonOSC](https://github.com/jpatricknola/AbletonOSC),
> public, consumed as a git submodule at `priv/AbletonOSC`. `SESHAT.md` at its
> root lists every divergence and the merge hazards. `mix abletonosc.install` is
> now a locate-and-copy; the anchor patching, the override mechanism, and
> `track_listeners.py` no longer exist — the wrong-object listener unbind is
> fixed in `AbletonOSCHandler._stop_listen` instead.
>
> **Everything below is the historical record**, kept for the reasoning and for
> the merge playbook in "If upstream revives", which is still live guidance.

Seshat extends AbletonOSC by **patching the user's installation in place**:
`mix abletonosc.install` copies the vendored handlers from `priv/abletonosc/`
and inserts two one-line anchor patches per handler into upstream's
`__init__.py` and `manager.py`. The recurring alternative is a **fork** —
Seshat's own AbletonOSC repo with the changes committed, installed wholesale.
This note records the trade-off, the exact triggers that flip the decision,
and the migration playbook, so that when a trigger fires the switch is a
morning's work instead of an archaeology project. Current decision: **patch
in place**; fork when a trigger below fires, not before.

## The shape of the delta today

Four vendored files. Three are pure **extensions** — new handler classes,
new addresses, upstream untouched beyond the two insert lines. One,
`track_listeners.py`, is an **override**: it re-registers five upstream
addresses to fix upstream's wrong-object listener unbind, and works only
because `add_handler` is a dict assignment and the installer anchors our
handlers below `TrackHandler`. That ordering invariant is the fragile part —
its failure mode is invisible (every address still answers) — and it is
fenced by `abletonosc_install_test` (anchor ordering) and
`vendored_addresses_test` (override coverage).

## What a fork would buy

- **The override mechanism disappears.** The listener fix lands inside
  upstream's own track handler instead of riding on dict-assignment ordering.
  The invisible-failure invariant and the test guarding it both go away.
- **The anchor-patching code disappears.** Install becomes "copy this
  directory"; no anchors, no drift detection, no manual-instructions
  fallback.
- **Upstream conflicts move to git.** Merges with conflict markers instead of
  an installer that either finds its lines or doesn't.

## What it would cost

- **Every upstream release routes through us**: fetch, merge, re-test,
  reinstall. The installer only demands attention when an anchor line
  actually moves — and it fails loud, printing the manual edits.
- **The delta stops being self-describing.** Today the entire divergence
  from upstream is four files in `priv/abletonosc/` plus eight greppable
  insert lines. In a fork it's a git range against a moving base.

Both costs assume a moving upstream — see the next section for why that
assumption is currently weak.

## State of upstream (observed 2026-07-28)

Upstream is **effectively dormant**: last commit to master 2025-11-19, last
merged PR 2025-11-16, 33 PRs open — the oldest (#84, master-track support)
since May 2023. The community has independently solved the same gaps Seshat
vendors — six open PRs add a browser API, four add master/return support,
and a May 2026 consolidation effort merging the duplicates into clean
submissions sits unmerged like the rest.

This cuts both ways, and mostly cancels out:

- The fork's headline cost (merging upstream releases) is theoretical while
  nothing releases.
- The installer's headline risk (anchor drift) is equally theoretical while
  nothing moves the anchors.

So dormancy is not itself a reason to fork — but it removes any reason to
*hesitate* when a trigger fires: there is no active upstream worth staying
merge-compatible with. Re-check the repo's pulse before acting on this
section; a revived upstream restores both the cost and the risk.

## Why waiting doesn't compound the cost

The usual "fork early, refactoring only gets harder" instinct doesn't apply
here, because nothing on the Elixir side knows which world it's in:

- `lib/` is already bridge-agnostic — OSC addresses are inline strings behind
  `Seshat.OSC.Transport`; nothing imports or inspects the Python. A fork
  changes **zero lines** in `lib/`.
- The vendored handler files are **byte-identical in either world** — they
  become normal committed modules in the fork.
- New vendored *extensions* (roadmap #3, #8, #15, #20) port for free; they're
  additive files whichever mechanism delivers them.

The switch surface is flat: the installer task, the repo layout, two tests,
and the docs. It is the same size after twenty more tools as it is today.
The one thing that **does** compound is the override count — every additional
override deepens the dependence on the ordering invariant. Hence the
triggers.

## Triggers — fork when any one fires

1. **A second override.** The likeliest source is the session-state listener
   items (device list per track, clip grid): device and clip-slot listeners
   are index-keyed, which is exactly where upstream's unbind bug lives. If
   upstream's listeners exist but carry the bug, the honest fix is another
   override — and at two, the ordering trick is the architecture, not a
   footnote. Any plan for those items must answer "does this create a second
   override?" explicitly.
2. **Needing to edit an upstream file** rather than append beside it —
   e.g. the ACK convention from [bridge-options.md](bridge-options.md)
   turning out to need changes in upstream's OSC server rather than our own
   handler.
3. **Recurring anchor drift.** One upstream refactor that moves the anchors
   is a shrug (the installer prints the manual edits). A second is a pattern.
4. **Distribution.** If Seshat ever ships to users beyond the author,
   "install our AbletonOSC" beats "patch yours" on support burden alone.

## The playbook (run when a trigger fires)

1. Fork `ideoforms/AbletonOSC`; keep upstream as a remote.
2. Move the extension handlers (`browser.py`, `return_track.py`,
   `song_structure.py`, plus any later ones) in as normal package modules;
   register them directly in `__init__.py` and `manager.py`.
3. Fold `track_listeners.py`'s fixes into upstream's track handler; delete
   the override file, the ordering invariant, and the anchor comments in
   `mix abletonosc.install` that explain it.
4. Gut `mix abletonosc.install` down to locate-and-copy: keep the
   probing/`locate!` code, replace patch/anchor logic with a directory sync
   from the fork (vendored via `priv/` or a git dependency — decide then).
5. Tests: `abletonosc_install_test`'s ordering guard dies with the invariant
   it guards; `vendored_addresses_test` survives unchanged in purpose (it
   greps `lib/` literals against what the Python registers) — retarget its
   Python paths.
6. Update CLAUDE.md's module map and vendored-handler section, and
   [.claude/rules/osc.md](../.claude/rules/osc.md).

Ongoing cost from that day: merging upstream releases.

## Shrinking the delta meanwhile

The wrong-object unbind is a genuine upstream bug, not a Seshat-specific
need, and **a PR to AbletonOSC with the fix** would in principle delete the
only override and leave the delta purely additive. But given the state of
upstream above, do not build a plan on it: PRs fixing real gaps have sat
unmerged for years. File it as good citizenship if the mood strikes — cheap,
and it documents the bug publicly for other AbletonOSC users — while
assuming the override is ours to carry. Trigger #1 stands on its own.

## When to reopen this

Don't — this note *is* the reopening protocol. Check the triggers when
planning #19/#22, when an anchor breaks, or when distribution becomes real;
otherwise the standing decision holds.
