# Plan — Send levels & return tracks

> **Archived 2026-07-26 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The six tools and
> `priv/abletonosc/return_track.py` live on `feat/send-levels`
> (`lib/seshat/tools/definitions.ex` / `handlers.ex`, `lib/seshat/commands/registry.ex`,
> `lib/seshat/session/state.ex`); deviations from this plan (Registry's
> `create_return_track` return shape, `Session.State`'s exit-catching `probe/4`,
> and dropping the Part 8 guard-error tests per `.claude/rules/testing.md`) are
> in the PR description. Still-open follow-ups — return-track pan/mute/solo,
> master pan, cue volume, and return→return sends — are tracked under
> "Smaller OSC surface" in [ROADMAP.md](../ROADMAP.md); the seven vendored
> addresses still have no automated coverage and no live-Ableton smoke test
> has been run against the installed handler yet.

Roadmap Priority 1. Six new tools — `set_track_send`, `get_track_sends`,
`create_return_track`, `delete_return_track`, `set_return_track_volume`,
`set_master_volume` — plus return tracks and the master level in
`get_session_state`, so "add some reverb to the vocals" and "turn down the
delay send on the drums" finally work. One new vendored Python handler
(browser.py-style) supplies the return/master addresses upstream AbletonOSC
doesn't have.

## Context

Mixing today stops at volume/pan/mute/solo on regular tracks. There is no way
to route a track into a shared reverb or delay, no way to see or set a send
level, and no way to touch a return track or the master fader at all. The
2026-07 tool audit ranks sends/returns the single biggest capability gap
(High), with master & return levels riding along (Low-Med).

Research changed the obvious approach in one important way. The roadmap asked
for verification of return/master addressing against the installed AbletonOSC
source (`~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`), and the
answer is **no — return and master tracks are unreachable upstream**:

1. Every `/live/track/*` handler resolves its index via
   `self.song.tracks[track_index]` (`abletonosc/track.py`,
   `create_track_callback`). The LOM's `Song.tracks` holds regular tracks
   only; returns live in `Song.return_tracks` and master in
   `Song.master_track`, which no upstream address touches.
2. `/live/song/get/num_tracks`, `track_names`, and `track_data` likewise
   iterate `self.song.tracks` only (`abletonosc/song.py`).
3. The only upstream return-track surface is `create_return_track` /
   `delete_return_track` (Song methods) and the per-track send getter/setter
   `/live/track/get|set/send` — sends on *regular* tracks, whose targets are
   the returns in order (send A = return 0).

Consequences:

- **Send get/set needs nothing new** — upstream addresses exist and are
  regular-track-scoped, which is what a send is.
- **Return-track names need a vendored handler.** The agent must resolve "the
  reverb send" → send index, and the only mapping is the return tracks' names
  in order. After `create_return_track` the new return can't even be named
  without it.
- **Return/master volume need the same handler.** That folds the roadmap's
  "return & master levels ride along" into this plan at near-zero marginal
  cost — the handler exists anyway for names.

