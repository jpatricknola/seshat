---
name: smoke-test
description: Verify a change end-to-end against a live Ableton Live instance using the seshat MCP tools
argument-hint: [optional - what to focus on, e.g. "the new set_track_send tool"]
disable-model-invocation: true
---

Smoke-test Seshat against the live Ableton instance. Focus: **$ARGUMENTS**
(if no focus given, test whatever changed on this branch — check `git diff`
and recent commits).

The test suite deliberately stops at the pure layer; anything reaching
`Transport.query/3` needs a live Ableton. This is that missing live layer, run
by hand. Use the `mcp__seshat__*` tools — they exercise the exact path a real
user's MCP client does.

## Preflight

1. Call `get_session_state`. If it errors or times out, Ableton isn't running
   or AbletonOSC isn't installed/enabled — report that and stop. (Setup:
   `mix abletonosc.install`, then enable AbletonOSC as a Control Surface in
   Live's preferences. See [README.md](README.md).)
2. Note what's in the session before you touch anything: track count, names,
   tempo. You'll restore or clean up afterwards. **If the session looks like
   real work in progress (named tracks, clips), create your own scratch
   tracks rather than modifying existing ones.**

## First, if the change touches the bridge

`/live/browser/*`, `/live/return_track/*` and `/live/master/*` are Seshat's own
— served by [priv/AbletonOSC/abletonosc/browser.py](priv/AbletonOSC/abletonosc/browser.py) and
[priv/AbletonOSC/abletonosc/return_track.py](priv/AbletonOSC/abletonosc/return_track.py) in our
fork of AbletonOSC, installed by `mix abletonosc.install`. `mix test` cannot
reach them at all, so a smoke test is the *only* thing standing behind that
whole surface. Before anything else:

- Run `mix abletonosc.install` and **restart Live** (or toggle AbletonOSC off
  and on under Preferences > Link/Tempo/MIDI). `/live/api/reload` does not pick
  these up.
- Confirm the extension is actually answering before you judge anything else:
  `get_session_state` prints the return tracks and master volume when
  `return_track.py` is loaded, and a single "Return/master state unavailable"
  line when it isn't. A whole feature reading as broken usually means this step
  was skipped.
- These handlers' getters **always reply, including on a bad index**, so an
  out-of-range index must come back as an immediate error naming the real
  count — not a ~2s timeout. A timeout here means the extension isn't loaded,
  and that distinction is the point of the envelope: if a bad index hangs
  instead, the handler is stale and needs reinstalling.
- **Watch Live's `Log.txt`.** Since the fork it should stay clean during
  ordinary work — upstream raised a `RemoteScriptError` on every clip-slot
  operation, so a traceback appearing during `write_midi_notes`,
  `delete_clip`, `duplicate_clip` or `get_clip_slots` means an old AbletonOSC
  is still installed. (`~/Library/Preferences/Ableton/Live <version>/Log.txt`.)
- **The listener fix, by hand in Live's UI.** Delete a track, then rename a
  different one, then call `get_session_state`. Every name must be under the
  right index. This is the one fix whose failure is silent — every address
  still answers — so nothing but this check finds it.

## Exercise the change

3. Drive the changed tool(s) through a realistic sequence, not just one call.
   For a new tool, include at least:
   - a normal call (verify the effect via `get_session_state` or the relevant
     `get_*` tool — remember a wrong OSC address fails *silently*, so an
     absent effect is a real failure signal, not noise);
   - a boundary value (index of the last track, 0.0/1.0 for levels, -1.0/1.0
     for pan);
   - an invalid input (out-of-range index) — confirm the error is clean, not
     a hang or timeout.
4. Where state should change, **read it back** rather than trusting the send:
   session state for track properties, `get_device_parameters` for device
   changes, `get_track_devices` after loading.

## If the change touches an address with no tool yet

