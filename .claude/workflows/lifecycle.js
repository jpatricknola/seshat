export const meta = {
  name: 'lifecycle',
  description: 'Run the full feature lifecycle unattended: plan → implement → pr-review (with fix loop) → ship, all on a feature branch',
  whenToUse: 'When the user wants a roadmap item taken from plan to shipped end to end without stopping at the usual human gates. Ends by pushing the feature branch and opening a PR; merging stays with the user. Args: { item, model, models: { plan | implement | review | fix | ship } } — each step has a default model; models overrides it per step and model overrides every step at once.',
  phases: [
    { title: 'Plan', detail: 'research + write docs/PLAN_*.md', model: 'fable' },
    { title: 'Implement', detail: 'work the plan on a feature branch', model: 'opus' },
    { title: 'Review', detail: 'pr-review the branch (opus), fix (sonnet), re-review — max 3 rounds' },
    { title: 'Ship', detail: 'roadmap/archive/CLAUDE.md close-out on the same branch', model: 'sonnet' },
  ],
}

const item = (args && args.item) || 'the highest-priority item in docs/ROADMAP.md'

// Model per step. Spend on the steps that decide things (plan, implement, review);
// save on the steps that execute an already-made decision (fix, ship).
const DEFAULT_MODELS = {
  plan: 'fable',
  implement: 'opus',
  review: 'opus',
  fix: 'sonnet',
  ship: 'sonnet',
}

// Overrides: args.models = { plan: 'opus', ... } keyed by step name, and/or args.model
// as a blanket default for every step. Both beat DEFAULT_MODELS.
const MODELS = (args && args.models) || {}
const OVERRIDE_ALL = args && args.model
const opts = (step, rest) => ({ ...rest, model: MODELS[step] || OVERRIDE_ALL || DEFAULT_MODELS[step] })

const NONINTERACTIVE = `You are one phase of an autonomous end-to-end lifecycle workflow; no user is available.
Where the skill's instructions say to stop and ask the user, instead make the best call yourself,
record it in your report under "Assumptions", and continue. Return status "blocked" only if you
genuinely cannot proceed. Your final output goes to the next phase's agent, not to a human — include
every concrete detail the next phase needs (paths, branch names, decisions, caveats). Work only in
this repository. Never merge to or commit on main, and never push or open a PR unless your phase
instructions explicitly direct it. Do not modify anything under .claude/skills/ or .claude/workflows/ —
that is the tooling running you, out of scope for the feature regardless of what you notice about it.`

const PHASE_SCHEMA = {
  type: 'object',
  required: ['status', 'report'],
  properties: {
    status: { type: 'string', enum: ['complete', 'blocked'] },
    report: { type: 'string', description: 'Full phase report: what was done, assumptions made, deviations, caveats' },
    branch: { type: 'string', description: 'Feature branch name, if one exists yet' },
    base_sha: { type: 'string', description: 'Full SHA of the commit the feature branch was created from (implement phase)' },
    plan_path: { type: 'string', description: 'Path to the plan doc, e.g. docs/PLAN_send_levels.md' },
    pr_url: { type: 'string', description: 'URL of the opened PR (ship phase only)' },
  },
}

// agent() yields null if the step is skipped or dies on a terminal API error; without this
// the next property access throws and takes the whole run down instead of returning cleanly.
const need = (result, step) =>
  result || { status: 'blocked', report: `The ${step} agent returned no result (skipped, or a terminal error after retries).` }

// Same, for the review step — it is gated on `verdict`, not `status`, and a missing verdict must
// fail closed to needs_changes rather than falling through to Ship unreviewed.
const needReview = (result) =>
  result || {
    verdict: 'needs_changes',
    dead: true,
    report: 'The review agent returned no result (skipped, or a terminal error after retries). Failing closed — the branch has not been reviewed.',
  }

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['verdict', 'report'],
  properties: {
    verdict: { type: 'string', enum: ['approve', 'approve_with_nits', 'needs_changes'] },
    report: { type: 'string', description: 'Full review: verdict reasoning and every finding with file:line and severity' },
  },
}

phase('Plan')
const plan = need(await agent(
  `${NONINTERACTIVE}

Read .claude/skills/plan/SKILL.md and carry out its instructions, with $ARGUMENTS = "${item}".
Commit nothing in this phase; just write the plan doc and the ROADMAP.md link edit in the working tree.
Return plan_path and a report covering: the item chosen, key decisions, open questions and how far you
got resolving them, and what the implementer must check first.`,
  opts('plan', { label: 'plan', schema: PHASE_SCHEMA })
), 'plan')
if (plan.status === 'blocked') return { stopped_at: 'plan', reason: plan.report }
log(`Plan written: ${plan.plan_path || 'see report'}`)

