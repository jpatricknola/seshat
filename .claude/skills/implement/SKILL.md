---
name: implement
description: Implement the code change described in a docs/PLAN_*.md — work the numbered parts in order, resolve its open questions, verify, and report per-item status. Use when the user says to implement, build, or start on a planned feature.
argument-hint: [plan or feature, e.g. "send levels"; defaults to the only active plan]
---

Implement the plan for: **$ARGUMENTS**

1. **Find the plan.** A `docs/PLAN_*.md` outside `archive/` matching
   $ARGUMENTS; with no argument, the single active plan doc — several, ask
   which; none, stop and suggest `/plan`. This skill implements a written plan,
   it doesn't invent one.

2. **Read the whole plan first**, Out of scope included — it binds as tightly as
   the parts. Settle Open questions before the parts that depend on them:
   - *Needs the user's call* → ask now, before code makes the choice by
     accident.
   - *Needs the AbletonOSC source* → read [priv/AbletonOSC](priv/AbletonOSC),
     not the installed copy under
     `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`, which is an
     output of `mix abletonosc.install` and may lag the fork.
   - *Needs live Ableton* → check (`ps aux | grep -i "[A]bleton Live"`) and
     measure. **The plan's reason for leaving it open doesn't bind you** — it
     was written in another session. One-off `mix run` script against
     `Seshat.OSC.Transport` for an address that ships; the probe rig in
     [ableton-osc-reference.md](.claude/docs/ableton-osc-reference.md) for one
     that doesn't. Prefer a non-destructive reading, and ask before spending the
     user's set.

   Only a question no available resource can answer stays open: implement the
   plan's assumption, carry the ⚠️ into your report, name what was missing.

3. **Set up the branch.** If on `main`, create a feature branch named after the
   feature — never implement on `main`. Empty `priv/AbletonOSC` →
   `git submodule update --init`, or the Python-grepping tests fail. Plan with a
   Python half → also `git -C priv/AbletonOSC checkout master`, since
   `submodule update` leaves a detached HEAD whose commits push nowhere. Full
   sequence in [.claude/rules/osc.md](.claude/rules/osc.md).

4. **Work the parts in plan order** — it usually encodes real dependencies
   (contract → handler → distribution). Per part:
   - Tool additions go Definitions → Handlers → count bump
     ([adding-a-tool.md](.claude/docs/adding-a-tool.md)); MCP components are
     generated, never hand-written.
   - Re-verify every OSC address against
     [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) as you use it —
     plan-to-code transcription is where a silent-fail typo creeps in.
   - Write that part's promised tests with it, not as a batch at the end.
   - **Python is committed in the submodule**: commit and push inside
     `priv/AbletonOSC` (the pin points at nothing until you do), then
     `git add priv/AbletonOSC` from the root, recording the divergence in the
     fork's `SESHAT.md` in the same commit.

5. **When reality contradicts the plan, weigh it.** Mechanical corrections (a
   wrong arity, a better existing helper): change it and log a deviation. Shape
   changes — an address that misbehaves, a part that's unnecessary or
   insufficient: stop and tell the user. The plan doc stays as written either
   way; it's a point-in-time record, and deviations belong in your report, where
   [/pr-review](.claude/skills/pr-review/SKILL.md) looks for them. What
   [/plan-review](.claude/skills/plan-review/SKILL.md) corrected before you
   started is part of the plan, not a deviation from it.

6. **Verify.** `mix precommit` clean. Never claim verification you couldn't
   perform: name what needs a live Ableton and suggest `/smoke-test`. **If the
   implementation outgrew the plan** — behaviour the plan's `## Live
   verification` section doesn't cover, which a deviation usually implies —
   run `/smoke-write` to bring that section up to the diff before
   suggesting anyone run it. Checks derived at run time by whoever happens to be
   in front of Live are checks nobody reviewed. **If you changed
   `priv/AbletonOSC`, green proves less than usual** — the tests grep the
   submodule, Live runs the installed copy, so your Python has never executed.
   Say so, and tell the user to reinstall and restart Live.

7. **Report per plan item**: **done**, **deviated** (what and why) or
   **blocked** (on what). Then open questions resolved vs. carried — for each
   carried one, whether Live was running and what you measured — what only
   Ableton can confirm, and the next step (`/pr-review` once pushed). Leave
   committing and pushing to the user unless they've said otherwise.
