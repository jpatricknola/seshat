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

`/live/clip/quantize` and `/live/browser/preview_item` / `stop_preview` are
served by the fork but have no Seshat tool (roadmap: `quantize_clip` and browser
preview audition), so the MCP
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
   **known wart** recorded in [docs/TOOL_AUDIT.md](docs/TOOL_AUDIT.md) §05: the pair-context read happens before the `looping` toggle goes out, so
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
6. **Non-4/4.** ⚠️ In a 6/8 set, `bars: 2` must give **two bars**, not four.
   `record_length_beats/3` assumes `record_length` counts quarter-note song
   beats (so 6/8 × 2 bars = 6.0), which is unverified — the 2026-07-29 check
   was 4/4, where the two conventions coincide. Wrong ⇒ one line in that
   function.
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
3. **The view follows you** (instructions) — after a `write_midi_notes`, ask
   "where is it?" Expect a description of what is *already* on screen, not
   navigation directions. This one is pure instruction: the follow cam moves
   Live's view but tells the model nothing, so its own smoke test passes
   whether or not this rule survives.
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

## Clean up and report

5. Delete any scratch tracks/scenes/clips you created (`delete_track`,
   `delete_scene`, `delete_clip`) or use `undo` for in-place changes. Leave
   the session as you found it.
6. Report: what you exercised, what you verified by reading state back, what
   failed or timed out, and what can only be judged by ear (sound choice,
   levels, timing feel) — flag those explicitly for the user to check.