Per the browser.py precedent (and the osc.md rule: any address upstream
doesn't provide is vendored in `priv/abletonosc/`), Part 1 adds
`priv/abletonosc/return_track.py`, and `mix abletonosc.install` grows from
one-file to a two-file install. Users must re-run the install task and restart
Live; every tool that depends on the new addresses fails with exactly that
instruction when the handler doesn't answer.

Two docs are wrong on the point this feature hinges on and get fixed here:
the Track API preamble in [abletonosc-api-docs.md](abletonosc-api-docs.md)
("Audio, MIDI, return, or master track") and the ableton-lom.md claim that
"`num_tracks` includes audio, MIDI, return, and master tracks".

## OSC contract

Upstream addresses, verified in [abletonosc-api-docs.md](abletonosc-api-docs.md)
and re-verified against the installed source (`track.py`, `song.py`):

| Address | Request args | Reply | Notes |
|---|---|---|---|
| `/live/track/get/send` | `[track_id, send_id]` | `[track_id, send_id, value]` | Echoes both indices — correlation-checkable |
| `/live/track/set/send` | `[track_id, send_id, value]` | — | `value` float 0.0–1.0 |
| `/live/song/create_return_track` | `[]` | — | Appends after existing returns; no index arg |
| `/live/song/delete_return_track` | `[track_index]` | — | Index into `song.return_tracks`, 0-based |

Bad indices raise `IndexError` inside the Python callback → **no reply, no
error** (the standard AbletonOSC silent failure). Every mutation below guards
with a get first.

New vendored addresses (Part 1), all under `/live/return_track/` and
`/live/master/`:

| Address | Request args | Reply | Notes |
|---|---|---|---|
| `/live/return_track/get/count` | `[]` | `[count]` | Also the "is the handler installed?" probe |
| `/live/return_track/get/name` | `[index]` | `[index, name]` | |
| `/live/return_track/set/name` | `[index, name]` | — | |
| `/live/return_track/get/volume` | `[index]` | `[index, volume]` | `mixer_device.volume.value`, 0.0–1.0 |
| `/live/return_track/set/volume` | `[index, volume]` | — | |
| `/live/master/get/volume` | `[]` | `[volume]` | `song.master_track.mixer_device.volume.value` |
| `/live/master/set/volume` | `[volume]` | — | |

Reply-shape decision: getters echo their index args upstream-style (so the
existing `query_string`/`query_float`/echo-check helpers work unchanged), and
an out-of-range index is bounds-checked in Python, logged, and **not replied
to** — matching upstream getters rather than browser.py's ok/error envelope.
The Elixir callers all validate indices via `get/count` (or a guard get)
first, so the mixed-envelope parsing browser.py needed buys nothing here.

## Parts

### 1. Vendored handler — `priv/abletonosc/return_track.py`

New file, modeled on `priv/abletonosc/browser.py`: `ReturnTrackHandler`
subclassing `AbletonOSCHandler`, `class_identifier = "return_track"`,
registering exactly the seven addresses in the contract table above.

- Return lookup: `self.song.return_tracks[index]` after an explicit
  `0 <= index < len(...)` bounds check (log + no reply on failure — see
  contract).
- Volume is a mixer property: `track.mixer_device.volume.value` (same reason
  upstream TrackHandler special-cases volume/panning).
- Master needs no index: read/write `self.song.master_track.mixer_device.volume.value`.
- No listeners in v1 (see Out of scope).
- Header comment in browser.py style: what it adds, why (upstream gap),
  installed by `mix abletonosc.install`.

### 2. Generalize `mix abletonosc.install` to install both handlers

`lib/mix/tasks/abletonosc.install.ex` currently hardcodes one source file and
one import/registration line pair. Rework to iterate a module-attribute list:

```elixir
@handlers [
  %{file: "browser.py", init_line: "from .browser import BrowserHandler",
    manager_line: "abletonosc.BrowserHandler(self),"},
  %{file: "return_track.py", init_line: "from .return_track import ReturnTrackHandler",
    manager_line: "abletonosc.ReturnTrackHandler(self),"}
]
```

- Keep the existing `@init_anchor` / `@manager_anchor` (MidiMapHandler lines)
  for both — `patch/3` is idempotent per line, so both inserts after the same
  anchor are fine in either order.
- The manual-instructions fallback and the moduledoc list both files.
- The moduledoc's `/live/api/reload` warning still applies — `reload_imports`
  won't know `abletonosc.return_track` either; restart Live or toggle the
  control surface.

### 3. Docs — the canonical address list and the two wrong claims

- `docs/abletonosc-api-docs.md`: add a "Return Track & Master API (Seshat
  extension)" section after the Browser API section — the seven vendored
  addresses, reply shapes, the silent-failure-on-bad-index behavior, and the
  install pointer. Fix the Track API preamble to "Regular (audio/MIDI) tracks
  only — `song.tracks`; return and master tracks are reachable via Seshat's
  return_track extension", and note on `num_tracks`/`track_names` that they
  exclude returns/master.
- `.claude/docs/ableton-lom.md`: fix the "All track types share the same
  index space" line — return tracks are 0-indexed *within* `return_tracks`,
  master is its own object, and `num_tracks` counts regular tracks only.

### 4. Send tools — `set_track_send`, `get_track_sends`

