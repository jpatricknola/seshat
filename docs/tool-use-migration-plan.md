# Migration Plan: JSON Parsing → Dual-Mode (MCP + API Key)

## Overview

We're transforming the app from a self-contained chat UI that calls the Anthropic API into a flexible Ableton control layer that supports two modes:

- **MCP mode (primary):** Claude Desktop connects to our app as an MCP server. The LLM reasoning happens entirely on the client side. Our app is a headless tool provider. No API key needed — the user's Claude subscription covers everything.
- **API key mode (fallback):** For users without Claude Desktop, or for our own dev/debug use, the app runs its own agentic tool-use loop via the Anthropic API. Requires an API key. Uses the existing LiveView as the interface.

Both modes share the same tool definitions, tool handlers, Registry, Transport, and Session State. The only difference is what's driving the tools: Claude Desktop or our own orchestration loop.

## User experience

These two modes are **separate user experiences** today. There is no way to unify them into a single UI.

### MCP mode user

1. Installs our app (runs as a background process)
2. Adds our MCP server to their Claude Desktop config (one-time setup — we could provide an installer or `seshat install` CLI command to automate this)
3. Restarts Claude Desktop
4. Types or speaks commands directly in Claude Desktop
5. Claude calls our tools via MCP, Ableton responds
6. **They never open a browser or see our LiveView**

### API key mode user

1. Installs our app and sets their Anthropic API key (env var or config)
2. Starts the Phoenix server
3. Opens `localhost:4000` in their browser
4. Types commands in the LiveView chat interface
5. Our Agent calls the Anthropic API, executes tools, Ableton responds
6. Results displayed in the LiveView

### Why can't we unify these today?

There is no way for our app to programmatically send a message to Claude Desktop and get a response back. Claude Desktop is a user-facing app, not a service — it doesn't expose a local API. MCP only goes one direction: Claude calls our tools, not the other way around.

For our LiveView to use local Claude, we'd need to send the user's text to a local Claude process and have it reason + call tools + return results. That interface doesn't exist yet.

### Future: unified UI via daemon/bridge mode

Claude Code's codebase contains unreleased feature flags for a **daemon/bridge mode** — a background service that third-party apps could send messages to programmatically. If/when this ships, it unlocks a third mode:

**Daemon mode:** Our LiveView sends the user's text to the local Claude daemon. Claude reasons locally (no API key needed), calls our tools, results come back to our UI. The user gets a single interface (our LiveView) powered by local Claude.

This would unify the experience: one UI, no API key, local Claude. Our architecture is ready for it — the shared tool layer means adding a third driver alongside MCP and Agent is straightforward. But we can't build against it today.

**When daemon mode ships, the migration is:** add a `Seshat.Daemon` module that connects to the local Claude socket instead of the Anthropic API, and add a mode selector in the LiveView. Everything else stays the same.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER INPUT                               │
│              (voice, text, Claude Desktop, browser)              │
└──────────────┬──────────────────────────────────┬───────────────┘
               │                              │
         MCP MODE                       API KEY MODE
               │                              │
               ▼                              ▼
┌──────────────────────┐        ┌──────────────────────────┐
│   Claude Desktop     │        │  Phoenix LiveView        │
│   (MCP client)       │        │  (our UI)                │
│                      │        │         │                │
│   LLM reasoning      │        │         ▼                │
│   managed by Claude  │        │  Seshat.Agent            │
│                      │        │  (agentic tool-use loop  │
│                      │        │   calling Anthropic API) │
└──────────┬───────────┘        └────────────┬─────────────┘
           │                                 │
           │        ┌────────────────┐       │
           └───────►│  Shared Layer  │◄──────┘
                    │                │
                    │  Tool Handlers │
                    │  Registry      │
                    │  Transport     │
                    │  Session State │
                    └───────┬────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │  OSC (UDP)    │
                    │  Ableton Live │
                    └───────────────┘

Future (daemon mode):

┌──────────────────────────┐
│  Phoenix LiveView        │
│  (our UI)                │
│         │                │
│         ▼                │
│  Seshat.Daemon           │
│  (sends to local Claude  │
│   daemon, no API key)    │
└────────────┬─────────────┘
             │
             ▼
      Shared Layer (same as above)
