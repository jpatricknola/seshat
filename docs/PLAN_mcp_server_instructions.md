# Plan — MCP server instructions: a home for session-level guidance

ROADMAP #1. Send server-level `instructions` from `Seshat.MCP.Server`,
carrying the cross-tool conventions no single tool description can, from one
source shared with API-key mode's system prompt.

## Context

In MCP mode — the primary mode — Seshat owns no system prompt. Tool
descriptions speak per tool; behavior *between* tools (what "start a new
project" implies, how to talk a user through a manual step, what not to relay
from tool replies) is unguided luck. The 2026-07-28 validation run produced
four findings that each needed a session-level rule and had nowhere to put it
([validation-script-thoughts-and-findings.md](validation-script-thoughts-and-findings.md)):

1. "Start a new project" only appended tracks, leaving the default set's
   leftover empty track for the user to notice.
2. `search_library`'s diagnostic text ("No 'Warm' tag exists in your
   library") was relayed verbatim to a musician who never asked about tags —
   it exists to steer the model's retry, not to be quoted.
3. Asked to talk the user through a manual UI step, Seshat first assumed Live
   fluency ("Tab to Session View"), then over-corrected into a four-paragraph
   lecture. The target register is precise brevity: every keystroke located
   physically, every step confirmed by what appears on screen, nothing else.
4. Asked for something outside its tools (audio output device), Seshat
   improvised instead of saying where the setting lives.

