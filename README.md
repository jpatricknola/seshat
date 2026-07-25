# Seshat

Natural-language control of Ableton Live. Say "pan the drums left a bit" or
"write a four-bar minor key bassline on track 2" and it happens in your session.

Seshat is an Elixir/Phoenix app that exposes ~32 Ableton control tools and
sends OSC to a running copy of Ableton Live.

## Prerequisites

1. **Ableton Live** (tested against Live 12).
2. **[AbletonOSC](https://github.com/ideoforms/AbletonOSC)** — a Python MIDI
   Remote Script. Install it into Ableton's Remote Scripts folder and enable it
   under Preferences → Link/MIDI → Control Surface. It listens on UDP 11000 and
   replies on 11001.
3. **Elixir 1.15+**.

No database required.

## Setup

```bash
mix setup
```

For API-key mode, set an Anthropic key — either an env var:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

or `config/dev.secret.exs` (gitignored):

```elixir
import Config
config :seshat, :anthropic_api_key, "sk-ant-..."
```

## Two ways to run it

### MCP mode (primary)

Seshat runs as an MCP server; the reasoning happens in your MCP client, so no
API key is needed — your Claude subscription covers it.

For **Claude Desktop**, add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "seshat": {
      "command": "mix",
      "args": ["mcp"],
      "cwd": "/path/to/seshat"
    }
  }
}
```

For **Claude Code**, the repo ships a `.mcp.json` — approve the `seshat` server
when prompted. It launches `mix mcp` over stdio.

Then just talk to Ableton from the client. You never open a browser.

### API-key mode (dev / fallback)

```bash
mix phx.server
```

Visit [localhost:4000](http://localhost:4000) and type commands into the chat
UI. `Seshat.Agent` runs its own tool-use loop against the Anthropic API
(`claude-haiku-4-5-20251001`).

Both modes drive the same tools through the same handlers.

## Development

```bash
mix precommit    # compile --warnings-as-errors, deps.unlock --unused, format, test
mix test         # 38 tests; no Ableton required
```

Tests avoid the live transport — anything reaching `Transport.query/2` needs
Ableton running and will time out after 5 seconds.

## Docs

| File | What's in it |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Architecture and conventions — read this first |
| [.claude/docs/adding-a-tool.md](.claude/docs/adding-a-tool.md) | How to add a tool |
| [.claude/docs/command-flow.md](.claude/docs/command-flow.md) | End-to-end request path for both modes |
| [.claude/docs/ableton-lom.md](.claude/docs/ableton-lom.md) | Ableton's Live Object Model |
| [.claude/docs/ableton-osc-reference.md](.claude/docs/ableton-osc-reference.md) | AbletonOSC conventions and gotchas |
| [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) | Canonical OSC address reference |
| [docs/PLAN_remaining_osc_tools.md](docs/PLAN_remaining_osc_tools.md) | What's not built yet |
| [docs/architecture-evaluation.md](docs/architecture-evaluation.md) | Why tool use over structured JSON |
| [docs/tool-use-migration-plan.md](docs/tool-use-migration-plan.md) | How the dual-mode design came about |

## Troubleshooting

**Commands report success but nothing happens in Ableton.** OSC is fire-and-forget
UDP — a wrong address produces no error. Check the address against
[docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md).

**Queries time out but sets work.** Something else is bound to port 11001, so
replies never arrive. Look for a "Port 11001 already in use" warning at startup.

**`get_session_state` says no tracks.** AbletonOSC isn't enabled as a Control
Surface, or Ableton isn't running.
