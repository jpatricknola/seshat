---
name: smoke-test
description: Run the automated live smoke tests against a running Ableton Live instance using the seshat MCP tools — the whole of docs/smoke_tests/auto/, or one named file in it
argument-hint: [optional - one file in docs/smoke_tests/auto/, e.g. `mirror` or `clips.md`; omit to run them all]
disable-model-invocation: true
---

Run Seshat's automated smoke tests against the live Ableton instance.

**This skill runs [docs/smoke_tests/auto/](docs/smoke_tests/auto/) and nothing
else.**

- **No argument** → every test in `auto/`, in the order listed by its
  [README](docs/smoke_tests/auto/README.md).
- **`$ARGUMENTS` names a file** → only that file. Match it loosely — `mirror`,
  `mirror.md` and `auto/mirror.md` all mean
  [docs/smoke_tests/auto/mirror.md](docs/smoke_tests/auto/mirror.md). If it
  matches no file in `auto/`, say so, list what is there, and stop; do not guess
  at the nearest one, and do not fall back to running everything.

**Never open, run, or substitute for anything in
[docs/smoke_tests/manual/](docs/smoke_tests/manual/).** The folder is the run
mode: `auto/` means one agent can run *and judge* the test alone; `manual/`
means a person is required. There is no per-test tag to read and no judgement
call to make. A test in `manual/` whose steps look automatable is still
user-required, because performing is not judging — and approximating one is the
single failure this split exists to prevent.

The test suite deliberately stops at the pure layer; anything reaching
`Transport.query/3` needs a live Ableton. This is that missing live layer, run by
an agent against the running application. Use the `mcp__seshat__*` tools — they
exercise the exact path a real user's MCP client does.

**You run tests here; you do not invent them.** If the behaviour you want to
check has no test, stop and run `/smoke-write`, which owns the rules for which
properties of a change imply which checks. Deriving a check in your head and
running it in the same breath produces a report nobody can re-run and nobody
reviewed — and it is how the checks once accreted into a single 9,000-word file
instead of into the plans.

**Catalog check, before running anything:** every `##` heading in the files you
are about to run has a `Last run` line, and no file in `auto/` contains a
`*Why manual:*` line. That second one means a user-required test is sitting in
the automated folder — a catalog error. Report it and stop rather than deciding
for yourself whether running it is safe.

Reuse scratch material within one file, but clean it up before moving to the
next. Restore global values immediately after the test that changes them; never
rely on a final batch of `undo` calls, because later cleanup operations would
sit above the edit you meant to undo.

What follows is how to run them honestly.

## Preflight

1. Call `get_session_state`. If it errors or times out, Ableton isn't running or
   AbletonOSC isn't installed/enabled — report that and stop. (Setup:
   `mix abletonosc.install`, then enable AbletonOSC as a Control Surface in Live's
   preferences. See [README.md](README.md).)
2. Note what's in the session before you touch anything: track count, names,
   tempo, time signature. You'll restore or clean up afterwards. **If the session
   looks like real work in progress (named tracks, clips), create your own scratch
   tracks rather than modifying existing ones.**
