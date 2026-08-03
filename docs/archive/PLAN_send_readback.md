# Plan: `set_track_send` reports an outcome it observed

> **Archived 2026-08-03 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The read-back path landed as
> planned — `do_call("set_track_send", …)` in
> [../../lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)
> now reads `/live/track/get/send` back through the shared `confirm_send/5`
> helper and reports confirmed, mismatch, or unconfirmed rather than
> asserting success. The live verification this plan called for
> (`smoke_tests/auto/sends.md`) was blocked by the environment that shipped
> it — a running Seshat instance held the OSC reply port on stale code — and
> was not run before archiving; it remains a pre-merge gate, tracked in the
> PR. No follow-up beyond what this plan already named in its Out of scope
> section.

Roadmap item: **"`set_track_send` reports a request, not an outcome"**
(currently #1).

## Context

`set_track_send` guards, fires, and then asserts:

```elixir
:ok <- Transport.send_message("/live/track/set/send", [track, send_index, value / 1.0]) do
  {:ok, "Set send #{send_letter(send_index)}… on track #{track} to #{value} (was #{format_number(old)})"}
```

([handlers.ex:2010-2027](../../lib/seshat/tools/handlers.ex#L2010-L2027), TODO! at
[2003](../../lib/seshat/tools/handlers.ex#L2003).) The pre-read
(`query_echoed/4` on `/live/track/get/send`) proves the track and send indices
exist and supplies the "was" value; nothing accounts for the *after*. The
setter is silent, and — the 2026-08-03 integration review's counter-review
correction (§1) — **no send listener exists in `track.py` and sends are
outside the mirror**, so this is the one mixer value where a rejected or lost
set is never corrected anywhere, ever: not by a push, not by a later
`get_session_state`. The reply is the only account the model gets, and today
it is asserted, not observed.

The failure that reaches this in practice is a dropped or swallowed datagram:
the reply says "Set send A … to 0.4", the send still sits at its old level,
and no later read happens because the model was told it worked. (A rejected
*index* cannot reach the setter — the guard already refuses it — and an
out-of-range *value* cannot either: `Seshat.Tools.Validation` enforces the
schema's 0.0–1.0 bound on every call path before dispatch.)

**Decision: read the value back, don't hedge the wording.** The roadmap entry
offered both shipped patterns. The hedge (`undo`/`redo`'s "confirms the
request was sent") is the honest floor, but here it routes every verification
to `get_track_sends` — which costs **two serialized queries per send on the
track** (name + level, up to ~25 round trips; roadmap "Bulk reads vs.
per-address queries"), invoked by a model that has just been told to be
suspicious. The read-back is **one** ~100ms guarded query on a tool that
already pays one, it produces an observed outcome instead of a stated
uncertainty, and it is the established Tier-C pattern for exactly this
situation: `set_device_parameter` reads its value string back through
`read_back_value/2`, `set_clip_properties` re-reads every write and reports
"Live reports X, not the Y that was sent", `arm_track/1` exists because
`/live/track/set/arm` is silent and Live can refuse. Roadmap #6's "keep
ordinary parameter setters fire-and-forget" rule is not violated: that rule's
stated basis is that each such setter's listener pushes Live's accepted value
into the mirror, and sends are precisely the mixer value with no listener —
the review's Tier correction, and the reason this item exists.

`set_track_send` is called a few times per session, not in bursts; one extra
guarded query does not meaningfully add to the head-of-line cost roadmap
item "Bulk reads vs. per-address queries" tracks.

**Measured 2026-08-03, against live Ableton (Live 12, running set).** Via the
running Seshat server's MCP tools: created a temporary return track, set track
0's send A to `0.37` (not exactly representable in float32), and read it back —
`get_track_sends` reported `0.37` exactly at `format_number/1`'s 4-decimal
rounding, which is the same precision the comparison below uses. Live stores
and returns what was sent; no quantization or clamping was observed at this
precision. Probe return track deleted afterwards; set restored to its prior
state.

## OSC contract

No new addresses, **no fork change, no `mix abletonosc.install`, no Live
restart.** Both addresses are upstream `track.py` and already in use by this
exact clause.

| Address | Request args | Reply | Source |
|---|---|---|---|
| `/live/track/get/send` | `track_id, send_id` | `track_id, send_id, value` | upstream `track.py` `track_get_send` |
| `/live/track/set/send` | `track_id, send_id, value` | **none, ever** | upstream `track.py` `track_set_send` |

Verified in [docs/abletonosc-api-docs.md](../abletonosc-api-docs.md) (Track
Properties / Track Setters tables) and against the fork source at
[priv/AbletonOSC/abletonosc/track.py:94-103](../../priv/AbletonOSC/abletonosc/track.py#L94-L103):
the getter returns `(send_id, value)` and `create_track_callback` prefixes
`track_id`, so the reply echoes **both** indices and the payload behind the
echo is the bare `[value]` — exactly the shape `read_back_value/2` already
decodes (`query_correlated/4` + `unwrap_payload/1`). A bad index raises
`IndexError` inside the callback and arrives as a structured `/live/error`,
which `query_echoed/4` (the pre-guard) renders in Live's own words; for the
silent *setter* the same `/live/error` matches no in-flight query and answers
nobody, which is why the read-back is the only account of the set available.

Ordering is the one wire property this leans on: the read-back datagram leaves
after the set and AbletonOSC processes datagrams in arrival order — the same
property `delete_device`'s count re-read and `set_device_parameter`'s
read-back already rely on (comment at
[handlers.ex:2635](../../lib/seshat/tools/handlers.ex#L2635); the latter's happy
path was live-verified in the echo-checks work, 2026-08-03). See Open
questions for the residual.

## Part 1 — the read-back in `Handlers`

[lib/seshat/tools/handlers.ex:2003-2027](../../lib/seshat/tools/handlers.ex#L2003-L2027)
— the single `do_call("set_track_send", …)` clause. The guard stays exactly as
it is (it pre-validates both indices with Live's own rejection wording and
supplies `old`); after the send, read the level back and branch three ways:

```elixir
with {:ok, old} <- query_echoed("/live/track/get/send", [track, send_index], subject, @send_index_hint),
     :ok <- Transport.send_message("/live/track/set/send", [track, send_index, value / 1.0]) do
  case read_back_value("/live/track/get/send", [track, send_index]) do
    {:ok, got} when is_number(got) -> …compare…
    _ -> …unconfirmed…
  end
end
```

- **Confirmed** — `Float.round(value / 1.0, 4) == Float.round(got / 1.0, 4)`:
  the existing sentence plus the observation, e.g.
  `"Set send A (\"Reverb\") on track 0 to 0.37 (was 0.0), confirmed by reading
  it back."`
  The 4-decimal comparison is `clip_value_matches?/3`'s shipped precedent
  ([handlers.ex:4817-4818](../../lib/seshat/tools/handlers.ex#L4817-L4818)) and
  absorbs the float32 wire truncation (OSC `f` is 32-bit; `0.37` returns as
  `0.3700000047683716`) without a new float32 helper — do not compare with
  `==`.
- **Mismatch** — an answered, correlated read that disagrees:
  `{:error, "Sent send A (\"Reverb\") on track 0 the value 0.37, but Live
  reports 0.0 (was 0.0) — the set did not land. Try once more, and if it still
  does not land, tell the user."}` The wording follows `clip_write_line/4`'s
  "Live reports X, not the Y that was sent". Naming the "was" value lets the
  model (and the user) see the dropped-datagram case at a glance: `got == old`.
  A non-number `got` (a shape this code can't read) takes the unconfirmed
  branch, not this one.
- **Unconfirmed** — `read_back_value/2` returned `:unconfirmed` (stale twice,
  timeout, or any error): `{:error, "The set was sent but reading send A on
  track 0 back did not confirm it — verify with get_track_sends."}` — the
  `set_vendored_parameter/7` wording
  ([handlers.ex:4192-4195](../../lib/seshat/tools/handlers.ex#L4192-L4195)).

`read_back_value/2`
([handlers.ex:4216-4223](../../lib/seshat/tools/handlers.ex#L4216-L4223)) is used
as-is: it already carries the echo check (both indices must come back), the
reissue-once stale defence, its own `catch :exit`, and the post-mutation
framing ("was not verified", never "nothing was sent"). No new query helper.

Keep a residual `catch :exit` on the clause mirroring `set_device_parameter`'s
([handlers.ex:3065-3073](../../lib/seshat/tools/handlers.ex#L3065-L3073)): the
guard and the read-back each catch their own exits, so what is left is the
send itself losing the transport — word it "The set was sent but reading the
level back timed out — verify with get_track_sends."

Replace the TODO! comment block at
[handlers.ex:2003-2009](../../lib/seshat/tools/handlers.ex#L2003-L2009) with a
comment stating why this one mixer setter reads back when its siblings don't
(no send listener, sends outside the mirror — nothing else ever corrects it).

Checkable: no code path in this clause may return `{:ok, …}` without an
answered, correlated read-back agreeing at 4 decimals; the mismatch reply must
name both the requested and the observed value; the unconfirmed replies must
say the set *was sent* and route to `get_track_sends`.

## Part 2 — tests

`test/seshat/tools/handlers_test.exs`, using the existing test-local `OSCSink`
pattern (the narrow handler-test exception in
[.claude/rules/testing.md](../../.claude/rules/testing.md) — the sink supplies
every reply, nothing waits on Ableton). The `scripted_trace`/`guarded_trace`
helpers from the echo-checks tests are the shape to copy.

1. **Happy path:** guard answers `[0, 0, 0.0]`, read-back answers
   `[0, 0, 0.37]` → `{:ok, message}`, message says confirmed; both the set and
   two gets appear on the wire in order.
2. **Float32 truncation still confirms:** call with `value: 0.37`, read-back
   answers the widened `0.3700000047683716` → confirmed, not mismatch. This
   pins the 4-decimal comparison against the wire's 32-bit floats.
3. **Mismatch:** read-back answers `[0, 0, 0.0]` (the old value) →
   `{:error, message}`; message names `0.37` and `0.0` and does not say "Set".
4. **Straggler on the read-back address:** first read-back reply echoes the
   wrong indices (`[9, 0, 0.9]`), second answers correctly → confirmed, and
   the trace shows the get reissued (three gets total including the guard).
5. **Stale twice:** both read-back replies mis-echo → the unconfirmed
   `{:error, message}` ("was sent … did not confirm"), never the straggler's
   value in an ok.
6. **Existing guard-rejection test**
   ([handlers_test.exs:709-739](../../test/seshat/tools/handlers_test.exs#L709-L739))
   must stay green unchanged — nothing before the set moved.

The unanswered-read-back path (2s `@guard_timeout` wait) is deliberately not
tested, matching the existing `read_back_value/2` call sites — the stale-twice
test covers the same reply branch without the wall-clock cost.

No tool added, **no tool-count bump** in `definitions_test.exs`.

## Part 3 — nothing else moves

Stated so the diff is checkable against it:

- **`Seshat.Tools.Definitions` unchanged.** The current description asserts
  nothing about confirmation, so it contradicts nothing; the reply strings
  carry the outcome and the mismatch reply carries its own next step. (The
  `undo`/`redo` precedent needed description text because its *refusal* had to
  stop a retry loop; there is no refusal here.)
- **No `Session.State` change** — sends stay outside the mirror; that boundary
  is roadmap territory ("Bulk reads vs. per-address queries", "Device list per
  track in session state").
- **No docs change** — [abletonosc-api-docs.md](../abletonosc-api-docs.md)'s
  "nothing pushes a send's accepted value into the mirror" note (Track API
  intro) remains true and is the reason for the read-back.

## Testing

All of Part 2 runs pure under `mix test` — the sink plays AbletonOSC, nothing
reaches a real Live. What `mix test` cannot show: that a real
`/live/track/get/send` issued immediately after `/live/track/set/send` (same
process, microseconds apart, likely the same AbletonOSC tick) returns the
*new* value rather than racing the set. That is the Live verification's job.

## Live verification

Nothing in `mix test` reaches any of this — sends had **zero** live coverage
before this change, so both tests below are new, written by `/smoke-write`
into a new `auto/` file (one file per subsystem; no existing file covered the
send/mixer surface). Run them with `/smoke-test`. No reinstall precondition:
both addresses are upstream and already installed.

- `smoke_tests/auto/sends.md § A send set is confirmed by its own read-back` —
  the whole feature: a non-float32-exact value, both boundary values, and an
  idempotent repeat must each come back *confirmed*, verified independently
  through `get_track_sends` afterwards. Every confirmed reply is also the
  proof of Open question 1 (same-tick set-then-get ordering on real
  AbletonOSC), which no pure test can supply.
- `smoke_tests/auto/sends.md § A bad send index is refused before the set` —
  the guard path against real Live's structured `/live/error`: fast, in
  Live's own words, nothing mutated.

**Uncovered:** the mismatch branch (no way to make real Live drop exactly one
loopback datagram on demand — pinned pure in Part 2, wording asserted there),
and the unanswered-read-back timeout path (same reason; its reply branch is
shared with stale-twice, which Part 2 pins).

## Out of scope

- **`get_track_sends`' 2-per-send query cost** — stays with "Bulk reads vs.
  per-address queries".
- **`read_back_value/2` collapsing `{:error, {:live_error, …}}` to
  `:unconfirmed`** — queued as "`set_device_parameter` on a regular track
  loses Live's rejection message". For this clause it is unreachable in
  practice (the guard has just validated both indices ~200ms earlier), and
  widening the helper here would preempt that item's fix.
- **`set_track_arm` / `set_time_signature`'s unverified replies** — named by
  the same review, staying with "Verify destructive mutations before reporting
  success".
- **A send listener / mirroring sends** — a fork change and a mirror-boundary
  decision, neither needed once the reply is observed.

## Open questions

1. ⚠️ **Does the read-back issued microseconds after the set return the new
   value on real AbletonOSC?** Effectively yes, on three converging pieces of
   evidence, but only for the sibling mechanism, not this clause itself:
   documented in-order datagram processing
   ([handlers.ex:2635](../../lib/seshat/tools/handlers.ex#L2635));
   `set_device_parameter`'s identical in-process set-then-read, **live-verified
   2026-08-03** in the echo-checks PR review ("Dry/Wet → 0.75 replied 'it now
   reads 75 %'", [PLAN_echo_checks.md](PLAN_echo_checks.md)
   Live verification) — and sends *are* `DeviceParameter`s on
   `mixer_device.sends`, the same LOM object kind; and today's own measurement,
   which confirmed set-then-read returns the new value at ~1s spacing.
   *Why not fully resolved now:* the in-process timing on this exact address
   pair only exists once the code does; no probe reproduces it beforehand.
   *Assumption:* it behaves like `set_device_parameter`'s read-back — no
   observed counterexample anywhere in the codebase's read-back history.
   *Resolution:* `smoke_tests/auto/sends.md § A send set is confirmed by its
   own read-back` is the check, run by `/smoke-test` before this ships.

No other question stayed open: value fidelity (does Live return what was set,
at the comparison's precision) was measured against the running Live today —
see Context — and the reply-shape and echo questions are settled by the fork
source read directly.
