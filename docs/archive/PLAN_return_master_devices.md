# Plan — Devices on return and master tracks

> **Archived 2026-07-31 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The feature lives in
> `Seshat.Tools.Definitions`/`Handlers`/`FollowCam`, `Seshat.Session.State`,
> and the fork's `abletonosc/return_track.py` and `abletonosc/browser.py`
> (see `priv/AbletonOSC/SESHAT.md`). No follow-ups from this plan are open on
> the roadmap.

Roadmap: "Devices on return and master tracks — make the sends system
self-serve." Extends the six existing device tools (`load_device`,
`get_track_devices`, `get_device_parameters`, `set_device_parameter`,
`delete_device`, `bypass_device`) with an optional `target` parameter reaching
return and master chains, adds five small mixer tools
(`set_return_track_pan`, `set_return_track_mute`, `set_return_track_solo`,
`set_master_pan`, `set_cue_volume`), and mirrors the new mixer state into
`Seshat.Session.State`. The whole OSC half is ordinary fork commits in two
files we already own (`return_track.py`, `browser.py`) — no upstream file is
touched. After this, "make a reverb return and send the vocal to it" works end
to end without the user touching Live.

## Context

`create_return_track` ships an empty return, and its own reply apologizes for
it: "Seshat cannot load a device onto a return track, so ask the user to drag
one on in Live." Every send into an empty return is silent, so the sends
system — otherwise complete since the send-levels work
([archive/PLAN_send_levels.md](PLAN_send_levels.md)) — still has a
human step in the middle of its headline workflow. The 2026-07-31 external
tool audit ([archive/TOOL_AUDIT_V2.md](TOOL_AUDIT_V2.md)) made
"let devices reach return & master tracks" its top recommendation, which is
exactly the revisit condition the Deliberately-not-planned entry was waiting
on. The same audit marked `get_track_devices`, `load_device`, `delete_device`,
`bypass_device`, and `create_return_track` as **Extend** rows.

The roadmap entry absorbs the former "Return/master mixer completeness" item:
return pan/mute/solo, master pan, and cue volume ride along, because they land
in the same fork file the device surface needs anyway (`return_track.py`), and
because "first-class return tracks" is one package, not two.

What research confirmed and changed:

1. **Nothing upstream reaches these chains.** Every `/live/device/*` address
   resolves its track through `song.tracks`
   (`priv/AbletonOSC/abletonosc/device.py`, `create_device_callback`), as do
   `/live/track/delete_device` and `/live/track/get/devices/*` in `track.py`,
   and `/live/view/set/selected_device` in `view.py`. Returns live in
   `song.return_tracks` and the master in `song.master_track`. So the whole
   device half is vendored addresses — but in files that are already ours.
2. **The load mechanism generalizes.** `browser.py`'s `_load_item` works by
   `song.view.selected_track = track` then
   `Live.Application.get_application().browser.load_item(item)`, and its
   `_loaded_device` diff (`before` list vs. after) works on any track object.
   `/live/return_track/select` already proves returns can be selected, and the
   master is selectable the same way (measured 2026-07-31). The
   browser-index machinery (`_index_cache`, `_find_item`) lives in
   `BrowserHandler`, so the load endpoints belong in `browser.py`; the rest
   belongs in `return_track.py`.
3. **The LOM details for the mixer half are already confirmed** (2026-07-28 PR
   review, recorded in the roadmap entry): return mute/solo are plain
   listenable `Track` properties; master pan is `mixer_device.panning` and cue
   volume is `mixer_device.cue_volume`, both `DeviceParameter`s like volume;
   the master has no mute/solo/arm.
