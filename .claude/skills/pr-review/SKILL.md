---
name: pr-review
description: Review a PR or branch against its implementation plan — plan conformance, correctness, test coverage, style, and ripple effects. Use when the user asks to review a PR, a branch, or the current changes before merging.
argument-hint: [PR number or branch; defaults to current branch vs main]
---

Review this change: **$ARGUMENTS** (no argument → current branch against `main`).

You are reviewing, not fixing. Report findings; only edit code if the user
asks afterwards. Read the *code*, not just the diff — a diff hunk that looks
fine can still be wrong in context, and the worst review misses are things
that are *absent* from the diff, which no amount of staring at hunks reveals.

1. **Establish the change set.** For a PR number, use `gh pr view` and
   `gh pr diff`; for a branch, `git diff main...<branch>` plus `git log` for
   the commit story. Read every changed file in full, not just the hunks —
   you need the surrounding code to judge the change.

2. **Find the implementation plan.** Look, in order: a `docs/PLAN_*.md`
   matching the feature, the relevant [docs/ROADMAP.md](docs/ROADMAP.md)
   entry, the PR description, the commit messages. Read it before reading
   any code so you know what the change is *supposed* to do. If no plan
   exists anywhere, say so and review against the intent you can infer —
   but flag that intent is inferred, not stated.

3. **Judge plan conformance.** Three failure modes, check for each:
   - **Incomplete** — plan items with no corresponding code. List each one.
   - **Deviation** — code that does something the plan didn't say. Deviations
     aren't automatically wrong, but each one deserves a sentence: justified
     improvement, or scope drift?
   - **Unplanned extras** — changes unrelated to the plan riding along in the
     PR. Flag them; they belong in their own PR.

4. **Review correctness.** For each changed file, hunt for real defects:
   logic errors, unhandled edge cases (empty lists, nil, index 0 vs 1,
   boundary values), error paths that swallow or mangle failures, race
   conditions in GenServer/PubSub code. Seshat-specific traps:
   - Every OSC address must appear verbatim in
     [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) (or be one of
     ours in [priv/abletonosc/browser.py](priv/abletonosc/browser.py)). UDP
     fails silently — a plausible-looking address is the most dangerous bug
     in this codebase. Check every one.
   - Handler clauses see string keys only; track indices are 0-based; pan is
     -1.0..1.0, volume 0.0..1.0.
   - `%Command{}` only for multi-step sequences; single messages go straight
     to Transport. No hand-written MCP components — they're generated.

5. **Review test coverage.** Is every new behavior actually exercised — not
   just "a test file exists," but do the assertions pin down the behavior the
   plan asked for? Check the standard obligations: tool count bumped in
   `definitions_test.exs` if a tool was added, MCP parity covered by the
   generated-component tests, nothing testing through `Transport.query/3`
   (needs live Ableton — test the pure layer instead). Then run `mix test`
   yourself; never take the PR's word that tests pass.

6. **Review style and readability.** Naming that lies or mumbles, functions
   doing two jobs, duplication of something that already exists in the
   codebase (grep before assuming it's new), comments that narrate instead of
   explaining a constraint, inconsistency with how neighbouring code does the
   same thing. Keep this proportionate — style notes are suggestions, not
   blockers, and say so.

7. **Check ripple effects — what *else* should have changed.** New module →
   CLAUDE.md module map. Shipped roadmap item → ROADMAP.md (or note that
   `/ship` should run after merge). Changed tool-adding flow or new OSC
   gotcha → [.claude/docs/](.claude/docs/). New tool → does its description
   in `Definitions` read as usable prompt text for a model that can't see
   the code? Stale references anywhere to renamed/moved things.

8. **Verify and report.** Run `mix precommit` on the branch. Then write the
   review:
   - **Verdict first** — one of: approve, approve with nits, needs changes —
     with a one-sentence reason.
   - **Findings ranked by severity** (bugs → plan gaps → test gaps → ripple
     effects → style), each with a `file:line` reference and, for bugs, the
     concrete scenario in which it misbehaves. A finding you can't state a
     failure scenario for is a style note, not a bug.
   - Skip the compliment padding. If a section has no findings, one line
     saying you checked it and it's clean is worth more than manufactured
     praise — and worth more than silence, which reads as "didn't look."
