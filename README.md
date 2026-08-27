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

Seshat is an MCP server built with Elixir/Phoenix. It exposes Ableton control
tools — tracks, clips, notes, devices, mixer, sends and returns, transport,
recording, and the sound library — and sends OSC to a running copy of Ableton
Live.

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

### Install the Accessibility helper (macOS, once)

```bash
mix ax.install
```

Two tools — `get_audio_outputs` and `set_audio_output` — do not go through
AbletonOSC at all. Live's application-wide audio *device* preference is not in
the Live Object Model, so there is no OSC address for it at any version of the
bridge; the only way to reach it is Live's own Settings window, through macOS
Accessibility. `mix ax.install` compiles a small native helper from
`native/seshat_ax/main.m` and installs it at `~/.seshat/bin/seshat-ax`.

Everything else Seshat does still goes through the LOM. The helper's protocol is
four commands wide — report its own version, report its own permission status,
list the outputs, set one — deliberately, so this stays one narrow workflow
rather than a second control surface.

macOS asks you to approve the helper once, under **System Settings → Privacy &
Security → Accessibility**; the task prompts for it and prints the path to turn
on. It needs **no** Automation/Apple Events permission and **no** Screen
Recording permission, and neither Ableton Live nor Seshat needs restarting
afterwards. Until it is granted, both tools fail immediately saying so — they
never open System Settings on their own.

The path is stable because macOS is expected to attach the permission to the
executable at that path: re-running `mix ax.install` after a change rebuilds
in place and, as measured 2026-08-03, keeps the grant. Compilation is atomic,
so a build that fails leaves the working, already-approved helper untouched.

**Open question, and the evidence now points away from that expectation.**
Three separate observations (2026-08-27) have a helper reporting itself
trusted when nothing ever approved it: two PR reviews built one fresh to a
scratch path and ran it from an already-approved terminal, and — the one that
is not explainable by the terminal — a GitHub Actions `macos-latest` runner,
a machine nobody has ever granted anything on, answered
`{"ok":true,"protocol_version":1,"trusted":true}`. That third result broke a
CI step which had asserted the opposite; the step now checks only that the
reply is well-formed and internally consistent, because either answer is one
macOS may legitimately give.

Two explanations survive, and this project has not separated them: macOS may
attribute Accessibility trust to the responsible *parent* process rather than
to the executable, or the environments observed may simply be trusted wholesale
(a CI runner running as root is trusted unconditionally, which would explain
the third case and say nothing about the first two). Nobody has run the
comparison that would tell them apart — the same installed build, launched from
a parent that was approved and from one that was not.

What this means in practice: **do not rely on the grant being attached to
`~/.seshat/bin/seshat-ax` specifically.** If trust follows the parent, a user
who launches Seshat from a different terminal, a supervisor, or a login agent
than the one they approved under can be refused despite having approved the
right path — and, in the other direction, a `trusted: true` reading is not by
itself proof that the install is correctly permitted. Treat the reading as
advisory until someone runs that comparison during a real onboarding.

When you ask for an output change, Live briefly comes to the front while the
helper reads or sets the value, then the application that was frontmost goes
back in front. A Settings window the helper opened is closed again; one you had
open already is left open, on the page you had selected. The change is applied to
Ableton's preferences rather than to your Set, so it is **outside Live's undo
history** — reverse it by setting the previous device, not with `undo`. It also
does not touch the macOS system-wide output; `Use System Device` selects
"follow macOS" inside Live and nothing more.

This is macOS-only. Seshat itself still compiles and tests anywhere; only these
two tools need the helper.

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

## Connect over MCP

Seshat runs only as an MCP server; the reasoning happens in your MCP client, so no
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
second Seshat instance (for example, `mix mcp` and `mix phx.server` running at
once).
```

If you see that, quit the other instance and restart. Reads returning
`{:error, :reply_port_unavailable}` are the same cause.

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
| [.claude/docs/command-flow.md](.claude/docs/command-flow.md) | End-to-end MCP request path |
| [.claude/docs/ableton-lom.md](.claude/docs/ableton-lom.md) | Ableton's Live Object Model |
| [.claude/docs/ableton-osc-reference.md](.claude/docs/ableton-osc-reference.md) | Seshat's consumer-side OSC notes (ports, ordering, correlation) |
| [priv/AbletonOSC/API.md](priv/AbletonOSC/API.md) | Canonical OSC address reference |
| [docs/ROADMAP.md](docs/ROADMAP.md) | What's not built yet — the living, priority-ordered queue |
| [docs/archive/PLAN_remaining_osc_tools.md](docs/archive/PLAN_remaining_osc_tools.md) | *Archived* — the tool-coverage plan ROADMAP.md superseded |
| [docs/archive/PLAN_sound_catalog.md](docs/archive/PLAN_sound_catalog.md) | *Archived* — how the tag-aware sound catalog works, and its open follow-ups |

## Troubleshooting

**Commands report success but nothing happens in Ableton.** OSC is fire-and-forget
UDP — a wrong address produces no error. Check the address against
[priv/AbletonOSC/API.md](priv/AbletonOSC/API.md).

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

**`get_audio_outputs` / `set_audio_output` say the helper isn't installed or
isn't trusted.** Run `mix ax.install` (macOS only) and turn on the printed path
under System Settings → Privacy & Security → Accessibility. No restart of Live
or Seshat is needed afterwards. If it still says untrusted, check that the entry
you enabled is `~/.seshat/bin/seshat-ax` and not an older copy left somewhere
else. The permission was *expected* to follow the executable, but the
evidence is against that being the whole story (see the "Open question" note
under [Install the Accessibility helper](#install-the-accessibility-helper-macos-once)).
So if the right path is enabled and it is still refused, try launching Seshat
from the same terminal application you approved under before re-checking the
path — trust may be attached to the parent process rather than to the binary.

**`set_audio_output` reports that Live's Settings couldn't be reached.** Live
was running but its Settings window wouldn't open or the Audio page wasn't
where the helper expects it. A modal dialog in Live blocks the menu, so dismiss
anything Live is asking about first. The helper only speaks Live 12's English
labels; a non-English Live is out of scope, and it will say it could not find
the control rather than guessing at coordinates.