Definitions (append to `@tools` in `lib/seshat/tools/definitions.ex`), then
`do_call/2` clauses in `lib/seshat/tools/handlers.ex` above the catch-all.

`set_track_send` draft description:

> Set a send level on a regular track — how much of that track's signal feeds
> a return track (shared reverb, delay, etc.). Track indices are 0-based:
> 'track 1' = index 0. Sends are 0-indexed in return-track order: send 0 =
> send A = the first return track, send 1 = send B = the second. Use
> get_session_state to see the return tracks and resolve 'the reverb send' to
> a send index, and get_track_sends to read current levels before relative
> changes. Value is 0.0 (off) to 1.0 (maximum). For 'a little reverb' start
> around 0.25–0.4; 0.6+ is a drenched, obvious effect. The send is only
> audible if its return track has an effect loaded. Regular tracks only — for
> a return track's own level use set_return_track_volume.

Params: `track` (integer), `send` (integer), `value` (number, 0.0–1.0), all
required. Handler:

1. Guard: `Transport.query("/live/track/get/send", [track, send], @guard_timeout)`,
   echo-checking both indices with `==` and reissuing once on mismatch
   (the `query_flag/3` pattern — the correlation hazard applies since
   `get_track_sends` hits the same address repeatedly). Timeout → error
   leading with "check the track index (get_session_state) and send index
   (get_track_sends; sends are 0-based, send A = 0)".
2. `Transport.send_message("/live/track/set/send", [track, send, value / 1.0])`.
3. Reply echoes old → new and, best-effort, the return name from
   `State.return_tracks()`: `Set send B ("B-Delay") on track 2 to 0.4 (was 0.0)`.
   No dB label for sends in v1 (⚠️ Open question 1).

`get_track_sends` draft description:

> Read every send level on one track, labeled with the send letter and the
> return track it feeds. Track indices are 0-based: 'track 1' = index 0. Use
> this before relative send changes ('a bit less delay') or to see which send
> index feeds which return. Requires Seshat's AbletonOSC extension (mix
> abletonosc.install).

Params: `track` (integer, required). Handler: `get/count` (2s probe — timeout
→ the install-hint error), then per return index: `/live/return_track/get/name`
and `/live/track/get/send [track, i]` (echo-checked). Zero returns → "No
return tracks in this set — create one with create_return_track." Output one
line per send: `send 0 (A) → "A-Reverb": 0.35`.

### 5. Return-track tools — `create_return_track`, `delete_return_track`

`create_return_track` is a create-then-name sequence → `%Command{}` +
Registry, exactly like `create_track`.

- `lib/seshat/commands/command.ex`: add `:create_return_track` to the
  `command` union type (reuses the existing `:name` field; no new fields).
- `lib/seshat/commands/registry.ex`: new `execute/1` clause:
  1. `{:ok, {_, [count]}} = Transport.query("/live/return_track/get/count", [], @probe)` —
     failure → error telling the user to run `mix abletonosc.install` and
     restart Live (this also fail-fasts before mutating anything).
  2. `Transport.send_message("/live/song/create_return_track", [])`.
  3. Re-query count. Unchanged → error: Live's return-track limit (12)
     reached, nothing created (⚠️ Open question 3). This re-query also
     sequences the rename behind the create, same trick as
     `create_and_name_track`'s num_tracks query.
  4. `Transport.send_message("/live/return_track/set/name", [count, name])` —
     the new return's index is the *old* count.
- Handler clause: build the Command, `Registry.execute/1`, `State.refresh()`,
  reply `Created return track "Space Reverb" (return 2 — send C on every track)`
  (letter = `<<?A + index>>`).

Draft description:

> Create a new return track in Ableton Live and name it. Return tracks host
> shared effects (reverb, delay) that regular tracks feed via sends; the new
> return is appended after existing ones, and every track automatically gains
> the matching send (new return's index = new send's index; return 0 = send
> A). Live allows at most 12 return tracks; the tool errors at the cap. The
> new return is empty — Seshat cannot yet load a device onto a return track,
> so ask the user to drop the effect onto it in Live.

Params: `name` (string, required).

`delete_return_track`: single message + guard, Transport direct.

