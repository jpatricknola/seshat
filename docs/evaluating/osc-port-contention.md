# OSC reply-port contention: why only one Seshat runs at a time

AbletonOSC sends every reply and listener update to a **fixed** UDP port,
11001 — not back to the sender's source port. Only one process can hold it, so
**only one Seshat instance can read from Ableton**, ever. That constraint is
not new and is not negotiable from our side; it belongs to AbletonOSC.

What was new is that the codebase handled losing that race in three separate
wrong ways, and that the repo's own configuration guaranteed the race would
happen. This note records what changed and why, and what was rejected.

## The symptom

Starting `mix phx.server` produced a warning followed by an endless crash
loop, roughly every five seconds:

```
[warning] Port 11001 already in use, binding to ephemeral port
[info] OSC Transport listening on UDP port 65122
...
[error] GenServer Seshat.Session.State terminating
** (stop) exited in: GenServer.call(Seshat.OSC.Transport, {:query, "/live/song/get/tempo", []}, 5000)
    ** (EXIT) time out
```

Ableton was running and healthy. A second Seshat held 11001 and was quietly
receiving all of Ableton's replies.

## Root cause: the repo started the competing instance

`.mcp.json` — committed, and read automatically by Claude Code on opening the
project — configured the `seshat` MCP server as a spawn of `mix mcp` over
stdio. That task calls `Mix.Task.run("app.start")`, booting the **entire OTP
application**, `OSC.Transport` and `Session.State` included. So merely opening
the project in an editor took port 11001, before the developer ran anything.

The task's own moduledoc already documented this as unsupported ("Do not run
alongside `mix phx.server`", recommending the HTTP endpoint instead). The
configuration contradicted the documentation, and the configuration won.

This matters for how the bug reads: nobody was doing anything unusual. The
default developer setup — open the project, start the server — was broken.

## The three defects

1. **A deaf transport reported itself as healthy.** On `:eaddrinuse`,
   `Transport.init/1` bound an ephemeral port and logged a warning about the
   port. A socket not bound to 11001 can send and can *never* receive, so every
   query issued from it was doomed before it left. The log said nothing about
   that consequence.

2. **`Session.State` crashed instead of degrading.** The module already had
   `probe/4`, whose entire purpose is catching the exit a timed-out
   `GenServer.call` raises in its caller — with a comment saying so. But
   `query_song_float/3`, `query_song_string/3`, `query_song_int/3` and the
   `num_tracks` query called `Transport.query/3` raw. The first timeout killed
   the GenServer inside `handle_continue(:setup)`; the supervisor restarted it
   into the identical failure, forever.

   **This defect was never really about port contention.** Starting Seshat with
   Ableton simply closed hit exactly the same crash loop. The port conflict was
   how we happened to find it.

3. **An empty track count queried track −1.** `Enum.map(0..(count - 1), ...)`
   with `count == 0` gives `0..-1`, which Elixir reads as a descending range:
   `[0, -1]`. Unrelated to the above; found while touching the same function.
   Fixed with a `read_tracks/2` clause mirroring the existing
   `read_return_tracks/2`.

## The change

| File | Change |
|---|---|
| `.mcp.json` | stdio spawn of `mix mcp` → `http://localhost:4000/mcp` |
| `lib/seshat/osc/transport.ex` | losing 11001 sets `deaf: true`, logs an error naming the conflict; queries return `{:error, :reply_port_unavailable}` immediately |
| `lib/seshat/session/state.ex` | all remaining raw queries routed through `probe/4`; catch-all fallback; `read_tracks/2` guards an empty set |
| `test/seshat/osc/transport_test.exs` | new — covers the deaf path |
| `README.md`, `lib/mix/tasks/mcp.ex`, `.claude/docs/ableton-osc-reference.md` | document the one-instance constraint |

## Decision 1: what a transport that lost the port should do

**Chosen: bind an ephemeral port, mark it `deaf`, fail queries instantly, log
an error.**

- *Rejected — keep the silent ephemeral fallback (status quo).* It converts a
  precise, detectable condition into a symptom that surfaces five seconds
  later, in a different module, as a timeout. The information is available at
  `init/1`; throwing it away is the whole bug.

- *Rejected — refuse to start (`{:stop, :eaddrinuse}`).* Appealing as fail-fast,
  and defensible. Rejected because `Transport` is a permanent child of the
  application supervisor: refusing means the whole app won't boot, taking down
  the web UI, the catalog, and the MCP endpoint — none of which need port
  11001 — over a condition that leaves most of Seshat usable. It also turns a
  clear diagnostic into a supervisor `:shutdown` cascade, which reads *worse*
  than the error we now log.

