# Device tools

`load_device`, `get_track_devices`, `get_device_parameters`,
`set_device_parameter`, `delete_device` and `bypass_device`, on regular tracks and
— via `target: "return" | "master"` — on the return and master chains. Every
address behind `target` is vendored, so [bridge.md](bridge.md)'s reinstall
precondition applies to all of it.

Set-up for the return/master tests: one MIDI track with an audible clip playing,
one return track, and a send from the track into it.

## Parameter 0 is the `Device On` switch, displaying `On`/`Off`

*Last run: 2026-08-05 (re-run against the merged bridge, **stock devices
only** — the Instrument Rack and AU plugin halves were not re-covered and their
2026-08-03 result below still stands as their most recent evidence). Reverb's
parameter 0 read "Device On = 0.0 (range 0.0-1.0)" once bypassed;
`bypass_device enabled: false` switched it Off, repeating replied "was already
Off — nothing to do" without writing, and `enabled: true` restored it. Previous
full run, 2026-08-03 — passed on all three device kinds. `get_device_parameters`
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

*Last run: 2026-08-05 (re-run against the merged bridge) — passed, both paths
re-run. `delete_device` device 7 on a 2-device chain → "There are 2 device(s) on
track 0 (indices 0–1) — there is no device 7. Chain: 0: Reverb, 1: EQ Eight."
(180ms). `delete_device` track 99 → "Ableton rejected the request: Index out of
range" (165ms) — note that this path **still carries the prefix**, because
`delete_device` is not a batched read; the batched reads render the same class
of rejection through `remote_error/1` instead, which is the inconsistency
ROADMAP #26 now describes. Previous run, 2026-08-03 — passed, but **the
bad-track-index premise was stale and is corrected below.** All three paths
answered in ≤0.24s (whole `mcp_call.py` round trip). `delete_device` device 7 on a 2-device chain → "There are 2
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

## Chain and parameter reads pair the right values

*Last run: 2026-08-05 — passed, and this is the first live run of this check.
With Reverb and EQ Eight on track 0, `get_track_devices` listed them in chain
order with the right type each (`Device 0 "Reverb" — audio effect (Reverb)`,
`Device 1 "EQ Eight" — audio effect (Eq8)`). `get_device_parameters` with
`device: 1` headed its reply `Device 1 "EQ Eight"` — device 1's name, not
device 0's — and the 84 parameters listed were unmistakably EQ Eight's
("1 Filter On A", "1 Frequency A", "1 Gain A"), not Reverb's 33. `device: 7`
errored in 236ms.*

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

*Last run: 2026-08-05 (re-run against the merged bridge) — passed, both
targets. `target: "return"` errored naming the stray track "2-Operator",
`target: "master"` naming "3-Operator"; nothing was claimed as loaded, a
refreshed `get_session_state` showed both strays present at indices 1 and 2,
and `get_track_devices` on return 0 still reported an empty chain. Both strays
deleted afterwards. Previous run, 2026-08-03 — passed, both targets.
`target: "return"` → error "Live
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

*Last run: 2026-08-05 — passed, and this is the first live run of this check.
`audio_effects` + `reverb` returned "Showing 25 of 158 matches" naming
plausible items (3 Band Ambience Reverb.adg, Compressed Room Reverb.adg) in
149ms — no wording about replies not being about what was asked for, so the
echo comparison passes legitimate replies. `sounds_typo` was refused in 142ms
by `Seshat.Tools.Validation` listing the eight valid categories, which is the
Validation error this step actually reaches, per the note below — not
`browser.py`'s stale-echo arm.*

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

