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

`assert length(tools) == 34` is a deliberate tripwire. Bump it.

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

## Adding music-theory knowledge

If the model needs to know something to *use* a tool correctly (chord
intervals, drum-map pitches, warp modes), it goes in `@system_prompt` in
`Seshat.Agent` — but note this only affects API-key mode. In MCP mode the
client's own model does the reasoning with no system prompt from us, so
anything essential must be in the **tool description** instead.