> Delete a return track. Return-track indices are 0-based and separate from
> regular track indices: return 0 = the first return = send A (see
> get_session_state). Deleting a return shifts the indices and send letters
> of the returns after it — re-check get_session_state afterwards.

Params: `return_track` (integer, required). Handler: guard via
`/live/return_track/get/name [index]` (2s, echo-checked — catches both a bad
index and a missing handler, with the two hints in one message), then
`/live/song/delete_return_track [index]`, then `State.refresh()`.

### 6. Level tools — `set_return_track_volume`, `set_master_volume`

Both vendored-address setters, Transport direct, each guarded by its getter
so a missing handler errors instead of silently doing nothing (the guard is
the difference between an error and a lie — same rationale as
`write_midi_notes`).

`set_return_track_volume`:

> Set the volume of a return track — the overall level of the shared effect
> it hosts. Return-track indices are 0-based and separate from regular
> tracks: return 0 = send A's return (see get_session_state). Same fader
> scale as set_track_volume: 0.0 = silence, 0.85 = unity gain (0 dB), 1.0 =
> +6 dB. To change how much one track feeds the effect, use set_track_send
> instead.

Params: `return_track` (integer), `value` (number, 0.0–1.0). Guard:
`/live/return_track/get/volume [index]` (2s, echo-checked), then set. Reply
reuses `volume_display/1` (⚠️ Open question 2) and echoes old → new.

`set_master_volume`:

> Set the master track's output volume in Ableton Live. Same fader scale as
> set_track_volume: 0.0 = silence, 0.85 = unity gain (0 dB, where a new set
> sits), 1.0 = +6 dB. Lower this if the master is clipping; prefer track
> volumes and sends for balance moves.

Params: `value` (number, 0.0–1.0). Guard: `/live/master/get/volume []` (2s),
then set; reply with `volume_display/1`, echoing the previous value.

### 7. Session state — return tracks and master

`lib/seshat/session/state.ex`:

- State gains `return_tracks: []` (`%{index, name, volume}`) and
  `master: %{volume: float} | nil` — `nil` meaning "extension not answering".
- `do_refresh/1`: after the regular-track loop, probe
  `/live/return_track/get/count` with a **2s** timeout (not the 5s default —
  a missing handler shouldn't stall every refresh). On success, per-index
  `get/name` + `get/volume` (reusing `query_string`/`query_float`, whose
  `[idx, value]` clauses already fit the echo shape) and one
  `/live/master/get/volume`. On failure, log one warning naming
  `mix abletonosc.install` and set `return_tracks: [], master: nil`.
- No new listeners (Out of scope); the mutating tools call `State.refresh()`.
- `get_session_state` handler (`handlers.ex`) appends after the track lines:

  ```
  Return 0 "A-Reverb" (send A): volume=0.85
  Return 1 "B-Delay" (send B): volume=0.85
  Master: volume=0.85
  ```

  and, when `master` is `nil`:
  `Return/master state unavailable — run mix abletonosc.install and restart Live.`
- `get_session_state` description in Definitions grows: "...plus return
  tracks (name and volume, in send order: return 0 = send A) and the master
  volume."

### 8. Tests, tripwires, audit table

- `test/seshat/tools/definitions_test.exs`: count 41 → **47**; add the six
  names to the expected-names list.
- `test/seshat/tools/handlers_test.exs`, following the existing patterns
  (fire-and-forget sends succeed without Ableton; guarded clauses hit their
  guard timeout):
  - `set_track_send` error path mentions the send index and `get_track_sends`.
  - `create_return_track` / `get_track_sends` error paths mention
    `mix abletonosc.install`.
  - `set_master_volume` / `set_return_track_volume` error paths (guard
    timeout) — i.e. they do **not** claim success without Ableton.
  - `delete_return_track` error path mentions 0-based return indices.
- `Seshat.MCP.ToolsTest` parity is automatic; all six names are
  `lower_snake_case` so the camelize round-trip holds.
- `docs/TOOL_AUDIT.md`: add the six rows to the inventory, update the tool
  count (41 → 47), and mark the "Sends / return tracks" and "Master & return
  volume" gap rows as addressed.
- `mix precommit` clean.

## Testing

Pure (no Ableton, runs in `mix test`):

- Definitions count + names, schema shape, MCP parity — all existing suites.
- Handler guard error paths as listed in Part 8 (each ≈2s guard timeout;
  matches how existing guarded tools are tested).
- Formatting helpers if extracted (send-letter labeling); nothing tests
  through `Transport.query/3` happy paths.

Needs live Ableton (`/smoke-test` checklist additions):

1. `mix abletonosc.install` reports both handlers copied/patched; restart
   Live; `/live/return_track/get/count` answers.
2. `get_session_state` shows the default set's returns ("A-Reverb",
   "B-Delay") and master volume.
