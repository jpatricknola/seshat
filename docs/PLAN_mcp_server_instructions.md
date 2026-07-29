# Plan — MCP server instructions: a home for session-level guidance

ROADMAP #1. Send server-level `instructions` from `Seshat.MCP.Server`,
carrying the cross-tool conventions no single tool description can, from one
source shared with API-key mode's system prompt.

**Sequencing (Patrick, 2026-07-29): plumbing first, wording last.**

- **Phase 1 — everything but the prompt.** Every module, callback, wiring
  point, test and doc, with the prompt itself left **empty** and marked. No
  prose is written, no wording is debated, nothing ships that anyone has to
  have an opinion about.

  **Acceptance criterion: MCP mode behaves exactly as it does today.** Phase 1
  lays preparation and nothing else — if a Phase 1 change is observable to an
  MCP client, it is a bug in the phase split. This holds by construction:
  `text/0` returns `nil` and `maybe_put_instructions/2` skips the field on
  nil, so the `initialize` result is byte-identical to the current one.
  (API-key mode is free to change or degrade in the gap — it is the disfavored
  path, and deduplicating its prompt against the shared text is fine whenever
  it happens.)
- **Phase 2 — dial in the prompts.** A working session on the text, and
  nothing else. Because Phase 1 leaves the seams open and its tests assert
  only structure, Phase 2 is pure prose: no new plumbing, no code changes, no
  test moves.

**Every site where a prompt will eventually live is marked in Phase 1** with
the same comment, so `grep -rn "TODO - phase 2" lib/` is the complete agenda:

```elixir
# TODO - phase 2
# <what this prompt is for and what it has to accomplish>
```

Two facts make the split clean rather than wishful, both verified in the dep:
`Anubis.Server.Session` calls `module.server_instructions()` at session init
([session.ex:163](../deps/anubis_mcp/lib/anubis/server/session.ex)), so our
callback resolves `Seshat.Instructions.text()` at runtime — Phase 2 recompiles
one module and reconnects, and `server.ex` is never touched again. And
`maybe_put_instructions/2` skips the field entirely on `nil`
([session.ex:1708-1710](../deps/anubis_mcp/lib/anubis/server/session.ex)),
which is exactly the Phase 1 behavior we want: an unfinished prompt is not
sent at all, rather than sent empty.

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

### What changed since this plan was first written

