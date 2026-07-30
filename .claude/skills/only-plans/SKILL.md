---
name: only-plans
description: Write and review plans for the top N roadmap items in one unattended run — plan → plan-review (with rival-plan tournament) per item, as sequential subagents — and stop there. No branch, no commits, no implementation. Use when the user wants the front of the roadmap turned into reviewed plan docs to read before deciding what to build.
argument-hint: [how many roadmap items to plan, e.g. "3"; defaults to 1]
---

Plan the top **$ARGUMENTS** items in [docs/ROADMAP.md](docs/ROADMAP.md) (no
argument, or a non-integer → **1**). Each item gets the `/lifecycle` planning
front end — plan, then plan-review, with a rival-plan tournament on
disagreement — and the run stops there. Nothing is implemented, nothing is
committed, no branch is created.

You are the orchestrator. Each phase is one **synchronous** `Agent` call
(`run_in_background: false`). Items are planned **one at a time, in roadmap
order** — never fan out across items in parallel: every planner edits
docs/ROADMAP.md to add its plan link, and concurrent planners would clobber
each other's edits and each research a roadmap the others are rewriting. Do
the phase work only through those agents; your own job is sequencing, passing
reports along, and posting a one-line status between phases.

## Before the first agent

Read the `## #N · <title>` headings in [docs/ROADMAP.md](docs/ROADMAP.md) and
take the first N titles. Resolve them **once, up front**: nothing ships during
this run, so ranks do not move, and pinning the list now means item 3 is the
same item whether it is planned first or last. Pass each item to its agents
**by title, never by rank** — that is this repository's rule for citing roadmap
items anywhere outside the file itself.

If the roadmap holds fewer than N items, plan all of them and say so in the
final report. Post the resolved list to the user before starting so they can
see what the run will cover.

## Models

Every agent in this skill runs on **fable**, passed as the `Agent` call's
`model` parameter. This is `/lifecycle`'s plan-review reasoning applied to the
whole run: these phases decide things rather than execute a decision already
made, the reviewer decides a phase by approving — an approval leaves no
artifact for anyone to check — and the judge is a decision nothing downstream
reviews, since this run has no implement or code-review phase behind it at
all. Rival and judge fire only on disagreement.

## Rules for every phase prompt

Start every agent prompt with this preamble, verbatim:

> You are one phase of an unattended planning run; no user is available. Where
> the skill's instructions say to stop and ask the user, instead make the best
> call yourself, record it in your report under "Assumptions", and continue.
> Report STATUS: blocked only if you genuinely cannot proceed. Your final
> report goes to the next phase's agent, not to a human — include every
> concrete detail the next phase needs (paths, decisions, caveats). Work only
> in this repository.
>
> **This run writes plans and nothing else.** Commit nothing, create no
> branch, push nothing, open no PR, and change no code — the only files you
> touch are plan docs under docs/ and the ROADMAP.md entry linking them. Do
> not modify the skills running this run — .claude/skills/only-plans/, plan/,
> plan-review/ — or anything under .claude/workflows/: that is the tooling
> running you. Every other project skill (.claude/skills/smoke-test/,
> add-tool/, …) is ordinary repository content, but this run only plans, so
> edits to it belong in the plan doc as a numbered part, not in the tree.
>
> **Several plan docs are active at once in this run** — one per roadmap item
> planned so far, all uncommitted in the working tree. Never rely on "the
> single active docs/PLAN_*.md": work on the exact path you are given and
> leave every other plan doc alone.
>
> If `priv/AbletonOSC` is empty, run `git submodule update --init` before
> anything else — it is the AbletonOSC fork, git worktrees do not populate
> submodules, and the plan skill directs you to read the real Python source
> there rather than the installed copy in Remote Scripts.

And end every prompt with:

> End your report with a fields block, one per line, omitting lines you have
> no value for:
> STATUS: complete | blocked
> PLAN_PATH: <e.g. docs/PLAN_send_levels.md>
> PLAN_VERDICT: <plan-review phase only>
> JUDGE_VERDICT: <judge agent only>

When a later phase needs an earlier phase's report, paste the **full report
verbatim** inside a tagged block (`<plan-report>`, `<plan-review-findings>`,
`<judge-decision>`) — never a summary; details you drop are decisions the next
agent will re-make differently.

## The loop — per item, in order

### Phase 1 — Plan

Agent prompt: preamble, the already-planned block below if this is not the
first item, then —