4. **Tool surface: extend the device tools, keep level setters separate.** The
   roadmap left this open. The audit settles both halves: it endorsed the
   existing split level-setter family explicitly ("`set_track_volume`,
   `set_track_send`, `set_return_track_volume`, `set_master_volume` all move a
   fader but target different objects… Correctly separate"), and marked the
   device tools "Extend". So: the six device tools gain one optional `target`
   parameter (enum `"return"` / `"master"`; omitted = regular track) rather
   than forking into twelve parallel tools — the device tools carry heavy
   shared workflow prose (audition loop, index discipline) that twelve copies
   would duplicate, and ~12 more tools is real schema weight. The new mixer
   setters are separate small tools, following `set_return_track_volume`'s
   precedent exactly.
5. **A Python half means the usual costs**: one submodule commit + a pin bump
   here, `mix abletonosc.install` + Live restart for the user, and nothing in
   `mix test` executes it — every Python behaviour below is a `/smoke-test`
   item by construction.

## OSC contract

### Existing addresses used unchanged

Verified in [abletonosc-api-docs.md](../abletonosc-api-docs.md):

| Address | Request | Reply | Use here |
|---|---|---|---|
| `/live/browser/load_item` | `[track_index, uri]` | `[track_index, uri, "ok", name, device_index]` / `[…, "error", msg]` | Regular-track loads, untouched |
| `/live/return_track/get/count` | `[]` | `[count]` | Install probe, unchanged |
| `/live/return_track/select` | `[index]` | — | Follow-cam fallback when a loaded device isn't on the chain yet (`device_index == -1`) |

### New vendored addresses — `return_track.py`, mixer surface

All getters with an index follow the fork's envelope rule
(`[…, "ok", value]` / `[…, "error", message]`, index echoed); index-less
master getters reply with the bare value; setters and listeners are silent on
a bad index. Listeners push the bare pair (or bare value for master) on the
matching `get/` address, once immediately on subscribe.

| Address | Request | Reply / push | Notes |
|---|---|---|---|
| `/live/return_track/get/panning` | `[index]` | `[index, "ok", pan]` / `[index, "error", msg]` | `mixer_device.panning.value`, −1.0…1.0 |
| `/live/return_track/set/panning` | `[index, pan]` | — | |
| `/live/return_track/start_listen/panning` | `[index]` | push `[index, pan]` on `get/panning` | DeviceParameter listener (see key note below) |
| `/live/return_track/stop_listen/panning` | `[index]` | — | |
| `/live/return_track/get/mute` | `[index]` | `[index, "ok", 0\|1]` / error | Plain `Track.mute` |
| `/live/return_track/set/mute` | `[index, 0\|1]` | — | |
| `/live/return_track/start_listen/mute` | `[index]` | push `[index, 0\|1]` | Base-class `_start_listen(track, "mute", (index,))` — derives the address itself |
| `/live/return_track/stop_listen/mute` | `[index]` | — | |
| `/live/return_track/get/solo` | `[index]` | `[index, "ok", 0\|1]` / error | |
| `/live/return_track/set/solo` | `[index, 0\|1]` | — | |
| `/live/return_track/start_listen/solo` | `[index]` | push `[index, 0\|1]` | |
| `/live/return_track/stop_listen/solo` | `[index]` | — | |
| `/live/master/get/panning` | `[]` | `[pan]` | `master_track.mixer_device.panning.value` |
| `/live/master/set/panning` | `[pan]` | — | |
| `/live/master/start_listen/panning` | `[]` | push `[pan]` | |
| `/live/master/stop_listen/panning` | `[]` | — | |
| `/live/master/get/cue_volume` | `[]` | `[value]` | `master_track.mixer_device.cue_volume.value` |
| `/live/master/set/cue_volume` | `[value]` | — | |
| `/live/master/start_listen/cue_volume` | `[]` | push `[value]` | |
| `/live/master/stop_listen/cue_volume` | `[]` | — | |
| `/live/master/select` | `[]` | — | `song.view.selected_track = master_track`; silent (steering). Measured 2026-07-31: the assignment sticks |
| `/live/return_track/select_device` | `[index, device]` | — | `song.view.select_device(rt.devices[device])`; silent (steering). Measured 2026-07-31: selects the device *and* shows `Detail/DeviceChain` |
| `/live/master/select_device` | `[device]` | — | Ditto for the master chain |

**Listener-key note (load-bearing):** the handler's DeviceParameter listeners
are registered under `("value", listener_params)` because `_stop_listen`
derives `remove_value_listener` from the prop. Today volume uses
`listener_params = (index,)` / `("master",)`. Panning and cue volume are also
DeviceParameters, so keeping that scheme would collide keys. Generalize
`_listen_to_volume` into `_listen_to_mixer_param` and discriminate the key by
property: `(index, "volume")`, `(index, "panning")`, `("master", "volume")`,
`("master", "panning")`, `("master", "cue_volume")` — migrating the existing
volume call sites to the new scheme in the same commit (keys are internal;
the install is wholesale and Live restarts, so no compat concern).

### New vendored addresses — `return_track.py`, device surface

| Address | Request | Reply | Notes |
|---|---|---|---|
| `/live/return_track/get/devices` | `[index]` | `[index, "ok", count, name₀, type₀, class₀, …]` / `[index, "error", msg]` | One query replaces upstream's three (`devices/name|type|class_name`); `type` is the same int as upstream's (1=audio_effect, 2=instrument, 4=midi_effect) |
| `/live/master/get/devices` | `[]` | `[count, name₀, type₀, class₀, …]` | No index → no failure path → bare reply, count first so it stays parseable |
| `/live/return_track/device/get/name` | `[index, device]` | `[index, device, "ok", name]` / error | Cheap guard for bypass |
| `/live/master/device/get/name` | `[device]` | `[device, "ok", name]` / error | Takes an index → envelope |
| `/live/return_track/device/get/parameters` | `[index, device]` | `[index, device, "ok", device_name, count, (pname, value, min, max)×N]` / error | One query replaces upstream's five |
| `/live/master/device/get/parameters` | `[device]` | `[device, "ok", device_name, count, …]` / error | |
| `/live/return_track/device/get/parameter/value` | `[index, device, param]` | `[index, device, param, "ok", value]` / error | Numeric read-back for bypass confirmation |
| `/live/master/device/get/parameter/value` | `[device, param]` | `[device, param, "ok", value]` / error | |
| `/live/return_track/device/get/parameter/value_string` | `[index, device, param]` | `[index, device, param, "ok", str]` / error | Read-back for set + bypass guard |
| `/live/master/device/get/parameter/value_string` | `[device, param]` | `[device, param, "ok", str]` / error | |
| `/live/return_track/device/set/parameter/value` | `[index, device, param, value]` | — | Silent setter; every caller reads back |
| `/live/master/device/set/parameter/value` | `[device, param, value]` | — | |
| `/live/return_track/delete_device` | `[index, device]` | `[index, device, "ok", remaining]` / `[index, device, "error", msg]` | **Replies**, unlike upstream's `/live/track/delete_device` — we own it, a delete has a failure path worth reporting, and it spares the count sandwich |
| `/live/master/delete_device` | `[device]` | `[device, "ok", remaining]` / error | |

Datagram size: the combined parameters reply for an Operator-class device
(~130 params) is ~5–6 KB; both `Transport` (`recbuf: 65_536`) and the Python
sender handle up to the UDP maximum, and upstream's own list getters already
ship multi-KB datagrams. A pathological plugin with >~1,500 parameters could
exceed 65 KB — the same ceiling upstream's separate list getters already
approach, accepted.

### New vendored addresses — `browser.py`, load endpoints

| Address | Request | Reply | Notes |
|---|---|---|---|
| `/live/browser/load_item_on_return` | `[return_index, uri]` | `[return_index, uri, "ok", return_name, device_name, device_index]` / `[return_index, uri, "error", msg]` | Same select-then-load, `_find_item`, and `_loaded_device` diff as `_load_item`, resolving through `song.return_tracks`; both names are needed because Live may rename the return as the first device lands |
| `/live/browser/load_item_on_master` | `[uri]` | `[uri, "ok", name, device_index]` / `[uri, "error", msg]` | Resolves `song.master_track` |

Separate addresses rather than a widened `/live/browser/load_item`, so the
shipped address keeps its exact shape and the reply arity itself says which
space was targeted. Both must also guard against the load *silently doing
something else*: `browser.load_item` with a non-effect item selected on a
return/master **does** create a stray MIDI track instead of erroring —
measured 2026-07-31 on both a return and the master, with nothing landing on
the target chain. So the guard is required for correctness, not caution:
snapshot `len(song.tracks)` before the load and report an error naming the
stray track if the count changed, and report an error when the device diff
finds nothing landed on the target chain. Do not auto-delete the stray track —
report it and let the model offer `delete_track` (the `create_project` lesson).

## Parts

### 1. Fork — mixer surface in `return_track.py`

`priv/AbletonOSC/abletonosc/return_track.py`: register the 23 mixer/steering
addresses from the contract (panning, mute, solo per return; master panning
and cue volume; `master/select`, both `select_device`s), reusing `_return_track`
for lookup, the base `_start_listen` for mute/solo, and the generalized
`_listen_to_mixer_param` (with the discriminated listener keys above) for the
three DeviceParameters. Extend the file's header comment with the new
addresses. Update `SESHAT.md` ("Seshat's own handlers" section) in the same
submodule commit.

### 2. Fork — device surface in `return_track.py`

Same file: the 14 device addresses from the contract. Add a
`_return_device(params, operation)` lookup mirroring `_return_track` (resolve
return, then bounds-check `device` against `track.devices`, echoing both
indices in error envelopes) and a master twin. `delete_device` calls
`track.delete_device(device)` and replies with the re-read count.
Parameter access is `device.parameters[i]` exactly as upstream's `device.py`.

### 3. Fork — load endpoints in `browser.py`

`priv/AbletonOSC/abletonosc/browser.py`: `_load_item_on_return` /
`_load_item_on_master` per the contract, sharing `_find_item` /
`_loaded_device` with `_load_item` (extract the common tail into a helper so
the three loads differ only in target resolution and reply prefix). Include
the measured stray-track guard. `_load_item_on_return` must also
re-read `track.name` *after* the load and carry it in the reply: Live renames
an empty return when its first device lands (`A-Return` → `A-Reverb`,
measured 2026-07-31), so any name echoed from before the load is wrong. Its
success reply therefore carries both that post-load return name and the loaded
device name, in the exact order declared in the contract. Update the
`browser.py` entry in `SESHAT.md` with both new endpoints and their reply
shapes.
Parts 1–3 are one submodule commit,
pushed, with the pin bump landing in the same Seshat commit as Parts 4–9
(two-commit fork workflow per [.claude/rules/osc.md](../../.claude/rules/osc.md)).

### 4. Docs — `abletonosc-api-docs.md`

Add every new address to the Return Track & Master API section (mixer +
device tables) and the two load endpoints to the Browser API section, with the
reply-shape bullets extended: the replying `delete_device` exception to
"setters are silent" (it is a method with a failure path, like `load_item`),
the combined-list getters, and the master's bare-reply getters.
Two literal statements in that file go stale with this change and must be
edited in the same pass: the Return Track & Master API intro's "⚠️ These
fourteen addresses do **not** exist in stock AbletonOSC" (update it to
fifty-one),
and the Browser API bullet "Regular tracks only (`song.tracks`) — return and
master tracks aren't addressable here", which now routes to
`load_item_on_return` / `load_item_on_master` instead.
`vendored_addresses_test` enforces this file in both directions, so this part
is not optional.

