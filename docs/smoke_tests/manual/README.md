# Manual smoke tests

Everything in this folder needs a person. That is what the folder means — see
[../README.md](../README.md) for the rules governing both halves of the suite.

**Grouped by what the run demands, not by subsystem.** These are the tests that
don't get run, and the reason is set-up cost: routing audio, opening a fresh
Desktop conversation, quitting Ableton. Grouping by faculty means one set-up
buys a whole file, which is the difference between a sitting and a good
intention. Each test carries a `*Why manual:*` line naming its specific
requirement.

| File | Needs | Tests |
|---|---|---|
| [conversation.md](conversation.md) | a fresh conversation; judges what the model says and picks | 19 |
| [on-screen.md](on-screen.md) | eyes on Live, or hands on Live's own controls | 16 |
| [engineered-state.md](engineered-state.md) | the app or session put into a state no tool can create | 10 |
| [by-ear.md](by-ear.md) | audio routed somewhere you can hear it | 6 |

## Finding a subsystem's manual tests

The automated half is still grouped by subsystem in [../auto/](../auto/). When a
change touches one, its human-judged checks are here:

| Subsystem | Where its manual tests live |
|---|---|
| model behaviour / `Seshat.Instructions` | all of [conversation.md](conversation.md) |
| views and the follow cam | [conversation.md](conversation.md) (sequencing), [on-screen.md](on-screen.md) (the visibility matrix) |
| devices | [on-screen.md](on-screen.md) (chains, mixer), [by-ear.md](by-ear.md) (bypass, cue), [conversation.md](conversation.md) (the audition loop) |
| catalog / `search_library` | [conversation.md](conversation.md) (ranking as a conversation), [by-ear.md](by-ear.md) (browser preview) |
| clips and quantize | [on-screen.md](on-screen.md) |
| the session mirror | [engineered-state.md](engineered-state.md) |
| recording | [engineered-state.md](engineered-state.md) (guards), [on-screen.md](on-screen.md) (follow cam), [by-ear.md](by-ear.md) (the audio take) |
| transport — swing and groove | [by-ear.md](by-ear.md) (swing), [on-screen.md](on-screen.md) (the groove dial), [conversation.md](conversation.md) (wording with no groove assigned) |
| bridge / network boundary | [engineered-state.md](engineered-state.md) (stale install, reply route, decoder), [on-screen.md](on-screen.md) (listener rebind, listener pushes) |
| MCP surface | [conversation.md](conversation.md) (Claude Desktop lists the tools) |
| audio output | [on-screen.md](on-screen.md) (Settings agreement), [by-ear.md](by-ear.md) (the switch) |
| undo | [engineered-state.md](engineered-state.md) (`can_undo=False`) |

## Reporting

The same honesty rules as the automated half, and they bite harder here because
nothing re-runs these for you:

- **A run that didn't provoke the condition is not a pass.** Several of these
  are races or depend on a state you may not reach; say what didn't happen.
- **"Not reproduced" is not "skipped", and neither is "passed."**
- **A substitution is named as a substitution** — what it covered *and what it
  lost*. Reporting the original as run is the failure this rule exists to stop.
- **A measurement goes where measurements live** —
  [../../abletonosc-api-docs.md](../../abletonosc-api-docs.md), dated and
  version-stamped, not only in a run report.

Stamp `*Last run:*` on the test itself with the date and a few words on the
outcome. A dated failure is the most useful line in the file; don't blank it and
don't soften it.
