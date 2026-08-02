# The advertised MCP surface

`mix test` asserts the generated `input_schema` inside the BEAM. It cannot tell
you whether a real client accepts what that encodes to, and the failure mode is
not one bad call: **a client that rejects the schema refuses the whole list**, so
every tool silently disappears and the session looks like Seshat was never
connected.

`scripts/mcp_call.py` in the smoke-test skill drives all of this over a real
handshake against `http://localhost:4000/mcp`.

## The tool list survives a real handshake

*Run mode: agent*
*Last run: 2026-08-02 — 65 tools, matching `Definitions.all()`*

`python3 .claude/skills/smoke-test/scripts/mcp_call.py list`. The count must
match `Definitions.all()`.

Do not read this conversation's tool list instead: a client caches `tools/list`
at connect, so after a server restart the cached list is the *old* schema and
proves nothing. This is also how you tell "the server is wrong" from "my client
is stale".

## A changed property carries what you intended

*Run mode: agent*
*Last run: 2026-08-02 — `set_track_pan.value` carries `minimum`/`maximum`*

`mcp_call.py schema <tool> <property>` for whatever moved. Recorded 2026-07-30,
when bounds moved into the advertised schema: the encoded shape became
`oneOf: [{"type": "number", "minimum": …, "maximum": …}, {"type": "integer", …}]`.
Bounds *inside* `oneOf` branches were the untested combination.

## A rejected call comes back readable, not as a protocol error

*Run mode: agent*
*Last run: —*

`mcp_call.py call set_track_pan '{"track": 0, "value": 2.0}'` must return a
`result` with `"isError": true` whose text names the bound and the value
(`must be at most 1.0 (got 2.0)`), with no Peri internals (`{:float,`) in it. An
`error` key with `-32602` means `Seshat.MCP.Server`'s `handle_request/2`
interception is gone.

The defect this guards was *found* by a real client swallowing the useful text:
Claude Code shows a JSON-RPC `-32602` as nothing but `MCP error -32602: Invalid
params`, `data.message` and all. So the check of record is client-shaped — what
comes back over a real handshake, not what the BEAM returns. Worth doing in
Claude Code itself once, too: a bad call should read as a retryable message in
the transcript, not as an opaque protocol error.

## An unknown tool name stays a JSON-RPC `-32602`

*Run mode: agent*
*Last run: 2026-08-02 — `-32602`, `Tool not found: no_such_tool`*

`mcp_call.py call no_such_tool '{}'`. That is what the MCP spec says an unknown
tool is, and it is the discriminator keeping the rewrite from swallowing real
protocol errors.

## The rejected value never reached Live

*Run mode: agent*
*Last run: —*

After the rejection above, read the target back. A refusal that silently *did*
send is the thing worth catching, and no reply string can show it to you.

## Claude Desktop lists the tools at all

*Run mode: user — requires a fresh Claude Desktop conversation*
*Last run: —*

In a fresh conversation. It is the client nothing else here exercises and the one
with a history of failing quietly; a schema it dislikes shows up as an empty tool
list, not an error message.
