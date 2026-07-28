# Plan — The audition loop (device removal & bypass)

Roadmap Priority 1. Two new tools — `delete_device` and `bypass_device` — plus
description updates to `load_device`, `set_device_parameter`, and
`get_track_devices`, so the device workflow stops being one-way. "Play me a
few electric pianos and I'll pick" becomes: search → load → listen → *delete,
load the next* → keep the winner. "Drums with the compressor… and without"
becomes a bypass toggle. No vendored Python: everything rides on addresses the
installed AbletonOSC already serves.

## Context

`load_device` and `set_device_parameter` can add a device and tweak it, but
nothing can remove one — a wrong load is permanent short of the user reaching
for the mouse — and nothing can switch one off to compare with/without. The
2026-07 tool audit ranks this Med-High ("the device workflow is one-way"), and
it is the last mile of the catalog work: `search_library` finds the
candidates, this makes swapping between them possible.

Research confirmed the roadmap entry's two claims against the installed
AbletonOSC source (`~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`):

1. **`/live/track/delete_device` exists upstream.** `abletonosc/track.py`
   registers it as a track method (`methods = ["delete_device",
   "stop_all_clips"]`), dispatched through `_call_method`, which calls
   `track.delete_device(device_id)` and returns `None` — so the address
   **never replies**, success or failure. A bad index raises inside the
   callback; the exception is logged at ERROR, which the manager relays as a
   `/live/error` message Seshat doesn't correlate. Net effect: a failed
   delete is indistinguishable from a successful one at the wire level, so
   the handler must verify by re-reading the device count (see Parts).
2. **Bypass is (almost certainly) free.** The Live Object Model documents
   every device's `parameters[0]` as "Device On" — the power button in the
   device's corner — and `/live/device/set/parameter/value` can set it.
   This cannot be verified without a running Live (⚠️ Open question 1), so
   `bypass_device` guards at runtime: it reads parameter 0's display value
   *before* mutating and refuses unless it reads On/Off. A device violating
   the assumption gets a clean refusal, never a wrong parameter write.

One scope boundary research made firm: **regular tracks only**. Both
`/live/track/*` methods and `/live/device/*` resolve their track index via
`self.song.tracks[...]` (`track.py` `create_track_callback`, `device.py`
`create_device_callback`) — return and master tracks are unreachable, same
finding as the send-levels plan. Return-track device control stays on the
roadmap's "Deliberately not planned" list; both tool descriptions say
"regular tracks only".

Neither tool touches `Seshat.Session.State`: the device chain isn't mirrored
(that's the roadmap's "Session state improvements" item 1, explicitly
query-on-demand until usage says otherwise), so there is nothing to refresh.

## OSC contract

All upstream, verified in [abletonosc-api-docs.md](abletonosc-api-docs.md)
and re-verified against the installed source (`track.py`, `device.py`,
`handler.py`, `osc_server.py`):

| Address | Request args | Reply | Notes |
|---|---|---|---|
| `/live/track/delete_device` | `[track_id, device_id]` | — (never replies) | `_call_method` returns `None`; bad index raises silently |
| `/live/track/get/devices/name` | `[track_id]` | `[track_id, name, ...]` | One name per device, chain order; bare `[track_id]` for an empty chain |
| `/live/track/get/num_devices` | `[track_id]` | `[track_id, num_devices]` | The delete-verification read |
| `/live/device/get/name` | `[track_id, device_id]` | `[track_id, device_id, name]` | Doubles as the index guard (bad index → no reply) |
| `/live/device/set/parameter/value` | `[track_id, device_id, parameter_id, value]` | — | Parameter 0 = "Device On"; value 1.0 = on, 0.0 = off |
| `/live/device/get/parameter/value_string` | `[track_id, device_id, parameter_id]` | `[track_id, device_id, parameter_id, value_string]` | Expected "On"/"Off" for parameter 0 (⚠️ Open question 1) |
| `/live/device/get/parameter/value` | `[track_id, device_id, parameter_id]` | `[track_id, device_id, parameter_id, value]` | Numeric readback, 0.0/1.0 — string-ambiguity-free confirmation |

Bad indices on the getters raise `IndexError` inside the callback → no reply
(the standard upstream silent failure), so guards use `@guard_timeout` (2s)
and a timeout means "bad index or Ableton not running", per the existing hint
pattern in `Handlers`.

