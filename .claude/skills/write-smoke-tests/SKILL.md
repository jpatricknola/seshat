---
name: write-smoke-tests
description: Derive the live checks a change needs and write them into its plan doc — what only a running Ableton can confirm, stated so someone else can run it. Use at plan time, after implementation when the diff outgrew the plan, or on a branch with no plan at all.
argument-hint: [optional - a plan doc, a branch, or what changed; defaults to the current diff]
---

Write the live checks for: **$ARGUMENTS** (no argument → whatever changed on
this branch; check `git diff` against `main` and recent commits).

`mix test` stops at the pure layer by design — anything reaching
`Transport.query/3` needs a running Ableton, and every OSC setter is
fire-and-forget, so a wrong address fails **silently**. The checks you write
here are the only thing standing behind that whole surface. You are not running
them; you are writing them so someone else — or you, later, in front of Live —
can.

**Needs no Ableton.** This is a desk job: the diff, the OSC contract, and the
rules below. If you find yourself wanting to try something in Live to decide
what to write, that is a *measurement*, and it belongs in
[docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) via `/plan` step 5,
not here.

## Where the checks go

Two destinations, and choosing between them is part of the job:

1. **The plan doc's `## Live verification` section** — `docs/PLAN_*.md` for the
   change under test. This is the default and holds the great majority: checks
   that verify *this feature works*. They are acceptance tests, and their job is
   done when they **pass** — not when the feature ships. `/ship` archives the
   ones that ran, and carries any that never did to
   [docs/PLAN_backfill_live_verification.md](docs/PLAN_backfill_live_verification.md)
   rather than retiring them, since archiving an unrun check silently converts
   *never verified* into *verified*.