phase('Implement')
const impl = need(await agent(
  `${NONINTERACTIVE}

Read .claude/skills/implement/SKILL.md and carry out its instructions for the plan at ${plan.plan_path}.
Create the feature branch from the CURRENT HEAD (do not switch to or branch from main). Before you
create it, record the current HEAD SHA ('git rev-parse HEAD') and return it as base_sha — later phases
diff against that exact commit rather than guessing the branch point. Always return both branch and
base_sha, even if you end up blocked partway.
The planning phase's report — treat its assumptions as decisions already made:
<plan-report>
${plan.report}
</plan-report>

When done and 'mix precommit' is clean, commit on the feature branch: the plan doc + ROADMAP link edit
as one commit, then the implementation. Stage files individually — never 'git add -A' or 'git add .'.
Put your per-plan-item report (done/deviated/blocked, assumptions carried) in the final commit message
body as well as your returned report, so it survives for the reviewer.`,
  opts('implement', { label: 'implement', schema: PHASE_SCHEMA })
), 'implement')
if (impl.status === 'blocked') return { stopped_at: 'implement', plan: plan.plan_path, reason: impl.report }
const branch = impl.branch
if (!branch) {
  return {
    stopped_at: 'implement',
    plan: plan.plan_path,
    reason: `Implement reported complete but returned no branch name, so no later phase can be targeted.\n\n${impl.report}`,
  }
}
log(`Implemented on ${branch}${impl.base_sha ? ` (from ${impl.base_sha.slice(0, 8)})` : ''}`)

phase('Review')
const MAX_ROUNDS = 3
let review = null
let lastFixReport = ''
for (let round = 1; round <= MAX_ROUNDS; round++) {
  review = needReview(await agent(
    `${NONINTERACTIVE}

Read .claude/skills/pr-review/SKILL.md and carry out its instructions, reviewing branch "${branch}"
against ${impl.base_sha
      ? `commit ${impl.base_sha} — the exact commit it was branched from, so 'git diff ${impl.base_sha}...${branch}' is your change set`
      : `its merge base (derive it with 'git merge-base'; the branch point may not be main)`}.
The plan doc is ${plan.plan_path}.
Implementer's report (deviations and assumptions are recorded here — judge them, don't rediscover them):
<implementer-report>
${impl.report}
</implementer-report>
${lastFixReport ? `A previous review round requested changes; the fixes applied since:\n<fix-report>\n${lastFixReport}\n</fix-report>` : ''}
Report findings only — change no code. Map your verdict to exactly: approve, approve_with_nits, or needs_changes.`,
    opts('review', { label: `review round ${round}`, phase: 'Review', schema: REVIEW_SCHEMA })
  ))
  // review.dead means the agent never ran — another round would just re-fail, and the fix agent
  // would be handed a non-finding to "fix". Stop and hand the branch back unreviewed.
  if (review.dead || review.verdict !== 'needs_changes' || round === MAX_ROUNDS) break

  const fix = need(await agent(
    `${NONINTERACTIVE}

You are addressing review findings on branch "${branch}" (check it out if needed). The plan doc is
${plan.plan_path}. Fix every finding below that you agree with; for any you believe is a false
positive, don't change code — rebut it in your report with evidence. Run 'mix precommit' until clean,
then commit the fixes on the same branch with a message referencing the review round.
<review-findings>
${review.report}
</review-findings>`,
    opts('fix', { label: `fix round ${round}`, phase: 'Review', schema: PHASE_SCHEMA })
  ), 'fix')
  if (fix.status === 'blocked') return { stopped_at: 'fix', branch, reason: fix.report, last_review: review.report }
  lastFixReport = fix.report
}
if (review.verdict === 'needs_changes') {
  return { stopped_at: 'review', branch, plan: plan.plan_path, verdict: review.verdict, findings: review.report }
}
log(`Review verdict: ${review.verdict}`)

phase('Ship')
const ship = need(await agent(
  `${NONINTERACTIVE}

Read .claude/skills/ship/SKILL.md and carry out its instructions for the feature just implemented on
branch "${branch}" (plan doc: ${plan.plan_path}) — the feature was implemented and reviewed on this
branch. Get today's date from the 'date' command for the archive banner. Commit the close-out (roadmap edit,
archived plan, any CLAUDE.md/docs sync) on the same branch as its own commit.

Then — this phase's explicit exception to the no-push rule — publish the branch and open a PR:
'git push -u origin ${branch}', then 'gh pr create'. Base the PR on the repo's default branch, EXCEPT
when this branch was cut from somewhere else: it was created from commit ${impl.base_sha || '(unrecorded)'},
so if that commit is not on the default branch, base the PR on the branch containing it instead —
otherwise the PR would carry unrelated commits that were never part of this review.

PR title: the feature name. PR body, in order: a two-sentence summary of what the feature does; a link
to the archived plan doc; the implementer's per-plan-item report; the review verdict and any remaining
nits; assumptions carried through the run. Both reports are given below — quote from them rather than
reconstructing them from the diff, and if the review left nits, list them verbatim so the PR reader
sees what was knowingly accepted.
<implementer-report>
${impl.report}
</implementer-report>
<review-verdict verdict="${review.verdict}">
${review.report}
</review-verdict>

End the body with:
🤖 Generated with [Claude Code](https://claude.com/claude-code)
Return the PR URL as pr_url. If push or PR creation fails (no remote, no gh auth), still return
status "complete" with the close-out done — report the failure in your report instead of blocking.`,
  opts('ship', { label: 'ship', schema: PHASE_SCHEMA })
), 'ship')

return {
  branch,
  plan: plan.plan_path,
  verdict: review.verdict,
  review: review.report,
  shipped: ship.status === 'complete',
  ship_report: ship.report,
  pr_url: ship.pr_url || null,
  next_step: ship.pr_url
    ? 'Review and merge the PR — merging stays with you.'
    : 'No PR was opened (see ship_report) — inspect the branch and push manually.',
}
