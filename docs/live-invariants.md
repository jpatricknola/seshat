# Live invariants

Checks that need a running Ableton and outlive any one feature. `/smoke-test`
runs the sections a change touches; `/full-smoke` sweeps the whole file
regardless of branch.

**This is not where feature verification goes.** A check that verifies *this
feature works* belongs in that feature's plan doc, written by
`/write-smoke-tests` and archived with the plan once it ships — its job is done
when it passes. Only three kinds of check are admitted here:

- **standing properties** of the system, tied to no feature;
- **tripwires guarding a corrected measurement** — a check that exists because
  someone once believed a wrong number, and the documentation would happily
  lead the next person back to it;
- **model-behaviour probes** tied to `Seshat.Instructions` rather than to any
  tool.

Entry is by promotion at `/ship`, never by writing here directly. That gate is
the only thing standing between this file and the fate of the monolithic
smoke-test checklist it replaced, which grew a section per feature and never
lost one.

**`Last verified` is load-bearing.** Every section carries one, and a run that
exercises a section updates it. Nothing else in this repo records whether the
live layer has actually been exercised — `mix test` cannot reach any of it, so
a section that has gone a long time without a date is the honest signal that
nobody has checked. Leave the date alone if you substituted something for the
check; note the substitution in the run report instead.

**Measurements cited here live in
[abletonosc-api-docs.md](abletonosc-api-docs.md)**, dated and version-stamped.
Never restate a number here — link to it. A number copied into a checklist is a
duplicate nobody keeps in sync.

---

## Bridge integrity

*Last verified: — (promoted from the previous checklist 2026-08-02; no run
recorded)*

`/live/browser/*`, `/live/return_track/*` and `/live/master/*` are Seshat's own,
served by the fork at [priv/AbletonOSC/](../priv/AbletonOSC/). `mix test` greps
the submodule in the repo; Live runs the copy in Remote Scripts. Nothing else in
this project can tell you those two agree.

1. **The extension is answering at all.** `get_session_state` prints return
   tracks and master volume when `return_track.py` is loaded, and a single
   "Return/master state unavailable" line when it isn't. A whole feature reading
   as broken usually means a skipped `mix abletonosc.install` and Live restart —
   check this before diagnosing anything else.
2. **A bad index errors immediately, not after ~2s.** These handlers always
   reply, including on an out-of-range index, and the reply names the real
   count. A ~2s timeout instead means the installed copy is stale. That
   distinction is the entire point of the reply envelope, and it is the cheapest
   stale-install detector there is. Try it at every depth, not just the track:
   a bad *device* index on `set_device_parameter` or `bypass_device` against a
   valid return must error the same way — that case once came back as a false
   "try again" timeout because the parameter index was echoed as `-1`.
3. **Live's `Log.txt` stays clean during ordinary work.** Baseline its byte size
   before the run and read only the tail. Upstream raised a `RemoteScriptError`
   on every clip-slot operation, so a traceback during `write_midi_notes`,
   `delete_clip`, `duplicate_clip` or `get_clip_slots` means an old AbletonOSC is
   still installed. (`~/Library/Preferences/Ableton/Live <version>/Log.txt`.)
4. **The listener rebind, by hand in Live's UI.** Delete a track, then rename a
   *different* one, then `get_session_state`. Every name must be under the right
   index. This guards the fork's fix to `AbletonOSCHandler._stop_listen`, which
   unbound a listener from the wrong object once an index had been reused. It is
   the one fix whose failure is completely silent — every address still answers —
   so nothing but this check finds it. Do it by hand: a tool-driven substitute
   exercises the same LOM mutation but proves nothing about UI-originated edits.

## OSC network boundary

*Last verified: — (promoted 2026-08-02; the bind and export changes shipped
2026-07-30)*

The command socket binds `127.0.0.1:11000` only, and `process()` does not
retarget its default reply destination to the last sender. Upstream's defaults
are reasonable for driving Live from a phone on the LAN and wrong here — every
OSC address controls Live and nothing on the wire authenticates.

1. **The bind.** `lsof -nP -iUDP:11000`. The only AbletonOSC line must read
   `127.0.0.1:11000`; `*:11000` or `0.0.0.0:11000` is exactly the regression
   this exists to close.
