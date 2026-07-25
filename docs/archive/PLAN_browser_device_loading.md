> **Archived 2026-07-26 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. `list_browser_items` and
> `load_device` exist today. Do not treat this as current documentation —
> see [CLAUDE.md](../../CLAUDE.md) and [abletonosc-api-docs.md](../abletonosc-api-docs.md).

# Implementation Plan: Browser + Device Loading Tools

`list_browser_items` + `load_device`

## Context

Seshat can create MIDI tracks and write notes, but has no way to load an
instrument or effect — so every arrangement it builds is silent. This is the
#1 capability gap. Fix: two new tools, `list_browser_items` (search Live's
browser) and `load_device` (load a browser item onto a track).

**Key constraint discovered during research:** upstream AbletonOSC has *no*
browser API at all (confirmed in
[abletonosc-api-docs.md](abletonosc-api-docs.md) and against the upstream
repo). The Live Object Model does support it (`Application.browser` →
`BrowserItem` trees with stable `.uri`s; `browser.load_item(item)` loads onto
the *selected* track). The community-standard approach (e.g.
ahujasid/ableton-mcp) is a custom remote-script endpoint. So this feature has
a Python half: a vendored AbletonOSC handler extension, distributed from this
repo (no fork to maintain).

## Part 1 — OSC address contract (Seshat extension addresses)

**`/live/browser/get/items`** — request `[category(s), filter(s), max_results(i)]`

- `category`: `instruments | sounds | drums | audio_effects | midi_effects | plugins | samples | user_library`
- `filter`: case-insensitive substring on item name, `""` = none;
  `max_results` clamped 1..100 (default 25 Elixir-side)
- Reply (same address so `Transport.query` matches): success
  `[category, filter, "ok", returned(i), total(i), name, uri, name, uri, ...]`;
  error `[category, filter, "error", message]`
- Only loadable leaf items returned (folders flattened). 25 items ≈ 4KB —
  well inside one UDP datagram.

**`/live/browser/load_item`** — request `[track_index(i), uri(s)]`

- Reply: success `[track_index, uri, "ok", loaded_device_name]`; error
  `[track_index, uri, "error", message]`
- Python handler sets `song.view.selected_track` immediately before
  `load_item` (atomic — avoids a two-message OSC race), then reads the
  track's device list post-load so the reply positively confirms what loaded
  (UDP is otherwise silent-fail).

## Part 2 — Python handler: new file `priv/abletonosc/browser.py`

`BrowserHandler(AbletonOSCHandler)` following the AbletonOSC pattern
(`init_api()` + `self.osc_server.add_handler`; returned tuple is sent as the
reply):

- `_index(category)`: iterative DFS over the category root, collecting
  `(name, uri, item)` for loadable items. Caps: `MAX_SCAN_NODES = 20000`,
  `MAX_DEPTH = 6` — the walk runs on Live's UI thread, so these bound
  worst-case stalls on huge samples/packs trees. Result cached per category
  for the Live session; cache keeps the live `BrowserItem` so load needs no
  second walk.
- `_get_items(params)`: validate category, filter cached index, reply with
  `returned`/`total` counts + name/uri pairs.
- `_load_item(params)`: validate track index against `song.tracks`, find item
  by uri (cache first, then lazy-index remaining categories), select track,
  `browser.load_item(item)`, reply with last device name on the track (falls
  back to the item name — some VST/AU instantiate async). All error paths
  reply on the same address so queries resolve instead of timing out.
- ⚠️ Verify exact base-class helpers (`self.song`, reply-on-return) against
  the installed AbletonOSC source when writing this file. Local install:
  `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`.

## Part 3 — Distribution: `mix abletonosc.install`

New `lib/mix/tasks/abletonosc.install.ex`:

1. Locate AbletonOSC: explicit path arg, else probe
   `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC` (and app-bundle
   MIDI Remote Scripts dirs).
2. Copy `priv/abletonosc/browser.py` → `<install>/abletonosc/browser.py`.
3. Idempotently patch `<install>/abletonosc/__init__.py` (add
   `from .browser import BrowserHandler`) and `manager.py` (add
   `BrowserHandler` to the handler list, anchored on an existing handler
   line).
4. If a patch anchor isn't found (upstream drift), abort that step and print
   the exact 2-line manual edit instead of guessing.
5. Print "restart Ableton Live (or toggle AbletonOSC off/on in Preferences)".

Manual fallback (copy file + 2-line edit) documented in README.

## Part 4 — Elixir transport: per-call timeout

