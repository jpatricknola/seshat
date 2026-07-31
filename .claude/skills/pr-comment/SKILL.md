---
name: pr-comment
description: Review a pushed GitHub branch or PR and post the findings as a PR comment — plan conformance, correctness, test coverage, style, and ripple effects. Read-only on the code; the deliverable is the comment. Use when the user asks to review a branch on GitHub and leave feedback rather than fix it.
argument-hint: [PR number or remote branch; defaults to the current branch's PR]
---

Review this change and leave the findings as a comment: **$ARGUMENTS** (no
argument → the PR for the current branch).

This is [pr-review](../pr-review/SKILL.md)'s posture with two differences that
govern everything below: **the change lives on GitHub, not necessarily in this
working tree**, and **the deliverable is a posted comment, not a report in the
terminal and not a code change.** Do not edit a single file of the change —
not a typo, not a format run. Every fix you would have made becomes a sentence
in the comment.

Read the *code*, not just the diff — a diff hunk that looks fine can still be
wrong in context, and the worst review misses are things that are *absent*
from the diff, which no amount of staring at hunks reveals.

1. **Resolve the target and fetch it.** You are reviewing a remote ref; nothing
   here should assume the local branch matches it.

   - A number → `gh pr view <n>` for the head branch, base ref, title and body.
   - A branch name → `gh pr list --head <branch>` to find its PR.
   - No argument → the current branch's PR, same way.

   Then `git fetch origin <head-branch> <base-branch>` and work from
   `origin/<head>` vs `origin/<base>`. If the branch has no PR, say so and ask
   whether to open one or comment on the head commit instead (`gh api` on the
   commit-comments endpoint) — don't silently pick one.

   Establish the change set with `git diff origin/<base>...origin/<head>` and
   `git log origin/<base>..origin/<head>` for the commit story. Read every
   changed file **in full at the reviewed revision** —
   `git show origin/<head>:<path>` — not the local copy, which may be a
   different version of the same file.

   **If the diff touches `priv/AbletonOSC`, you have not seen the change.** A
   submodule bump renders as two lines — `-Subproject commit <old>` /
   `+Subproject commit <new>` — and every line of Python behind it is
   invisible. Fetch inside the submodule first, or the new commit won't exist
   locally:

   ```
   git -C priv/AbletonOSC fetch origin
   git -C priv/AbletonOSC log --oneline <old>..<new>
   git -C priv/AbletonOSC diff <old>..<new>
   ```

   Review that Python as carefully as the Elixir: it runs inside Live, it
   cannot be unit-tested here, and a mistake in it fails silently over UDP.
   Check the fork's `SESHAT.md` was updated too — it is the only record of
   what diverges from upstream, and a divergence missing from it is invisible
   at the next upstream merge.

2. **Read what's already been said.** `gh pr view <n> --comments` plus
   `gh api repos/{owner}/{repo}/pulls/<n>/comments` for inline review threads.
   A comment repeating a finding someone already raised — or one the author
   already answered — is noise that makes the whole review easier to ignore.
   Note which of your findings are *new*, and if a previous round's finding
   is still unfixed, say it's still open rather than reporting it fresh.

3. **Find the implementation plan.** Look, in order: a `docs/PLAN_*.md`
   matching the feature (check the branch's copy — the plan may only exist
   there), the relevant [docs/ROADMAP.md](docs/ROADMAP.md) entry, the PR
   description, the commit messages. Read it before reading any code so you
   know what the change is *supposed* to do. If no plan exists anywhere, say
   so and review against the intent you can infer — but flag that intent is
   inferred, not stated.

4. **Judge plan conformance.** Three failure modes, check for each:
   - **Incomplete** — plan items with no corresponding code. List each one.
   - **Deviation** — code that does something the plan didn't say. Deviations
     aren't automatically wrong, but each one deserves a sentence: justified
     improvement, or scope drift?
   - **Unplanned extras** — changes unrelated to the plan riding along in the
     PR. Flag them; they belong in their own PR.

5. **Review correctness.** For each changed file, hunt for real defects:
   logic errors, unhandled edge cases (empty lists, nil, index 0 vs 1,
   boundary values), error paths that swallow or mangle failures, race
   conditions in GenServer/PubSub code. Seshat-specific traps:
   - Every OSC address must appear verbatim in
     [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) (or be one of
     ours in the fork's handler modules). UDP fails silently — a
     plausible-looking address is the most dangerous bug in this codebase.
     Check every one.
   - Handler clauses see string keys only; track indices are 0-based; pan is
     -1.0..1.0, volume 0.0..1.0.
   - `%Command{}` only for multi-step sequences; single messages go straight
     to Transport. No hand-written MCP components — they're generated.

6. **Review test coverage.** Is every new behavior actually exercised — not
   just "a test file exists," but do the assertions pin down the behavior the
   plan asked for? Check the standard obligations: tool count bumped in
   `definitions_test.exs` if a tool was added, MCP parity covered by the
   generated-component tests, nothing testing through `Transport.query/3`
   (needs live Ableton — test the pure layer instead).

7. **Verify, without leaving a trace.** You need the branch checked out to run
   anything, and you must give the tree back exactly as you found it.

   - `git status --porcelain` first. **If the working tree is dirty, do not
     check anything out.** Skip verification entirely and say so in the
     comment — an uncommitted change of the user's is worth more than a test
     run.
   - Clean tree → note the current ref (`git rev-parse --abbrev-ref HEAD`),
     `git checkout origin/<head>`, run `mix compile --warnings-as-errors`,
     `mix test`, and `mix format --check-formatted`, then `git checkout -` back.
     If the diff bumped the submodule, `git submodule update` after checkout
     and again after returning, or the Python-grepping tests read the wrong
     revision.
   - Never `mix precommit` here: its `format` and `deps.unlock --unused` steps
     rewrite files, and you have no commit to put the result in. An
     unformatted file is a *finding*, not something you silently correct.
   - Whatever happens, end on the ref you started on with the tree clean.
     Confirm it before you post.

8. **Review style and readability.** Naming that lies or mumbles, functions
   doing two jobs, duplication of something that already exists in the
   codebase (grep before assuming it's new), comments that narrate instead of
   explaining a constraint, inconsistency with how neighbouring code does the
   same thing. Keep this proportionate — style notes are suggestions, not
   blockers, and say so.

9. **Check ripple effects — what *else* should have changed.** New module →
   CLAUDE.md module map. Shipped roadmap item → ROADMAP.md (or note that
   `/ship` should run after merge). Changed tool-adding flow or new OSC
   gotcha → [.claude/docs/](.claude/docs/). New tool → does its description
   in `Definitions` read as usable prompt text for a model that can't see
   the code? Stale references anywhere to renamed/moved things.

10. **Write the comment, then post it.** Write the body to a file in the
    scratchpad first and post with `gh pr comment <n> --body-file <path>` —
    never inline a long body through the shell. Structure:

    - **Verdict first** — one of: approve, approve with nits, needs changes —
      with a one-sentence reason.
    - **Findings ranked by severity** (bugs → plan gaps → test gaps → ripple
      effects → style), each with a `file:line` reference and, for bugs, the
      concrete scenario in which it misbehaves. A finding you can't state a
      failure scenario for is a style note, not a bug. Link line references as
      GitHub permalinks against the head SHA where it helps.
    - **What was verified**, in one line: the commands you ran and their
      result, or the plain statement that verification was skipped and why.
    - Skip the compliment padding. If a section has no findings, one line
      saying you checked it and it's clean is worth more than manufactured
      praise — and worth more than silence, which reads as "didn't look."

    Write it as the repo owner would write it: plain prose, no attribution
    footer, no "generated by" line, no emoji headers. It's a review comment on
    their own PR.

    Show the user the comment URL `gh` returns, and a two-line summary of the
    verdict. Don't re-print the whole comment in the terminal — it's already
    on the PR.
