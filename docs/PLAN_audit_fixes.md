# Plan — Tool audit fixes

Follow-ups from [../TOOL_AUDIT.md](../TOOL_AUDIT.md) (25 Jul 2026). Scope:
the correctness and description fixes on **existing** tools — the two silent
failures, the misleading volume scale, and a small description-consistency
pass. **No new tools here**: every coverage gap the audit found (sends,
device removal, record/capture, per-clip properties, quantize, time
signature, …) is prioritised on [ROADMAP.md](ROADMAP.md) instead.

Explicitly **not** doing (audit calls them optional, declining on purpose):

- `set_track_state` merge of mute/solo/arm — three tiny clear tools beat one
  polymorphic one; nothing is hurting.
- `remove_notes` requiring a range / `all: true` — default-all is documented,
  mitigated by the `get_clip_notes` pairing, and changing required params
  breaks existing callers for a Low-severity footgun.
- `create_scene` param rename `index` → `scene` — breaking schema change for
  cosmetic consistency.
- `search_library` ⟷ `list_browser_items` reciprocal note — **already done**:
  the current `list_browser_items` description carries the "TRY search_library
  FIRST … use this for raw samples / empty catalog" routing note the audit
  asked for. Verify wording, no code change expected.

## OSC contract

Addresses verified against [abletonosc-api-docs.md](abletonosc-api-docs.md).
Both are already used by `Handlers` (`track_data` properties, `ensure_clip/2`).

| Address | Request args | Reply |
|---|---|---|
| `/live/track/get/has_midi_input` | `[track_id]` | `[track_id, has_midi_input]` |
| `/live/clip_slot/get/has_clip` | `[track_id, clip_index]` | `[track_id, clip_index, has_clip]` |

No new addresses. Parts 3–4 are Elixir-side only.

---

## Part 1 — `write_midi_notes` errors on audio tracks (High)

The audit's #1: the description itself admits "this tool fails silently on
audio tracks" — the one failure mode that makes the agent report a phantom
success.

1. In `lib/seshat/tools/handlers.ex`, add an `ensure_midi_track/1` private
   helper alongside `ensure_clip/2` / `ensure_midi_clip/2`: query
   `/live/track/get/has_midi_input [track]`; `:ok` when truthy, else an
   instructive error in the house error style, e.g.
   *"Track N is an audio track — MIDI notes can only be written to MIDI
   tracks. Check track types with get_clip_slots or get_session_state."*
2. In the `write_midi_notes` clause, run `ensure_midi_track(track)` before
   building the `%Command{}`; only call `Registry.execute/1` on `:ok`.
3. Update the tool description in `definitions.ex`: replace "this tool fails
   silently on audio tracks" with the new behavior ("errors if the track is
   an audio track"), keeping the "use get_clip_slots first to pick an empty
   slot on a MIDI track" advice.
4. Update [validation-script.md](validation-script.md) (~line 461): the
   deliberate-misuse step currently expects the *agent* to notice the silent
   failure; after this the *tool* errors — reword the expected outcome.

Cost: one extra round-trip per write (~ms, same pattern as
`get_clip_notes`'s `ensure_clip`). Worth it — this is the tool's only guard.

## Part 2 — `fire_clip` guards the empty slot (Medium)

Firing an empty slot silently *stops the track* — a milder cousin of Part 1.
The plumbing already exists.

1. Reuse `ensure_clip/2` in the `fire_clip` clause before sending
   `/live/clip/fire`. Its current error text is read-flavored ("there is
   nothing to read") — make the message action-neutral so it serves both
   callers, and have `fire_clip` append the intent hint: *"firing an empty
   slot silently stops the track — if you meant to stop it, use stop_clip."*
2. Update `fire_clip`'s description: the "firing an empty slot just stops the
   track" warning becomes "empty slots are rejected with an error; use
   stop_clip to stop a track".
3. `stop_clip` keeps its current behavior — stopping is always safe.

## Part 3 — Honest volume scale + display-value echoes (Medium)

Two audit items merged, both about the mixer setters lagging the
echo-and-verify standard set by `set_device_parameter` / `load_device`.

1. **Fix the `set_track_volume` description** (correctness): Ableton's 0–1
   mixer scale is not linear and 1.0 is not "full" — ~0.85 ≈ 0 dB (unity),
   1.0 ≈ +6 dB. Rewrite the value guidance: *"0.0 = silence, 0.85 = unity
   gain (0 dB, the default), 1.0 = +6 dB (maximum boost)"*, and fix the
   common mappings ('full' = 0.85 unity, not 1.0). The canonical docs' own
   example uses `0.85`.
2. **Echo approximate dB** from the handler. Add a pure
   `volume_display/1` helper: Live's fader is close to linear-in-dB across
   its useful top (`dB ≈ 40 × value − 34`; 0.85 → 0 dB, 1.0 → +6 dB,
   0.4 → −18 dB) and dives toward −inf below that. Echo
   `"Set volume on track 0 to 0.85 (≈ 0 dB)"`; `0.0` → "silence";
   below 0.4 → "below −18 dB". Label as approximate — there is no OSC
   `value_string` for the mixer, so this is computed, not read back.
3. **Echo pan as Live displays it.** Pure `pan_display/1` helper mapping
   −1.0…1.0 to Live's `50L / C / 50R`:
   `"Set pan on track 0 to -0.5 (25L)"`.
4. Mute/solo/arm already echo human-readable results ("Muted track 0") —
   no change.

Both helpers are pure → unit-test them directly (see Verification).

## Part 4 — Description consistency pass (Low)

Small drifts the audit flagged in §03. `definitions.ex` only; no behavior.

1. **"Slot N = scene N"** — the equivalence is currently explained only in
   `get_clip_slots`. Restate it in one short clause ("clip slot N sits in
   scene N") in each clip-slot tool where it's missing: `fire_clip`,
   `stop_clip`, `delete_clip`, `duplicate_clip`, `set_clip_name`,
   `write_midi_notes`, `get_clip_notes`, `remove_notes`.
2. **1-based user speech** — the "refer to tracks by name or 1-based UI
   number when talking to the user" guidance appears only in
   `get_session_state`; echo it in the other read tools (`get_clip_slots`,
   `get_clip_notes`, `get_track_devices`, `get_device_parameters`).

Keep the exemplary four (`write_midi_notes`, `search_library`,
`get_clip_slots`, `get_device_parameters`) as the style template — additive
edits only.

## Part 5 — Update the audit doc

TOOL_AUDIT.md is a living doc. After Parts 1–4: flip `write_midi_notes`,
`fire_clip`, `set_track_volume` to **Keep** in the §05 inventory (with a
one-word note, e.g. "Fixed 07/2026"), and update the "At a glance" counts.
Strike the §01 `search_library` routing item as already-present. Leave §02
(coverage gaps) pointing at ROADMAP.md.

---

## Verification

- `mix precommit` — tool count is unchanged (41), so `definitions_test.exs`
  needs no bump; MCP parity tests regenerate from `Definitions`.
- Unit tests for the new pure helpers (`volume_display/1`, `pan_display/1`)
  — boundary values 0.0 / 0.4 / 0.85 / 1.0 and −1.0 / 0.0 / 1.0.
- `ensure_midi_track/1` and the `fire_clip` guard reach `Transport.query/3`
  → **not** unit-testable per the testing rules. Cover via `/smoke-test`:
  - `write_midi_notes` against an audio track → explicit error naming the
    track and its type.
  - `fire_clip` on an empty slot → explicit error; the track keeps playing.
  - `set_track_volume 0.85` → echo contains "0 dB"; pan −0.5 → "25L".