Ordering: AbletonOSC processes datagrams in arrival order and
`track.delete_device` runs synchronously, so a `num_devices` query sent after
the delete reads the post-delete chain — same sequencing trick as
`create_and_name_track`'s count re-query.

## Parts

### 1. `delete_device` — Definitions + Handlers

Append to `@tools` in
[lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex). Draft
description:

> Delete a device from a track's chain in Ableton Live — the undo for
> load_device, and one half of the audition loop: delete the current
> candidate, load the next, compare by ear. Track and device indices are
> 0-based — ALWAYS call get_track_devices first to confirm which index is
> which. Deleting a device shifts every later device's index down by one, so
> indices noted before the delete are stale; the reply lists the remaining
> chain with its fresh indices. Regular tracks only — devices on return or
> master tracks are out of reach. To compare with/without a device instead
> of removing it, use bypass_device.

Params: `track` (integer), `device` (integer), both required, each with a
0-indexed description pointing at `get_track_devices`.

Handler clause in [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex)
(single mutating message with read guards — Transport direct, no
`%Command{}`, same guard-first shape as `set_track_send`):

1. **Guard + name read:**
   `Transport.query("/live/track/get/devices/name", [track], @guard_timeout)`
   → `[echoed_track | names]`, and **require `echoed_track == track`** — a
   reply echoing a different track is a stale reply from an earlier
   timed-out query, the exact wrong-track answer `query_echoed/4` exists to
   catch; treat a mismatch as that helper does (reissue once, then error).
   This guard can't ride `query_echoed/4` itself only because
   `unwrap_payload/1` takes single-value payloads and this reply is a list.
   Timeout → error with a new `@device_index_hint` (see Part 3). This
   validates the track index and captures the pre-delete chain in one query.
2. **Bounds check in Elixir:** `device >= length(names)` → error naming the
   real range and the chain, **without sending the delete** (the LOM would
   raise silently; we can do better than a 2s stall):
   `"Track 2 has 2 devices (indices 0–1) — there is no device 3. Chain: 0: Operator, 1: Reverb."`
   An empty chain gets its own message.
