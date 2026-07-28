# Seshat

Natural-language control of Ableton Live. Say "pan the drums left a bit" or
"write a four-bar minor key bassline on track 2" and it happens in your session.

Seshat is an Elixir/Phoenix app that exposes ~47 Ableton control tools and
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
git submodule update --init   # checks out Seshat's AbletonOSC fork
mix setup
mix abletonosc.install        # installs it into Ableton Live
```

Seshat runs its own fork of AbletonOSC —
[jpatricknola/AbletonOSC](https://github.com/jpatricknola/AbletonOSC), checked
out as a submodule at `priv/AbletonOSC`. `mix abletonosc.install` copies it
wholesale into Live's Remote Scripts directory, replacing any existing
AbletonOSC install. The fork adds what upstream is missing:

- **A browser API**, without which `search_library`, `list_browser_items` and
  `load_device` don't work.
- **Return track and master addresses** — upstream only reaches regular tracks
  — without which `set_track_send`, `get_track_sends`, `create_return_track`,
  `delete_return_track`, `set_return_track_volume`, `set_master_volume`, and the
  return/master lines in `get_session_state` don't work.
- **Track-list listeners**, so the session mirror follows tracks added, deleted
  or reordered by hand in Live.

It also fixes bugs in upstream's own code that have no extension seam — most
importantly a listener that unbinds from the wrong object once a track index has
been reused. `SESHAT.md` at the fork root lists every divergence.

The task probes for your AbletonOSC install (pass the path if it can't find it,
or if you want a fresh install somewhere specific). **Restart Ableton Live
afterwards** (or toggle AbletonOSC off and back on under Preferences >
Link/Tempo/MIDI > Control Surface) — `/live/api/reload` won't pick up a new
install, and can leave AbletonOSC with no handlers at all.

### Build the sound catalog (once)

With Ableton Live running, ask the assistant to **reindex the library** (the
`reindex_library` tool). It walks Live's whole browser and merges in the tags
Ableton's sound designers wrote for every factory and Pack preset, so
`search_library` can answer "a warm analog bass" rather than handing back 267
undifferentiated names.

It takes up to a minute and Live's UI will hitch while it runs. The result is
saved to `~/.seshat/catalog.json` and reused forever after — searching works
even with Ableton closed. Re-run it after installing new Packs or plugins, or
after saving your own presets.

<details>
<summary>Manual install</summary>

The task is a directory copy, so doing it by hand is one command. From the
Seshat project root, with Live closed:

```bash
rm -rf "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC"
cp -R priv/AbletonOSC "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC"
rm -rf "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC/.git" \
       "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC/tests"
```

There is nothing to register: the fork's `__init__.py` and `manager.py` already
list every handler. Restart Ableton Live.
</details>

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
when prompted. It connects over HTTP to a running `mix phx.server`, so start
that first; the tools are unavailable without it. This is deliberate: only one
process can hold OSC reply port 11001, so spawning a second Seshat over stdio
alongside the server would leave one of them unable to read from Ableton (see
[Only one Seshat at a time](#only-one-seshat-at-a-time)).

Then just talk to Ableton from the client. You never open a browser — the
server only needs to be running, not looked at.

### Only one Seshat at a time

AbletonOSC sends every reply and listener update to a fixed port, UDP 11001.
Whichever Seshat binds it first is the only one that can read Ableton; a second
instance can still send commands but never hears back. It detects this at
startup and says so:

```
[error] OSC reply port 11001 is already bound by another process — usually a
second Seshat instance (an MCP server and `mix phx.server` running at once).
```

If you see that, quit the other instance and restart. Reads returning
`{:error, :reply_port_unavailable}` are the same cause.

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
mix test         # 83 tests; no Ableton required
```

Tests avoid the live transport — anything reaching `Transport.query/3` needs
Ableton running and will time out (5 seconds by default).

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
| [docs/PLAN_sound_catalog.md](docs/PLAN_sound_catalog.md) | How the tag-aware sound catalog works, and its open follow-ups |
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

**`list_browser_items` times out.** Either `mix abletonosc.install` hasn't been
run (or Live wasn't restarted after it), or you're doing the first unfiltered
search of a huge category — retry with a filter.

**`search_library` says the catalog is empty.** It has never been built — run
`reindex_library` with Ableton open. If that times out too, it's the same
browser handler that `list_browser_items` needs.

**`search_library` returns items but almost none have tags.** Ableton's preset
database wasn't readable at reindex time, so everything fell back to
folder-derived tags. It lives at
`~/Library/Application Support/Ableton/Live Database/Live-files-*.db`; the
reindex logs a warning saying why it couldn't be read.