2. **The fixed default reply route.** `manager.py`'s `test_callback` replies
   with a bare `self.osc_server.send(...)` rather than a tuple through
   `process_message`, so `/live/test` is the one call that exercises the removed
   last-sender rewrite directly. No tool sends it, and the reply goes to the
   fixed 11001 that a running Seshat already owns — so **stop Seshat for the
   length of this check** (`[Errno 48] Address already in use` on the bind means
   you didn't):

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

   Expect a datagram carrying `/live/test` and `ok`. Live also flashes "Received
   OSC OK" in its status bar — that only proves the callback *ran*, so it is not
   a substitute for receiving the reply. A timeout is the failure this check
   exists to catch, and nothing else here would catch it. If stopping Seshat
   isn't practical, a listener push travels the same `osc_server.send` default
   route — record that you substituted it rather than reporting this as run.
3. **The obsolete path-taking export form is rejected.** `/live/browser/export`
   chooses its own file under `~/.seshat/browser-exports/` and takes no
   argument. Send the old form with
   `.claude/skills/smoke-test/scripts/osc_send.py /live/browser/export /tmp/seshat-should-not-exist.json`
   and confirm the file was never created and `Log.txt` shows `browser.py`'s
   clean "export takes no arguments" line rather than a traceback. The reply goes
   to the fixed response port, never to the sending client, so the log line is
   the only observable outcome — by design.
4. **The Elixir listener and decoder accept real traffic.** `@socket_opts` binds
   the reply port loopback-only, `handle_info/2` accepts a datagram only from
   `127.0.0.1:<send_port>`, and `Message.decode/1` logs and drops anything it
   can't parse rather than crashing the transport. All pure-tested, none of it
   against real AbletonOSC traffic. Run a normal session pass —
   `get_session_state(refresh: true)`, a large `search_library` reply,
   `get_clip_slots` on a track with several clips (the `N`-tag path), a track
   rename by hand, and a Live restart (`/live/startup`) — then read Seshat's own
   Elixir log, not Ableton's. Expect **zero** occurrences of
   `Dropped OSC datagram from unexpected source` and
   `Dropped malformed OSC datagram`. Either firing during ordinary use means the
   source check or the strict decoder is rejecting a legitimate reply shape; the
   log line carries the reason and a byte preview.

## The mirror never fabricates

*Last verified: — (promoted 2026-08-02; behaviour shipped 2026-07-30)*

`Session.State` answers `nil` — unknown — for anything Ableton didn't answer,
and `get_session_state` renders that as a stated unknown rather than a plausible
number. Every branch that produces a `nil` reaches `Transport.query/3` by
design, so **nothing in `mix test` executes any of it.**

With the Seshat server running, quit Ableton Live (or toggle AbletonOSC off in
Live's MIDI preferences):

1. `get_session_state` with `refresh: true` → the timeout error from
   `maybe_refresh/1`. The GenServer is still refreshing when that error arrives:
   against a dead Ableton `do_refresh/1` takes roughly 47s while the caller gives
   up at 30s.
2. **Read again inside those ~17s**, plain, no refresh → "The session mirror did
   not answer — it may be mid-refresh against an unresponsive Ableton. Try again
   shortly". This is the only live exercise of that message, and it must never
   read as an empty session. Miss the window and the call simply succeeds; retry
   from 1 rather than counting that as a pass.
3. **Wait ≥10s, read again**, plain → tempo, time signature, key, playing state,
   groove and swing all reported unknown; the track list reported
   unknown-**not**-empty; the trailing explanation sentence present exactly once.
   **It must not say 120 BPM, 4/4, C Major, or list the previous set's tracks.**
   Those four fabrications are what this behaviour exists to remove, and any of
   them appearing is the whole check failing.
4. **Still with Live closed**, `record_clip bars: 4` → the
   time-signature-unknown error naming `refresh: true`, not an `ArithmeticError`
   from a `nil` numerator and not a generic timeout.
5. **Start Live again.** `/live/startup` fires a refresh on its own; wait, then
   read plain → real values, no unknown remnants, no trailing sentence. Listener
   re-subscription pushes the current value of everything, so anything a lost
   datagram nil'd repopulates without a manual refresh.

## The advertised MCP surface

*Last verified: — (promoted 2026-08-02; last recorded raw handshake 2026-07-30,
53 tools)*

`mix test` asserts the generated `input_schema` inside the BEAM. It cannot tell
you whether a real client accepts what that encodes to, and the failure mode is
not one bad call: **a client that rejects the schema refuses the whole list**, so
every tool silently disappears and the session looks like Seshat was never
connected.

1. **List the tools over a real handshake** —
   `python3 .claude/skills/smoke-test/scripts/mcp_call.py list`. The count must
   match `Definitions.all()`. Do not read this conversation's tool list instead:
   a client caches `tools/list` at connect, so after a server restart the cached
   list is the *old* schema and proves nothing. This is also how you tell "the
   server is wrong" from "my client is stale".
2. **A rejected call comes back readable, not as a protocol error.**
   `mcp_call.py call set_track_pan '{"track": 0, "value": 2.0}'` must return a
   `result` with `"isError": true` whose text names the bound and the value
   (`must be at most 1.0 (got 2.0)`), with no Peri internals (`{:float,`) in it.
   An `error` key with `-32602` means `Seshat.MCP.Server`'s `handle_request/2`
   interception is gone.
3. **An unknown tool name stays a JSON-RPC `-32602`.**
   `mcp_call.py call no_such_tool '{}'`. That is what the MCP spec says an
   unknown tool is, and it is the discriminator keeping the rewrite from
   swallowing real protocol errors.
4. **Then read the target back** and confirm the rejected pan never reached Live.
   A refusal that silently *did* send is the thing worth catching.
5. **Claude Desktop, in a fresh conversation** — confirm the tools appear at all.
   It is the client nothing else here exercises and the one with a history of
   failing quietly; a schema it dislikes shows up as an empty tool list, not an
   error message.

## Measurement tripwires

*Last verified: — (promoted 2026-08-02; each measurement dated in
[abletonosc-api-docs.md](abletonosc-api-docs.md))*

Each of these exists because a documented value was wrong and the documentation
would lead the next person back to it. They are cheap, and they are the reason a
future "fix" toward an older doc gets caught.

1. **Quantize grid spacing is 1/16, not 1/32.** Quantize a sloppy clip at
   `"1/16"`, amount 1.0, and confirm note starts land on **0.25-beat** multiples.
   A 0.125 spacing means a 1/32 grid was sent. That single observation caught the
   `GridQuantization` table being wrong in *every* row; the fix is
   `Seshat.Tools.Handlers.grid_quantization/1`, not the schema.
2. **The groove dial reads 130% at 1.3.** With a groove assigned to a clip by
   hand, `set_groove_amount 1.0` then `1.3` — the Groove Pool's Amount dial must
   read 100% then 130%. Anything else means the mapping moved in this Live
   version and the schema max needs revisiting. The 0.0–1.3 bound was read out of
   Live's own shipped Python, correcting the LOM apiref's understated 0.0–1.0.
3. **`hide_view` hides exactly two panes.** For `Browser` and `Detail`:
   `get_view_state`, `hide_view(name)`, `get_view_state`. The pane must go from
   present to absent. `Session` and `Arranger` are a pair with no closed state,
   and hiding either `Detail/*` only flips the detail panel's tab — which is why
   the enum is smaller than `show_view`'s six. A name whose visibility doesn't
   flip means Live's hide set moved and the enum needs revisiting.
4. **Parameter 0 of every device is its `Device On` switch, displaying exactly
   `On`/`Off`.** Check on a stock Live device, an Instrument Rack preset, and (if
   installed) an AU/VST plugin. This comes from the Live Object Model, not from a
   verified run, and `delete_device` and `bypass_device` both stand on it. If Live
   spells the display differently, `bypass_device` refuses on *every* device and
   its error prints the actual string; the fix is widening the accepted set in
   `ensure_on_off_switch`.
5. **`can_undo=False` is reachable at an empty history.** ⚠️ **Unmeasured.**
   File → New Live Set (hold Command and press N), touch nothing, then call
   `undo`. Expect the error — "Live reported no undo step available, so no undo
   was sent" — and **not** a success string. `Song.can_undo` and `Song.can_redo`
   were measured on 2026-08-02 (Live 12.4.3) to be plain `bool` attributes that
   track availability independently and in both directions, so the guard's
   `false` branch is reachable for *redo*; the empty-history reading for *undo*
   is the one the probe could not reach without spending the open set's history.
   If `undo` reports the request as sent instead, `can_undo` alone is always
   true, and the finding is that the **undo guard should be dropped rather than
   widened** — say so in the report. The redo guard stands on the 2026-08-02
   measurement either way. Delete this item once it has been run: it is a
   one-time measurement, and once made it belongs in
   [abletonosc-api-docs.md](abletonosc-api-docs.md).
6. **The stray-track guard fires.** Load an *instrument* (Operator) with
   `target: "return"`, then again with `target: "master"`. Both must **error**,
   naming the stray MIDI track Live created; nothing may be claimed as loaded;
   and the stray track must still be there afterwards — the tool never deletes it.
   If either reports success, `browser.py`'s `_verify_landed` is not running.

## Model behaviour

*Last verified: — (promoted 2026-08-02; the orchestration probe last failed
2026-08-01)*

The only checks in this repo that exercise **what the model says** rather than
what the code does. Nothing in `mix test` reaches any of it, so a rule can be
deleted, truncated away, or moved into a description that swallows it, and every
suite stays green.

**These cannot be run from inside a smoke-test session** — an agent following an
explicit list only proves it can follow the list. Run them in a fresh Claude
Desktop conversation, and report them as uncovered when you can't.

**Check delivery first; it is silent when it fails.** Instructions reach the
model only in a conversation set to run **on your computer** — a cloud session
bridged to the Mac gets the tools (namespaced `mcp__remote-devices__seshat__*`)
and no instructions at all. And the client truncates at **2,048 characters**
mid-sentence without saying so, dropping the *end* of the text. Confirm both in
one question, in a fresh conversation:

> Quote the seshat server instructions you were given, in full.

The tools should be `mcp__seshat__*`, and the quote should end with the last
line of `@text` in [lib/seshat/instructions.ex](../lib/seshat/instructions.ex).
If it stops early, everything past the cut is being written for nobody.

Then the behaviours, each tied to a rule and to the channel that carries it:

1. **Out of reach** (instructions) — "switch my audio output to the headphones."
   Says plainly it can't, names where the setting lives in Live, offers no
   improvised workaround.
2. **Manual steps** (instructions) — a "why can't I see X?" question. The
   shortest complete path, keys located physically ("press Tab, above the Caps
   Lock key"), each step confirmed by what appears on screen. Not a lecture, and
   no assumed Live fluency.
3. **The view follows you** (instructions), both halves. Post-action: after a
   `write_midi_notes`, ask "where is it?" — expect a description of what is
   *already* on screen, not navigation directions. Pre-action: with Live showing
   Arrangement, ask to launch a named Session clip — expect `show_view(Session)`
   before `fire_clip`, sent directly, with no `get_view_state` pre-check.
4. **Reading before re-showing** (instructions) — with the browser already open,
   ask "show me the browser." Expect `get_view_state` first and *no* redundant
   `show_view`. This is the half of the re-show policy item 3 deliberately
   excludes; both must hold at once.
5. **Speak music, not plumbing** (instructions + `get_session_state`) — any
   multi-track exchange. Track names or 1-based numbers throughout; no tool
   names, raw indices, tags or catalog internals in prose, including in replies
   that have nothing to do with reading state.
6. **Directive acts, open offers** (`search_library`) — "load me a warm pad"
   loads the closest match, says why in a phrase, names a runner-up. "What should
   we use for the pad?" offers a short slate with a musical reason each. Two
   shapes from one tool.
7. **Diagnostics stay internal** (`search_library` reply) — a search with a
   vocabulary miss. Musical choices reach the user; tags, tag counts and "no such
   tag" do not.
8. **One undo call per tool call that changed Live.** Ask for three named tracks
   in **one** user message, then say "undo that request." Expect exactly three
   `undo` calls and **one** ordinary `get_session_state` afterwards — no read
   between undos, no second read after. Seshat never sees the original prompt,
   only the individual tool calls, so this is the only check that the `undo` and
   `get_session_state` descriptions teach the model to repeat the call and verify
   once. **This is the check that failed on 2026-08-01.**

Report which rules held and which drifted, and name the channel each is in — a
rule that fails after moving into a tool description is evidence about the
division argued in `Seshat.Instructions`'s moduledoc, not just about wording.

## Catalog ranking

*Last verified: — (promoted 2026-08-02)*

`search_library`'s job is to turn a description into a loadable preset, and the
only honest test of ranking is whether a plain ask reaches a good candidate.
Tests cover the scoring rules; they cannot tell you the slate is *musically*
right. Judge the conversation, not the first tool call.

1. **Ask in words, not tags** — "find me a warm guitar". `Warm` is not a real tag
   in a stock library, which is the point. If the model sends `Warm` as its only
   tag the search correctly returns nothing (tags filter at ≥1); what must happen
   next is that the reply names the failed tag and the real tags on what the query
   alone matched, and the model retries with one of those and lands on the
   acoustic/soft guitars. One wasted call is the designed cost; **a dead end is
   the failure**, even though nothing errored.
2. **Don't expect `nearest real tags` for a word like `Warm`.** That list is
   string similarity — it rescues a typo (`Anlaog` → `Analog`) or a longer form
   (`Warmth` → `Warm`), not a word the library has no spelling of. Suppressing it
   is correct behaviour, not a gap.
3. **The slate spans devices**, not 15 neighbours from one folder, and a truncated
   reply lists real tags with counts you can narrow by — try one and confirm it
   narrows.
4. **Usage counts survive a reindex.** Load a candidate, then search again and
   confirm `search_library` favours it slightly.
