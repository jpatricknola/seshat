# Bridge options: AbletonOSC vs a Max for Live WebSocket device

Seshat reaches Ableton through **AbletonOSC**, a Python MIDI Remote Script
speaking OSC over UDP. The recurring alternative idea is a **Max for Live
device speaking WebSocket**. This note records the trade-off so the question
doesn't get re-litigated from scratch. Current decision: **stay on
AbletonOSC**; treat M4L as the escape hatch if a Remote Script hits a wall.

## What a M4L WebSocket bridge would buy

All of it comes down to one thing: **TCP reliability you can see.**

- **Connection state.** A connect/disconnect event the moment Ableton goes
  away, instead of today's 5-second query timeouts against silence.
- **Real errors.** "No such command" replies instead of nothing. The classic
  AbletonOSC failure — wrong address, dropped packet, dead Ableton all look
  identical (silence) — disappears.
- **Delivery and ordering guarantees.** No fire-and-forget.
- **No datagram size limits.** Bulk payloads (browser listings, catalog
  exports) wouldn't need to fit through UDP packets.
- Same power: M4L devices have full Live API access, like a Remote Script.

## What it would cost

- **Live Suite only.** Max for Live requires Suite (or the paid add-on).
  Remote Scripts work on every edition, including Standard. For distribution,
  that's a hard regression.
- **The device must be in the set** — every project, or baked into the user's
  default template. A Remote Script installs once, globally.
- **A new toolchain.** A Max patch plus its JS runtime, with its own quirks —
  versus Python we already know and already extend (`priv/AbletonOSC/abletonosc/browser.py`).
- **A rewrite of everything below `Handlers`.** The tool contract in
  `Seshat.Tools.Definitions` survives; the transport, address vocabulary,
  value conventions, and listener mechanism don't. All current sites are
  greppable via `"/live/`.

## Why we stay: the real pain has cheaper fixes

The genuine problem is UDP silence, and it can be attacked inside AbletonOSC,
which we already vendor into:

- An ACK convention in our own handler (e.g. `browser.py` answering an echo
  for any command).
- Following every `set` with a cheap `get` to confirm the change landed —
  a pattern some tools (`set_device_parameter`) already use.

That's most of the reliability win with no Suite requirement and no rewrite.

## When to reopen this

Reopen only if a workflow needs something a Remote Script fundamentally can't
do — not for incremental reliability annoyance, which the fixes above cover.
