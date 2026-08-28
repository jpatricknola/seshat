# Automated conversation-routing evaluations

_Options doc · 28 Aug 2026 · evaluates how to replace hand-typed fresh-
conversation routing checks with repeatable model/tool-trace measurements ·
decides nothing by itself, but may feed a plan for an eval harness_

> **Decision 2026-08-28:** promoted to the top of `docs/ROADMAP.md`. The first
> roadmap slice is this doc's two-case base/head decision experiment; a general
> fixture engine follows only if that experiment validates the route.

## Verdict up front

Build a **record-only MCP evaluation server plus a headless-client runner**.
The server advertises the exact Seshat instructions and tool schemas under
test, answers reads from synthetic session fixtures, records every tool call,
and simulates mutations in memory without touching OSC or Ableton. The runner
starts a fresh `claude -p` process for each prompt, points it only at that
server, and judges the resulting structured trace with deterministic
predicates.

For a tool-surface PR, run the same corpus against snapshots from the base and
head revisions. Report semantic success, first-call validity, wrong target,
extra calls and refusal rate over several fresh trials. That tests the actual
claim of PR #77 — whether the consolidated surface routes better — rather than
merely checking that `set_mixer` works after it has already been selected.

Do **not** put stochastic external-model runs in `mix precommit`. Make this an
agent-runnable, on-demand gate for changes to `Definitions`, tool descriptions
or `Instructions`; keep the ordinary suite deterministic. A much smaller live
smoke test remains responsible for proving that correctly selected calls land
in Ableton.

## Capability frame

The harness needs six separate capabilities:

| Capability | Input | Output | Constraint |
|---|---|---|---|
| Present the real surface | Instructions plus `tools/list` from one revision | What the model sees | Preserve names, descriptions, schemas and ordering exactly |
| Supply discoverable state | Synthetic tracks, returns, clips and notes | Plausible tool results | No Live, OSC or user setup |
| Exercise routing | Natural-language prompt in a fresh conversation | Model tool calls and final reply | Pin model; isolate from repo instructions and unrelated tools |
| Record behavior | MCP calls and results | Ordered structured trace | Never retain hidden reasoning; no mutation outside the fixture |
| Judge behavior | Trace plus fixture | Deterministic pass/fail and metrics | Accept valid numeric variation; do not use prose equality |
| Compare revisions | Same cases and model against base/head surfaces | A/B delta | Several trials because model choice is stochastic |

The first gate is **routing**, not musical judgment. “Did it call
`set_mixer target: return`?” is machine-judgeable. “Did ‘a touch’ sound like
the right amount?” remains an ear check and should not contaminate the routing
score.

## Existing layers and the Live-native ladder

This feature sits above Live; none of its capabilities requires a new Ableton
operation.

| Capability | Existing rung | Result |
|---|---|---|
| Surface presentation | `Seshat.Tools.Definitions`, `Seshat.Instructions`, generated MCP components | Already complete; snapshot or serve these unchanged |
| Session/clip discovery replies | `get_session_state`, `get_clip_slots`, `get_clip_notes` contracts | Fixture the replies; executing their OSC reads would add risk without testing routing |
| Tool-call capture | MCP `tools/call`; Claude Code stream JSON includes tool-use events | Existing protocol boundary is sufficient |
| Mutation execution | `Handlers` → OSC → Live | Deliberately stop above this rung; simulate success in memory |
| Final live proof | Existing smoke-test system | Retain a small separate check after routing passes |

The fork, LOM, Extensions SDK and Accessibility rungs are not applicable: the
harness must not reach any of them. A solution that needs Ableton running has
failed to isolate the behavior being measured.

## Options

### A. Headless Claude Code plus a record-only MCP server — recommended

Run the installed Claude Code CLI non-interactively and allow only the eval
server’s MCP tools. Measured locally 2026-08-28 with Claude Code 2.1.220:
`--print`, `--output-format stream-json`, `--model`, `--tools ""`,
`--mcp-config`, `--strict-mcp-config`, `--allowedTools`,
`--system-prompt` and `--no-session-persistence` are all available. Earlier
project work measured subscription authentication with `claude -p`; `--bare`
must not be used because it disables OAuth/keychain authentication.

Strengths:

