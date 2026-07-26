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
   - Questions marked *needs live Ableton / the installed AbletonOSC
     source*: resolve them **first**, before the parts that depend on them —
     read the installed source at
     `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`, or test the
     address against a running Live. If a question truly can't be resolved
     yet, implement the plan's recorded assumption and carry the ⚠️ into
     your final report — never silently pick something else.

3. **Set up the branch.** If on `main`, create a feature branch named after
   the feature. Never implement directly on `main`.

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

7. **Report per plan item.** Walk the plan's parts and mark each one
   **done**, **deviated** (what and why), or **blocked** (on what). Then:
   open questions resolved vs. still carried, what only Ableton can confirm,
   and the suggested next step — `/pr-review` once the branch is pushed as a
   PR. Leave committing and pushing to the user unless they've said
   otherwise.
