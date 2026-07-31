# Seshat

```
................................................................................
................................................................................
...................................I=~~~I~~~7...................................
...................................I....I...7...................................
..............................7II7II....I...~III77:.............................
...........................7I+.........:7.........,II,..........................
.........................I7...........I7:7...........77.........................
........................7~....,=7III?+.II,+?III7?,.....7,.......................
.......................I=...~I?.......~I+7.......,7I....7.......................
......................??...77.........I~.I.........+7....7......................
.....................,7...II..........7..I:.........=I...+I.....................
.....................I...?I+II........I..I~.......+IIII...7:....................
....................?I...7+I..I7......I..I~.....=I:.=77...,I....................
....................I...+I.?I...7:....7..I:....I+..~I..I...I....................
...................:?...7...=I...II...7:.I...+7...77...I+...I...................
...................7...7I.....77...7..+7~I..?I..~7......I...I~..................
..................77..,I........I?.+7?IIIII?I..I?.......I+..,I..................
.................,I...I,..........II7,.....III~..........I...7=.................
.................7...=I=I7777777I=.I........~?:I7777777I?=I...I.................
................I+...7=...........?=.........I...........:I7..:I................
...............?7...I~?7I7I?+?IIII?I.........I7III???IIIII+7:..~I...............
..............:I...7,..............I+.......I...............I=..:I..............
.............?7..:I,.............I7.II?..~II.77,.............7?..+7.............
............I7..+I.............7I..II..III.I7..?I.............I7..,I............
...........7=..I+............,I,..+I...77?..:7...I+............,7:.,I~..........
..........I..77.............77..,7?....77?....I:..~7.............II..7+.........
...........I7..............I?..I7......I7?.....?I...7..............II~..........
..........................?+,II........II?.......+I=:7..........................
..........................=I=..........I7I.........,II..........................
.......................................III......................................
......................................,I?I......................................
......................................:I+I......................................
......................................~I~I......................................
......................................+I:I......................................
......................................II.I......................................
......................................7I.I......................................
......................................I+.7......................................
......................................7~.7......................................
......................................I..7......................................
......................................I..I,.....................................
......................................7..7:.....................................
.....................................,7..+=.....................................
.....................................:I..:?.....................................
.....................................=I...I.....................................
.....................................?=...I.....................................
.....................................7,...I.....................................
.....................................I....I.....................................
.....................................II7I77.....................................
................................................................................
................................................................................
```

Natural-language control of Ableton Live. Say "pan the drums left a bit" or
"write a four-bar minor key bassline on track 2" and it happens in your session.

Seshat is an Elixir/Phoenix app that exposes Ableton control tools — tracks,
clips, notes, devices, mixer, sends and returns, transport, recording, and the
sound library — and sends OSC to a running copy of Ableton Live.

## Prerequisites

1. **Ableton Live** (tested against Live 12).
2. **Elixir 1.15+**.

Nothing else to download: the AbletonOSC bridge ships with Seshat as a
submodule, and `mix abletonosc.install` below puts it in place. You enable it
under Preferences → Link/MIDI → Control Surface once it's installed. It listens
on `127.0.0.1:11000` and replies to `127.0.0.1:11001`. Both halves of the bridge
are local-only: the command socket accepts loopback traffic only, and its replies
and listener pushes always go to loopback, never to whichever host last sent
something. Stock AbletonOSC listens on every network interface and follows the
last sender; Seshat's fork deliberately does neither, because every OSC address
can control Live and none of them authenticate.

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

It takes up to a minute and Live's UI will hitch while it runs. Along the way,
AbletonOSC writes a temporary export of the browser to
`~/.seshat/browser-exports/` and Seshat deletes it once the merge finishes; the
result that persists is saved to `~/.seshat/catalog.json` and reused forever
after — searching works even with Ableton closed. Re-run it after installing
new Packs or plugins, or after saving your own presets.

<details>
<summary>Manual install</summary>

The task is a directory copy, so doing it by hand is one command. From the
Seshat project root, with Live closed:

