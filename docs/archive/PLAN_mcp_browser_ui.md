> **Archived 2026-07-26 — never built.** A designed-but-unimplemented feature:
> `AssistantLive` still has only the API-key backend. The idea is tracked in
> [ROADMAP.md](../ROADMAP.md). If picked up, re-verify the "verified facts"
> section — it was tested against claude CLI 2.1.114 and may have drifted.

# Implementation Plan: MCP Mode in the Browser UI

Add a second reasoning backend to `SeshatWeb.AssistantLive`: instead of calling
the Anthropic API with an API key, spawn **headless Claude Code** (`claude -p`)
as a subprocess. It authenticates with the user's Claude subscription, consumes
Seshat's tools over the app's own MCP endpoint (`/mcp`), and streams its
activity back into our UI — Claude Code's agentic loop, wearing our interface.
A toggle in the UI selects the backend per conversation.

```
                         ┌─ API mode ──→ Seshat.Agent ──→ Anthropic API ($ per token)
Browser ──→ AssistantLive┤                                      │ tool calls (in-process)
                         └─ MCP mode ──→ claude -p subprocess   ▼
                                          (subscription)  Tools.Handlers ──→ OSC ──→ Ableton
                                               │                ▲
                                               └── MCP over HTTP: localhost:4000/mcp
```

Everything below `Tools.Handlers` is untouched. The subprocess connects back to
the same BEAM that spawned it, so both backends share one OSC transport and one
session state (the port-11001 constraint stays satisfied).

---

## Verified facts (tested on this machine, claude CLI 2.1.114)

- **Subscription auth works headless.** With `ANTHROPIC_API_KEY` absent from the
  subprocess env, `claude -p` uses the logged-in claude.ai account. Verified:
  `env -u ANTHROPIC_API_KEY claude -p "..." --output-format json` succeeded.
- **Result JSON shape** (from `--output-format json`):
  `{"type":"result","subtype":"success","is_error":false,"num_turns":1,
  "result":"...","session_id":"<uuid>","total_cost_usd":...,"usage":{...},
  "permission_denials":[]}`
- **Multi-turn**: `--resume <session_id>` continues a stored conversation;
  `--session-id <uuid>` pins one; `--no-session-persistence` disables storage.
- **Tool lockdown**: `--tools ""` disables ALL built-in tools (no Bash/file
  access); `--mcp-config '<json>'` + `--strict-mcp-config` loads ONLY our MCP
  server; `--allowedTools "mcp__seshat__*"` auto-allows our tools so the
  non-interactive run never stalls on permissions.
- **Streaming**: `--output-format stream-json` emits one JSON event per line
  (`system:init`, `assistant`, `user` tool-results, final `result`);
  `--input-format stream-json` allows a long-lived conversational process.
- **Traps**:
  - `--bare` disables OAuth/keychain auth → would break subscription mode. Never use it.
  - The default model follows the user's CLI config (currently Fable). Pin
    `--model` from app config so browser chats use a sensible/cheap tier.
  - The `claude` asdf shim needs `ASDF_NODEJS_VERSION=20.11.1` in env (seshat's
    `.tool-versions` has no nodejs entry).
  - The shell env that launched `phx.server` may contain `ANTHROPIC_API_KEY`;
    it MUST be stripped from the subprocess env or turns bill the API silently.

---

## Milestone 1 — Backend abstraction + UI toggle

No new behavior; make room for two backends.

1. **`Seshat.Assistant.Backend`** (new): behaviour with
   `run(input, conversation, opts) :: {:ok, result} | {:error, String.t()}`
   where `result` is the existing shape (`response`, `commands_executed`, plus
   backend-private continuation state: `messages` for API mode, `session_id`
   for MCP mode).
2. **`Seshat.Agent`**: adopt the behaviour (rename optional; keep module —
   tests reference it via `Req.Test`).