### 5. `Session.State` — mirror the new mixer state

[lib/seshat/session/state.ex](../../lib/seshat/session/state.ex):

- Return entries grow to `%{index, name, volume, pan, mute, solo}`; `master`
  grows to `%{volume, pan, cue_volume}`. Failed reads stay `nil` (the
  stated-unknown rule — never fabricate).
- `read_return_tracks/2` reads the three new per-return values;
  `read_master/1` reads panning and cue volume (probe pattern unchanged).
- `subscribe_return_listeners/1` subscribes the new listeners;
  `handle_info` clauses accept both the push arity and the envelope query
  arity for `get/panning`, `get/mute`, `get/solo` (mirroring the
  name/volume pairs) and the bare master pushes for `get/panning` /
  `get/cue_volume`. Normalize mute/solo ints to booleans at the boundary.
- `Seshat.Tools.Handlers.format_return_tracks/2` rendering: return lines gain
  pan/mute/solo in the same style as regular track lines; the master line gains
  pan and cue volume.

### 6. Five mixer tools — Definitions, Handlers, count bump

Shape of `set_return_track_volume` throughout: guard getter → silent setter →
`State.refresh()` → reply naming old and new. Bounds in the schema: pan
−1.0…1.0; cue volume 0.0…1.0; mute/solo booleans (`muted`/`soloed`, matching
the track tools). Draft descriptions:

