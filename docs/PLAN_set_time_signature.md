# Plan — `set_time_signature`: the missing half of the tempo pair

Roadmap item "`set_time_signature`". One new tool — `set_time_signature` —
that sets the song's global time signature via
`/live/song/set/signature_numerator` and
`/live/song/set/signature_denominator`.

**No Python half.** Both addresses are upstream AbletonOSC: `signature_numerator`
and `signature_denominator` sit in `properties_rw` in the fork's
[abletonosc/song.py](../priv/AbletonOSC/abletonosc/song.py), which generates
`get`/`set`/`start_listen`/`stop_listen` handlers for each. No submodule
commit, no pin bump, no `mix abletonosc.install`, no Live restart.

## Context

`get_session_state` reports the time signature, `record_clip` converts bars to
beats using it, and `set_tempo` exists — but there is no setter, so anything in
3/4 or 6/8 starts with a manual step in Live's transport bar. This is the
cheap symmetry win the roadmap describes: two upstream addresses, one tool,
and every downstream consumer of the signature (the mirror, `record_clip`'s
bar math, the model's clip-length arithmetic) already exists.

Research confirmed the roadmap entry's claims and surfaced one hazard:

1. **Setting an invalid value is a silent no-op.** `AbletonOSCHandler._set_property`
   ([abletonosc/handler.py](../priv/AbletonOSC/abletonosc/handler.py)) wraps
   `setattr` in a try/except that logs and swallows every exception, and
   setters never reply. A numerator of 0 or a denominator of 3 — values Live's
   own UI cannot express — would be rejected by the Live API, logged in Live,
   and look identical to success on the wire. So the schema must make invalid
   values unrepresentable: numerator bounded 1–99, denominator an enum of
   {1, 2, 4, 8, 16} — exactly the choices Live's transport-bar signature
   control offers. `Seshat.Tools.Validation` enforces bounds and enums from
   the schema by construction, in both entry modes, and `MCP.Schema` carries
   both to the wire (`{:integer, {:range, ...}}`, `{:enum, values}`).
2. **The mirror updates itself — no new Session.State code.**
   `@listened_song_properties` in
   [lib/seshat/session/state.ex](../lib/seshat/session/state.ex) already
   includes `signature_numerator` and `signature_denominator`, and the
   `handle_info` clauses for `/live/song/get/signature_numerator|denominator`
   pushes already exist. Setting the property fires Live's property listener,
   AbletonOSC pushes the new value, the mirror absorbs it. This is how the
   roadmap note "the echo can verify against the mirror" is satisfied: the
   *smoke test* verifies through `get_session_state` (no `refresh: true`
   needed), not by a read-back inside the handler.
3. **No verification round-trip in the handler.** This is an ordinary
   parameter setter, and the settled rule
   ([.claude/rules/osc.md](../.claude/rules/osc.md), reaffirmed in the
   roadmap's "Verify destructive mutations" planner notes) keeps those
   fire-and-forget — `set_tempo` is the exact precedent. With the schema
   closing the invalid-value hole, the only remaining failure is a dropped
   loopback datagram, which no setter in the codebase guards against and
   which the always-visible mirror would expose on the next
   `get_session_state`.
4. **Two sends is still Transport-direct, not a `%Command{}`.** `set_loop`
   already sends up to three messages from one handler clause via `with`;
   Registry stays for the three multi-step sequences it owns (which
   interleave queries and verification, not just sends). The transient
   half-set state between the two datagrams (e.g. 6/4 for a microsecond on
   the way from 3/4 to 6/8) is harmless — Live's own UI edits the two fields
   separately too.
5. **Live still counts quarter-note beats regardless of the signature.**
   `record_length_beats/3` in
   [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex) exists
   precisely because `record_length` and clip lengths are measured in
   quarter-note song-time beats, not signature beats — one bar of 6/8 is 3.0
   beats. The tool's reply computes and states this so the model's next
   `write_midi_notes`/`set_loop` call uses the right arithmetic instead of
   assuming a bar of 6/8 is 6.0 beats. **Measured in Live on 2026-07-31 and
   confirmed** (Open question 3): in 6/8, a 6.0-beat song loop spans exactly
   two bars. The LOM never defines the beat unit, so this rests on the
   measurement rather than on documentation.

## OSC contract

| Address | Args sent | Reply | Notes |
|---|---|---|---|
| `/live/song/set/signature_numerator` | `numerator (int)` | **none, ever** | Upstream. `_set_property` logs and swallows Live API rejections — silence is also what success looks like, hence the schema bounds |
| `/live/song/set/signature_denominator` | `denominator (int)` | **none, ever** | Same |

Listener echo (already subscribed, no code change): each set fires the
property listener, and AbletonOSC pushes `/live/song/get/signature_numerator
[value]` / `/live/song/get/signature_denominator [value]` to 11001, where
`Session.State`'s existing `handle_info` clauses update the mirror.

Both values are sent as integers — the schema says `integer`, and
`Seshat.Tools.Validation` rejects `6.0` rather than coercing (its documented
policy), so nothing float-typed can reach `setattr` on an int property.

## Numbered parts

### 1. Define the tool — `lib/seshat/tools/definitions.ex`

Insert next to `set_tempo` (the transport group), keeping the pair adjacent:

```elixir
%{
  name: "set_time_signature",
  description:
    "Set the song's global time signature in Ableton Live — the one in the " <>
      "transport bar that bar lines, the metronome, and bars-based recording " <>
      "follow. numerator is beats per bar (1-99); denominator is the note " <>
      "value that gets the beat (1, 2, 4, 8, or 16 — the same choices as " <>
      "Live's own control). Note for later calls: clip lengths, loop points, " <>
      "and note times stay measured in quarter-note beats regardless of the " <>
      "signature — one bar of 3/4 is 3.0 beats, one bar of 6/8 is also 3.0 " <>
      "beats. Changing the signature moves the bar grid; already-written " <>
      "notes do not move.",
  parameters: %{
    type: "object",
    properties: %{
      "numerator" => %{
        type: "integer",
        minimum: 1,
        maximum: 99,
        description: "Beats per bar (the top number), 1-99"
      },
      "denominator" => %{
        type: "integer",
        enum: [1, 2, 4, 8, 16],
        description: "Note value that gets the beat (the bottom number): 1, 2, 4, 8, or 16"
      }
    },
    required: ["numerator", "denominator"]
  }
}
```

Decisions folded in, so they don't reopen during implementation:

- **Both parameters required.** A time signature is spoken as a whole
  ("put it in 6/8"); a numerator-only call has no use case worth an optional
  parameter, and re-sending an unchanged denominator is a free idempotent set.
- **`denominator` is an integer enum, not a bounded range.** 1–16 would admit
  3, 5, 6 … which Live rejects — silently, per the `_set_property` finding.
  The enum matches Live's UI menu exactly. `Validation` checks enums first
  (tighter than type) and `MCP.Schema` emits `{:enum, [1, 2, 4, 8, 16]}`, so
  both modes refuse loudly with the allowed list in the message.
- **Bounds are Live's UI bounds** (numerator spinner 1–99, denominator menu
  1/2/4/8/16). Over-restricting to the UI's range is safe by construction;
  under-restricting reintroduces the silent no-op (see Open questions).
- The description spends its weight on the one thing the model will get wrong
  otherwise: quarter-note beat math for subsequent clip work. That guidance
  currently lives only in API-key mode's system prompt; the description
  carries it to MCP mode too, where it costs nothing (no instructions-budget
  impact).

### 2. Handle it — `lib/seshat/tools/handlers.ex`

One `do_call/2` clause next to `set_tempo`, Transport-direct, `set_loop`'s
multi-send shape:

```elixir
defp do_call("set_time_signature", %{"numerator" => numerator, "denominator" => denominator}) do
  with :ok <- Transport.send_message("/live/song/set/signature_numerator", [numerator]),
       :ok <- Transport.send_message("/live/song/set/signature_denominator", [denominator]) do
    beats = numerator * 4 / denominator

    {:ok,
     "Set the time signature to #{numerator}/#{denominator}. " <>
       "Clip lengths and note times still count quarter-note beats: one bar is now #{beats} beats."}
  else
    {:error, reason} -> {:error, inspect(reason)}
  end
end
```

- Numerator first, denominator second — the order is arbitrary and the
  transient in-between signature harmless, but pick one and keep it so the
  wire assertions in the tests are deterministic.
- `numerator * 4 / denominator` is float division in Elixir, so the reply
  reads "3.0 beats" / "3.5 beats" — matching how every other beats value is
  rendered (`record_clip`, `set_loop`).
- Values go on the wire as the integers the schema guaranteed — no `/ 1.0`
  coercion here, unlike `set_tempo`'s float `bpm` (Live's
  `signature_numerator`/`signature_denominator` are int properties).
