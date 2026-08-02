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
  these up. This is not optional bookkeeping: `mix test` greps the submodule in
  the repo, while Live runs the copy in Remote Scripts, so a green suite says
  nothing about what Live has actually loaded. If the branch touched
  `priv/AbletonOSC` at all, reinstall before you believe a single result below.
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

`/live/browser/preview_item` and `/live/browser/stop_preview` are served by the
fork but have no Seshat tool (roadmap: browser preview audition), so the MCP
surface can't reach them. Drive them by raw OSC — **send-only**, so nothing
binds port 11001 and Seshat's own reader stays alive:

```bash
python3 -c '
import sys; sys.path.insert(0, "priv/AbletonOSC")
from pythonosc.udp_client import SimpleUDPClient
c = SimpleUDPClient("127.0.0.1", 11000)
c.send_message("/live/browser/preview_item", ["query:Sounds#Bass:FileId_5200"])
'
```

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

## If the change touches devices on return or master tracks (`target: "return"` / `"master"`)

Every address behind `target` is vendored — `return_track.py` and `browser.py`
in the fork — so **`mix test` has executed none of it**. Reinstall and restart
Live first (the bridge section above), or every check below passes for the wrong
reason. Set up: one MIDI track with an audible clip playing, one return track,
and a send from the track into it.

1. **The headline workflow.** `create_return_track "Room Reverb"`, then
   `load_device target: "return", track: <that index>` with a Reverb uri. The
   reply names *both* the return and the device; the view lands on the return's
   device chain; raising the track's send is now audible. Live renames the
   return as the first device lands (`A-Return` → `A-Reverb`) — confirm the
   reply carries the **post-load** name, not the one it was created with.
2. **Master.** `load_device target: "master"` with an EQ Eight. The reply names
   the master, the view lands on the master's device chain, and the whole mix is
   affected.
3. **The stray-track guard** — the one measured behaviour this whole guard
   exists for. Load an *instrument* (Operator) with `target: "return"`, and
   again with `target: "master"`. Both must **error**, naming the stray MIDI
   track Live created; nothing may be claimed as loaded; and the stray track
   must still be there afterwards (the tool never deletes it — the model should
   offer `delete_track`). If either reports success, the verification in
   `browser.py`'s `_verify_landed` is not running.
4. **The read/write surface, on both chains.** With `target: "return"` and
   `target: "master"`:
   - `get_track_devices` lists the chain and says "return track N" / "the
     master track", never "track N".
   - `get_device_parameters` lists every parameter of a large device (Reverb,
     EQ Eight) in one reply — watch for truncation, this is the combined
     getter's only real test.
   - `set_device_parameter` changes an audible parameter and the reply echoes
     Live's own display string.
   - `bypass_device` toggles the device off and on, audibly, and repeating it
     replies "already Off" without writing.
   - `delete_device` removes it, the reply's remaining chain matches a fresh
     `get_track_devices`, and the view lands sensibly (successor device, or the
     empty chain).
5. **Error paths must be errors, not timeouts.** A bad device index on either
   chain comes back **immediately** with an error envelope naming the chain —
   these getters always reply. A ≈2s stall instead means the installed copy
   predates this work. Try a bad index at every depth, not just the device:
   a bad **device** index on `set_device_parameter` or `bypass_device` (valid
   return, out-of-range device) must error the same way — this is the case
   that used to come back as a false "try again" timeout, because the
   parameter index in the reply was echoed as `-1` instead of the value
   actually asked for.
