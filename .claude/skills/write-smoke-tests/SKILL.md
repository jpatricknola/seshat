---
name: write-smoke-tests
description: Derive the live checks a change needs and cite them in its plan doc — picking existing tests out of docs/smoke-tests/ and writing new ones there when nothing fits. Use at plan time, after implementation when the diff outgrew the plan, or on a branch with no plan at all.
argument-hint: [optional - a plan doc, a branch, or what changed; defaults to the current diff]
---

Write the live verification for: **$ARGUMENTS** (no argument → whatever changed
on this branch; check `git diff` against `main` and recent commits).

`mix test` stops at the pure layer by design — anything reaching
`Transport.query/3` needs a running Ableton, and every OSC setter is
fire-and-forget, so a wrong address fails **silently**. The tests in
[docs/smoke-tests/](docs/smoke-tests/) are the only thing standing behind that
whole surface. You are not running them; you are deciding which ones this change
needs, and writing any it needs that don't exist yet.

**Needs no Ableton.** This is a desk job: the diff, the OSC contract, and the
rules below. If you find yourself wanting to try something in Live to decide what
to write, that is a *measurement*, and it belongs in
[docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) via `/plan` step 5,
not here.

## What you produce

A `## Live verification` section in the change's plan doc — `docs/PLAN_*.md` —
citing each test it needs by **file and title**:

```markdown
## Live verification

Nothing in `mix test` reaches any of this. Run with `/smoke-test`.

- `smoke-tests/devices.md § The stray-track guard fires` — the guard this
  change moves into `_load_onto`; a success reply here is the whole failure.
- `smoke-tests/bridge.md § A bad index errors immediately, not after ~2s` —
  new vendored addresses, so this is the stale-install detector.
- `smoke-tests/mirror.md § The return and master mixer listeners push` —
  three new listeners.

**Uncovered:** whether the return sounds right at all (ears), and the
slow-loading VST path (no third-party effect installed here).
```

Citations only — never copy a test's body into the plan. `/smoke-test` writes its
results underneath each citation, and `/ship` archives the plan with those results
in it, which is how "was this change verified" stays answerable a year later.

If there is no plan doc — a branch that skipped `/plan`, or a backfill for
something already shipped — create `docs/PLAN_<snake_case_name>.md` with a Context
paragraph and this section.

## Choosing the tests

Read the diff properly first: which `Handlers` clauses, whether it's
single-message or `%Command{}` + Registry, whether `Session.State` gained a field,
whether `priv/AbletonOSC` moved. Then work the table — each property of the change
implies a class of check, and most changes trip more than one row.

