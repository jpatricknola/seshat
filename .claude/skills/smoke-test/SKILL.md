---
name: smoke-test
description: Verify a change end-to-end against a live Ableton Live instance using the seshat MCP tools
argument-hint: [optional - what to focus on, e.g. "the new set_track_send tool"]
disable-model-invocation: true
---

Smoke-test Seshat against the live Ableton instance. Focus: **$ARGUMENTS**
(if no focus given, test whatever changed on this branch — check `git diff`
and recent commits).

The test suite deliberately stops at the pure layer; anything reaching
`Transport.query/3` needs a live Ableton. This is that missing live layer, run by
hand. Use the `mcp__seshat__*` tools — they exercise the exact path a real user's
MCP client does.

**You run tests here; you do not invent them.** They live in
[docs/smoke-tests/](docs/smoke-tests/), one file per subsystem, and the change
under test names the ones it needs in its plan doc's `## Live verification`
section — `docs/PLAN_*.md` while the work is in flight,
[docs/archive/](docs/archive/) once `/ship` has run.

**If the plan has no `## Live verification` section, or it plainly doesn't cover
the diff, stop and run `/write-smoke-tests` first.** Deriving checks in your head
and running them in the same breath produces a report nobody can re-run and nobody
reviewed — and it is how the checks once accreted into a single 9,000-word file
instead of into the plans. Write them down, then come back. A branch whose plan
predates this split is the common case, not an exception.

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
3. **If the change touches `priv/AbletonOSC` at all: `mix abletonosc.install` and
   restart Live** (or toggle AbletonOSC off and on under Preferences >
   Link/Tempo/MIDI — `/live/api/reload` does not pick these up). This is not
   bookkeeping. `mix test` greps the submodule in the repo; Live runs the copy in
   Remote Scripts. A green suite says nothing about what Live has actually loaded,
   so **without this every result below is right for the wrong reason.** Confirm
   it took before believing anything, per
   [smoke-tests/bridge.md](docs/smoke-tests/bridge.md).
4. **Baseline Live's `Log.txt`** — record its current byte size
   (`~/Library/Preferences/Ableton/Live <version>/Log.txt`) so later checks read
   only the tail past that offset and pre-existing noise never masquerades as a
   finding.

## Running a test

Work the plan's citations in order, opening each test in
[docs/smoke-tests/](docs/smoke-tests/) as you reach it. Two habits decide whether
a run is worth anything:

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
`docs/smoke-tests/`** as you go, and say you did in the report. A test you
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

Two places, and both matter:

1. **Under each citation in the plan doc.** Write what you observed — the value
   you read back, the wording that came out, what you substituted, what never got
   provoked — not the word "pass". This is the evidence for *this change*, and
   `/ship` archives it with the plan, which is what makes "was this verified"
   answerable after the branch is gone.
2. **On the test itself**, in `docs/smoke-tests/`: update its `*Last run:*` line
   to today's date (from the `date` command) and a few words on the outcome. The
   plan's record answers "was this change verified"; this line answers "has anyone
   exercised this test lately", which no archived plan can. **Leave it alone for a
   test you substituted rather than ran** — the substitution belongs in the report,
   not in the stamp.

A test that **failed** keeps a failing stamp, dated. Don't blank it and don't
soften it; a dated failure is the most useful line in the file.

## Clean up and report

1. Delete any scratch tracks/scenes/clips you created (`delete_track`,
   `delete_scene`, `delete_clip`) or `undo` in-place changes. Restore tempo and
   time signature if you moved them. Leave the session as you found it.
2. Report: what you exercised, what you verified by reading state back, what
   failed or timed out, what was substituted, and what can only be judged by ear
   (sound choice, levels, timing feel) — flag those explicitly for the user to
   check.
3. **Findings that are real but out of scope for the branch** go into
   [docs/ROADMAP.md](docs/ROADMAP.md) as an issue, cited by title, as well as into
   the report. The report is read once; the roadmap is the queue.

### Writing results into the PR

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