- No `FollowCam` steering: do **not** add a `FollowCam.steer/2` call —
  steering is invoked explicitly per tool from handler clauses, and
  `set_tempo`'s clause has none, exactly because a song-level setter has no
  pane to show. (`calls/2`'s catch-all no-op exists, but relying on it would
  add a pointless call.)

### 3. Tests

- **`test/seshat/tools/definitions_test.exs`** — two edits, not one. Bump the
  count assertion: `53 → 54` if this lands before
  [PLAN_quantize_clip.md](PLAN_quantize_clip.md)'s `quantize_clip`, `54 → 55`
  after it. **And add `set_time_signature` beside `set_tempo` in the
  `expected` name list** in "includes all expected tool names" — the count
  assertion alone would pass if the tool were named something else or
  silently replaced another, so the manual inventory is what actually pins
  this tool's presence. (The existing schema sweeps then cover the new
  bounds/enum by construction.)
- **`test/seshat/tools/validation_test.exs`** — three cases in the existing
  style: `numerator: 0` rejected with the bound, `denominator: 3` rejected
  naming the allowed values, `numerator: 6.0` rejected as not an integer.
  These document that the silent-no-op hole is closed at validation.
- **`test/seshat/tools/handlers_test.exs`** — an OSCSink describe block
  (`setup :osc_sink`), the `set_track_pan` pattern: a valid call returns
  `{:ok, msg}` with `msg =~ "6/8"` and `msg =~ "3.0 beats"`, and both
  datagrams land — `assert_receive {:osc_out,
  "/live/song/set/signature_numerator", [6]}` then
  `{:osc_out, "/live/song/set/signature_denominator", [8]}` — proving
  integers, not floats, went on the wire.
