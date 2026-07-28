# Roadmap

The single living list of what's **not built yet**, written as a priority-ordered
issue queue: **#1 is the biggest win, work top to bottom.** Ranking is
**impact-per-effort**: mission impact weighed against cost, so a medium-impact
quick win outranks a high-impact slog. Issue numbers are
ranks, not stable identifiers — when something ships, delete its issue and let
the rest renumber (the `/ship` skill handles this). If a shipped issue had a
detailed plan doc, move that doc to [archive/](archive/) with a status banner.
[archive/](archive/) holds point-in-time plans and decision records — never
treat those as current.

Each issue gives the goal, why it's worth building, and the context a plan
author needs — it is **not** an implementation plan. Plans get written per
issue (the `/plan` skill) when the work is picked up.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address — naming is irregular, and a wrong address fails silently.

**The play-and-keep arc (#2 · #4 · #5 · #9 · #10):** today the agent generates
and the user listens. These five issues — capture, session record, per-clip
properties, quantize, groove — make the collaboration bidirectional: the user
plays, Seshat keeps it and cleans it up. That is the largest gap between the
current state and the mission, and it is cheap: mostly upstream addresses, one
small fork commit (see #6). The quick wins interleaved among them come from the
2026-07-28 validation run
([validation-script-thoughts-and-findings.md](validation-script-thoughts-and-findings.md)).

---

## #1 · MCP server instructions — a home for session-level guidance

**Plan:** [PLAN_mcp_server_instructions.md](PLAN_mcp_server_instructions.md)

**Goal:** send server-level `instructions` from `Seshat.MCP.Server` (it
currently declares only `capabilities: [:tools]`) carrying the cross-tool
conventions no single tool description can: clear empty default tracks when
the user starts a new project; explain where a setting lives instead of
improvising when a request is outside Seshat's reach; when manual steps are
unavoidable, give the shortest complete path with keys located physically
("press the Tab key, above Caps Lock") and each step confirmed by what
appears on screen; offer choices from searches; read state before relative
changes; assume no Live UI fluency unless the user demonstrates it.

**Why:** the strongest recurring theme of the 2026-07-28 validation run —
four separate findings each needed a session-level rule and had nowhere to
put it ([validation-script-thoughts-and-findings.md](validation-script-thoughts-and-findings.md)).
In MCP mode (the primary mode) there is no Seshat-owned system prompt: tool
descriptions speak per tool, and behavior *between* tools is currently
unguided luck. An afternoon of writing that upgrades every future session —
the best impact-to-effort ratio on this list.

**Planner notes:**
- Keep it short — instructions ride along in every session's context.
- Include the don't-leak-plumbing rule: `search_library`'s facet/diagnose
  text exists to steer the model's retries, not to be relayed ("No 'Warm'
  tag exists in your library" reached the user this run). Consider also
  marking that text as model-internal in the reply itself.
- Nothing machine-specific (tag vocabulary etc.) — same rule that governs
  tool descriptions.
- API-key mode parity: `Seshat.Agent`'s system prompt should carry the same
  guidance from one shared source, not a diverging copy.

## #2 · `capture_midi` — "keep that"

**Goal:** a single tool that retroactively captures what the user just played
into a clip, via `/live/song/capture_midi`.

**Why:** Live continuously buffers recent MIDI input even on un-armed tracks.
The user noodles on a controller, stumbles into something good, and says
"keep that" — without ever having armed a track or touched the mouse. This is
the single highest-value moment in improvisation and it is ephemeral by
nature: re-played ideas lose the feel. It is also exactly the workflow where a
voice/agent interface beats a mouse, because the user's hands are on the
instrument.

**Planner notes:**
- One fire-and-forget message, no Registry sequence, no vendored Python.
- The address never replies — decide how the tool confirms success (probable
  answer: re-read clip slots / session state and report what appeared, the
  same verify-by-re-read pattern `delete_device` uses).
- Capture can also adjust the song tempo when Live infers one from the
  playing — the reply should surface that if detectable.
- Pairs with `get_clip_notes` / `write_midi_notes`: once captured, the agent
  can tighten, harmonize, or build variations. Issues #5, #9 and #10 build out
  that editing follow-through.

## #3 · Follow cam — every action visibly lands on screen

**Goal:** every mutating tool ends by steering Live's view to what it just
touched, automatically — write notes → clip selected with the note editor
open on them; load a device → that device selected; duplicate a scene → new
scene selected. Steering addresses are mostly upstream
(`/live/view/set/selected_clip|track|device|scene`); opening the note editor
needs one small vendored view address (`song.view.detail_clip` +
`Application.View.show_view("Detail/Clip")`).

**Why:** the 2026-07-28 validation run's headline finding
([validation-script-thoughts-and-findings.md](validation-script-thoughts-and-findings.md)):
after `write_midi_notes`, Session view shows only an anonymous colored slot —
the user assumed the write had *failed* until playback proved otherwise, and
when they asked "why can't I see the notes?", Seshat's only lever was a
paragraph of UI tutoring. Acting beats instructing, and automatic beats
asked-for: the change appearing on screen *is* the confirmation.

**Planner notes:**
- Put the steering in the **handlers**, not in tool-description guidance —
  deterministic, no extra round trip, works even when the model forgets.
- The view address goes into the AbletonOSC fork (#6) as an ordinary
  commit; re-run `mix abletonosc.install`.
- Make it easy to toggle off (config or tool) — auto-yanking the view can be
  wrong when the user is studying something else; default on.
- Free adjunct worth bundling: name clips at write time (`set_clip_name`
  exists) so occupied slots carry visible text — grid readouts report clip
  names too.
- The fallback register when Seshat *must* instruct (something its tools
  can't reach) is in the findings file: shortest complete path, keys located
  physically, each step confirmed by what appears on screen.

## #4 · Session record — deliberate takes into clip slots

**Goal:** tools to start/stop Session-view recording and report record state:
`/live/song/set/session_record [1|0]`, `/live/song/trigger_session_record`,
`/live/song/get/session_record_status`.

**Why:** `set_track_arm` and `start_playing` exist, but nothing actually
records — the record loop is incomplete, so those tools currently lead
nowhere. This is the deliberate-take counterpart to #2's retroactive grab:
"record me an eight-bar take on the keys track" becomes a real sentence, with
the agent as engineer (arm, count in, record, stop) while the user performs.

**Planner notes:**
- Scope is Session view only: arrangement overdub and punch in/out stay out
  (see Deliberately not planned).
- Decide the tool shape: one `session_record` tool with a state param vs.
  separate start/stop — look at how `set_metronome`/transport tools are
  shaped for consistency.
- Recording lands in the armed track's playing slot; the description must
  spell out the preconditions (armed track, slot choice) in the house style —
  see [TOOL_AUDIT.md](TOOL_AUDIT.md) §04 for the exemplary-description
  pattern.

## #5 · Per-clip properties — loop brace, length, launch settings

**Goal:** read/write a clip's own loop points and launch behavior:
`/live/clip/get|set/loop_start`, `loop_end`, `looping`, launch
mode/quantization; warp mode and clip gain for audio clips.

**Why:** `set_loop` is the *song* loop — a clip's own loop brace is
unreachable. This blocks the natural sentence right after a capture: "loop
the good two bars." Captured clips arrive with whatever length and brace Live
inferred, so #2 is only half-usable without this. It also fixes a standing
audit gap (clip length can't be changed after creation).

**Planner notes:**
- Check every address against
  [abletonosc-api-docs.md](abletonosc-api-docs.md) individually — clip
  address naming is irregular; do not infer one address from another.
- Audio-clip properties (warp, gain) only apply to audio clips — the tool
  should error cleanly on MIDI clips rather than silently no-op, matching the
  `write_midi_notes` guard precedent.
- Decide granularity: one `set_clip_properties` tool vs. per-property tools.
  The audit's finding that granular-by-object beats polymorphic merges
  ([TOOL_AUDIT.md](TOOL_AUDIT.md) §01) is the relevant prior.

## #6 · Fork AbletonOSC — own the bridge, retire the installer overrides

**Plan:** [PLAN_fork_abletonosc.md](PLAN_fork_abletonosc.md)

**Goal:** fork `ideoforms/AbletonOSC` to `jpatricknola/AbletonOSC`; fold our
wrong-object listener-unbind fix into the base class (deleting
`track_listeners.py` and the override mechanism); cherry-pick the valuable
community-PR content (#213 clip_slot log-flood fix, #208 error resilience,
#198's `quantize` method, #204's preview calls); move our three extension
handlers in as normal modules; reduce `mix abletonosc.install` to
locate-and-copy of a `priv/AbletonOSC` submodule.

**Why:** two of [fork-options.md](fork-options.md)'s triggers fired
2026-07-28 — vendoring the #213 fix would need a *second* dict-assignment
override, and #208's resilience pieces (one bad OSC message no longer aborts
the rest of the tick's queue — the shape of every Registry sequence) have no
additive seam at all. Upstream is dormant (no merges since 2025-11), so the
fork's carrying cost is ~zero. Riders: #213 stops a log flood Seshat triggers
on every clip operation *today*, and the fork lands the Python halves of #9
(quantize) and #16 (preview) for free.

## #7 · Catalog vocabulary — read tag axes, teach the menu proactively

**Goal:** read the tag *axes* (Character, Genres, Type, …) and the
preset→device relation out of Ableton's database, and surface the real
vocabulary proactively in tool replies — so the model sees the menu before
ordering, instead of guessing tags and learning only from failures.

**Why:** this is levers №1+№2 of
[sound-search-options.md](sound-search-options.md) — read that doc before
planning; it grounds every claim in measurements. The top of the search
funnel leaks first-attempt vocabulary misses ("warm" isn't a tag here, `Soft`
is), and the axes fix real traps the flat tag list creates (`Distortion` the
device tag vs. `Distorted` the character tag). Highest certain win left in
the catalog area, at Low/Low-Med effort. №2 also enables future levers, which
is why they ship together.

**Planner notes:**
- The axis lives in `files.parent_id`, which
  `Seshat.Library.AbletonDB.read_tags/1` currently discards; the
  preset→device map is the `file_devices` table (4,535 rows on the dev
  machine).
- Vocabulary is per-machine (depends on installed Packs) — it must flow
  through replies/catalog data, never be hardcoded in a tool description.
  That rule already governs `search_library`'s design.
- Requires a catalog rebuild (`reindex_library`) — fine, just say so; no
  migration shims (see CLAUDE.md).

## #8 · Catalog staleness check — reindex without being asked

**Goal:** a free freshness check — does `catalog.json` exist, and is its
build timestamp newer than the mtime of Ableton's browser database? Run it
at server startup and/or on `search_library` calls; when the catalog is
missing or stale, tell the user a reindex is needed and will take up to a
minute (Live's UI freezes), then run it.

**Why:** 2026-07-28 validation run: the script literally has the *user*
asking whether an index exists yet — backwards. The user shouldn't need to
know indexing exists. The check costs two file stats; the expensive rebuild
stays announced and cause-driven instead of manual or unprompted.

**Planner notes:**
- `catalog.json` needs a built-at timestamp if the merge writer doesn't
  already record one.
- The Ableton DB path comes from `Seshat.Library.AbletonDB` (per-machine;
  the Windows caveat is #26's problem, not this one's).
- Decide the surfacing point: a line in `search_library` replies, a startup
  check, or both.

## #9 · `quantize_clip` — the most common MIDI cleanup

**Goal:** quantize a clip's notes to a grid with an amount (0–1 for partial
quantize), via the Live Object Model's `Clip.quantize(grid, amount)`.

**Why:** "tighten the timing" is the most common cleanup move on played
MIDI — the direct follow-up to #2/#4. Today it takes a full
read → remove → rewrite by hand, which loses Live-native swing handling and
burns tool calls.

**Planner notes:**
- **The address lands with the fork (#6):** `/live/clip/quantize
  [track_id, clip_id, grid, amount]` via the clip methods list (per upstream
  PR #198). What remains here is the Elixir tool. The grid is the
  `GridQuantization` enum (0=none, 4=bar, 6=1/4, 7=1/8, 8=1/16, 9=1/32 —
  full table in [PLAN_fork_abletonosc.md](PLAN_fork_abletonosc.md)), **not**
  `RecordingQuantization` — the tool description must carry it.
- The rejected alternative (Elixir-side read → snap → rewrite with existing
  note tools) is recorded here deliberately: zero install surface but worse
  results (no Live-native swing). Don't resurrect it without new evidence.
- Partial quantize (amount < 1.0) is the musically useful form — full
  quantize kills feel. The description should teach that.

## #10 · Groove amount — "make it swing"

**Goal:** read/set the global groove amount:
`/live/song/get|set/groove_amount`.

**Why:** the third leg of played-MIDI cleanup after quantize: humanize/swing.
Small, upstream, and it completes the play-and-keep arc's editing vocabulary.

**Planner notes:** single scalar property, transport-tool shaped. Check the
value range in the API docs rather than assuming 0–1.

## #11 · `set_time_signature`

**Goal:** `/live/song/set/signature_numerator` +
`/live/song/set/signature_denominator`.

**Why:** cheap symmetry win — `get_session_state` reports the time signature
and `set_tempo` exists, but there's no setter. Anything in 3/4 or 6/8 starts
with a manual step today.

**Planner notes:** two addresses, one tool. Session state already listens to
both properties, so the echo can verify against the mirror.

## #12 · `screenshot_live` — let Seshat see the screen

**Goal:** capture Live's window (macOS `screencapture` targeted by window
ID) and return the image in the MCP tool result, so the client model —
already vision-capable — can look at the actual UI when the user asks about
it.

**Why:** 2026-07-28 validation run: "why can't I see the notes?" — OSC is
blind to presentation. The mirror knows session *state*, never what's on
screen (focused view, open dialogs, browser panes), so UI questions today
get guesses. Trigger is user UI questions, not routine post-action use —
the follow cam (#3) covers that.

**Planner notes:**
- Verify Anubis supports image content in tool results (the MCP spec does).
- Downscale before returning — full-res screenshots are token-expensive.
- One-time macOS Screen Recording permission for the BEAM process; capture
  works occluded but not minimized.
- API-key mode would need image blocks threaded through `Seshat.Agent`'s
  loop — decide whether to support it there or keep this MCP-only.

## #13 · Search eval harness — numbers before opinions

**Goal:** a repeatable harness that scores `search_library` relevance against
a fixed set of realistic "describe a sound" queries, so every further catalog
lever gets measured instead of argued.

**Why:** lever №9 of [sound-search-options.md](sound-search-options.md),
estimated at a morning's work. It exists to **gate #14–#19**: after #7 lands,
the eval decides whether any of the remaining catalog levers are still worth
buying. Sequenced after #7 because #7 is a certain win with or without
numbers.

**Planner notes:** the result-quality work already used a six-query/77-slot
benchmark informally (see
[archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md));
formalize that rather than inventing a new one. Runs offline against the
catalog — no Ableton needed.

---

**Gate: issues #14–#19 are catalog levers that wait on #13's eval.** Buy each
only if the eval still shows the miss it targets after #7 lands. They're
ranked by [sound-search-options.md](sound-search-options.md)'s
impact-per-effort ordering.

## #14 · Widen the search slate at tied score bands

**Goal:** when the score band straddling the result cut is large (the ~46
identical-tag `E-Piano *` presets), show more of the band rather than
pretending rank means something inside it.

**Why:** lever №4 — a presentation fix for ranking headroom that scoring
provably can't close (a graded per-term variant measured +1 slot across six
queries and was rejected). Hours of work, honest fix.

## #15 · Accepted-search memory

**Goal:** remember what a description resolved to — "this request led to this
accepted preset" — and let it bias future rankings.

**Why:** lever №8. `use_count`/recency already bias rankings, but the
description→preset association is thrown away today. Compounds over time; a
personal tool can afford a personal memory.

**Planner notes:** this is the one catalog feature that wants a write-side
store. Keep it out of the read-only catalog file — a separate small file
under `~/.seshat/` — and it is still not a database (see CLAUDE.md).

## #16 · Browser preview audition

**Goal:** play a preset's browser preview instead of loading it, so the agent
can flip through ten candidates in the time one heavy preset takes to
instantiate.

**Why:** lever №6 — the lighter cousin of the shipped audition loop
(`delete_device`/`bypass_device`). Metadata will never distinguish two `Soft`
pads as well as ten seconds of audio. Explicitly sequenced after the eval:
better search may make it unnecessary.

**Planner notes:** the fork (#6) lands `/live/browser/preview_item` and
`/live/browser/stop_preview`; what remains here is the Elixir tool. The
preview plays through Live's cue channel — the tool description must
surface that audibility depends on cue routing.

## #17 · Opt-in `samples` index

**Goal:** index the `samples` category (3,567 items) into the catalog,
returned **only** when `category: samples` is explicitly requested.

**Why:** lever №7, the only category still invisible — "a vinyl crackle" is
unfindable while `Crackle Vinyl Pop.wav` sits in the browser. Sample uris
carry FileIds, so tag-awareness comes free.

**Planner notes:** samples is why `EXPORT_CATEGORIES` excludes it and the
20k-node scan cap exists — measure the walk cost first. Keeping samples out
of default results is a hard requirement so the preset slate stays clean.

## #18 · LLM enrichment at reindex

**Goal:** generate tags/descriptions for untagged and third-party items at
reindex time, using an API key or an MCP-client-driven tagging turn.

**Why:** lever №5 — highest ceiling (it attacks the thin-signal problem
directly: ~200 of 5,795 entries say anything real about their sound) and
highest cost. Last resort: buy only if the #13 eval still shows first-slate
misses on thin-tagged entries after everything above. Concrete evidence from
the 2026-07-28 validation run: for "warm, slightly out-of-tune electric
piano," the character lived only in preset *names* — E-Piano Rusty, Old
School, MKII Old, Cheap were invisible to tag scoring because no warm/aged/
detuned vocabulary exists to carry them.

## #19 · User XMP tags

**Goal:** read the user's own tags from
`User Library/Ableton Folder Info/12/`.

**Why:** user-authored tags are the highest-precision signal a personal
library can have; currently ignored. Small, but only matters once the user
actually tags things — hence the low rank.

---

## #20 · Device list per track in session state

**Goal:** mirror each track's device chain in `Seshat.Session.State`, so the
agent sees loaded devices without a `get_track_devices` round-trip.

**Why:** device-chain reads are frequent (every load/delete/bypass verifies
by re-read), and the session-state mirror is push-fresh for everything else.
Quality-of-life multiplier for the now-complete device workflow — but the
gain is latency and tokens, not user-visible experience, hence the rank.

**Planner notes:** needs device add/remove listeners per track — check what
upstream offers before assuming a new handler is required. The clip-grid
precedent applies (see #23 note): query-on-demand shipped first, promotion to
push state only once usage justified the subscription surface. Usage now
plausibly does; confirm before building. These listeners are index-keyed —
the fork (#6) fixes the wrong-object unbind in the handler base class, so
any listener work here is an ordinary fork commit, no override gymnastics.

## #21 · Return/master mixer completeness

**Goal:** return-track pan/mute/solo, master pan, cue volume.

**Why:** the sends/returns work shipped levels only. The fork's
`return_track.py` handler already has the return/master surface open, so
each of these is one more address as an ordinary fork commit — low-effort
breadth whenever someone's nearby. (The 2026-07-28 PR review confirmed the
LOM details: return mute/solo are plain listenable props, master pan is
`mixer_device.panning`, cue volume is `mixer_device.cue_volume`, and the
master has no mute/solo/arm.)

## #22 · Modify a note in place

**Goal:** edit one note's velocity/length/pitch directly instead of
read → remove range → rewrite.

**Why:** the current path works but is three calls and a footgun
(`remove_notes` ranges). Cleaner, not urgent.

## #23 · Clip grid in session state — only if usage demands it

**Goal:** promote the clip grid from on-demand (`get_clip_slots`, shipped)
into push-fresh `Session.State`.

**Why (conditional):** clip-slot listeners are a large subscription surface
(tracks × scenes × properties). The standing decision
([archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) is to
wait for evidence the grid is read constantly. Revisit after #2/#4 ship —
capture and record will raise grid-read frequency. Index-keyed listeners
like #20's — post-fork (#6) these are ordinary fork commits on the fixed
base class.

## #24 · Small OSC breadth — grab bag

Individually tiny, none blocking a workflow; pick up opportunistically:

- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low
  value for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groups · routing/IO · automation** — grouping tracks, input/output
  routing & monitoring, automation envelopes.
- **Sends on return tracks** (return→return routing, feedback sends) —
  niche, needs Live's "sends only" awareness, no named workflow yet.

## #25 · MCP mode in the browser UI

**Goal:** give `AssistantLive` a second backend — headless Claude Code
(`claude -p`) as a subprocess consuming Seshat's own `/mcp` endpoint — so the
browser UI runs off a Claude subscription instead of an API key, with a
per-conversation toggle.

**Why:** removes the API-key requirement from the only mode that needs one.
Designed but never built; ranked low because MCP mode already serves the
project's one user.

**Planner notes:** full design (milestones, streaming UI, tested CLI flags
that may have drifted) in
[archive/PLAN_mcp_browser_ui.md](archive/PLAN_mcp_browser_ui.md) — verify the
CLI flags against current Claude Code before trusting it.

## #26 · Windows DB location for `Seshat.Library.AbletonDB`

**Goal:** find Ableton's browser database on Windows (currently macOS only;
returns `{:error, :not_found}` cleanly elsewhere).

**Why:** portability groundwork; zero value until a Windows user exists.

---

## Deliberately not planned

- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Return/master-track device loading, device *reordering* (removal & bypass
  shipped — see `delete_device`/`bypass_device`), rack inner chains, parameter
  listeners (live meters/automation following) — revisit if a real workflow
  needs them.
- Embeddings or a semantic index for the catalog — the LLM is already the
  semantic layer and has the musical context.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