```bash
rm -rf "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC"
cp -R priv/AbletonOSC "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC"
rm -rf "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC/.git" \
       "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC/.github" \
       "$HOME/Music/Ableton/User Library/Remote Scripts/AbletonOSC/.gitignore" \
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

## Starting a session

Every session, start the three pieces in this order:

1. **Ableton Live**, with AbletonOSC enabled under Preferences →
   Link/Tempo/MIDI → Control Surface. Open the set you want to work on.
2. **Seshat** — `mix phx.server` from the project root.
3. **Your Claude client** — Claude Code or Claude Desktop.

Each step wants the one before it already up.

**Live before Seshat**, because Seshat queries Ableton the moment it boots to
build its session mirror. With Live down, that's a stack of five-second
timeouts and an empty mirror. It isn't fatal — AbletonOSC sends `/live/startup`
when it initialises and Seshat refreshes off that — but the boot is slow and
noisy for no reason, and until it lands the assistant thinks your set has no
tracks.

**Seshat before the client**, because both clients connect over HTTP to the
running server rather than spawning their own. No server, no tools — they won't
appear in the client at all. This is deliberate: only one process can hold OSC
reply port 11001, so a second Seshat would be deaf to Ableton (see
[Only one Seshat at a time](#only-one-seshat-at-a-time)).

The same order applies to restarts. Restarting Seshat drops the client's
connection, so reconnect it afterwards — in Claude Code, `/mcp` → reconnect.
Restarting *Live* needs nothing: `/live/startup` re-syncs the mirror on its own.

## Two ways to run it

### MCP mode (primary)

Seshat runs as an MCP server; the reasoning happens in your MCP client, so no
API key is needed — your Claude subscription covers it.

For **Claude Desktop**, add this to `claude_desktop_config.json` (with the
server already running, per [Starting a session](#starting-a-session)):

```json
{
  "mcpServers": {
    "seshat": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:4000/mcp"]
    }
  }
}
```

`mcp-remote` bridges Desktop's stdio to the running server's HTTP endpoint.
Don't spawn `mix mcp` here instead — that starts a *second* Seshat alongside
the server, and only one of them can read Ableton (see
[Only one Seshat at a time](#only-one-seshat-at-a-time)).

**Set the conversation to run on your computer, not in the cloud.** Claude
Desktop can run a chat locally or as a cloud session that reaches your Mac
through its remote-devices bridge. Only the local setting delivers Seshat's
session instructions (`Seshat.Instructions`) to the model. In a bridged
session the tools still work — they arrive namespaced
`mcp__remote-devices__seshat__*` rather than `mcp__seshat__*` — but the
server's `instructions` field does not survive the hop, so the model loses
every session-level convention and behaves like a bare tool-caller.

Verified 2026-07-29 by putting a marker phrase in the instructions and asking
for it back: delivered when run locally, absent when bridged. The same test
found the client truncates instructions at 2,048 characters without saying
so, which is why `Seshat.Instructions` has a hard ceiling — see the comment
above `@text` in [lib/seshat/instructions.ex](lib/seshat/instructions.ex).

For **Claude Code**, the repo ships a `.mcp.json` — approve the `seshat` server
when prompted. It points at the running server's HTTP endpoint, so the order in
[Starting a session](#starting-a-session) applies: no `mix phx.server`, no
tools.

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
mix test         # no Ableton required — and safe to run with Live open
```

`mix test` cannot reach Ableton. In `MIX_ENV=test` the OSC transport sends to a
throwaway UDP port and binds another ([config/test.exs](config/test.exs)), never
AbletonOSC's 11000/11001 — [test/seshat/osc/transport_test.exs](test/seshat/osc/transport_test.exs)
fails if that is ever pointed back at Live. Nothing in the suite reaches
`Transport.query/3` either: those need a live Ableton and would time out
(5 seconds by default).

## Docs

| File | What's in it |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Architecture and conventions — read this first |
| [.claude/docs/adding-a-tool.md](.claude/docs/adding-a-tool.md) | How to add a tool |
| [.claude/docs/command-flow.md](.claude/docs/command-flow.md) | End-to-end request path for both modes |
| [.claude/docs/ableton-lom.md](.claude/docs/ableton-lom.md) | Ableton's Live Object Model |
| [.claude/docs/ableton-osc-reference.md](.claude/docs/ableton-osc-reference.md) | AbletonOSC conventions and gotchas |
| [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) | Canonical OSC address reference |
| [docs/ROADMAP.md](docs/ROADMAP.md) | What's not built yet — the living, priority-ordered queue |
| [docs/archive/PLAN_remaining_osc_tools.md](docs/archive/PLAN_remaining_osc_tools.md) | *Archived* — the tool-coverage plan ROADMAP.md superseded |
| [docs/archive/PLAN_sound_catalog.md](docs/archive/PLAN_sound_catalog.md) | *Archived* — how the tag-aware sound catalog works, and its open follow-ups |
| [docs/archive/architecture-evaluation.md](docs/archive/architecture-evaluation.md) | *Archived* — why tool use over structured JSON |
| [docs/archive/tool-use-migration-plan.md](docs/archive/tool-use-migration-plan.md) | *Archived* — how the dual-mode design came about |

## Troubleshooting

**Commands report success but nothing happens in Ableton.** OSC is fire-and-forget
UDP — a wrong address produces no error. Check the address against
[docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md).

**Queries time out but sets work.** Something else is bound to port 11001, so
replies never arrive. Look for an "OSC reply port 11001 is already bound by
another process" error at startup ([above](#only-one-seshat-at-a-time)).

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
