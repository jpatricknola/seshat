# Smoke tests

The live layer `mix test` cannot reach. Anything past `Transport.query/3` needs
a running Ableton, and every OSC setter is fire-and-forget — success, a value
Live rejected, and a Remote Scripts copy predating the fork are identical on the
wire. These files are the only thing standing behind that whole surface.

One file per subsystem. Read the one you need; nothing here is meant to be read
in full.

| File | Covers |
|---|---|
| [bridge.md](bridge.md) | the fork answering at all, the reply envelope, the listener rebind |
| [network-boundary.md](network-boundary.md) | the loopback bind, the fixed reply route, browser exports, the Elixir decoder |
| [mirror.md](mirror.md) | `Session.State` — unknowns, degraded rebuilds, refresh coalescing |
| [mcp-surface.md](mcp-surface.md) | the advertised tool list and how a rejection reaches a client |
| [model-behaviour.md](model-behaviour.md) | what the model *says* — `Seshat.Instructions` and tool descriptions |
| [catalog.md](catalog.md) | `search_library` ranking as a conversation, browser preview |
| [devices.md](devices.md) | the device tools, on regular, return and master chains |
| [clips.md](clips.md) | clip properties and `quantize_clip` |
| [recording.md](recording.md) | `record_clip` / `stop_recording` |
| [views.md](views.md) | `show_view` / `hide_view` / `get_view_state` and the follow cam |
| [transport.md](transport.md) | tempo, time signature, swing and groove |
| [undo.md](undo.md) | undo granularity and the `can_undo` / `can_redo` guards |

## How a test gets run

1. **`/plan` writes a `## Live verification` section** listing the tests that
   change needs, each cited as `smoke-tests/<file>.md § <Title>`. It uses
   `/write-smoke-tests`, which owns the rules for which properties of a change
   imply which tests. If nothing here fits, that skill writes a new test into
   the right file and cites it like any other.
2. **`/smoke-test` runs them** against live Ableton and records the result in
   the plan, under each citation — what was observed, what was substituted,
   what never got provoked. That record is the evidence for *that change*, and
   it stays with the plan when `/ship` archives it.
3. **It also stamps the test's own `Last run` line here.** The plan's record
   answers "was this change verified"; the `Last run` line answers "has anyone
   exercised this test lately", which no archived plan can.

`/full-smoke` sweeps this whole folder regardless of branch, in the subset that
needs no human, and names everything it couldn't cover.

## What goes in, and what comes out

A test lives here for as long as the behaviour it checks exists. **Passing is
not grounds for removal** — every setter this covers can silently stop landing
next month exactly as easily as it could on the day it shipped, so these are
regression tests, not acceptance tests. A test is deleted when its tool, its
address, or its guarantee is deleted, and at no other time.

Two things a test must not be:

- **A lab notebook.** A check may state the number it expects — "confirm the
  spacing is 0.25" is not runnable otherwise — but it may never be that
  number's only home. Measurements live in
  [../abletonosc-api-docs.md](../abletonosc-api-docs.md), dated and
  version-stamped, and operationally in the code that acts on them. Link there.
  A number copied into a checklist is a duplicate nobody keeps in sync, which
  is how the old monolithic checklist rotted.
- **A bug report.** A check reading "if it misbehaves, the fix is…" is a defect
  nobody triaged. It belongs in [../ROADMAP.md](../ROADMAP.md). Naming the fix a
  *failure* implies is different and correct — that is what makes a check
  survive a year.

## Writing one so it survives

Three parts, and a test missing any of them decays into a tick-box within two
runs: **what to do**, concretely enough to follow without re-reading the diff;
**what you'd see if it worked**, stated as an observation rather than "verify it
works"; and **what its failure means, and the fix it implies**.

`*Last run: —*` means nobody has ever run it. Leave it alone if you substituted
something for the check — the substitution goes in the run report, not here.
