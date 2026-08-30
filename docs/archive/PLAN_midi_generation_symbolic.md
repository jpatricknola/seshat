# Plan — MIDI generation: the first solution, composed symbolically

> **Archived 2026-08-30 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ (see the PR for the
> implementer's per-item report, the review's verdict and nits, and the
> assumptions carried through the run). The feature lives in
> `lib/seshat/generation/midi/` (`pattern.ex`, `performance.ex`, `bass.ex`,
> `profiles.ex`), `lib/seshat/generation/midi_parts.ex`, and the
> `generate_midi` tool in `Seshat.Tools.Definitions`/`Handlers`; the harvested
> style data lives in `priv/midi_generation/style_profiles.json`
> (`experiments/gmd_profiles/harvest.py` is how it was produced). The
> roadmap's "MIDI generation — the first solution, composed symbolically"
> entry is removed. Two PR-review nits were applied directly (a wording fix
> for a track wrongly called silent, and a doc note on `edit_notes`
> `parts`/`validate/1` bounds); the velocity-class clamp's own quality finding
> became its own roadmap entry, "Soften the velocity-class clamp in symbolic
> MIDI generation"; the partial-failure-wording gap was folded into the
> existing "Pin the wording of `edit_notes`' partial-failure message" item;
> and the routing-eval corpus gap was folded into the existing "Routing evals
> — general corpus and client-realism lane" item as a planner note. Live
> verification is partial: five automated `docs/smoke_tests/auto/` checks ran
> and passed against real Ableton Live 12.4.5 (see "Live verification"
> below for the measurements); the four manual checks this plan cites —
> `manual/by-ear.md`'s acceptance slate, `manual/on-screen.md`'s Chance-lane
> check, `manual/conversation.md`'s routing check, and
> `manual/engineered-state.md`'s groove-from-pool check — still read
> `*Last run: —*` and need a person.

Roadmap item **"MIDI generation — the first solution, composed symbolically"**
(re-scoped twice on 2026-08-30; this plan is written against the second
re-scope). One feature, no bake-off: a **pattern DSL that Claude writes,
compiled to notes by pure Elixir, with a performance layer authored into the
notes themselves**, landing as separate per-part MIDI tracks in one call and
one undo step, written through the fork's `/live/clip/add/notes_extended` so
probability and velocity deviation carry. Style numbers come from profiles
harvested **offline** from the Groove MIDI Dataset (CC-BY-4.0, attribution
committed); bass is the bounded rule engine. No runtime retrieval, no neural
model, no new native-process door.

The deciding evidence is in
[symbolic-midi-first-solution.md](../evaluating/generative%20features/symbolic-midi-first-solution.md)
(verdict and the three 2026-08-30 measurements),
[symbolic-midi-strategy-options.md](../evaluating/generative%20features/symbolic-midi-strategy-options.md)
(the shared seam and judging protocol), and
[music-generation-user-stories.md](../evaluating/generative%20features/music-generation-user-stories.md)
(the acceptance bar). The superseded four-arm plan
([PLAN_midi_generation_decision_experiment.md](../PLAN_midi_generation_decision_experiment.md))
contributes its measured facts — the 6.45 s in-process cost of a four-part
request, the ~35 s conversational-chain equivalent, the datagram arithmetic —
and its fixed-slate/blind-judging protocol, which becomes this feature's
acceptance test rather than a pre-feature experiment.

## Context

Claude composing raw notes failed on feel (2026-08-25): uniform velocities,
grid-locked timing. The failure is an abstraction failure, not a knowledge
failure — the model knows what a lazy backbeat is but cannot express it one
note-map at a time. This feature gives the model the right abstraction (a
compact step-pattern language plus named style/feel controls) and moves the
feel into deterministic Seshat code:

- **Composition** stays with Claude: it writes per-part step patterns
  (`X x g -`), picks roots and a bass relationship, chooses a style profile.
  The LLM-does-the-resolving convention holds — the tool is dumb and
  mechanical, and the "grammar" is mostly schema.
- **Performance** is Seshat's: a pure pass that applies harvested microtiming
  (GMD averages 6.7–14.8 % of a 16th, max ≈ 48 %), velocity contours
  (σ ≈ 28–33, ghosts down to velocity 5), swing, accent shape, and Live's own
  per-note `probability` / `velocity_deviation` — the fields the
  `notes_extended` family exists for. Live's Groove Pool cannot be stocked
  from code (tier-1 measured), so feel must live in the notes; an assigned
  Live groove is offered only as a garnish on whatever the user's pool
  already holds.
- **Placement** is one handler-owned workflow: guards → compile → create
  tracks → load instruments → write clips → read back, inside the existing
  per-call undo bracket, so "one request is one undo step" holds by
  construction and the ~35 s conversational chain collapses to one call
  (~5–8 s in-process for four parts, by the 2026-08-28 measurements).

Two Live-side riders the roadmap names are folded in because they are small
and this feature is their consumer: **clip groove assignment** (fork
addresses exist, no tool) as the garnish above, and **reading the selected
scene** (upstream address, no tool) so "this section" is resolvable — it
lands as one more line in `get_view_state`, not a new tool.

