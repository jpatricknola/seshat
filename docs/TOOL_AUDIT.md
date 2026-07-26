# Seshat MCP — Tool Audit

_Living doc · MCP design review · 41 tools reviewed · 25 Jul 2026 — update as tools change._

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

**At a glance:** 41 tools in the surface · 0 correctness fixes outstanding (3 applied) · 0 unresolved overlaps · ~10 coverage gaps (mostly optional), all on the roadmap.

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
| **Sends / return tracks** (`create_return_track`, `set_send`)             | High     | No way to route a track into reverb/delay. Mixing stops at volume/pan/mute/solo — you can't build space or depth.                                   |
| **Remove / bypass / reorder a device** (`delete_device`, `bypass_device`) | Med-High | You can `load_device` and tweak params, but can't undo a wrong load, turn a device off (A/B), or reorder the chain. The device workflow is one-way. |
| **Capture / record into a slot** (`session_record`, `capture_midi`)       | Medium   | `set_track_arm` + `start_playing` exist, but nothing actually records or captures played MIDI. The record loop is incomplete.                       |
| **Per-clip properties** (clip loop/start/end, launch mode)                | Medium   | `set_loop` is the _song_ loop, not a clip's loop. No control of a clip's own loop brace, length after creation, or launch quantization.             |
| **Quantize notes** (`quantize_clip`)                                      | Medium   | The most common MIDI cleanup move, currently impossible without a full read→remove→rewrite by hand.                                                 |
| **Set time signature** (`set_time_signature`)                             | Low-Med  | `get_session_state` reports it and `set_tempo` exists, but there's no setter. Cheap, obvious symmetry win.                                          |
| **Master & return volume**                                                | Low-Med  | The mixer setters operate on regular tracks only — no master or return level control (confirmed by `get_clip_slots` excluding them).                |
| **Modify a note in place**                                                | Low      | Changing one note's velocity/length means read → remove range → rewrite. Works, but a direct edit would be cleaner.                                 |
| **Arrangement view** (record, place clips at bars, locators)              | Low      | Everything today is Session view. Fine for clip-launch work; a scope decision, not a bug.                                                           |
| **Groups · routing/IO · automation · groove**                             | Low      | Breadth for later — grouping tracks, input/output routing & monitoring, automation envelopes, swing/groove.                                         |

---

## 03 · Naming & Consistency

Conventions are strong overall. A few small drifts worth aligning as you grow the surface.

**Result-echo quality is inconsistent — Medium.** Newer setters set the bar: `set_device_parameter` and `load_device` echo a human-readable result ("2.5 kHz", "Loaded 'Analog Bass'") and tell me to verify it. Older mixer setters echo raw internals — `"OK — volume track 0 to 0.8"` — which I can't confirm against intent. _Action:_ have the older setters echo display values too (dB for volume, L/R for pan). This is what lets me self-check that an action did what the user meant.

**`scene` vs `clip_slot` for the same grid row — Low.** One row of the Session grid is `scene` in `fire_scene`/`select_scene` but `clip_slot` in `fire_clip`/`write_midi_notes`. That mirrors Ableton's own model (a scene is a row of slots), so it's defensible — but only `get_clip_slots` explains the equivalence. _Action:_ restate "slot N = scene N" in each clip-slot tool's description.

**Minor param drift — Low.** `create_scene` names the position `index`, while every other scene tool uses `scene`. Scalar setters use a generic `value` while booleans use property names (`muted`/`soloed`/`armed`). Both defensible; noting for consistency as the surface grows.

**Indexing is clean — strong.** 0-based everywhere, consistently documented, with the "'track 1' = index 0" reminder repeated across tools. The user-facing guidance ("refer to tracks by name or 1-based UI number") only appears in `get_session_state` — consider echoing it in the other read tools so the 1-based-to-user rule is never missed.

---

## 04 · Descriptions & Schemas

Description quality is a real strength here. Two behaviors, though, were correctness issues, not wording ones — both now fixed.

**`write_midi_notes` ~~fails silently on audio tracks — High · fix behavior~~ · FIXED 26 Jul.** The description admitted it: "this tool fails silently on audio tracks." Silent failure is the worst failure mode — I'd report success on a write that never happened. (`fire_clip` on an empty slot is a milder version: it silently stops the track instead of erroring.) _Original action:_ return an explicit error ("track N is an audio track — can't write MIDI") instead of a silent no-op. _Outcome:_ both are guarded now — `write_midi_notes` rejects audio tracks *and* group tracks (a MIDI group track passes `has_midi_input` but owns no clip slots), `fire_clip` rejects empty slots and points at `stop_clip`, and both descriptions state the new behavior.