- **`set_return_track_pan`** — "Set the pan of a return track — where the
  shared effect sits in the stereo field. Return-track indices are 0-based and
  separate from regular tracks: return 0 = send A's return (see
  get_session_state). -1.0 = hard left, 0.0 = center, 1.0 = hard right.
  For a regular track's pan use set_track_pan. Requires Seshat's AbletonOSC
  extension (mix abletonosc.install)."
- **`set_return_track_mute`** — "Mute or unmute a return track — silences the
  shared effect (reverb, delay) for every track feeding it, without touching
  the sends. muted: true silences, false brings it back. Return-track indices
  are 0-based and separate from regular tracks: return 0 = send A (see
  get_session_state). For a regular track use set_track_mute. Requires
  Seshat's AbletonOSC extension (mix abletonosc.install)."
- **`set_return_track_solo`** — same shape ("hear the effect channel alone —
  useful when dialing in a reverb").
- **`set_master_pan`** — "Set the master track's stereo pan in Ableton Live.
  -1.0 = hard left, 0.0 = center (where nearly every mix should stay), 1.0 =
  hard right. Prefer track pans for placement; this tilts the entire mix.
  Requires Seshat's AbletonOSC extension (mix abletonosc.install)."
- **`set_cue_volume`** — "Set the cue (preview/headphone) volume on Ableton
  Live's master track — the level of browser previews and of anything cued,
  separate from the master output the audience hears. 0.0 = silent, 1.0 =
  maximum. If a browser preview is inaudible, this dial is the likely reason.
  Requires Seshat's AbletonOSC extension (mix abletonosc.install)."

Handlers: `set_master_pan`/`set_cue_volume` guard with the bare master
getters (the `master_volume/0` helper pattern); the return tools guard with
`query_echoed` + `@return_extension_hint`. Bump `definitions_test.exs` from
60 to 65.

### 7. Extend the six device tools with `target`

[lib/seshat/tools/definitions.ex](../../lib/seshat/tools/definitions.ex): each of
`load_device`, `get_track_devices`, `get_device_parameters`,
`set_device_parameter`, `delete_device`, `bypass_device` gains one optional
parameter (identical across all six):

```
"target" => %{
  type: "string",
  enum: ["return", "master"],
  description:
    "Aim this call at a return track's device chain ('return') or the " <>
    "master track's ('master') instead of a regular track's. With " <>
    "'return', track is the 0-based return-track index (return 0 = send " <>
    "A — see get_session_state). With 'master', track is ignored — pass " <>
    "0. Omit for regular tracks."
}
```

`track` stays required with an unchanged schema (the master "pass 0" wart is
one documented sentence; keeping `track` required preserves the wire contract
for the overwhelmingly common regular-track case). Description edits: delete
both "Regular tracks only" sentences (`delete_device`, `bypass_device`); add
one shared sentence to all six, e.g. "Return and master chains are reachable
too — pass target: 'return' (with the return index in track) or target:
'master'."; `load_device` additionally: "On returns and the master, load
audio effects only — that is all Live allows there."

[lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex): each clause
dispatches on `params["target"]` (`nil` → existing flow, untouched):

- `load_device` — `"return"` → query `/live/browser/load_item_on_return
  [track, uri]` at `@load_timeout`; `"master"` → `/live/browser/load_item_on_master
  [uri]`. Both: `Catalog.record_load(uri)` on ok, then
  `FollowCam.steer("load_device", %{return: track, device: device})` /
  `%{master: true, device: device}`. Parse the return endpoint's distinct
  `return_name, device_name` fields and reply with both the chain and what
  landed (for example, `Loaded 'Reverb' onto return track 0 'A-Reverb'`);
  the master reply names the device and the master chain.
- `get_track_devices` — one query to `…/get/devices`; split the flat triples
  into parallel name/type/class lists first, rejecting a tail whose length is
  not divisible by three or whose triple count disagrees with the reply's
  declared `count`. Generalize `format_device_chain` to take a chain label so
  its existing regular-track output stays unchanged while return and master
  replies do not falsely say `track 0`.
- `get_device_parameters` — one query to `…/device/get/parameters`, reuse
  `format_device_parameters` after splitting the flat parameter tail into
  parallel name/value/min/max lists and rejecting a tail whose length is not
  divisible by four or whose quadruple count disagrees with the declared
  `count`. Generalize that formatter's location label for the same reason.
- `set_device_parameter` — first guard the device/parameter with
  `…/device/get/parameter/value_string`, then send the silent setter via
  `…/device/set/parameter/value`, then read the same getter back. The pre-read
  is required by the vendored-setter rule: a bad index must be refused before
  anything is sent, not discovered only after a silent mutation attempt.
- `delete_device` — read `…/get/devices` for names + Elixir bounds check, then
  query the replying delete, check `remaining == length(names) - 1`, steer,
  and reply with the fresh chain. Generalize `ensure_device_index`,
  `device_out_of_range_error`, and `deleted_device_reply` around the same chain
  label; reusing their current track-only strings would misreport return 0 as
  regular track 0 and the master as a numbered track.
- `bypass_device` — `…/device/get/name`, `…/device/get/parameter/value_string`
  param 0, existing `ensure_on_off_switch`, set param 0, read back — the
  regular flow with addresses swapped. Confirmation uses the new numeric
  `…/device/get/parameter/value` and compares against exactly `0.0`/`1.0`,
  preserving `confirm_device_enabled`'s existing guarantee that display-label
  spelling cannot make a successful toggle look failed (or vice versa).
  Generalize the bypass/no-op reply helpers to use the same chain labels.

Every return/master timeout or unexpected reply uses
`@return_extension_hint` / `extension_missing_error` and names the targeted
chain; none may fall through to the existing regular-track timeout text. That
is what makes a stale install distinguishable in smoke item 7.

All new addresses appear as **string literals** in these clauses (the
`vendored_addresses_test` grep is blind to interpolation).

### 8. Follow cam — steer on return/master chains

[lib/seshat/tools/follow_cam.ex](../../lib/seshat/tools/follow_cam.ex), new
`calls/2` clauses mirroring the regular-track device clauses:

- `load_device`/`bypass_device` with `%{return: i, device: d}`, `d >= 0` →
  `/live/return_track/select_device [i, d]` + `show_view Detail/DeviceChain`;
  `device: -1` → `/live/return_track/select [i]` + the pane.
- `delete_device` with `%{return: i, remaining: 0}` → select the return + the
  pane; otherwise `select_device [i, min(d, remaining - 1)]` + the pane.
- Master twins using `/live/master/select` / `/live/master/select_device [d]`.

### 9. Description and reply cleanups

- `create_return_track` (Definitions): replace "The new return is empty —
  Seshat cannot yet load a device onto a return track, so ask the user to
  drop the effect onto it in Live." with "The new return is empty — load its
  effect immediately with load_device (target: 'return') so the sends into
  it are audible."
- `create_return_track` handler reply (handlers.ex ~1750): same correction —
  point at `load_device` with `target: "return"` instead of apologizing.
- `set_track_send`: "The send is only audible if its return track has an
  effect loaded" gains "— load one with load_device (target: 'return')".
- `get_session_state` description: the return-track sentence now reads "name,
  volume, pan, mute/solo, in send order" and the master gains "pan and cue
  volume".
- Master-facing descriptions and replies use "master (shown as Main in Live
  12)" at least once on each discovery path, so the model can reconcile the
  tool vocabulary with the label the user sees in Live.