Melody and harmony have no symbolic candidate and stay out. Composer's
Assistant 2 and AMT stay unbuilt specialists, gated on hearing this ship.

## OSC contract

Every address verified against [priv/AbletonOSC/API.md](../../priv/AbletonOSC/API.md)
at pin `3b6b9bc`. No fork change is needed: the extended-notes family and the
Groove API are already registered and documented; `lib/` has simply never
used them. **The installed Remote Scripts copy must be at or past the pin
before live verification** — `add/notes_extended` against an older copy fails
silently (unknown address, UDP, no reply).

| Address | Args out | Reply | Use here |
|---|---|---|---|
| `/live/clip/add/notes_extended` | `track, clip, <8 fields per note>…` — `pitch`(i), `start_time, duration, velocity, probability, velocity_deviation, release_velocity`(f), `mute`(0/1), in canonical order `pitch, start_time, duration, velocity, mute, probability, velocity_deviation, release_velocity` | **none, ever** | the note write; repeated adds append |
| `/live/clip/get/notes_extended` | `track, clip[, start_pitch, pitch_span, start_time, time_span]` — range args all-or-nothing (0 or 4); no range = whole clip (`0, 127, -8192, 16384`); the time window matches notes by their *start* | `track, clip, <9 fields per note>…` (`note_id` last; `mute` returns as OSC bool) | post-write read-back, **windowed by time range** (see the reply-ceiling bullet below); echoes both indices for correlation — but *not* the range args, so consecutive windows on one clip correlate identically and need the content check in Part 5 step 6 |
| `/live/clip_slot/get/has_clip` | `track, slot` | `track, slot, has_clip` | slot-empty guard (echo-checked) |
| `/live/clip_slot/create_clip` | `track, slot, length` (beats, float) | none | per-part clip creation |
| `/live/clip/set/name` | `track, clip, name` | none | clip named by part role (fire-and-forget) |
| `/live/song/get/num_scenes` | — | `num_scenes` | slot-exists guard, both branches (new and existing tracks) |
| `/live/song/get/num_tracks` | — | `count` | Registry `:create_track` count-verified create (existing code) |
| `/live/song/create_midi_track` | `index` (-1 append) | none | via Registry `:create_track` (existing code) |
| `/live/track/set/name` | `track, name` | none | via Registry (existing code) |
| `/live/track/get/has_midi_input` | `track` | `track, flag` | existing-track type guard (existing `ensure_midi_track` shape) |
| `/live/track/get/is_foldable` | `track` | `track, flag` | group-track refusal (existing shape) |
| `/live/browser/load_item` | `track, uri` | `track, uri, status[, detail…]` (fork's widened reply) | optional per-part instrument load, 30 s budget (existing `load_device` mechanics) |
| `/live/song/get/groove_pool` | — | five fields per groove, **no count prefix**; empty pool = zero args (an answer, not an error) | pool names for the mirror / plain empty-pool refusal |
| `/live/song/start_listen/groove_pool` | — | pushes the full dump on **membership** change only | mirror listener |
| `/live/clip/set/groove` | `track, clip, groove_index` (**≥ 0**; `-1` is a rejection, not a clear — assignment is one-way) | none | garnish setter |
| `/live/clip/get/groove` | `track, clip` | `track, clip, groove_index` (`-1` when `has_groove` false) | garnish read-back |
| `/live/view/get/selected_scene` | — | `scene_index` | `get_view_state` line |

Measured facts this plan rests on (do not re-derive):

- **Eight-field writes are accepted and land** — measured 2026-08-30 against
  Live 12.4.5 with `probability 0.5`, `velocity_deviation 15.0`; read back
  through `get_clip_notes`. ⚠️ Whether the three expression fields *persist
  with their sent values* is still unmeasured (`API.md`'s ⚠️) — read-back
  went through the five-field getter. See Open questions.
- **Datagram arithmetic, measured 2026-08-30 via `Seshat.OSC.Message.encode/2`:**
  an `add/notes_extended` datagram is **44 bytes + 40 per note** (n=1 → 84,
  n=200 → 8,044, n=229 → 9,204, n=230 → 9,244). Against this Mac's
  `net.inet.udp.maxdgram` of 9,216 the hard ceiling is **229 notes**; the
  workflow chunks at **200 notes per datagram** (8,044 bytes), and repeated
  adds append, so a dense lane (16 bars at 1/32 = 512 steps) is three
  datagrams, not a drop. This supersedes the five-field 367-note figure for
  this path and means the separate "`write_midi_notes` must chunk" roadmap
  defect is *not* a gate here (that tool keeps its own item).
- **The reply direction is bounded by the same ceiling** (plan-review
  derivation, 2026-08-30, from the same encoding arithmetic): a
  `get/notes_extended` reply carries 9 fields per note — the 8 sent plus
  `note_id`, with `mute` as a payload-free OSC bool — ≈ 41 bytes/note plus
  ~44 of header, and AbletonOSC's Python sends it as **one datagram** under
  the same `maxdgram` 9,216 sysctl (neither side raises `SO_SNDBUF`). One
  reply therefore caps at roughly **220 notes**; a whole-clip read of the
  dense lane the write chunker exists for (512 notes, or the 256-note
  16-bar 1/16 hat lane in the smoke test) produces a reply that can never
  arrive — the read-back would time out and report "unconfirmed" for
  exactly the clips most worth confirming. **The read-back must window**
  (Part 5 step 6); this is a derived bound, so the first live run should
  note where the real ceiling sits if it differs.
- **Groove Pool cannot be stocked from code** (tier 1, 2026-08-30): no
  add/create/import member, no browser grooves root. An empty pool must be
  told plainly, with "drag one in from Live's browser" as the only remedy.
- **GMD coverage** (whole dataset, 2026-08-30): 424 beat files ≥ 4 bars;
  rock 151, latin 51, funk 50, jazz 44, hiphop 30, dance 7; **no lo-fi,
  trap, house, techno or D&B label**. Harvested profiles cover what exists;
  the missing styles get *authored* profiles derived from neighbours and are
  documented as authored, never claimed as harvested.

## Numbered parts

### 1. Style profiles — harvested offline, committed as data

**Files:** `experiments/gmd_profiles/harvest.py` (new, dev-only, never run at
runtime), `priv/midi_generation/style_profiles.json` (new, committed),
`priv/midi_generation/ATTRIBUTION.md` (new).

`harvest.py` downloads `groove-v1.0.0-midionly.zip` (3.26 MB; the URL and a
SHA-256 recorded in the script), filters `beat` files ≥ 4 bars via
`info.csv`, maps Roland TD-11 pitches to lane classes (kick / snare /
closed-hat / open-hat / toms / ride / crash — the mapping is documented
upstream in GMD's own docs), and emits per-style statistics keyed by lane
class:

- timing: mean signed offset and σ from the nearest 16th, as a *fraction of
  a 16th* (tempo-independent), per lane;
- swing: median offset of off-8th onsets;
- velocity: mean and σ per accent class (accented / ordinary / ghost, split
  by per-file velocity terciles), ghost fraction per lane;
- density guardrails (hits per bar per lane, p10–p90) — carried for the
  reply's honesty, not enforcement.

Harvested styles: `rock`, `funk`, `jazz`, `latin`, `hiphop`, `dance`.
Authored styles (in the same JSON, each with `"authored_from"` naming its
donor and the delta applied): `lofi` (hiphop + more drag and jitter, lower
ghost probability), `boom_bap` (hiphop, tighter), `house` and `techno`
(dance, tighter still, straight 16ths), `trap` (dance timing, half-time
accent contour). The JSON's header object carries the CC-BY-4.0 attribution
line and the dataset citation; `ATTRIBUTION.md` carries the full notice.
GMD itself is **not** committed and **not** read at request time.

A pure test pins every committed profile inside the measured envelope
(mean timing offset within 0–20 % of a 16th, velocity σ within 10–45, ghost
velocities ≥ 1) so a bad re-harvest cannot ship unnoticed, and pins that
every `style` enum value in `Definitions` has a profile and vice versa.

### 2. The pattern compiler — `Seshat.Generation.Midi.Pattern` (pure)

**File:** `lib/seshat/generation/midi/pattern.ex` (new).

Input: a pattern string, a resolution, `bars`, the time signature. Grammar,
deliberately minimal (v1 authors variation by writing bars out; no named
operators — Claude can compute a Euclidean pattern itself):

- one character per step: `X` accent, `x` hit, `g` ghost, `-` rest;
- `|` is an ignored bar separator, whitespace ignored;
- resolutions `1/8`, `1/8T`, `1/16`, `1/16T`, `1/32` (steps per beat 2, 3,
  4, 6, 8);
- a pattern shorter than `bars × steps_per_bar` **repeats whole** to fill
  (must divide evenly, else a refusal naming the lengths); longer is a
  refusal.

Output: `{:ok, [%{step_beats, accent: :accent | :hit | :ghost}]}` on the
exact grid, or `{:error, message}` naming the offending character and
position. No OSC, no randomness.

### 3. The performance layer — `Seshat.Generation.Midi.Performance` (pure, seeded)

**File:** `lib/seshat/generation/midi/performance.ex` (new).

Input: gridded notes + lane class + profile + `humanize` (0–1) + optional
`swing` override + seed. Output: full eight-field notes. Deterministic: the
RNG is `:rand.seed_s(:exsss, {seed, part_index, 0})` threaded functionally,
so same request + same seed = byte-identical notes, and omitting `seed`
draws one and **reports it** in the reply (story 7's explicit variation
mechanism).

Per note:

- **start** = grid + swing displacement (off-8ths/off-16ths per profile) +
  lane push/drag mean + Gaussian jitter (σ from profile), all × `humanize`,
  clamped to `[0.0, clip_end)` and never re-ordered past a neighbour;
- **velocity** = accent-class mean (accent high, ghost low) shaped by a
  contour (downbeat/backbeat emphasis per lane class) + jitter × `humanize`,
  clamped 1–127;
- **probability** = 1.0 for accents and ordinary hits, profile's ghost
  probability (< 1.0) for ghosts — Live re-rolls feel on every pass;
- **velocity_deviation** = profile per lane × `humanize`;
- **release_velocity** = 64.0; **duration** = step length × 0.9 for drums
  (bass durations come from Part 4); **mute** = 0.

`humanize: 0.0` must emit the raw grid exactly — that is the A/B arm the
acceptance slate needs.

### 4. The bass rules — `Seshat.Generation.Midi.Bass` (pure)

**File:** `lib/seshat/generation/midi/bass.ex` (new). The bounded §E.1
engine, verbatim where the archived plan specified it:

Input: the *compiled* onsets of one drum part (the actual kick, so
conditioned wiring is native, not a mode), `roots` (one MIDI pitch per bar,
**28–43** = E1–G2, validated), and `relationship`:

- `lock` — an onset on every followed-part onset, rests elsewhere;
- `answer` — an onset on the 8th after each followed onset not itself
  followed by another within a beat;
- `sustain` — hold the root from the bar's first followed onset to its last.

Durations and velocities come from a bass phrase rule (bar-1 downbeat
accented, decay across the bar, the last 16th before a followed onset ghosted
at ~45) — **never** copied from the drum velocities. A bass part may instead
carry an explicit `pattern` (compiled by Part 2, pitched by `roots` per bar)
— that is the *independent* wiring, kept so the independent-vs-conditioned
comparison stays one factor. Key/scale fit is the model's job (it read
`get_session_state`); the tool validates register and shape only.

### 5. The workflow — `Seshat.Generation.MidiParts`

**File:** `lib/seshat/generation/midi_parts.ex` (new), modeled on
`Seshat.Generation.AudioClip`'s ordering discipline (guards before side
effects, honest partial reporting, read-back before claiming success).
`Handlers` dispatches to it and formats nothing musical itself.

Order, for a request of N parts:

1. **Validate everything pure first**: cross-field part rules (drum needs
   `pattern` + `pitch`; bass needs `roots` sized to `bars` and exactly one of
   `pattern` / `relationship`; `follows` must name a drum part in this
   request, defaulting to the lowest-pitched drum part; duplicate roles
   refused), then compile and perform **every** part. Any failure refuses the
   whole request before any OSC.
2. **Guards** (all before any mutation): `num_scenes` covers `clip_slot` on
   *both* branches (new and existing tracks — the `generate_audio` review
   lesson); every explicit `track` is a MIDI, non-group track
   (`has_midi_input` / `is_foldable`, echo-checked) and its target slot is
   empty (`has_clip`, echo-checked). An occupied slot names the slot and
   states nothing was created; a missing scene points at `create_scene`.
3. **Create tracks** for parts without `track`, via Registry
   `%Command{command: :create_track, track_type: :midi, name: role}` —
   count-verified, appended, index captured.
4. **Load instruments** where `instrument_uri` was given, through the same
   `/live/browser/load_item` mechanics and 30 s budget as `load_device`
   (extract the regular-track load into a shared private helper rather than
   duplicating it; `Catalog.record_load/1` still fires). A failed load does
   **not** abort the part — the notes still land and the reply names the
   silent track.
5. **Write clips**: per part, `create_clip` (length = bars × beats per bar)
   then `add/notes_extended` in chunks of ≤ 200 notes, then `set/name` with
   the role.
6. **Read back** each clip through `get/notes_extended`, **windowed by time
   range** so no expected reply exceeds ~200 notes (the reply direction
   shares the 9,216-byte ceiling — see the OSC contract's reply-ceiling
   bullet): partition the clip's time axis into windows sized from the
   *written* notes (the workflow knows every start it sent), choosing window
   edges strictly between consecutive distinct note starts — never on one —
   so the getter's match-by-start semantics can neither drop nor double-count
   a boundary note; a clip whose expected count fits one reply reads whole.
   Correlate on the echoed track/clip pair with the reissue-once stale
   defence (the `query_correlated/4` family) — and because the range args
   are **not** echoed, two windows on one clip correlate identically, so
   each window's returned starts are also checked against that window's
   expected set, a mismatch treated as stale and reissued once. Compare note
   count and, per field, whether `probability` / `velocity_deviation` came
   back as sent or as defaults. The reply reports the comparison honestly —
   "sent and confirmed" vs. "sent; Live returned defaults, so per-note
   chance did not stick" — which is what closes `API.md`'s ⚠️ with a
   measurement instead of hope.
7. **FollowCam** steers to the last part's clip (a `calls/2` decision for
   `"generate_midi"` in `lib/seshat/tools/follow_cam.ex`, same shape as
   `write_midi_notes`).
