# Seshat MCP — Tool Audit

_Living doc · MCP design review · one verdict per tool · 25 Jul 2026 — update as tools change._

> **The tool count lives in one place:** the assertion in
> [test/seshat/tools/definitions_test.exs](../test/seshat/tools/definitions_test.exs),
> which fails until it is bumped deliberately. Don't restate it in prose here or
> anywhere else — the inventory table below is the list, and a number copied into
> a sentence goes stale silently.

> **Fixes applied 26 Jul 2026.** All three correctness items are done
> (`write_midi_notes` and `fire_clip` now error instead of failing silently;
> `set_track_volume` states the real scale and echoes dB, as does
> `set_track_pan` in L/R) — see
> [archive/PLAN_audit_fixes.md](archive/PLAN_audit_fixes.md).
> The `search_library` ⟷ `list_browser_items` routing note turned out to be
> already present on both sides. The optional merges were declined on purpose.
> What remains from this audit is §02, now tracked on
> [ROADMAP.md](ROADMAP.md).
>
> Both new guards query Ableton, so neither is unit-testable (see
> [.claude/rules/testing.md](../.claude/rules/testing.md)) — the **Keep**
> verdicts below record the intended behavior and are pending confirmation by
> the Part 8 traps in [validation-script.md](validation-script.md).

> **Sends, return tracks and master shipped 26 Jul 2026** — six new tools
> (`set_track_send`, `get_track_sends`, `create_return_track`,
> `delete_return_track`, `set_return_track_volume`, `set_master_volume`),
> closing §02's top gap and the master/return level gap with it. Returns and the
> master needed a second vendored AbletonOSC handler
> (`priv/AbletonOSC/abletonosc/return_track.py`) because upstream reaches `song.tracks`
> only — see [archive/PLAN_send_levels.md](archive/PLAN_send_levels.md).

> **`search_library` result quality shipped 27 Jul 2026.** Two things §04
> praised as exemplary description work were in fact false: the `tags`
> parameter filtered with a strict AND (one tag the library lacked zeroed the
> whole search), and the description advertised 30 tags, four of which don't
> exist here — its own worked example, "a warm analog bass", returned
> nothing. Tags now score rather than gate, the score band at the result cut
> round-robins across device roots, and the zero-result, truncated and
> `reindex_library` replies report the machine's real vocabulary instead of a
> hardcoded list. See
> [archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md).