### 10. Tests

- `definitions_test.exs`: count 60 → 65 and add all five new tool names to the
  explicit expected-name list; existing schema-shape assertions cover their
  basic shape by construction.
- `validation_test.exs`: `target` enum rejects other strings; pan bounds
  −1.0…1.0 enforced; optional-param absence passes.
- `follow_cam_test.exs`: every new `calls/2` clause, including the `-1` and
  `remaining: 0` edges.
- `session/state_test.exs`: refresh parsing for every new return/master field,
  subscription sends for all new listeners, bare-push and envelope updates,
  boolean normalization for mute/solo, preservation of sibling master fields,
  and unknown (`nil`) values on failed reads.
- `handlers_test.exs`: pure helpers — the chain/parameter formatters fed
  return-shaped data (including malformed tails and count mismatches), the
  generalized `deleted_device_reply` labels, the expanded return/master state
  rendering, and the generalized bypass/no-op reply labels.
- `vendored_addresses_test.exs`: update the exact browser-handler registration
  list from five to seven addresses and the exact return/master-handler list
  from fourteen to fifty-one. The generic tripwire then passes only once
  Parts 1–4 agree — every new literal in `lib/` is registered in Python and
  listed in the docs.
- MCP parity tests cover the new/changed definitions automatically (generated
  components). Add an MCP input-validation assertion for `target`: omission and
  `"return"`/`"master"` pass, while any other string fails. Optional enums
  already exist (`set_clip_properties.launch_mode` / `warp_mode`), so this is a
  focused regression assertion for the six changed schemas, not a converter
  change.
