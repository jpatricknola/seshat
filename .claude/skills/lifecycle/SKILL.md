---
name: lifecycle
description: Run the full feature lifecycle unattended — plan → implement → pr-review (with fix loop) → ship — as sequential subagents on a feature branch. Ends by pushing the branch and opening a PR; merging stays with the user. Use when the user wants a roadmap item taken from plan to shipped end to end without stopping at the usual human gates.
argument-hint: [roadmap item; optional model overrides, e.g. "send levels, implement=sonnet" or "model=opus"]
---

Run the full lifecycle for: **$ARGUMENTS** (no item named → the
highest-priority item in [docs/ROADMAP.md](docs/ROADMAP.md)).

You are the orchestrator. Each phase is one **synchronous** `Agent` call
(`run_in_background: false`) — never run phases in parallel or in the
background: each phase consumes the previous phase's report, and running them
inline is the point, so the user can watch every agent's actions in the chat.
Do the phase work only through those agents; your own job is sequencing,
passing reports along, and posting a one-line status between phases.

## Models

Each step has a default model; `$ARGUMENTS` may override per step
(`implement=sonnet review=opus`) or all steps at once (`model=opus`). Spend on
the steps that decide things, save on the steps that execute a decision
already made:

| step | default |
|---|---|
| plan | fable |
| implement | opus |
| review | opus |
| fix | sonnet |
| ship | sonnet |

Pass the resolved model as the `Agent` call's `model` parameter.

## Rules for every phase prompt

Start every agent prompt with this preamble, verbatim:

> You are one phase of an autonomous end-to-end lifecycle run; no user is
> available. Where the skill's instructions say to stop and ask the user,
> instead make the best call yourself, record it in your report under
> "Assumptions", and continue. Report STATUS: blocked only if you genuinely
> cannot proceed. Your final report goes to the next phase's agent, not to a
> human — include every concrete detail the next phase needs (paths, branch
> names, decisions, caveats). Work only in this repository. Never merge to or
> commit on main, and never push or open a PR unless your phase instructions
> explicitly direct it. Do not modify anything under .claude/skills/ or
> .claude/workflows/ — that is the tooling running you, out of scope for the
> feature regardless of what you notice about it.

And end every prompt with:

> End your report with a fields block, one per line, omitting lines you have
> no value for:
> STATUS: complete | blocked
> BRANCH: <feature branch name, if one exists yet>
> BASE_SHA: <full SHA the branch was created from>
> PLAN_PATH: <e.g. docs/PLAN_send_levels.md>
> PR_URL: <opened PR, ship phase only>

When a later phase needs an earlier phase's report, paste the **full report
verbatim** inside a tagged block (`<plan-report>`, `<implementer-report>`,
`<fix-report round="N">`, `<review-findings>`) — never a summary; details you
drop are decisions the next agent will re-make differently.

If any `Agent` call dies or returns nothing usable, treat it as blocked —
except the review phase, which **fails closed**: a dead review agent means
the branch has *not* been reviewed, so stop and hand the branch back
unreviewed rather than proceeding to ship. Whenever you stop early, tell the
user which phase stopped, why (quote the report), and the branch/plan state
so they can pick it up by hand.

## Phase 1 — Plan

Agent prompt: preamble, then —

> Read .claude/skills/plan/SKILL.md and carry out its instructions, with
> $ARGUMENTS = "<the item>". Commit nothing in this phase; just write the
> plan doc and the ROADMAP.md link edit in the working tree. Return
> PLAN_PATH and a report covering: the item chosen, key decisions, open
> questions and how far you got resolving them, and what the implementer
> must check first.

If blocked, stop. If the planner forgot PLAN_PATH, describe it to later
phases as "the single active docs/PLAN_*.md" rather than a made-up path.

## Phase 2 — Implement