The follow cam shipped 2026-07-29 (was ROADMAP #3, now closed). That was the
*acting* fix for finding 3's underlying problem: after a create, write or
delete, `Seshat.Tools.FollowCam` already selects what the tool touched and
shows the pane it lives in ([lib/seshat/tools/follow_cam.ex](../lib/seshat/tools/follow_cam.ex)).
Two consequences for this issue:

- The manual-steps register now covers a genuinely narrower case — only what
  the tools can't reach at all, not "the user can't see what I just made."
- The text needs a rule it didn't have: **the view already follows.** Left
  unsaid, the model will keep offering navigation directions to something
  that is already on screen, and the instructions will talk over the follow
  cam instead of complementing it. Carried into the Phase 2 agenda.

Cross-references also renumbered as things shipped: catalog staleness is now
ROADMAP #5, `screenshot_live` #9, LLM enrichment #15.

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
- **Phase 1 sends nothing.** `text/0` returns `nil`, so the field is omitted
  and the handshake is byte-for-byte what it is today. Phase 1 is verifiable
  as *plumbing* (parity, composition, no crash on nil) but produces no
  behavioral change by design.
- ⚠️ The MCP spec says clients **MAY** add instructions to the system prompt —
  delivery to the model is client behavior we can't force (Open question 1).

---

# Phase 1 — everything but the prompt

One PR. No prose, no wording decisions, no behavioral change. The deliverable
is a channel that provably carries whatever Phase 2 puts in it.

## 1.1 `Seshat.Instructions` — the shared source

New file `lib/seshat/instructions.ex`. Top-level module (not under `Tools` or
`MCP`) because both entry points read it — same reasoning that puts
`Seshat.Tools.Handlers` at the funnel point of both modes.

```elixir
# TODO - phase 2
# Session-level guidance sent to the model at connect time, shared by both
# entry points. Covers what no single tool description can: what "start a new
# project" implies, how to talk a user through a manual step, what not to
# relay from tool replies, and the voice to do it all in. See the Phase 2
# agenda in docs/PLAN_mcp_server_instructions.md for the intended rules.
@text nil

@spec text() :: String.t() | nil
def text, do: @text
```

`nil`, not `""`: Anubis skips the field on nil, so Phase 1 changes nothing on
the wire. An empty string would be *sent*, advertising an empty instructions
field to every client.

Moduledoc states the governing rules so future edits keep them — short,
nothing machine-specific, session-level only (per-tool guidance belongs in
`Seshat.Tools.Definitions`, view steering in `Seshat.Tools.FollowCam`), both
`Seshat.MCP.Server` and `Seshat.Agent` consume it — and says plainly that
**this file is edited as prose and no test asserts on its wording**, so a
future reader knows a rewrite is a one-file change.

## 1.2 `Seshat.MCP.Server` — send it

[lib/seshat/mcp/server.ex](../lib/seshat/mcp/server.ex): add

```elixir
@impl Anubis.Server
def server_instructions, do: Seshat.Instructions.text()
```

A module-defined callback wins over the `use`-option default (Anubis checks
`Module.defines?/2` before injecting its own), so no change to the `use`
options. No TODO marker here — this file holds no prompt, and never will;
it resolves the text at runtime. Moduledoc gains a line saying session-level
guidance is sent as server instructions from `Seshat.Instructions`.

## 1.3 `Seshat.Agent` — same source, no diverging copy

[lib/seshat/agent.ex](../lib/seshat/agent.ex): rename the `@system_prompt`
attribute to `@agent_specific` with its **content unchanged**, and compose:

```elixir
@spec system_prompt() :: String.t()
def system_prompt do
  [Seshat.Instructions.text(), @agent_specific]
  |> Enum.reject(&is_nil/1)
  |> Enum.join("\n\n")
end
```

`call_api/3` sends `system: system_prompt()` instead of `@system_prompt`. The
`reject(&is_nil/1)` is not scaffolding — it is the composition point, correct
in both phases, and it means Phase 2 changes no code here at all.

**Phase 1 deletes nothing** (Patrick, 2026-07-29). The rename is
attribute-only — not one word of the existing prompt changes, and API-key mode
behaves in Phase 1 exactly as it does today. Everything this issue does to
prompting is additive: a session-level block that doesn't exist at all right
now, delivered to a mode that currently receives no guidance whatsoever.

The marker above `@agent_specific` records the one thing Phase 2 may want to
revisit:

```elixir
# TODO - phase 2
# API-key-mode-only prompt: the MIDI crash course and note-editing loop exist
# because this mode runs a small model (claude-haiku-4-5); MCP mode's client
# needs none of it. Three rules here are general rather than API-mode-specific
# — refer to tracks by name or 1-based UI number; read get_session_state
# before relative changes; resolve track names through get_session_state — so
# if the phase 2 text comes to state them, this prompt will say them twice.
# Deduplicating is optional; see the plan for the trade-off.
```

## 1.4 `search_library` marks its diagnostics as model-internal

The one Phase 1 item that ships real prose — and it still gets the marker, so
Phase 2 reviews its wording alongside everything else.

Guidance alone didn't stop the leak reaching the user, so the reply also marks
itself. In [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex),
`format_catalog_entries/3` ([handlers.ex:168-194](../lib/seshat/tools/handlers.ex#L168-L194))
gains a module attribute appended to the two branches that emit steering text:

```elixir
# TODO - phase 2
# Marks search steering text as model-internal, at the point of use. Stops
# catalog plumbing ("No 'Warm' tag exists in your library") being relayed to a
# musician who never asked about tags. Wording ships in phase 1 because it is
# self-contained and the fix is needed either way; revisit it in phase 2 for
# consistency with the session instructions' voice.
@diagnostics_internal "(Diagnostics are for refining your search — present " <>
                        "results musically; don't mention tags to the user.)"
```

- Zero-result branch (diagnosis, via `format_diagnosis/1`): appended after the
  diagnosis notes.
- Truncated-with-facets branch: appended after the "top tags among them…"
  header.

The exact-match and no-facets branches stay untouched — they contain nothing
to leak. The `search_library` tool description in `Definitions` is *not*
changed: the marker travels with the text it governs, which reaches the model
at exactly the moment it matters, in both modes.

## 1.5 Tests — all text-agnostic

The constraint that makes the phase split work: **no test asserts on the
content of the instructions**, and every one of these passes in both phases
without edits.

- New `test/seshat/instructions_test.exs`: `text/0` returns `nil` or a binary
  under 3,000 characters. Weak in Phase 1 by construction; in Phase 2 it
  becomes the "keep it short" tripwire, so the intention survives as a failing
  test rather than a forgotten note. The bound catches a runaway, not a
  rewrite.
- New `test/seshat/mcp/server_test.exs`:
  `Seshat.MCP.Server.server_instructions() == Seshat.Instructions.text()` —
  the parity guard, same spirit as the existing MCP⟷Definitions parity tests
  in [test/seshat/mcp/tools_test.exs](../test/seshat/mcp/tools_test.exs). Real
  value in Phase 1: it holds at `nil` and keeps holding when text appears.
- Unit test on `Seshat.Agent.system_prompt/0`: contains the `@agent_specific`
  material, and contains `Seshat.Instructions.text()` whenever that is
  non-nil. Covers the nil branch now and the composed branch later.
- [test/seshat/agent_test.exs](../test/seshat/agent_test.exs): in a `Req.Test`
  intercept, assert the request body's `system` field equals
  `Seshat.Agent.system_prompt()` — the guard against `call_api/3` drifting
  back to a stale attribute, which is the actual regression risk here.
- [test/seshat/tools/handlers_test.exs](../test/seshat/tools/handlers_test.exs):
  `format_catalog_entries/3` cases — zero-result-with-diagnosis and
  truncated-with-facets replies contain the internal marker; full-result
  replies don't.

No tool added or removed → no `definitions_test.exs` count bump.

## 1.6 Docs

- [CLAUDE.md](../CLAUDE.md): add `lib/seshat/instructions.ex` to the module
  map; one line in the "Two entry points" section noting both modes share
  `Seshat.Instructions`.
- [docs/TOOL_AUDIT.md](TOOL_AUDIT.md): note on the `search_library` inventory
  row that the diagnostic-leak wart is fixed (reply now marks diagnostics as
  internal).

## 1.7 Optional local canary — de-risk Open question 1 early

Not a shipped step and not committed. Because Phase 1 sends `nil`, the "does
the client actually hand instructions to the model?" question can't be
answered by anything Phase 1 ships — but it *gates whether Phase 2's prose is
worth writing*, so it is worth five minutes before starting Phase 2:

1. Temporarily set `@text` to one distinctive sentence that exists nowhere
   else in the repo.
2. Restart the server, reconnect Claude Code, ask Seshat to repeat it.
3. Revert.

Quoting it back is proof of delivery to the model. If it fails, the
shared-source structure still stands and Phase 2 still improves API-key mode,
but the delivery channel needs rethinking before the text is worth polishing
(see Out of scope on fallback channels).

---

# Phase 2 — dial in the prompts

`grep -rn "TODO - phase 2" lib/` is the agenda. Three sites, one of which is
the actual work:

1. **Write the text** (1.1) — the session below.
2. **Decide whether to deduplicate `@agent_specific`** (1.3) — optional, and
   only if the new text actually states those three rules. Leaving the
   duplication costs ~50 tokens per API-mode request and nothing else; the
   real argument for removing it is drift, since two copies of a rule can
   later disagree and only the shared one is authoritative. Either way this is
   a judgment made *with the finished text in hand*, which is the whole reason
   it isn't a Phase 1 decision.
3. **Consistency pass on the `search_library` marker** (1.4) — already
   working; only its voice is in question.

Closes with a `refute Seshat.Instructions.text() =~ "TODO"` guard and the
removal of the markers.

## Starting draft

Not shipped in Phase 1 — this is the session's starting point, and Phase 2 is
free to rewrite it wholesale.

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
- The view follows you: creating, writing to, or deleting something already
  selects it in Live and opens the pane it lives in. Say what to look at
  ("the notes are in the editor at the bottom"), don't give directions to it.
- Manual steps, when unavoidable: give the shortest complete path. Locate
  every key physically ("press the Tab key, above Caps Lock"), confirm every
  step by what appears on screen ("you should now see a grid of colored
  cells"). No concept explanations, no alternatives up front — keep fallbacks
  for when a step didn't work.
```

~1,900 characters. Each bullet traces to a validation finding, a roadmap note,
or a shipped feature; nothing is machine-specific, and nothing duplicates what
a tool description already says (the 0-based index rule, value ranges, and
per-tool preconditions stay in descriptions where they belong).

## Open decisions for the session

Deferred from 2026-07-29 rather than answered — these are wording calls, and
they are exactly what Phase 2 is for.

1. **Voice.** The draft is almost entirely guardrails. The run's strongest
   *positive* finding was about register — the "my gut for an 86 BPM lo-fi
   track: E-Piano Moody for instant vibe, or Detuned if you want the
   out-of-tune quality front and center… I can also stack a touch of chorus"
   reply, flagged as the target behavior and the shape to keep. The draft
   encodes that as one thin bullet. Options: add a short voice section (have
   an opinion and say why musically, name the trade-off, offer the next
   production move), leave voice emergent, or restructure the whole text
   around character with the guardrails as consequences.
   *Direction chosen 2026-07-29: voice becomes pluggable — producer personas,
   ROADMAP #4, stubs in [priv/producers/](../priv/producers/). The base text
   here stays guardrails-only; Phase 2 should write it knowing a persona will
   compose on top rather than folding a voice section in.*
2. **Ask before loading, always?** The draft's default costs a turn on every
   sound choice, including "just load me a warm pad." Alternative: slate by
   default, act on directive phrasing and name the runners-up — cheaper to
   undo now that `delete_device` ships.
3. **New project.** Delete leftover empty defaults as part of the request, or
   always offer? The draft hedges with "— or offer to," which is the one line
   in it that decides nothing.
4. **Length.** ~1,900 characters against a 3,000 tripwire. A voice section
   pushes toward 2,500. Confirm the budget is real before writing to it.

## Behavior smoke-test (Phase 2, not Phase 1)

Additions to `/smoke-test`, each mapping to a validation finding. Phase 1 has
nothing to smoke-test — it sends `nil` by design.

1. "Let's start a new project — give me two MIDI tracks" against a default
   set → leftover empty track deleted or its removal offered, per decision 3.
2. A search with a vocabulary miss ("warm electric piano") → reply presents
   musical choices, no tag talk.
3. A request outside the tools ("switch audio output to my headphones") →
   names where the setting lives in Live, no improvised workaround.
4. A "why can't I see X?" UI question → keystroke-located, screen-confirmed
   steps in the precise-brevity register.
5. After a `write_midi_notes`, ask "where is it?" → answer describes what is
   already on screen rather than giving navigation directions (the follow-cam
   rule).

---

## Out of scope

- **The other model-facing prose in the codebase.** `@system_prompt` in
  `Seshat.Agent` is the only *system prompt* in `lib/`, but it is not the only
  text the model reads. Two bodies stay untouched, deliberately:
  - **Tool and parameter descriptions** — 145 `description:` fields in
    [lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex).
    These are prompts, and most of Seshat's model-facing words live here.
    They are governed already (house style, [TOOL_AUDIT.md](TOOL_AUDIT.md) §04
    as the exemplar) and revising them is a standing audit job, not this
    issue's. The instructions exist for what *no* tool description can say;
    anything a single tool can state belongs in its description and stays
    there.
  - **Handler reply text** — every `{:ok, …}` / `{:error, …}` string in
    [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex) steers the
    model's next move. Phase 1 touches exactly one (1.4's diagnostics marker,
    because it is the specific leak a validation finding named) and leaves the
    rest.

  If Phase 2 should widen to either, that is a scope decision to take
  knowingly — it turns a one-file prose session into a sweep over 145
  descriptions plus every reply string, which is closer to a
  `/plan`-sized issue of its own than a phase of this one.
- **Follow cam / view steering** — shipped 2026-07-29. This issue only adds
  the instruction that tells the model the steering happened.
- **New-project kickoff flow as tooling** (a brief that persists, kickoff
  questions steering search) — the instructions carry its practical core
  ("invite a one-line brief"); anything stateful stays a roadmap discussion.
- **Catalog staleness surfacing** — ROADMAP #5, even though it may one day
  want a line here.
- **`AssistantLive` UI changes** — the browser UI already gets the shared text
  through `Seshat.Agent`; nothing to show the user.
- **A fallback delivery channel** (MCP resource, preamble in a tool
  description) if some client ignores `instructions` — not designed until 1.7
  actually shows a client we care about ignoring them.

## Open questions

1. **⚠️ Does the client deliver instructions to the model?** The MCP spec
   makes it a MAY; Anubis sends the field, but whether Claude Code / Claude
   Desktop inject it into context can only be verified with a live session.
   Phase 1 can't answer it — it sends `nil` — so 1.7's throwaway canary is the
   cheap way to settle it before Phase 2 spends effort on wording.
2. **Is the text Patrick's?** It is a personality contract as much as a
   mechanism, and only its author can sign off wording. Resolved by
   construction: Phase 2 *is* that session, and the four open decisions above
   are its agenda.
