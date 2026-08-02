---
name: add-tool
description: Add a new Ableton control tool end to end
argument-hint: [what the tool should do, e.g. "set a send level on a track"]
allowed-tools: Read, Edit, Write, Bash(mix:*), Bash(grep:*), Bash(rg:*)
---

Add a new tool to Seshat: **$ARGUMENTS**

Follow [.claude/docs/adding-a-tool.md](.claude/docs/adding-a-tool.md). Work in
this order and do not skip the verification step.

1. **Find the OSC address** in [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md).
   Do not guess or infer it from a similar address — AbletonOSC's naming is
   irregular and a wrong address fails silently.

   If the capability isn't in that file, **we own the bridge and can add it** —
   `priv/AbletonOSC` is our fork, not a read-only dependency. That is a bigger
   job than a tool (Python, a reinstall, a Live restart, a smoke test the pure
   suite can't reach), so say what the address would need to be and let the user
   decide whether to take it on before you start writing Python. The workflow,
   once they say yes, is in [.claude/rules/osc.md](.claude/rules/osc.md).
   Inventing an Elixir-side address for a handler that doesn't exist is still
   the one thing never to do: it fails silently, forever.

2. **Add the definition** to `@tools` in
   [lib/seshat/tools/definitions.ex](lib/seshat/tools/definitions.ex). Write the
   description as prompt text for a model that can't see the code: state the
   index base, the value range, and which tool to call first to resolve names.
   Match the style of the neighbouring definitions.

3. **Add the handler** — a `do_call/2` clause in
   [lib/seshat/tools/handlers.ex](lib/seshat/tools/handlers.ex), above the
   catch-all at the bottom. Params are string-keyed. If the operation needs
   more than one OSC message or any sequencing, add a `%Command{}` clause to
   [lib/seshat/commands/registry.ex](lib/seshat/commands/registry.ex) instead
   and call `execute/1`.

4. **Bump the tool count** in
   [test/seshat/tools/definitions_test.exs](test/seshat/tools/definitions_test.exs).

5. **Verify** with `mix precommit`. `Seshat.MCP.ToolsTest` confirms the tool
   reached the MCP server with a matching schema.

Do **not** create a module under `lib/seshat/mcp/` — MCP components are
generated from the definitions at compile time.

Report which OSC address you used and what you'd need Ableton running to
actually confirm. Then run `/smoke-write` — a new tool always needs live
checks written, since nothing in `mix test` reaches past the pure layer, and a
send-only setter fails silently — and suggest `/smoke-test` to run them with
Ableton open.
