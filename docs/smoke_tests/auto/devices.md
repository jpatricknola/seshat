# Device tools

`load_device`, `get_track_devices`, `get_device_parameters`,
`set_device_parameter`, `delete_device` and `bypass_device`, on regular tracks and
— via `target: "return" | "master"` — on the return and master chains. Every
address behind `target` is vendored, so [bridge.md](bridge.md)'s reinstall
precondition applies to all of it.

Set-up for the return/master tests: one MIDI track with an audible clip playing,
one return track, and a send from the track into it.

## Parameter 0 is the `Device On` switch, displaying `On`/`Off`

*Last run: 2026-08-03 — passed on all three device kinds. `get_device_parameters`
reported parameter 0 as "Device On" (range 0.0–1.0) on a stock Live device
(Reverb, 33 params), an Instrument Rack preset ("E-Piano Basic".adg, 18 params)
and an AU plugin (Apple AUDelay, 4 params). `bypass_device enabled: false`
switched each Off; reading parameter 0 back on the plugin showed 0.0, and
repeating the call replied "was already Off — nothing to do" without writing.
All three re-enabled. `ensure_on_off_switch` never refused, so the display
string is in the accepted set on Live 12.4.3.*

Both `delete_device` and `bypass_device` stand on this, and it comes from the
Live Object Model rather than from a verified run. Check on a stock Live device,
an Instrument Rack preset, and (if installed) an AU/VST plugin:
`get_device_parameters` shows parameter 0 named "Device On", and `bypass_device`
toggles it.

If Live spells the display differently, `bypass_device` refuses on *every* device
and its error prints the actual string; the fix is widening the accepted set in
`ensure_on_off_switch` ([lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)).

## Device error paths are errors, not stalls

*Last run: 2026-08-03 — passed, but **the bad-track-index premise was stale and
is corrected below.** All three paths answered in ≤0.24s (whole `mcp_call.py`
round trip). `delete_device` device 7 on a 2-device chain → "There are 2
device(s) on track 1 (indices 0–1) — there is no device 7. Chain: 0: E-Piano
Basic, 1: AUDelay." `delete_device` device 0 on an empty chain → "There are no
devices on track 2, so there is nothing to delete (asked for device 0). Check
the chain with get_track_devices." `delete_device` track 99 → "Ableton rejected
the request: Index out of range" in 0.19s.*

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

## The stray-track guard fires

*Last run: 2026-08-03 — passed, both targets. `target: "return"` → error "Live
would not load 'Operator' onto return track 0 — it created a new track
"5-Operator" and put it there instead, leaving return track 0 unchanged… The new
track was left in place rather than deleted." `target: "master"` → the same
shape, naming "6-Operator" and the master. Nothing was claimed as loaded; a
refreshed `get_session_state` showed both stray tracks still present (indices 4
and 5), and `get_track_devices` on the return still listed only Reverb and
Ballad Reverb. `_verify_landed` is running. Both strays deleted afterwards.*

Load an *instrument* (Operator) with `target: "return"`, then again with
`target: "master"`. Both must **error**, naming the stray MIDI track Live created;
nothing may be claimed as loaded; and the stray track must still be there
afterwards — the tool never deletes it, the model should offer `delete_track`. If
either reports success, `browser.py`'s `_verify_landed` is not running.

## Browser search echoes the search it ran

*Last run: —*

`list_browser_items` verifies the category and filter its reply echoes
against the request before presenting anything — a real reply must pass that
check, and a stale one must not be presented as this search's results (the
stale branch is suite-fed; this checks the real replies still get through).

Search a real category with a filter that has matches (e.g. category
`audio_effects`, filter `reverb`) and confirm results come back naming
plausible items. Then search an unknown category (e.g. `sounds_typo`) and
confirm an immediate clean error listing the valid categories — not a stale
warning, not a 15s stall.

A valid search erroring with wording about replies "not about the … asked
for" means the echo comparison is rejecting legitimate replies — check what
`browser.py` echoes against what the request sent (string round-trip) in
`list_browser_items`'s decode
([lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)).