6. **A slow-loading effect, not just the stray-track guard.** If a
   third-party VST3/AU effect is installed, load it (not an instrument) with
   `target: "return"`. Some plugins instantiate asynchronously, which can
   leave `_verify_landed` seeing no change yet and reporting an error for a
   load that in fact succeeds a moment later — item 3 above only exercises
   the synchronous Operator case. If this happens, confirm with
   `get_track_devices` whether the device actually landed; either way this is
   a known limitation of the guard (see the plan's review notes), not a new
   regression to chase.

## If the change touches the return/master mixer tools (`set_return_track_pan` / `set_return_track_mute` / `set_return_track_solo` / `set_master_pan` / `set_cue_volume`)

All five are vendored too — reinstall and restart Live first.

1. Each setter moves the right control in Live's mixer, and its reply names the
   old value as well as the new one.
2. `set_return_track_mute` silences the shared effect for every track feeding
   it, and the sends themselves are untouched (check `get_track_sends`).
   `set_return_track_solo` hears the return alone.
3. **Push, not poll.** Move each of those controls *by hand in Live* and
   confirm `get_session_state` reflects it without `refresh: true`: return pan,
   mute and solo; master pan; cue volume. This is what the new listeners are
   for, and a missed `start_listen` looks exactly like a working tool until you
   try this.
4. **Listener rebind.** Delete a return track, then move the pan/mute/solo of
   the return that took its index. `get_session_state` must show the change on
   the *right* return — a stale binding writes one return's state onto another.
5. `get_session_state`'s return lines carry pan and mute/solo; the master line
   carries pan and cue volume and names itself "shown as Main in Live 12".
6. **Cue volume is audible.** `preview_item` a preset, then change
   `set_cue_volume` and preview again — the preview level follows. The scales
   are already measured (master pan −1.0…1.0 shown as `50L`/`C`/`50R`, cue
   0.0…1.0 on track volume's dB curve with `0.85` = `0.0 dB`), so this check is
   about audibility, not range.
7. **A stale install is distinguishable.** Before reinstalling — or against an
   older Remote Scripts copy — every one of these five tools, and every
   `target:` call above, must fail with the `mix abletonosc.install` hint rather
   than a bare timeout or a regular-track error message.

## If the change touches the clip property tools (`get_clip_properties` / `set_clip_properties`)

Every clip setter is fire-and-forget and Live's own rejection of an invalid loop
range is silent, so `mix test` proves the write-ordering logic and nothing about
whether the writes land. Three assumptions here come from Live's object model
rather than from any run:

1. **The headline sentence.** Capture or write an 8-beat MIDI clip, then "loop
   beats 4–8": the brace visibly moves in the note editor, playback loops that
   section, and the reply echoes 4.0–8.0 plus the new length.
2. **Looping-off aliasing.** With looping off, `get_clip_properties` should show
   the loop points tracking the play markers. Then set `looping` *and* the loop
   points in one call and confirm the intended brace results — this is the
   **known wart** recorded by the 07/2026 review: the
   pair-context read happens before the `looping` toggle goes out, so
   on a clip whose stored brace differs from its markers the ordering and the
   single-sided validation can both run on stale values. If it misbehaves, the
   fix is to send `looping` first and read the pair context after.
3. **Ordering and invalid states.** Move a brace entirely past the old one in
   one call (the end-first path) and confirm it lands. Then make a single-sided
   invalid write (`loop_start` beyond the current `loop_end`) and confirm it
   errors naming the current value with Live untouched. Note for the record
   whether Live clamps or ignores an inverted loop point.
4. **Audio clip.** Set `gain` — the echo shows a plausible dB from
   `gain_display_string`. Change `warp_mode`/`warping` and see it in clip view.
   Confirm `velocity_amount` and `legato` read and write without timeouts —
   they are *assumed* present on audio clips; if a read stalls, move them to
   the MIDI-only branch of `@clip_common_reads`. On an **unwarped** audio clip,
   confirm the reply says "seconds" rather than "beats".
5. **MIDI guard.** `gain` on a MIDI clip errors cleanly and nothing is sent.
6. **Reader.** `get_clip_properties` on a freshly captured clip reports the
   length and brace Live inferred; on an empty slot it errors via `ensure_clip`
   rather than burning fourteen timeouts.
7. **Follow cam.** A brace edit leaves the clip selected with the note editor
   open.

## If the change touches `quantize_clip`

`/live/clip/quantize` **never replies** — success, a bad grid integer, and a
Remote Scripts copy predating the fork are all the same silence on the wire — so
nothing in `mix test` can tell you the notes moved, let alone where to. Drive it
through the tool (not raw OSC): the string→int mapping, the before/after diff
and the reply wording only exist in `quantize_clip`.

Play or write a deliberately sloppy MIDI clip first — notes a little either side
of the beat, at least one pair of same-pitch notes close together.

1. **The headline, and the check that catches the enum.** `"1/16"` at amount
   1.0. Notes land on the grid in the note editor and the reply's counts match
   what visibly moved. **Confirm the landing positions are 1/16ths — 0.25-beat
   spacing — and not 1/32nds.** That single observation is what caught the
   documented `GridQuantization` table being wrong in every row (measured
   31 Jul 2026); it is the regression check for anyone "fixing"
   `grid_quantization/1` back toward an older doc.
2. **Partial strength.** `undo`, then the same grid at amount 0.5. Notes move
   *toward* the grid, not onto it, and the reply still counts them. Live
   interpolates linearly: a note at 1.37 with a 1.25 target lands at 1.31.
3. **Already tight.** Quantize the same clip twice at 1.0. The second call
   reports "no note changed" — read that reply and confirm its stale-install
   hint doesn't read as an error, because here silence is normal.
4. **Triplets.** `"1/8T"` and `"1/16T"` on a straight part: notes land on
   thirds and sixths of a beat. The old docs claimed triplet grids did not
   exist, so this confirms the tool reaches values that were written off.
5. **Collisions.** A full quantize that stacks two same-pitch notes. Expect the
   count-change wording: same-point collisions **merge** into one note keeping
   the *later* velocity, while a post-move same-pitch overlap instead **trims**
   the earlier note's duration. Both are Live's behaviour, measured — the reply
   should say which happened.
6. **Audio clip.** Rejected cleanly by `ensure_midi_clip`, with no warp markers
   touched.
7. **Refusals cost nothing.** `amount: 0` errors immediately (0% strength moves
   nothing), and an empty slot errors via `ensure_clip` — neither should take a
   guard timeout.
8. **Undo.** One `undo` restores the take.
9. **Non-4/4.** The mapping measured identical in 4/4 and 6/8, so a quantize in
   an odd meter is a cheap confirmation nothing meter-dependent crept in.
10. **Follow cam.** The quantized clip is left selected with the note editor
    open — the notes snapping on screen *is* the confirmation.

## If the change touches `set_swing_amount` / `set_groove_amount`

`swing_amount` is fork-only — one `properties_rw` line added to
`priv/AbletonOSC/abletonosc/song.py` — so a Remote Scripts copy that predates
the fork pin makes `/live/song/set/swing_amount` silently a no-op, indistinguishable
from success, same as every other silent setter. `groove_amount` is upstream
and needs no reinstall. If this branch touched `priv/AbletonOSC` at all, run
`mix abletonosc.install` and restart Live first (see "First, if the change
touches the bridge" above) — item 1 below is what catches a skipped reinstall.

1. **First:** `get_session_state` shows numeric groove *and* swing values, not
   "unknown". Live 12 Suite has `Song.swing_amount`, so "swing unknown" here
   means the wire, not the property — almost certainly the fork wasn't
   reinstalled or Live wasn't restarted. Fix that before anything else; every
   item below depends on it.
2. `set_swing_amount 0.25`, then `get_session_state` **without** `refresh:
   true` — the mirror shows 0.25 via the listener echo, not a fresh query.
3. Set swing, then `quantize_clip` at `"1/8"` on a straight clip — notes land
   *off* the straight grid on swung positions (the end-to-end "make it
   swing"; also exercises `quantize_clip`'s own smoke item 4 from the other
   side). Judge by ear whether 0.10–0.20 reads as "subtle" — if not, the fix
   is `set_swing_amount`'s description, not the code.
4. Assign a groove to a clip by hand in Live, then `set_groove_amount 0.0`,
   then `1.0`, then `1.3` — audible change, and the Groove Pool's Amount dial
   follows: expect the dial to read **100%** at 1.0 and **130%** at 1.3.
   Anything else means the mapping moved in this Live version and
   `set_groove_amount`'s schema max needs revisiting.
5. `set_groove_amount` with **no** grooves assigned anywhere in the set —
   nothing changes audibly, and the model's reply (fed by the tool
   description) says so rather than promising swing.

(Groove and swing already appear in the unknown-state field list in "If the
change touches `Session.State`'s refresh" below — nothing further to add
there.)

## If the change touches the view tools (`show_view` / `hide_view` / `get_view_state`)

The three setters — `/live/view/show_view`, `/live/view/hide_view`,
`/live/view/set/detail_clip` — **never reply**, so a pane that appears and a
name Live rejects are identical on the wire and nothing in `mix test` can
confirm anything showed. `get_view_state` is what changes that: since
2026-07-31 `/live/view/get/is_view_visible` reads each pane's real visibility
back out of Live, so most of this section is now **self-checking** — Seshat
confirms its own view changes and no human has to watch the screen. Run it with
Ableton open all the same: the addresses only exist in the fork, so a missing
`mix abletonosc.install` (or a Live that wasn't restarted) is exactly what
items 1–3 catch.

1. **Visibility matrix — no human eyes needed.** For each of `Browser`,
   `Arranger`, `Session`, `Detail`, `Detail/Clip`, `Detail/DeviceChain`: call
   `show_view(name)`, then `get_view_state`, and confirm the summary reports
   that pane. This finally covers bare `Detail`, which the 2026-07-31 run had
   to leave unconfirmed because closing the detail panel needed a keystroke —
   now `hide_view(Detail)` closes it and the getter proves it closed. Two
   readings the summary derives rather than reads, worth eyeballing once
   against the screen: "Main view" comes from the Session/Arranger pair, and
   the detail panel's named tab comes from the `Detail/*` flags.
2. **Hide-set tripwire.** For each name in `hide_view`'s enum (`Browser`,
   `Detail`): `get_view_state`, `hide_view(name)`, `get_view_state` again. The
   pane must go from present to absent. A name whose visibility doesn't flip
   means Live's hide set moved in this version and the enum needs revisiting —
   the same dial-check reasoning as `set_groove_amount`. `hide_view` reads
   itself back, so a stuck pane comes out as an honest error rather than a
   false success; if it reports one, that *is* the finding.
3. **Honest failure, only while the old copy is still installed.** Before
   reinstalling during implementation, call `hide_view` and `get_view_state`
   against the still-old AbletonOSC and confirm both come back — after the 2s
   guard timeout — with the "run `mix abletonosc.install` and restart Ableton
   Live" hint rather than a bare timeout. If the new copy is already installed,
   report this check as **not reproduced**; do not downgrade and restart Live
   just to manufacture it. A raw `Transport.query` is not a substitute: it
   bypasses the handler wording this check exists to verify.
4. **Show-first sequencing.** Start in Arrangement, ask naturally to launch a
   named Session clip. Expect `show_view(Session)` before `fire_clip` — the
   grid appears, then the launch happens on screen — and expect it sent
   *directly*, with no `get_view_state` pre-check: six serialized reads to
   avoid one harmless idempotent send would only delay the action.
5. **No redundant pre-show.** Start in Session, ask to change a clip's loop
   brace or notes. Expect no `show_view(Detail/Clip)` beforehand — the
   existing follow cam already leaves the edited clip on screen right after
   the write.
6. **Selected-track pane.** With a *different* track selected, ask to change
   a device parameter on a named track. Expect `select_track` then
   `show_view(Detail/DeviceChain)` before the mutation — `set_device_parameter`
   is the one mutation with no follow cam behind it, so a skipped pre-show
   here shows the wrong track's chain.
7. **Arrangement pre-show.** Start in Session, ask to set the song loop
   brace. Expect `show_view(Arranger)` before `set_loop`.
8. **Pure navigation.** Ask only "show me the timeline" and "show me the
   notes again." Expect `show_view` alone — no invented follow-up mutation,
   no keyboard instructions.
9. **Reading before re-showing.** With Live's browser already open, ask "show
   me the browser." Expect `get_view_state` first and *no* redundant
   `show_view` — the answer says it is already open. This is the half of the
   re-show policy that item 4 deliberately excludes; both must hold at once.
10. **Hiding in words.** Ask "hide the browser, I need the room" and, in a
    separate turn, "close the detail panel." Expect `hide_view(Browser)` and
    `hide_view(Detail)` respectively — not a keystroke instruction, and not
    `show_view` of something else. Then ask "what am I looking at?" and expect
    `get_view_state` with an answer naming panes in the user's vocabulary
    ("Session view, browser closed"), never tool names or raw flags.

## If the change touches the recording tools (`record_clip` / `stop_recording`)

These shipped 2026-07-29 having **never executed against Live** — the only
verification behind them was one raw-OSC fire in 4/4. Four assumptions are load-
bearing and unreachable by `mix test`; each names its own fix. Items 1, 2 and 5
are the ones that must pass before anyone trusts the pair.

1. **Fixed-length take.** Empty slot, armed MIDI track, transport stopped,
   `record_clip bars: 2` → recording starts immediately, Live stops it itself,
   and `get_clip_properties` shows exactly 8.0 beats, looping. This also
   exercises `will_record_on_start` on the happy path: if Live gates that
   property on anything beyond "armed track, empty slot", `record_clip` errors
   on *every* call and it surfaces here first.
2. **Auto-arm.** Same on a **disarmed** track → the tool arms it and the reply
   says "Armed the track first." Then check what Live's exclusive-arm
   preference did to whatever was armed before — the disclosure currently
   doesn't mention it, and if exclusive arm silently disarms another track
   that sentence needs to say so. If `set/arm` doesn't land at all, the re-read
   in `arm_track/1` turns it into a loud error rather than a lie, so a failure
   here is visible either way.
3. **Open-ended take and the re-fire.** ⚠️ `stop_recording` assumes that firing
   a recording slot ends the take at the next launch-quantization boundary and
   drops the clip into looped playback. `record_clip` with no `bars`, then
   `stop_recording` → confirm it ends on the bar line and keeps looping. If
   Live does something else, the fallback is
   `/live/song/set/session_record 0` (immediate, unquantized) — a different
   address and a different reply.
4. **Echo wording.** ⚠️ Fire with the transport **playing** → the reply must say
   "Queued". That depends on `is_triggered` reading true between the fire and
   the boundary; if it reads false, `queued_or_nothing/2` mislabels a perfectly
   healthy take as a hard failure. Fire with the transport **stopped** →
   "Recording now."
5. **Audio take — the headline.** An audio track with an input routed, 4 bars →
   audible material in the clip. This is the capability the whole feature
   exists for and the one thing `capture_midi` can never do. A silent take
   means the input isn't set, which Seshat cannot see or fix.
6. **Non-4/4.** Set 6/8 with `set_time_signature` (numerator 6, denominator
   8), then `get_session_state` **without** `refresh: true` should already
   show 6/8 — confirms the property listener pushes the change to the mirror
   without a round-trip. Then `record_clip bars: 2` must give **two bars**,
   not four: `record_length_beats/3` counts quarter-note song beats
   regardless of signature (6/8 × 2 bars = 6.0 beats), confirmed against
   Live 2026-07-31.
7. **Guards, each producing its own error with nothing fired:** an occupied
   slot (names `delete_clip`), a group track (`can_be_armed` false), and an
   armable track whose `will_record_on_start` stays false (unroute its input).
8. **`stop_recording` boundaries.** On a fixed-length take it ends it early. On
   a slot that is merely *playing* it errors and the clip **keeps playing** —
   the guard must run before any fire, or the re-fire restarts the clip. On a
   slot in the queued window (fired, boundary not reached) it currently errors
   with "Slot S on track T is empty… nothing was fired", which is safe but
   misleading; note whether that window is long enough in practice to be worth
   a better message.
9. **Follow cam.** `record_clip` lands the view on the reddening slot in
   Session with the detail pane left alone; `stop_recording` opens the finished
   take in the note editor (or waveform, for audio).

## If the change touches the OSC network boundary or browser exports

Shipped 2026-07-30: `osc_server.py`'s command socket moved from binding
`0.0.0.0:11000` to `127.0.0.1:11000` only, and stopped rewriting its default
reply destination to the last sender; `browser.py`'s `/live/browser/export`
moved from opening a caller-supplied path with Live's privileges to choosing
its own file under `~/.seshat/browser-exports/`. Both live in the one fork
commit, so — per the bridge checklist above — nothing here means anything
without `mix abletonosc.install` and a Live restart (or AbletonOSC toggle)
first.

1. **The bind itself.** `lsof -nP -iUDP:11000`. The only AbletonOSC line must
   read `127.0.0.1:11000`; `*:11000` or `0.0.0.0:11000` is exactly the
   regression this change exists to close.
2. **The fixed default reply route.** `manager.py`'s `test_callback` replies
   with a bare `self.osc_server.send(...)`, not a tuple returned through
   `process_message`, so `/live/test` is the one call that exercises the
   removed last-sender rewrite directly — everything else here only proves the
   per-message reply path still works. No tool sends it, and the reply goes to
   the fixed 11001 that a running Seshat already owns, so **stop Seshat for
   the length of this check** (`[Errno 48] Address already in use` on the bind
   means you didn't):
   ```bash
   python3 -c '
   import socket, sys; sys.path.insert(0, "priv/AbletonOSC")
   from pythonosc.udp_client import SimpleUDPClient
   s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
   s.bind(("127.0.0.1", 11001)); s.settimeout(5)
   SimpleUDPClient("127.0.0.1", 11000).send_message("/live/test", [])
   print(s.recvfrom(1024))
   '
   ```
   Expect a datagram carrying `/live/test` and `ok` (Live also flashes
   "Received OSC OK" in its status bar — that only proves the callback *ran*,
   so it is not a substitute for receiving the reply). A timeout is the
   failure this check exists to catch, and nothing else here would catch it.
   If stopping Seshat isn't practical, item 3's listener push travels the same
   `osc_server.send` default route — record that you substituted it rather
   than reporting this item as run.
3. **Callback replies and listener pushes both still land on 11001.**
   `get_session_state(refresh: true)`, then change tempo or a track's volume
   by hand in Live, then call `get_session_state` again and confirm it sees
   the change. The first call is a direct reply; the second depends on a
   listener push reaching the fixed `127.0.0.1:11001` with no incoming
   datagram to retarget it — both are exactly what moved.
4. **Stale-export cleanup, with real fixtures.** Before running
   `reindex_library`, plant two files in `~/.seshat/browser-exports/` matching
   `seshat-browser-export-*.json`: one with a modification time more than ten
   minutes old (backdate it — `touch -A`/`os.utime`), one fresh. Reindex must
   succeed, remove the stale fixture, leave the fresh one alone, and clean up
   only the export it just created (`Catalog.consume_export/3`'s `after` block
   deletes nothing but the path Python replied with, and only once it has
   validated it). Remove the fresh fixture by hand
   once you've confirmed it survived — nothing in this system will ever do
   that for you.
5. **The obsolete path-taking form, from outside Seshat.** Send it with a
   send-only OSC client so nothing binds port 11001 and Seshat's own reader
   stays alive:
   ```bash
   python3 -c '
   import sys; sys.path.insert(0, "priv/AbletonOSC")
   from pythonosc.udp_client import SimpleUDPClient
   c = SimpleUDPClient("127.0.0.1", 11000)
   c.send_message("/live/browser/export", ["/tmp/seshat-should-not-exist.json"])
   '
   ```
   Confirm `/tmp/seshat-should-not-exist.json` was never created, and that
   Live's `Log.txt` shows `browser.py`'s clean "export takes no arguments"
   validation line rather than a traceback. Its reply goes to the fixed
   response port, never back to this client's socket, so the log line is the
   only observable outcome here — by design, since nothing else confirms the
   obsolete form was rejected rather than ignored.
6. **Log.txt, specifically for this section.** No bind error at startup, no
   traceback from either export path, no unknown-address error on `/live/test`
   or `get_session_state`'s underlying calls.
7. **The Elixir listener/decoder (shipped 2026-07-30, `Seshat.OSC.Transport` /
   `Seshat.OSC.Message`).** `@socket_opts` binds the reply port loopback-only
   and `handle_info/2` accepts a datagram only from `127.0.0.1:<send_port>`;
   `Message.decode/1` is a strict decoder that logs and drops anything it
   can't parse instead of crashing the transport — both are pure-tested
   (`message_test.exs`, `transport_test.exs`) but never against real
   AbletonOSC traffic. Run a normal session pass — `get_session_state(refresh:
   true)`, a `search_library` call with a large reply, `get_clip_slots` on a
   track with several clips (exercises the `N`-tag path), a track rename by
   hand in Live (listener push), and a Live restart (`/live/startup`) — then
   check Seshat's own Elixir console/log output (not Ableton's `Log.txt` —
   this is `lib/seshat/osc/transport.ex`, running in the BEAM). Expect
   **zero** occurrences of `Dropped OSC datagram from unexpected source` and
   `Dropped malformed OSC datagram`. Either one firing during ordinary use
   means the strict decoder or the source check is rejecting a legitimate
   AbletonOSC reply shape — the log line carries the reason and a byte
   preview, which is what would need loosening.

## If the change touches `Session.State`'s refresh or `get_session_state`'s reply

The mirror answers `nil` — "unknown" — for anything Ableton didn't answer, and
`get_session_state` renders that as unknown rather than a plausible number.
**Nothing in `mix test` executes any of it**: every changed branch lives in
`do_refresh/1`, which reaches `Transport.query/3` by design, so this checklist
is the verification by construction. The formatters are pure-tested
(`handlers_test.exs`); the failure path that produces `nil` at all is only
reachable here.

With the Seshat server running, **quit Ableton Live** (or toggle AbletonOSC off
in Live's MIDI preferences). Then, in order — steps 1 and 2 are timing-coupled,
so read both before starting:

1. **Force a failed refresh.** `get_session_state` with `refresh: true`, once →
   the timeout error from `maybe_refresh/1` ("Refreshing from Ableton timed
   out"). The GenServer is **still refreshing** when that error arrives: against
   a dead Ableton `do_refresh/1` takes roughly 47s (eight song queries at 5s
   each, the 5s `num_tracks` probe, the 2s returns probe) while the caller
   gives up at 30s, so about 17s of it remain.
2. **Read again immediately** (inside those ~17s), plain, **no** refresh → the
   mid-refresh error: "The session mirror did not answer — it may be mid-refresh
   against an unresponsive Ableton. Try again shortly". The call queues behind
   the running refresh and exits its own 5s call timeout. **This is a required
   check, not a caveat** — it is the only live exercise of that message, and it
   must read as "try again shortly", never as an empty session. If you miss the
   window the call simply succeeds; retry from step 1 rather than treating that
   success as a failure.
3. **Wait ≥10s, then read again**, plain, no refresh → the unknown-state reply.
   Expect tempo, time signature, key, playing state, groove amount and swing
   amount all reported unknown, the track list reported unknown-**not**-empty,
   and the trailing explanation
   sentence ("Unknown values mean Ableton did not answer…") present **exactly
   once**. **It must not say 120 BPM, 4/4, C Major, or list the previous set's
   tracks** — those four are the fabrications this behaviour exists to remove,
   and any of them appearing here is the whole check failing.
4. **Still with Live closed**, `record_clip` on any track with `bars: 4` → the
   time-signature-unknown error naming `refresh: true` and saying nothing was
   recorded. Not a crash (an `ArithmeticError` from a `nil` numerator), and not
   a generic timeout message.
5. **Start Live again.** AbletonOSC's `/live/startup` fires a refresh on its
   own; wait for it, then `get_session_state` plain → real values, no unknown
   remnants anywhere, and no trailing explanation sentence. This is the recovery
   half: listener re-subscription pushes the current value of everything, so
   anything a lost datagram nil'd repopulates without a manual refresh.

The rest of this section needs Live **running**, so it follows step 5 rather
than the dead-Ableton setup above. These check the degraded-rebuild path: a
rebuild that races a structural change gets no reply for an index that has just
gone, and must report the track list unknown rather than name what it managed to
read before the hole.

6. **The degraded rebuild is honest.** Ask for several tracks to be created and
   then removed **in one model response** — creates and deletes in the same
   instruction, so they land inside one debounce window and race the rebuild.
   Then read state once, plainly. Either the list is correct, or it reports the
   track list unknown — **it must never name a track that is not in Live's UI**.
   Compare the reply against Live's own track headers by eye; that comparison is
   the check. The race is timing-dependent and may take several attempts to
   provoke; a run that never degrades is **not a pass**, it is a run that did not
   test this. The log signature of a degraded rebuild is a `Song: …` line
   followed by `the read stopped at index …`, with **no `Loaded N tracks` line
   between them**: `Song:` is emitted before every rebuild's `num_tracks` probe,
   while `Loaded …` and the stopped-index warning are the two arms of one `case`
   and can never both describe the same rebuild. Healthy `Loaded …` lines from
   neighbouring rebuilds in the same burst are expected — don't read one as
   contradicting the degraded read.
7. **It recovers without `refresh: true`.** After a degraded read, make no
   further tool call and wait ~3s, then read plainly again: the list is correct.
   This is the single retry doing what the narrowed `refresh: true` no longer
   lets the model do for itself. If a structure push was still pending when the
   rebuild ran, the log shows it as a second `Song:` / `Loaded …` sequence
   following the informational `could not read the track list — retrying once`
   line, and **exactly one** such retry; if nothing was pending, recovery instead
   comes from the re-subscription echo (`Track list changed in Live —
   scheduling a session refresh`) and that line never appears. Either way, the
   check is the list being correct on the follow-up read.
8. **A genuine disagreement still brakes.** Not reproducible on demand and not
   required to pass — but if a `did not reproduce it` warning appears in the log
   during any of this, confirm it is followed by no further refresh for that
   list. The brake is what stops the flood, and the failed/disagreed split must
   not have loosened it for the disagreed case.
9. **The settling marker appears and clears.** Creates plus a plain read in one
   model response → the reply carries "A structural change is still settling…".
   A later plain read, after the window, does not. `refresh: true` never carries
   it (`refresh_sync/0` cancels the timer before rebuilding).
10. **The orchestration check.** In Claude Desktop, create three tracks in one
    request, then say "undo that". The trace must be exactly three `undo` calls
    followed by **one** ordinary `get_session_state` — no read between undos, no
    second read after. This verifies the shipped `get_session_state` description
    rather than the mirror, and it is the check that failed on 2026-08-01. Run it
    last, since it is the end-to-end statement of the whole item.

## If the change touches mirror-refresh coalescing (`Session.State`'s scheduler)

Asynchronous refreshes are debounced: `refresh/0` and the structure pushes move
one trailing timer to **one second** after the latest request, and only then does
a single rebuild run. The guarantee is a bounded backlog — at most one running
rebuild plus one scheduled one. State correctness alone cannot see any of this:
one refresh and twenty redundant ones leave the same mirror. **Read the server
log and count rebuilds** — a full one prints a `Song: …` line followed by
`Loaded N tracks: …`.

**How the calls are issued is part of the check, not a detail.** Checks 2, 3 and
4 need a second call to land *inside* the one-second window. Measured on this
machine 2026-07-31: tool calls emitted **in one model response** arrive ~0.5s
apart, while calls needing **separate model rounds** arrive ~2.1s apart at the
floor — after the timer has already fired. So ask for the whole sequence in a
*single instruction* and let it come out as several tool calls in one response;
one message per step silently tests nothing, and reports success while doing it.
Check 1 is exempt: it asserts a refresh does *not* happen, so spacing can't fake
a pass.

No bridge reinstall or Live restart is required — this is Elixir-only.

1. **The seven scalar setters no longer refresh.** Issue the four return mixer
   setters (volume, pan, mute, solo) and the three master ones (volume, pan, cue
   volume) in a burst, then `get_session_state` **without** `refresh: true`: it
   answers and carries the pushed final values. The log shows **no** full-refresh
   `Song:` / `Loaded …` sequence caused by those setters. If the four return
   values are the ones that don't arrive, the fix is to restore `State.refresh()`
   in those four handlers only — their listener pushes were inferred from the
   master ones, never measured.
2. **A burst of creates collapses.** On scratch material, create several tracks
   with a distinct final name, **with the creates and the read in one model
   response**. An ordinary read during the quiet window answers promptly (it may
   still show the pre-create structure — that snapshot window is intended); after
   the window, state includes the final track. Record the log timestamps of every
   tool call and every `Song:` / `Loaded …` sequence: calls closer together than
   the window must share one trailing refresh, and calls separated by longer model
   rounds may form several windows — report the observed count rather than
   claiming the whole request was one window. At no point may finished calls leave
   a *chain* of refreshes queued; after the last call exactly one trailing refresh
   converges the mirror. Delete every scratch track afterwards.
3. **`refresh: true` absorbs the pending timer.** While an asynchronous refresh
   is pending, call `get_session_state(refresh: true)` — issue the mutation and
   the refreshing read **in one model response**, or the timer has already fired
   and nothing is pending when the read lands, which reads as a pass. It rebuilds
   immediately, and **no duplicate refresh appears a second later**.
4. **The last request is never dropped.** Make one more structural mutation while
   a rebuild is already running (it lasts 1.0–1.8s, so again from the same model
   response), and confirm one trailing refresh follows it and the final mutation
   is present afterwards. Check the log timestamps to confirm the mutation really
   landed *mid*-rebuild: arriving just after one looks identical in the final
   state and is the likely near-miss.
5. **The dead-Ableton reply is still honest.** `get_session_state` now makes one
   `snapshot/0` call instead of four narrower ones, so re-run steps 1 and 2 of the
   `Session.State` refresh section above with Live unavailable: the plain read
   made while the forced refresh is still running must still say "the session
   mirror did not answer", never stale state and never an empty session.

## If the change touches session guidance (`Seshat.Instructions` or a tool description)

The only checks in this repo that exercise **what the model says** rather than
what the code does. Nothing in `mix test` reaches any of this, so a rule can be
deleted, truncated away, or moved to a description that swallows it, and every
suite stays green.

**Check delivery first — it is silent when it fails.** Instructions reach the
model only in a conversation set to run **on your computer**; a cloud session
reaching the Mac through the remote-devices bridge gets the tools (namespaced
`mcp__remote-devices__seshat__*`) and no instructions at all. And the client
truncates at **2,048 characters** mid-sentence without saying so, dropping the
*end* of the text. Confirm both in one question, in a fresh conversation:

> Quote the seshat server instructions you were given, in full.

The tools should be `mcp__seshat__*`, and the quote should end with the last
line of `@text` in [lib/seshat/instructions.ex](lib/seshat/instructions.ex).
If it stops early, the text is over the cap and everything past the cut is
being written for nobody.

Then the behaviours, each tied to a rule and to where that rule now lives:

1. **Out of reach** (instructions) — "switch my audio output to the
   headphones." Expect: says plainly it can't, names where the setting lives
   in Live, offers no improvised workaround.
2. **Manual steps** (instructions) — a "why can't I see X?" question. Expect
   the shortest complete path, keys located physically ("press Tab, above the
   Caps Lock key"), each step confirmed by what appears on screen. Not a
   lecture, and not an assumption of Live fluency.
3. **The view follows you** (instructions) — two halves. Post-action: after a
   `write_midi_notes`, ask "where is it?" Expect a description of what is
   *already* on screen, not navigation directions — the follow cam moves
   Live's view but tells the model nothing, so its own smoke test passes
   whether or not this rule survives. Pre-action: while Live shows Arrangement,
   ask to launch a named Session clip. Expect `show_view(Session)` called
   before `fire_clip`, so the launch happens visibly instead of off screen
   (see "If the change touches the view tools" above for the full sequencing
   check, including when the model should read `get_view_state` first instead).
4. **Speak music, not plumbing** (instructions + `get_session_state`) — any
   multi-track exchange. Expect track names or 1-based numbers throughout,
   and no tool names, raw indices, tags, or catalog internals leaking into
   prose — including in replies that have nothing to do with reading state,
   which is what would show the rule being read too narrowly since it moved.
5. **Directive acts, open offers** (`search_library`) — "load me a warm pad"
   should load the closest match, say why in a phrase, and name a runner-up.
   "What should we use for the pad?" should offer a short slate with a musical
   reason each. Two different shapes from one tool.
6. **Diagnostics stay internal** (`search_library` reply) — a search with a
   vocabulary miss ("warm electric piano"). Expect musical choices; expect no
   mention of tags, tag counts, or "no such tag" reaching the user.

Report which rules held and which drifted, and say which channel each one is
in — a rule that fails after moving into a tool description is evidence about
the division in `Seshat.Instructions`'s moduledoc, not just about wording.

## If the change touches the advertised MCP schema (`Seshat.MCP.Schema` or a tool's JSON Schema)

`mix test` asserts the *generated* `input_schema` inside the BEAM. It cannot tell
you whether a real client accepts what that encodes to, and the failure mode is
not one bad call — a client that rejects the schema refuses the **whole list**,
so every tool silently disappears and the session looks like Seshat was never
connected.

1. **List the tools over a real handshake.** Not through this conversation's tool
   list: a client caches `tools/list` at connect, so after restarting the server
   your cached list is the *old* schema and proves nothing. This is also how you
   tell "the server is wrong" from "my client is stale" — the distinction that
   otherwise costs twenty minutes.

   ```bash
   python3 -c '
   import json, urllib.request
   U = "http://localhost:4000/mcp"
   H = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
   def post(body, sid=None):
       h = dict(H)
       if sid: h["Mcp-Session-Id"] = sid
       r = urllib.request.urlopen(urllib.request.Request(U, json.dumps(body).encode(), h), timeout=15)
       raw = r.read().decode()
       if raw.startswith(("event:", "data:")):
           raw = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")][0]
       return json.loads(raw), r.headers.get("Mcp-Session-Id")
   _, sid = post({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}})
   post({"jsonrpc":"2.0","method":"notifications/initialized"}, sid)
   t, _ = post({"jsonrpc":"2.0","id":2,"method":"tools/list"}, sid)
   tools = t["result"]["tools"]
   print("tools listed:", len(tools))
   print(json.dumps(next(x for x in tools if x["name"] == "set_track_pan")["inputSchema"]["properties"]["value"]))
   '
   ```

   The count must match `Definitions.all()`, and the property you changed must
   carry what you intended. Swap `set_track_pan`/`value` for whatever moved.

2. **Then Claude Desktop specifically**, in a fresh conversation: confirm the
   tools appear at all. It is the client nothing else here exercises, and the one
   with a history of failing quietly (it truncates server instructions at 2,048
   characters without saying so). A schema it dislikes shows up as an empty tool
   list, not an error message.

3. **Call one tool per changed shape** and confirm a valid call still lands and
   an invalid one is refused without reaching Live — read the target back, since
   a refusal that silently *did* send is the thing worth catching.

Recorded 2026-07-30, when bounds moved into the advertised schema: the encoded
shape became `oneOf: [{"type": "number", "minimum": …, "maximum": …}, {"type":
"integer", …}]`. Bounds *inside* `oneOf` branches were the untested combination;
all 53 tools listed fine over a raw handshake, and Claude Desktop was not
covered.

## If the change touches how MCP mode rejects a bad call (`Seshat.MCP.Server`'s `handle_request/2`, `Seshat.Tools.Validation`)

`mix test` covers this seam purely — `handle_request/2` is request map in, reply
tuple out, and `Seshat.MCP.ServerTest` drives it directly. The live check exists
anyway because the defect was *found* by a real client swallowing the useful
text: Claude Code shows a JSON-RPC `-32602` as nothing but `MCP error -32602:
Invalid params`, `data.message` and all. So the check of record is
client-shaped: what comes back over a real handshake, not what the BEAM returns.

With the server running (same `post`/`sid` helper as the schema section
above, reproduced here so this block is copy-pasteable on its own):

```bash
python3 -c '
import json, urllib.request
U = "http://localhost:4000/mcp"
H = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
def post(body, sid=None):
    h = dict(H)
    if sid: h["Mcp-Session-Id"] = sid
    r = urllib.request.urlopen(urllib.request.Request(U, json.dumps(body).encode(), h), timeout=15)
    raw = r.read().decode()
    if raw.startswith(("event:", "data:")):
        raw = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")][0]
    return json.loads(raw), r.headers.get("Mcp-Session-Id")
_, sid = post({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}})
post({"jsonrpc":"2.0","method":"notifications/initialized"}, sid)
bad, _ = post({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_track_pan","arguments":{"track":0,"value":2.0}}}, sid)
print("out of range:", json.dumps(bad)[:400])
unknown, _ = post({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}, sid)
print("unknown tool:", json.dumps(unknown)[:300])
'
```

- The out-of-range call must come back as a **tool result** — a `result` with
  `"isError": true` whose text names the bound and the value it got (`must be
  at most 1.0 (got 2.0)`), with no Peri internals (`{:float,`) in it. An
  `"error"` key with `-32602` means the interception is gone.
- The unknown tool name must stay a JSON-RPC `-32602`. That is what the MCP
  spec says an unknown tool is, and it is the discriminator that keeps the
  rewrite from swallowing real protocol errors.
- Then read the target back (`get_session_state`) and confirm the rejected pan
  never reached Live — a refusal that silently *did* send is the thing worth
  catching.

Worth doing in Claude Code itself once, too: a bad call should read as a
retryable message in the transcript, not as an opaque protocol error.

## If the change touches undo granularity (`Handlers.call/2`'s undo wrap, `song.py`'s step methods)

Nothing in `mix test` proves any of this. The suite pins the *wire shape* —
`begin_undo_step`, the tool's own messages, `end_undo_step`, in that order — but
whether Live actually collapses them into one history entry happens inside Live,
and both addresses are send-only, so a Remote Scripts copy predating the fork
pin drops them indistinguishably from success. Run `mix abletonosc.install` and
**restart Live** first (see "First, if the change touches the bridge" above);
item 1 is what catches a skipped reinstall.

The failure this exists to prevent: before the wrap, `create_track` followed by
`write_midi_notes` collapsed into **one** step on Live 12.4.3, so a single
`undo` deleted the whole track, notes and all — and the same pair with an
intervening timed-out call landed as two. Unpredictable, not merely coarse.

1. **The headline.** `create_track` (name it), then `write_midi_notes` into it,
   then **one** `undo`. The clip and its notes disappear; **the track stays.**
   A vanished track means the wrap isn't reaching Live — reinstall and restart
   before reading anything else here as a real result.
2. `undo` again: the track goes.
3. `redo` twice: both come back, one step at a time — clip first, in the
   original order.
4. **Read-only tools cost nothing.** `get_session_state`, then `search_library`,
   then `undo`. The undo reverts the last real *change*, not one of the reads —
   an empty begin/end pair leaves Live's history untouched, which is what lets
   every tool be wrapped without maintaining a mutating-tool list.
5. **A multi-message tool is still one step.** `create_return_track`, or a
   `write_midi_notes` over an existing clip, undone in one call. `write_midi_notes`
   is three OSC messages (create clip, add notes, name it) and must revert as a
   unit, because the wrap encloses the whole dispatch rather than each datagram.
6. **An error path still closes its step.** Call something that fails cleanly —
   `fire_clip` on an empty slot, `quantize_clip` with `amount: 0` — then make a
   real change and `undo` it. The undo must revert exactly that change; if the
   failed call had leaked an open step, the two would be grouped.

Then, **outside this checklist, in the real Claude Desktop client** (a smoke
agent following an explicit list would only prove it can follow the list): ask
for three named tracks in **one** user message, then say "undo that request."
Confirm the model issues **three** `undo` calls and all three tracks disappear.
Seshat never sees the original prompt — only the individual tool calls — so this
is the only check that the `undo` tool description actually teaches the model to
repeat the call. If it undoes once and stops, the fix is that description.

## If the change touches undo/redo *reporting* (the `can_undo` / `can_redo` guards)

`/live/song/undo` and `/live/song/redo` never reply, so the handler's reply can
only ever confirm the request — and the guard read before the send is the only
thing that can turn "off the end of the history" into an honest refusal. Both
guard addresses are upstream properties that already ship, so no reinstall is
needed here.

Nothing in `mix test` settles the live half: the suite supplies the guard's
reply itself, so it proves how Seshat *reacts* to a `false`, never that Live
ever says `false`.

**Already measured — don't re-derive it (2026-08-02, Live 12.4.3, probe rig).**
`Song.can_undo` and `Song.can_redo` are plain `bool` attributes, not methods and
not raising, so a reply is always encodable. They track availability
*independently and in both directions*: in a set reading `can_undo=True
can_redo=True`, one new edit (a `create_midi_track`) flipped `can_redo` to
**False** while `can_undo` stayed `True`, and undoing that edit flipped
`can_redo` back to `True`. So the property is not hardwired true, and the
guard's `false` branch is reachable. What remains unmeasured is only
`can_undo=False` at a genuinely empty history — check 1 below.

1. **The `can_undo` boundary, in a brand-new empty set.** File → New Live Set
   (hold Command and press N), touch nothing, then call `undo`. Expect the error
   — "Live reported no undo step available, so no undo was sent" — and **not** a
   success string. This is the one reading the probe above could not reach
   without spending the open set's history. If `undo` reports the request as sent
   instead, `can_undo` alone is always true, and the finding is that the *undo*
   guard should be dropped rather than widened — say so in the report; the redo
   guard stands on the measurement above either way.
2. **An ordinary undo still works and still moves exactly one step.**
   `create_track`, then `undo`: the track disappears, and the reply says the
   request was sent rather than claiming history moved. Then `redo` once and
   confirm it comes back.
3. **A refusal is not a dead end.** After 1, make any real change and `undo` it:
   the refusal must not have left the guard stuck — the next call reads Live
   again, not a remembered answer.

## Clean up and report

5. Delete any scratch tracks/scenes/clips you created (`delete_track`,
   `delete_scene`, `delete_clip`) or use `undo` for in-place changes. Leave
   the session as you found it.
6. Report: what you exercised, what you verified by reading state back, what
   failed or timed out, and what can only be judged by ear (sound choice,
   levels, timing feel) — flag those explicitly for the user to check.
7. **If the branch has an open PR, write the results into its body.** A smoke
   test is the only evidence that the live half works, and it is exactly the
   evidence a reviewer cannot reproduce — the PR body is where it belongs.

   ```bash
   gh pr view --json number,body --jq .number   # empty output = no PR, stop here
   ```

   Read the existing body, edit it, and write it back from a file:

   ```bash
   gh pr view --json body --jq .body > /tmp/pr-body.md
   # edit /tmp/pr-body.md, then:
   gh pr edit --body-file /tmp/pr-body.md
   ```

   **Never pass `--body` inline and never retype the body from memory** — both
   silently discard whatever you did not reproduce, and the plan report and
   review verdict already in there are not yours to drop.

   Add (or, on a re-run, *replace*) one section headed
   "Live verification — smoke-tested DATE", taking DATE from the `date`
   command, placed directly after the summary so it reads before the
   implementation detail. Put in it:

   - the headline behaviour, stated as what a user would notice, not as a tool
     call: what was broken before and what happens now;
   - a table of what you exercised and what came back — normal call, boundary,
     invalid input, and the read-back that proves the effect actually landed;
   - **what you did not cover, named specifically.** An untested client, a
     hardware path you had no input routed for, a check you skipped because
     Live was in the wrong state. A smoke test that reports only successes reads
     as full coverage and quietly retires the checks nobody ran.

   Correct anything the body now states falsely — a body written before the run
   usually carries an open question the run just answered, and leaving it says
   the work is still outstanding.

   Findings that are real but out of scope for the branch go in the body as
   findings *and* into [docs/ROADMAP.md](docs/ROADMAP.md) as an issue, cited by
   title. The body is read once at merge; the roadmap is the queue.
