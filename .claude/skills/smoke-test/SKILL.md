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

## First, if the change touches a vendored address

`/live/browser/*`, `/live/return_track/*` and `/live/master/*` are Seshat's own
— served by [priv/abletonosc/browser.py](priv/abletonosc/browser.py) and
[priv/abletonosc/return_track.py](priv/abletonosc/return_track.py), installed
by `mix abletonosc.install`. `mix test` cannot reach them at all, so a smoke
test is the *only* thing standing behind that whole surface. Before anything
else:

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

## Clean up and report

5. Delete any scratch tracks/scenes/clips you created (`delete_track`,
   `delete_scene`, `delete_clip`) or use `undo` for in-place changes. Leave
   the session as you found it.
6. Report: what you exercised, what you verified by reading state back, what
   failed or timed out, and what can only be judged by ear (sound choice,
   levels, timing feel) — flag those explicitly for the user to check.
