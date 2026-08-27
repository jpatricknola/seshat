# Adding a Tool

Tools are defined once and surfaced over MCP automatically. Tool definitions
are the single model-facing contract; there is no separate command schema to
keep in sync.

## Before minting a name

The backend capability inventory is deliberately much larger than the tool
surface. A new AbletonOSC address, AX helper command, LOM member or generation
provider operation does **not** imply a new model-facing tool.

Apply this routing test first:

1. Same verb, different destination → add a `target` value to the existing
   tool.
2. Same noun, another cohesive property → add an optional property to the
   existing tool.
3. One action as the producer experiences it, even when it takes several
   primitives → one high-level tool whose domain operation composes them.
4. Knowledge needed only while another action runs → put it in that action's
   reply, or in `Session.State` when it is listened to and read frequently.
5. Mint a name only when the model must choose a genuinely different verb,
   noun, or workflow.

Completing `priv/AbletonOSC/FORK_GAPS.md` is bridge work, not a publication
queue. Close gaps freely; publish them through the smallest existing intention
that fits. Provider names, OSC addresses, AX command names and pipeline stages
stay below the tool contract unless the producer genuinely chooses among them.

Consolidation has a cohesion limit. A property bag or action enum stays one
tool only while its values share the same noun/workflow, targeting shape,
safety and verification semantics. Split when those differ. Never create a
generic AX remote or a miscellaneous action enum merely to keep the count down.

**80 tools is the review line.** The test suite stops an unreviewed 81st tool.
Any plan that adds a name records why none of the shapes above fit, plus the
before/after tool count, serialized `tools/list` bytes, largest schema, new
near-neighbour names, conditional validation cases, and a representative
fresh-conversation selection check. Past roughly 90 tools, measure client
support for modal tool sets before adopting them. The standing reasoning is in
[tool-surface-scaling.md](../../docs/evaluating/tool-surface-scaling.md).

## The four steps

### 1. Define it — `lib/seshat/tools/definitions.ex`

Append a map to `@tools`:

```elixir
%{
  name: "set_track_send",
  description:
    "Set a send level on a track. Track indices are 0-based. " <>
      "Send 0 = send A, 1 = send B. Value is 0.0–1.0. " <>
      "Use get_session_state to resolve track names to indices.",
  parameters: %{
    type: "object",
    properties: %{
      "track" => %{type: "integer", minimum: 0, description: "0-indexed track number"},
      "send" => %{type: "integer", minimum: 0, description: "0-indexed send. Send A = 0."},
      "value" => %{type: "number", minimum: 0.0, maximum: 1.0, description: "Send level"}
    },
    required: ["track", "send", "value"]
  }
}
```

The description is the entire prompt the model gets for this tool. Spell out
index bases, value ranges, and which tool to call first. Terse descriptions are
the most common cause of wrong tool calls.

Supported JSON Schema in `parameters`: `type` (`string`/`integer`/`number`/
`boolean`/`array`/`object`), `description`, `enum`, `minimum`/`maximum`,
`items`, nested `properties` + `required`. Anything else is ignored by the MCP
schema converter.

Every index parameter must declare `minimum: 0` — a negative index reaching
AbletonOSC's Python selects from the *end* of Live's collection, so `track: -1`
would delete the last track and echo "track -1" as if that were the target
(`definitions_test.exs` enforces this, and that every integer property declares
an `enum` or a `minimum`). Declared bounds are enforced centrally by
`Seshat.Tools.Validation` before `call/2` dispatches, so a handler clause never
needs its own numeric range or type check — write the bound into the schema
instead, where the model can also see it.

### 2. Handle it — `lib/seshat/tools/handlers.ex`

Add a `do_call/2` clause. Params are always string-keyed here — `call/2`
normalises MCP's atom keys before dispatch.

```elixir
defp do_call("set_track_send", %{"track" => track, "send" => send, "value" => value}) do
  case Transport.send_message("/live/track/set/send", [track, send, value / 1.0]) do
    :ok -> {:ok, "OK — set send #{send} on track #{track} to #{value}"}
    {:error, reason} -> {:error, inspect(reason)}
  end
end
```

Put the clause **above** the catch-all `do_call(name, _params)` at the bottom.

Return `{:ok, message}` or `{:error, reason}`. The message goes straight back to
the model, so make it state what actually happened — the model uses it to
decide whether to keep going.

For a short, ordered OSC mutation sequence representable as a `%Command{}`, add
a clause to `Seshat.Commands.Registry` and call `execute/1`. Registry owns
bounded wire sequences such as create-then-name a track or
ensure-clip-then-add-notes; it is not a generic workflow engine.

Keep `Handlers` as the sole dispatcher, not the home of every future domain
implementation. A literal single-message call can stay in its clause. Extract a
focused module when the operation has independently testable arithmetic,
substantial cross-field validation, several backend steps, provider adapters,
or a lifecycle of its own. Those domain modules may compose Registry commands,
OSC reads, AX commands and provider adapters; the handler should validate/
dispatch and format the outcome. Generation backends and AX/OSC mechanics stay
behind that seam.