3. **Delete:** `Transport.send_message("/live/track/delete_device", [track, device])`.
4. **Verify:** `Transport.query("/live/track/get/num_devices", [track])` →
   expect `length(names) - 1`. Count unchanged → error ("the delete did not
   go through — check Ableton and re-read with get_track_devices"). Timeout
   → "the delete was sent but confirming it timed out — verify with
   get_track_devices". This is the only defense the no-reply address allows.
   Raw `Transport.query`, deliberately not `query_echoed/4`: its canned
   timeout error says "nothing further was sent", which is false once the
   delete is on the wire — post-mutation confirms need their own wording
   (`set_device_parameter`'s readback sets the precedent).
5. **Reply** with the deleted name and the remaining chain re-indexed from
   the step-1 names (`List.delete_at(names, device)`), saving the model a
   follow-up round-trip:
   `Deleted 'Compressor' (device 1) from track 2. Remaining chain: 0: Operator, 1: Reverb — later device indices have shifted down by one.`

Formatting of the bounds-check error and the success reply goes in a pure
helper (alongside `format_device_chain/4`) so it's testable without a
Transport.

### 2. `bypass_device` — Definitions + Handlers

Draft description:

> Switch a device on or off in place. Off is a bypass: the device stays in
> the chain with all its settings intact but stops processing — the way to
> A/B a sound with and without it ("here's the drums with the compressor…
> and without"). enabled: false switches it off, enabled: true brings it
> back unchanged. Track and device indices are 0-based — call
> get_track_devices first to find the device index. This toggles the
> device's own power switch (its parameter 0, "Device On"), exactly like
> clicking the device's on/off button in Live. Bypassing an instrument
> silences its track. Regular tracks only. To remove the device from the
> chain entirely, use delete_device.

Params: `track` (integer), `device` (integer), `enabled` (boolean —
"false bypasses the device, true re-enables it"), all required.

Handler clause (Transport direct):

1. **Guard + name read:** `query_echoed("/live/device/get/name",
   [track, device], "device #{device} on track #{track}",
   @device_index_hint)` → device name. Single-value payload, so the house
   guard helper applies as-is — echo matching and the reissue-once stale
   defense come free; a timeout produces the `@device_index_hint` error.
2. **Semantic guard:** `query_echoed("/live/device/get/parameter/value_string",
   [track, device, 0], "device #{device} on track #{track}",
   @device_index_hint)` → prior display. Unless it reads
   `"On"` or `"Off"` (case-insensitive), **refuse without mutating**:
   `"Parameter 0 of 'X' reads '…', not On/Off — this device doesn't expose the standard Device On switch at parameter 0. Inspect it with get_device_parameters instead."`
   This is what turns Open question 1 from a hazard into a clean error, and
   its error message self-diagnoses (it shows the actual display string).
3. **Set:** `Transport.send_message("/live/device/set/parameter/value",
   [track, device, 0, if(enabled, do: 1.0, else: 0.0)])`.
4. **Confirm numerically:** `Transport.query("/live/device/get/parameter/value",
   [track, device, 0])` → expect 1.0/0.0 to match `enabled` (float compare
   against exact endpoints is safe for a quantized on/off parameter).
   Mismatch → error telling the model to re-check with
   get_device_parameters; timeout → "the toggle was sent but reading it back
   timed out — verify with get_device_parameters". Raw `Transport.query`
   here for the same reason as `delete_device` step 4: `query_echoed/4`'s
   timeout wording claims nothing was sent, which is false after the set.
5. **Reply**, noting a no-op politely:
   `'Compressor' (device 1 on track 2) is now Off — bypassed, settings kept.` /
   `…is now On.` / `…was already Off — nothing to do.`

### 3. Shared hint + description updates to the three neighbor tools

[lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex): new module
attribute alongside the existing hint family:

```elixir
@device_index_hint "An index that doesn't exist gets no reply from Ableton at all, so check the " <>
                     "track and device indices with get_track_devices first; failing that, check " <>
                     "Ableton is running with AbletonOSC enabled."
```

[lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex), one
sentence each (checkable against the diff):

- `load_device`: add — "A wrong or unwanted load is not permanent:
  delete_device removes it, which is how to audition candidates in place
  (load, listen, delete, load the next)."
- `set_device_parameter`: add — "To switch a whole device on or off
  (bypass), use bypass_device instead of setting parameter 0 by hand." This
  keeps its "ALWAYS call get_device_parameters first" contract
  uncontradicted — the reason bypass is a separate tool rather than a
  description trick (see below).
- `get_track_devices`: extend the resolver sentence so the index it returns
  is named as what `delete_device` and `bypass_device` consume too.

**Why a `bypass_device` tool at all** (the roadmap left it open): teaching
the trick inside `set_device_parameter`'s description would carve an
exception into an audit-rated-exemplary description ("ALWAYS call
get_device_parameters first… except parameter 0"), and the A/B loop wants a
crisp verb the model can reach for without re-deriving the trick each
session. The tool also centralises the pre-mutation On/Off guard, which a
description cannot enforce. Cost: one generated MCP component, zero new OSC
surface.

### 4. Docs — Device API preamble accuracy

[docs/abletonosc-api-docs.md](abletonosc-api-docs.md): the
`/live/track/delete_device` row already exists and is accurate (added when
the roadmap entry was researched). Two small accuracy touches:

- Device API preamble ("Instruments and effects. Query/set parameters."):
  note that all `/live/device/*` addresses resolve tracks via `song.tracks`
  — regular tracks only, per `device.py` — and that parameter 0 of every
  device is its "Device On" switch (with the ⚠️ caveat until smoke-tested).
- Track Methods table: extend the `delete_device` description cell with the
  failure mode — bad index raises silently (no reply), so callers must
  verify by re-reading `num_devices`.

### 5. Tests, tripwires, audit table

- [test/seshat/tools/definitions_test.exs](../test/seshat/tools/definitions_test.exs):
  count 46 → **48**; add `delete_device` and `bypass_device` to the
  expected-names list.
- [test/seshat/tools/handlers_test.exs](../test/seshat/tools/handlers_test.exs):
  pure formatting helpers only, per
  [.claude/rules/testing.md](../.claude/rules/testing.md) — the
  bounds-check error message (device out of range, empty chain) and the
  post-delete remaining-chain reply, driven through the extracted helper
  with literal name lists. **No guard-timeout tests**: both new handlers
  lead with a guarded Transport read, and the send-levels PR already established
  that guard-path tests get dropped rather than stall the suite.
- `Seshat.MCP.ToolsTest` parity is automatic; both names round-trip
  `Macro.camelize/1` → `Macro.underscore/1`.
- [docs/TOOL_AUDIT.md](TOOL_AUDIT.md): two new inventory rows; flip the
  "Remove / bypass / reorder a device" gap row to reordering-only; drop the
  "No delete/bypass companion" note on `set_device_parameter`; footer count
  46 → 48.
- `mix precommit` clean.

## Testing

Pure (no Ableton, runs in `mix test`):

- Definitions count + names, schema shape, MCP parity — existing suites.
- The delete-reply / bounds-error formatting helper (Part 5).
- Nothing tests through `Transport.query/3`.

Needs live Ableton (audition-loop smoke checklist — run these before trusting
the feature; items 1–2 are the ones the plan's assumptions hang on):

1. **Parameter 0 identity check** (Open question 1): on a stock Live device,
   an Instrument Rack preset, and an AU/VST plugin, `get_device_parameters`
   shows parameter 0 named "Device On" and
   `/live/device/get/parameter/value_string` reads exactly `On`/`Off`. If
   the strings differ, `bypass_device`'s step-2 guard refuses on every
   device — its error message prints the actual string, so the fix (widen
   the accepted set) is immediate.
2. `bypass_device enabled: false` on an effect is audible and the device's
   power button visibly dims in Live; `enabled: true` restores it with
   settings intact; bypassing an instrument silences the track; a repeated
   bypass reports "already Off".
3. `delete_device` removes the right device (verify in Live's UI), the reply's
   remaining chain matches `get_track_devices`, and later indices shift as
   warned.
4. Error paths: bad device index errors fast (bounds check, no 2s stall);
   bad track index errors in ≈2s with the get_track_devices hint; deleting
   from an empty chain errors cleanly.
5. `delete_device` while the track is playing its clip (Open question 2):
   no crash, audio just drops the device.
6. The full loop as a conversation: search_library for electric pianos →
   load one on a MIDI track with a clip → fire → "next" (delete + load) →
   "keep that one" — set ends with only the winner; then an effect A/B via
   bypass_device.

## Out of scope

- **Reordering the device chain** — roadmap says out until a workflow
  demands it; stays on "Deliberately not planned".
- **Return/master-track devices** — unreachable upstream (`song.tracks`
  only, verified); already parked on the roadmap. Descriptions say "regular
  tracks only".
- **Browser preview auditioning** (play a preset without loading it) —
  catalog lever №6, sequenced separately under sound catalog follow-ups.
- **Device list in `Session.State`** — roadmap "Session state improvements"
  item 1; these tools query on demand, per its own guidance.
- **A combined `swap_device` tool** (delete + load in one call) — the model
  composes `delete_device` + `load_device` fine, and a fused tool would
  duplicate `load_device`'s uri contract; revisit only if real transcripts
  show the two-call dance failing.

## Open questions

1. **Is parameter 0 "Device On", displaying exactly "On"/"Off", for every
   device kind?** — ⚠️ needs live Ableton. The LOM documents
   `parameters[0]` as Device On, and Max for Live / AU / VST devices expose
   it too, but neither the parameter identity nor Live's exact
   `value_string` spelling can be checked from source. **Assumed yes**, and
   the plan makes the assumption safe rather than load-bearing:
   `bypass_device` reads parameter 0's display *before* mutating and
   refuses (printing the actual string) unless it reads On/Off
   case-insensitively — a violation is a clean, self-diagnosing error, not
   a wrong write. Smoke item 1 is the first thing the implementer should
   run with Ableton open; if Live spells the strings differently, widening
   the accepted set is a one-line change.
2. **Deleting a device on a playing track** — ⚠️ needs live Ableton.
   Whether Live glitches, clicks, or handles it gracefully is unknowable
   from source; no design decision depends on it (the delete either happens
   — count drops — or it doesn't). Smoke item 5 observes it; if it's ugly,
   the fix is a description sentence advising to stop the clip first, not a
   code change.
