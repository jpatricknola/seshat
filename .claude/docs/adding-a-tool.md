# Adding a Tool

Tools are defined once and surfaced to both entry points automatically. This
doc replaces the old "system prompt contract" — there is no longer a JSON
command schema in a system prompt to keep in sync.

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
      "track" => %{type: "integer", description: "0-indexed track number"},
      "send" => %{type: "integer", description: "0-indexed send. Send A = 0."},
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
`items`, nested `properties` + `required`. Anything else is passed to Anthropic
but ignored by the MCP schema converter.

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

For anything multi-step or stateful, add a `%Command{}` clause to
`Seshat.Commands.Registry` instead and call `execute/1`. Registry is where
sequences live (create-then-name a track, ensure-clip-then-add-notes).

### 3. Update the count — `test/seshat/tools/definitions_test.exs`

The `assert length(tools) == N` there is a deliberate tripwire. Bump it.

**That assertion is the only place the tool count is written down**, and it stays
that way — no prose anywhere restates it (the README, `CLAUDE.md` and
`TOOL_AUDIT.md` all deliberately describe the surface without a number, because a
count copied into a sentence goes stale silently and nothing fails). Add the tool
to `TOOL_AUDIT.md`'s inventory table with a verdict; don't add a count beside it.

### 4. Verify

```
mix precommit
```

`Seshat.MCP.ToolsTest` will confirm the tool appears on the MCP server with a
matching schema. If the name doesn't round-trip through `Macro.camelize/1` →
`Macro.underscore/1`, that test fails — stick to `lower_snake_case` names.

## What you do NOT do

- **Don't write an MCP component.** `Seshat.MCP.Tools` generates one per
  definition at compile time. `lib/seshat/mcp/tools/` no longer exists.
- **Don't touch `Seshat.MCP.Server`.** It registers whatever `Definitions` has.
- **Don't add a JSON shape to a system prompt.** The old `Commands.Parser`
  approach is gone. `Seshat.Agent`'s system prompt carries only cross-cutting
  guidance (note names, beat math, index bases), not per-tool schemas.

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

Three places, and the choice is not a matter of taste:

1. **The tool description** — anything that matters when using *this* tool:
   chord intervals, drum-map pitches, warp modes, index bases, which tool to
   call first, how to present the result. This is the default, and it is the
   only one of the three with no length limit (~36KB of schemas ships every
   request).
2. **`Seshat.Instructions`** — only what belongs to *no* tool: register, what
   to do when a request is outside the tools entirely, the fact that the view
   has already moved. Hard-capped at 2,048 characters, because Claude Desktop
   truncates past that silently — so a rule that could live in a description
   is free there and scarce here. Reaches both modes.
3. **`@agent_specific` in `Seshat.Agent`** — API-key mode only, for what that
   loop needs and MCP mode gets from its own client (its own identity, its own
   turn budget). Nothing user-facing belongs here alone; it would be invisible
   in the primary mode.

Nothing in `mix test` checks what any of this makes the model *say* — the
`/smoke-test` skill has the behavioural checks, one per rule.