3. **Establish that the bridge Live is running is the bridge you think it is.**
   This is three comparisons, not one, and **all three must hold** before any
   fork-dependent result below means anything:

   ```bash
   git submodule status                                  # a) recorded pin
   git -C priv/AbletonOSC log --oneline -1               #    …vs actual checkout
   git -C priv/AbletonOSC fetch origin && \
     git -C priv/AbletonOSC log --oneline HEAD..origin/master   # b) behind origin?
   diff -rq --exclude=__pycache__ priv/AbletonOSC/abletonosc \
     "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC/abletonosc"  # c)
   ```

   a) **checkout == recorded pin**, b) **nothing on `origin/master` the checkout
   lacks**, c) **installed copy == checkout**, byte for byte.

   On (a), which way it disagrees decides what to do. A checkout **behind** the
   pin means Live is running Python older than the code in this tree — stop, as
   below. A checkout **ahead** of the pin, matching origin, with the bump staged
   but not yet committed, is the ordinary mid-work state while landing a bridge
   change: `git ls-tree HEAD` reads the last *commit*, so staging alone will not
   quiet it. Note it in the report and carry on; the results are about the
   bridge Live is running, and that is the checkout.

   **(c) alone is the trap, and it has already cost a full run.** On 2026-08-05 a
   `/smoke-test bridge` run passed (c) byte for byte and reported six green
   fork-divergence checks — against a bridge whose PR had been merged hours
   earlier. `mix abletonosc.install` copies from the *local submodule checkout*,
   and merging on GitHub does not move it, so the install had faithfully deployed
   pre-merge code. Install and checkout agreed perfectly; they agreed on the wrong
   commit. (c) can only ever tell you the two match — (a) and (b) are what tell you
   *what* they match. Never report a fork-dependent pass on (c) alone.

   If any of the three fails, **do not reinstall, do not pull, and do not restart
   Live** — all three are user actions this skill never takes. Run the tests
   unrelated to the fork, skip the fork-dependent ones, and report precisely which
   comparison failed and what the loaded bridge actually is, by commit.

   Why it matters at all: `mix test` greps the submodule in the repo; Live runs
   the copy in Remote Scripts. A green suite says nothing about what Live has
   actually loaded, so **against a stale copy every result below is right for the
   wrong reason.** All three holding is what licenses the fork-dependent
   results — see [smoke_tests/auto/bridge.md](docs/smoke_tests/auto/bridge.md).

   **Files on disk are still not code in memory.** Live loads Remote Scripts at
   startup; a reinstall since the last launch leaves all three comparisons green
   while Live runs the old bridge from memory. The cheap probe is `bridge.md`'s
   own fast-fail checks — if a divergence the checkout contains does not show on
   the wire, suspect a missing restart before suspecting the code.

   If a change of yours needs the new Python loaded, `mix abletonosc.install`
   and the Live restart belong to whoever is driving that change, before they
   invoke this skill.
4. **Baseline Live's `Log.txt`** — record its current byte size
   (`~/Library/Preferences/Ableton/Live <version>/Log.txt`) so later checks read
   only the tail past that offset and pre-existing noise never masquerades as a
   finding.

## Running a test

Work the files in order, opening each test in
[docs/smoke_tests/auto/](docs/smoke_tests/auto/) as you reach it and reading it
in full before acting on it. Two habits decide whether a run is worth anything:

- **Verify through a `get_*` tool, never through the tool's own reply.** Every OSC
  setter is fire-and-forget; a wrong address fails silently, and a refusal that
  quietly *did* send reads identically to one that didn't. The read-back is the
  test.
- **Follow the test's stated method exactly where it specifies one.** When it says
  to issue a sequence in a single instruction, or to change a value by hand in
  Live rather than through a tool, that is not stylistic — it is what makes the
  test able to fail. Substituting a more convenient method usually produces a pass
  that means nothing.

If a test turns out to be wrong, ambiguous, or overtaken by the code, **fix it in
`docs/smoke_tests/`** as you go, and say you did in the report. A test you
silently reinterpreted is one nobody can re-run the same way.

Two helpers live beside this file, so nothing has to be retyped from memory:

- `scripts/osc_send.py` — send-only OSC, for addresses with no tool yet. Its
  send-only-ness is load-bearing: a client that binds 11001 to hear a reply makes
  Seshat's own reader deaf while it holds the port.
- `scripts/mcp_call.py` — `list` / `schema` / `call` over a real HTTP handshake,
  for anything about the advertised surface or how a rejection reaches a client.

## Judging honestly

The failure mode of a smoke test is not a missed bug — it's a report that reads as
coverage. Four rules:

1. **A run that didn't provoke the condition is not a pass.** Timing-dependent
   tests (a degraded rebuild, a mid-rebuild mutation, a queued-record window) may
   take several attempts. A run that never degraded is a run that did not test
   degradation. Say that, don't tick it.
