# Implementation Plan: Automated conversation-routing evaluations

Roadmap item: **Automate conversation-routing evaluations** (top of the queue,
ranked first by decision on 2026-08-28). Options doc:
[evaluating/automated-conversation-routing-evals.md](evaluating/automated-conversation-routing-evals.md).

This plan is the **first slice — the decision experiment** — not the general
eval platform. It builds exactly enough harness to run the two seed cases from
[smoke_tests/manual/conversation.md](smoke_tests/manual/conversation.md) §
*Mixer and note edits route to one call each* against the pre- and
post-consolidation tool surfaces, five fresh trials each, and score the traces
without a person reading a transcript. Everything is shaped so a second slice
can add cases as data without touching the runner, but nothing here is built
for that second slice on faith.

## Context

PR #77 collapsed 67 tools into 52 on one bet: that intention-shaped names
(`set_mixer`, `edit_notes`) route better than same-verb-different-target names
(`set_master_volume`, `set_return_track_mute`, `remove_notes`). Nothing
executable guards that bet. `mix test` proves what a tool does *after* the
model selects it; the only check of the selection itself is a manual
conversation test with `Last run: —`. Every future change to a description,
a schema, or `Seshat.Instructions` is in the same position: it either reads
well or it doesn't, and nobody measures.

The measured route (all three measurements 2026-08-28, this machine, Claude
Code CLI **2.1.220**, model `claude-sonnet-5`, subscription auth):

1. **A headless Claude Code run can be constrained to a record-only MCP
   server, and its stream carries the tool calls.** A 40-line Python stub
   serving `get_session_state` + `set_mixer` over stdio, launched by
   `claude -p … --tools "" --mcp-config <stub only> --strict-mcp-config
   --allowedTools "mcp__seshat_eval__*"`, received exactly the calls the manual
   test expects for the mixer prompt — `get_session_state`, then
   `set_mixer {target: master, volume: 0.75}`, then
   `set_mixer {target: return, track: 0, mute: true}` — in 9.1s wall, 4.7s of
   which was model time. `system/init` listed only the two MCP tools;
   `apiKeySource: "none"` confirmed subscription auth with `ANTHROPIC_API_KEY`
   stripped. The recorder's own trace and the client stream agreed call for
   call.
2. **The user's own Claude Code configuration leaks into a naive run.** The
   first attempt fired this machine's `SessionStart` hook (a plugin that
   rewrites the model's register) inside the eval. `--setting-sources ""`
   removed it: `plugins: []`, `skills: []`, no hook events, `permissionMode:
   "default"`, and the `--allowedTools` glob still auto-approved every MCP
   call with `permission_denials: []`. **This flag is mandatory**, and the
   runner asserts the init event shows no plugins and no hooks before it
   counts a trial.
3. **MCP server `instructions` reach the headless model.** Asked to quote the
   server's instructions verbatim (no tool calls), the model returned the stub's
   instruction string exactly. So the surface-contract lane can include
   `Seshat.Instructions` as the real client would deliver it — the recorder
   sends the snapshot's instructions in its `initialize` result and nothing
   else carries them.

Two constraints the research fixed:

