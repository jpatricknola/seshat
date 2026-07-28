---
name: lifecycle
description: Run the full feature lifecycle unattended — plan → plan-review (with rival-plan tournament) → implement → pr-review (with fix loop) → ship — as sequential subagents on a feature branch. Ends by pushing the branch and opening a PR; merging stays with the user. Use when the user wants a roadmap item taken from plan to shipped end to end without stopping at the usual human gates.
argument-hint: [roadmap item; optional model overrides, e.g. "send levels, implement=sonnet" or "judge=opus" or "model=opus"]
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
| plan-review | fable |
| rival | fable |
| judge | fable |
| implement | opus |
| review | opus |
| fix | sonnet |
| ship | sonnet |

The whole plan-review phase runs on fable deliberately. Its reviewer decides a
phase by approving — an approval leaves no artifact for anyone to check — and
its judge is the only decision in this pipeline that nothing downstream
reviews: a judge that picks the worse plan stays invisible until the feature is
built wrong. Rival and judge fire only on disagreement, so the aggregate cost
is nearer one extra agent per plan than three.

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
>
> If `priv/AbletonOSC` is empty, run `git submodule update --init` before
> anything else — it is the AbletonOSC fork, git worktrees do not populate
> submodules, and two test files fail without it. If your phase changes the
> Python in there, `git -C priv/AbletonOSC checkout master` first (a fresh
> `submodule update` leaves a detached HEAD), commit and push inside the
> submodule, and `git add priv/AbletonOSC` from the root to stage the pin.
> Note in your report that Live still runs the copy installed by
> `mix abletonosc.install`, so no test in this repo has executed that Python.

And end every prompt with:

> End your report with a fields block, one per line, omitting lines you have
> no value for:
> STATUS: complete | blocked
> BRANCH: <feature branch name, if one exists yet>
> BASE_SHA: <full SHA the branch was created from>
> PLAN_PATH: <e.g. docs/PLAN_send_levels.md>
> PLAN_VERDICT: <plan-review phase only>
> JUDGE_VERDICT: <judge agent only>
> VERDICT: <code review phase only>
> PR_URL: <opened PR, ship phase only>

When a later phase needs an earlier phase's report, paste the **full report
verbatim** inside a tagged block (`<plan-report>`, `<plan-review-findings>`,
`<judge-decision>`, `<implementer-report>`, `<fix-report round="N">`,
`<review-findings>`) — never a summary; details you drop are decisions the
next agent will re-make differently.

If any `Agent` call dies or returns nothing usable, treat it as blocked —
with two exceptions at opposite ends. The code review phase **fails closed**:
a dead review agent means the branch has *not* been reviewed, so stop and
hand the branch back unreviewed rather than proceeding to ship. The plan
review phase **fails open**: code review still stands behind it, so a dead
agent there means continuing to implement with an unreviewed plan and saying
so in the final report — a gate meant to improve plans should not become a new
way for the run to end with nothing.

Failing open means carrying on with **plan A, and only plan A on disk**. Which
of the three agents died decides the cleanup: a dead reviewer leaves nothing to
clean; a dead rival or a dead judge can leave a `docs/PLAN_*_alt.md` behind, and
you delete it before Phase 3 — everything downstream assumes exactly one active
plan doc, and the implementer, having no user to ask, would have to guess
between two. Say in the final report which agent died and that you deleted the
rival.

Whenever you stop early, tell the user which phase stopped, why (quote the
report), and the branch/plan state so they can pick it up by hand.

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

## Phase 2 — Plan review, with tournament (conditional)

One review agent always; a rival author and a judge only if the reviewer
disagrees. There is no revise loop here — the reviewer either approves or
commissions a competing plan, and the judge's decision is final.

**Review** agent prompt: preamble, `<plan-report>` block, then —

> Read .claude/skills/plan-review/SKILL.md and carry out § Review for the
> plan at <PLAN_PATH>. Apply corrections to the plan doc itself as that
> section directs, but commit nothing — the plan doc and the ROADMAP edit are
> still uncommitted in the working tree and Phase 3 commits them. State your
> verdict on a line "PLAN_VERDICT: <verdict>".

On `approve` or `approve_with_corrections`, go to Phase 3. On `rival`, run
two more agents in sequence.

**Rival** agent prompt: preamble, `<plan-review-findings>` block, then —

> Read .claude/skills/plan-review/SKILL.md and carry out § Rival. The review
> findings above are your brief; read the roadmap entry yourself as that
> section directs — those two are your inputs and nothing else is. Do not open
> <PLAN_PATH> until your own plan is written — that section says when to read
> it and what to do with it. Write to the `_alt.md` path § Rival names, never
> to <PLAN_PATH>. Commit nothing. Return the path you wrote.

**Judge** agent prompt: preamble, `<plan-review-findings>` block ("contested
claims, not facts — read them only after you have formed your own view of
both plans"), then —

> Read .claude/skills/plan-review/SKILL.md and carry out § Judge, choosing
> between <PLAN_PATH> as plan A and <rival path> as plan B. Promote the
> winner and delete the loser file exactly as that section directs, but commit
> nothing. State "JUDGE_VERDICT: <verdict>" and return PLAN_PATH for the
> surviving doc.

On `neither`, stop: report both plans — by path, both still on disk — and the
judge's reasoning to the user. That verdict is a judgment about the roadmap
item itself, which is theirs to make.

Otherwise carry the surviving PLAN_PATH into Phase 3, and confirm before you do
that only one `docs/PLAN_*.md` is active — the judge is directed to delete the
loser, and a rival left behind is a plan doc the implementer cannot choose
between with no user to ask. If one survives the judge, delete it yourself and
note it.

## Phase 3 — Implement

Agent prompt: preamble, `<plan-report>` block ("treat its assumptions as
decisions already made"), `<plan-review-findings>` and — if a tournament ran
— `<judge-decision>` ("the plan you are given is the one that survived this;
its corrections and amendments are already in the doc"), then —

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

## Phase 4 — Review, with fix loop (max 3 rounds)

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

## Phase 5 — Ship

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

Branch, plan path, the plan-review verdict — and if a tournament ran, which
plan won and what decided it — the code review verdict (with any accepted
nits), whether the close-out shipped, and the PR URL. If a PR was opened:
merging stays with the user. If not: say why and point at the branch to
inspect manually.