- **MCP parity** (`Seshat.MCP.ToolsTest`) is generated coverage — no work,
  but it is the check that the integer enum survives Peri conversion.

### 4. Bookkeeping

- **`docs/TOOL_AUDIT.md`** — three edits. Add a `set_time_signature` row to
  the inventory table with a verdict, directly under `set_tempo` in the
  Transport group. **Rewrite the `set_tempo` row's note**, which currently
  reads "Pairs with a missing `set_time_signature`." and goes stale the
  moment this ships — make it "Pairs with `set_time_signature`." Remove the
  time-signature setter from the coverage-gap list if it appears there.
- No change to `Session.State` (both listeners and both `handle_info` clauses
  exist), no change to `Seshat.Instructions` (the beat-math guidance rides in
  the description), no change to
  [abletonosc-api-docs.md](abletonosc-api-docs.md) (both addresses already
  documented), no change to `FollowCam`.

### 5. Retire the beat-unit warning — `lib/seshat/tools/handlers.ex`

`record_length_beats/3`'s `@doc` currently ends with a ⚠️ block saying the
quarter-note assumption is unverified in odd meters and naming itself as the
one line to change if Live counts signature beats instead. **That is no longer
true** (Open question 3), and a stale warning is worse than none — the next
reader treats a settled fact as a live risk. Replace those three lines with
the measurement:

```
Verified 2026-07-31 in Live: with the song in 6/8, a song loop of 6.0 beats
reads 2.0.0 — two bars — in the transport bar, so a bar of 6/8 is 3.0
song-time beats and this formula is right. Neither the LOM Song page nor the
Clip page defines the beat unit, so this is measurement, not documentation.
```

Leave the prose above it alone; it already states the rule correctly. Nothing
else changes — the function itself was never wrong.

## Testing

Covered pure (no Ableton): definitions count and schema sweeps, validation of
both parameters (bound, enum, integer-not-float), both datagrams asserted at
the OSCSink with integer payloads, reply wording including the beats-per-bar
line, MCP schema parity.