```

## What changes

| Layer | Current | MCP mode | API key mode |
|---|---|---|---|
| LLM integration | We call API, parse JSON | Gone — MCP client handles it | We call API with tool definitions |
| Parser module | Prompt engineering + JSON parsing | Not used | Replaced by `Seshat.Agent` (agentic loop) |
| System prompt | 40 lines of JSON formatting rules | Not our concern | Simplified — role + rules only, no JSON schema |
| Entry point | LiveView only | MCP protocol (stdio/SSE) | LiveView |
| Tool execution | Parser builds Command, passes to Registry | MCP server dispatches to tool handler → Registry | Agent loop dispatches to tool handler → Registry |

## What doesn't change

- **OSC Transport** — untouched
- **OSC Message encoding** — untouched
- **Session State** — untouched
- **Registry** — untouched, still receives Command structs
- **Command struct** — still used internally

## Module structure after migration

```
lib/seshat/
├── commands/
│   ├── command.ex              # unchanged
│   └── registry.ex             # unchanged
├── osc/
│   ├── transport.ex            # unchanged
│   └── message.ex              # unchanged
├── session/
│   └── state.ex                # unchanged
├── tools/
│   ├── definitions.ex          # tool schemas (shared by both modes)
│   └── handlers.ex             # tool execution logic (shared by both modes)
├── mcp/
│   └── server.ex               # MCP protocol handler (stdio/SSE transport)
└── agent.ex                    # agentic tool-use loop for API key mode
```

`Seshat.Tools.Definitions` and `Seshat.Tools.Handlers` are the shared core. Both `Seshat.MCP.Server` and `Seshat.Agent` use them. The old `Parser` module is eventually deleted.

## Step-by-step plan

### Phase 1: Extract shared tool layer

Create the shared tool infrastructure that both modes will use.

**`Seshat.Tools.Definitions`** — tool schemas in a format-agnostic structure that can be serialized to either MCP or Anthropic API format:

```elixir
def all do
  [
    %{
      name: "set_track_pan",
      description: "Set the stereo panning position of a track...",
      parameters: %{
        type: "object",
        properties: %{
          track: %{type: "integer", description: "0-indexed track number..."},
          value: %{type: "number", minimum: -1.0, maximum: 1.0, description: "Pan position..."}
        },
        required: ["track", "value"]
      }
    },
    # ... more tools
  ]
end

# Serialize for Anthropic API tool use
def to_anthropic_tools, do: ...

# Serialize for MCP tools/list response
def to_mcp_tools, do: ...
```

**`Seshat.Tools.Handlers`** — dispatches tool calls to the Registry:

```elixir
def call("set_track_pan", %{"track" => track, "value" => value}) do
  command = %Command{command: :pan, track: track, value: value}
  case Registry.execute(command) do
    :ok -> {:ok, "Panned track #{track} to #{value}"}
    {:error, reason} -> {:error, reason}
  end
end

def call("get_session_state", _params) do
  state = Session.State.get()
  {:ok, Jason.encode!(state)}
end
```

**Initial tool set:**

```
set_track_pan(track, value)
set_track_volume(track, value)
set_track_mute(track, muted)
set_track_solo(track, soloed)
create_track(track_type, name)
create_project(tracks)
get_session_state()
```

This phase is purely additive. Nothing existing changes.

### Phase 2: Build MCP server

Create `Seshat.MCP.Server` — handles the MCP protocol and delegates to the shared tool layer.

**Transport:** Start with stdio (Claude Desktop native support). The server:
- Handles `initialize` / `initialized` handshake
- Responds to `tools/list` using `Definitions.to_mcp_tools()`
- Routes `tools/call` to `Handlers.call(name, params)`
- Returns results in MCP format

**Test milestone:** Configure Claude Desktop to connect, type "pan track 1 left," verify Ableton responds.

### Phase 3: Build API key agent

Create `Seshat.Agent` — an agentic loop that calls the Anthropic API with tool definitions and executes tool calls.

```elixir
def run(input, history \\ []) do
  tools = Definitions.to_anthropic_tools()

  messages = history ++ [%{role: "user", content: input}]

  {:ok, response} = call_api(messages, tools)

  process_response(response, messages)
end

defp process_response(%{stop_reason: "end_turn"} = response, messages) do
  text = extract_text(response)
  {:ok, %{response: text, commands_executed: [], messages: messages ++ [response]}}
end

defp process_response(%{stop_reason: "tool_use"} = response, messages) do
  tool_results = execute_tool_calls(response)  # calls Handlers.call/2
  messages = messages ++ [response, %{role: "user", content: tool_results}]

  {:ok, next_response} = call_api(messages, Definitions.to_anthropic_tools())
  process_response(next_response, messages)
end
```

This replaces the current `Parser` module. Same idea — user input in, actions out — but now it supports multi-step tool use instead of single-shot JSON.

**System prompt simplifies to:**

```
You are an assistant for Ableton Live. You control the DAW using the tools provided.