> **`create_project` removed 28 Jul 2026.** The 25 Jul "Keep" verdict didn't
> survive the validation run: the tool's AppleScript Cmd+N step only worked
> when redundant, and its default-track cleanup was both racy and impossible
> to complete (Live keeps a set's last track). Replaced by a stripped Default
> Live Set plus ordinary `create_track` calls — see
> [archive/create-project-removal.md](archive/create-project-removal.md).

> **Follow cam shipped 28 Jul 2026.** No new tools: sixteen existing ones
> (`create_track`, `duplicate_track`, `create_return_track`, `create_scene`,
> `duplicate_scene`, `write_midi_notes`, `remove_notes`, `capture_midi`,
> `duplicate_clip`, `load_device`, `delete_device`, `bypass_device`,
> `delete_track`, `delete_return_track`, `delete_scene`, `delete_clip`) now end
> by steering Live's view onto what they changed — selection plus the pane it
> lives in — so the change is visible without the model being asked to select
> anything. Parameter tweaks, transport, renames and reads deliberately do not
> steer, and there is no toggle. `write_midi_notes` and `capture_midi` also
> gained an optional `name`, so an occupied slot carries visible text; there is
> no auto-generated fallback. The decision lives in
> `Seshat.Tools.FollowCam.calls/2` (pure, fully unit-tested); the panes needed
> three new vendored OSC addresses. See
> [archive/PLAN_follow_cam.md](archive/PLAN_follow_cam.md).

> **Superseded in part, 2026-07-30 — an external review found correctness
> defects this audit missed.** See
> [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md), the active correctness
> backlog. Three verdicts below were wrong and are corrected inline: the
> "0 correctness fixes outstanding" line, §03's "Indexing is clean — strong",
> and the `create_track` inventory row. The audit's scope explains the gap
> rather than excusing it — it reviewed the tool surface as *designed*
> (descriptions, schemas, overlaps, coverage) and did not trace handler
> implementations, so defects that live below the schema were invisible to it.
> Consult both docs before "fixing" a tool.

**At a glance:** ~~0 correctness fixes outstanding (3 applied)~~ ~~≥4 outstanding, from the 2026-07-29 external review (index validation, numeric bounds, `create_track` verification, fabricated session-state defaults)~~ ~~1 outstanding, from the 2026-07-29 external review (`create_track` verification — index validation and numeric bounds fixed 2026-07-30, fabricated session-state defaults fixed 2026-07-30)~~ **0 outstanding from the 2026-07-29 external review** (index validation, numeric bounds and fabricated session-state defaults fixed 2026-07-30; `create_track` verification fixed 2026-07-30) · 0 unresolved overlaps · ~6 coverage gaps (mostly optional), all on the roadmap.

**Overall: healthy.** The surface is well-factored — granular-by-object, consistently 0-based, and several descriptions are genuinely exemplary. There is little dead weight and almost nothing to merge. The highest-value work is not consolidation; it's a couple of correctness fixes (silent failures, a misleading scale) and filling the sends/record gaps. Treat the merge ideas as optional polish.

Priority key: **High** = blocks a common workflow · **Medium** = worth building soon · **Low** = breadth / later.

---

## 01 · Consolidation & Redundancy

Where two tools do the same job, or one should split. Verdict: barely anything — one genuine overlap, one optional merge.

**`search_library` ⟷ `list_browser_items` — ~~Medium · clarify roles~~ · RESOLVED, no change needed.** Two sound-discovery tools with heavy overlap. _Original action:_ add a reciprocal routing note in `list_browser_items`. _Outcome (26 Jul):_ on re-reading the source, that note is already there — `list_browser_items` opens with "TRY search_library FIRST … use this one when search_library comes back empty, when the catalog has never been built, or for raw samples." The hierarchy is stated on both sides; the audit read a stale copy. Keeping both tools, as recommended.

**Boolean track toggles — Low · optional merge.** `set_track_mute`, `set_track_solo`, and `set_track_arm` share an identical signature (`track` + a bool) and identical intent shape. Textbook merge candidate: `set_track_state(track, state: mute|solo|arm, enabled)`. _Action:_ optional — three tiny, crystal-clear tools aren't hurting anything, so merge only if you're actively trimming. Do **not** fold `set_track_volume`/`set_track_pan` in with them; their value ranges differ (0–1 vs −1..1) and separate descriptions keep selection accurate.

**Everything else is distinct — keep as-is.** The `delete_*`, `duplicate_*`, and `set_*_name` families look mergeable but aren't — each addresses a different object (track vs scene vs track+slot) with different parameters. Merging them into polymorphic `delete(type, …)` tools would _lower_ selection accuracy. Leave them split.

---

## 02 · Coverage Gaps

Operations a producer would expect that no tool currently reaches, ranked by how often they block real work.

| Gap                                                                       | Priority | Why it matters                                                                                                                                      |
| ------------------------------------------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| ~~**Sends / return tracks**~~ · **ADDRESSED 07/2026**                     | ~~High~~ | Was the top gap. `set_track_send` / `get_track_sends` / `create_return_track` / `delete_return_track` now cover the reverb-and-delay workflow. Loading a device *onto* a return is still manual. |
| ~~**Remove / bypass a device**~~ · **ADDRESSED 07/2026** | ~~Med-High~~ | `delete_device` and `bypass_device` close the audition loop — a wrong load is undoable and a device can be A/B'd in place. Regular tracks only (upstream reaches `song.tracks` alone). |
| **Reorder the device chain**                                              | Low      | The remaining half of the old one-way-device-workflow gap: a device can be added, bypassed and removed, but not moved. Deliberately not planned until a workflow demands it. |
| ~~**Record into a slot**~~ · **ADDRESSED 07/2026** | ~~Medium~~ | `capture_midi` keeps the MIDI just played from Live's retroactive buffer; `record_clip` and `stop_recording` now cover the *deliberate* take — arm (automatic), record into a chosen slot, fixed-length or open-ended, on MIDI **and audio** tracks. Both ride `/live/clip_slot/fire`'s optional `record_length`, so no fork change was needed. Still out deliberately: global multi-track session record (`/live/song/set/session_record` — different user story, no slot choice) and count-in (`count_in_duration`/`is_counting_in` are in Live 12's LOM but unregistered upstream; a one-line fork commit plus an install if takes prove to start before the user is ready). |
| ~~**Per-clip properties** (clip loop/start/end, launch mode)~~ · **ADDRESSED 07/2026** | ~~Medium~~ | `get_clip_properties` and `set_clip_properties` reach a clip's own loop brace, play markers, launch mode/quantization, legato and velocity amount, plus gain/warp for audio clips — so a captured clip can now be trimmed to the good bars. Length still has no direct setter (Live has none); it follows from the markers or the loop. Still out: `muted`, `color`, `position`, `pitch_coarse`/`pitch_fine`, `ram_mode` and `duplicate_loop` — grab-bag territory, roadmap "Small OSC breadth". |
| ~~**Quantize notes** (`quantize_clip`)~~ · **ADDRESSED 07/2026**          | ~~Medium~~ | `quantize_clip` calls Live's own `Clip.quantize` through the fork's existing `/live/clip/quantize`, so the grid arithmetic never gets reimplemented in Elixir — which turned out to matter: the documented `GridQuantization` table was wrong in every row, and the tool's string enum (`"1/16"`, `"1/8T"`, …) keeps the corrected integers behind one private function. Still out: per-pitch quantize (`Clip.quantize_pitch`), audio-clip warp-marker quantize, and groove/swing amount. |
| **Set time signature** (`set_time_signature`)                             | Low-Med  | `get_session_state` reports it and `set_tempo` exists, but there's no setter. Cheap, obvious symmetry win.                                          |
| ~~**Master & return volume**~~ · **ADDRESSED 07/2026**                    | ~~Low-Med~~ | `set_master_volume` and `set_return_track_volume` ride along with the sends work, and `get_session_state` now reports both. Pan/mute/solo on returns and the master are still out. |
| **Modify a note in place**                                                | Low      | Changing one note's velocity/length means read → remove range → rewrite. Works, but a direct edit would be cleaner.                                 |
| **Arrangement view** (record, place clips at bars, locators)              | Low      | Everything today is Session view. Fine for clip-launch work; a scope decision, not a bug.                                                           |
| **Groups · routing/IO · automation · groove**                             | Low      | Breadth for later — grouping tracks, input/output routing & monitoring, automation envelopes, swing/groove.                                         |

---

## 03 · Naming & Consistency

Conventions are strong overall. A few small drifts worth aligning as you grow the surface.

**Result-echo quality is inconsistent — Medium.** Newer setters set the bar: `set_device_parameter` and `load_device` echo a human-readable result ("2.5 kHz", "Loaded 'Analog Bass'") and tell me to verify it. Older mixer setters echo raw internals — `"OK — volume track 0 to 0.8"` — which I can't confirm against intent. _Action:_ have the older setters echo display values too (dB for volume, L/R for pan). This is what lets me self-check that an action did what the user meant.

**`scene` vs `clip_slot` for the same grid row — Low.** One row of the Session grid is `scene` in `fire_scene`/`select_scene` but `clip_slot` in `fire_clip`/`write_midi_notes`. That mirrors Ableton's own model (a scene is a row of slots), so it's defensible — but only `get_clip_slots` explains the equivalence. _Action:_ restate "slot N = scene N" in each clip-slot tool's description.

**Minor param drift — Low.** `create_scene` names the position `index`, while every other scene tool uses `scene`. Scalar setters use a generic `value` while booleans use property names (`muted`/`soloed`/`armed`). Both defensible; noting for consistency as the surface grows.

**~~Indexing is clean — strong.~~ ~~CORRECTED 30 Jul — the convention is clean; the *schemas* are not.~~ FIXED 30 Jul — the schemas enforce it now too.** This verdict asked whether the 0-based convention was applied consistently and never asked whether the schemas enforced it. They didn't: `minimum: 0` was present on the newer tools and missing on the older ones (`set_track_pan`, `set_track_volume`, `delete_track`, `duplicate_track`, `set_track_name`), and Python indexes Live's collections directly — so `track: -1` silently operated on the *last* track while the reply echoed "track -1". Finding #3 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md); closed by `Seshat.Tools.Validation`, a schema-driven validator called from `Handlers.call/2` before every dispatch, plus the missing `minimum`/`maximum` bounds added across `Definitions` and the `MCP.Schema` number branch now carrying its ranges through the wire (finding #4). See [archive/PLAN_enforce_tool_ranges.md](archive/PLAN_enforce_tool_ranges.md). The original observation below still holds for the convention itself. 0-based everywhere, consistently documented, with the "'track 1' = index 0" reminder repeated across tools. The user-facing guidance ("refer to tracks by name or 1-based UI number") only appears in `get_session_state` — consider echoing it in the other read tools so the 1-based-to-user rule is never missed.

---

## 04 · Descriptions & Schemas

Description quality is a real strength here. Two behaviors, though, were correctness issues, not wording ones — both now fixed.

**`write_midi_notes` ~~fails silently on audio tracks — High · fix behavior~~ · FIXED 26 Jul.** The description admitted it: "this tool fails silently on audio tracks." Silent failure is the worst failure mode — I'd report success on a write that never happened. (`fire_clip` on an empty slot is a milder version: it silently stops the track instead of erroring.) _Original action:_ return an explicit error ("track N is an audio track — can't write MIDI") instead of a silent no-op. _Outcome:_ both are guarded now — `write_midi_notes` rejects audio tracks *and* group tracks (a MIDI group track passes `has_midi_input` but owns no clip slots), `fire_clip` rejects empty slots and points at `stop_clip`, and both descriptions state the new behavior.

**`set_track_volume` ~~scale is misleading — Medium · fix description~~ · FIXED 26 Jul.** Description said "0.0 = silence, 1.0 = full/max." In Ableton the mixer's 0–1 is not linear and 1.0 is _not_ the ceiling — roughly 0.85 ≈ 0 dB (unity) and 1.0 ≈ +6 dB. Callers (me included) will misjudge "set it to full." _Original action:_ correct the description to note ~0.85 = unity / 0 dB, and ideally echo the resulting dB value. _Outcome:_ both done — the description gives the real scale and maps 'full' to 0.85, and the reply echoes an approximate dB (`Handlers.volume_display/1`). `set_track_pan` got the same treatment in Live's L/R notation.

**`remove_notes` deletes ALL notes by default — Low.** With no range, it clears the whole clip. Documented, and well-mitigated by pairing with `get_clip_notes` — but a footgun for a caller who forgets the range. _Action:_ optional — require an explicit range or an `all: true` flag to make full clears deliberate.

**Exemplary descriptions to keep as the template — strong.** `write_midi_notes`, `search_library`, `get_clip_slots`, and `get_device_parameters` are model descriptions: they state preconditions ("call X first"), give units and legal ranges, warn about edge cases, and tell the caller to verify the echoed result. Use these as the house style for every new tool.

---

## 05 · Full Inventory

Every tool with a per-tool verdict. Status: **Keep** = good as-is · **Fix** = behavior/description change · **Review** = resolve overlap · **Merge?** = optional consolidation.

Nineteen tools below steer Live's view onto what they changed: every
**Structure**, **MIDI** and device-mutating one (the sixteen in the follow-cam
note above), plus three that create or reshape a clip without belonging to those
categories — `set_clip_properties`, and the `record_clip`/`stop_recording` pair
listed here under **Transport**. Rows aren't annotated individually: steering
follows from what a tool *does to a clip*, not from any one row.

| Tool                    | Category  | Status | Note                                                     |
| ----------------------- | --------- | ------ | -------------------------------------------------------- |
| `get_session_state`     | Read      | Keep   | Track-level state. Stays fresh by push; `refresh: true` is the backstop. **Fixed 07/2026 (Finding #7):** a failed refresh query now yields `nil`, never a plausible-looking default, and the reply states each unknown explicitly rather than reporting a fabricated number the model would otherwise write bar lengths against. |
| `get_clip_slots`        | Read      | Keep   | Exemplary description.                                   |
| `get_clip_notes`        | Read      | Keep   | Clean errors. Closes the read-notes gap.                 |
| `get_track_devices`     | Read      | Keep   | Racks show as one device — noted well.                   |
| `get_device_parameters` | Read      | Keep   | Great "trust the min/max" guidance.                      |
| `undo`                  | History   | Keep   | —                                                        |
| `redo`                  | History   | Keep   | —                                                        |
| `create_track`          | Structure | Keep   | Verifies the count rose by exactly one before naming the track and reporting the index (finding #6, fixed 07/2026); an unchanged count, or a jump of more than one, errors honestly instead of returning a bogus or ambiguous index. |
| `create_scene`          | Structure | Keep   | Position param `index` vs `scene` elsewhere.             |
| `delete_track`          | Structure | Keep   | —                                                        |
| `delete_scene`          | Structure | Keep   | —                                                        |
| `delete_clip`           | Structure | Keep   | —                                                        |
| `duplicate_track`       | Structure | Keep   | —                                                        |
| `duplicate_scene`       | Structure | Keep   | —                                                        |
| `duplicate_clip`        | Structure | Keep   | —                                                        |
| `set_track_name`        | Naming    | Keep   | —                                                        |
| `set_scene_name`        | Naming    | Keep   | —                                                        |
| `set_clip_name`         | Naming    | Keep   | —                                                        |
| `select_track`          | Selection | Keep   | —                                                        |
| `select_scene`          | Selection | Keep   | —                                                        |
| `set_track_volume`      | Mixer     | Keep   | Fixed 07/2026 — real scale documented, echoes dB.        |
| `set_track_pan`         | Mixer     | Keep   | Echoes Live's L/R notation (07/2026).                    |
| `set_track_mute`        | Mixer     | Merge? | Optional: fold into `set_track_state`.                   |
| `set_track_solo`        | Mixer     | Merge? | Optional: fold into `set_track_state`.                   |
| `set_track_arm`         | Mixer     | Merge? | Optional: fold into `set_track_state`.                   |
| `start_playing`         | Transport | Keep   | —                                                        |
| `stop_playing`          | Transport | Keep   | —                                                        |
| `set_tempo`             | Transport | Keep   | Pairs with a missing `set_time_signature`.               |
| `set_metronome`         | Transport | Keep   | —                                                        |
| `set_loop`              | Transport | Keep   | Song loop — description now points at `set_clip_properties` for a clip's own brace (07/2026). |
| `capture_midi`          | Transport | Keep   | New 07/2026. Verifies by clip-grid diff (the address never replies); reports Live's tempo inference. Optional `name` (07/2026). |
| `record_clip`           | Transport | Keep   | New 07/2026 — closes the §02 record-into-a-slot gap, and the only route audio has into a set. Fixed-length via `/live/clip_slot/fire`'s `record_length`; auto-arms, with `can_be_armed`/`will_record_on_start` guards and a re-read after the silent `set/arm`. |
| `stop_recording`        | Transport | Keep   | New 07/2026. Re-fires the recording slot, so the take ends on the quantization boundary and drops into looped playback. Guarded so the fire can never reach an empty slot and *start* a recording. |
| `fire_clip`             | Launch    | Keep   | Fixed 07/2026 — empty slot errors, not a silent stop.    |
| `fire_scene`            | Launch    | Keep   | —                                                        |
| `stop_clip`             | Launch    | Keep   | —                                                        |
| `write_midi_notes`      | MIDI      | Keep   | Fixed 07/2026 — audio and group tracks error. Optional `name` (07/2026). |
| `remove_notes`          | MIDI      | Keep   | Default-all is a mild footgun.                           |
| `list_browser_items`    | Devices   | Keep   | Fallback note already present — overlap resolved.        |
| `load_device`           | Devices   | Keep   | Good echo-and-verify pattern.                            |
| `set_device_parameter`  | Devices   | Keep   | Exemplary. Points at `bypass_device` for parameter 0.    |
| `delete_device`         | Devices   | Keep   | New 07/2026. Bounds-checks, then verifies by re-count (the address never replies). |
| `bypass_device`         | Devices   | Keep   | New 07/2026. Refuses unless parameter 0 reads On/Off.    |
| `search_library`        | Library   | Keep   | Scored 07/2026. Tags rank, don't gate; replies teach tags, and mark that steering text model-internal. |
| `reindex_library`       | Library   | Keep   | Reports the library's real tag vocabulary (07/2026).     |
| `get_track_sends`       | Read      | Keep   | New 07/2026. Labels each send with its return.           |
| `set_track_send`        | Mixer     | Keep   | New 07/2026. No dB echo — send curve unconfirmed.        |
| `set_return_track_volume` | Mixer   | Keep   | New 07/2026. Reuses the track fader's dB labels.         |
| `set_master_volume`     | Mixer     | Keep   | New 07/2026. Reuses the track fader's dB labels.         |
| `create_return_track`   | Structure | Keep   | New 07/2026. Errors at Live's 12-return cap.             |
| `delete_return_track`   | Structure | Keep   | New 07/2026. Warns that send letters shift.              |
| `get_clip_properties`   | Read      | Keep   | New 07/2026. Fourteen targeted reads of one clip; skips the audio-only set on a MIDI clip rather than timing out. |
| `quantize_clip`         | Clips     | Keep   | New 07/2026. Calls Live's own quantize rather than snapping in Elixir; `grid` is a string enum because the *documented* `GridQuantization` integers were wrong in every row (measured 31 Jul 2026), so the correction lives in one private function instead of in every caller's head. The address never replies, so verification is a before/after note diff — deliberately multiset, not paired, since a full quantize can legitimately merge same-pitch notes or trim an overlapped one. Refuses `amount: 0` (0% strength provably moves nothing, and would otherwise reach the "your install may be stale" hedge). |
| `set_clip_properties`   | Clips     | Keep   | New 07/2026. One object, several optional properties (the `set_loop` shape). Orders paired writes so `start < end` holds after every message, then verifies each by re-read — clip setters never reply. **Known wart (PR review, 07/2026):** the pair-context read that drives that ordering runs *before* a `looping` toggle in the same call is sent, so on a clip whose stored loop brace differs from its play markers, a simultaneous `looping: true` + brace move can see stale (pre-toggle) values. That affects both halves of the decision: the write *ordering*, and the single-sided validation that rejects `loop_start` alone against the current `loop_end`. The read-back echo would still surface any resulting mismatch — nothing is silently corrupted — but the guarantee doesn't hold in that one case. Fix is cheap (send `looping` first, then read the pair context), though it trades away the "nothing was set" promise on a validation failure; confirm against real Live behavior alongside smoke item 2 before or while fixing. |

---

## 06 · If You Do Five Things

1. ✅ **Make `write_midi_notes` error on audio tracks** — done 26 Jul, and on group tracks too (they report MIDI input but hold no clips, so they were the same phantom success by another route). Kills the one silent-failure that could make me report a write that never happened.
2. ✅ **Build sends / return tracks** — done 26 Jul: `set_track_send`, `get_track_sends`, `create_return_track`, `delete_return_track`, plus `set_return_track_volume` / `set_master_volume` riding along. Reverb/delay mixing is unlocked; only *loading* an effect onto a return is still a manual step in Live.
3. ✅ **Add device removal & bypass** — done 28 Jul: `delete_device` and `bypass_device` close the audition loop (load, listen, delete, load the next; or A/B via the device's own on/off switch). Reordering the chain stays out of scope.
4. ✅ **Fix the `set_track_volume` scale + echo dB** — done 26 Jul: 0.85 is unity, 1.0 is +6 dB, and both mixer setters now echo a display value.
5. ✅ **Clarify `search_library` vs `list_browser_items`** — already in place on both sides; no change was needed.

---

_Seshat MCP tool audit · living document · last swept 29 Jul 2026. Update the inventory status column as tools are added, fixed, or merged._