- Run `mix precommit` after the focused tests.

### 11. Install + smoke

`mix abletonosc.install`, restart Live. `/smoke-test` additions (edits to
`.claude/skills/smoke-test/` land with the implementation, not this planning
run) — the checks only Ableton can give:

1. `load_device target: "return"` puts a reverb on a return; reply names it;
   view lands on the return's device chain; the send becomes audible.
2. `load_device target: "master"` loads an EQ on the master.
3. Load an *instrument* at a return and at the master — confirm the guard
   built from the 2026-07-31 measurement fires: an error naming the stray
   MIDI track Live creates, nothing claimed as loaded, and the stray track
   left in place for the model to offer to delete.
4. `get_track_devices` / `get_device_parameters` / `set_device_parameter` /
   `bypass_device` / `delete_device` with `target: "return"` and `"master"`,
   including a bad device index (error envelope, not timeout).
5. Return pan/mute/solo and master pan/cue from Seshat, then moved by hand in
   Live's UI — the mirror follows by push; `get_session_state` shows the new
   fields; delete a return and re-check listener rebind.
6. Cue volume audibly changes browser-preview level (ties to `preview_item`'s
   cue-routing note). The scales themselves are already measured — master pan
   −1.0…1.0 shown as `50L`/`C`/`50R`, cue 0.0…1.0 on track volume's dB curve
   with `0.85` = `0.0 dB` — so this check is about audibility, not range.