8. **Reply**: names every part → track index/name → slot, says the result is
   MIDI, reports the style, the seed actually used, note counts, the
   read-back verdict, any silent tracks, and that **one `undo` removes the
   whole request**. Partial failure (e.g. two tracks created, then a write
   failed) follows `AudioClip`'s honesty pattern: say exactly what exists,
   what was not confirmed, and that one `undo` removes what was created —
   never "done".

The whole `do_call` runs inside the existing per-call undo bracket; nothing
new is needed for one-undo-step, and `generate_midi` is **not** in
`unstepped_names/0`.

CLAUDE.md's module map gains a row for each new module (`Pattern`,
`Performance`, `Bass`, `MidiParts`; the profiles JSON is data, not a
module), in the same commit that adds them — the map lists every
`lib/seshat/generation/` module today and a missing row is what the
plan-review sweep exists to catch.

### 6. The tool — `generate_midi` (Definitions → Handlers → count 54 → 55)

**Files:** `lib/seshat/tools/definitions.ex`,
`lib/seshat/tools/handlers.ex`, `lib/seshat/tools/follow_cam.ex`,
`test/seshat/tools/definitions_test.exs` (54 → 55). The MCP component is
generated; `Seshat.Tools.Validation` covers the schema by construction.

A new name is justified against `.claude/docs/adding-a-tool.md`'s routing
test: this is rule 3 — one producer action ("make me a beat") composed of
many primitives — and neither near-neighbour fits: `write_midi_notes` is the
mechanical single-clip note writer with no parts, feel, tracks or
instruments; `generate_audio`'s schema (text prompt → rendered file import)
shares no targeting or content shape, past the cohesion limit for a `form`
enum on one tool. Near-neighbour names to watch in routing:
`generate_audio`, `write_midi_notes`, `capture_midi`, `edit_notes`. The gate
numbers (serialized `tools/list` bytes, largest schema) are recorded at
implementation time with `mcp_call.py stats`; the fresh-conversation
selection check is the rewritten
`manual/conversation.md § A generation request routes to one call and names
the form`.