When a consolidated schema has conditional rules that supported JSON Schema
cannot express, preflight them before any transport call. Collect all missing,
conflicting and target-unsupported fields, reject the whole call, and name the
accepted alternatives. If a third tool needs the same kind of support matrix,
extract a shared convention rather than growing another bespoke validator.

Every tool registered in `Definitions` is automatically wrapped in its own
Ableton undo step — `Handlers.call/2` sends `begin_undo_step`/`end_undo_step`
around every known-tool dispatch (see `.claude/rules/osc.md`), so there is
nothing to opt into here. One consequence worth knowing: the wrap holds a
node-wide `:global.trans` lock for the handler's full duration, so a
long-running tool (a slow `load_device`, a `reindex_library` export) blocks
every other tool call, not just concurrent undo steps, until it returns.

There is one opt-out, and it is narrower than it looks. A definition carrying
`undo_step: false` dispatches with no lock and no begin/end datagrams:

```elixir
%{
  name: "get_audio_outputs",
  undo_step: false,
  description: "...",
  parameters: %{type: "object", properties: %{}, required: []}
}
```

**It is for a tool whose mechanism cannot contribute to Live's undo history at
all** — today, only the two Accessibility-backed audio-output tools, which
change an Ableton *preference* through macOS UI rather than editing the Live
Set. It is not for a read-only OSC tool: those stay wrapped deliberately,
because an empty begin/end pair is measured free while a hand-maintained list of
mutating tools fails silently the first time a new tool forgets to join it.

If you reach for it, the tool almost certainly also needs a sentence in its
description telling the model the change is outside Live's undo history and how
to reverse it — `undo` will not. `definitions_test` pins the opted-out set by
name, so adding one is a deliberate, reviewed edit rather than a quiet flag.

### 3. Update the count — `test/seshat/tools/definitions_test.exs`

The `assert length(tools) == N` there is a deliberate tripwire. Bump it.

**That assertion is the only place the tool count is written down**, and it stays
that way — no prose anywhere restates it (the README and `CLAUDE.md` both
deliberately describe the surface without a number, because a count copied into
a sentence goes stale silently and nothing fails).

Keep the separate `length(tools) <= 80` review-line assertion. The exact count
changes normally; the ceiling must fail independently so an implementer cannot
cross it by mechanically bumping the expected count.

### 4. Verify

```
mix precommit
```

`Seshat.MCP.ToolsTest` will confirm the tool appears on the MCP server with a
matching schema. If the name doesn't round-trip through `Macro.camelize/1` →
`Macro.underscore/1`, that test fails — stick to `lower_snake_case` names.

For any surface change, also run the real-handshake surface-stat check in
`docs/smoke_tests/auto/mcp-surface.md`. Record the advertised count and compact
JSON byte size, inspect the largest schema, and run the fresh-conversation
selection check named by the feature's plan. Count is only a proxy: fewer tools
that route worse is a regression.

## What you do NOT do

- **Don't write an MCP component.** `Seshat.MCP.Tools` generates one per
  definition at compile time. `lib/seshat/mcp/tools/` no longer exists.
- **Don't touch `Seshat.MCP.Server`.** It registers whatever `Definitions` has.
- **Don't add a JSON shape to server instructions.** Tool schemas and
  descriptions are the model-facing contract.

## If the tool needs new session state

`Seshat.Session.State` mirrors Ableton so tools don't have to round-trip. To
track a new property:

1. Add it to `@listened_properties`
2. Add a `handle_info` clause for the property push
3. Add it to the initial query in `do_refresh/1`
4. Surface it in `get_session_state`'s output so the model can actually see it

Only do this for properties read often. One-off reads should query in the
handler.

## Adding guidance the model needs

Two places, and the choice is not a matter of taste:

1. **The tool description** — anything that matters when using *this* tool:
   chord intervals, drum-map pitches, warp modes, index bases, which tool to
   call first, how to present the result. This is the default, and it is the
   only one with no length limit (58,709 bytes of schemas ship in every
   request — 52 tools, largest `set_clip_properties` at 3,585 bytes, measured
   2026-08-28 client-side with `mcp_call.py stats` over a real `tools/list`
   handshake; the Elixir-side estimate was 57,450, so add ~2% when guessing
   from `Definitions`).
2. **`Seshat.Instructions`** — only what belongs to *no* tool: register, what
   to do when a request is outside the tools entirely, the fact that the view
   has already moved. Hard-capped at 2,048 characters, because Claude Desktop
   truncates past that silently — so a rule that could live in a description
   is free there and scarce here.

Nothing in `mix test` checks what any of this makes the model *say* —
[docs/smoke_tests/manual/conversation.md](../../docs/smoke_tests/manual/conversation.md)
has the behavioural checks, one per rule.
