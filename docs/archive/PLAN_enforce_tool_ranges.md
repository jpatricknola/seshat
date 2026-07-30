# Plan — Enforce tool ranges and non-negative indices centrally

> **Archived 2026-07-30 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The fix lives in
> `Seshat.Tools.Validation` (new, schema-driven, called from
> `Handlers.call/2` before dispatch), the missing `minimum`/`maximum` bounds
> added across `Seshat.Tools.Definitions`, and the `MCP.Schema` number branch
> now carrying ranges through `oneOf`. Reviewed with three non-blocking nits
> (a stale test comment claiming coverage `ensure_bars/1` no longer needs, a
> dead nil-guard in `Validation`, and a `required`-vs-`properties` name-typo
> gap with no live instance) — none fixed on this branch; see the PR for the
> exact text. Open question 2 (how MCP clients render the bounded `oneOf`,
> specifically Claude Desktop) is carried forward, not closable from the test
> suite — the first `/smoke-test` connect after this ships is the check.

Roadmap item "Enforce tool ranges and non-negative indices centrally".
Evidence: findings #3 and #4 in
[../REPOSITORY_REVIEW.md](../../REPOSITORY_REVIEW.md), whose reviewer responses
set the shape of this plan — validate in `Handlers` (the seam both modes
share), correct `MCP.Schema` so the advertised schema matches what is
enforced, and **no Python bounds checks** (declined: it would diverge
`track.py`, `clip.py` and `scene.py` permanently for redundant defence).

## Context

Two defects, one seam.