`/live/clip/quantize` and `/live/browser/preview_item` / `stop_preview` are
served by the fork but have no Seshat tool (roadmap #9 and #16), so the MCP
surface can't reach them. Drive them by raw OSC — **send-only**, so nothing
binds port 11001 and Seshat's own reader stays alive:

```bash
python3 -c '
import sys; sys.path.insert(0, "priv/AbletonOSC")
from pythonosc.udp_client import SimpleUDPClient
c = SimpleUDPClient("127.0.0.1", 11000)
c.send_message("/live/clip/quantize", [0, 0, 8, 1.0])   # track 0, clip 0, 1/16, full
'
```

- **Quantize**: record or write a deliberately sloppy MIDI clip, then quantize
  it. Grid `8` is sixteenths — if it lands on half notes, the handler took the
  wrong enum. Then undo and re-run with amount `0.5`: the notes should move
  halfway toward the grid, not all the way.
- **Preview**: `preview_item` with a `uri` from `search_library`, with Live's
  cue output routed somewhere audible and the cue level up. Confirm it sounds
  *without* anything being added to the set, and that `stop_preview` silences
  it. A silent preview with cue routed nowhere is expected, not a bug — which
  is exactly why the cue caveat has to reach the eventual tool's description.

## If the change touches the sound catalog

`search_library`'s job is to turn a description into a loadable preset, and the
only honest test of ranking is whether a plain ask reaches a good candidate.
Tests cover the scoring rules; they cannot tell you the slate is *musically*
right.

- Ask for a sound in words rather than in tags — "find me a warm guitar". `Warm`
  is not a real tag in a stock library, which is the point. **Judge the
  conversation, not the first tool call.** If the model sends `Warm` as its only
  tag the search correctly returns nothing (tags filter at ≥1) — what has to
  happen next is that the reply names the failed tag and the real tags on what
  the query alone matches, and the model retries with one of those and lands on
  the acoustic/soft guitars. One wasted call is the designed cost; **a dead end
  is the failure**, even though nothing errored.
- Don't expect `nearest real tags` to appear for a word like `Warm`. That list is
  string similarity — it rescues a typo (`Anlaog` → `Analog`) or a longer form
  (`Warmth` → `Warm`), not a word the library has no spelling of. The nearest
  string neighbour of "Warm" in a stock vocabulary is "Marimba" at 0.726, below
  the threshold, and suppressing that is correct.
- Check the slate spans devices rather than 15 neighbours from one folder, and
  that a truncated reply lists real tags with counts you can then narrow by —
  try one of them and confirm it does narrow.
- Confirm the model presents 3–5 candidates with reasons instead of loading the
  first hit unasked, then load one and confirm `search_library` favours it
  slightly afterwards (usage counts survive a reindex).

## If the change touches the device tools (`delete_device` / `bypass_device`)

Both stand on an assumption `mix test` cannot reach: **parameter 0 of every
device is its "Device On" switch, displaying exactly `On`/`Off`**. That comes
from the Live Object Model, not from a verified run — so check it first, and
on more than one kind of device:

1. On a stock Live device, an Instrument Rack preset, and (if installed) an
   AU/VST plugin: `get_device_parameters` shows parameter 0 named "Device On",
   and `bypass_device` toggles it. If Live spells the display differently,
   `bypass_device` refuses on *every* device and its error prints the actual
   string — the fix is widening the accepted set in `ensure_on_off_switch`
   ([lib/seshat/tools/handlers.ex](lib/seshat/tools/handlers.ex)).
2. `bypass_device enabled: false` on an effect is audible and the device's
   power button visibly dims in Live; `enabled: true` restores it with
   settings intact; bypassing an instrument silences its track; repeating a
   bypass replies "already Off" without writing.
3. `delete_device` removes the right device (confirm in Live's UI), its
   reply's remaining chain matches a fresh `get_track_devices`, and later
   device indices shift down as the reply warns.
4. Error paths: an out-of-range device index errors immediately (Elixir-side
   bounds check — no 2s stall); a bad track index errors in ≈2s with the
   get_track_devices hint; deleting from an empty chain errors cleanly.
5. Delete a device while its track's clip is playing — no crash expected;
   note by ear whether Live clicks or glitches (open question 2 in
   [docs/archive/PLAN_audition_loop.md](docs/archive/PLAN_audition_loop.md) —
   if it's ugly, the fix is a description sentence advising to stop the clip
   first).
6. The loop as a conversation: `search_library` for electric pianos → load
   one on a MIDI track with a clip → fire → "next" (delete + load) → "keep
   that one" — the set ends holding only the winner. Then an effect A/B via
   `bypass_device`.

## Clean up and report

5. Delete any scratch tracks/scenes/clips you created (`delete_track`,
   `delete_scene`, `delete_clip`) or use `undo` for in-place changes. Leave
   the session as you found it.
6. Report: what you exercised, what you verified by reading state back, what
   failed or timed out, and what can only be judged by ear (sound choice,
   levels, timing feel) — flag those explicitly for the user to check.
