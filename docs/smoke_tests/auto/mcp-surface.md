# The advertised MCP surface

`mix test` asserts the generated `input_schema` inside the BEAM. It cannot tell
you whether a real client accepts what that encodes to, and the failure mode is
not one bad call: **a client that rejects the schema refuses the whole list**, so
every tool silently disappears and the session looks like Seshat was never
connected.

`scripts/mcp_call.py` in the smoke-test skill drives all of this over a real
handshake against `http://localhost:4000/mcp`.

## The tool list survives a real handshake

*Last run: 2026-08-02 — 65 tools, matching `Definitions.all()`*

`python3 .claude/skills/smoke-test/scripts/mcp_call.py list`. The count must
match `Definitions.all()`.

Do not read this conversation's tool list instead: a client caches `tools/list`
at connect, so after a server restart the cached list is the *old* schema and
proves nothing. This is also how you tell "the server is wrong" from "my client
is stale".

## The surface budget is measured, not guessed

*Last run: —*

`python3 .claude/skills/smoke-test/scripts/mcp_call.py stats` against a freshly
restarted server. Record all four values here: advertised tool count, compact
JSON bytes for the complete `tools/list` array, largest individual tool, and
that tool's compact JSON bytes.

The consolidation plans from a 67-tool / 62,784-byte baseline to 52 tools. Use
the byte comparison only if `stats` reproduces the old baseline when run on the
pre-consolidation definitions; otherwise state that the encoding method changed
and establish this output as the new baseline. The count must match
`Definitions.all()`, total bytes must fall, and the largest tool must still be a
cohesive noun/workflow rather than a miscellaneous bag assembled to save names.

A smaller count with larger total bytes is not automatically a failure, but it
must be explained by removed repetition or better routing text. A largest tool
whose fields have unrelated targeting, safety or verification semantics is a
design failure even when the total shrank — split it by workflow before calling
the consolidation successful.

## A changed property carries what you intended

*Last run: 2026-08-02 — `set_track_pan.value` carries `minimum`/`maximum`*

`mcp_call.py schema <tool> <property>` for whatever moved. Recorded 2026-07-30,
when bounds moved into the advertised schema: the encoded shape became
`oneOf: [{"type": "number", "minimum": …, "maximum": …}, {"type": "integer", …}]`.
Bounds *inside* `oneOf` branches were the untested combination.

## A rejected call comes back readable, not as a protocol error

*Last run: 2026-08-03 — passed. Came back as `result` with `"isError": true` and
the text "Invalid parameters for set_track_pan — nothing was sent to Ableton:\n-
value: must be at most 1.0 (got 2.0) — Pan position. -1.0 = full left, 0.0 =
center, 1.0 = full right". No `error` key, no `-32602`, no Peri internals.*

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

*Last run: 2026-08-02 — `-32602`, `Tool not found: no_such_tool`*

`mcp_call.py call no_such_tool '{}'`. That is what the MCP spec says an unknown
tool is, and it is the discriminator keeping the rewrite from swallowing real
protocol errors.

## The rejected value never reached Live

*Last run: 2026-08-03 — passed. Track 0's pan read 0.0 before the rejected
`value: 2.0` call and still read 0.0 afterwards via
`get_session_state(refresh: true)` — a fresh read from Live, not the mirror. Had
the write gone out, Live would have clamped it to 1.0.*

After the rejection above, read the target back. A refusal that silently *did*
send is the thing worth catching, and no reply string can show it to you.


## A mutating tool with nothing required survives the client

*Last run: —*

`set_mixer` is the first *mutating* tool whose schema has `required: []` and
an optional `target` enum — everything on it is optional because the handler
decides what a target needs. The list-level risk is the one at the top of this
file.

`mcp_call.py schema set_mixer target` shows the enum
`["track", "return", "master", "cue"]` and `set_mixer` absent from `required`;
`schema set_mixer volume` carries `minimum` 0 and `maximum` 1. Then
`call set_mixer '{"track": 0, "pan": -1.0}'` reaches Ableton (pan reads back
`50L`), `call set_mixer '{"track": 0}'` returns a *tool result* saying no
property was given, and `call set_mixer '{"track": 0, "gain": 0.5}'` returns a
tool result that names the six properties `set_mixer` does take (the
Elixir-side validator ignores keys the schema doesn't name, so this lands as
"no property given") — never a JSON-RPC `-32602` for either. If Peri rejects
the unknown key on the wire instead, `Seshat.MCP.Server`'s `-32602` rewrite
still turns it into a tool result; record which path answered.

A `-32602` here is Peri rejecting before `Validation`'s wording can be
delivered; the tool list itself disappearing is the schema being refused
wholesale.