7. With the extension missing (pre-reinstall), the new tools fail with the
   `mix abletonosc.install` hint, not a bare timeout.

## Testing

Pure (`mix test`, no Ableton): everything in Part 10 — decision and formatting
logic, schema bounds, follow-cam calls, MCP parity, and the vendored-address
tripwire. Nothing tests through `Transport.query/3`; the query flows in the
extended handler clauses and all Python behaviour are smoke-only (Part 11).
The four questions that used to be open here were measured directly against
Live 12.4.3 on 2026-07-31 (method and results under Open questions), so no
part of this plan now rests on an unverified assumption about the Live API.

## Out of scope

- **Sends on return tracks** (return→return routing, feedback sends) — stays
  in the roadmap grab bag; `set_track_send`/`get_track_sends` remain
  regular-track tools.
- **A user-facing `select_track` that reaches returns/master** — the vendored
  select addresses exist for steering; widening the `select_track` tool is a
  rider for another day (grab-bag class).
- **Mirroring device chains in `Session.State`** — roadmap "Device list per
  track in session state" owns that decision, now for returns/master too.
- **Rack inner chains, device reordering, parameter listeners** —
  deliberately not planned, unchanged.
- **`remove_notes` footgun, verify-before-mutate sweep** — roadmap "Verify
  destructive mutations…"; this plan only adds the *replying* vendored delete,
  it does not retrofit others.

