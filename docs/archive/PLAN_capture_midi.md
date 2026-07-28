> **Archived 2026-07-28 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. `capture_midi` lives in
> `Seshat.Tools.Definitions` / `Handlers` (`snapshot_grid/0`,
> `snapshot_tracks/2`, `capture_diff/2`, `captured_reply/4`,
> `nothing_captured_reply/2`). The open questions below about Arrangement
> routing, capture-to-clip timing, and a nothing-buffered capture still want
> a live-Ableton smoke pass (`docs/PLAN_capture_midi.md`'s own smoke items
> 1–5, still tracked). The follow-ups it names remain open on
> [ROADMAP.md](../ROADMAP.md) under their current numbers: session record
> (#3), per-clip loop brace/length (#4), quantize (#7), groove (#8), follow
> cam (#2), and clip-grid-into-session-state promotion (#21) — all renumbered
> since this plan shipped and capture's own slot (formerly #2) was removed.

# Plan — `capture_midi`: "keep that"

Roadmap #2 (at time of writing; shipped and removed — see banner above). One
new tool — `capture_midi` — that retroactively captures what
the user just played into a Session clip, via the upstream
`/live/song/capture_midi` address. No parameters, no `%Command{}` sequence,
and **no fork changes**: everything rides on addresses the installed
AbletonOSC already serves, so this ships as pure Elixir with no
`mix abletonosc.install` on the user.

## Context

Live continuously buffers recent MIDI input even on un-armed tracks. The user
noodles on a controller, stumbles into something good, and says "keep that" —
without ever having armed a track or touched the mouse. That moment is
ephemeral by nature (re-played ideas lose the feel), and it is exactly where a
voice/agent interface beats a mouse, because the user's hands are on the
instrument. Today Seshat has nothing for it: `set_track_arm` and
`start_playing` exist but nothing records, and `write_midi_notes` only keeps
what the *agent* composed. This is the head of the roadmap's play-and-keep arc
(#2 · #4 · #5 · #8 · #9).

Research confirmed the roadmap entry's core claims against the fork source at
`priv/AbletonOSC` (the real source, not the installed copy):

1. **`/live/song/capture_midi` exists upstream and never replies.**
   `abletonosc/song.py` registers it in the song-methods list, dispatched
   through `_call_method`, which calls `song.capture_midi()` and returns
   nothing. The fork's `_call_method` also *catches* exceptions (logged at
   ERROR, never re-raised), so a capture with nothing buffered is exactly as
   silent as a successful one. Success and failure are indistinguishable on
   the wire — the handler must verify by re-reading, the same
   sandwich `delete_device` uses.
2. **Verification can reuse the clip-grid plumbing wholesale.** The
   `get_clip_slots` handler already turns `/live/song/get/track_data` into
   structured per-track slot data (`parse_track_data/3`,
   `@track_data_properties` in
   [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex)), including
   clip name, length, playing and recording flags. Snapshot the grid before,
   fire capture, snapshot after, diff: whatever slot went from empty to
   occupied *is* the captured clip, wherever Live chose to put it. This is
   deliberately behaviour-agnostic — Live's placement rules (first empty slot
   vs. new scene, armed tracks vs. input-monitored tracks, several tracks at
   once) don't need to be modelled, only observed.
3. **The tempo side-effect is detectable with two one-value queries.** Capture
   can adjust the song tempo when the transport was stopped and Live inferred
   one from the playing. `/live/song/get/tempo` before and after the capture
   surfaces it; AbletonOSC processes datagrams in arrival order and
   `song.capture_midi()` runs synchronously inside the callback, so a tempo
   query sent after the capture message reads the post-capture value — the
   same ordering trick `delete_device`'s count re-read relies on.
   `Seshat.Session.State` needs no work: its existing tempo and `is_playing`
   listeners pick up the change by push.

**Decision — no `can_capture_midi` pre-check.** The LOM has a read-only
`Song.can_capture_midi` flag that would let the tool refuse cleanly before
firing, but the fork's `song.py` doesn't expose it, so it would be this
feature's only Python half: a one-word edit to `properties_r`, dragging with
it two commits (submodule + pin bump), a `mix abletonosc.install`, a Live
restart, and a smoke-test-only verification path. The grid diff already
distinguishes the outcomes the user cares about — captured (report what
appeared) vs. nothing captured (report that, with the likely causes) — so the
pre-check buys only a marginally crisper error message. Rejected as
disproportionate; revisit only if the nothing-appeared reply proves confusing
in practice.

## OSC contract

All upstream, verified in [abletonosc-api-docs.md](abletonosc-api-docs.md) and
re-verified against the fork source (`song.py`, `handler.py`):

| Address | Request args | Reply | Notes |
|---|---|---|---|
| `/live/song/capture_midi` | — | — (never replies) | `_call_method` → `song.capture_midi()`; exceptions caught and logged, so failure is silent too |
| `/live/song/get/tempo` | — | `[tempo_bpm]` (float) | Before/after pair detects capture's tempo inference |
| `/live/song/get/num_tracks` | — | `[num_tracks]` | Grid snapshot bounds (existing `get_clip_slots` read) |
| `/live/song/get/num_scenes` | — | `[num_scenes]` | Re-queried after capture — capture may add a scene |
| `/live/song/get/track_data` | `[start, end, properties...]` | flat value list | Same `@track_data_properties` batch `get_clip_slots` sends; parsed by the existing `parse_track_data/3` |
| `/live/scene/get/name` | `[scene_id]` | `[scene_id, name]` | `get_clip_slots` only — the capture snapshots skip scene names (see Part 1) |

The three getters reply reliably (no index args to get wrong), so the
snapshots use the Transport default 5s timeout like `get_clip_slots` does, not
`@guard_timeout`.

## Parts

### 1. Extract a structured grid snapshot — `lib/seshat/tools/handlers.ex`

`get_clip_slots`'s private flow is query counts → `query_scene_names/1` →
`query_track_data/2` → `parse_track_data/3` → `format_clip_slots/2`. The
capture handler needs the same data structured rather than formatted, and
needs it twice. Extract the shared portion into one private helper:

- `snapshot_grid/0` → `{:ok, %{num_scenes: n, tracks: parsed_tracks}}` —
  wraps the `num_tracks`/`num_scenes` queries, `query_track_data/2`, and
  `parse_track_data/3`. An empty session (`num_tracks < 1` or
  `num_scenes < 1`) returns `{:ok, %{num_scenes: 0, tracks: []}}` rather than
  an error — capture on an empty set falls through to the honest
  nothing-appeared reply.
- `get_clip_slots` keeps its exact current output: it calls `snapshot_grid/0`,
  keeps its empty-grid early return, reads scene names as today, and formats.
  Scene names cost one query per scene, which is why the capture path skips
  them — the diff only needs occupancy, and the before/after pair would
  otherwise double a per-scene query burst for names that are mostly empty
  strings.

No public API changes; `parse_track_data/3` and `format_clip_slots/2` stay as
the tested pure layer.

### 2. `capture_midi` — Definitions + Handlers

Append to `@tools` in
[lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex), next to
the transport/recording group (after `set_track_arm`). No parameters
(`properties: %{}, required: []`, like `start_playing`). Draft description:

> Retroactively capture the MIDI the user just played into a new Session
> clip — Ableton Live keeps a buffer of recent MIDI input even when nothing
> was armed or recording, so this is the "keep that" move when the user
> stumbles onto something good while noodling. Call it right away: the buffer
> is ephemeral, and re-playing an idea never feels the same. No parameters —
> Live itself decides which track(s) the material belongs to (the tracks that
> received the MIDI) and where the clip lands. The reply reports exactly which
> clip(s) appeared (track, slot, length, whether Live started them playing)
> and whether Live adjusted the song tempo to match the playing — it does that
> when the transport was stopped. MIDI only; audio can't be captured. If
> nothing MIDI was played since the last capture, the reply says nothing
> appeared. Follow up with get_clip_notes to inspect what was kept, or
> set_clip_name to label it.

Handler clause (single mutating message with read sandwiches — Transport
direct, no `%Command{}`), above the catch-all:

1. **Before-reads:** `Transport.query("/live/song/get/tempo", [])` and
   `snapshot_grid/0`. Either failing → error *before anything is sent*
   ("Ableton not reachable" phrasing, matching `get_clip_slots`'s timeout
   message); never fire a capture that can't be verified.
2. **Fire:** `Transport.send_message("/live/song/capture_midi", [])`.
3. **After-reads:** tempo query, then `snapshot_grid/0` again (counts
   re-queried — capture may have added a scene).
4. **Diff:** `capture_diff(before, after)` (pure, public, `@doc`'d — Part 3).
   - New clips found → `{:ok, captured_reply(...)}`.
   - No new clips → **one bounded retry**: `Process.sleep(250)`, re-snapshot,
     re-diff (⚠️ Open question 2 — insurance in case Live defers the clip
     insertion past the LOM call's return). Still nothing →
     `{:error, nothing_captured_reply(...)}`.
5. **After-read failure** (`catch :exit` after the send): the capture already
   fired, so the error must not pretend otherwise — "Capture was sent but
   reading the session back timed out — check the result with
   get_clip_slots", the `set_device_parameter` precedent.

### 3. Pure diff + reply helpers — `lib/seshat/tools/handlers.ex`

Public, documented, tested — the same pattern as `parse_track_data/3` /
`deleted_device_reply/3`:

- `capture_diff(before, after)` → list of
  `%{track_index, track_name, slot_index, clip}` for every slot that is
  occupied in `after` and empty (or beyond `before`'s scene count) in
  `before`, in track order. Tracks are matched by index — capture never
  creates or reorders tracks. Also expose whether `after.num_scenes` grew.
- `captured_reply(new_clips, scenes_added, tempo_before, tempo_after)` —
  one line per clip: track index and name, slot index, length in beats,
  clip name when Live assigned one, `[playing]` from the after-snapshot's
  actual flag (never assumed). A grown scene count adds "Live added scene N
  to hold it." A tempo change (compare the raw floats; print rounded to one
  decimal) adds "Live set the tempo to X BPM to match the playing (was Y)."
- `nothing_captured_reply(tempo_before, tempo_after)` — states that capture
  ran but no new Session clip appeared, that Live buffers only MIDI played
  into a track (armed or monitoring its input), and that if Arrangement view
  was focused the capture may have landed there instead (⚠️ Open question 1).
  When the tempo pair differs, say so explicitly — a tempo change with no new
  grid clip is positive evidence the capture landed *somewhere* outside the
  Session grid, which turns the Arrangement caveat from a guess into the
  likely cause.

### 4. Count bump + tests + audit

- `test/seshat/tools/definitions_test.exs`: tool count 48 → 49.
- [docs/TOOL_AUDIT.md](TOOL_AUDIT.md): add a `capture_midi` row to the §04
  inventory table, and update the §02 "Capture / record into a slot" gap row —
  the capture half is addressed, `session_record` remains (roadmap #4). The
  delete_device/bypass_device work set the precedent: the implementing change
  carries the audit update, not `/ship`.
- New pure tests in the handlers test file: `capture_diff/2` (no change; one
  new clip; new clips on two tracks at once; a clip landing in a new scene,
  i.e. `after` has more scenes than `before`; empty before-grid), and the
  three reply helpers including the tempo-line rounding and the
  scene-added line.
- `Seshat.MCP.ToolsTest` parity is automatic; `capture_midi` round-trips
  `Macro.camelize/1` cleanly.
- `mix precommit` before declaring done.

## Testing

**Pure (the suite, no Ableton):** everything in Part 4 — the diff, the reply
text, the definitions count, MCP parity. The handler clause itself reaches
`Transport.query/3` and is deliberately untested at that layer, per the
testing rules.

**`/smoke-test` (needs Live + a MIDI controller):**

1. Happy path: noodle on an un-armed, input-monitored MIDI track, call
   `capture_midi` — reply names the right track/slot, clip audible, mirror's
   tempo unchanged.
2. Tempo inference: transport stopped, play in time, capture — reply reports
   the tempo Live inferred, and `get_session_state` shows the same value
   (push listener).
3. Nothing buffered: capture twice in a row (second has nothing new) — clean
   nothing-appeared error, no crash, `/live/error` in Live's log at worst.
4. Arrangement view focused during capture (⚠️ 1) — observe where the clip
   lands and whether the nothing-appeared message's Arrangement caveat is
   accurate.
5. Deferred insertion (⚠️ 2): watch whether the first diff ever comes up
   empty on a successful capture (the 250 ms retry saving it).

## Out of scope

- **Session record / deliberate takes** — roadmap #4.
- **Editing the captured clip's loop brace or length** — roadmap #5; noted
  there that captured clips arrive with whatever Live inferred.
- **Quantize / groove follow-ups** — roadmap #8, #9.
- **Auto-naming the captured clip or steering the view to it** — the follow
  cam (#3) bundles both; this tool's reply pointing at `set_clip_name` is the
  interim.
- **`capture_and_insert_scene`** — a different LOM method (freezes currently
  *playing* clips into a new scene), not the play-and-keep moment; stays
  unplanned.
- **Arrangement-view capture** — Seshat is Session-only by standing decision
  (ROADMAP "Deliberately not planned").
- **Promoting the clip grid into `Session.State`** — roadmap #22 explicitly
  waits for post-#2/#4 evidence; this tool's two on-demand snapshots per call
  are part of that evidence.

## Open questions

1. **⚠️ What does a bare `capture_midi()` do when Arrangement view is
   focused?** The Live 11+ LOM gives `Song.capture_midi` an optional
   `CaptureDestination` (auto/session/arrangement) and the UI button captures
   into the focused view; `_call_method` sends no argument, so we get `auto`.
   Whether `auto` can route to the Arrangement — invisible to the grid diff —
   can only be answered with Live running (smoke item 4). Assumed meanwhile:
   possible, so `nothing_captured_reply` names it as a cause. Passing a
   destination over OSC was rejected for now: `_call_method` would forward a
   raw OSC integer where Boost.Python may demand the enum type, which is
   unverifiable without Live; if smoke-testing shows Arrangement capture is a
   real trap, the fix is a small fork commit registering an explicit
   session-destination call, taken as follow-up work.
2. **⚠️ Is the captured clip present the moment `song.capture_midi()`
   returns?** The call is synchronous, but Live may defer the actual clip
   insertion to a later UI tick — nothing in the fork source answers this.
   Assumed mostly-yes; the single 250 ms retry in Part 2 covers the deferred
   case, and smoke item 5 tells us whether it ever fires (if it never does,
   the retry is one `if` worth deleting later; if it always does, the delay
   may need tuning).
3. **⚠️ Does capture with nothing buffered raise inside Live?** Harmless
   either way — the fork's `_call_method` catches and logs, nothing unwinds —
   but smoke item 3 should confirm the tool's error path reads cleanly and
   Live stays healthy.