Needs `/smoke-test` with Ableton open (nothing in `mix test` executes the
Live API):

1. Set 6/8 — Live's transport bar shows 6/8.
2. `get_session_state` **without** `refresh: true` immediately after shows
   6/8 — this is the listener-echo verification the roadmap entry asks for,
   and it exercises the push path end to end.
3. Set 3/4, then `record_clip` with `bars: 2` — records 6.0 quarter-note
   beats (the `record_length_beats/3` conversion consuming the new mirror
   values).
4. In MCP mode, attempt `denominator: 3` — refused before anything reaches
   Ableton, with the allowed values readable in the refusal (subject to the
   known MCP-refusal-legibility gap tracked by the roadmap's "Model-readable
   rejections" item — the JSON-RPC error is expected there today; the point
   is that nothing was sent).
5. Set 7/8 (odd numerator, a value the enum permits and Live accepts) — bar
   grid updates, metronome follows.

## Out of scope

- **Per-scene time signatures** (`/live/scene/set/time_signature_numerator`
  / `_denominator` / `_enabled`) — real upstream addresses, different
  feature (scene-launch overrides). No roadmap entry asks for them; grab-bag
  material if a workflow ever does.
- **Groove amount** — the next roadmap item in the arc, its own plan.
- **A time-signature getter tool** — `get_session_state` already reports it;
  a dedicated getter would duplicate the mirror.
- **Restretching existing clips to the new signature** — Live itself doesn't
  do this and neither should we; the description says so instead.

## Open questions

1. **⚠️ The bounds are taken from Live's UI, not from LOM documentation.**
   The Live Object Model docs don't state the accepted range for
   `signature_numerator`/`signature_denominator` — verified 2026-07-30
   against [the LOM Song apiref](https://docs.cycling74.com/apiref/lom/song/),
   which gives both as bare `int`, get/set/observe, with no range where
   sibling properties like `swing_amount` do carry one ("Range: 0.0 - 1.0").
   So there is nothing further to look up, and nothing to probe either: what
   `setattr` accepts can only be tested through a setter, which is the thing
   this plan builds. **This question cannot close before implementation** —
   it closes at smoke time or not at all. Live's transport-bar
   control offers numerator 1–99 and denominator {1, 2, 4, 8, 16}, and the
   schema mirrors that. Couldn't be resolved now: confirming what `setattr`
   actually accepts needs live Ableton, and `_set_property`'s
   swallow-everything makes probing from the wire uninformative. Assumed
   meanwhile: the UI range is the safe subset — if the LOM secretly accepts
   more (a denominator of 32, say), the schema refuses a value that would
   have worked, which is a loud, correctable error rather than a silent
   no-op, and widening an enum later is a one-line change. Smoke items 1 and
   5 confirm the accepted cases.
2. **✅ RESOLVED 2026-07-31 — push-on-set confirmed.** The signature was
   changed by hand in Live's transport bar (4/4 → 6/8) and
   `get_session_state` **without** `refresh: true` immediately reported 6/8.
   The property listener fires and the mirror absorbs the push, for these two
   properties specifically. A manual edit exercises the same path an OSC set
   would — Live's property listeners fire on any change regardless of its
   source — so nothing about this is contingent on the tool existing. Smoke
   item 2 stays in the list as a regression check, not as an open question.
3. **✅ RESOLVED 2026-07-31 — beats are quarter notes, and the shipped
   formula is correct.** Context item 5's claim held up under test. With Live
   in 6/8, the song loop was set to 6.0 beats via `set_loop` and Live's
   transport-bar loop-length field read **2.0.0 — two bars**. So a bar of 6/8
   is 3.0 song-time beats, `bars × numerator × 4 / denominator` is right, and
   `record_length_beats/3` has been correct all along. This also closes the
   assumption the archived session-record plan left open
   ([archive/PLAN_session_record.md](archive/PLAN_session_record.md)), whose
   2026-07-29 verification ran only in 4/4 where the two readings coincide —
   see part 5 for making that durable in code. Neither the LOM Song page nor
   the Clip page defines the beat unit anywhere, so measurement was the only
   route. Smoke item 3 stays as a regression check.