2. **"Not reproduced" is not "skipped", and neither is "passed".** A test gated on
   a state you can no longer reach — an honest-failure check against an old install
   you already replaced — is reported as *not reproduced*, with the reason. Never
   manufacture the state destructively to tick the box.
3. **A substitution is named as a substitution.** If you stood something in for a
   hands-and-ears step, report what the stand-in covered *and what it lost*.
   Reporting the original as run is the failure this rule exists to stop.
4. **A run that measures something records it where measurements live.** Half
   these tests exist to read a number off Live — a dial reading, a display string,
   whether a property ever goes false. When you observe one, add it to
   [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) dated and
   version-stamped alongside the ones already there, and correct anything it
   contradicts. A measurement that lives only in a run report is one the next
   person re-derives from the LOM apiref, which is exactly how the quantize grid
   table came to be wrong in every row.

## Recording the results

**On the test itself**, in `docs/smoke_tests/auto/`: update its `*Last run:*`
line to today's date (from the `date` command) and a few words on the outcome —
the value you read back, the wording that came out, what never got provoked, not
the word "pass". This line is the only record anywhere that the live layer was
actually exercised, and it is what a later reader uses to decide whether a green
suite means anything.

**Leave the stamp alone for a test you substituted rather than ran** — the
substitution belongs in the report, not in the stamp. A test that **failed**
keeps a failing stamp, dated: don't blank it and don't soften it, a dated failure
is the most useful line in the file.

**If the branch has a plan doc with a `## Live verification` section**, also
write what you observed under each citation this run covered. That record is the
evidence for *that change*, and `/ship` archives it with the plan, which is what
makes "was this verified" answerable after the branch is gone. Citations
resolving into `manual/` are not yours to fill in — leave them for whoever runs
them.

## Clean up and report

1. Delete any scratch tracks/scenes/clips you created (`delete_track`,
   `delete_scene`, `delete_clip`) or `undo` in-place changes. Restore tempo and
   time signature if you moved them. Leave the session as you found it.
2. **Open with counts**: passed, failed, not reproduced, skipped by environment.
   Then what you exercised, what you verified by reading state back, what failed
   or timed out, and what was substituted.
3. **Name what this run could not cover.** A full-`auto/` run should point at
   [docs/smoke_tests/manual/](docs/smoke_tests/manual/) and say what still needs
   a person; a single-file run should say which file it was, so nobody reads it
   as a sweep. A report that lists only successes reads as full coverage and
   quietly retires the checks nobody ran.
4. **Findings that are real but out of scope** go into
   [docs/ROADMAP.md](docs/ROADMAP.md) as an issue, cited by title, as well as into
   the report. The report is read once; the roadmap is the queue.

### Writing results into the PR, if there is one

**If the branch has an open PR, write the results into its body.** A smoke test is
the only evidence that the live half works, and it is exactly the evidence a
reviewer cannot reproduce — the PR body is where it belongs.

```bash
gh pr view --json number,body --jq .number   # empty output = no PR, stop here
```

Read the existing body, edit it, and write it back from a file:

```bash
gh pr view --json body --jq .body > /tmp/pr-body.md
# edit /tmp/pr-body.md, then:
gh pr edit --body-file /tmp/pr-body.md
```

**Never pass `--body` inline and never retype the body from memory** — both
silently discard whatever you did not reproduce, and the plan report and review
verdict already in there are not yours to drop.

Add (or, on a re-run, *replace*) one section headed "Live verification —
smoke-tested DATE", taking DATE from the `date` command, placed directly after the
summary so it reads before the implementation detail. Put in it:

- the headline behaviour, stated as what a user would notice, not as a tool call:
  what was broken before and what happens now;
- a table of what you exercised and what came back — normal call, boundary,
  invalid input, and the read-back that proves the effect actually landed;
- **what you did not cover, named specifically.** An untested client, a hardware
  path you had no input routed for, a test you skipped because Live was in the
  wrong state. A smoke test that reports only successes reads as full coverage and
  quietly retires the checks nobody ran.

Correct anything the body now states falsely — a body written before the run
usually carries an open question the run just answered, and leaving it says the
work is still outstanding.