Rules:
- Track indices are 0-based. "Track 1" = index 0.
- Use get_session_state to check current values before making relative adjustments.
- For ambiguous requests, use your best judgment.
- You can call multiple tools to fulfill a single request.
```

### Phase 4: Update LiveView for API key mode

The chat interface wires through `Seshat.Agent` instead of the old `Parser`. Handle the new return shape:

- Display text responses from Claude (for queries, guidance, etc.)
- Log each executed command in the chat history
- Handle multi-action responses ("Done — I panned the guitars wider and added reverb.")
- Store full conversation history (including tool calls/results) for multi-turn context

**Dashboard features** (useful in both modes):
- Live session state viewer
- Tool call log (from either MCP or Agent)
- OSC message log
- MCP connection status indicator

### Phase 5: Configuration

```elixir
# config/dev.exs
config :seshat, :anthropic_api_key, System.get_env("ANTHROPIC_API_KEY")
```

No explicit mode toggle needed. Both modes can be active simultaneously:
- If an MCP client connects via stdio/SSE → MCP mode is active
- If user opens the LiveView and an API key is configured → API key mode is available
- If no API key is set, the LiveView shows the dashboard only (no chat)

### Phase 6: Expose MCP resources

MCP supports **resources** — read-only data the client can pull into context:

```
seshat://session/state → full track list with mixer values
seshat://session/tracks/{index} → single track details
```

Lets Claude Desktop read session state without a tool call. Not critical — `get_session_state` tool works fine — but a nicer experience.

### Phase 7: Add new tools

Adding capabilities is now the same for both modes:
1. Add definition to `Seshat.Tools.Definitions`
2. Add handler to `Seshat.Tools.Handlers`
3. Add `Registry.execute` clause if it needs OSC

No changes to MCP server or Agent needed. Both pick up new tools automatically.

**Candidate tools:**

- `set_tempo(bpm)`
- `start_playback()` / `stop_playback()`
- `arm_track(track, armed)`
- `start_recording()`
- `get_track_devices(track)`
- `search_presets(query, category, tags)`
- `load_preset(track, preset_path)`
- `add_device(track, device_name, position)`
- `set_device_parameter(track, device, param, value)`

## Migration order and risk

| Phase | Risk | Notes |
|---|---|---|
| 1. Shared tool layer | None | Purely additive |
| 2. MCP server | Low | New code, no existing changes |
| 3. API key agent | Medium | Replaces parser, but old parser stays until tested |
| 4. LiveView update | Low | Incremental changes |
| 5. Configuration | Low | Config only |
| 6. MCP resources | None | Additive, optional |
| 7. New tools | None per tool | Ongoing |

**Nothing is deleted until both modes work.** The old parser and LiveView chat keep functioning in parallel.

## Testing strategy

- **Unit test tool handlers** — call `Handlers.call/2` with known inputs, mock Transport, verify OSC messages.
- **MCP protocol tests** — send raw JSON-RPC to MCP server, verify tool list and tool call responses.
- **Agent loop tests** — mock Anthropic API responses, verify correct tool call sequences.
- **End-to-end MCP** — Claude Desktop → tool call → Ableton responds.
- **End-to-end API key** — LiveView input → Agent → tool call → Ableton responds.
- **Regression** — "pan track 1 to the left" works identically in both modes.

## Open questions

1. **MCP library:** Use an existing Elixir MCP library or implement the protocol ourselves? Evaluate what's on Hex. The protocol is simple (JSON-RPC over stdio) but a library handles edge cases.

2. **stdio vs SSE:** Start with stdio for MCP (Claude Desktop native). Add SSE later if we want remote/multi-client support. Phoenix makes SSE trivial.

3. **Model selection for API key mode:** Currently using Haiku. For complex multi-step workflows, Sonnet would be better. Could make it configurable or auto-select based on detected complexity.

4. **MCP notifications:** Server-initiated push of session state changes (e.g. user mutes a track in Ableton directly). Would let Claude react to external changes. Worth exploring after basics work.

5. **Speech-to-text:** The end goal is voice control. In MCP mode, this depends on the MCP client supporting STT (or system-level dictation). In API key mode, we could add our own STT integration. Either way, outside the scope of this migration.

6. **Cost for API key mode:** Tool use with multiple round-trips costs more tokens than single-shot JSON. Haiku is cheap, but worth monitoring. MCP mode has no per-call cost to us.

7. **Daemon/bridge mode:** Claude Code contains unreleased feature flags for a local daemon mode. When this ships, we can add a `Seshat.Daemon` module as a third driver — our LiveView sends text to the local Claude daemon, which reasons and calls tools without an API key. The shared tool layer means this is a drop-in addition. Track Anthropic's releases for this.