- **Base and head cannot both be running Seshats.** Only one instance can bind
  AbletonOSC's reply port, and the harness must never touch OSC anyway. The
  recorder therefore serves a **surface snapshot** — a JSON file of
  `{instructions, tools}` — and the base snapshot is captured once from a
  worktree at `c3096d6` (the last 67-tool commit, before #76/#77) and
  committed. The head snapshot is generated from the checkout at run time. A
  `mix run --no-start` snippet encoding
  `Seshat.MCP.Server.__components__(:tool)` through Anubis's `JSON.Encoder`
  was verified on this checkout: 52 tools, **60,246** compact bytes (CLAUDE.md
  records the same day's `mcp_call.py stats` at 58,709 — the two count
  different envelopes; the snapshot test asserts tool count and name set, never
  a byte total);
  instructions are 1,316 chars. The encoder matters: the published tool object
  includes `title`, which a hand-built `{name, description, inputSchema}` map
  silently omits.
- **The note case must name its target.** The manual test says "with a MIDI
  clip open"; no tool reads the selected clip, so the automated prompt states
  the track and the fixture states the clip. That is a correction to the seed,
  already recorded in [smoke_tests/manual/conversation.md](smoke_tests/manual/conversation.md)
  (narrowed at plan time, see Part 10).

## Contract

No OSC. Nothing in this plan sends a datagram, and a test greps for it (Part 9).
The load-bearing contracts are instead the two process boundaries below, both
measured today and pinned by captured fixtures.

### The client command (Claude Code 2.1.220)

```text
claude -p <prompt>
  --output-format stream-json --verbose
  --model <one model from the panel; default panel claude-sonnet-5, claude-opus-5>
  --setting-sources ""
  --system-prompt <fixed lane prompt>
  --tools ""
  --mcp-config <path to a JSON naming only the recorder>
  --strict-mcp-config
  --allowedTools "mcp__seshat_eval__*"
  --disable-slash-commands
  --no-session-persistence
```

Run with `cwd` = a fresh temp directory (never the repo: `CLAUDE.md`
auto-discovery), `stdin` = `/dev/null` (otherwise the CLI waits 3s for piped
input and warns), env = inherited minus `ANTHROPIC_API_KEY`. `--bare` is
never used (disables OAuth/keychain). `--verbose` is kept: `stream-json` in
print mode has historically required it and it cost nothing today.

The MCP config names one stdio server:

```json
{"mcpServers": {"seshat_eval": {"type": "stdio",
  "command": "<repo>/priv/routing_eval/bin/recorder",
  "args": ["--surface", "<path>", "--fixture", "<path>", "--trace", "<path>"]}}}
```

`priv/routing_eval/bin/recorder` is a committed POSIX wrapper (mode `100755`
in git, as is `bin/closed-stdin`) that resolves the repo from its own location
**through symlinks** (`cd "$(dirname "$0")" && pwd -P`, then up three levels),
changes directory with quoted paths, and `exec`s `env MIX_QUIET=1 mix
routing.recorder "$@"`. The runner writes the `command` path as
`Path.expand("priv/routing_eval/bin/recorder")` from `File.cwd!()` — the task
already requires running from the repo root for its `git status` check — and
**never** via `Application.app_dir/2`, which in dev resolves to
`_build/dev/lib/seshat/priv`, a symlink whose parent chain is not the repo.
The config contains no shell command string or interpolated path.

The server name is part of the contract: tool names reach the model as
`mcp__seshat_eval__<tool>` and the runner strips exactly that prefix.

### Stream events (measured shapes, one JSON object per line)

| `type` | Fields the runner reads | Notes |
|---|---|---|
| `system` / `subtype: "init"` | `model`, `tools` (list of `mcp__…` names), `mcp_servers[{name,status}]`, `claude_code_version`, `apiKeySource`, `permissionMode`, `plugins`, `session_id` | The trial is **void** unless `plugins == []`, `mcp_servers == [{seshat_eval, connected}]`, `tools` equals the snapshot's complete name set with the `mcp__seshat_eval__` prefix, and `apiKeySource == "none"` |
| `system` / `hook_started`, `hook_response` | presence only | Any occurrence voids the trial — settings leaked |
| `system` / `thinking_tokens` | — | Ignored |
| `rate_limit_event` | `rate_limit_info.status`, `rateLimitType`, `resetsAt`, `overageStatus` | Emitted every turn; `status: "allowed"` is normal. Any other status voids the trial and **stops the run**, reporting `resetsAt`. Measured today: `overageStatus: "rejected"` (`out_of_credits`) — on this account an exhausted window fails outright rather than billing overage |
| `assistant` | `message.content[]` blocks: `tool_use{id,name,input}`, `text{text}`, `thinking` | `thinking` blocks are dropped unread — never written to disk |
| `user` | `message.content[0]` = `tool_result{tool_use_id,is_error,content}` | Correlates to `tool_use.id` |
| `result` | `subtype`, `is_error`, `num_turns`, `duration_ms`, `result` (final text), `usage`, `permission_denials` | `permission_denials != []` voids the trial |

The recorder's own trace (below) is the authoritative call list; the stream's
`tool_use` blocks are cross-checked against it (same count, same names in
order) so a parsing regression on either side fails loudly.

### The recorder protocol (MCP over stdio, newline-delimited JSON-RPC)

| Method | Reply |
|---|---|
| `initialize` | `{protocolVersion: <echo>, capabilities: {tools: {}}, serverInfo: {name: "seshat_eval", version: "0.1.0"}, instructions: <snapshot.instructions>}` |
| `notifications/initialized` | none |
| `ping` | `{}` |
| `tools/list` | `{tools: <snapshot.tools>}` — the array verbatim, order preserved |
| `tools/call` | `{content: [{type: "text", text}], isError}` — arguments checked against that tool's `inputSchema` first; a violation returns `isError: true` with `Validation`-style wording and is recorded as such |
| anything else | JSON-RPC `-32601` |

Trace file, appended one line per `tools/call`:
`{"seq", "name", "arguments", "is_error", "schema_valid", "kind": "read" | "view" | "mutation", "result_preview"}`.

## Parts

All new Elixir code lives under `lib/seshat/eval/` and
`lib/mix/tasks/routing.*.ex`; fixtures, snapshots, cases and the two bounded
executable wrappers live under `priv/routing_eval/`. Nothing in `lib/seshat/tools/`,
`lib/seshat/mcp/`, or `Definitions` changes.

### 1. `Seshat.Eval.Surface` — the contract as data

`lib/seshat/eval/surface.ex`. A struct `%Surface{id, revision, captured_at,
instructions, tools}` where `tools` is the exact list of maps `tools/list`
would publish, including `title` and any future optional protocol fields.

- `current(revision)` calls Anubis's real
  `Anubis.Server.Handlers.Tools.handle_list/3` with an empty `Frame`, encodes the returned
  component structs with their Anubis-provided `JSON.Encoder`, and decodes
  them back to string-key maps. That preserves the handler's visibility,
  ordering and optional-field behavior instead of reimplementing them. It
  adds `Seshat.Instructions.text/0` and the caller-supplied revision. No app
  start or subprocess is needed.
- `load!/1` / `dump/1` — JSON in and out (`Jason`), keys sorted, so a
  committed snapshot diffs cleanly.
- `kind/2 :: :read | :view | :mutation` — the split the judge counts on.
  Rule: a name starting with `get_`, plus `search_library`,
  `list_browser_items`, `reindex_library`, is a read; `show_view`, `hide_view`,
  `select_track`, `select_scene` are **view** calls (they change what Live
  shows, never the Set — `Seshat.Instructions` actively teaches the model to
  send one before a view-specific action, so scoring one as an extra mutation
  would fail a trial for obeying the instructions under test); everything else
  is a mutation. A name rule rather than a per-tool flag because the base
  snapshot predates any flag and the split must hold for both surfaces
  identically (all four view tools exist at `c3096d6`).
- `mix routing.snapshot [--out path]` (`lib/mix/tasks/routing.snapshot.ex`)
  resolves `git rev-parse --short HEAD` at the Mix-task boundary and writes
  `current(revision)`. Runs `Mix.Task.run("app.config")` only — **never
  `app.start`**.

Committed base snapshot: `priv/routing_eval/surfaces/base-c3096d6.json`,
captured once by the implementer with the verified snippet (this plan's
Context) in a temporary worktree at `c3096d6`, with `revision: "c3096d6"` and
the 67-tool count asserted in the test that loads it. The head surface is
never committed — `mix routing.eval` resolves the revision and calls
`Surface.current(revision)`.

### 2. `Seshat.Eval.SchemaCheck` — first-call validity on any surface

`lib/seshat/eval/schema_check.ex`. `violations(json_schema, arguments) ::
[String.t()]` over the **published JSON Schema** (string keys, `type`, `enum`,
`minimum`, `maximum`, `required`, `properties`, `items`,
`additionalProperties: false`). It deliberately does not reuse
`Seshat.Tools.Validation`, which reads the *current* `Definitions` — useless
for the base snapshot. Same wording style ("`pan`: must be at most 1.0 (got
2.0)") so a recorded rejection reads like production's.

### 3. `Seshat.Eval.Fixture` — the discoverable session

`lib/seshat/eval/fixture.ex` + `priv/routing_eval/fixtures/<name>.json`.

A fixture is the synthetic set: `song`, `tracks`, `return_tracks`, `master`,
`clips` keyed `"track:slot"` with `name`, `length`, `notes`. Reads render
through the **real formatters** so the model sees production prose:
`Handlers.format_session_state/5` (`refresh_pending?: false`),
`Handlers.format_clip_notes/5`, and a small local renderer for
`get_clip_slots` mirroring its clause's wording. Both formatter functions are
already public. They are the checkout's renderers on both surfaces — the
read replies barely moved between `c3096d6` and head, and the routing under
test is the *choice* of call, not the reply text; recorded as a known
approximation in Open questions.

The three reads useful to these prompts (`get_session_state`,
`get_clip_notes`, and the harmless discovery detour `get_clip_slots`) are
rendered from that initial state. Mutations are recorded and answered with a
short templated success line naming the tool and arguments, but are **not**
applied: neither seed case reads state after writing, and building a general
state simulator before a case needs it would violate this slice's purpose.
Every other mutation is recorded, answered `"Done."`, and left to the judge
to count as an extra. A read the fixture has no data for answers `isError:
true`, "not available in this evaluation fixture", so the model cannot
proceed on invented state. Add mutation simulation only when a later case has
a concrete read-after-write assertion.

The one fixture this slice ships, `named_tracks_and_reverb.json`:
tracks `Drums` (audio, 0), `Bass` (midi, 1), `Keys` (midi, 2); returns
`Reverb` (0), `Delay` (1); master volume 0.85; clip `1:0` named `Bass`, 4
beats, notes C2 @0.0, C2 @1.0, Eb2 @2.0, G2 @3.0, all vel 100, dur 1.0.
The third note is unique by both pitch (39) and start (2.0), so either
window strategy the description teaches can be judged exactly.

### 4. `Seshat.Eval.Recorder` — the record-only MCP server

`lib/seshat/eval/recorder.ex` is **pure**: `handle(request, state) ::
{reply | nil, state}` implementing the protocol table above over a `%Surface{}`
and a `%Fixture{}`; `state` carries the sequence counter and the trace so far.
`lib/seshat/eval/recorder/stdio.ex` is the loop: read a line from stdin,
decode, `handle/2`, write the reply, append the trace line to `--trace`.
Stdout carries only JSON-RPC; Logger goes to stderr exactly as `mix mcp`
already arranges it.

`mix routing.recorder --surface <path> --fixture <path> --trace <path>`
(`lib/mix/tasks/routing.recorder.ex`): `app.config`, never `app.start`; loads
the already-written surface and the fixture, then runs the loop until stdin
closes. One process per trial by construction — Claude Code spawns it and it
dies with the client.

### 5. `Seshat.Eval.Stream` — event parsing, pinned by capture

`lib/seshat/eval/trial.ex` defines the data struct; one module per file.
`lib/seshat/eval/stream.ex`, pure: `parse(lines) :: {:ok, %Trial{init, calls,
results, final_text, result}} | {:error, reason}`, dropping `thinking`
blocks before anything else touches the event. `void_reason(trial,
expected_tool_names)` returns the first isolation failure from the table
(plugins, hooks, missing/foreign tools, denials, API-key auth) or `nil`.

The stream captured today (the second run, with `--setting-sources ""`) is
committed as `test/fixtures/routing/stream-2.1.220.jsonl` with its
`session_id`, `cwd` and `uuid` values scrubbed. It is the tripwire: when a
CLI upgrade moves a field, `Seshat.Eval.StreamTest` fails on the fixture
before a live run silently scores zero calls.

### 6. `Seshat.Eval.Client` — one fresh model process per trial

`lib/seshat/eval/client.ex` is pure: it builds the MCP-config map and an
invocation (executable, argv and sanitized env) from the contract and
caller-supplied config/cwd paths.
The executable and argv prefix come from `Application.get_env(:seshat,
:routing_eval_command, ["claude"])` so tests substitute a capture-replay
script — the same seam the archived browser-UI plan proposed.

The process boundary lives under `lib/mix/tasks/`, not `lib/seshat/eval/`:
`Mix.Tasks.Routing.Eval.Runner`
(`lib/mix/tasks/routing.eval.runner.ex`) opens
`priv/routing_eval/bin/closed-stdin` with `Port.open/2`; that committed wrapper
redirects stdin from `/dev/null` and `exec`s the invocation with positional
arguments. The runner creates the unique temp cwd, writes the config JSON,
collects newline output, enforces a per-trial timeout
(default 120s), closes the port on timeout, waits for its exit status, and
removes only the exact temp directory it created. This is direct argv
execution, not `/bin/sh -c`. Keeping `Port.open` here is required by Seshat's
existing invariant that `Seshat.AX.Client` is the only module under
`lib/seshat/` allowed to start a process; `ax/client_test.exs` already greps
that invariant. `mix test` never starts the real CLI.

Lane prompt (fixed, in `Seshat.Eval.Client.@system_prompt`, versioned in the
report by hash):

> You are Seshat, an assistant that controls the user's Ableton Live set
> through the tools provided. Carry out the request with the tools, then
> reply in one or two sentences.

That is the surface-contract lane: everything else the model knows about
Seshat arrives through the recorder — the snapshot's instructions and tool
descriptions — so a base/head delta is a delta in the contract alone. The
client-realism lane (Claude Code's default system prompt) is out of scope.

### 7. Cases and `Seshat.Eval.Judge`

Cases are data: `priv/routing_eval/cases/<id>.json`:

```json
{
  "id": "mixer_master_and_return",
  "fixture": "named_tracks_and_reverb",
  "prompt": "Bring the master down a touch and mute the reverb return.",
  "expect": {
    "head": {
      "calls": [
        {"tool": "set_mixer", "count": 1,
         "where": {"target": "master", "volume": {"lt": {"fixture": "master.volume"}, "gt": 0.5}}},
        {"tool": "set_mixer", "count": 1,
         "where": {"target": "return", "track": 0, "mute": true}}
      ],
      "max_mutations": 2, "no_tool_errors": true, "must_not_call": []
    },
    "base": {
      "calls": [
        {"tool": "set_master_volume", "count": 1,
         "where": {"value": {"lt": {"fixture": "master.volume"}, "gt": 0.5}}},
        {"tool": "set_return_track_mute", "count": 1,
         "where": {"return_track": 0, "muted": true}}
      ],
      "max_mutations": 2, "no_tool_errors": true, "must_not_call": []
    }
  }
}
```

```json
{
  "id": "note_third_quieter",
  "fixture": "named_tracks_and_reverb",
  "prompt": "In the Bass track's first clip, make the third note a little quieter.",
  "expect": {
    "head": {
      "calls": [
        {"tool": "get_clip_notes", "min_count": 1, "where": {"track": 1}},
        {"tool": "edit_notes", "count": 1,
         "where": {"track": 1, "clip_slot": {"absent_or": 0},
                   "window_selects_exactly": {"fixture": "clips.1:0.notes[2]"},
                   "velocity_down_from": 100, "delete": {"absent_or": false}}}
      ],
      "max_mutations": 1, "no_tool_errors": true,
      "must_not_call": ["write_midi_notes"]
    },
    "base": {
      "calls": [
        {"tool": "get_clip_notes", "min_count": 1, "where": {"track": 1}},
        {"tool": "remove_notes", "count": 1,
         "where": {"track": 1, "window_selects_exactly": {"fixture": "clips.1:0.notes[2]"}}},
        {"tool": "write_midi_notes", "count": 1,
         "where": {"track": 1, "notes_replace_quieter": {"fixture": "clips.1:0.notes[2]"}}}
      ],
      "max_mutations": 2, "no_tool_errors": true, "must_not_call": []
    }
  }
}
```

Expectations are keyed per surface id because the base surface *cannot*
express the head intention in one call — that asymmetry is the finding, not a
nuisance to abstract away. `Seshat.Eval.Judge` (`lib/seshat/eval/judge.ex`,
pure) evaluates `where` with a closed matcher vocabulary: literal equality;
`lt`/`gt`/`between`; `{"fixture": path}` dereferencing into the fixture;
`absent_or`; and three named predicates — `window_selects_exactly` (the
pitch/time window of the call, defaults applied, starts exactly the given
fixture notes and no others), `velocity_down_from` (`velocity < n` or
`velocity_delta < 0`), `notes_replace_quieter` (the written notes are the
given note at lower velocity). Unknown matcher keys are a case-file error,
not a silent pass.

Per trial the verdict is a map: `semantic_success`, `first_call_valid`,
`first_mutation_valid`, `all_calls_valid` (each validity field means
schema-valid and not `isError`), `correct_target_first_mutation`,
`read_count`, `view_count`, `mutation_count` (view calls are neither reads nor
mutations and never count against `max_mutations`), `tool_errors`,
`extra_mutations`,
`claimed_inability` (final text matched against a short phrase list —
"can't", "not able", "no tool" — reported as a flag, never a fail on its
own), `void_reason`. `semantic_success` is true only when every `calls` entry
matches with its count, `max_mutations` and `no_tool_errors` hold, and nothing
in `must_not_call` appears. `first_mutation_valid` is reported alongside the roadmap's literal
first-call metric because both seed cases intentionally begin with an easy
read; without it, a malformed first write would be hidden by a valid
`get_session_state` or `get_clip_notes` call.

### 8. `mix routing.eval` and the report

`lib/mix/tasks/routing.eval.ex`:

```text
mix routing.eval [--surface head] [--surface base-c3096d6] [--case id]…
                 [--trials 5] [--model claude-sonnet-5] [--model claude-opus-5]…
                 [--out priv/routing_eval/runs/<stamp>]
```

Defaults: both surfaces, every case, five trials, and a **model panel** of
`claude-sonnet-5` and `claude-opus-5` (`--model` repeats; any name the CLI
accepts, `fable` included). Seshat is meant to work under many models, so no
single model is the oracle: every trial is scored per model and the gate is
*head must not regress on any model in the panel*. Trials are **interleaved**
— `for t <- 1..5, case <- cases, model <- models, surface <- surfaces` — so
base and head see the same hour of the same model. Default panel size: 2
cases × 2 surfaces × 2 models × 5 trials = 40 runs, ~7 minutes at today's
~10s per run. Each trial: snapshot path (head written to
the run dir once), fresh trace path, build the client invocation, execute it
through the Mix-task runner, `Stream.parse/1`,
`Judge.judge/3`, then the sanitized stream (thinking dropped), the trace
and the verdict are written under `<out>/<case>/<model-key>/<surface>/<n>/`
(`model-key` is the generated ordinal `m01`, `m02`, …; the report maps it to
the unmodified model name) so panel members cannot overwrite each other and a
CLI-supplied model name never becomes a path. The task
refuses to run if `claude --version` is not found, if `git status` shows
`lib/` or `priv/routing_eval/` dirty (the head snapshot must match a
revision), or if `ANTHROPIC_API_KEY` would be the auth source.

`Seshat.Eval.Report` (pure) writes `report.md` and `report.json`: a header
(CLI version, each model as reported by `init`, surface ids + revisions + tool
counts + sha256 of each surface's `{instructions, tools}` contract payload,
lane prompt hash, run stamp), then the
options doc's gate table per case — semantic success rate, correct target on
first mutation, first-call validity, first-mutation validity, all-call
validity, median mutations, tool refusals, void
trials — for each surface **per model**, plus a panel row (worst model wins), then
every observed call, trial by trial, in order, with its arguments. Void trials are listed and excluded from rates;
a case with fewer than the requested valid trials on either surface is
marked **inconclusive**, never scored.

`priv/routing_eval/runs/` is gitignored (add the entry to `.gitignore` in this
change — it is not there today). The one run that decides PR #77's
claim is copied into this plan's Live verification section when it is made.

### 9. Tests and guards

- `test/seshat/eval/surface_test.exs`: `current(revision)` is structurally
  identical to `Seshat.MCP.Server.__components__(:tool)` encoded through the
  Anubis `JSON.Encoder` and sorted by name — the snippet verified in Context,
  and an independent path from the `handle_list/3` call `current/1` itself
  makes (comparing it against `handle_list/3` would be a tautology) — includes
  `title`, and has
  `length(Definitions.all())` tools; the committed base snapshot loads with 67 tools and includes
  `set_master_volume`, `set_return_track_mute`, `remove_notes` and not
  `set_mixer` / `edit_notes`; `kind/2` on both surfaces, including that all
  four view tools are `:view` on each.
- `schema_check_test.exs`: enum, bounds, required, unknown key, nested array
  item — same cases `validation_test.exs` already pins, against JSON.
- `fixture_test.exs`: `get_session_state` renders the three tracks and two
  returns through the real formatter; `get_clip_notes` renders the fixture
  notes; a mutation receives a success reply without changing the initial
  fixture; unknown read → `isError`.
- `recorder_test.exs`: full handshake as a request list → replies; a
  schema-invalid `tools/call` is recorded `schema_valid: false` and answered
  `isError: true`; the trace has one line per call in order.
- `stream_test.exs`: parses the committed 2.1.220 capture into three calls
  with the exact arguments observed today; a synthetic `hook_started` event
  and a synthetic `plugins: [..]` init each produce a `void_reason`; a missing
  or foreign init tool is also void against the expected snapshot name set.
- `judge_test.exs`: both cases pass hand-built happy-path traces for **both**
  base and head (pinning the historical parameter names as well as the new
  ones); the mixer case fails when the return call is retargeted to track 1 or
  a third mutation is added; the head note case fails on delete+write, and
  `window_selects_exactly` rejects a window that also catches the fourth note.
- `client_test.exs`: the pure invocation contains every flag of the contract,
  including `--setting-sources ""`, and its env lacks `ANTHROPIC_API_KEY`.
  With `:routing_eval_command` pointed at a capture-replay script, the
  Mix-task runner returns the lines, closes stdin, removes the temp cwd, and
  kills a deliberately hanging fixture process at the configured timeout.
- `report_test.exs`: rates and the inconclusive marking from hand-built
  verdicts.
- **No-OSC guard:** a test greps `lib/seshat/eval/`,
  `lib/mix/tasks/routing.*` and `priv/routing_eval/bin/`
  for `Transport`, `/live/`, `:gen_udp` and `Session.State` and asserts
  zero hits — the same shape as `ax/client_test.exs`'s process-start grep.
- `mix precommit` is unchanged; nothing spawns `claude`.

### 10. Docs

- `CLAUDE.md`: add `lib/seshat/eval/` and the routing Mix tasks to the module
  map, plus a short "Routing evals" paragraph under Verification — what
  `mix routing.eval` is, that it is on-demand and never in `precommit`, and
  that a change to `Definitions`, a description or `Instructions` should run
  it against `head` and attach `report.md` to the PR.
- `docs/smoke_tests/manual/conversation.md` § *Mixer and note edits route to
  one call each*: **already narrowed at plan time** (by `/smoke-write`,
  2026-08-28) to the residue this harness cannot judge — that the replies
  speak music — and pointed at this plan for the routing half. When shipping,
  repoint its link from the plan doc to `CLAUDE.md` § Verification.
- `.claude/skills/smoke-test/scripts/mcp_call.py` docstring gains one line
  pointing at `mix routing.snapshot` as the no-server way to read the surface.

## Testing

Everything in Parts 1–9 is pure or seam-substituted and runs in `mix test`
with no Ableton, no network, no `claude`. The three things only a real run
can prove are listed under Live verification. Nothing here reaches
`Transport.query/3` — there is no Transport in the eval tree at all, and the
grep test keeps it that way.

## Live verification

This change sends no OSC, adds no address, no listener, no schema change and
no model-facing text, so none of the `auto/` files apply. Its live layer is
the model, not Ableton, and it verifies itself with one on-demand run —
recorded here, not in `docs/smoke_tests/`, because it is a one-time decision
experiment rather than a regression check:

- **The decision run** — `mix routing.eval` with defaults (both surfaces, both
  cases, five interleaved trials, the default two-model panel). The implementer pastes
  `report.md`'s gate table and every observed call under this bullet. Pass
  for the harness: zero void trials, every trial judged without reading a
  transcript, and predicates that separate the surfaces (or show they don't)
  on their own. The *result* — whether head routes better — is a finding for
  the PR and CLAUDE.md, not a pass/fail of this plan.
- `smoke_tests/manual/conversation.md § Mixer and note edits route to one call
  each` — already narrowed to the "replies speak music" residue; still needs
  a person, still `Last run: —`.
- `smoke_tests/manual/conversation.md § The instructions arrive, and arrive
  whole` — unchanged and still owed to Claude Desktop: measurement 3 proved
  delivery through **Claude Code**, which says nothing about the Desktop
  client this file exists for.

**Uncovered:** Claude Desktop routing (no headless interface exists for it);
the client-realism lane; run-to-run variance beyond five trials.

## Out of scope

- The general corpus (paraphrases, cue/return/master coverage, ~20 cases) —
  stays on the roadmap as the second slice, gated on this run not killing the
  approach.
- A client-realism lane using Claude Code's default system prompt, and a
  direct-API model adapter (options doc B) — roadmap.
- A prose/LLM judge for "speaks music" — deliberately not built (options doc
  D); the manual residue keeps it.
- Nightly or CI scheduling of the eval — it is externally metered and
  stochastic; the acceptance criterion says on demand.
- Generating the base snapshot automatically from a `--rev` — a one-time
  manual capture is recorded instead; if a third surface is ever needed the
  same snippet works.

## Open questions

1. ~~Does `claude-sonnet-5` stand in for the model the user actually pairs
   with Seshat?~~ **Resolved 2026-08-28 by the user:** Seshat is meant to
   work under many models, so no single one is bet on. `--model` is a
   repeatable panel (default Sonnet 5 + Opus 5), scored per model, gated on
   the worst — Part 8.
2. **Are five trials enough to separate the surfaces?** Enough for this
   slice, not for a benchmark. The slice's purpose is a kill decision — can
   predicates score traces without a person — and five trials answer that.
   On separation: today's head runs were 3/3 ideal on the mixer case, so
   head looks near-deterministic; if base is equally consistent, five trials
   show a clean split or a clean tie, and if base is noisy, that noise *is*
   the finding. The one bad outcome is a 3/5-vs-4/5 muddle, which the report
   marks *not separated* and a `--trials 10` rerun settles. **Decision: keep
   five; no further design.**
3. **Do fixture read replies rendered by the checkout's formatters bias the
   base surface?** Real but small, and it cuts the safe way. The read
   formatters (`format_session_state`, `format_clip_notes`) predate #77 and
   #77 did not touch them, so base saw near-identical text. What #77 changed
   are *mutations*, whose replies arrive after the routing choice has been
   made and cannot affect which tool is picked first. Bias could only show
   in a follow-up call — a base model reading a generic "Done." and deciding
   to verify — which inflates base's *read count*, not its semantic success
   or first-mutation target, the gate metrics. So the approximation, if it
   moves anything, handicaps base on a secondary metric. **Decision: accept
   as a documented approximation; not worth a base-checkout runner.** If
   base traces show a reply being misread, that is the first thing to
   revisit.
4. ~~Subscription rate limits.~~ **Closed 2026-08-28** — irrelevant to
   routing. `rate_limit_event` is a per-turn quota report (`status:
   "allowed"` on every run today); an exhausted window fails runs rather than
   billing overage on this account. Handled as plumbing in the Contract
   table (non-`allowed` → stop the run naming `resetsAt`), nothing to decide.