MCP's `initialize` response has a first-class field for exactly this:
`instructions`, which clients "MAY add to the system prompt". Anubis already
supports it — `Anubis.Server` defines an overridable `server_instructions/0`
callback ([deps/anubis_mcp/lib/anubis/server.ex:192](../deps/anubis_mcp/lib/anubis/server.ex))
whose non-nil return `Anubis.Server.Session` puts into the `initialize`
result. `Seshat.MCP.Server` currently declares only `capabilities: [:tools]`
and inherits the default `nil`. So the transport work is one callback; the
real deliverable is the *text*, and a structure that keeps API-key mode
(`Seshat.Agent`'s `@system_prompt`) reading from the same source instead of
diverging.

Key constraints, all inherited from how tool descriptions are governed:

- **Short.** The instructions ride along in every session's context.
  Everything that can live in a tool description already does; this text is
  only for what no single tool can say.
- **Nothing machine-specific.** Tag vocabulary, installed Packs, track names —
  all per-machine, all already flowing through tool replies. Same rule that
  keeps them out of tool descriptions.
- **One source, two modes.** `Seshat.Agent` keeps its API-mode-only material
  (the MIDI crash course exists because that mode runs a small model), but the
  session conventions must not become a diverging copy.

## Contract

No OSC surface — this feature sends nothing to Ableton. The contract is MCP's
`initialize` handshake instead:

- `Seshat.MCP.Server.server_instructions/0` (arity 0, `@impl Anubis.Server`)
  returns `String.t() | nil`. Non-nil → Anubis serialises it as the
  `instructions` field of the `initialize` result. Verified in
  [deps/anubis_mcp/lib/anubis/server/session.ex](../deps/anubis_mcp/lib/anubis/server/session.ex)
  (`module.server_instructions()` captured at session init;
  `maybe_put_instructions/2` on the result).
- Both transports (stdio via `mix mcp`, streamable HTTP) use the same server
  module, so both get it for free.
- Instructions are delivered at connect time: shipping this needs a server
  restart and an MCP client reconnect, nothing more. No
  `mix abletonosc.install`, no reindex.
- ⚠️ The MCP spec says clients **MAY** add instructions to the system prompt —
  delivery to the model is client behavior we can't force. Claude Code is
  known to surface server instructions; verify at smoke-test time before
  judging any behavioral change (Open question 1).

## The instructions text (draft)

The load-bearing section — this is prompt text, so the draft is the plan.
Lives in `Seshat.Instructions.text/0`:

```
Seshat controls the user's live Ableton Live set. The user is a musician at
work: the goal is making music, not teaching Ableton.

- Assume no Live UI fluency unless the user demonstrates it.
- Starting fresh: "new project" means replace what's here, not add to it.
  Invite a one-line brief (genre, tempo, mood, reference) before assuming
  defaults. If the set holds leftover empty default tracks, create the new
  tracks first, then delete the empty leftovers (Live requires at least one
  track) — or offer to.
- Read before you change: check get_session_state before relative adjustments
  ("a bit more", "turn it down") and to resolve track names.
- Speak music, not plumbing: refer to tracks and devices by name or the
  1-based numbers Live displays — never raw indices, tool names, tags, or
  catalog internals. Search diagnostics ("no such tag", tag suggestions) are
  instructions for your next search, never content to relay.
- Offer choices: present search results as a short slate with a one-line
  musical reason each and a recommendation; ask before loading.
- Know the boundaries: when a request needs something these tools can't
  reach, say so plainly and say exactly where in Live the setting lives.
  Don't improvise workarounds.
- Manual steps, when unavoidable: give the shortest complete path. Locate
  every key physically ("press the Tab key, above Caps Lock"), confirm every
  step by what appears on screen ("you should now see a grid of colored
  cells"). No concept explanations, no alternatives up front — keep fallbacks
  for when a step didn't work.
```

~1,700 characters. Each bullet traces to a validation finding or a roadmap
note; nothing here is machine-specific, and nothing duplicates what a tool
description already says (the 0-based index rule, value ranges, and per-tool
preconditions stay in descriptions where they belong).

## Parts

### 1. `Seshat.Instructions` — the shared source

New file `lib/seshat/instructions.ex`. Top-level module (not under `Tools` or
`MCP`) because both entry points read it — same reasoning that puts
`Seshat.Tools.Handlers` at the funnel point of both modes.

- `@text` module attribute holding the draft above; `def text, do: @text`.
- Moduledoc stating the governing rules so future edits keep them: short,
  nothing machine-specific, session-level only (per-tool guidance belongs in
  `Seshat.Tools.Definitions`), and that both `Seshat.MCP.Server` and
  `Seshat.Agent` consume it.

### 2. `Seshat.MCP.Server` — send it

[lib/seshat/mcp/server.ex](../lib/seshat/mcp/server.ex): add

```elixir
@impl Anubis.Server
def server_instructions, do: Seshat.Instructions.text()
```

A module-defined callback wins over the `use`-option default (Anubis checks
`Module.defines?/2` before injecting its own), so no change to the `use`
options. Moduledoc gains a line saying session-level guidance is sent as
server instructions from `Seshat.Instructions`.

### 3. `Seshat.Agent` — same source, no diverging copy

[lib/seshat/agent.ex](../lib/seshat/agent.ex): replace the `@system_prompt`
attribute with a `system_prompt/0` function returning
`Seshat.Instructions.text() <> "\n" <> @agent_specific`, and delete the
bullets the shared text now covers:

- "When reporting back to the user, refer to tracks by name or 1-based UI
  number…" — subsumed by *speak music, not plumbing*.
- "Use get_session_state to check current values before making relative
  adjustments…" and "When the user refers to a track by name…" — subsumed by
  *read before you change*.

Everything else stays as `@agent_specific`: the 0-based index rule, the
key/scale hint, best-judgment-over-clarification, multi-tool calls, and the
whole MIDI writing / editing crash course — that material exists because
API-key mode runs a small model, and has no business in MCP instructions.

### 4. `search_library` marks its diagnostics as model-internal

The roadmap's rider: guidance alone didn't stop the leak reaching the user,
so the reply also marks itself. In
[lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex),
`format_catalog_entries/3` appends one sentence to the two branches that emit
steering text:

- Zero-result branch (diagnosis): after the diagnosis notes, add
  `"(Diagnostics are for refining your search — present results musically;
  don't mention tags to the user.)"`
- Truncated-with-facets branch: same sentence after the "top tags among
  them…" header.

The exact-match and no-facets branches stay untouched — they contain nothing
to leak. The `search_library` tool description in `Definitions` is *not*
changed: the marker travels with the text it governs, which reaches the model
at exactly the moment it matters, in both modes.

### 5. Docs

- [CLAUDE.md](../CLAUDE.md): add `lib/seshat/instructions.ex` to the module
  map; one line in the "Two entry points" section noting both modes share
  `Seshat.Instructions`.
- [docs/TOOL_AUDIT.md](TOOL_AUDIT.md): note on the `search_library` inventory
  row that the diagnostic-leak wart is fixed (reply now marks diagnostics as
  internal).

### 6. Tests

- New `test/seshat/instructions_test.exs`: text is non-empty; a soft length
  tripwire (`String.length(text) < 3_000`) so "keep it short" survives future
  edits as a failing test, not a forgotten intention.
- New `test/seshat/mcp/server_test.exs` (or extend `tools_test.exs`):
  `Seshat.MCP.Server.server_instructions() == Seshat.Instructions.text()` —
  the parity guard, same spirit as the existing MCP⟷Definitions parity tests.
- [test/seshat/agent_test.exs](../test/seshat/agent_test.exs): in the
  existing `Req.Test` intercept, assert the request's `system` field starts
  with `Seshat.Instructions.text()` — API-key mode provably carries the
  shared source.
- [test/seshat/tools/handlers_test.exs](../test/seshat/tools/handlers_test.exs):
  `format_catalog_entries/3` cases — zero-result-with-diagnosis and
  truncated-with-facets replies contain the internal marker; full-result
  replies don't.

No tool added or removed → no `definitions_test.exs` count bump.

## Testing

Everything above is pure — no Ableton, no `Transport.query/3`, `mix test`
covers it all. What needs a live client (`/smoke-test` additions, in order):

1. **Delivery check first** (gates the rest): restart the server, reconnect
   Claude Code, confirm the instructions text actually appears in the
   client's context (e.g. `/context` or the MCP server details view). If it
   doesn't, stop and resolve Open question 1 before evaluating behavior.
2. "Let's start a new project — give me two MIDI tracks" against a default
   set → leftover empty track deleted or its removal offered.
3. A search with a vocabulary miss ("warm electric piano") → reply presents
   musical choices, no tag talk.
4. A request outside the tools ("switch audio output to my headphones") →
   names where the setting lives in Live, no improvised workaround.
5. A "why can't I see X?" UI question → keystroke-located, screen-confirmed
   steps in the precise-brevity register.

## Out of scope

- **Follow cam / view steering** — the *acting* fix for finding 3's underlying
  problem stays ROADMAP #3; this issue ships only the instructing register
  for cases where tools can't act.
- **New-project kickoff flow as tooling** (a brief that persists, kickoff
  questions steering search) — the instructions carry its practical core
  ("invite a one-line brief"); anything stateful stays a roadmap discussion.
- **Catalog staleness surfacing** — ROADMAP #7, even though it may one day
  want a line here.
- **`AssistantLive` UI changes** — the browser UI already gets the shared
  text through `Seshat.Agent`; nothing to show the user.
- **A fallback delivery channel** (MCP resource, preamble in a tool
  description) if some client ignores `instructions` — not designed until a
  client we care about actually ignores them.

## Open questions

1. **⚠️ Does the client deliver instructions to the model?** The MCP spec
   makes it a MAY; Anubis sends the field, but whether Claude Code / Claude
   Desktop inject it into context can only be verified with a live session.
   Couldn't resolve now: needs the running server and a reconnected client.
   Assumed in the meantime: Claude Code does (it is documented to surface
   server instructions). Smoke-test step 1 verifies before any behavioral
   judgment; if it fails, the shared-source structure still stands and only
   the delivery channel needs rethinking.
2. **Is the draft's tone Patrick's?** The text is a personality contract as
   much as a mechanism, and only its author can sign off wording (e.g. is
   "ask before loading" too strong a default for every search?). Couldn't
   resolve now: needs the user's read. Assumed in the meantime: the draft
   ships as written above; `/plan-review` and the user's pass on this doc are
   the review points.
