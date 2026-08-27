---
name: pr-review
description: Review a PR or branch against its implementation plan — plan conformance, correctness, pure and agent-runnable live test coverage, style, and ripple effects. Use when the user asks to review a PR, a branch, or the current changes before merging.
argument-hint: [PR number or branch; defaults to current branch vs main]
---

Review this change: **$ARGUMENTS** (no argument → current branch against `main`).

You are reviewing, not fixing. Report findings; only edit code if the user
asks afterwards. Read the *code*, not just the diff — a diff hunk that looks
fine can still be wrong in context, and the worst review misses are things
that are *absent* from the diff, which no amount of staring at hunks reveals.

1. **Establish the change set.** For a PR number, use `gh pr view` and
   `gh pr diff`; for a branch, diff it against the given base ref — `main`
   when none was specified — with `git diff <base>...<branch>`, plus
   `git log` for the commit story. Read every changed file in full, not just
   the hunks — you need the surrounding code to judge the change.

   **If the diff touches `priv/AbletonOSC`, you have not seen the change.** A
   submodule bump renders as two lines — `-Subproject commit <old>` /
   `+Subproject commit <new>` — and every line of Python behind it is
   invisible. Expand it before reviewing anything else:

   ```
   git -C priv/AbletonOSC log --oneline <old>..<new>
   git -C priv/AbletonOSC diff <old>..<new>
   ```

   Review that Python as carefully as the Elixir: it runs inside Live, it
   cannot be unit-tested here, and a mistake in it fails silently over UDP.
   Check the fork's `SESHAT.md` was updated too — it is the only record of
   what diverges from upstream, and a divergence missing from it is invisible
   at the next upstream merge.

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
     [priv/AbletonOSC/API.md](priv/AbletonOSC/API.md) (or be one of
     ours in [priv/AbletonOSC/abletonosc/browser.py](priv/AbletonOSC/abletonosc/browser.py)). UDP
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

6. **Run the plan's zero-user smoke tests.** Read
   [.claude/skills/smoke-test/SKILL.md](.claude/skills/smoke-test/SKILL.md) in
   full for its preflight, execution, judgment, and cleanup rules. From the
   plan's `## Live verification` section, resolve every cited
   `smoke_tests/<folder>/<file>.md § <Title>` to its exact heading. **The
   folder it resolves into decides what you do with it:**
   - in `smoke_tests/auto/` → run the complete cited test against Live.
   - in `smoke_tests/manual/` → do not run it and do not substitute for it;
     list it under **User-required** with its `*Why manual:*` reason.
   - Missing citation or heading → a plan/test-catalog finding.

   Resolve the path rather than judging the test's content: a citation whose
   steps *look* automatable but sits in `manual/` is still user-required, and
   deciding otherwise mid-review is how a human-judged check gets quietly
   approximated by an agent.

   This is the plan-scoped subset, **not** `/smoke-test`'s full run over
   `auto/`. Use that skill's preflight semantics either way: never reinstall the
   bridge, restart Live, restart Seshat, click or type in Live, route hardware,
   use eyes or ears, or open another client. If bridge drift or another
   environmental precondition prevents a test, mark it **skipped by
   environment** and state exactly what is missing.

   The running Seshat instance must be serving the checkout under review. If
   that cannot be established without user action, do not treat its results as
   PR verification; mark the affected tests as skipped by environment.

   Temporarily mutate only scratch Live state needed by a test and restore it
   immediately. Then follow the smoke-test skill's **Recording the results**
   rules for the plan: directly beneath each executed citation, write dated,
   concrete evidence of what was observed (including failures, substitutions,
   or a condition that was not provoked), not merely "passed". This plan update
   is the one intentional repository mutation made by a review. Do not update
   smoke-test `Last run` lines, API docs, ROADMAP, or the PR body as part of PR
   review. Do not write a result for a user-required or environment-skipped test
   that was not executed; identify it in the review report instead.

   A failed smoke test is a blocking correctness finding. A test that was
   unavailable, skipped, or did not provoke its condition is **incomplete**,
   never passed, but is not by itself proof that the code is wrong. If there is
   no plan or no `## Live verification` section, report that no plan-scoped live
   tests were available; do not invent them during review.

7. **Review style and readability.** Naming that lies or mumbles, functions
   doing two jobs, duplication of something that already exists in the
   codebase (grep before assuming it's new), comments that narrate instead of
   explaining a constraint, inconsistency with how neighbouring code does the
   same thing. Keep this proportionate — style notes are suggestions, not
   blockers, and say so.

8. **Check ripple effects — what *else* should have changed.** New module →
   CLAUDE.md module map. Shipped roadmap item → ROADMAP.md (or note that
   `/ship` should run after merge). Changed tool-adding flow or new OSC
   gotcha → [.claude/docs/](.claude/docs/). New tool → does its description
   in `Definitions` read as usable prompt text for a model that can't see
   the code? Stale references anywhere to renamed/moved things.

9. **Verify and report.** Aside from recording smoke evidence in the plan,
   verify without mutating the tree — you're reviewing, not fixing. Record the
   initial working-tree state, then run `mix compile --warnings-as-errors`,
   `mix test`, and `mix format --check-formatted`. Do **not** run `mix precommit` here:
   its `format` and `deps.unlock --unused` steps rewrite files, and a
   formatting change made during a review either gets absorbed into someone
   else's commit or is left behind uncommitted while the branch ships
   unformatted. An unformatted file is a *finding*, not something you silently
   correct. If a verification command changes anything outside the intended
   plan evidence, restore only that command's changes before reporting; never
   discard changes that existed before the review. Then write the review:
   - **Verdict first** — one of: approve, approve with nits, needs changes —
     with a one-sentence reason.
   - **Live verification next** — one of: passed, failed, incomplete, not
     applicable. Name every agent test run and its observed result, every
     environment-skipped or unprovoked test, and every User-required test.
   - **Findings ranked by severity** (bugs → plan gaps → test gaps → ripple
     effects → style), each with a `file:line` reference and, for bugs, the
     concrete scenario in which it misbehaves. A finding you can't state a
     failure scenario for is a style note, not a bug.
   - Skip the compliment padding. If a section has no findings, one line
     saying you checked it and it's clean is worth more than manufactured
     praise — and worth more than silence, which reads as "didn't look."
