# Plan: Follow cam — every action visibly lands on screen

## Context

The 2026-07-28 validation run's headline finding
([validation-script-thoughts-and-findings.md](validation-script-thoughts-and-findings.md)):
after `write_midi_notes`, Session view shows only an anonymous colored slot.
The user assumed the write had *failed* until playback proved otherwise, and
when they asked "why can't I see the notes?", Seshat's only lever was a
paragraph of UI tutoring. Acting beats instructing: the change appearing on
screen *is* the confirmation.

The fix is automatic view steering in the tool **handlers** — deterministic,
no extra round trip, works even when the model forgets. Every tool that
creates, writes, or destroys an object ends by selecting what it touched and
showing the pane where it is visible: a clip write selects the clip and opens
the note editor; a device load selects the device and opens the device chain;
a delete steers to whatever now occupies that index, or to the container when
nothing does.

Which tools steer is a settled decision (roadmap #2, tightened 2026-07-28),
not a judgment call for the implementer:

- **In:** `create_track`, `duplicate_track`, `create_return_track`,
  `create_scene`, `duplicate_scene`, `write_midi_notes`, `remove_notes`,
  `capture_midi`, `duplicate_clip`, `load_device`, `delete_device`,
  `bypass_device`, `delete_track`, `delete_return_track`, `delete_scene`,
  `delete_clip`.
- **Out:** parameter tweaks (volume, pan, send, mute, solo, arm, tempo,
  metronome), transport (`fire_clip`, `stop_clip`, `start_playing`,
  `stop_playing`), renames, and every read tool. A view that jumps on each
  volume nudge is exactly what would make someone ask for the off switch
  we're not building.
- **No transport-state exception.** Steering during playback is intended —
  `capture_midi` runs *while* the user is playing and is precisely when they
  most need to see where the take landed.
- **No toggle** — not config, not a tool. If steering ever feels intrusive,
  the when-to-steer rule is wrong and gets fixed, not switched off.
- **Returns in scope, master out.** The master's only tool is
  `set_master_volume`, a parameter tweak, which doesn't steer.

Research constraints that shaped the plan:

- Upstream already serves `/live/view/set/selected_track|scene|clip|device`.
  What it cannot do: show a *pane* (`Application.View.show_view` has no OSC
  address), put a clip into the Detail view (`song.view.detail_clip`), or
  select a return track (`selected_track`'s setter resolves through
  `song.tracks` only). Those three gaps are the fork's Python half.
- The indices are mostly already in hand — the handlers just discard them.
  `create_and_name_track` reads `num_tracks` before creating
  ([registry.ex:209](../lib/seshat/commands/registry.ex#L209)),
  `:create_return_track` already returns the new index, `capture_midi` diffs
  the clip grid, and `delete_device` holds the pre-delete chain. The one real
  gap is `load_device`: `/live/browser/load_item` replies with the name only,
  so its reply is extended with the new device index (it's our file) rather
  than paying a `get_track_devices` round trip.
- Every steering send is fire-and-forget UDP with no reply, so nothing can be
  asserted at the wire. The decision — tool plus result → which view calls, in
  what order — lives in a pure function (`Seshat.Tools.FollowCam.calls/2`)
  that tests drive directly.
- Free adjunct bundled in: an optional, model-supplied `name` on
  `write_midi_notes` and `capture_midi`, so occupied slots carry visible text.
  No auto-generated fallback — "Clip 3" is noise.

A Python half is not free: it lands as a commit in the submodule plus a pin
bump here, it puts `mix abletonosc.install` + a Live restart on the user, and
**no test in this repo executes it** — every behavior of the new addresses is
a `/smoke-test` item by construction.

## OSC contract

### Upstream addresses used for steering (verified in [abletonosc-api-docs.md](abletonosc-api-docs.md), View API)

| Address | Request | Reply | Use |
|---|---|---|---|
| `/live/view/set/selected_track` | `track_index` | none | track create/duplicate/delete (regular tracks only) |
| `/live/view/set/selected_scene` | `scene_index` | none | scene create/duplicate/delete |
| `/live/view/set/selected_clip` | `track_index, scene_index` | none | clip writes and deletes (sets track + scene selection) |
| `/live/view/set/selected_device` | `track_index, device_index` | none | device load/delete/bypass |

Facts the steering needs, read with existing upstream getters:

| Address | Request | Reply | Use |
|---|---|---|---|
| `/live/song/get/num_tracks` | | `num_tracks` | post-`delete_track` clamp |
| `/live/song/get/num_scenes` | | `num_scenes` | post-`delete_scene` / `create_scene -1` resolution |
| `/live/return_track/get/count` | | `count` | post-`delete_return_track` clamp (Seshat ext., bare value) |
| `/live/clip/set/name` | `track_index, scene_index, name` | none | the optional clip `name` |

### New vendored addresses (fork commits in `priv/AbletonOSC`)

| Address | Request | Reply | Serving file |
|---|---|---|---|
| `/live/view/show_view` | `view_name` | none | `abletonosc/view.py` |
| `/live/view/set/detail_clip` | `track_index, scene_index` | none | `abletonosc/view.py` |
| `/live/return_track/select` | `return_index` | none | `abletonosc/return_track.py` |

- `show_view` wraps `Live.Application.get_application().view.show_view(name)`.
  ⚠️ Valid names per the Live API: `"Browser"`, `"Arranger"`, `"Session"`,
  `"Detail"`, `"Detail/Clip"`, `"Detail/DeviceChain"`. Seshat sends only the
  last three plus `"Session"`; the address stays general (settled decision —
  not a clip-editor-only wrapper). An unknown name raises inside Live; catch
  and log, send nothing.
- `set/detail_clip` sets `song.view.detail_clip` to the clip in
  `song.tracks[track_index].clip_slots[scene_index]`; a slot with no clip is
  logged and ignored.
- `select` resolves through the existing `_return_track` bounds-checked lookup
  and sets `song.view.selected_track` to the return track.
  ⚠️ `song.view.selected_track` accepting a member of `song.return_tracks` is
  the documented LOM behavior (any track including returns is selectable) but
  only Ableton can confirm it.
- All three are **silent** — fire-and-forget like the vendored setters.
  Nothing waits on them, and steering must never fail the tool it follows, so
  the ok/error envelope rule for vendored *getters* does not apply. Errors go
  to Live's log.

### Changed vendored reply

| Address | Request | Reply |
|---|---|---|
| `/live/browser/load_item` | `track_index, uri` | `track_index, uri, 'ok', device_name, device_index` |
| `/live/browser/load_item` | | `track_index, uri, 'error', message` (unchanged) |

`device_index` is the loaded device's position in `track.devices` (the index
`/live/view/set/selected_device` and the device tools take). `-1` when the
device is not yet on the chain — some VST/AU plugins instantiate
asynchronously (the existing `_loaded_device_name` fallback case). No
backwards compatibility with the 4-element reply: `mix abletonosc.install` is
required, and the Elixir side reports a stale extension explicitly (Part 4).

## Numbered parts

### Part 1 — Fork Python: three addresses and one reply extension

Files (all in the submodule; `git -C priv/AbletonOSC checkout master` first,
commit and push there, then `git add priv/AbletonOSC` from the root in the
same Seshat commit as the Elixir side):

1. `priv/AbletonOSC/abletonosc/view.py` — add `import Live`; register
   `/live/view/show_view` and `/live/view/set/detail_clip` in `init_api`.
   Both wrap their LOM call in try/except → `self.logger.error`, reply
   nothing. This is an edit to an upstream file, so it goes in `SESHAT.md`
   under a new "Additions to upstream files" note (the existing divergence
   list is the model).
2. `priv/AbletonOSC/abletonosc/return_track.py` — register
   `/live/return_track/select`, implemented with the existing
   `_return_track(params, "select")` lookup; on error return `None`
   (silent, logged by the lookup). Update the file's header comment table.
3. `priv/AbletonOSC/abletonosc/browser.py` — rename `_loaded_device_name` to
   `_loaded_device`, returning `(name, index)`: prefer the device whose name
   matches `item.name` (its index), else the last device, else
   `(item.name, -1)` when the chain is empty. `_load_item`'s ok-reply becomes
   `(track_index, uri, "ok", name, index)`. Update the module header comment.
4. `priv/AbletonOSC/SESHAT.md` — record all three divergences.

**Live runs the copy installed by `mix abletonosc.install`, not the
submodule** — after this part lands, a reinstall + Live restart is required
before any smoke test means anything.

### Part 2 — Canonical docs

[abletonosc-api-docs.md](abletonosc-api-docs.md):

- View API section: add `/live/view/show_view` and
  `/live/view/set/detail_clip` rows, marked as Seshat extensions (fork only),
  with the valid view-name list and the "silent, errors logged" behavior.
- Return Track & Master section: add `/live/return_track/select`.
- Browser API section: update both `load_item` rows to the 5-element ok reply
  and document `device_index` / `-1`.

`vendored_addresses_test` enforces registered → documented, so this part is
load-bearing, not cosmetic.

### Part 3 — The pure seam: `Seshat.Tools.FollowCam`

New file `lib/seshat/tools/follow_cam.ex`:

- `@spec calls(String.t(), map()) :: [{String.t(), list()}]` — pure. One
  clause per steering tool, taking the facts the handler gathered and
  returning the ordered `{address, args}` list. All addresses as string
  literals (the vendored tripwire greps for `"/live/` literals; never
  interpolate).
- `@spec steer(String.t(), map()) :: :ok` — iterates `calls/2` through
  `Transport.send_message/2`, ignoring `{:error, _}` returns and catching
  `:exit` (a dead or absent Transport), so steering can never fail or delay
  the tool it follows. Always returns `:ok`.

The recipes (selection first, then panes; `t` = track, `s` = slot/scene,
`d` = device index):

| Tool | Facts | Calls, in order |
|---|---|---|
| `write_midi_notes`, `remove_notes`, `duplicate_clip` (target slot), `capture_midi` (first new clip in track order) | `t`, `s` | `set/selected_clip [t,s]` · `set/detail_clip [t,s]` · `show_view ["Session"]` · `show_view ["Detail/Clip"]` |
| `delete_clip` | `t`, `s` | `set/selected_clip [t,s]` · `show_view ["Session"]` (no detail — the slot is empty now) |
| `create_track` (new index from Registry), `duplicate_track` (source + 1) | `t` | `set/selected_track [t]` — no pane change: track headers are visible in Session and Arrangement both |
| `delete_track` | deleted index `t`, remaining count `n` | `n == 0` → no calls; else `set/selected_track [min(t, n-1)]` |
| `create_return_track` (index from Registry) | `r` | `/live/return_track/select [r]` |
| `delete_return_track` | deleted index `r`, remaining count `n` | `n == 0` → no calls (the container would be the master, which is out of scope); else `select [min(r, n-1)]` |
| `create_scene` (resolved index), `duplicate_scene` (source + 1) | `s` | `set/selected_scene [s]` · `show_view ["Session"]` (scenes exist only there) |
| `delete_scene` | deleted index `s`, remaining count `n` | `n == 0` → no calls; else `set/selected_scene [min(s, n-1)]` · `show_view ["Session"]` |
| `load_device` | `t`, `d` | `d >= 0` → `set/selected_device [t,d]` · `show_view ["Detail/DeviceChain"]`; `d == -1` (async plugin) → `set/selected_track [t]` · `show_view ["Detail/DeviceChain"]` |
| `delete_device` | `t`, deleted index `d`, remaining chain length `n` | `n == 0` → `set/selected_track [t]` · `show_view ["Detail/DeviceChain"]` (the empty chain is the evidence); else `set/selected_device [t, min(d, n-1)]` · `show_view ["Detail/DeviceChain"]` |
| `bypass_device` | `t`, `d` | `set/selected_device [t,d]` · `show_view ["Detail/DeviceChain"]` — on the no-op ("already Off") path too: showing the device is the confirmation either way |

Design calls made here rather than deferred: `capture_midi` with several new
clips steers to the first in track-then-slot order (typically there is one;
the reply lists them all regardless). Steering happens only on the success
path — an errored tool steers nowhere.

### Part 4 — Wire the handlers (and Registry)

[lib/seshat/commands/registry.ex](../lib/seshat/commands/registry.ex):

- `execute(%Command{command: :create_track, ...})` returns `{:ok, index}`
  instead of `:ok` — `create_and_name_track` already holds the pre-create
  `num_tracks`, which *is* the new index. The `@spec` union already covers
  `{:ok, non_neg_integer()}` (for `:create_return_track`); update the
  moduledoc sentence claiming only `:create_return_track` hands back an
  index, and the handler.

[lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex), per clause:

- `create_track`: take `{:ok, index}` from Registry, steer, and include the
  index in the reply ("Created midi track 'Drums' at index 3") — the model
  currently has to re-derive it.
- `duplicate_track`: steer to `track + 1`, then `State.refresh()`. The
  ordering rule for every clause below is precisely: any post-mutation
  **count query** (num_tracks, num_scenes, return count) runs *before* the
  `State.refresh()` cast, so it cannot interleave with the refresh's own
  queries to the same addresses; the steering sends themselves are
  fire-and-forget and cannot race anything. Reply mentions the new index.
  ⚠️ Live placing the duplicate at source + 1 is assumed; smoke-test it.
- `delete_track`: after the delete, query `/live/song/get/num_tracks`
  (2s guard timeout, best-effort: on timeout/mismatch skip steering, keep the
  success reply), steer, then `State.refresh()`.
- `create_scene`: query `/live/song/get/num_scenes` after the create; resolved
  index is `count - 1` when the param was `-1`, else the param. Steer; reply
  names the resolved index.
- `duplicate_scene`: steer to `scene + 1`.
- `delete_scene`: query `num_scenes` after, steer with the clamp.
- `write_midi_notes`, `remove_notes`: steer with the known track/slot.
- `duplicate_clip`: steer to the target slot.
- `capture_midi`: in `report_capture`/`retry_capture_diff`'s success branch,
  steer to the first new clip.
- `delete_clip`: steer to the now-empty slot.
- `create_return_track` / `delete_return_track`: steer with the index Registry
  / the count re-read provides (`/live/return_track/get/count`, bare-value
  reply, 2s guard timeout, best-effort). Note `:create_return_track` (like
  `:create_track`) calls `State.refresh()` *inside* `Registry.execute/1`
  before returning — steer after Registry returns and leave that refresh
  where it is; only `delete_return_track`'s handler-side count query needs
  to run before the handler's own `State.refresh()`.
- `load_device`: match the new 5-element reply
  `[_track, _uri, "ok", name, device_index]`, steer, and keep the reply text
  ("Loaded 'X' onto track N (device D)"). Add a clause matching the old
  4-element ok shape that returns an error telling the user to re-run
  `mix abletonosc.install` and restart Live — not a compat path, a
  self-diagnosing refusal.
- `delete_device`: steer using the pre-delete `names` list already in hand
  (`length(names) - 1` is the remaining count).
- `bypass_device`: steer in both `set_device_enabled` outcomes (write and
  no-op).

Replies otherwise stay as they are — steering is plumbing, not something the
model needs narrated beyond the one-line description notes in Part 5.

### Part 5 — The clip `name` adjunct

[lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex):

- `write_midi_notes`: add optional `"name"` param —
  `%{type: "string", description: "Optional clip name, shown on the clip in Live's Session grid and in get_clip_slots readouts. Only used when creating or writing the clip — omit to leave it unnamed (there is no auto-generated fallback); set_clip_name renames later."}`.
  Append to the description:
  `"Optionally pass name to label the clip. After the write, Live's view follows automatically — the clip is selected with the note editor open — so no select_track call is needed to show the result."`
- `capture_midi`: add optional `"name"` param —
  `%{type: "string", description: "Optional name for the captured clip(s), shown in Live's Session grid. Omit to leave them unnamed."}`
  — and update the description's "No parameters" sentence accordingly, plus:
  `"The view follows the capture automatically: the new clip is selected with the note editor open, even mid-playback."`
- `load_device`: append one sentence:
  `"The view follows the load automatically — the new device is selected with its panel open."`

[lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex):

- `write_midi_notes`: when `"name"` is present, send
  `/live/clip/set/name [track, slot, name]` after the successful write and
  before steering; the reply mentions the name.
- `capture_midi`: when `"name"` is present and the diff found new clips, send
  `/live/clip/set/name` for each new clip (a multi-track capture is one take;
  the same name on each is correct) and substitute the name into the clip
  maps so `captured_reply/4` prints it — the after-snapshot predates the
  rename, so re-reading would cost a round trip for a string we just wrote
  (the same trust `set_clip_name` itself extends to a fire-and-forget send).

No new tools, so no count bump in `definitions_test.exs`; MCP components
regenerate from the definitions.

### Part 6 — Tests

- New `test/seshat/tools/follow_cam_test.exs`: drive `calls/2` for every
  steering tool — exact address/args sequences in order, and the edge rules:
  delete-last → no calls (tracks, returns, scenes), the `min` clamp on
  mid-list deletes, `load_device` with `d == -1`, `delete_device` to an empty
  chain, `capture_midi` first-clip choice.
- [test/seshat/osc/vendored_addresses_test.exs](../test/seshat/osc/vendored_addresses_test.exs):
  - add `@view_file "priv/AbletonOSC/abletonosc/view.py"` to
    `@handler_files` (its upstream addresses are already all in the docs, so
    the registered → documented direction stays green);
  - add `@vendored_view_addresses ["/live/view/show_view", "/live/view/set/detail_clip"]`,
    fold into `vendored?/1`, and extend the exact-match "still sent" pin test
    to cover them (same self-exclusion hazard as the song addresses);
  - new "the view handler registers exactly …" test pinning view.py's full
    list (upstream's twelve plus the two new ones);
  - the return/master exact-list test grows to fourteen with
    `/live/return_track/select`.
- Existing handler-shape tests: unaffected — `steer/2` swallows transport
  errors and exits, so clauses that now steer behave identically in a test
  environment with nothing listening on the wire.
- `mix precommit` before declaring done.

### Part 7 — Documentation ripple

- [CLAUDE.md](../CLAUDE.md): the "Before using any OSC address" fork section
  says Seshat's addresses live in *three* handler modules — after this
  feature, vendored addresses also live in upstream's `view.py`
  (`/live/view/show_view`, `/live/view/set/detail_clip`). Update that section
  and the module-map row for the submodule, and add a module-map row for
  `lib/seshat/tools/follow_cam.ex`.
- [.claude/rules/osc.md](../.claude/rules/osc.md): same correction to the
  "ours, not upstream's" bullet.
- [TOOL_AUDIT.md](TOOL_AUDIT.md): note on the inventory that the sixteen
  steering tools now follow-cam, and that `write_midi_notes`/`capture_midi`
  gained the optional `name`.
- The `/smoke-test` checklist line the roadmap asks for **cannot be edited by
  this lifecycle run** (`.claude/skills/` is out of scope for its agents); the
  checklist content is in Testing below for the user to fold in afterwards.

## Testing

Covered pure (no Ableton):

- Every steering recipe, ordering, and edge rule via `FollowCam.calls/2`.
- Both directions of the vendored-address seam (Elixir literals ↔ Python
  registrations ↔ canonical docs), including the two new view addresses and
  the return select.
- Definitions/MCP parity for the new `name` params (existing parity suite).

Only Ableton can confirm (fold into `/smoke-test`, after
`mix abletonosc.install` + Live restart — **no test in this repo executes the
fork's Python**):

1. `write_midi_notes` from Arrangement view with the Detail pane closed: the
   view must land in Session with the note editor open on the new notes —
   the validation-run failure re-run as the acceptance test.
2. `capture_midi` **while playing**: the new clip selected and visible
   mid-playback, playback undisturbed; with `name`, the grid shows it.
3. `load_device`: the loaded device selected with Detail/DeviceChain shown;
   reply carries a sane device index (instrument lands *before* existing
   audio effects — the index must be the instrument's, not the tail's). Try a
   slow AU/VST for the `-1` path.
4. `delete_device` down to an empty chain; `bypass_device` no-op path — the
   pane still shows the chain.
5. `duplicate_track`: confirm the copy lands at source + 1 and gets selected;
   same check for `duplicate_scene`.
6. `create_return_track` / `delete_return_track`: selection lands on the
   return strip; delete-last steers nowhere and errors nothing.
7. Deletes in the middle of tracks/scenes: selection lands on the successor
   at the same index.
8. Bad view name / empty slot on the new addresses: silent on the wire, one
   line in Live's `Log.txt`, no `RemoteScriptError` during ordinary steering.

## Out of scope

- **Master selection** — `set_master_volume` is a parameter tweak and doesn't
  steer; no master-select address is added (settled).
- **Any steering toggle** — not config, not a tool (settled).
- **Steering for parameter/transport/rename/read tools** (settled; the list
  in Context is exhaustive).
- **Session-record interaction** — selecting a scene changes which slot row
  session record targets; that hazard belongs to roadmap #3, which should
  read this plan's recipes when it lands.
- **`select_track` / `select_scene` tools** — unchanged; they remain the
  model's explicit steering levers and are read-only view moves, not part of
  the in-list.
- **Naming beyond the two writing tools** — `set_clip_name` already covers
  renames; no name param spreads to `duplicate_clip` etc.

## Open questions

1. ⚠️ **Do `duplicate_track` / `duplicate_scene` place the copy at
   source + 1?** Assumed (it is Live's UI behavior); only a live Ableton can
   confirm the LOM call matches. If a copy lands elsewhere, the fix is a
   post-duplicate `num_tracks`/`num_scenes`-style read, not a recipe change.
   Smoke-test item 5.
2. ⚠️ **Do the view-name strings land?** `"Session"`, `"Detail/Clip"`,
   `"Detail/DeviceChain"` are the Live API's documented constants for
   `Application.View.show_view`, but the installed Live's acceptance can only
   be proven on the machine. Smoke-test items 1–4 all exercise them.
3. ⚠️ **Does `song.view.selected_track` accept a return track?** Documented
   LOM behavior says any track is selectable; unverifiable without Live.
   Fallback if not: `song.view.selected_track` has no return-capable
   alternative, so the recipe for returns would drop to no-op — but there is
   no reason to expect that. Smoke-test item 6.
4. ⚠️ **`load_item`'s device index for async plugins.** The `-1` path exists
   because `_loaded_device_name` already handles an empty chain; whether a
   given plugin resolves fast enough to index is per-plugin. The recipe
   degrades to track-selection, so nothing breaks either way. Smoke-test
   item 3.
5. ⚠️ **Does `detail_clip` need the pane visible first?** The recipe sets
   `detail_clip` before `show_view ["Detail/Clip"]`; if Live requires the
   opposite order the two sends swap — a one-line recipe change the pure
   tests pin either way. Smoke-test item 1 decides.

None of these needs the user's call — all five are Ableton-only checks, listed
first in the smoke-test section, and each has a stated fallback that stays
inside this plan's shape.
