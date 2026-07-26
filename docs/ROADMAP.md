# Roadmap

The single living list of what's **not built yet**. When something here ships,
delete it from this file; if it shipped from a detailed plan doc, move that doc
to [archive/](archive/) with a status banner. [archive/](archive/) holds
point-in-time plans and decision records — never treat those as current.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address.

---

## Priority 1 — Device removal & bypass

Audit: Med-High. `load_device` + `set_device_parameter` make the device
workflow one-way — a wrong load can't be undone, and there's no A/B. Also
unlocks the catalog audition/hot-swap loop (below).

- `delete_device` — **upstream has it after all**: `/live/track/delete_device`
  is registered as a track *method* in the installed AbletonOSC
  (`abletonosc/track.py`, `methods = ["delete_device", "stop_all_clips"]`).
  Argument shape confirmed against that source and already added to
  [abletonosc-api-docs.md](abletonosc-api-docs.md) — `track_id, device_id`, no
  reply. No vendored Python needed; this is only a tool away.
- Bypass may be free: every Live device's parameter 0 is "Device On", so
  `set_device_parameter` can already A/B a device — verify, then either add a
  `bypass_device` convenience or just teach the `set_device_parameter`
  description the trick.
- Reordering the chain is out of scope until a workflow demands it.

## Catalog result quality

The catalog's job is to turn "I want a warm analog bass" into a loadable uri.
Alias folding shipped (see
[catalog-aliasing-options.md](catalog-aliasing-options.md)) and roughly doubled
the distinct presets a 25-slot search offers. These are the remaining levers,
measured against a real 8,222-row catalog and ordered by impact.

- **Ranking has almost no signal.** `score/1` is `name_score(0|2|4) +
  tag_source(0|1) + min(use_count, 3)`, and in practice the middle term is
  always 1 and the last always 0 — so a match set collapses into two score
  bands. Re-measured *after* the fold, on the folded catalog: in 5 of 6
  realistic searches **zero** slots were decided by score; all 25 came from
  the alphabetical `&1.name` tie-break among 47–86 entries tied at the top
  band. Folding halved the match sets ("electric piano" 294 → 127) but they
  are still 4–7× the 25-slot cap, so it did not dent this. The effective
  behaviour is *filter, sort alphabetically, take 25*:

  ```
  query                    score bands          slots by score / alphabetical
  electric piano           score5:70 score1:57            0 / 25
  a distorted guitar amp   score5:70 score1:117           0 / 25
  an 808 bass              score5:86 score1:10            0 / 25
  a bright synth lead      score5:49 score1:52            0 / 25
  a soft evolving pad      score5:47 score1:19            0 / 25
  plucked strings          score5:1  score1:175           1 / 24
  ```

  Available and unused: how many requested tags matched, whole-token vs
  substring hits, name vs path vs the `description` credit line, category fit.
  Make the tie-break deterministic (`uri`) while there — but the goal is to
  make ties rare, not merely stable.
- **Tags filter when they should score.** `matches_tags?` is a strict AND, so
  one tag the library doesn't have zeroes the whole search. Scoring tag
  overlap instead fixes the zero-result failure *and* supplies the signal the
  point above needs.
- **The advertised tag vocabulary is wrong.** `search_library`'s description
  lists 30 tags; `Warm`, `Wide`, `Mono` and `Hi-hat` do not exist in the
  catalog — and its own worked example, "'a warm analog bass' is query 'bass'
  + tags ['Analog', 'Warm']", returns **nothing**. (`Hi-hat` fails on the
  hyphen: the real tags are `Closed Hihat` / `Open Hihat`.) Hardcoding a fix is
  fragile since the vocabulary depends on installed Packs — better to surface
  the real one, e.g. top tags in `reindex_library`'s reply or in the
  empty-result message.
- **Coverage.** ~~`plugins` and `user_library` produced zero rows — empty
  library or broken walk?~~ _Answered 27 Jul 2026: neither walk is broken._
  `plugins` was Live configuration — plugin sources disabled in Preferences;
  enabling them added 66 tagged rows (see
  [catalog-aliasing-options.md](catalog-aliasing-options.md) for the new
  AUv2/VST3 duplicate class this exposed). `user_library` is genuinely empty —
  no saved presets exist on this machine, so the walk remains untested there.
  `samples` is excluded by design, so "a vinyl crackle" is unfindable — yet
  the category holds 3,567 items whose uris carry FileIds, so an opt-in
  samples index would be tag-aware for free.

**Suggested order.** Tag scoring and ranking are one piece of work, not two:
softening the AND is what supplies the signal the scorer needs, and doing
ranking first means inventing a tie-break for a match set that a tag score
would have separated anyway. The vocabulary fix is independent and much
smaller — a good warm-up, or a standalone if you want the zero-result failure
gone today. Coverage is a question to answer before it is work to schedule.

