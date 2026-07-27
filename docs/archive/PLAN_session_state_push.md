# Session state: push-based updates for everything mirrored, plus a manual refresh backstop

> **Archived 2026-07-27 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The listeners live in
> [priv/abletonosc/song_structure.py](../../priv/abletonosc/song_structure.py),
> [return_track.py](../../priv/abletonosc/return_track.py) and — an addition
> this plan did not anticipate —
> [track_listeners.py](../../priv/abletonosc/track_listeners.py), which
> overrides five of upstream's track listeners that unbind from the wrong
> track once an index is reused. The Elixir side is
> [lib/seshat/session/state.ex](../../lib/seshat/session/state.ex)
> (`stale?/2`, `refresh_sync/0`, the `/live/startup` handler). The open
> follow-ups moved to [ROADMAP.md](../ROADMAP.md): the `create_project`
> AppleScript bug under Priority 1.

## Context

During the validation run, tracks deleted by hand in Live's UI never reached `Seshat.Session.State` — it reported 7 tracks when 3 existed. Auditing the whole mirror surface, the stale-state loopholes are:

| # | Loophole | Today | Fix |
|---|---|---|---|
| 1 | Track add/delete/duplicate/reorder in Live's UI | nothing fires | vendored `tracks` listener (LOM `Song.add_tracks_listener`) |
| 2 | Ableton restart / set load / AbletonOSC reload | mirror wrong **and all listeners dead** forever | handle `/live/startup` (sent on every control-surface init) → refresh |
| 3 | Seshat's own `undo`/`redo` restoring/removing tracks | no `State.refresh()` call — stale via our own tools | covered by the same `tracks` listener |
| 4 | Return-track add/delete/reorder in UI | no listeners on returns at all | vendored `return_tracks` listener (`Song.add_return_tracks_listener`) |
| 5 | Return rename / return volume / master volume in UI | no listeners | vendored per-return `name`+`volume` and master `volume` listeners |

Accepted non-fixes: swapping two *identically named* tracks (invisible to name comparison; not worth it), a lost UDP push (manual `refresh: true` backstop). Scenes/clips/devices/sends are never mirrored — their tools query Live directly and can't go stale.

**Mechanism.** Upstream AbletonOSC only exposes listeners for scalar properties, but Seshat already vendors handlers (`browser.py`, `return_track.py`), and upstream's base `AbletonOSCHandler._start_listen(target, prop, params, getter)` accepts a custom getter (verified in the installed copy). Landing this = re-run `mix abletonosc.install` + restart Live. No compat layer (per CLAUDE.md: single user, not production).

## Part A — Python: vendored listeners

### A1. New `priv/abletonosc/song_structure.py`