**Recorded at review round 2** (not at implementation time as planned — the
first pass shipped without running this): 55 tools, 72,239 serialized bytes,
largest schema `generate_midi` at 5,446 bytes (was 52 tools / 58,709 bytes /
`set_clip_properties` at 3,585 before this feature). Computed directly from
`Seshat.Tools.Definitions.all/0` and `Seshat.MCP.Schema.to_json_schema/1`
rather than `mcp_call.py stats` — no Seshat MCP server was running against
this checkout — and cross-checked against the pr-review round that measured
the same numbers independently.

Schema draft (bounds are the contract — a silent no-op is not detectable on
this wire):

```
generate_midi
  description  string, optional — the musical brief, echoed in the reply
  bars         integer 1–16, default 4
  clip_slot    integer ≥ 0, default 0 — Session scene; must be empty on every target track
  style        enum: rock funk jazz latin hiphop dance lofi boom_bap house techno trap
  humanize     number 0–1, default 1.0 (0 = raw grid, for A/B listening)
  swing        number 0–1, optional — overrides the profile's swing
  seed         integer ≥ 0, optional — same seed, same take; reply names the seed used
  parts        array 1–8 of:
    role            string 1–32 chars — track and clip name ("Kick", "Bass")
    type            enum drum | bass, default drum
    pitch           integer 0–127 — drum parts only; GM defaults in the description
    pattern         string ≤ 1600 chars — steps X x g -, | and space ignored
    resolution      enum 1/8 1/8T 1/16 1/16T 1/32, default 1/16
    roots           array of integers 28–43 — bass only, one per bar
    relationship    enum lock | answer | sustain — bass without pattern
    follows         string, optional — role of the drum part a relationship derives from
    track           integer ≥ 0, optional — write onto this existing MIDI track
    instrument_uri  string, optional — browser URI from search_library
```