[transport.ex](../lib/seshat/osc/transport.ex): `query/2` → `query/3` with
`timeout \\ 5000` (backwards compatible). A timed-out call leaves stale
`pending`, but the next query overwrites it and a late `GenServer.reply` to a
dead caller is a no-op — document in a comment. Use `15_000` for browsing
(first index of a big category is slow), `30_000` for loading (heavy
plugins).

## Part 5 — Tool definitions

[definitions.ex](../lib/seshat/tools/definitions.ex) — two entries per
[adding-a-tool.md](../.claude/docs/adding-a-tool.md). Descriptions are the
model's entire prompt in MCP mode — they must teach the workflow:

- `list_browser_items(category*, filter, max_results)` — category enum as
  above; explain each category, "a MIDI track is silent until an instrument
  is loaded", "always call this before load_device, never guess a uri", "use
  a filter to keep results small", "first search of a large category may take
  seconds".
- `load_device(track*, uri*)` — 0-based track indices, uri comes from
  `list_browser_items`, instruments make MIDI audible, audio effects append
  to the chain, reply names the loaded device.

## Part 6 — Handlers

[handlers.ex](../lib/seshat/tools/handlers.ex) — two `do_call/2` clauses
above the catch-all, each `catch :exit` for timeout (same pattern as
`get_session_state`) with actionable messages ("try a narrower filter",
"heavy plugin may still be loading"):

- `list_browser_items`:
  `Transport.query("/live/browser/get/items", [category, filter, max_results], 15_000)`,
  pattern-match `"ok"`/`"error"` at position 2.
- `load_device`:
  `Transport.query("/live/browser/load_item", [track, uri], 30_000)` →
  `"Loaded '<name>' onto track <n>"`.
- Pure helper `format_browser_items/2` (public for testability, like
  `stringify_keys/1`): chunk name/uri pairs, one line per item, append
  "Showing X of Y matches — refine the filter" when truncated, friendly
  message when empty.

## Part 7 — Tests + docs

1. [definitions_test.exs](../test/seshat/tools/definitions_test.exs): count
   32 → 34; add names to expected list.
2. Handlers test: unit-test `format_browser_items/2` (truncated / empty /
   well-formed). Do **not** test the `do_call` clauses — they hit
   `Transport.query` (needs live Ableton). MCP parity is automatic via
   `Seshat.MCP.ToolsTest`.
3. [abletonosc-api-docs.md](abletonosc-api-docs.md) (canonical address list —
   project rule): new "Browser API (Seshat extension — not in upstream
   AbletonOSC)" section with both addresses + install note.
4. [CLAUDE.md](../CLAUDE.md): "32 tool definitions" → 34, test count;
   one-line note that `priv/abletonosc/` vendors the remote-script extension.
   [adding-a-tool.md](../.claude/docs/adding-a-tool.md): `== 32` mention.
   [README.md](../README.md): install step + fallback.
   [PLAN_remaining_osc_tools.md](PLAN_remaining_osc_tools.md): mark browser
   loading done.
5. `mix precommit`.

**Sequencing:** Python handler + install task → `query/3` → definitions +
handlers + tests → docs → `mix precommit`.

## Verification (end-to-end, needs Ableton Live running)

1. `mix abletonosc.install`, restart Live, `Transport.query("/live/test", [])` ok.
2. `iex -S mix`: query `["instruments", "operator", 10]` → "ok" + name/uri
   pairs; unfiltered `["samples", "", 25]` returns ≤25 within 15s, second
   call fast (cache).
3. Full MCP workflow: `create_track` (midi) → `list_browser_items` →
   `load_device` → device visible in Live UI → `write_midi_notes` →
   `fire_clip` → **audible sound**. Then load a Reverb onto the same track →
   appends after the instrument.
4. Error paths: bad uri, track 99, unknown category — all return error
   messages, no timeout/crash; queries still work afterward.
5. `mix precommit` green with Ableton closed.

## Risks / follow-ups

- Installer patching is version-brittle vs upstream AbletonOSC — mitigated by
  anchor-detect + abort-to-manual-instructions.
- Scan caps may incompletely index very large libraries — `total` count +
  "refine the filter" guidance keeps that visible; tune caps during
  verification.
- `/live/api/reload` may not pick up a *new* module — restart Live after
  install (reload works for later edits to browser.py).
- Return/master tracks not supported (`song.tracks` only) — follow-up if
  wanted.
- Surfacing loaded devices in `get_session_state` is deliberately out of
  scope — already planned under Device Parameter Control in
  [PLAN_remaining_osc_tools.md](PLAN_remaining_osc_tools.md).