| The change touches… | …so it needs |
|---|---|
| a **vendored address** (`/live/browser/*`, `/live/return_track/*`, `/live/master/*`, or an addition to an upstream file) | [bridge.md](docs/smoke-tests/bridge.md) — the reinstall precondition, and the bad-index envelope. Without the reinstall every result is right for the wrong reason; these handlers always reply, so an out-of-range index must come back as an **immediate error naming the real count**, never a ~2s timeout. |
| a **send-only setter** (never replies — the clip setters, the view setters, `undo`/`redo`, `quantize`) | a read-back through a getter or by eye for **every** assertion. Success, a value Live rejected, and a Remote Scripts copy predating the fork are identical on the wire. A test that says "call it and confirm it worked" is not a test. |
| anything reaching **`Transport.query/3`** | tests written on the assumption of **zero** prior coverage. Say so in the section — a reader who assumes the suite has it half-covered will skip the boring half. |
| a **new listener or mirrored field** in `Session.State` | a push-not-poll check: change the value **by hand in Live**, then `get_session_state` **without** `refresh: true`. A missing `start_listen` looks exactly like a working tool until someone tries this. Plus a rebind check: delete the object above it and confirm the listener followed. |
| **model-facing text** (`Seshat.Instructions`, a tool description) | [model-behaviour.md](docs/smoke-tests/model-behaviour.md) — and mark it as needing a **fresh conversation in a real client**; an agent following an explicit list only proves it can follow the list. Include the delivery check: instructions reach the model only in a conversation running on the user's computer, and the client truncates at 2,048 characters mid-sentence without saying so. |
| the **advertised MCP schema** (`Seshat.MCP.Schema`, a tool's JSON Schema) | [mcp-surface.md](docs/smoke-tests/mcp-surface.md). State the failure mode: a client that rejects the schema refuses the **whole list**, so every tool silently disappears and the session looks like Seshat was never connected. One bad call is not the risk. |
| a **value mapping taken from documentation rather than measurement** | a dial check — read the number off Live's own UI and confirm it says what the mapping claims. This is what caught the `GridQuantization` table being wrong in every row. Any table sourced from the LOM apiref rather than a run is suspect until one of these passes. |
| a **guard whose false branch the test suite supplies itself** | a check that the condition is *reachable in Live at all*. A suite feeding the guard its own `false` proves how Seshat reacts, never that Live ever says it. Name the state that produces it for real; if you can't, say so and mark the test ⚠️ unmeasured. |
| **timing, debouncing, or a race** | an explicit instruction on **how the calls are issued**, because that is part of the check. Measured 2026-07-31: tool calls emitted in **one model response** arrive ~0.5s apart, while calls needing separate model rounds arrive ~2.1s apart at the floor. A check that doesn't say "ask for the whole sequence in one instruction" silently tests nothing and reports success while doing it. |

Rows the diff doesn't trip are not tests you skipped — don't list them.

## Writing a new test

Only when nothing in the folder fits. Put it in the file that owns that
subsystem — [docs/smoke-tests/README.md](docs/smoke-tests/README.md) has the map —
and give it a title stable enough to cite: renaming it dangles every plan that
referenced it.

Three parts, and a test missing any of them decays into a tick-box within two
runs:

1. **What to do**, concretely enough to follow without re-reading the diff —
   named tools, actual values, the sequence.
2. **What you'd see if it worked** — stated as an observation, not as "verify it
   works". The read-back that would catch a silent no-op *is* the test.
3. **What its failure means, and the fix it implies.** "Confirm the spacing is
   0.25 and not 0.125, because 0.125 means a 1/32 grid was sent, and the fix is
   `grid_quantization/1`" survives a year. "Verify quantize works" does not.

Drive each behaviour as a realistic sequence rather than one call: a **normal
call** verified through a `get_*` tool rather than the tool's own reply; a
**boundary value** (last track index, `0.0`/`1.0` for levels, `-1.0`/`1.0` for
pan); an **invalid input** confirming the error is clean and immediate rather than
a hang. For anything mutating, include the read-back that would catch a refusal
which quietly *did* send — that's the case most worth catching and the one a reply
string can never show you.

Give it a `*Last run: —*` line. Someone else's run stamps it, not you.

**Cite measurements, never restate them.** The numbers behind these tests live in
[docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md), dated and
version-stamped, and operationally in the tool descriptions that act on them. A
number copied into a checklist is a duplicate nobody keeps in sync, and that is
precisely how the old monolithic smoke-test file became a lab notebook.

## Say what you did not cover

The section ends with what the tests deliberately leave uncovered, each with its
reason — anything needing ears, hardware routing, a second client, a track type no
tool can create, or a race that can't be provoked on demand. A verification
section that reads as complete is worse than a short one, because it retires the
checks nobody wrote.

If a gap is worth closing later, it goes into [docs/ROADMAP.md](docs/ROADMAP.md)
as an issue, cited by title — same rule as any other finding. A test reading "if it
misbehaves, the fix is…" is a defect nobody triaged; file it instead.

## Report

Which tests you cited, which you wrote from scratch and into which file, which
rows of the table the diff tripped, and what you left uncovered. If you wrote
tests for behaviour the plan didn't describe — the diff outgrew its plan — say
that plainly; it is a finding about the plan, not just about the tests.

Then recommend `/smoke-test` to run them, which needs what this skill did not:
Ableton open, and a bridge matching the repo.
