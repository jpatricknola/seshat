export const meta = {
  name: 'lifecycle',
  description: 'Run the full feature lifecycle unattended: plan → implement → pr-review (with fix loop) → ship, all on a feature branch',
  whenToUse: 'When the user wants a roadmap item taken from plan to shipped end to end without stopping at the usual human gates. Ends by pushing the feature branch and opening a PR; merging stays with the user.',
  phases: [
    { title: 'Plan', detail: 'research + write docs/PLAN_*.md' },
    { title: 'Implement', detail: 'work the plan on a feature branch' },
    { title: 'Review', detail: 'pr-review the branch, fix, re-review (max 3 rounds)' },
    { title: 'Ship', detail: 'roadmap/archive/CLAUDE.md close-out on the same branch' },
  ],
}

const item = (args && args.item) || 'the highest-priority item in docs/ROADMAP.md'

const NONINTERACTIVE = `You are one phase of an autonomous end-to-end lifecycle workflow; no user is available.
Where the skill's instructions say to stop and ask the user, instead make the best call yourself,
record it in your report under "Assumptions", and continue. Return status "blocked" only if you
genuinely cannot proceed. Your final output goes to the next phase's agent, not to a human — include
every concrete detail the next phase needs (paths, branch names, decisions, caveats). Work only in
this repository. Never merge to or commit on main, and never push or open a PR unless your phase
instructions explicitly direct it. Do not commit or modify anything
under .claude/skills/ or .claude/workflows/ — those are unrelated work in progress in this tree.`

const PHASE_SCHEMA = {
  type: 'object',
  required: ['status', 'report'],
  properties: {
    status: { type: 'string', enum: ['complete', 'blocked'] },
    report: { type: 'string', description: 'Full phase report: what was done, assumptions made, deviations, caveats' },
    branch: { type: 'string', description: 'Feature branch name, if one exists yet' },
    plan_path: { type: 'string', description: 'Path to the plan doc, e.g. docs/PLAN_send_levels.md' },
    pr_url: { type: 'string', description: 'URL of the opened PR (ship phase only)' },
  },
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
const plan = await agent(
  `${NONINTERACTIVE}

Read .claude/skills/plan/SKILL.md and carry out its instructions, with $ARGUMENTS = "${item}".
Commit nothing in this phase; just write the plan doc and the ROADMAP.md link edit in the working tree.
Return plan_path and a report covering: the item chosen, key decisions, open questions and how far you
got resolving them, and what the implementer must check first.`,
  { label: 'plan', schema: PHASE_SCHEMA }
)
if (plan.status === 'blocked') return { stopped_at: 'plan', reason: plan.report }
log(`Plan written: ${plan.plan_path || 'see report'}`)

phase('Implement')
const impl = await agent(
  `${NONINTERACTIVE}

Read .claude/skills/implement/SKILL.md and carry out its instructions for the plan at ${plan.plan_path}.
Create the feature branch from the CURRENT HEAD (do not switch to or branch from main).
The planning phase's report — treat its assumptions as decisions already made:
<plan-report>
${plan.report}
</plan-report>

When done and 'mix precommit' is clean, commit on the feature branch: the plan doc + ROADMAP link edit
as one commit, then the implementation. Stage files individually — never 'git add -A' or 'git add .'.
Put your per-plan-item report (done/deviated/blocked, assumptions carried) in the final commit message
body as well as your returned report, so it survives for the reviewer.`,
  { label: 'implement', schema: PHASE_SCHEMA }
)
if (impl.status === 'blocked') return { stopped_at: 'implement', plan: plan.plan_path, reason: impl.report }
const branch = impl.branch
log(`Implemented on ${branch}`)

phase('Review')
const MAX_ROUNDS = 3
let review = null
let lastFixReport = ''
for (let round = 1; round <= MAX_ROUNDS; round++) {
  review = await agent(
    `${NONINTERACTIVE}

Read .claude/skills/pr-review/SKILL.md and carry out its instructions, reviewing branch "${branch}"
against its merge base (the branch it was created from — use 'git merge-base' with the reflog or the
implementer's report below; it may not be main). The plan doc is ${plan.plan_path}.
Implementer's report (deviations and assumptions are recorded here — judge them, don't rediscover them):
<implementer-report>
${impl.report}
</implementer-report>
${lastFixReport ? `A previous review round requested changes; the fixes applied since:\n<fix-report>\n${lastFixReport}\n</fix-report>` : ''}
Report findings only — change no code. Map your verdict to exactly: approve, approve_with_nits, or needs_changes.`,
    { label: `review round ${round}`, phase: 'Review', schema: REVIEW_SCHEMA }
  )
  if (review.verdict !== 'needs_changes' || round === MAX_ROUNDS) break

  const fix = await agent(
    `${NONINTERACTIVE}

You are addressing review findings on branch "${branch}" (check it out if needed). The plan doc is
${plan.plan_path}. Fix every finding below that you agree with; for any you believe is a false
positive, don't change code — rebut it in your report with evidence. Run 'mix precommit' until clean,
then commit the fixes on the same branch with a message referencing the review round.
<review-findings>
${review.report}
</review-findings>`,
    { label: `fix round ${round}`, phase: 'Review', schema: PHASE_SCHEMA }
  )
  if (fix.status === 'blocked') return { stopped_at: 'fix', branch, reason: fix.report, last_review: review.report }
  lastFixReport = fix.report
}
if (review.verdict === 'needs_changes') {
  return { stopped_at: 'review', branch, plan: plan.plan_path, verdict: review.verdict, findings: review.report }
}
log(`Review verdict: ${review.verdict}`)

phase('Ship')
const ship = await agent(
  `${NONINTERACTIVE}

Read .claude/skills/ship/SKILL.md and carry out its instructions for the feature just implemented on
branch "${branch}" (plan doc: ${plan.plan_path}). You are on the feature branch and the code IS on this
branch — that satisfies the skill's "confirm it shipped" check; do not require a merge to main.
Get today's date from the 'date' command for the archive banner. Commit the close-out (roadmap edit,
archived plan, any CLAUDE.md/docs sync) on the same branch as its own commit.

Then — this phase's explicit exception to the no-push rule — publish the branch and open a PR:
'git push -u origin ${branch}', then 'gh pr create' against the repo's default branch. PR title: the
feature name. PR body, in order: a two-sentence summary of what the feature does; a link to the
archived plan doc; the implementer's per-plan-item report; the review verdict with any remaining nits;
assumptions carried through the run. End the body with:
🤖 Generated with [Claude Code](https://claude.com/claude-code)
Return the PR URL as pr_url. If push or PR creation fails (no remote, no gh auth), still return
status "complete" with the close-out done — report the failure in your report instead of blocking.`,
  { label: 'ship', schema: PHASE_SCHEMA }
)

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