3. **`Seshat.Assistant.ClaudeCode`** (new, stub in this milestone).
4. **AssistantLive**: `backend` assign (`:api | :mcp`), toggle component in the
   header (two-segment control, DOM id `backend-toggle`). Switching backends
   mid-session starts a fresh conversation for the newly selected backend
   (keep each backend's continuation state in separate assigns; simplest
   correct semantics — histories don't transfer between billing models).
   Disable the MCP option with a tooltip when `claude` isn't available
   (availability check at mount: cached `System.find_executable` + version run).

## Milestone 2 — MCP backend, blocking (end-to-end working)

Per-turn subprocess invocation; fits the existing `start_async` plumbing.

1. **`Seshat.Assistant.ClaudeCode.run/3`** builds and runs (via `System.cmd/3`
   with `stderr_to_stdout: false`):

   ```
   claude -p <input> \
     --output-format json \
     --model <config, default "sonnet"> \
     --system-prompt <shared music prompt> \
     --tools "" \
     --mcp-config '{"mcpServers":{"seshat":{"type":"http","url":"http://localhost:<port>/mcp"}}}' \
     --strict-mcp-config \
     --allowedTools "mcp__seshat__*" \
     [--resume <session_id when continuing>]
   ```

   - env: inherit minus `ANTHROPIC_API_KEY`, plus `ASDF_NODEJS_VERSION`.
   - cwd: the OS tmp dir (never the repo — avoids CLAUDE.md auto-discovery and
     workspace trust weirdness).
   - MCP URL port read from `SeshatWeb.Endpoint.config(:http)` — don't hardcode 4000.
   - Command name + env come from `Application.get_env(:seshat, :claude_cmd)`
     so tests can substitute a fake script (same pattern as `:agent_req_options`).
2. **Parse the result JSON**: `result` → `response`; `session_id` stored for
   the next turn; `is_error`/`permission_denials` → friendly error strings.
   In this milestone `commands_executed` stays empty (tool detail arrives with
   streaming in Milestone 3) — show "n agentic turns" from `num_turns` instead.
3. **Prompt sharing**: move `Seshat.Agent`'s `@system_prompt` into
   `Seshat.Assistant.Prompt` (single source; both backends use it). Use
   `--system-prompt` (full replace, not append) — Claude Code's default system
   prompt is ~33k tokens of coding-agent instructions we don't want.
4. **Failure modes** mapped to user-visible messages:
   - CLI missing / not logged in (`is_error` + stderr sniff) → "MCP mode needs
     Claude Code installed and logged in"
   - Endpoint unreachable (tool listing empty) → "Seshat server not reachable
     on /mcp"
   - Timeout: kill after configurable ms (default 120s).

## Milestone 3 — Streaming: live tool-call feed ("the Claude Code UI feel")

1. **`Seshat.Assistant.ClaudeCode.Session`** (new GenServer, one per LiveView,
   under a `DynamicSupervisor`): owns a long-lived port running
   `claude -p --input-format stream-json --output-format stream-json --include-partial-messages ...`.
   User turns are written to stdin as JSON lines; events stream back.
2. **Event handling** (line-buffered port, decode per line):
   - `system:init` → session ready (tool count, model)
   - `assistant` with `tool_use` blocks → push `{:tool_call, name, args}` to the
     LiveView (`mcp__seshat__` prefix stripped for display)
   - `user` with `tool_result` blocks → `{:tool_result, ...}`
   - `assistant` text / partial chunks → `{:text_delta, ...}`
   - `result` → turn complete
   (Exact event field names verified against real output as the first task of
   this milestone.)
3. **AssistantLive**: replace `start_async` with `handle_info` on these events
   for MCP mode; render an activity feed per in-flight turn (tool chips with
   args → results, then the final message). Stop button kills the turn
   (`Session.interrupt/1` → send SIGINT to port / close and respawn).
4. Port lifecycle: crash of subprocess → LiveView shows error, next turn
   respawns with `--resume` (session survives process death since sessions
   persist on disk).

## Milestone 4 — Polish

- Persist backend choice (URL param or localStorage hook).
- Optional cost/turn indicator (API mode: none today; MCP mode: `num_turns`,
  duration; `total_cost_usd` is notional under subscription — label it or hide it).
- `mix precommit` green; README section for MCP-mode-in-browser setup
  (install + login of Claude Code).

---

## Files

| Path | Change |
|---|---|
| `lib/seshat/assistant/backend.ex` | new — behaviour |
| `lib/seshat/assistant/prompt.ex` | new — shared system prompt (moved from `Seshat.Agent`) |
| `lib/seshat/assistant/claude_code.ex` | new — blocking runner (M2) |
| `lib/seshat/assistant/claude_code/session.ex` | new — streaming port GenServer (M3) |
| `lib/seshat/agent.ex` | adopt behaviour; prompt moves out |
| `lib/seshat_web/live/assistant_live.ex` | toggle, per-backend state, activity feed |
| `lib/seshat/application.ex` | DynamicSupervisor for sessions (M3) |
| `config/*.exs` | `:claude_cmd`, `:claude_model`, timeout |
| `test/support/fixtures/fake_claude.sh` | canned JSON / stream-json emitter |
| `test/seshat/assistant/claude_code_test.exs` | runner + parser tests |
| `test/seshat_web/live/assistant_live_test.exs` | toggle + both backends |

## Testing

- **Unit**: event/result parsing against captured real JSON fixtures.
- **Integration without subscription**: `:claude_cmd` points at
  `fake_claude.sh`, which replays canned output — full LiveView flow tested in
  CI with zero external calls (mirrors the `Req.Test` pattern used for API mode).
- **Manual end-to-end**: phx.server + Ableton running, toggle to MCP, "add a
  piano track" — verify the track appears, the tool feed rendered, and the
  turn used subscription auth (no `ANTHROPIC_API_KEY` in env).

## Out of scope (explicitly)

- Multi-user/hosted deployment (subprocess auth is the local user's login).
- Mixing histories across backends when toggling mid-conversation.
- Replacing API mode — it stays as the fallback for machines without Claude Code.
