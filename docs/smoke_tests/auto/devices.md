# Device tools

`load_device`, `get_track_devices`, `get_device_parameters`,
`set_device_parameter`, `delete_device` and `bypass_device`, on regular tracks and
— via `target: "return" | "master"` — on the return and master chains. Every
address behind `target` is vendored, so [bridge.md](bridge.md)'s reinstall
precondition applies to all of it.

Set-up for the return/master tests: one MIDI track with an audible clip playing,
one return track, and a send from the track into it.

## Parameter 0 is the `Device On` switch, displaying `On`/`Off`

*Last run: 2026-11-08 — passed on all three device kinds, Live 12.4.6. get_device_parameters reported parameter 0 as "Device On" (range 0.0–1.0) on stock Reverb (33 params, on a return), the "E-Piano Basic" Instrument Rack (18 params) and Apple AUDelay (4 params). bypass_device enabled: false switched each Off; parameter 0 read back 0.0 on Reverb and on the plugin; repeating replied "was already Off — nothing to do"; all three re-enabled. ensure_on_off_switch never refused.*

Both `delete_device` and `bypass_device` stand on this, and it comes from the
Live Object Model rather than from a verified run. Check on a stock Live device,
an Instrument Rack preset, and (if installed) an AU/VST plugin:
`get_device_parameters` shows parameter 0 named "Device On", and `bypass_device`
toggles it.

If Live spells the display differently, `bypass_device` refuses on *every* device
and its error prints the actual string; the fix is widening the accepted set in
`ensure_on_off_switch` ([lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)).

## Device error paths are errors, not stalls

*Last run: 2026-11-08 — passed, all three paths ≤0.25s. delete_device device 7 on a 2-device return chain → "There are 2 device(s) on return track 0 (indices 0–1) — there is no device 7. Chain: 0: Reverb, 1: Ballad Reverb."; device 0 on an empty track → "There are no devices on track 0, so there is nothing to delete (asked for device 0). Check the chain with get_track_devices."; track 99 → "Ableton rejected the request: Index out of range" (175ms), still carrying the prefix as noted below.*

An out-of-range device index errors immediately (Elixir-side bounds check — no 2s
stall); deleting from an empty chain errors cleanly, naming `get_track_devices`.

A bad *track* index no longer stalls ~2s and no longer carries the
`get_track_devices` hint. That hint lives on `do_call`'s `catch :exit` timeout
branch, and the `/live/error` correlation shipped 2026-08-03 made that branch
unreachable here: Live's rejection now arrives in milliseconds and renders
through `Transport.describe_error/1` as the generic "Ableton rejected the
request: Index out of range". Expect **fast and generic**, not slow and helpful.
The lost guidance — the message no longer says which index was bad or what to
call next — is tracked in [../ROADMAP.md](../ROADMAP.md), not here.

## Chain and parameter reads pair the right values

*Last run: 2026-11-08 — passed. With Reverb and EQ Eight on track 0, get_track_devices listed `Device 0 "Reverb" — audio effect (Reverb)`, `Device 1 "EQ Eight" — audio effect (Eq8)`; get_device_parameters device: 1 headed `Device 1 "EQ Eight"` with 84 parameters (Output, Scale, Adaptive Q…), not Reverb's 33; device: 7 errored in 165ms with the generic batched-read "Index out of range".*

The regular-track `get_track_devices` (three parallel list getters) and
`get_device_parameters` (five) each collapse to one batched tick, and the
thing that must survive is the pairing: all lists describing the *same*
chain, the parameter read describing the device that was asked for.

On a regular track with **two different devices** loaded (load them if
needed; delete what you added afterwards), `get_track_devices` must list
both in chain order with the right type for each. Then
`get_device_parameters` with `device: 1` must head its reply with device 1's
name — not device 0's — and list that device's parameters. Then ask for
`device: 7` on the same track: immediate error, as § Device error paths are
errors, not stalls already pins.

A name/type mispairing or a parameter list under the wrong device name means
the batch decode zipped replies that don't belong together — exactly the
parallel-list hazard the old per-query echo checks guarded, now living in
`Seshat.OSC.Transport`'s batch matching.

## The stray-track guard fires

*Last run: 2026-11-08 — passed, both targets. target: "return" errored naming the stray "2-Operator", target: "master" naming "3-Operator"; nothing claimed as loaded; a refreshed get_session_state showed both strays at indices 1 and 2; return 0 still listed Reverb and Ballad Reverb only, the master empty. Both strays deleted afterwards.*

Load an *instrument* (Operator) with `target: "return"`, then again with
`target: "master"`. Both must **error**, naming the stray MIDI track Live created;
nothing may be claimed as loaded; and the stray track must still be there
afterwards — the tool never deletes it, the model should offer `delete_track`. If
either reports success, `browser.py`'s `_verify_landed` is not running.

## Browser search echoes the search it ran

*Last run: 2026-11-08 — passed. `audio_effects` + `reverb` returned "Showing 25 of 158 matches" naming 3 Band Ambience Reverb.adg, Compressed Room Reverb.adg, Delayed Hall Reverb.adg in 193ms with no stale-reply wording; `sounds_typo` was refused in 143ms by Validation listing the eight valid categories.*

`list_browser_items` verifies the category and filter its reply echoes
against the request before presenting anything — a real reply must pass that
check, and a stale one must not be presented as this search's results (the
stale branch is suite-fed; this checks the real replies still get through).

Search a real category with a filter that has matches (e.g. category
`audio_effects`, filter `reverb`) and confirm results come back naming
plausible items. Then search an unknown category (e.g. `sounds_typo`) and
confirm an immediate clean error listing the valid categories — not a stale
warning, not a 15s stall.

Note: `category` is a schema enum in `Definitions`, so the unknown-category
step is rejected by `Seshat.Tools.Validation` before any datagram is sent —
it exercises Validation's error, not `browser.py`'s echoed error arm. That
arm (an error envelope about another search is stale) is covered only by the
pure test in `handlers_test.exs`; this step still confirms a clean immediate
error, just not the one it names.

A valid search erroring with wording about replies "were not about what was
asked for" means the echo comparison is rejecting legitimate replies — check
what `browser.py` echoes against what the request sent (string round-trip) in
`list_browser_items`'s decode
([lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)).