Description draft (prompt text for a model that can't see the code):

> Compose MIDI — drums and bass — from step patterns you write, landing as
> separate parts, one track and clip each, in one Session scene, one call,
> one undo step. MIDI is the default form for musical material; only an
> explicit audio request goes to generate_audio. Patterns: one character per
> step — X accent, x hit, g ghost, - rest ("x-g-X-g-…"); | and spaces are
> ignored; resolution defaults to 1/16; a shorter pattern repeats to fill
> the bars. Drum parts play one pitch (GM: kick 36, snare 38, closed hat 42,
> open hat 46 — match the loaded kit). Bass parts take one root per bar
> (MIDI 28–43) plus either a pattern or a relationship derived from the
> actual drum onsets: lock (with each kick), answer (the 8th after), sustain
> (hold the bar). Style + humanize add real-drummer microtiming, velocity
> shape, ghost dynamics and per-note chance; same seed = same take, so for
> "another take" change or omit the seed and target the next empty scene —
> never an occupied slot, which is refused. New tracks are created per part
> unless track names an existing MIDI track. Pass instrument_uri per part
> (from search_library) so the result makes sound; without it the track is
> silent and the reply says so. Read get_session_state first for tempo, time
> signature and key. Track indices are 0-based.

`generate_audio`'s description gains one sentence routing unadorned musical
material to `generate_midi` (MIDI is the default form). No
`Seshat.Instructions` change — the 2,048-char budget stays untouched;
everything above rides in schemas.

Because `Definitions` changes (a new tool and an edited description),
**`mix routing.eval` must run on this branch** and its `report.md` attach to
the PR. The same call was made and skipped on the three prior generation
PRs; CLAUDE.md names it outstanding each time. Not optional here: the new
tool sits between two near-neighbours (`generate_audio`,
`write_midi_notes`) and the MIDI-default flip inverts the expected routing
of an existing conversation check.

### 7. The groove garnish — assignment, read-back, and pool visibility

**Files:** `lib/seshat/tools/definitions.ex` (two property additions),
`lib/seshat/tools/handlers.ex`, `lib/seshat/session/state.ex`.

- `set_clip_properties` gains `groove` (integer ≥ 0, pool index). The
  handler refuses **before sending** when the mirrored pool is empty —
  "the Groove Pool is empty; grooves can only be added by dragging one in
  from Live's browser" — because that is a Live ceiling, not a bad index.
  Otherwise it sends `set/groove` and confirms through `get/groove`
  (fire-and-forget setter, so the read-back is the reply's evidence); an
  out-of-range index surfaces Live's own structured error naming the pool's
  real size. The description states one-way assignment: clearing needs
  Live's clip Groove chooser.
- `get_clip_properties` reports the assigned groove (index and, via the
  mirror, its name) or "no groove".
- `Seshat.Session.State` mirrors the pool's **names** (`groove_pool`,
  subscribed via `/live/song/start_listen/groove_pool`, initial read at
  refresh; membership pushes only, which is exactly what a name list needs).
  `get_session_state`'s song line renders "Groove Pool: Swing 16ths 66" or
  "Groove Pool: empty (grooves are added by hand in Live's browser)".

`generate_midi` itself never touches grooves — the model assigns one
afterwards via `set_clip_properties` when the pool has something and the
user asks for it. Severable: if implementation runs long, this part can ship
separately without weakening the acceptance slate (the A/B's groove arm is
assigned by the judge, who is at Live's UI anyway) — but it is small and the
roadmap names it, so the default is to build it.

### 8. `get_view_state` reports the selected scene

**File:** `lib/seshat/tools/handlers.ex`. One more read in the
`get_view_state` clause — `/live/view/get/selected_scene` (upstream address,
reply `scene_index`, echoes nothing; length-1 shape check stands in for the
echo, as `query_scene_names/1` does) — rendered as "Selected scene: N". This
is the roadmap's second named rider and what lets a model resolve "this
section" before targeting `clip_slot`. `select_scene` already exists as the
setter, so the pair is self-checking in `auto/views.md`.

### 9. Acceptance: the by-ear slate, and the Result

Not `mix test` and not `/smoke-test` — a person. The slate protocol is
committed in
`manual/by-ear.md § The fixed slate — composed beats judged blind`
(8 fixed prompts, four styles, 4 and 8 bars, fill and dropout, three seeds,
blind codes, and the raw-grid / performed / +groove A/B on one skeleton).
The verdict is recorded as a dated **Result** section in
[midi-generation-options.md](../evaluating/generative%20features/midi-generation-options.md),
including the overturn condition: if the grammar compiles reliably but
listeners call it mechanical *and* the performance layer does not close the
gap, the neural specialists (CA2 infill first, AMT bass) earn their
process-door argument. After the extended read-back has run against live
Ableton, narrow `API.md`'s ⚠️ on the extended-notes family — a doc-only
commit in the standalone fork clone (no pin bump needed per the fork
doc rule).

## Testing

All pure, none touching `Transport.query/3`:

- **Pattern** (`pattern_test.exs`): golden compiles per resolution; repeat-
  to-fill and the non-dividing refusal; bad character named with position;
  bar-separator and whitespace tolerance; 16-bar × 1/32 size case.
- **Performance** (`performance_test.exs`): determinism (same seed twice =
  identical lists); `humanize: 0.0` = the raw grid exactly; offsets bounded
  by profile σ ceiling and clamped ≥ 0; accents > ordinary > ghosts in
  velocity; ghosts carry `probability < 1.0`, others 1.0; velocities within
  1–127 at extreme profiles.
- **Bass** (`bass_test.exs`): `lock` lands on exactly the followed onsets;
  `answer` never coincides with one; `sustain` spans first-to-last; register
  and roots-length validation refusals; drum velocities provably not copied
  (distinct inputs, same bass contour).
- **Profiles** (`profiles_test.exs`): every committed profile within the
  measured envelope; enum ↔ profile parity; authored profiles name donors;
  attribution header present.
- **Workflow** (`midi_parts_test.exs`, against `Seshat.Test.OSCSink`):
  wire-order assertion (guards → creates → loads → clip → chunked adds →
  name → read-back — the arrival-order trace, as `AudioClip`'s suite does);
  chunk boundaries at 200/201 notes and encoded size ≤ 9,216 for every
  emitted datagram; occupied-slot and non-MIDI-track refusals send zero
  mutating datagrams; scene guard on both branches; failed instrument load
  still writes notes and names the silent track; read-back windowing —
  every window's expected count ≤ ~200, window edges never coincide with a
  written note start, a small clip reads whole in one query, and a window
  reply whose starts don't match the window's expected set is treated as
  stale and reissued once; read-back defaults-vs-sent wording both ways;
  partial-failure wording; stale-then-answered and stale-twice read-back
  paths.
- **Tool surface**: `definitions_test.exs` count 54 → 55; schema/validation
  parity is by construction; MCP component parity is generated and already
  tested; `handlers_test.exs` pins `generate_midi` inside the undo bracket
  (not unstepped).
- **Garnish**: empty-pool refusal wording; `groove` read-back confirmation
  and Live-error passthrough; mirror `groove_pool` field parsing including
  the zero-argument empty reply; `get_view_state` selected-scene rendering
  including an unanswered read stated as unknown.

## Live verification

Nothing in `mix test` reaches any of this — every check below assumes zero
prior coverage of the extended-notes family, which `lib/` has never
exercised on a real wire. Run the automated half with `/smoke-test`.
**Precondition:** the installed Remote Scripts copy must be at or past pin
`3b6b9bc` and Live restarted on it — `/smoke-test` never installs, and
against a stale copy every `notes_extended` result is right for the wrong
reason. (Given the 2026-08-30 install-truncation forensics in
[seshat#83](https://github.com/jpatricknola/seshat/issues/83), verify the
install landed whole before trusting a green run.)

- `smoke_tests/auto/generation.md § A composed beat lands as per-part tracks
  and one undo removes it` — the headline: independent read-back of tracks,
  slots, notes, feel mechanics (velocity spread, off-grid starts, bass
  lock), the one-undo-step promise, and the dense-lane chunk boundary.

  **Ran 2026-08-30 (PR review round 2), passed.** Live 12.4.5, 120 BPM 4/4,
  baseline one MIDI track. A four-part funk request (kick 36, snare 38, hats
  42, bass `lock` on roots `[36,36,38,38]`, seed 20260830, no instrument
  URIs) created tracks 1–4 named by role, each with a 16.0-beat clip named
  by role in slot 0 — confirmed through `get_clip_slots`, not the tool's
  reply. `get_clip_notes` on the kick: 24 notes, pitch 36 only, all inside
  16 beats, velocities 10.2–120.7, starts off the 16th grid (grid 0.75 →
  0.6852, 1.5 → 1.4656, 3.0 → 2.9782), so the performance layer ran. The
  bass read back 24 notes, C2 for bars 1–2 and D2 for bars 3–4 as the roots
  asked, one per kick onset. Dense lane: 16 bars × 1/16 = **256 notes**
  written in two chunks and confirmed across two read-back windows, with
  notes present at beat 63.7 of a 64-beat clip — the chunked write and the
  windowed read both work on a real wire, which nothing in `mix test`
  reaches. Two `undo` calls (newest first) removed both requests whole: the
  session returned to exactly one track and eight empty slots, so
  one call = one undo step holds for a five-datagram, four-track request.
  Caveats: bass onsets sit on the *drum pattern's grid* positions and are
  then humanized independently, so a `lock` bass and its kick landed up to
  ~0.065 beats (~32 ms at 120 BPM) apart — per plan, but it is the by-ear
  slate that decides whether that reads as lock. The velocity band clamp
  pins outliers to exact boundary values (see the review's quality finding).
- `smoke_tests/auto/generation.md § Extended note fields survive the wire` —
  closes `API.md`'s ⚠️: probability / velocity_deviation read back as sent,
  or the finding that Live discards them.

  **Ran 2026-08-30 (PR review round 2), passed — and the ⚠️ is answered.**
  The four-part funk beat above (ghosts in every drum pattern) reported
  "Per-note chance and velocity spread came back as sent", read through
  `/live/clip/get/notes_extended` after a write on
  `/live/clip/add/notes_extended`. **Live persists `probability` and
  `velocity_deviation` as sent** on Live 12.4.5 — the first time either has
  been read back at all. The all-`x` dense lane (no ghosts) reported
  "Velocity spread came back as sent" and said nothing about per-note
  chance, which is the per-field split behaving correctly on real data.
  `priv/AbletonOSC/API.md`'s ⚠️ on the extended-notes family can now be
  narrowed by a doc-only fork commit (Part 9); PR review does not edit API
  docs, so that is left outstanding.
- `smoke_tests/auto/generation.md § An occupied MIDI target slot is refused
  before anything is created` — guard ordering under a real Live.

  **Ran 2026-08-30 (PR review round 2), passed.** Targeting `track: 1`,
  `clip_slot: 0` while the funk beat occupied it was refused with "Slot 0 on
  track 1 … already holds a clip … Nothing was written and no track was
  created", and `get_clip_slots` showed the track count and the clip
  unchanged. Targeting a scratch **audio** track was refused with "…is not a
  MIDI track…", again with no track created; the scratch audio track was
  deleted afterwards and the session left as found.
- `smoke_tests/auto/views.md § The selected scene reads back` — the new
  upstream address consumed for the first time, self-checking against
  `select_scene`.

  **Ran 2026-08-30 (PR review round 2), passed.** `select_scene 0` →
  `get_view_state` "Selected scene: 0."; `select_scene 7` (the set's last
  scene) → "Selected scene: 7."; `select_scene 3` → "Selected scene: 3.".
  Setter and getter agree in both directions. Selection restored to 0.
- `smoke_tests/auto/mcp-surface.md` (handshake and budget checks) — the tool
  count and serialized bytes move, and `parts` is a root-level array of
  rich objects; a client that rejects the schema loses the **whole** tool
  list, not one tool. The last recorded run predates this surface.

  **Ran 2026-08-30 (PR review round 2), passed.** `mcp_call.py list` over a
  real handshake: **55 tools**, matching `Definitions.all/0`. `mcp_call.py
  stats`: **55 tools / 73,569 bytes / largest `generate_midi` at 5,470
  bytes** — up 9,447 bytes and two tools from the file's 2026-08-30
  baseline of 53 / 64,122 / `generate_audio` 3,875 (one of those two tools
  is `convert_audio_to_midi`, which shipped after that stamp). `parts`
  survives the handshake intact and is the surface's first **array of rich
  objects**: `items.type: object`, `items.additionalProperties: false`,
  `items.required: ["role"]`, `minimum`/`maximum` preserved on nested
  integers *and* on the doubly-nested `roots.items` (28–43). Measured
  against a server that was **not** freshly restarted — dev code reloading
  had brought it to this checkout, proven by the 55-tool list and by
  `get_view_state` answering the new selected-scene line. Note these
  client-visible bytes are ~1.8 % above the Elixir-side estimate Part 6
  records (72,239 / 5,446); quote these.
- `smoke_tests/manual/engineered-state.md § A groove from the pool lands on a
  clip, and an empty pool is told plainly` — pool stocking is drag-only, so
  a person; covers the empty-pool refusal, assignment read-back, bad index,
  and the one-way contract.
- `smoke_tests/manual/on-screen.md § Probability shows as Chance in the clip
  editor` — the wire read-back proves storage; eyes prove Live's editor and
  playback honour it.
- `smoke_tests/manual/conversation.md § A generation request routes to one
  call and names the form` — rewritten for the MIDI-default flip: unadorned
  material → `generate_midi`, explicit audio → `generate_audio`, another
  take → next empty scene. Fresh client, judged by a person.
- `smoke_tests/manual/by-ear.md § The fixed slate — composed beats judged
  blind` — the acceptance test itself (Part 9).

**Uncovered, deliberately:** whether the composed material is musically
*good* is only the by-ear slate — no automated check claims it; multi-
listener agreement (one listener ranks personal usefulness only — recorded
limitation, not a gap to close); arbitrary third-party kits' pad maps (no
pad-read address exists — `FORK_GAPS.md` owns that gap; GM defaults plus the
model adjusting `pitch` is the contract); the OS-level UDP drop itself (the
chunker is tested by arithmetic against the measured 44 + 40·N encoding;
deliberately over-filling a datagram against live Ableton proves nothing the
arithmetic doesn't); and `mix routing.eval`'s stochastic routing evidence,
which is run on demand per Part 6 rather than cited here.

## Out of scope

- **Melody and harmony parts** — no symbolic candidate exists (the decision
  doc's standing verdict); the schema's `type` enum is `drum | bass` and
  grows only when a candidate does.
- **Neural specialists** — Composer's Assistant 2 (infill/revision) and AMT
  (bass) stay unbuilt, gated on the by-ear verdict; each needs a third
  native-process door argued in its own commit.
- **Runtime retrieval from GMD** — measured too thin for the target styles;
  GMD is an offline donor only. No GMD file ships or is read at request
  time.
- **Stocking the Groove Pool** — a Live ceiling, not a gap; the empty pool
  is reported plainly and nothing more.
- **`write_midi_notes` chunking** — that tool's own roadmap defect stands;
  this feature's writes chunk in its own workflow and never widen
  `write_midi_notes`.
- **Persisting plan/pattern artifacts beside the clip** — "keep the snare,
  change the hats" within a conversation works because the model holds the
  pattern it wrote and re-emits it (plus `edit_notes` for surgical tweaks);
  durable cross-conversation pattern storage is future work, on the roadmap
  only if the by-ear phase shows it's missed.
- **Arrangement view, audio conditioning, full-song structure** — the
  user-stories boundaries hold.
- **A `get_clip_notes` extended widening** (reading probability etc. back
  through a public tool) — the workflow's internal read-back covers this
  feature; widening the public reader is its own small item if expression
  editing ever lands.

## Open questions

1. ⚠️ **Do `probability` / `velocity_deviation` / `release_velocity` persist
   with their sent values?** Measured *accepted* (2026-08-30) but never read
   back — the probe read used the five-field getter, and `API.md` carries
   the ⚠️. Could not be closed this pass without rewriting the installed
   Remote Scripts copy under a running Seshat (the reply port is held, so
   only the probe-handler/Log.txt rig reaches a reply, and
   [seshat#83](https://github.com/jpatricknola/seshat/issues/83) records an
   install-restore truncating on this machine *today* — an unattended
   reload/reinstall cycle was judged a worse risk than the open question).
   **Assumed: they persist** (Live's documented note API; Push's own editor
   round-trips them). The workflow's read-back (Part 5 step 6) measures it
   on first live run and the reply is honest either way; if they do not
   persist, the feel core (microtiming + velocity, both proven through
   `get_clip_notes`) is untouched and the description drops the per-note
   chance claim.
2. **Does the grammar sound idiomatic, and does the performance layer close
   the feel gap?** The acceptance question itself — answerable only by the
   by-ear slate (Part 9), by design after the feature exists. The overturn
   condition is written in the decision doc and restated in Part 9.
3. **Are 30 hiphop / 7 dance files enough for stable per-lane statistics?**
   Resolved at harvest time, not plannable: the harvest script computes
   per-style sample counts per lane and falls back to the all-styles pooled
   statistic for any lane with < 8 source files, recording which lanes fell
   back in the JSON. The profiles test's envelope bounds catch a degenerate
   harvest either way.
4. **Does an assigned Live groove improve or homogenise the result?** By-ear
   A/B arm (Part 9); the garnish ships regardless since assignment is
   user-driven.
