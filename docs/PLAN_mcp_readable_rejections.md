# Plan — Model-readable rejections for invalid tool parameters in MCP mode

Roadmap: "Model-readable rejections for invalid tool parameters in MCP mode."
One override on `Seshat.MCP.Server` — `handle_request/2`, which Anubis
explicitly makes `defoverridable` — intercepts the JSON-RPC `-32602` that Peri
produces for an invalid `tools/call` and replaces it with a **tool result**
(`isError: true`) carrying `Seshat.Tools.Validation`'s message: the parameter,
the bound, the value it got, and the parameter's own description. No OSC, no
Python, no schema change; the advertised `inputSchema` and the Peri layer stay
exactly as shipped. After this, a model that sends `value: 2.0` reads "must be
at most 1.0 (got 2.0) — Pan position…" and quietly retries, in MCP mode as it
already does in API-key mode.

## Context

Bounds are enforced in both modes ("Enforce tool ranges and non-negative
indices centrally", shipped 2026-07-30), and `Seshat.Tools.Validation` already
writes the model-facing refusal — but in MCP mode Peri rejects at the wire
first, and a Peri rejection is a JSON-RPC *protocol error*, not a tool result.
Protocol errors are for broken calls (malformed JSON, unknown method); tool
results are the channel clients feed back to the model. Claude Code, measured
2026-07-30, surfaces a `-32602` as nothing but `MCP error -32602: Invalid
params` — the explanatory `data.message` never reaches the model, and even
that hidden text is Elixir internals (`expected either {:float, {:range, ...}}
or {:integer, {:range, ...}}, got: 2.0`).

The central validator's message reaches the model only in the narrow band
where Peri passes and `Validation` catches — e.g. `track: 1.5`, because Peri's
bound clauses guard on `is_numeric/1` without re-checking the base type. That
band works today (measured, case C below) and is the model of what every
rejection should look like.

What research settled:

1. **The seam is `handle_request/2` on `Seshat.MCP.Server`, not the
   components.** The roadmap entry pointed at the generated component in
   `mcp/tools.ex`, but a Peri rejection never reaches a component: Anubis's
   `Handlers.Tools.handle_call/3` validates first and returns
   `Error.protocol(:invalid_params, %{message: …})` before `execute/2` exists
   in the call path. The component cannot intercept what it never receives.
   `handle_request/2` is the one hook Anubis deliberately leaves open
   (`defoverridable handle_request: 2` in `__before_compile__`), it sees every
   `tools/call` before and after dispatch, and it lives on the module both
   transports share — HTTP and `mix mcp` stdio get the fix at once.
2. **The override compiles and dispatches, verified empirically** (probe
   compiled against this repo's deps, 2026-07-31, and independently repeated
   at plan review): a module body's specific `handle_request/2` clause
   coexists with the catch-all Anubis injects at `__before_compile__` — no
   duplicate-clause warning under `warnings-as-errors`, because the injected
   default is `quote generated: true` — and dispatch reaches the body's clause
   first. The injected catch-all remains reachable for `tools/list` and
   unknown methods, so it does not need to be copied into Seshat. Delegating
   to `Anubis.Server.Handlers.handle/3` (what the default does verbatim)
   round-trips correctly.
3. **The advertised schema and the Peri schema cannot be decoupled**, which
   kills the alternative design (loosen Peri, keep the advertisement strict):
   `input_schema/0` derives from `__mcp_raw_schema__()` — the same raw schema
   the `validate_input` closure feeds to Peri — inside Anubis's `__using__`,
   and neither function is `defoverridable`. Redefining either in the 65
   generated components would be a duplicate-def against a non-generated
   context. The interception design needs none of that: Peri keeps rejecting,
   we rewrite what its rejection becomes.
4. **"Tool not found" arrives on the same channel** — also
   `Error.protocol(:invalid_params, …)` (measured, case D). The rewrite must
   discriminate by tool-name membership in `Seshat.Tools.Definitions`, never
   by error text: an unknown tool keeps its protocol error (that is what the
   MCP spec says an unknown tool is), while a known tool's rejection becomes a
   tool result.
5. **Peri passes unknown extra keys** (measured, case F), so the fallback band
   — Peri rejects, central validator says `:ok` — is narrow. The one
   reproducible member is non-map `arguments` (a JSON array or scalar), which
   `Validation.validate/2`'s `is_map` guard would crash on rather than judge.
   The fallback returns Peri's own `data.message` framed as a tool result:
   worse prose, right channel. Falling through to the handler is never
   acceptable — Peri rejected for a reason.

## Measured evidence (2026-07-31)

Probed over raw MCP streamable HTTP against the running server (Anubis 1.10.0,
Peri 0.9.0). "Before" is today's behaviour; "after" is this plan's contract.

| # | Call | Before | After |
|---|---|---|---|
| A | `set_track_pan {track: 0, value: 2.0}` | JSON-RPC error `-32602`, `data.message: "value: expected either {:float, {:range, ...}} or {:integer, {:range, ...}}, got: 2.0"` | Tool result, `isError: true`: `Invalid parameters for set_track_pan — nothing was sent to Ableton:` + `- value: must be at most 1.0 (got 2.0) — <the param's own description>` |
| B | `write_midi_notes` with `velocity: 200` | `-32602`, `data.message: "notes: ; notes: "` — empty, doubled, no index | Tool result naming `notes[0].velocity`, the bound, and 200 |
| C | `set_track_pan {track: 1.5, value: 0.0}` | Tool result, `isError: true`, full central-validator message | **Unchanged** — the band where Peri passes and `Validation` catches already behaves correctly |
| D | unknown tool name | `-32602`, `data.message: "Tool not found: …"` | **Unchanged** — protocol error, per MCP spec; discriminated by Definitions membership |
| E | `set_track_pan {value: 0.5}` (missing `track`) | `-32602`, `data.message: "track: is required, expected type of {:integer, {:gte, ...}}"` | Tool result: `- track: required but missing — 0-indexed track number` |
| F | `set_metronome` with an extra unknown key | Peri passes, tool executes | **Unchanged** — nothing to rewrite |
| G | `set_track_pan {track: "zero", …}` | `-32602`, Peri type text | Tool result: `- track: must be an integer (got "zero") — …` |

Also measured: the `handle_request/2` override probe of research item 2, and
`Response.error(Response.tool(), msg)` / `Response.to_protocol/1` as the
public constructors for the tool-error protocol map (the same pair the
generated components and Anubis's own `forward_to` use).

## Wire contract

No OSC. The contract is JSON-RPC over both MCP transports:

- An invalid `tools/call` **naming a tool that exists** returns a normal
  `result` whose `content` is one text block —
  `Seshat.Tools.Validation`'s message, verbatim — with `isError: true`.
- An invalid `tools/call` naming an **unknown tool** returns JSON-RPC error
  `-32602` exactly as today.
- A `tools/call` that Peri rejects but the central validator passes returns a
  tool result (`isError: true`) framed by the same first line, carrying Peri's
  `data.message` text as the violation line.
- Valid calls, all other methods, and every non-`invalid_params` error
  (scopes → execution error, task policy → method_not_found, handler crashes)
  pass through byte-identical to today.

## Parts

### 1. `Seshat.MCP.Server` — intercept and rewrite

[lib/seshat/mcp/server.ex](../lib/seshat/mcp/server.ex): add one specific
`handle_request/2` clause (with `@impl Anubis.Server`) ahead of the generated
default:

- `%{"method" => "tools/call"} = request` — delegate to
  `Anubis.Server.Handlers.handle(request, __MODULE__, frame)`. On
  `{:error, %Anubis.MCP.Error{reason: :invalid_params}, frame}` where
  `request["params"]["name"]` is in a compile-time `MapSet` of
  `Definitions.all()` names, rewrite via `rewrite_rejection/3`; everything
  else returns untouched.

Do not add a Seshat catch-all: Anubis's generated `handle_request/2` remains
the general clause for every other method. Keeping that default avoids copying
dependency plumbing Seshat does not own.

`rewrite_rejection(name, arguments, error)`:

- `arguments` is `params["arguments"]` when it is a map, `%{}` when the key is
  absent (Anubis validates `%{}` in that case too — measured E), and
  *not-a-map* otherwise.
- Map arguments: `Seshat.Tools.Validation.validate(name, arguments)`. The
  wire decode guarantees string keys, so no normalisation. `{:error, message}`
  → that message. `:ok` → the fallback framing around
  `error.data[:message]` (research item 5: Peri saw something the central
  validator doesn't model; its text is the only diagnosis available).
- Non-map arguments: the fallback framing around `error.data[:message]`
  directly — `Validation.validate/2` is guarded `is_map` and must not be fed
  this.
- Fallback framing: `"Invalid parameters for #{name} — nothing was sent to
  Ableton:\n- #{peri_text}"` — the same first line `Validation.message/2`
  emits, duplicated as a string literal. One sentence of drift risk against a
  private function; not worth widening `Validation`'s API for.
- Reply: `{:reply, Response.to_protocol(Response.error(Response.tool(),
  message)), frame}` — the exact map Anubis's `forward_to` would have built
  had the handler itself returned `{:error, message}`.

Moduledoc gains a paragraph saying why the override exists and what it relies
on (the three facts in research item 2), so an Anubis upgrade that breaks the
seam has prose to find.

### 2. Tests — `test/seshat/mcp/server_test.exs`

All pure: `handle_request/2` is a plain function taking a request map and a
`%Anubis.Server.Frame{}`, which is how the probe drove it. Change the module to
`use ExUnit.Case, async: false` before adding the valid-call test below: its
`OSCSink` and `Transport` bind the fixed test ports, just like the other
wire-reaching test modules, so this file cannot run concurrently with them.
Update the moduledoc to cover server dispatch as well as instructions, then add
a describe "invalid tools/call rejections", asserting on the returned tuple:

- Case A: out-of-range `value` → `{:reply, %{"isError" => true, "content" =>
  [%{"text" => text}]}, _}` with `text` containing `must be at most 1.0`,
  `(got 2.0)`, and the parameter's description — and **not** containing
  `{:float,` (the Peri internals must be gone).
- Case B: one bad velocity among valid notes → text names `notes[0].velocity`
  and `127`.
- Case E: missing required `track` → `required but missing`.
- Case G: string where integer expected → `must be an integer (got "zero")`.
- Case D: unknown tool → `{:error, %Anubis.MCP.Error{reason:
  :invalid_params}, _}` untouched — the discriminator works.
- Absent `"arguments"` key → same as E.
- Non-map `"arguments"` (a list) → `isError: true`, text begins `Invalid
  parameters for` and carries Peri's text — the fallback band.
- Valid call passes through to the real handler: start `Transport` +
  `Seshat.Test.OSCSink` per [.claude/rules/testing.md](../.claude/rules/testing.md),
  call `set_metronome {enabled: true}`, assert the OSC send arrives at the
  sink and the reply is `{:reply, %{"isError" => false}, _}` — proving the
  interception never touches the valid path.
- A method other than `tools/call` (e.g. `tools/list`) still answers — the
  generated Anubis catch-all remains reachable.

These tests double as the Anubis-upgrade tripwire: if a future version changes
the error reason, the injected-default mechanics, or `Handlers.handle/3`,
case A or D fails loudly rather than the feature silently reverting to
protocol errors.

### 3. Smoke-test skill — client's-eye check

`.claude/skills/smoke-test/SKILL.md`: extend the advertised-MCP-schema section
(or add a sibling) with the raw-handshake probe: with the server running, an
out-of-range `set_track_pan` over HTTP MCP must come back as a **tool result**
(`isError: true`) whose text names the bound and the got-value, and an unknown
tool name must stay a JSON-RPC `-32602`. Note that `mix test` covers the same
seam purely; the smoke item exists because this defect was *found* by a real
client swallowing `data.message`, so the check of record is a client-shaped
probe against the running server.

### 4. Roadmap link

[docs/ROADMAP.md](ROADMAP.md): add the plan-doc pointer to the item's entry
(house style: the "MCP mode in the browser UI" entry). No shrinking — that is
`/ship`'s job.

## Testing

Everything is pure `mix test` — this is the rare plan with no
Ableton-dependent half: the seam is request-map in, tuple out, and the probe
already exercised it without a running server. The only live checks are Part
3's client's-eye probes (running server, raw MCP handshake), which exist to
watch the channel a real client sees, not because the suite can't reach the
logic. Nothing tests through `Transport.query/3`; the one test that starts
`Transport` uses `OSCSink` per the testing rules.

## Out of scope

- **Prompts and resources** — the server registers neither; only the
  `tools/call` rejection channel changes.
- **Improving Peri's own message text** (the `is required, expected type of`
  typo lives upstream) — the fallback band keeps Peri's prose; making it
  pretty means patching a hex dep for a case measurement could barely
  produce.
- **API-key mode** — already correct: `Validation` runs inside
  `Handlers.call/2` and its message reaches the model as a tool result today.
- **Output-schema validation, MCP task support, auth** — untouched Anubis
  features.
- **`Seshat.MCP.Schema` changes** — none. The advertised `inputSchema` is
  deliberately identical before and after; this item is about which layer
  *speaks*, not which layer knows (roadmap's own phrasing, preserved).

## Open questions

None. The three things that could have stayed open were all measured on
2026-07-31 against this repo's deps and the running server: the override
compiles clean under warnings-as-errors and wins dispatch (research item 2);
every rejection class's current wire shape is in the evidence table; and the
fallback band's only reproducible member (non-map `arguments`) is handled
explicitly in Part 1. The residual risk is an Anubis upgrade moving the seam,
which is a tripwire concern (Part 2), not an open question.