**Missing minimums (finding #3).** `minimum: 0` is present on the newer tool
schemas (`set_track_send`, the return-track family) and missing on the older
ones — every `track`, `clip_slot`, `scene`, `device` and `parameter` index
outside those. AbletonOSC's Python indexes Live's collections directly
(`self.song.tracks[track_id]`), where `-1` means the *last* element. So
`delete_track` with `track: -1` deletes the last track while the reply echoes
"track -1" — invalid input became a valid but unintended destructive
operation. The realistic caller is a model hallucinating Python's `-1 == last`
convention, not an attacker.

**Advertised bounds are not enforced anywhere (finding #4).** In MCP mode,
[schema.ex:45](../../lib/seshat/mcp/schema.ex#L45) converts every JSON Schema
`number` to an unconstrained `{:either, {:float, :integer}}` — a runtime probe
confirmed `set_track_pan` accepts `2.0` against a declared maximum of `1.0`.
In API-key mode there is **no validation layer at all**: the Anthropic API
does not enforce tool schemas, and `Handlers` dispatches whatever arrives. So
bounds are advisory in both modes, and fixing only the Peri conversion would
leave half the surface unguarded while appearing to close the issue.

Research also surfaced a third leak the review missed: Peri's constraint
clauses check *bounds* without re-checking the *base type*
([peri.ex:919-956](../../deps/peri/lib/peri.ex#L919) — the `{:integer, {:gte, 0}}`
clause guards on `is_numeric(val)`, not `is_integer(val)`), so even in MCP
mode a bounded integer param accepts `1.5`. One more reason the authoritative
check lives in our own code, with Peri as the wire-level first pass.

The fix: a single schema-driven validator called from `Handlers.call/2` —
the one dispatch point both entry modes funnel through (verified:
`Seshat.MCP.Tools`' generated `execute/2` and `Seshat.Agent`'s loop both call
`Handlers.call/2` and nothing else does) — plus the missing bounds added to
`Definitions`, plus the `MCP.Schema` number branch carrying its ranges so the
wire-advertised schema and the Peri validation both tell the truth. Because
the validator reads the schemas from `Definitions`, every future tool is
covered by construction, and a schema-generated test can probe every declared
bound from either side without hand-writing cases.

## OSC contract

**No new addresses, no changed wire behavior, no Python half.** This plan
rejects bad values *before* `Transport` is reached; every OSC message that is
still sent is one that is sent today. The Python side is deliberately
untouched (finding #3's third bullet, declined — see
[../REPOSITORY_REVIEW.md](../../REPOSITORY_REVIEW.md)): upstream's
`track.py`/`clip.py`/`scene.py` keep indexing Live's collections directly,
and the Elixir validator plus the loopback bind are the whole defence.

For the record, the behavior being closed off (verified in
[priv/AbletonOSC/abletonosc/track.py](../../priv/AbletonOSC/abletonosc/track.py),
`clip.py`, `scene.py`): a negative index reaching Python selects from the end
of `song.tracks` / `song.scenes` / the clip-slot list, Python-style, and the
reply echoes the negative index as if it were a real target.

One deliberate negative index survives: `create_scene`'s `index: -1` means
"append at the end" — that is AbletonOSC's own convention for
`/live/song/create_scene`, already documented in the tool description, so its
schema gets `minimum: -1`, not `0`.

---

## Part 1 — `Definitions`: declare the missing bounds

In [lib/seshat/tools/definitions.ex](../../lib/seshat/tools/definitions.ex).
Schema edits only — no descriptions change (they already state "0-based"
everywhere), no tool is added, so no count bump in `definitions_test.exs`.

1. Add `minimum: 0` to every index-shaped integer property that lacks it:
   - `track` on: `set_track_pan`, `set_track_volume`, `set_track_mute`,
     `set_track_solo`, `write_midi_notes`, `delete_track`, `duplicate_track`,
     `set_track_name`, `set_track_arm`, `record_clip`, `stop_recording`,
     `fire_clip`, `stop_clip`, `delete_clip`, `duplicate_clip`,
     `set_clip_name`, `get_clip_properties`, `set_clip_properties`,
     `select_track`, `remove_notes`, `get_clip_notes`, `load_device`,
     `get_track_devices`, `get_device_parameters`, `set_device_parameter`,
     `delete_device`, `bypass_device`
   - `clip_slot` on: `write_midi_notes`, `record_clip`, `stop_recording`,
     `fire_clip`, `stop_clip`, `delete_clip`, `duplicate_clip`,
     `set_clip_name`, `get_clip_properties`, `set_clip_properties`,
     `remove_notes`, `get_clip_notes`
   - `target_track`, `target_clip_slot` on `duplicate_clip`
   - `scene` on: `fire_scene`, `delete_scene`, `duplicate_scene`,
     `set_scene_name`, `select_scene`
   - `device` on: `get_device_parameters`, `set_device_parameter`,
     `delete_device`, `bypass_device`
   - `parameter` on `set_device_parameter`
2. `create_scene`'s `index` gets `minimum: -1` (append convention, above).
3. Bound the remaining unbounded numerics of the same defect class (negative
   or nonsense values that today go straight to Live):
   - `remove_notes` / `get_clip_notes`: `start_pitch` `minimum: 0,
     maximum: 127`; `pitch_span` `minimum: 1, maximum: 128`; `start_time`
     `minimum: 0.0`; `time_span` `minimum: 0.0` (zero is a degenerate no-op,
     not a hazard).
   - `write_midi_notes.clip_length` `minimum: 0.01` — the file's existing
     convention for strictly-positive numbers (`duration`'s `minimum: 0.01`).
   - `set_loop`: `start` `minimum: 0.0`; `length` `minimum: 0.01`.
   - `record_clip.bars` `minimum: 0.01`. The handler's `ensure_bars/1`
     (`bars > 0` with a friendlier message) stays — it is being reworked by
     [PLAN_stop_fabricating_session_state.md](PLAN_stop_fabricating_session_state.md)
     Part 4's neighborhood, and a redundant belt costs nothing.
4. **Deliberately left unbounded:** `set_device_parameter.value` — its legal
   range is per-parameter, reported by `get_device_parameters`, and Live
   clamps; a schema bound would be a lie. No `maximum` on any index — track,
   scene and device counts are dynamic; existence is the guard-getter
   pattern's job and roadmap "Verify destructive mutations before reporting
   success" extends it.

## Part 2 — `Seshat.Tools.Validation`: one schema-driven validator

New file `lib/seshat/tools/validation.ex`, pure, no process, no OSC. Public
API:

```elixir
@spec validate(tool_name :: String.t(), params :: map()) :: :ok | {:error, String.t()}
```

`params` is the already-stringified map (`Handlers.stringify_keys/1` runs
first). Behavior:

1. Look up the tool's `:parameters` schema from `Seshat.Tools.Definitions`
   (a compile-time module attribute map, the same dependency direction
   `Seshat.MCP.Tools` already has). An unknown tool name returns `:ok` —
   `do_call/2`'s catch-all keeps owning the "Unknown tool" reply.
2. Walk the schema against the params, collecting **all** violations rather
   than stopping at the first, so the model fixes everything in one retry:
   - **required**: every name in `required` must be present. (Today a
     known tool called with a missing required param falls through the
     pattern-matched `do_call/2` clauses to the catch-all and reports
     "Unknown tool: set_track_pan" — a misleading message this replaces.)
   - **type**, for present params: `integer` → `is_integer` (rejecting `1.5`
     exactly as Peri's plain `:integer` does in MCP mode today — the two
     modes converge rather than diverge); `number` → `is_number`; `string` →
     `is_binary`; `boolean` → `is_boolean`; `array` → `is_list`; `object` →
     a map. Type checking is what keeps the bounds comparison honest —
     Elixir's term ordering would happily conclude `"abc" >= 0`.
   - **enum**: membership.
   - **minimum` / `maximum`**: inclusive, checked only when the value passed
     its type check.
   - **recursion**: `array` items each validated against `items` (error path
     `notes[2].velocity`); nested `object` recurses with its own
     `properties`/`required`.
   - Params not in the schema are ignored (handlers ignore unknown keys;
     Peri already governs the MCP wire).
3. Error text is one line per violation, mechanical, ending with the
   parameter's own schema `description` when it has one — the description is
   already the model-facing teaching text, so reuse it instead of writing a
   second set of hints:

   ```
   Invalid parameters for set_track_pan — nothing was sent to Ableton:
   - value: must be at most 1.0 (got 2.0) — Pan position. -1.0 = full left, 0.0 = center, 1.0 = full right
   ```

   Other forms: `- track: must be at least 0 (got -1) — 0-indexed track
   number`, `- track: required but missing — 0-indexed track number`,
   `- track: must be an integer (got 1.5)`, `- warp_mode: must be one of
   0, 1, 2, 3, 4, 6 (got 5)`.

## Part 3 — Wire it into `Handlers.call/2`

In [lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex). Two edits:
add `alias Seshat.Tools.Validation` to the alias block
([handlers.ex:14-19](../../lib/seshat/tools/handlers.ex#L14), which today aliases
`FollowCam` from the same namespace), and rewrite `call/2`
([handlers.ex:194-197](../../lib/seshat/tools/handlers.ex#L194)):

```elixir
def call(name, params) when is_binary(name) and is_map(params) do
  params = stringify_keys(params)

  case Validation.validate(name, params) do
    :ok -> do_call(name, params)
    {:error, message} -> {:error, message}
  end
end
```

The `{:error, message}` rides the exact path every existing handler error
already takes — `Response.error` in MCP mode, an error tool-result block in
`Seshat.Agent`'s loop — so nothing downstream changes. Existing hand-rolled
guards (`ensure_bars/1`, the clip-property range checks, `device_out_of_range`
re-reads) stay: they check things a static schema cannot (cross-field
ordering, live existence), and pruning the one or two now-redundant ones is
not worth colliding with the other in-flight plans.

## Part 4 — `MCP.Schema`: numbers keep their bounds

In [lib/seshat/mcp/schema.ex](../../lib/seshat/mcp/schema.ex), the number branch
([schema.ex:45](../../lib/seshat/mcp/schema.ex#L45)) becomes:

```elixir
defp peri_type(%{type: "number"} = spec),
  do: {:either, {with_range(:float, spec), with_range(:integer, spec)}}
```

`with_range/2` already exists (it serves the `integer` branch) and returns the
bare base type when the spec has no bounds, so unbounded numbers keep today's
exact shape. Update the comment above the clause: integers are still accepted
where the schema says number (both branches; verified — Peri's bound clauses
guard on `is_numeric(val)`, so an in-range integer satisfies the float
branch), but out-of-range values now fail both branches and the call is
rejected at the wire.

Wire-schema consequence, checked against Peri's encoder
([encoder.ex:172-233](../../deps/peri/lib/peri/json_schema/encoder.ex#L172)):
a bounded number is advertised as `oneOf: [{"type": "number", "minimum": …,
"maximum": …}, {"type": "integer", …}]`. Today's advertisement is already
`oneOf` (that is what `{:either, …}` encodes to) — this only adds the
`minimum`/`maximum` keys inside branches that exist now, so client-side risk
is minimal.

Peri's compile-time `validate_type/2` accepts `{:either, {schema, schema}}`
with constrained branches ([peri.ex:1932](../../deps/peri/lib/peri.ex#L1932),
[peri.ex:1752](../../deps/peri/lib/peri.ex#L1752)) — **verified by execution**,
not just by reading: this change was applied temporarily, compiled, probed
through the real generated component, and reverted. Open question 1 has the
measured compile-time, runtime and `input_schema` results; the Part 5 tests
lock them in.

## Part 5 — Tests

1. **`test/seshat/tools/validation_test.exs`** (new):
   - Hand-written cases: `track: -1` rejected naming the parameter;
     `set_track_pan` `value: 2.0` and `-1.5` rejected, `-1.0`/`1.0`/integer
     `1` accepted; `create_scene` `index: -1` accepted, `-2` rejected;
     `track: 1.5` rejected as non-integer; enum violation
     (`set_clip_properties` `warp_mode: 5`) rejected; nested violation
     (`write_midi_notes` note with `velocity: 0`) rejected with the
     `notes[0].velocity` path; missing required param rejected with the
     "required but missing" line, not "Unknown tool"; multiple violations all
     reported; unknown tool name returns `:ok`.
   - **Schema-generated boundary sweep** (the review's "parity tests that
     submit values immediately outside every declared bound", automated):
     walk `Definitions.all()`; for every tool synthesize a minimal valid
     params map from its schema (required params only: first enum value,
     `minimum` or `0`/`"x"`/`true`/one synthesized array item as the type
     demands); assert it validates; then for every bounded property
     (top-level and nested) assert min − 1 (or − 0.01 for floats) and
     max + 1 are rejected and the exact bounds accepted.
2. **`test/seshat/tools/definitions_test.exs`** — two tripwires for future
   tools, alongside the existing count test (which does **not** change — no
   tool is added):
   - Every property named `track`, `clip_slot`, `target_track`,
     `target_clip_slot`, `scene`, `device`, `parameter`, `send` or
     `return_track` (recursively) declares `minimum: 0`.
   - Every `type: "integer"` property declares `enum` or `minimum`
     (`create_scene`'s `index` satisfies this with `-1`).
3. **`test/seshat/tools/handlers_test.exs`** — the rejection happens before
   the wire: with `OSCSink` forwarding, `call("set_track_pan", %{"track" => 0,
   "value" => 2.0})` returns `{:error, msg}` and `refute_receive {:osc_out, _,
   _}`; same for `call("delete_track", %{"track" => -1})`. Atom-keyed params
   (the MCP shape) are validated identically — extend the existing
   "param key normalisation" describe block.
4. **`test/seshat/mcp/tools_test.exs`** — the wire layer now agrees: add to
   the "input validation" describe block a case asserting
   `validate("set_track_pan", %{"track" => 0, "value" => 2.0})` errors and
   `%{"track" => -1, "value" => 0.0}` errors; a non-numeric value on a bounded
   number (`%{"track" => 0, "value" => "loud"}`) returns `{:error, _}` rather
   than crashing (Peri's final `validate_field` catch-all,
   [peri.ex:1317](../../deps/peri/lib/peri.ex#L1317), turns any unmatched
   value/type pair into a clean error — verified at plan review); the existing
   "accepts integers where the schema says number" test must keep passing
   (integer `1` within pan's bounds).

   **Required, not optional: assert the advertised schema.** Part 4's whole
   deliverable is the *wire advertisement*, and runtime Peri validation does
   not prove the encoder retained the bounds — they are separate code paths in
   Peri, and the roadmap item's second planner note asks specifically for the
   advertised schema to match what is enforced. So assert the generated
   component's `input_schema` for `set_track_pan`'s `value`: both `oneOf`
   branches carry `minimum: -1.0` and `maximum: 1.0` (the `number` branch and
   the `integer` branch). Verified reachable at plan review — Peri's encoder
   maps `{:either, {a, b}}` to `oneOf` of both converted branches
   ([encoder.ex:228](../../deps/peri/lib/peri/json_schema/encoder.ex#L228)) and
   puts `minimum`/`maximum` on a `{type, {:range, …}}`
   ([encoder.ex:181](../../deps/peri/lib/peri/json_schema/encoder.ex#L181)).

## Part 6 — Keep the next tool honest

1. In [.claude/docs/adding-a-tool.md](../../.claude/docs/adding-a-tool.md), step 1:
   add two sentences after the "Supported JSON Schema" paragraph — every index
   param must declare `minimum: 0` (`definitions_test` enforces it), and declared
   bounds are enforced centrally by `Seshat.Tools.Validation` before dispatch, so
   a handler clause never needs its own numeric range check. This plan's edit is
   the doc text only; the mechanical enforcement is Part 5.2.
2. Add a module-map row for `lib/seshat/tools/validation.ex` in
   [CLAUDE.md](../../CLAUDE.md), after the `handlers.ex` row: schema-driven
   parameter validation, called from `Handlers.call/2` before dispatch.

## Testing

- **Pure (`mix test`) — everything.** This is the rare item with no Ableton
  half: the validator is pure, the schema edits are data, and the MCP
  conversion is exercised through the generated components' `validate_input`
  in `tools_test.exs`. `mix precommit` before done.
- **`/smoke-test`: nothing to add.** The behavior change on a live Ableton is
  only that bad calls now stop in Elixir instead of misfiring in Python, and
  that is asserted at the OSCSink wire in Part 5.3. (Optionally, a manual
  check that a rejected call's error text reads sensibly in Claude Desktop —
  cosmetic, not correctness.)

## Out of scope

- **Python bounds checks** — declined in the review response (finding #3,
  bullet 3); would permanently diverge three upstream files for redundant
  defence. The fork's loopback bind means Elixir is the only caller.
- **Upper-bound / existence checks on indices** (does track 7 exist?) —
  dynamic state, not schema; stays with the guard-getter pattern and the
  roadmap item "Verify destructive mutations before reporting success".
- **Coercing instead of rejecting** (truncating `1.5`, clamping `2.0` to
  `1.0`) — rejected: `Seshat.Tools.Validation` deliberately demands a true
  integer where the schema says integer, and truncating or clamping silently
  executes something the model didn't ask for, which is the defect class this
  item exists to kill. Note that Peri is *not* the thing doing the rejecting
  once Part 1 lands: a plain `:integer` rejects `1.5`, but the bounded
  `{:integer, {:gte, 0}}` this plan produces guards on `is_numeric(val)`
  (Context, above), so every index param loses its wire-level non-integer
  check and the central validator becomes the only one. That is the intended
  trade — one authoritative check covering both entry modes, rather than a
  wire check that covers half the surface.
- **Pruning hand-rolled guards made redundant** (`ensure_bars/1` and kin) —
  left in place; near-zero cost, and their neighborhoods are being edited by
  [PLAN_stop_fabricating_session_state.md](PLAN_stop_fabricating_session_state.md).
- **`create_scene`'s `index`-vs-`scene` param naming drift** — recorded in
  [TOOL_AUDIT.md](../TOOL_AUDIT.md) §03 as a Low, not this item.
- **TOOL_AUDIT.md sweep** — §03's correction note and the "≥4 outstanding"
  tally get updated at `/ship` time, per that doc's own convention.
- **Rate limiting / auth on the entry points** — deployment-gated, see
  [SECURITY_BACKLOG.md](../SECURITY_BACKLOG.md).

## Open questions

1. ✅ **RESOLVED by execution — Peri behaves as read.** No longer an open
   question. The Part 4 one-line change was applied temporarily on top of
   `main` (with `minimum: 0` added to `set_track_pan.track`), the app
   compiled, the real generated component was probed, and both files were
   reverted — `lib/` is unchanged. Results:

   - **Compile-time acceptance:** the component built with
     `{:required, {:meta, {:either, {{:float, {:range, {-1.0, 1.0}}},
     {:integer, {:range, {-1.0, 1.0}}}}}, [description: …]}}`. Anubis's
     compile-time validation accepts constrained `:either` branches.
   - **Runtime, through the generated `validate_input`:** `2.0` and `-1.5`
     rejected; `1.0`, `-1.0`, `0.5` accepted; integers `1`, `0`, `-1`
     accepted (so "accepts integers where the schema says number" survives);
     `"loud"` returns a clean `{:error, …}`, no crash. `track: -1` rejected.
   - **Advertised `input_schema`:** exactly the target shape —
     `"value" => %{"description" => …, "oneOf" => [%{"type" => "number",
     "minimum" => -1.0, "maximum" => 1.0}, %{"type" => "integer", "minimum"
     => -1.0, "maximum" => 1.0}]}`. The description stays at property level,
     outside the `oneOf`.
   - **The whole existing suite passed under the change** (184 tests in
     `test/seshat/mcp/` and `test/seshat/tools/`, 0 failures), so Part 4 is
     not expected to disturb anything already asserted.
   - **The bounded-integer leak reproduced too:** `track: 1.5` and
     `track: 0.0` both *pass* Peri once `track` carries `minimum: 0`,
     confirming Context's claim by execution. This is why Part 2's validator
     is the authoritative integer check.

   Part 5.4 still gets written — it is the regression guard, not the
   experiment — but it is no longer a risk to retire first.

   **There is no `{:custom, …}` fallback.** An earlier draft of this plan
   offered one; it is withdrawn, because it would silently destroy the wire
   schema Part 4 exists to fix. Peri's encoder routes `{:custom, _}` to
   `unsupported/3`
   ([encoder.ex:272](../../deps/peri/lib/peri/json_schema/encoder.ex#L272)),
   which returns a bare `%{}` unless called with `on_unsupported: :raise`
   ([encoder.ex:287](../../deps/peri/lib/peri/json_schema/encoder.ex#L287)) —
   and Anubis calls it without that option
   ([anubis/server/component/schema.ex:24](../../deps/anubis_mcp/lib/anubis/server/component/schema.ex#L24)).
   So the parameter would advertise not just no bounds but **no type at all**,
   with no compile error and no warning: the tools still list, the schema is
   just empty. If the constrained `{:either, …}` shape misbehaves, the answer
   is another *statically encodable* Peri representation, or stopping and
   reassessing — never a validator the encoder cannot see.
2. ⚠️ **Narrowed, not closed: how MCP clients render the bounded `oneOf`.**
   Both halves of the shape are already proven on the wire against a live
   client. Measured against the running Seshat MCP server from a connected
   client (Claude Code, this session), `set_track_send` is advertised as:

   ```json
   "send":  {"type": "integer", "minimum": 0, "description": "…"},
   "track": {"type": "integer", "minimum": 0, "description": "…"},
   "value": {"oneOf": [{"type": "number"}, {"type": "integer"}], "description": "…"}
   ```

   So `minimum` on an integer param and a bare `number`/`integer` `oneOf` are
   both shipping today and both accepted — the tool lists and calls fine.
   (That readout is also the defect in the flesh: `value` is documented
   "0.0 (off) to 1.0 (maximum)" and advertises no bounds at all.)

   What remains untested is only the *combination*: `minimum`/`maximum`
   inside `oneOf` branches, and specifically in **Claude Desktop**, which the
   evidence above does not cover. A client-side regression would show up as
   tools failing to list, which the first `/smoke-test` connect catches. Not
   closable from the test suite, but the residual risk is now one keyword
   placement rather than the whole shape.

   If a client *does* reject a `number` param, suspect the `oneOf` before
   suspecting the new keywords: `oneOf` means *exactly one* branch matches,
   and an integer like `1` satisfies both `{"type": "number"}` and
   `{"type": "integer"}`, so a strict validator has grounds to reject a
   well-formed integer today. That ambiguity is **pre-existing** — it is what
   `{:either, {:float, :integer}}` has always encoded to — and this plan
   neither causes nor worsens it, so fixing it is a separate item
   ([TOOL_AUDIT.md](../TOOL_AUDIT.md) material, not this one).