- exercises a real supported client and its MCP handling;
- uses the logged-in subscription rather than adding an API key to Seshat;
- exposes structured tool-use events, so judgment needs no transcript parsing;
- can run base and head against the same pinned model and fixtures;
- never touches Live when pointed at the recorder.

Costs:

- requires Claude Code installed and logged in;
- stochastic and externally metered, so unsuitable for `mix precommit`;
- Claude Code is one client, not proof of Claude Desktop behavior;
- exact stream-event fields need capturing again before implementation because
  the archived measurement was made against CLI 2.1.114.

### B. Direct provider API with the tool schemas

Send the same prompts and schemas through a provider’s tool-use API and execute
fixture responses inside the runner.

This is simpler than hosting MCP and permits explicit temperature/seed controls
where supported, but it does not test MCP schema transport, server instructions
or the client’s agent loop. Seshat also has no API-key requirement today. Keep
this as an optional model-adapter later, not the first implementation.

### C. Headless client against real Seshat and Live

Script `claude -p` against `http://localhost:4000/mcp`, prepare a scratch set,
and inspect the stream trace.

This is the closest replacement for the current manual check, but it mixes two
questions: whether the model selected the right call and whether Live accepted
it. It is slow, mutates a user session, inherits OSC port contention, and still
needs fixture setup and cleanup. Use it only as a final thin smoke test, never
as the routing corpus runner.

### D. Ask another model to judge conversational transcripts

An LLM judge can score whether the final answer “speaks music,” but it is an
unnecessary source of variance for tool routing. The calls are structured and
should be checked structurally. A prose judge may be added as a non-blocking
metric after the trace gate is trustworthy.

## Recommended process

### 1. Commit a small declarative corpus

Store cases as data, not ExUnit code, so prompts and expectations can grow
without growing the runner. Each case contains:

```yaml
id: mixer_master_and_return
fixture: named_tracks_and_reverb
prompt: Bring the master down a touch and mute the reverb return.
expect:
  calls:
    - name: set_mixer
      where: {target: master, volume: {lt_fixture: master.volume}}
      count: 1
    - name: set_mixer
      where: {target: return, track: 0, mute: true}
      count: 1
  no_tool_errors: true
  max_mutating_calls: 2
```

Assertions should describe semantics, not one serialization. “A touch” accepts
a bounded decrease rather than one exact fader value. Independent mutations may
arrive in either order. Safety assertions — wrong target, schema-invalid call,
or an unexpected mutating call — remain exact failures.

Every case must make its target resolvable. The current manual note-edit check
says only “with a MIDI clip open,” but Seshat cannot read the selected clip’s
track/slot from `get_view_state`. An automated case should establish “the Bass
clip is track 1, slot 0” in its prompt/context or provide a discovery route the
tools actually expose. Automation is useful here: it turns tacit human setup
into an explicit fixture contract.

### 2. Serve the production contract through a recorder

The eval MCP server should:

1. publish the selected revision’s `Seshat.Instructions` and exact tool array;
2. validate raw arguments against that revision’s schemas;
3. answer read tools from the case fixture;
4. apply mutations only to an in-memory fixture when later reads depend on
   them;
5. append `{sequence, name, arguments, result}` to the case trace;
6. expose no generic “call arbitrary tool” escape hatch and send no OSC.

For one-revision regression runs it can compile against the checkout. For the
one-time PR #77 proof, capture base and head `initialize`/`tools/list` outputs
as versioned surface snapshots and let the recorder serve either. That prevents
the comparison from depending on two running Seshat instances or two OSC
listeners.

### 3. Start one fresh model process per trial

Run from a temporary directory, not the repository, to avoid `CLAUDE.md` and
project settings changing the result. Strip `ANTHROPIC_API_KEY` so the command
does not silently switch from subscription auth. Use:

```text
claude -p <prompt>
  --output-format stream-json
  --model <pinned model>
  --system-prompt <fixed routing-eval prompt>
  --tools ""
  --mcp-config <only the recorder>
  --strict-mcp-config
  --allowedTools "mcp__seshat_eval__*"
  --disable-slash-commands
  --no-session-persistence
```

The runner records the CLI version, actual model identifier from the init
event, surface hash, case ID and duration. It extracts tool-use and final-text
blocks but discards thinking content.

Use a fixed minimal system prompt for the primary **surface-contract** lane, so
base/head differ only in Seshat’s contract. Add a separate periodic
**client-realism** lane using Claude Code’s normal system prompt. Do not mix the
two scores: there is no single “real client” prompt shared by Claude Code and
Claude Desktop.