Not planned: embeddings or a semantic index. The LLM is already the semantic
layer and has the musical context; the failure is that truncation and
alphabetical ordering stop good candidates from reaching it.

## Capture MIDI & session record

"Keep that." The user noodles an idea on their controller and the agent grabs
it — Live remembers recent MIDI input even on un-armed tracks.

```
/live/song/capture_midi
```

- Tool: `capture_midi` — single fire-and-forget message, no Registry needed.
- Pairs with `get_clip_notes`: capture, then tighten the timing,
  harmonize, or build a variation. Turns the collaboration bidirectional —
  today the agent generates and the user listens; this lets the user play and
  the agent edit.
- **Session record** belongs here too (audit: Medium — `set_track_arm` +
  `start_playing` exist but nothing actually records, so the record loop is
  incomplete): `/live/song/set/session_record [1|0]` and
  `/live/song/trigger_session_record`, with
  `/live/song/get/session_record_status` to report state. Arrangement
  overdub / punch in-out stay out (Session view only).

## Clip properties & MIDI cleanup

Audit: Medium ×2. `set_loop` is the *song* loop — a clip's own loop brace,
length after creation, and launch quantization are unreachable; and the most
common MIDI cleanup move (quantize) currently takes a full
read → remove → rewrite by hand.

- **Per-clip properties** — loop points (`/live/clip/get|set/loop_start`,
  `loop_end`, `looping`), launch mode/quantization; warp mode and clip gain
  for audio clips. Check each address against
  [abletonosc-api-docs.md](abletonosc-api-docs.md) — naming is irregular.
- **`quantize_clip`** — **no upstream address**; the Live Object Model has
  `Clip.quantize(grid, amount)`, so this needs a vendored handler the same
  way `/live/browser/*` does. Alternative without Python: an Elixir-side
  read → snap → rewrite using the existing note tools — worse (loses
  Live-native swing handling) but zero install surface.

## Sound catalog follow-ups

Deliberately left out of catalog v1 (see
[archive/PLAN_sound_catalog.md](archive/PLAN_sound_catalog.md) for context):

- **LLM enrichment** for untagged/third-party items — needs an API key or an
  MCP-client-driven tagging turn.
- **User XMP tags** — read `User Library/Ableton Folder Info/12/`.
- **`samples` category** in the browser export (huge, rarely tag-searched).
- **Windows DB location** for `Seshat.Library.AbletonDB` (currently macOS only;
  returns `{:error, :not_found}` cleanly elsewhere).
- **Audition / hot-swap loop** — needs `delete_device`, now tracked under
  Priority 1 (device removal & bypass) above.

## Session state improvements

1. **Device list per track** — so the agent sees loaded devices without a
   `get_track_devices` round-trip.
2. **Clip grid** — `get_clip_slots` (shipped, see
   [archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) queries
   on demand; promote the grid into `Session.State` only if usage shows it
   read constantly. Clip-slot listeners are a large subscription surface
   (tracks × scenes × properties) — not worth it until then.

Query on-demand in the tools to start; promote into `Session.State` only if
read frequently.

## Idea — MCP mode in the browser UI

Give `AssistantLive` a second backend: spawn headless Claude Code (`claude -p`)
as a subprocess consuming Seshat's own `/mcp` endpoint, so the browser UI works
off a Claude subscription instead of an API key, with a per-conversation
toggle. Designed but never built — full plan (milestones, streaming UI, tested
CLI flags that may have drifted) in
[archive/PLAN_mcp_browser_ui.md](archive/PLAN_mcp_browser_ui.md).

## Smaller OSC surface

- **`set_time_signature`** — audit: Low-Med, cheap symmetry win
  (`get_session_state` reports it, `set_tempo` exists, no setter).
  `/live/song/set/signature_numerator` + `/live/song/set/signature_denominator`.
- **Modify a note in place** — audit: Low. Changing one note's velocity today
  is read → remove range → rewrite; works, a direct edit would be cleaner.
- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low value
  for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groove amount** — `/live/song/get|set/groove_amount`; pairs with "make it
  swing" now that `get_clip_notes` has landed.
- **Groups · routing/IO · automation** — audit: Low, breadth for later.
  Grouping tracks, input/output routing & monitoring, automation envelopes.
- **Return-track pan/mute/solo, master pan, cue volume** — send levels &
  return tracks (shipped) only covers levels; `priv/abletonosc/return_track.py`
  already has the return/master mixer surface open, so each of these is one
  more address in that same vendored handler.
- **Sends on return tracks** (return→return routing, feedback sends) — niche,
  needs Live's "sends only" awareness; not part of any named workflow yet.

## Deliberately not planned

- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Return/master-track device loading, device *reordering* (removal & bypass
  are now Priority 1 above), rack inner chains, parameter listeners (live
  meters/automation following) — revisit if a real workflow needs them.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