## Open questions

**All four were measured against live Ableton on 2026-07-31 and are now
closed** — see [Measured evidence](#measured-evidence-2026-07-31) below. They
are kept here with their answers because the assumptions they replaced are
load-bearing for Parts 1–3.

1. **✅ What does `browser.load_item` do with a non-effect item when a
   return/master is selected?** **It creates a stray MIDI track** and loads the
   instrument there, leaving the target chain untouched. Measured on both a
   return (`tracks 1→2`, stray `2-Operator`, `landed=[]`) and the master
   (`tracks 2→3`, stray `3-Operator`, `landed=[]`). The audio-effect case works
   exactly as hoped on both (`landed=['Reverb']`, track count unchanged). The
   plan's assumed guard is therefore **mandatory, not precautionary**: snapshot
   `len(song.tracks)`, and on a change report the error naming the stray track
   without auto-deleting it.
2. **✅ Does `song.view.selected_track = song.master_track` stick?** Yes —
   assigned and read back as the master (`is_master=True`). `/live/master/select`
   and `load_item_on_master` can both be built on it.
3. **✅ Does `song.view.select_device` on a return/master device show that
   chain?** Yes, on both. After `select_device`, the selected track is the
   return/master, `view.selected_device` is the device, and both `Detail` and
   `Detail/DeviceChain` read visible. The follow cam needs no fallback.
4. **✅ Master pan and cue-volume scales/labels.** `panning` is −1.0…1.0,
   parameter name `Track Panning`, displayed in Live's L/C/R form (`-1.0`→`50L`,
   `0.0`→`C`, `1.0`→`50R`) — **not** degrees or a percentage. `cue_volume` is
   0.0…1.0, parameter name **`Preview Volume`**, and shares the *identical* dB
   curve with track volume (`0.0`→`-inf dB`, `0.5`→`-14.0 dB`, `0.85`→`0.0 dB`,
   `1.0`→`6.0 dB`). Both accept writes and read back exactly.

## Measured evidence (2026-07-31)

Method: a temporary probe handler was added to the *installed* Remote Scripts
copy of `return_track.py` (never the repo), triggered with `/live/api/reload`
plus a probe address, and read back out of Live's `Log.txt`. No Live restart
was needed — `/live/api/reload` re-imports `return_track.py`. The installed
copy was restored with `mix abletonosc.install` and the probe address confirmed
gone. Live 12.4.3, Live 12 Suite.

Beyond the four answers above, the run established five things the plan should
build on:

- **`Track.delete_device(index)` works on both a return and the master** —
  removed the loaded Reverb from each, count read back as 0. Part 2's
  `delete_device` needs no special casing.
- **Return mute, solo and panning all read and write**, and
  `add_mute_listener` / `add_solo_listener` / `add_name_listener` are all
  callable — confirming Part 1's use of the base `_start_listen` for mute/solo.
- **The master has no `mute`, `solo` or `arm`, and reading one raises rather
  than returning falsy**: `RuntimeError("Main track has no 'mute' property!")`
  and `RuntimeError("Main and Return Tracks have no 'Arm' state!")`. Returns
  have no `arm` either. So feature-detection via `hasattr` is unsafe on LOM
  objects — the Python must simply not offer these addresses.
- **Live 12 calls the master track "Main"** — `song.master_track.name` is
  `'Main'`, and Live's own error strings say "Main track". Tool descriptions
  and replies should say "master (shown as Main in Live 12)" at least once so
  the model's prose matches what the user sees on screen.
- **Loading the first device onto a return renames it**: `A-Return` became
  `A-Reverb` the moment the Reverb landed. `load_item_on_return`'s reply should
  read the return's name back after the load rather than echoing the name it
  was given, and `Session.State`'s name listener will fire on its own — but a
  tool reply built from the pre-load mirror would be wrong.