3. `set_track_send` on a playing track is audible; `get_track_sends` echoes
   the value back; bad send index errors fast (≈2s) with the right hint.
4. `create_return_track "Space"` appends and names it; verify in Live's UI;
   create up to the 12-return cap and confirm the clean error (Open
   question 3).
5. `delete_return_track` removes the right return; send letters shift as
   documented.
6. `set_return_track_volume` / `set_master_volume` move the right faders;
   check 0.85 lands on 0 dB for both (Open question 2) and what dB Live
   shows for a send at 0.5/0.85/1.0 (Open question 1).
7. Uninstalled-handler behavior: with the return_track.py registration line
   removed, every new tool that needs it errors with the install hint and
   `get_session_state` shows the unavailable line, within ~2s.

## Out of scope

- **Loading a device onto a return track** — `/live/browser/load_item` is
  regular-tracks-only and the roadmap's "Deliberately not planned" list
  explicitly parks return/master device loading. The from-scratch story
  ("create a return, put a reverb on it") therefore ends with the user
  dropping the device in by hand, and `create_return_track`'s description
  says so. Research note for the roadmap: now that returns are otherwise
  first-class, extending browser.py's `load_item` to them is ~20 lines and
  is the natural next rider — recorded here, decided there.
- **Return-track pan / mute / solo, master pan, cue volume** — levels only,
  per the audit's gap row. The vendored handler makes them one address each
  later; stays on the roadmap under "Smaller OSC surface" if wanted.
- **Sends on return tracks** (return→return routing, feedback) — niche,
  needs Live's "sends only" awareness; not part of any named workflow.
- **Listeners for return/master properties** — v1 mirrors on refresh and
  after Seshat's own mutations; a fader moved in Live's UI goes stale until
  the next refresh, same as clip state today. Promote to listeners only if
  usage shows it matters (roadmap "Session state improvements" pattern).
- **Send-level mirroring in `Session.State`** — tracks × returns values with
  a listener each; query-on-demand via `get_track_sends` per the roadmap's
  own guidance.

## Open questions

1. **Send dial value↔dB mapping** — ⚠️ needs live Ableton. Live's send dial
   tops out at 0 dB by default (unlike the track fader's +6), so
   `volume_display/1`'s labels ("0.85 = unity") are presumably wrong for
   sends. Couldn't be resolved at planning time: the mapping isn't in the
   AbletonOSC source (it just writes `.value`) or the docs. **Assumed:** send
   replies echo the raw 0.0–1.0 value with no dB label in v1; smoke-test
   step 6 reads the real curve off Live's UI, and a `send_display/1` can be
   added in the same PR if the curve is confirmed.
2. **Return/master fader scale** — ⚠️ needs live Ableton. Return and master
   faders look like the track fader (unity at 0.85, max +6 dB), and the LOM
   gives all tracks the same MixerDevice, so the plan **assumes**
   `volume_display/1` applies and reuses it. Smoke-test step 6 verifies;
   if wrong, drop the label the same way as sends.
3. **`create_return_track` at Live's 12-return cap** — ⚠️ needs live
   Ableton. Whether the LOM call raises (silent no-reply) or no-ops is
   unknown; either way the count re-check in Part 5 converts it to a clean
   "limit reached, nothing created" error, so the plan doesn't depend on the
   answer. Smoke-test step 4 confirms the message.
4. **Exact Live version behavior of `song.return_tracks` naming on create**
   — resolved as irrelevant: whatever default name Live assigns ("A Return"
   etc.), the Registry sequence renames it immediately using the old count
   as the index, which depends only on append semantics (verified: the LOM
   appends returns after existing ones; upstream exposes no index argument).
