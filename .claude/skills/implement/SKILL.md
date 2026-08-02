---
name: implement
description: Implement the code change described in a docs/PLAN_*.md — work the numbered parts in order, resolve its open questions, verify, and report per-item status. Use when the user says to implement, build, or start on a planned feature.
argument-hint: [plan or feature, e.g. "send levels"; defaults to the only active plan]
---

Implement the plan for: **$ARGUMENTS**

1. **Find the plan.** A `docs/PLAN_*.md` outside `archive/` matching
   $ARGUMENTS; with no argument, the single active plan doc — if there are
   several, stop and ask which. If there's no plan doc at all, stop and
   suggest `/plan` first: this skill implements a written plan, it doesn't
   invent one.

2. **Read the whole plan before touching code** — including Out of scope
   (equally binding: don't build what it excludes) and Open questions:
   - A question marked *needs the user's call* that is still unanswered:
     stop and ask now, before code makes the choice by accident.
   - Questions marked *needs live Ableton / the AbletonOSC source*: resolve
     them **first**, before the parts that depend on them — read the source
     in [priv/AbletonOSC](priv/AbletonOSC), or measure against a running
     Live. Read the **submodule**, never the copy under
     `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`: that copy is
     an *output* of `mix abletonosc.install` and may be older than the fork,
     so a question resolved against it can be answered by code we no longer
     ship.

     **Check whether Live is running (`ps aux | grep -i "[A]bleton Live"`)
     before accepting any question as unresolvable.** The plan's own reason
     for leaving it open is *not* binding on you — it was written in another
     session, and a planner that had no Live, or that refused to touch the
     one it had, hands you a question that is trivially answerable in yours.
     If Live is running, measure. For an address that already ships, `mix run`
     a one-off script against `Seshat.OSC.Transport` and read the reply; for
     one that doesn't exist yet, use the probe rig under "Measuring the Live
     API without building the feature first" in
     [.claude/docs/ableton-osc-reference.md](.claude/docs/ableton-osc-reference.md).
     Prefer the non-destructive form of a measurement — the same property
     read at a boundary you can reach without spending the user's open set —
     and where only a destructive form exists (a new set, an exhausted undo
     history, a deleted track), say exactly what you need and ask for it
     rather than assuming.

     Only a question that *no* available resource can answer may stay open:
     implement the plan's recorded assumption, carry the ⚠️ into your final
     report, and name the resource that was missing. Never silently pick
     something else, and never let an assumption a running Live could have
     settled reach the reviewer as settled — a whole part built on an
     unmeasured property is a part nobody downstream can check.

3. **Set up the branch.** If on `main`, create a feature branch named after
   the feature. Never implement directly on `main`.

   If `priv/AbletonOSC` is empty, run `git submodule update --init` — a fresh
   worktree doesn't populate it, and the Python-grepping tests fail until it
   does. **If the plan has a Python half**, also `git -C priv/AbletonOSC
   checkout master` now: `submodule update` leaves a detached HEAD, and a
   commit made there belongs to no branch and pushes nowhere. Full sequence in
   [.claude/rules/osc.md](.claude/rules/osc.md).

4. **Work the numbered parts in plan order.** The ordering usually encodes
   real dependencies (contract → handler → distribution). Per part:
   - Follow the repo shape where it applies: tool additions go
     Definitions → Handlers → count bump per
     [.claude/docs/adding-a-tool.md](.claude/docs/adding-a-tool.md); MCP
     components are generated, never hand-written.
   - Re-verify each OSC address against
     [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) as you use
     it, even though the plan already did — transcription between plan and
     code is exactly where a silent-fail typo creeps in.
   - Write the tests the plan's Testing section promised *with* the part,
     not as a batch at the end.
   - **A Python part is committed in the submodule, not in Seshat.** Commit
     and push inside `priv/AbletonOSC`, then `git add priv/AbletonOSC` from
     the root to stage the bumped SHA. Leave the Seshat commit itself to the
     user as usual, but the submodule commit has to exist or the pin points
     at nothing. Add the divergence to `SESHAT.md` in the fork in the same
     commit — that file is the only record of what we changed and why.

5. **When reality contradicts the plan, stop and weigh it.** Small mechanical
   corrections (a misremembered arity, a better existing helper): make the
   change and log it as a deviation. Anything that changes the plan's shape —
   an OSC address that doesn't behave as documented, a part that's
   unnecessary or insufficient: pause and tell the user before building
   around it. Either way the plan doc stays as written — it's a
   point-in-time record (`/ship` archives it as "the plan as written
   *before* implementation") — deviations live in your report, where
   `/pr-review` will look for them. "As written" includes anything
   [/plan-review](.claude/skills/plan-review/SKILL.md) corrected before you
   started: those edits are part of the plan you're implementing, not
   deviations from it.

6. **Verify.** `mix precommit` clean — compile warnings, format, full test
   suite. If behavior needs a live Ableton to confirm, say exactly what to
   check and suggest `/smoke-test`; never claim end-to-end verification you
   couldn't perform.

   **If you changed `priv/AbletonOSC`, a green suite proves less than usual.**
   The tests grep the submodule in this repo; Live runs the copy that
   `mix abletonosc.install` made. Nothing you wrote in Python has executed.
   Say so plainly in the report and tell the user to reinstall and restart
   Live before smoke-testing — don't let "248 tests, 0 failures" stand in for
   evidence it works.

7. **Report per plan item.** Walk the plan's parts and mark each one
   **done**, **deviated** (what and why), or **blocked** (on what). Then:
   open questions resolved vs. still carried — and for each still carried,
   whether Live was running and what you measured — what only Ableton can confirm,
   and the suggested next step — `/pr-review` once the branch is pushed as a
   PR. Leave committing and pushing to the user unless they've said
   otherwise.
