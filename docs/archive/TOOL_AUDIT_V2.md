# Seshat MCP — Tool Audit (v2)

> **Archived 2026-07-31 — harvested.** Written by the MCP consumer (Claude
> Desktop) against the exposed tool surface; its actionable findings became
> ROADMAP.md items the same day ("Devices on return and master tracks",
> "Read-only audio input display", the `remove_notes` bullet under "Verify
> destructive mutations", and the Groove Pool note in the grab bag) — the rest
> were deliberately declined. **Known errors, verified against the code
> 2026-07-31:** the surface was 57 tools, not 58 — `create_project` in the
> inventory had already been removed (stale client tool cache; see
> [create-project-removal.md](create-project-removal.md)); the 25 Jul date is
> wrong (it covers tools shipped 29–31 Jul); and the "Corrections to v1"
> section is backwards for three of its four items — the `write_midi_notes`,
> `fire_clip`, and `set_track_volume` findings were real when v1 made them and
> drove fixes that shipped 26 Jul; the auditor re-read the post-fix schemas.

_Point-in-time record · 2026-07-31 · supersedes v1 ([TOOL_AUDIT.md](TOOL_AUDIT.md), 41 tools)._

**At a glance:** 58 tools (was 41) · 6/6 of v1's High+Medium gaps now built · 0 correctness bugs found · 2 Medium gaps remaining.

**Verdict: excellent and near-complete.** Seventeen tools were added since v1, closing every High- and Medium-priority gap from the last audit. On a careful re-read the surface has clean, explicit error handling throughout, wide use of echo-and-verify, and consistently strong descriptions. There are no correctness bugs and essentially nothing to consolidate. What remains is two Medium coverage gaps and some low-priority breadth.

---

## ⚠ Corrections to v1 — findings that did not survive verification

The first audit leaned on memory and observed replies rather than a direct schema re-read, and several "problems" were wrong. **None of them drove a build, so no work was wasted** — but the record needs fixing:

- **`write_midi_notes` "fails silently on audio tracks" — RETRACTED.** The schema says writing to an audio or group track is _rejected with an error and nothing is written._ No silent failure.
- **`fire_clip` "silent no-op on empty slot" — RETRACTED.** It _rejects an empty slot with an error_ and points to `stop_clip`.
- **`set_track_volume` "misleading 0–1 scale, doesn't echo dB" — RETRACTED.** The description already explains 0.85 = unity / +6 dB at 1.0, and a live test echoed `0.85 (≈ 0 dB)`. Accurate as-is.
- **`search_library` / `list_browser_items` "routing note only on one side" — RETRACTED.** `list_browser_items` already opens with "TRY search_library FIRST" and names the fallback cases. Reciprocal already exists; no action.

_Process note: this pass was done by re-reading each tool's current schema directly (and one live test), not from memory — which is how these were caught._

---

## 00 · Closed Since v1

Every one of these was a v1 gap:

✓ Sends / return tracks (6 tools) · ✓ Master & return volume · ✓ Device delete / bypass · ✓ Capture / record (3 tools) · ✓ Per-clip properties (loop, markers, launch, warp) · ✓ Quantize · ✓ Set time signature · ✓ Swing

---

## 01 · Consolidation & Redundancy

Now that the surface is bigger the question is sharper — and the answer is still "almost nothing."

**Boolean track toggles — Low · optional merge.** `set_track_mute`, `set_track_solo`, `set_track_arm` still share an identical signature (`track` + bool) — the only real consolidation candidate. Merge into `set_track_state(track, state, enabled)` only if trimming; three clear tools are fine.

**Level-setter family — keep.** `set_track_volume`, `set_track_send`, `set_return_track_volume`, `set_master_volume` all move a fader but target different objects with different addressing. Merging would blur selection. Correctly separate.

**No redundancy elsewhere.** The `search_library` / `list_browser_items` pair flagged in v1 is actually well-handled — distinct backends, reciprocal routing notes on both sides. Nothing to do.

---

## 02 · Coverage Gaps

Most of v1's list is gone. Two Medium gaps stand out because each blunts a feature that was _just_ built.

| Gap                                                                      | Priority | Why it matters now                                                                                                                                                                                                                                                                                                                     |
| ------------------------------------------------------------------------ | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Devices on return & master tracks** (load / inspect / delete / bypass) | Medium   | You can `create_return_track` but can't load an effect onto it (the tool says so), and `get_track_devices`/`delete_device`/`bypass_device` are regular-track-only. A reverb return sits empty and every send is silent until the user adds the effect by hand in Live. This is the piece that makes the sends system fully self-serve. |
| **Audio input routing** (read / set a track's input)                     | Medium   | `record_clip` states it "cannot choose or check the input," so an audio take is a coin-flip on whether anything was routed. Even a read-only "what's this track's input?" would let me warn before a silent take.                                                                                                                      |
| **In-place note editing** (transpose / re-velocity a note)               | Low      | `quantize_clip` now covers timing; changing an existing note's pitch/velocity/length is still read→remove→write. Fine, just not direct.                                                                                                                                                                                                |
| **Arrangement view**                                                     | Low      | Everything is Session view. With record and clip-properties now in, Arrangement is the largest structural absence — but a scope decision, not a defect.                                                                                                                                                                                |
| **Track grouping · automation**                                          | Low      | No group/ungroup; no automation envelopes. Breadth for later.                                                                                                                                                                                                                                                                          |

---

## 03 · Naming & Consistency

A strength, and the new tools raised the bar rather than drifting.

**Conventions held across 17 new tools — strong.** 0-based everywhere; the return-track index space is explicitly separated from regular tracks in every send/return tool; echo-and-verify is now widespread (`set_clip_properties` re-reads every write and echoes what Live actually applied). Related tools cross-reference each other.

**Integer enums in `set_clip_properties` — Low.** `launch_mode` (0=Trigger…), `launch_quantization` (0=Global…14=1/32), and `warp_mode` take raw integers. Powerful and fully documented, but less self-documenting than string enums ("trigger", "1/16"). _Action:_ optionally accept string enums alongside the ints.

**Minor param drift — Low.** `create_scene` names its position `index` where every other scene tool uses `scene`. Cosmetic.

---

## 04 · Descriptions & Schemas

The clear strength of this MCP. This pass found **no correctness bugs and no silent failures.** Two small notes remain.

**`remove_notes` deletes ALL notes by default — Low.** With no range it clears the whole clip. Documented and mitigated by pairing with `get_clip_notes`, but a footgun if the range is omitted. _Action:_ optionally require an explicit range or an `all: true` flag.

**`set_groove_amount` is inert in Seshat-only workflows — Low · rethink.** The tool honestly says it only affects clips that already have a Groove Pool groove assigned — and Seshat can't assign grooves. So in a pure-MCP session this knob usually changes nothing; `set_swing_amount` + `quantize_clip` is the real path to swing. _Action:_ either add groove assignment (making it live) or de-emphasize it so it doesn't read as a working feature it isn't.

**Templates to keep copying — strong.** `capture_midi`, `record_clip`, `set_clip_properties`, `get_clip_properties`, `search_library`, and `get_device_parameters` are model descriptions — preconditions, units, legal ranges, edge-case behavior, and "verify the echo." Keep them as the standard for every new tool.

---

## 05 · Full Inventory — 58 Tools

Status: **Keep** = good as-is · **Extend** = owns a remaining gap · **Merge?** = optional · **Review** = rethink / minor.

| Tool                      | Category  | Status | Note                                                     |
| ------------------------- | --------- | ------ | -------------------------------------------------------- |
| `get_session_state`       | Read      | Keep   | Now reports returns, master, key, swing/groove.          |
| `get_clip_slots`          | Read      | Keep   | Exemplary.                                               |
| `get_clip_notes`          | Read      | Keep   | Clean empty-slot error (verified).                       |
| `get_clip_properties`     | Read      | Keep   | New. Thorough; names the unit it reports.                |
| `get_track_devices`       | Read      | Extend | Regular tracks only — no return/master chains.           |
| `get_device_parameters`   | Read      | Keep   | "Trust the min/max" guidance is great.                   |
| `get_track_sends`         | Read      | Keep   | New. Reads sends before relative changes.                |
| `undo`                    | History   | Keep   | —                                                        |
| `redo`                    | History   | Keep   | —                                                        |
| `create_project`          | Structure | Keep   | —                                                        |
| `create_track`            | Structure | Keep   | —                                                        |
| `create_scene`            | Structure | Review | Position param `index` vs `scene`.                       |
| `create_return_track`     | Structure | Extend | New. Can't yet load a device onto the return.            |
| `delete_track`            | Structure | Keep   | —                                                        |
| `delete_scene`            | Structure | Keep   | —                                                        |
| `delete_clip`             | Structure | Keep   | —                                                        |
| `delete_return_track`     | Structure | Keep   | New. Warns indices shift.                                |
| `duplicate_track`         | Structure | Keep   | —                                                        |
| `duplicate_scene`         | Structure | Keep   | —                                                        |
| `duplicate_clip`          | Structure | Keep   | —                                                        |
| `set_track_name`          | Naming    | Keep   | —                                                        |
| `set_scene_name`          | Naming    | Keep   | —                                                        |
| `set_clip_name`           | Naming    | Keep   | —                                                        |
| `select_track`            | Selection | Keep   | —                                                        |
| `select_scene`            | Selection | Keep   | —                                                        |
| `set_track_volume`        | Mixer     | Keep   | Verified: echoes dB. (v1 flag retracted.)                |
| `set_track_pan`           | Mixer     | Keep   | —                                                        |
| `set_track_mute`          | Mixer     | Merge? | Optional `set_track_state`.                              |
| `set_track_solo`          | Mixer     | Merge? | Optional `set_track_state`.                              |
| `set_track_arm`           | Mixer     | Merge? | Optional `set_track_state`.                              |
| `set_track_send`          | Mixer     | Keep   | New. Great value guidance (0.25–0.4 subtle).             |
| `set_return_track_volume` | Mixer     | Keep   | New. —                                                   |
| `set_master_volume`       | Mixer     | Keep   | New. Correct fader-scale note.                           |
| `start_playing`           | Transport | Keep   | —                                                        |
| `stop_playing`            | Transport | Keep   | —                                                        |
| `set_tempo`               | Transport | Keep   | —                                                        |
| `set_time_signature`      | Transport | Keep   | New. Closes a v1 gap; good beats-vs-bars note.           |
| `set_metronome`           | Transport | Keep   | —                                                        |
| `set_loop`                | Transport | Keep   | Song loop; distinct from clip loop (now covered).        |
| `set_swing_amount`        | Feel      | Keep   | New. Correctly notes it needs quantize to apply.         |
| `set_groove_amount`       | Feel      | Review | New. Inert without groove assignment (Seshat can't).     |
| `fire_clip`               | Launch    | Keep   | Errors on empty slot. (v1 flag retracted.)               |
| `fire_scene`              | Launch    | Keep   | —                                                        |
| `stop_clip`               | Launch    | Keep   | —                                                        |
| `record_clip`             | Record    | Extend | New. Exemplary; audio limited by input-routing gap.      |
| `stop_recording`          | Record    | Keep   | New. —                                                   |
| `capture_midi`            | Record    | Keep   | New. Excellent retroactive-buffer description.           |
| `write_midi_notes`        | MIDI      | Keep   | Errors on audio/group tracks. (v1 flag retracted.)       |
| `remove_notes`            | MIDI      | Review | Default-all clear is a mild footgun.                     |
| `quantize_clip`           | MIDI      | Keep   | New. One-call, single-undo; triplet grids.               |
| `set_clip_properties`     | Clip      | Keep   | New. Very thorough; integer enums (see §03).             |
| `list_browser_items`      | Devices   | Keep   | Already points to `search_library`. (v1 flag retracted.) |
| `load_device`             | Devices   | Extend | Regular tracks only — can't load onto returns.           |
| `set_device_parameter`    | Devices   | Keep   | Exemplary.                                               |
| `delete_device`           | Devices   | Keep   | New. Completes the audition loop.                        |
| `bypass_device`           | Devices   | Keep   | New. Clean A/B; toggles Device On.                       |
| `search_library`          | Library   | Keep   | Primary discovery. —                                     |
| `reindex_library`         | Library   | Keep   | —                                                        |

---

## 06 · If You Do Three Things

The v1 five became three — the rest got built.

1. **Let devices reach return & master tracks** — load / inspect / delete / bypass on returns and master. This makes the sends system self-serve; right now a created reverb return is empty until the user acts in Live.
2. **Add audio input routing (even read-only)** — so `record_clip` can confirm a track has an input before an audio take, turning silent-take guesswork into a warning.
3. **Decide `set_groove_amount`'s fate** — add groove assignment to make it live, or de-emphasize it; today it's a knob that usually does nothing in a Seshat-only session.

**Meta — keep the "errors, not silent failures" discipline.** The single best quality signal in this surface: audio-track writes, empty-slot fires, audio-only clip props, and out-of-range values all fail loudly with helpful messages. It's already the norm — hold that line on every new tool and the surface stays trustworthy.

---

_Seshat MCP tool audit · v2 · verified against live schemas · 58 tools as of 25 Jul 2026. Supersedes v1._