Agent prompt: preamble, `<plan-report>` block ("treat its assumptions as
decisions already made"), then —

> Read .claude/skills/implement/SKILL.md and carry out its instructions for
> the plan at <PLAN_PATH>. Create the feature branch in place with
> 'git checkout -b' from wherever HEAD currently is — do not check out or
> switch to another ref first: the planner's plan doc and ROADMAP edit are
> uncommitted in the working tree and must ride along onto the new branch.
> Before you create it, record the current HEAD SHA ('git rev-parse HEAD')
> and return it as BASE_SHA — later phases diff against that exact commit
> rather than guessing the branch point. Always return both BRANCH and
> BASE_SHA, even if you end up blocked partway. When done and
> 'mix precommit' is clean, commit on the feature branch: the plan doc +
> ROADMAP link edit as one commit, then the implementation. Stage files
> individually — never 'git add -A' or 'git add .'. Put your per-plan-item
> report (done/deviated/blocked, assumptions carried) in the final commit
> message body as well as your returned report, so it survives for the
> reviewer.

If blocked, stop. If it reports complete but returns no BRANCH, stop too —
no later phase can be targeted.

## Phase 3 — Review, with fix loop (max 3 rounds)

Keep every fix round's report, oldest first; each round's reviewer gets
**all** of them — a false positive rebutted in round 1 must stay rebutted in
round 3, not resurface because only the latest fix report was passed along.

**Review** agent prompt: preamble, `<implementer-report>` block
("deviations and assumptions are recorded here — judge them, don't
rediscover them"), all `<fix-report round="N">` blocks so far ("findings
rebutted as false positives in these reports stay settled unless you have
new evidence"), then —

> Read .claude/skills/pr-review/SKILL.md and carry out its instructions,
> reviewing branch "<BRANCH>" against commit <BASE_SHA> — the exact commit
> it was branched from, so 'git diff <BASE_SHA>...<BRANCH>' is your change
> set. (No BASE_SHA recorded → derive the merge base with 'git merge-base';
> the branch point may not be main.) The plan doc is <PLAN_PATH>. Check out
> "<BRANCH>" first if HEAD is not already on it — the skill's compile and
> test steps run against the working tree, and testing the wrong checkout
> would pass a review the branch never earned. Report findings only —
> change no code. State your verdict as exactly one of: approve,
> approve_with_nits, or needs_changes, on a line "VERDICT: <verdict>".

On `approve` or `approve_with_nits`, go to Ship. On `needs_changes` after
round 3, stop and report the outstanding findings. Otherwise run a **fix**
agent — preamble, `<review-findings>` block, then —

> You are addressing review findings on branch "<BRANCH>" (check it out if
> needed). The plan doc is <PLAN_PATH>. Fix every finding below that you
> agree with; for any you believe is a false positive, don't change code —
> rebut it in your report with evidence. Run 'mix precommit' until clean,
> then commit the fixes on the same branch with a message referencing the
> review round.

If the fix agent is blocked, stop (include the last review's findings in
your report to the user). Otherwise append its report and loop back to
review.

## Phase 4 — Ship

Agent prompt: preamble, `<implementer-report>` and
`<review-verdict verdict="...">` blocks, then —

> Read .claude/skills/ship/SKILL.md and carry out its instructions for the
> feature just implemented on branch "<BRANCH>" (plan doc: <PLAN_PATH>) —
> the feature was implemented and reviewed on this branch. Get today's date
> from the 'date' command for the archive banner. Commit the close-out
> (roadmap edit, archived plan, any CLAUDE.md/docs sync) on the same branch
> as its own commit.
>
> Then — this phase's explicit exception to the no-push rule — publish the
> branch and open a PR: 'git push -u origin <BRANCH>', then 'gh pr create'.
> Base the PR on the repo's default branch, EXCEPT when this branch was cut
> from somewhere else: it was created from commit <BASE_SHA>, so if that
> commit is not on the default branch, base the PR on the branch containing
> it instead — otherwise the PR would carry unrelated commits that were
> never part of this review.
>
> PR title: the feature name. PR body, in order: a two-sentence summary of
> what the feature does; a link to the archived plan doc; the implementer's
> per-plan-item report; the review verdict and any remaining nits;
> assumptions carried through the run. Both reports are given above — quote
> from them rather than reconstructing them from the diff, and if the
> review left nits, list them verbatim so the PR reader sees what was
> knowingly accepted. End the body with:
> 🤖 Generated with [Claude Code](https://claude.com/claude-code)
> Return the PR URL as PR_URL. If push or PR creation fails (no remote, no
> gh auth), still return STATUS: complete with the close-out done — report
> the failure in your report instead of blocking.

## Final report to the user

Branch, plan path, review verdict (with any accepted nits), whether the
close-out shipped, and the PR URL. If a PR was opened: merging stays with
the user. If not: say why and point at the branch to inspect manually.