**`set_track_volume` ~~scale is misleading — Medium · fix description~~ · FIXED 26 Jul.** Description said "0.0 = silence, 1.0 = full/max." In Ableton the mixer's 0–1 is not linear and 1.0 is _not_ the ceiling — roughly 0.85 ≈ 0 dB (unity) and 1.0 ≈ +6 dB. Callers (me included) will misjudge "set it to full." _Original action:_ correct the description to note ~0.85 = unity / 0 dB, and ideally echo the resulting dB value. _Outcome:_ both done — the description gives the real scale and maps 'full' to 0.85, and the reply echoes an approximate dB (`Handlers.volume_display/1`). `set_track_pan` got the same treatment in Live's L/R notation.

**`remove_notes` deletes ALL notes by default — Low.** With no range, it clears the whole clip. Documented, and well-mitigated by pairing with `get_clip_notes` — but a footgun for a caller who forgets the range. _Action:_ optional — require an explicit range or an `all: true` flag to make full clears deliberate.

**Exemplary descriptions to keep as the template — strong.** `write_midi_notes`, `search_library`, `get_clip_slots`, and `get_device_parameters` are model descriptions: they state preconditions ("call X first"), give units and legal ranges, warn about edge cases, and tell the caller to verify the echoed result. Use these as the house style for every new tool.

---

## 05 · Full Inventory

All 41 tools with a per-tool verdict. Status: **Keep** = good as-is · **Fix** = behavior/description change · **Review** = resolve overlap · **Merge?** = optional consolidation.

| Tool                    | Category  | Status | Note                                                     |
| ----------------------- | --------- | ------ | -------------------------------------------------------- |
| `get_session_state`     | Read      | Keep   | Track-level state. Solid.                                |
| `get_clip_slots`        | Read      | Keep   | Exemplary description.                                   |
| `get_clip_notes`        | Read      | Keep   | Clean errors. Closes the read-notes gap.                 |
| `get_track_devices`     | Read      | Keep   | Racks show as one device — noted well.                   |
| `get_device_parameters` | Read      | Keep   | Great "trust the min/max" guidance.                      |
| `undo`                  | History   | Keep   | —                                                        |
| `redo`                  | History   | Keep   | —                                                        |
| `create_project`        | Structure | Keep   | —                                                        |
| `create_track`          | Structure | Keep   | —                                                        |
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
| `set_loop`              | Transport | Keep   | Song loop — distinct from per-clip loop gap.             |
| `fire_clip`             | Launch    | Keep   | Fixed 07/2026 — empty slot errors, not a silent stop.    |
| `fire_scene`            | Launch    | Keep   | —                                                        |
| `stop_clip`             | Launch    | Keep   | —                                                        |
| `write_midi_notes`      | MIDI      | Keep   | Fixed 07/2026 — audio and group tracks error.            |
| `remove_notes`          | MIDI      | Keep   | Default-all is a mild footgun.                           |
| `list_browser_items`    | Devices   | Keep   | Fallback note already present — overlap resolved.        |
| `load_device`           | Devices   | Keep   | Good echo-and-verify pattern.                            |
| `set_device_parameter`  | Devices   | Keep   | Exemplary. No delete/bypass companion.                   |
| `search_library`        | Library   | Keep   | Primary discovery tool; routing stated on both sides.    |
| `reindex_library`       | Library   | Keep   | —                                                        |

---

## 06 · If You Do Five Things

1. ✅ **Make `write_midi_notes` error on audio tracks** — done 26 Jul, and on group tracks too (they report MIDI input but hold no clips, so they were the same phantom success by another route). Kills the one silent-failure that could make me report a write that never happened.
2. **Build sends / return tracks** — `create_return_track` + `set_send`. The biggest capability gap — unlocks all reverb/delay mixing. Roadmap Priority 1.
3. **Add device removal & bypass** — so the device workflow isn't one-way; you can undo a wrong load and A/B. Roadmap Priority 2. (`/live/track/delete_device` exists in the installed AbletonOSC but is missing from our address docs — cheaper than it looked.)
4. ✅ **Fix the `set_track_volume` scale + echo dB** — done 26 Jul: 0.85 is unity, 1.0 is +6 dB, and both mixer setters now echo a display value.
5. ✅ **Clarify `search_library` vs `list_browser_items`** — already in place on both sides; no change was needed.

---

_Seshat MCP tool audit · living document · 41 tools as of 25 Jul 2026. Update the inventory status column and the summary counts as tools are added, fixed, or merged._