### 4. Judge traces deterministically

Per trial, report:

- semantic intent completion;
- first-call schema validity;
- correct tool, target and resolved index;
- number of read and mutating calls;
- tool errors/refusals;
- extra or unsafe mutations;
- final answer claiming inability despite an available route.

The mixer seed passes when it produces one master decrease and one return mute,
with no wrong-target or extra mutation. The note seed passes when it reads the
notes and makes one `edit_notes` call whose pitch/time window selects the third
fixture note and whose velocity change is downward. It fails on a delete plus
`write_midi_notes` reconstruction even if the simulated musical result matches.

### 5. Run repeated A/B trials

One successful conversation proves possibility, not reliability. Start with
five fresh trials per case per surface. Keep the model and corpus identical and
interleave base/head runs to reduce time-of-day/model-rollout bias.

Report both raw traces and aggregate deltas:

| Metric | Base | Head | Gate |
|---|---:|---:|---|
| Semantic success | — | — | Head must not regress |
| Correct target on first mutation | — | — | 100% on destructive/high-risk cases |
| Schema-valid first call | — | — | Head must not regress |
| Median mutating calls | — | — | At or below expected intention count |
| Tool refusals | — | — | Head lower or equal |

Do not declare PR #77’s selection claim proven from the two original prompts.
Seed the corpus with them, then add paraphrases covering regular/return/master/
cue targets, multi-property calls, relative edits, and note selection by pitch,
ordinal and time range. Roughly 20 cases × 5 trials is enough for a first signal;
it is not a statistical benchmark.

### 6. Put it in the development lifecycle

- `mix precommit`: deterministic code and schema tests only.
- `mix routing.eval`: on-demand external run; no Live required.
- Tool-surface PR: run affected cases against base/head and attach the Markdown
  summary to the PR or archived plan.
- Release/nightly, if a logged-in runner exists: full corpus against the
  current surface and pinned model.
- Live smoke: one representative routing trace may continue into scratch Live
  to prove integration, but it is not the selection score.

A corpus failure is evidence, not an automatically actionable code diagnosis.
Save the observed trace and identify whether the likely lever is the tool name,
description, schema, instructions or fixture ambiguity before changing text.

## Smallest decision experiment

Before planning the full harness:

1. Build a recorder that exposes only the tools needed by the two existing
   mixer/note cases and returns fixed `get_session_state`/`get_clip_notes`
   results.
2. Capture one current Claude Code 2.1.220 stream to pin event parsing.
3. Run five fresh trials for each case against PR #77’s surface.
4. Snapshot the base surface and repeat with the old tool names.
5. Inspect whether exact trace predicates distinguish success without a human
   reading the transcript.

This spike kills the approach if Claude Code cannot be constrained to the
recorder, its stream omits tool calls, subscription-authenticated headless runs
are not repeatable, or the cases cannot be judged without subjective prose.
All four questions can be answered before building a general fixture engine.

## What remains unmeasured

- Current Claude Code stream-event field shapes; only the available flags were
  rechecked on 2.1.220.
- Claude Desktop automation — there is no corresponding supported headless
  interface in this repository’s evidence.
- Run-to-run variance and the number of trials needed for stable comparisons.
- Whether a fixed replacement system prompt or the normal Claude Code prompt
  better predicts the client where Seshat will actually be used.
- Subscription rate limits for a 100-turn corpus.
- The true projected tool inventory; the handoff’s `52 → ~82` claim and the
  scaling doc’s `52 → ~60–62` estimate disagree and should not be baked into
  eval thresholds.

## Source index

- `docs/smoke_tests/manual/conversation.md` — the two seed routing scenarios.
- `docs/evaluating/tool-surface-scaling.md` — required metrics, corpus gate and
  bounded-intent architecture.
- `docs/archive/PLAN_mcp_browser_ui.md` — measured headless Claude Code auth,
  MCP lockdown and stream JSON behavior on CLI 2.1.114.
- Local `claude --help`, Claude Code 2.1.220, checked 2026-08-28 — current
  non-interactive, MCP, model, output and isolation flags.
- `lib/seshat/mcp/tools.ex` and `lib/seshat/mcp/server.ex` — the production
  schemas, instructions and tool execution boundary the recorder must mirror.
