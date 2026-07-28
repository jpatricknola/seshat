# Roadmap

The single living list of what's **not built yet**. When something here ships,
delete it from this file; if it shipped from a detailed plan doc, move that doc
to [archive/](archive/) with a status banner. [archive/](archive/) holds
point-in-time plans and decision records — never treat those as current.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address.

Sections below are grouped by *topic*, not sequenced — a section's position
in the file carries no priority. Where a section contains its own numbered
sequence (the levers under sound catalog follow-ups, say), that sequence
orders work *within* that area only.

---

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

[sound-search-options.md](sound-search-options.md) is the standing research
doc for this whole area — it ranks nine levers by measured impact on the real
dev catalog and proposes a sequence. Read it before picking any item below;
the numbered references (№1–№9) point into it.

That sequence orders *this section's* work, and only applies once you've
decided search quality is the focus. Its lever №3 — `delete_device` +
`bypass_device`, the audition loop — has shipped (see
[archive/PLAN_audition_loop.md](archive/PLAN_audition_loop.md)): search finds the
candidates, delete/bypass make swapping between them possible. It paid off
twice — it closed the one-way device workflow *and* it was the last mile of
this section's listening loop.

Left out of catalog v1 (see
[archive/PLAN_sound_catalog.md](archive/PLAN_sound_catalog.md) for context),
plus what the result-quality work found and did not close:

- **№9 eval harness that measures relevance** — do this first: it is what
  gives every item below a number instead of an opinion. Estimated a morning's
  work.
- **№2 + №1 — read Ableton's tag *axes*, and teach the vocabulary
  proactively.** The biggest certain win, and it attacks the mouth of the
  funnel (a first-attempt vocabulary miss). Ableton's own database already
  carries the axis each tag belongs to and the preset→device relation; the
  tool replies should hand the model the real menu rather than make it guess.
- **№4 widen the slate where the scorer is blind** — presentation fix for the
  tied score band; closes the "ranking headroom" item below honestly, in
  hours rather than by another pass over the scorer.
- **№8 remember what a description resolved to** — accepted-search memory,
  compounds over time.
- **№6 audition without loading (browser preview)** — the lighter cousin of
  the (now shipped) audition loop: play a preset's browser preview instead of
  loading it, so the agent can flip through ten candidates in the time one
  heavy preset takes to instantiate. Sequence it after the eval can show
  whether it's still needed once search quality improves.

- **№7 coverage: an opt-in `samples` index.** The only category still invisible
  to the catalog. Excluded by design as huge and rarely tag-searched — yet it
  holds 3,567 items whose uris carry FileIds, so indexing it would be
  tag-aware for free, and today "a vinyl crackle" is unfindable despite
  `Crackle Vinyl Pop.wav` sitting right there. Keep samples out of default
  results (only when `category: samples` is asked for) so the preset slate
  stays clean; check the walk cost — samples is why `EXPORT_CATEGORIES`
  excludes it and the 20k-node scan cap exists. (The other coverage questions
  are answered: `plugins` indexes fine once Live's plugin sources are enabled
  — 66 tagged rows, plus a new AUv2/VST3 duplicate-pair class recorded in
  [archive/catalog-aliasing-options.md](archive/catalog-aliasing-options.md) —
  and `user_library` is genuinely empty on this machine, so that walk is
  merely untested, not broken.)
- **Ranking headroom needs a new signal, not new weights.** Scoring,
  diversity and diagnosis shipped (see
  [archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md)),
  taking the six benchmark queries from 28/77 to 39/77 slots decided by
  score. The residual is genuinely undifferentiated: ~46 `E-Piano <variation>`
  presets sharing the single tag `Electric Piano`, which no weighting can
  separate — a graded per-term variant was measured at +1 slot across all six
  queries and rejected. Anything further wants data the catalog doesn't carry
  yet (LLM enrichment or XMP tags, both below), not another pass over the
  scorer — or a presentation change rather than a scoring one, which is what
  №4 above proposes.
- **№5 LLM enrichment** for untagged/third-party items — needs an API key or
  an MCP-client-driven tagging turn. Highest ceiling and highest cost; buy it
  only if the №9 eval still shows first-slate misses on thin-tagged entries.
- **User XMP tags** — read `User Library/Ableton Folder Info/12/`.
- **Windows DB location** for `Seshat.Library.AbletonDB` (currently macOS only;
  returns `{:error, :not_found}` cleanly elsewhere).

Not planned: embeddings or a semantic index. The LLM is already the semantic
layer and has the musical context.

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
  shipped — see `delete_device`/`bypass_device`), rack inner chains, parameter
  listeners (live meters/automation following) — revisit if a real workflow
  needs them.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