> Read .claude/skills/plan/SKILL.md and carry out its instructions, with
> $ARGUMENTS = "<the item title>". Plan that item and no other, even if the
> roadmap ranks it below others — the run planning it has already chosen it.
> Write the plan doc and the ROADMAP.md link edit in the working tree and stop
> there. Return PLAN_PATH and a report covering: the item planned, key
> decisions, open questions and how far you got resolving them, and what an
> implementer must check first.

From the second item on, prepend a `<plans-already-written>` block listing
every earlier item in this run by title and plan path, then —

> Those plans exist in the working tree and are part of this run. The plan
> skill directs you to fold true prerequisites into your scope; where a
> prerequisite is already covered by one of those plans, cite its path and
> depend on it instead of re-planning it. Read them before deciding scope. If
> your item turns out to be wholly absorbed by an earlier plan in this run,
> write no doc: report STATUS: complete, say which plan absorbed it, and name
> the section that covers it.

If the planner reports the item absorbed, record that and move to the next
item — no review phase for a doc that does not exist.

### Phase 2 — Plan review, with tournament (conditional)

One review agent always; a rival author and a judge only if the reviewer
disagrees. There is no revise loop — the reviewer either approves or
commissions a competing plan, and the judge's decision is final.

**Review** agent prompt: preamble, `<plan-report>` block, then —

> Read .claude/skills/plan-review/SKILL.md and carry out § Review for the plan
> at <PLAN_PATH> — that exact path, not "the single active plan doc". Apply
> corrections to the plan doc itself as that section directs, but commit
> nothing. State your verdict on a line "PLAN_VERDICT: <verdict>".

On `approve` or `approve_with_corrections`, the item is done. On `rival`, run
two more agents in sequence.

**Rival** agent prompt: preamble, `<plan-review-findings>` block, then —

> Read .claude/skills/plan-review/SKILL.md and carry out § Rival. The review
> findings above are your brief; read the roadmap entry for "<item title>"
> yourself as that section directs — those two are your inputs and nothing
> else is. Do not open <PLAN_PATH> until your own plan is written — that
> section says when to read it and what to do with it. Write to the `_alt.md`
> path § Rival names, never to <PLAN_PATH>. Commit nothing. Return the path
> you wrote.

**Judge** agent prompt: preamble, `<plan-review-findings>` block ("contested
claims, not facts — read them only after you have formed your own view of both
plans"), then —

> Read .claude/skills/plan-review/SKILL.md and carry out § Judge, choosing
> between <PLAN_PATH> as plan A and <rival path> as plan B. Promote the winner
> and delete the loser file exactly as that section directs, but commit
> nothing. Its rule that exactly one docs/PLAN_*.md may be left active applies
> to **this pair only** — the other plan docs in the tree belong to other
> items in this run and must be left untouched. State "JUDGE_VERDICT:
> <verdict>" and return PLAN_PATH for the surviving doc.

On `neither`, leave both docs on disk, record the judge's reasoning, and move
on to the next item — that verdict is a judgment about the roadmap item
itself, which is the user's to make, and it says nothing about the items still
to be planned.

Otherwise confirm the tournament left one doc for this item — if the judge
left a `_alt.md` behind on a verdict other than `neither`, delete it and note
that you did.

### A blocked item does not end the run

This is the one place this skill deliberately parts with `/lifecycle`, which
stops at the first blocked phase. There, phases feed each other and a blocked
plan makes the rest meaningless. Here the items are independent: N−1 usable
plans are worth having, and an item that could not be planned is itself a
finding. So on a blocked or dead agent, record what happened, clean up any
half-written doc the phase left, and continue with the next item.

The plan-review phase still **fails open** within an item, as in `/lifecycle`:
a dead reviewer, rival, or judge means keeping plan A, and only plan A on
disk — delete any stray `docs/PLAN_*_alt.md` before moving on — and saying in
the final report which agent died. A gate meant to improve plans should not
become a new way for an item to end with nothing. A dead *planner*, by
contrast, leaves the item with no plan at all: skip its review phase and go on.

## Final report to the user

A row per item, in roadmap order: title, plan path, plan-review verdict, and —
where a tournament ran — which plan won and what decided it. Then, plainly:

- Every item that ended blocked, absorbed, or on a `neither` verdict, with why.
- Any agent that died and what was cleaned up because of it.
- The open questions each plan left for the user's call, gathered together —
  this run's whole output is documents to read, and these are the parts that
  need a person.

Close with the state of the tree: N plan docs and the ROADMAP link edits are
**uncommitted on the current branch**, nothing was committed or pushed, and
implementation starts when the user picks a plan and runs `/implement` (or
`/lifecycle` for the full arc on a single item).