2. **[docs/live-invariants.md](docs/live-invariants.md)** — checks that outlive
   the feature. Only three kinds qualify:
   - **standing properties** of the system, tied to no feature: the bridge
     answering at all, the loopback bind, the listener rebind after a delete,
     the advertised tool count matching `Definitions.all()`;
   - **tripwires guarding a corrected measurement** — a check that exists
     because someone once believed a wrong number and the documentation would
     happily lead them back to it (the quantize grid spacing, the groove dial
     reading 130%, `hide_view`'s two-name enum);
   - **model-behaviour probes** tied to `Seshat.Instructions` rather than to any
     tool.

   Do **not** write directly into `live-invariants.md`. Write the check into the
   plan and **mark it `<!-- standing -->`** with one line saying which of the
   three kinds it is. `/ship` does the promotion, and marking it here means
   `/ship` is confirming a judgment rather than re-deriving one.

If there is no plan doc — a branch that skipped `/plan`, or a backfill for
something already shipped — create `docs/PLAN_<snake_case_name>.md` with just a
Context paragraph and the `## Live verification` section. A stub plan is a
better home than a checklist file, because `/ship` already knows how to archive
one.

## Deriving the checks

Read the diff properly first: which `Handlers` clauses, whether it's
single-message or `%Command{}` + Registry, whether `Session.State` gained a
field, whether `priv/AbletonOSC` moved. Then work the table — each property of
the change implies a class of check, and most changes trip more than one row.

| The change touches… | …so the plan needs |
|---|---|
| a **vendored address** (`/live/browser/*`, `/live/return_track/*`, `/live/master/*`, or an addition to an upstream file) | a reinstall-and-restart precondition stated at the top of the section — without it every result is right for the wrong reason. Then: these handlers always reply, including on a bad index, so an out-of-range index must come back as an **immediate error naming the real count**, never a ~2s timeout. That distinction is the entire point of the reply envelope, and a stale install is what it detects. |
| a **send-only setter** (never replies — the clip setters, the view setters, `undo`/`redo`, `quantize`) | a read-back through a getter or by eye for **every** assertion. Success, a value Live rejected, and a Remote Scripts copy predating the fork are identical on the wire. Write the check as "read X back and confirm Y", never "call it and confirm it worked". |
| anything reaching **`Transport.query/3`** | checks written on the assumption of **zero** prior coverage. Say so explicitly in the section — this is the reason the section exists, and a reader who assumes the suite has it half-covered will skip the boring half. |
| a **new listener or mirrored field** in `Session.State` | a push-not-poll check: change the value **by hand in Live**, then `get_session_state` **without** `refresh: true`. A missing `start_listen` looks exactly like a working tool until someone tries this. Plus a rebind check: delete the object above it and confirm the listener followed, since a stale binding writes one track's state onto another. |
| **model-facing text** (`Seshat.Instructions`, a tool description) | a behaviour probe explicitly marked as needing a **fresh conversation in a real client** — an agent following an explicit list only proves it can follow the list. Add a delivery check too: instructions reach the model only in a conversation running on the user's computer, and the client truncates at 2,048 characters mid-sentence without saying so. |
| the **advertised MCP schema** (`Seshat.MCP.Schema`, a tool's JSON Schema) | a raw-handshake check via `scripts/mcp_call.py` in the smoke-test skill, count matched against `Definitions.all()`. State the failure mode in the check: a client that rejects the schema refuses the **whole list**, so every tool silently disappears and the session looks like Seshat was never connected. One bad call is not the risk. |
| a **value mapping taken from documentation rather than measurement** | a dial check — read the number off Live's own UI and confirm it says what the mapping claims. This is what caught the `GridQuantization` table being wrong in every row. Any table sourced from the LOM apiref rather than a run is suspect until one of these passes, and the check is a `<!-- standing -->` tripwire. |
| a **guard whose false branch the test suite supplies itself** | a check that the condition is *reachable in Live at all*. A suite feeding the guard its own `false` proves how Seshat reacts, never that Live ever says it. Name the state that produces it for real; if you can't, write the check as "confirm this branch is reachable" and flag it as unmeasured. |
| **timing, debouncing, or a race** | an explicit instruction on **how the calls are issued**, because that is part of the check. Measured 2026-07-31: tool calls emitted in **one model response** arrive ~0.5s apart, while calls needing separate model rounds arrive ~2.1s apart at the floor. A check that doesn't say "ask for the whole sequence in one instruction" silently tests nothing and reports success while doing it. |

Rows the diff doesn't trip are not checks you skipped — don't list them.

## Writing each check so it survives

Every check gets three things, and a check missing any of them decays into a
tick-box within two runs:

1. **What to do**, concretely enough to follow without re-reading the diff —
   named tools, actual values, the sequence.
2. **What you'd see if it worked** — stated as an observation, not as
   "verify it works". The read-back that would catch a silent no-op *is* the
   check.
3. **What its failure means, and the fix it implies.** "Confirm the spacing is
   0.25 and not 0.125, because 0.125 means a 1/32 grid was sent, and the fix is
   `grid_quantization/1`" survives a year. "Verify quantize works" does not.

Drive each behaviour as a realistic sequence rather than one call: a **normal
call** verified through a `get_*` tool rather than the tool's own reply; a
**boundary value** (last track index, `0.0`/`1.0` for levels, `-1.0`/`1.0` for
pan); an **invalid input** confirming the error is clean and immediate rather
than a hang. For anything mutating, include the read-back that would catch a
refusal which quietly *did* send — that's the case most worth catching and the
one a reply string can never show you.

**Cite measurements, never restate them.** The numbers behind these checks live
in [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md), dated and
version-stamped, and operationally in the tool descriptions that act on them.
Link there. A number copied into a checklist is a duplicate nobody will keep in
sync, and that is precisely how the old monolithic smoke-test file became a lab
notebook.

## Say what you did not cover

The section ends with what the checks deliberately leave uncovered, each with
its reason — anything needing ears, hardware routing, a second client, a track
type no tool can create, or a race that can't be provoked on demand. A
verification section that reads as complete is worse than a short one, because
it retires the checks nobody wrote.

If a gap is worth closing later, it goes into [docs/ROADMAP.md](docs/ROADMAP.md)
as an issue, cited by title — same rule as any other finding.

## Report

Say which destination each check went to, which you marked `<!-- standing -->`
and why, which rows of the table the diff tripped, and what you left uncovered.
If you wrote checks for behaviour the plan didn't describe — the diff outgrew
its plan — say that plainly; it is a finding about the plan, not just about the
tests.

Then recommend `/smoke-test` to run them, which needs what this skill did not:
Ableton open, and a bridge matching the repo.
