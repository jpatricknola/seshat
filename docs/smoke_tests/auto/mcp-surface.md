# The advertised MCP surface

`mix test` asserts the generated `input_schema` inside the BEAM. It cannot tell
you whether a real client accepts what that encodes to, and the failure mode is
not one bad call: **a client that rejects the schema refuses the whole list**, so
every tool silently disappears and the session looks like Seshat was never
connected.

`scripts/mcp_call.py` in the smoke-test skill drives all of this over a real
handshake against `http://localhost:4000/mcp`.

## The tool list survives a real handshake

*Last run: 2026-08-28 — 52 tools listed over a real handshake with every published object (root and nested) carrying `additionalProperties: false`; matches `Definitions.all()`.*

`python3 .claude/skills/smoke-test/scripts/mcp_call.py list`. The count must
match `Definitions.all()`.

Do not read this conversation's tool list instead: a client caches `tools/list`
at connect, so after a server restart the cached list is the *old* schema and
proves nothing. This is also how you tell "the server is wrong" from "my client
is stale".

## The surface budget is measured, not guessed

*Last run: 2026-08-28 (closed schemas) — **52 tools / 60,246 bytes / largest `set_clip_properties` at 3,614 bytes**. Up 1,537 bytes from the same day's 58,709 / 3,585 open-schema baseline: 55 `"additionalProperties":false` members (one per published object, nested ones included), ~28 bytes each, no text change. Total is still below the 62,784-byte 67-tool baseline.*

`python3 .claude/skills/smoke-test/scripts/mcp_call.py stats` against a freshly
restarted server. Record all four values here: advertised tool count, compact
JSON bytes for the complete `tools/list` array, largest individual tool, and
that tool's compact JSON bytes.

The consolidation planned from a 67-tool / 62,784-byte baseline to 52 tools.
For reference, encoding the MCP-converted schemas Elixir-side on 2026-08-28 gave
52 tools / 57,450 bytes, largest `set_clip_properties` at 3,555 — the
client-visible number from `stats` the same day was 58,709 / 3,585, about 2%
more, and is the one to quote. Use
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

*Last run: 2026-08-28 — `schema set_mixer pan` came back as a plain `{"type": "number", "minimum": -1.0, "maximum": 1.0}` with its description; no `oneOf` wrapper on this property.*

`mcp_call.py schema <tool> <property>` for whatever moved. Recorded 2026-07-30,
when bounds moved into the advertised schema: the encoded shape became
`oneOf: [{"type": "number", "minimum": …, "maximum": …}, {"type": "integer", …}]`.
Bounds *inside* `oneOf` branches were the untested combination.

## A rejected call comes back readable, not as a protocol error

*Last run: 2026-08-28 — `result` with `"isError": true`, text "Invalid parameters for set_mixer — nothing was sent to Ableton:\n- pan: must be at most 1.0 (got 2.0) — -1.0 = hard left…"; no `error` key, no `-32602`, no Peri internals.*

`mcp_call.py call set_mixer '{"track": 0, "pan": 2.0}'` must return a
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

*Last run: 2026-08-28 — `-32602`, `Tool not found: no_such_tool`*

`mcp_call.py call no_such_tool '{}'`. That is what the MCP spec says an unknown
tool is, and it is the discriminator keeping the rewrite from swallowing real
protocol errors.

## The rejected value never reached Live

*Last run: 2026-08-28 — track 0 pan read 0.0 via `get_session_state(refresh: true)` after the rejected `pan: 2.0`; a subsequent `pan: -1.0` over the same path read back -1.0 fresh from Live, so the path itself works and the refusal did not send.*

After the rejection above, read the target back. A refusal that silently *did*
send is the thing worth catching, and no reply string can show it to you.


## A mutating tool with nothing required survives the client and rejects unknown keys

*Last run: 2026-08-28 — enum and bounds as described, `required: []`, root schema closed. `pan: -1.0` reached Live (`50L`, read back -1.0). `{"track": 0}` returned the "Nothing to set" tool result. The mixed-key call returned a tool result naming `panning: unknown parameter` with the accepted keys, and track 0's volume read back unchanged at 0.85. **The first run of this check failed**: Peri's `:strict` mode silently *drops* unknown keys rather than rejecting them, so `panning` never reached `Validation` and `volume 0.6` was written to Live. Fixed the same day by running `Validation` on the raw arguments in `Seshat.MCP.Server.handle_request/2` before Anubis/Peri see them — so the path that answered is `Validation`, ahead of Peri, not the `-32602` rewrite.*

`set_mixer` is the first *mutating* tool whose schema has `required: []` and
an optional `target` enum — everything on it is optional because the handler
decides what a target needs. The list-level risk is the one at the top of this
file.

`mcp_call.py schema set_mixer target` shows the enum
`["track", "return", "master", "cue"]` and `set_mixer` absent from `required`;
the full `set_mixer` input schema carries `additionalProperties: false`, and
`schema set_mixer volume` carries `minimum` 0 and `maximum` 1. Then
`call set_mixer '{"track": 0, "pan": -1.0}'` reaches Ableton (pan reads back
`50L`), `call set_mixer '{"track": 0}'` returns a *tool result* saying no
property was given. Finally,
`call set_mixer '{"track": 0, "volume": 0.6, "panning": -0.5}'` returns a
readable tool error naming `panning` as unknown and the accepted keys, with no
volume write reaching Live. Whether Peri or `Seshat.Tools.Validation` rejects
first, the client must receive a tool result rather than a JSON-RPC `-32602`;
record which path answered.

A `-32602` here is Peri rejecting before `Validation`'s wording can be
delivered; the tool list itself disappearing is the schema being refused
wholesale.