House-style header comment (why upstream can't do this). Class `SongStructureHandler`, `class_identifier = "song"`. Registers, via the base `_start_listen`/`_stop_listen` with name-tuple getters:

- `/live/song/start_listen/tracks` + `stop_listen` — `Song.add_tracks_listener`, getter `tuple(t.name for t in self.song.tracks)` → pushes `/live/song/get/tracks [name0, name1, ...]`
- `/live/song/start_listen/return_tracks` + `stop_listen` — `Song.add_return_tracks_listener`, same shape → pushes `/live/song/get/return_tracks [names...]`

Base class gives idempotent re-listen, cleanup on reload, and an immediate initial push on subscribe. Upstream registers neither address (checked `song.py`) — no collision.

### A2. Extend `priv/abletonosc/return_track.py`

- `/live/return_track/start_listen/name [index]` + `stop_listen` — returns are LOM `Track` objects, so base `_start_listen(self.song.return_tracks[index], "name", (index,))` works as-is → pushes `/live/return_track/get/name [index, name]` (bare pair; query replies keep their `[index, "ok", name]` envelope — the shapes stay distinguishable).
- `/live/return_track/start_listen/volume [index]` + `stop_listen` — hand-rolled: the listenable object is `mixer_device.volume` (a `DeviceParameter` with `add_value_listener`), and the base class would derive the wrong address (`get/value`). Register a custom callback pushing `/live/return_track/get/volume [index, value]`, stored under `self.listener_functions[("value", (index,))]` with `listener_objects` = the param, so the base `_stop_listen`/`_clear_listeners` bookkeeping (`remove_value_listener`) still works. Send once immediately on subscribe, matching base behavior.
- `/live/master/start_listen/volume` + `stop_listen` — same hand-rolled pattern on `master_track.mixer_device.volume`, key `("value", ("master",))` → pushes `/live/master/get/volume [value]`.

Correlation note: pushes share `get/*` addresses with query replies, so one can be consumed by a pending `Transport` query on the same address — the exact situation upstream's track listeners already create, mitigated by the existing echo checks; a consumed push carries a current value anyway.

### A3. Register in the installer — [lib/mix/tasks/abletonosc.install.ex](lib/mix/tasks/abletonosc.install.ex)

Third `@handlers` entry (`song_structure.py` / `from .song_structure import SongStructureHandler` / `abletonosc.SongStructureHandler(self),`). The task is already generic over the list; update the moduledoc.

## Part B — Elixir: `Session.State` reacts

All in [lib/seshat/session/state.ex](lib/seshat/session/state.ex).

### B1. Subscribe (end of `do_refresh/1`, alongside existing subscriptions)

- `/live/song/start_listen/tracks` and `/live/song/start_listen/return_tracks` (from `subscribe_song_listeners/0`, kept apart from `@listened_song_properties` — different payload shape; comment marks them as Seshat-extension addresses).
- Per return track: `/live/return_track/start_listen/name [i]`, `/live/return_track/start_listen/volume [i]`.
- `/live/master/start_listen/volume`.

### B2. New `handle_info` clauses (above the catch-all)

- `"/live/startup"` → `{:noreply, do_refresh(state)}` — covers loophole 2 (fresh song object; re-subscribes everything).
- `"/live/song/get/tracks"`, `names` → `do_refresh` if `stale?(state.tracks, names)`, else no-op.
- `"/live/song/get/return_tracks"`, `names` → same comparison against `state.return_tracks` names.
- `"/live/return_track/get/name"` — `[i, name]` push and `[i, "ok", name]` query-reply shapes both update return `i`'s name in the mirror.
- `"/live/return_track/get/volume"` — likewise for volume.
- `"/live/master/get/volume"`, `[v]` → update `state.master`.
- New pure public `stale?/2`: `Enum.map(tracks, & &1.name) != live_names` — order-sensitive, so reorders count.

No debounce: a burst of pushes queues; the first triggers `do_refresh`, the rest compare equal and no-op. Stale per-index listeners left on old indices are harmless (their indices are absent from the refreshed mirror; `update_track/4` skips unmatched).

### B3. Forced refresh backstop

- `State.refresh_sync/0`: `GenServer.call(__MODULE__, :refresh_sync, @refresh_sync_timeout)` (30s — a refresh against a stalled Ableton is a stack of 5s timeouts); `handle_call(:refresh_sync, _from, state), do: {:reply, :ok, do_refresh(state)}`. Cast `refresh/0` stays for fire-and-forget sites.
- `get_session_state` ([handlers.ex:1360](lib/seshat/tools/handlers.ex#L1360), [definitions.ex:814](lib/seshat/tools/definitions.ex#L814)): optional `"refresh"` boolean — when true, `State.refresh_sync()` before serving. Description gains: UI changes stream in automatically; pass `refresh: true` if the state ever looks wrong. Clause reads `Map.get(params, "refresh", false)`; clause-level `catch :exit` stays. Tool count stays 47; `Seshat.MCP.Schema` already handles optional booleans.

## Part C — docs & cross-checks

- [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md): document every new address in the Seshat-extensions section (required by `vendored_addresses_test`), and note `/live/startup` is acted on.
- [test/seshat/osc/vendored_addresses_test.exs](test/seshat/osc/vendored_addresses_test.exs): add `song_structure.py` to `@handler_files`; update the "exactly the seven documented addresses" return/master assertion for the six new listen addresses. **Coverage gap to close:** `@vendored_prefixes` can't cover the new `/live/song/*` addresses (upstream owns most of `/live/song/`), so the used→registered tripwire would miss a typo in the two `start_listen` addresses `Session.State` sends — add `"/live/song/start_listen/tracks"` and `"/live/song/start_listen/return_tracks"` as exact-match entries alongside the prefix filter. Keep the pushed reply addresses (`/live/song/get/tracks`, `/live/song/get/return_tracks`) *out* of that check — they are push-only, sent by the handler but never registered via `add_handler`, so they'd fail it; they still get documented like every other address.
- [test/mix/tasks/abletonosc_install_test.exs](test/mix/tasks/abletonosc_install_test.exs): third file in the copy/registration assertions.
- CLAUDE.md module map + `.claude/rules/osc.md`: add the third vendored file; mention state now stays fresh by push.

## Tests (pure only, per house rules)

- `stale?/2`: identical → false; deleted/added/renamed/reordered → true; empty mirror vs live → true.
- `handle_info` (via the existing no-GenServer `state_test.exs` pattern): tracks push matching mirror → unchanged; return name/volume pushes (both shapes) update the right return; master push updates master. (Branches that call `do_refresh` need live Ableton — not unit-tested.)
- `definitions_test.exs`: count stays 47.

## Verification

1. `mix precommit`
2. `mix abletonosc.install` + restart Live, then:
   - Delete/add/reorder tracks in the UI → "What's in the session?" correct immediately.
   - `undo` via Seshat after creating a track → mirror correct.
   - Add/rename a return, move a return/master fader in the UI → `get_session_state` reflects it without `refresh: true`.
   - Load a different set (and restart Live) → mirror follows via `/live/startup`; confirm in server logs. If set-load turns out not to re-init the control surface, note it and fall back to `refresh: true` for that case.

## Follow-ups (not this session)

- `create_project` fix: AppleScript targets "Ableton Live 12" but the app is "Ableton Live 12 Suite" (process name is always `"Live"`); plus `can_undo` unsaved-set guard and create-before-delete ordering. Root cause at [registry.ex:236](lib/seshat/commands/registry.ex#L236).
- Update the `get_session_state` row in [docs/TOOL_AUDIT.md](docs/TOOL_AUDIT.md) once this lands.