- *Chosen.* Sends still work, because they genuinely do: a deaf instance can
  drive Ableton, it just can't read it. Queries fail in microseconds rather
  than stalling 5s each (startup issues seven-plus serially). Every caller
  already handles `{:error, reason}`, so nothing downstream needed changing.

**The honest weakness of the chosen option:** a half-working instance — writes
land, reads don't — is a strange state to be in, and arguably more confusing
than a dead one. It is defensible only because the startup log is explicit
about exactly that, and because the alternative denies the user working
functionality for no gain. A reviewer who disagrees should push on this one
first; it is the softest call in the change.

## Decision 2: how Claude Code should reach the MCP server

**Chosen: point `.mcp.json` at the HTTP endpoint the running app already
serves.**

`Application.start/2` already starts the MCP server with
`transport: :streamable_http`, and the router forwards `/mcp` to it. So the
Phoenix server is already a complete MCP server; the stdio spawn was a second,
redundant one.

- *Rejected — leave `.mcp.json` alone and rely on the better error message.*
  This makes every developer hit a broken default and then read a log to
  recover. Diagnostics are not a substitute for not causing the problem.

- *Rejected — keep stdio, add a port guard to `mix mcp`.* Refuse to start if
  11001 is taken, with a clear message. This preserves standalone MCP, but
  gets the precedence backwards: whichever process starts first wins, and the
  editor-spawned one usually starts first, so the developer's explicit
  `mix phx.server` would be the one that loses. Fixing that means a priority
  scheme between two instances — complexity in service of keeping a second
  instance we don't want.

- *Chosen.* One process, unambiguous ownership of 11001, same tool surface
  (both transports serve components generated from `Seshat.Tools.Definitions`,
  so there is no capability difference).

**Trade-off accepted:** the MCP tools now require `mix phx.server` to be
running. No server, no `mcp__seshat__*`. This was raised with the user and
accepted explicitly, on the grounds that the server is already how they work.
It is a real regression for a "just open the editor and talk to Ableton"
workflow, and it is the other thing a reviewer should probe.

`mix mcp` is **kept**, not deleted — it remains correct for Claude Desktop on a
machine where nothing else starts Seshat. What changed is that it is no longer
launched automatically.

## Decision 3: crash vs. degrade in `Session.State`

**Chosen: degrade — keep the defaults, log a warning, stay alive.**

A supervisor restart is the right response to a transient fault. An
unreachable Ableton is not transient: restarting re-runs the identical queries
against the identical silence. The old behaviour was an infinite loop that
also denied the user the parts of Seshat that don't need Ableton.

Mirrored state is a cache of Ableton's truth, and its absence is representable
— the return-track and master code already established this, using `nil` for
"unknown" and refusing to fabricate a number. Extending that stance to song
and track state is consistent rather than novel.

## What this does not fix

- **Two Seshats still cannot both read Ableton.** Nothing can change that
  short of leaving AbletonOSC (see [bridge-options.md](bridge-options.md)).
  The change makes the collision loud and survivable, not impossible.
- **The deaf instance can still send.** Two instances both driving Ableton
  remains possible, and is fine — Ableton just receives commands — but it is
  not prevented.

## Testing

`test/seshat/osc/transport_test.exs` is a deliberate exception to the standing
rule that tests must not reach `Transport.query/3`. That rule exists because
queries need a live Ableton; the deaf path is the one query that resolves
without one, and is therefore the one worth testing. The setup occupies the
configured reply port itself (31001 in `config/test.exs`, not AbletonOSC's
11001 — see [PLAN_test_isolation.md](../archive/PLAN_test_isolation.md)), and
tolerates the port already being held — either way the precondition holds.
The query assertion uses a 200 ms timeout on purpose: if the
short-circuit ever regresses, the call exits and the test fails, rather than
passing quietly five seconds later.

Not covered: `Session.State`'s degraded refresh. `do_refresh/1` hardcodes
`Seshat.OSC.Transport` rather than taking it as an argument, so there is no
seam to inject a failing transport. The per-index helpers already thread a
`transport` argument through; extending that to `do_refresh/1` would make the
degradation testable and is the obvious follow-up.

## When to reopen this

- If MCP-without-a-server becomes a workflow that matters, revisit Decision 2 —
  most likely by making the stdio task refuse to boot when 11001 is held,
  accepting that the developer must then start it deliberately.
- If the half-working deaf state proves confusing in practice, revisit
  Decision 1 toward refusing to start, and move `Transport` under a supervisor
  whose failure doesn't take the web layer with it.
