# Automated smoke tests

Everything in this folder can be run **and judged** by one agent, with Live and
Seshat already running and no user action. That is what the folder means — see
[../README.md](../README.md) for the rules governing both halves of the suite.

Run the lot with **`/smoke-test`**, or one file with `/smoke-test <name>`.

One file per subsystem. Read the one you need; nothing here is meant to be read
in full.

| File | Covers |
|---|---|
| [bridge.md](bridge.md) | the fork answering at all, the reply envelope, fast rejection |
| [network-boundary.md](network-boundary.md) | the loopback bind, browser exports, stale-export cleanup |
| [mirror.md](mirror.md) | `Session.State` — the settling marker, refresh coalescing |
| [mcp-surface.md](mcp-surface.md) | the advertised tool list and how a rejection reaches a client |
| [catalog.md](catalog.md) | `search_library` tag diagnostics and usage ranking |
| [devices.md](devices.md) | parameter 0, device error paths, the stray-track guard |
| [clips.md](clips.md) | clip properties and `quantize_clip` |
| [recording.md](recording.md) | `record_clip` / `stop_recording` |
| [views.md](views.md) | `hide_view` |
| [transport.md](transport.md) | tempo, time signature, swing and groove |
| [audio-output.md](audio-output.md) | the unavailable-output failure path |
| [undo.md](undo.md) | undo granularity and the `can_undo` / `can_redo` guards |

Several subsystems have a human-judged half as well — the same feature's ear,
eye and conversation checks live in [../manual/](../manual/), grouped by what
the run demands rather than by subsystem. `bridge.md`, `mirror.md`,
`devices.md`, `views.md`, `catalog.md`, `transport.md`, `recording.md`,
`network-boundary.md`, `clips.md`, `mcp-surface.md` and `audio-output.md` all
have one; only `undo.md` is very nearly self-contained.

## Two habits that decide whether a run is worth anything

- **Verify through a `get_*` tool, never through the tool's own reply.** Every
  OSC setter is fire-and-forget; a wrong address fails silently, and a refusal
  that quietly *did* send reads identically to one that didn't. The read-back is
  the test.
- **Follow the stated method exactly where one is specified.** When a test says
  to issue a sequence in a single model response, or to baseline a log offset
  first, that is not stylistic — it is what makes the test able to fail.

Some tests here read the Seshat server's log (`log/dev.log`, configured by
`config :seshat, :logger` in [../../../config/dev.exs](../../../config/dev.exs)).
Baseline its byte size before the run and read only the tail past that offset.
