# Tool-surface scaling — growing capability without growing the tool list

_Options doc · 27 Aug 2026 (corrected same day: `set_loop` is the song loop, not a clip fold) · audits the 67 tools shipped today, what the
roadmap and the generation research would add, and how to keep building
without the tool list becoming the bottleneck. Verdict and a recommended
sequence at the end._

## The problem, with numbers

Seshat ships **67 tools**. Serialised to JSON the way MCP sends them, that is
**62,784 bytes — roughly 16k tokens — in every request**, before the user has
said a word. Every capability so far has been "one thing Live can do = one
tool," and the queue ahead is long: the roadmap's ready items imply another
eight to ten tools on the same pattern, the generation epic implies several
more, and the AX rung has just opened a door to a whole class of Live menu
commands that were previously unreachable. On the current pattern the list
reaches 100 within a few months and keeps going.

Three ceilings, in the order they bite:

1. **Selection accuracy — bites first, at roughly 50–100 tools.** The model
   picks between names, and confusable neighbours are what it gets wrong:
   `set_track_volume` / `set_return_track_volume` / `set_master_volume` are
   three names for one idea. The failure is silent — a wrong-target call
   looks like the model being careless, not like an architectural cost — so
   it never shows up as a defect against the tool list. Naming collisions,
   not raw count, are the cost here.
2. **Context tax — every turn, forever.** The schemas are cached but they
   still occupy the window and compete for attention with the 2,048
   characters of `Seshat.Instructions`, which is the scarcest text in the
   system. At 300 tools Seshat would own ~80k tokens of every conversation.
3. **Client caps — unmeasured.** Claude Desktop silently truncates server
   `instructions` at 2,048 characters (measured 2026-07-29). Nothing says it
   has no comparable limit on the tool list; nothing says it does. It has
   not been tested, and it should be before any plan assumes the count is
   free.

The **selection-accuracy** ceiling decides the strategy. It is not "how many
tools" but "how many *near-duplicate names* the model has to discriminate
between," so the levers that matter are the ones that remove same-verb
neighbours, not the ones that shave bytes.

## What already works — two patterns in the tree

Two consolidation patterns are already in `Definitions`, argued in the file
itself, and should simply be applied more widely:

- **Parameterise on target, not on name.** The six device tools take
  `target: "return" | "master"` (`@device_target`,
  [definitions.ex:17-25](../../lib/seshat/tools/definitions.ex#L17-L25))
  rather than existing as eighteen tools. The comment above it records why
  `track` stays required with a "pass 0" wart for master: making it optional
  would change the wire contract for the common case. That reasoning
  transfers unchanged.
- **One tool, many optional properties.** `set_clip_properties` sets any of
  ~a dozen clip fields in one call, each key carrying its own schema so
  `Seshat.Tools.Validation` still bounds every value by construction. It is
  the largest schema in the file (3.4KB) and replaces what would otherwise be
  twelve tools; the reply reports per-property outcomes, including the
  loop-pair ordering rider. This is the stronger of the two patterns and the
  one the mixer surface should adopt.

`show_view` does the same for six pane names via an enum. The pattern is
established; it just stopped being applied once the mixer tools were written.

## Audit — the 67 tools today

Grouped by what the model actually has to choose between.

### Mixer setters — 12 tools, one concept

| | track | return | master | cue |
|---|---|---|---|---|
| volume | ✓ | ✓ | ✓ | ✓ |
| pan | ✓ | ✓ | ✓ | — |
| mute | ✓ | ✓ | — | — |
| solo | ✓ | ✓ | — | — |
| arm | ✓ | — | — | — |

Twelve tools differing only in target and index-parameter name
(`track` vs `return_track` vs none). Plus `set_track_name`, which is the same
shape again. The fader-scale paragraph ("0.85 = unity gain") is repeated in
six descriptions. **Proposed: one `set_mixer` tool** — `target:
"track" | "return" | "master" | "cue"` (default `track`), `track` index,
and optional `volume`, `pan`, `mute`, `solo`, `arm`, `name`. Every property
keeps its own schema and bounds; the reply reports each one it was asked
for, the way `set_clip_properties` does. Properties the target does not have
(`arm` on a return, `pan` on cue) are refused by name in the reply, which is
better than today's situation where the model cannot mute the master because
no tool exists and has to discover that by absence. **13 → 1.**

One trade-off to state: the description gets longer, since it now carries
the fader scale, the pan range, and the return/master index rules once each.
Net bytes still fall — those paragraphs exist 6× and 11× today — and the
model discriminates between one name and its neighbours instead of thirteen.

### Structure — create/delete/duplicate × track/return/scene

`create_track` (with `track_type: midi | audio`), `create_return_track`,
`create_scene`; `delete_track`, `delete_return_track`, `delete_scene`;
`duplicate_track`, `duplicate_scene`. **Proposed:** `create_return_track`
folds into `create_track` as `track_type: "return"`; `delete_return_track`
folds into `delete_track` as `target: "return"`. Scenes stay separate — a
scene is a different noun, the model *should* choose between them. **8 → 6.**

### Transport — 5 tools, keep

`start_playing`, `stop_playing`, `set_tempo`, `set_metronome`,
`set_time_signature`. Cheap (the two playing tools are the smallest schemas
in the file, 130 bytes each) and the verbs are genuinely distinct. A
`set_transport` merge would save little and cost the crisp mapping from
"stop" to `stop_playing`. Leave them.

### Clips — 12 tools, mostly right

`fire_clip`, `stop_clip`, `record_clip`, `stop_recording`, `capture_midi`,
`delete_clip`, `duplicate_clip`, `set_clip_name`, `set_clip_properties`,
`get_clip_properties`, `get_clip_slots`, `set_loop`. One fold:
`set_clip_name` is one property of `set_clip_properties` (add `name` there).
`set_loop` is **not** a fold, despite the name — it is the *song's*
arrangement loop (`/live/song/set/loop`), a different object from the clip's
loop brace, and both descriptions already spend a sentence keeping the two
apart. **12 → 11.** `fire`/`stop`/`record` stay: the verb is the whole
meaning.

### Notes — 4 tools, and the roadmap wants a fifth

`write_midi_notes`, `get_clip_notes`, `remove_notes`, `quantize_clip`.
Roadmap #11 ("Modify a note in place") would add `modify_note`. **Don't.**
The three-call read/remove/rewrite chain it complains about is real, but the
fix is an `edit_notes` shape that takes a match (pitch/time range) and a
delta — velocity, length, pitch shift — which the model reaches for on
"make the third note quieter" and on "shift everything up a fifth" alike.
One tool that subsumes `remove_notes` (delta: delete) as well. **4 → 4 with
#11 absorbed, or 5 today → 4.**

### Devices — 6 tools, done right

`load_device`, `get_track_devices`, `get_device_parameters`,
`set_device_parameter`, `delete_device`, `bypass_device`, all carrying
`@device_target`. This is the pattern. One note: `bypass_device` and
`delete_device` are the same shape (`track`, `device`, `target`) and differ
only in verb; the destructive one should stay a separate name so the model
cannot bypass-when-it-meant-delete by flipping a flag. Keep.

### Sends — 2, keep. Scenes — 5, keep (see structure above). View — 3, keep

`hide_view`'s enum is deliberately smaller than `show_view`'s — the two
panes measured to actually close — and a merged `set_view(visible:)` would
throw that schema-level guard away. Keep them apart.

### Session, library, history, audio output — 8, keep

`get_session_state`, `select_track`, `select_scene`, `search_library`,
`reindex_library`, `list_browser_items`, `undo`, `redo`,
`get_audio_outputs`, `set_audio_output`. All distinct verbs on distinct
nouns. `select_track`/`select_scene` could become one `select` with a
target enum; low value, same noun problem as create/delete scenes. Leave.

### Description diet — free bytes, zero risk

`"Requires Seshat's AbletonOSC extension (mix abletonosc.install)."` appears
in **11 descriptions**. It is addressed to a developer, not the model: the
model cannot run Mix, the user never sees descriptions, and an uninstalled
fork surfaces as a timeout the handler already renders. Delete every copy.
~700 bytes back and, more usefully, eleven descriptions that end on their
actual guidance.

### Audit total

| Group | Today | After | Saved |
|---|---|---|---|
| Mixer setters (+ `set_track_name`) | 13 | 1 | 12 |
| Structure (return folds) | 8 | 6 | 2 |
| Clips (`set_clip_name` fold) | 12 | 11 | 1 |
| Everything else | 34 | 34 | 0 |
| **Total** | **67** | **52** | **15** |

Fifteen tools removed, no capability lost, and every removal is a
same-verb-different-target neighbour — exactly the shape the selection
ceiling punishes. Breaking change to the tool contract; nothing is in
production, and the `/smoke-test` files that name the old tools need
updating in the same PR.

## Audit — what the roadmap would add

Working the queue from the top, counting only ready items:

| Item | On the current pattern | Recommended shape | Net tools |
|---|---|---|---|
| #6 Browser preview audition | `preview_item`, `stop_preview` | One `preview_item` with `action: play \| stop`, or fold into `list_browser_items` — the fork already ships both addresses | +1 |
| #7 `start_new_project` | 1 | Keep as a tool — the roadmap's own argument (routing a user utterance off the capped instructions budget) is the right use of a tool name | +1 |
| #10 Audio input display | 1 read tool | **0** — the roadmap already says the smallest version is `record_clip` reading routing and naming it in the reply. Take that version | 0 |
| #11 Modify a note in place | 1 | Absorbed by `edit_notes` (above) | 0 |
| #12 `screenshot_live` | 1 | 1 — a genuinely new modality | +1 |
| #15 Producer personas | `load_producer`, `list_producers` | **0 tools — this is an MCP *prompt*, or a *resource*.** See "Mechanisms other than tools" below. The roadmap asks the planner for out-of-the-box delivery; the box it should look outside of is the tool list | 0 |
| #18 Grab bag: colour, MIDI map, groups, routing, automation | 5–8 | Colour is a `set_mixer` property (+0). Routing is a `set_routing` with input/output/monitor as optional properties (+1). Groups, automation, MIDI map: one each when a workflow needs them (+0 now) | +1 |
| #16 Verify destructive mutations | 0 | 0 — reply quality, no surface | 0 |
| #2, #3, #4, #13, #14, #17, #19 (catalog) | 0 | 0 — all change `search_library`'s ranking and replies, not the surface | 0 |
| Selected scene/clip read (prerequisite named in the MIDI research) | 1 | Fold into `get_view_state`, which already reads view state and folds it into prose | 0 |
| Drum Rack pad map (prerequisite if rack output is in scope) | 1 | Fold into `get_device_parameters` for a rack device — a rack's pad map *is* its parameters | 0 |

**Roadmap on the current pattern: ~12 new tools. Recommended: +5.**

## Audit — what the generation research would add

This is where the count could explode, and where the research has already
made the right product decision without noticing it is also the right
tool-surface decision.

[music-generation-user-stories.md](generative%20features/music-generation-user-stories.md)
fixes it: **"One request is one reversible action… one high-level generation
operation and one Ableton undo step. It must not be implemented as a loose
conversation-time chain of independently undoable track, device, and note
mutations."** That is one tool. Call it `generate_parts`: a brief, a list of
roles (`kick`, `snare`, `hats`, `bass`, …), bar count, output form
(`midi` default | `audio`), and a target section. It creates tracks, resolves
sounds through the catalog, loads devices, writes clips and verifies — all
inside the handler, not as model-driven calls. The primitives it composes
(`create_track`, `load_device`, `write_midi_notes`) stay as they are for
direct use. Stories 6–8 (revise one part, another take, hard constraints) are
parameters on the same tool — `revise: [roles]`, `variation: true` — not
sibling tools.

Backend choice (Route C / D / joint, SA3 vs MRT2, IDM vs Convert Drums) is
**invisible at the tool layer**. The tool says what to make; the handler
picks how. The blinded bake-off changes the handler, never `Definitions`.

Live improvisation ([live-improv-exploration.md](generative%20features/live-improv-exploration.md))
is the other shape. Its §6 lists nine collaborator intentions — `start`,
`set_harmony`, `follow`, `set_density`, `add_influence`, `exclude`,
`build_tension`, `capture`, `stop`. On the current pattern that is nine
tools. It should be **two**: `improvise` with an `action` enum and the
optional fields each action needs (`start` takes role and boundary;
`set_density` takes level and ramp; `capture` takes bars and destination),
and `improvise_status` for the read side. The doc's own framing — "the
collaboration session exposes Seshat-level intentions rather than
provider-specific fields" — is an argument for a small verb surface over a
provider adapter, which is the same argument as this document's.

The Live-native AX commands ([live-native-options.md §3](generative%20features/live-native-options.md),
[ui-scripting-options.md](ui-scripting-options.md) "What UI scripting could
buy"): Stem Separation, Convert Harmony/Melody/Drums, Extract Groove, Slice
to New MIDI Track. Each is a named menu command with OSC-side read-back. On
the current pattern: four to six tools, and the door stays open to every
other menu item. **Recommended: one `run_live_command` with a closed enum**,
where each enum value is a command the AX spike has actually measured
(reachability, dialogs, duration, what the mirror sees). Adding a command is
one enum entry plus its safety case, never a new name. Note this changes
nothing about `native/seshat_ax/main.m` staying a closed protocol: the enum is
at the Elixir layer, and each entry still maps to a specific, bounded native
command — the helper gains no generic "press this" affordance.

### The AX path — two counts that look like one

The AX rung is the one place a lot of new capability is about to arrive
from, so it is worth being explicit that it does **not** need a tool per
action. Two counts are involved, and only one has a ceiling:

- **Model-facing names** — the count this document is about.
- **Native commands in `main.m`** — one bounded case per action. No ceiling
  that matters; a new case is a few dozen lines and a smoke test.

Today the two are 1:1 (`get_audio_outputs` → `list-outputs`,
`set_audio_output` → `set-output`). They need not stay that way. The shape
that scales is **two tools, both with closed enums**, each enum value backed
by its own native case:

- **`run_live_command`** — verbs. `command: stem_separation | convert_drums
  | convert_harmony | convert_melody | extract_groove | slice_to_midi | …`,
  plus whichever of `clip` / `track` / `scene` the command targets. Fire,
  then verify on the OSC side.
- **`live_setting`** — nouns. `action: get | set`, `setting: audio_output |
  audio_input | sample_rate | buffer_size | …`, `value`. Today's two audio-
  output tools fold into it the day a second setting is needed; not before.

What stays fixed however long those enums get:

- **The helper stays closed.** No `press_element`, no `dump_tree`, no
  `keystroke`. Every enum value maps to a specific bounded native command
  with its own safety case, exactly as the two audio-output commands do.
  The mechanism ladder in [ui-scripting-options.md](ui-scripting-options.md)
  is unchanged; `ax-probe` stays a development tool for *finding* targets,
  never a runtime affordance.
- **Independent read-back is the entry ticket.** Stem Separation and Convert
  Drums produce new tracks that push into `Session.State`, so a
  count-before/count-after guard bounds misdelivery the way `create_track`
  already does; a Settings value is re-read after the set. A command whose
  result cannot be read back through OSC or a stable AX value does not go
  in the enum, whatever the shortcut is.
- **Per-command caveats live in the enum description** — Suite gate,
  seconds-to-minutes duration, whether a mode dialog appears. They grow one
  schema, not the name list, and the model reads them at the moment it is
  choosing the value.

The ceiling that *does* remain is description length. Fifteen commands with
a sentence of caveats each is ~2–3KB of schema — the size of
`set_clip_properties` today, fine. Fifty would want splitting by noun
(`run_clip_command`, `run_track_command`). That is well past anything the
LOM gaps currently motivate.

| Epic | On the current pattern | Recommended | Net |
|---|---|---|---|
| Clip generation (stories 1–8) | 4–6 (`generate_drums`, `generate_bass`, `generate_rhythm_section`, `regenerate_part`, …) | `generate_parts` | +1 |
| Live improvisation | 9–10 | `improvise`, `improvise_status` | +2 |
| Live-native AX commands | 4–6, growing | `run_live_command` (enum) | +1 |
| Audio import (audio-output stories) | 1 | Fold into `generate_parts` as `output: audio`; an `import_audio` primitive only if a user story needs bare import | +0–1 |
| Groove pool assignment (fork gap) | 1 | A `groove` property on `set_clip_properties` | 0 |

**Generation on the current pattern: ~20 new tools. Recommended: +4–5.**

## The whole LOM, without the whole LOM's tool count

The question behind all of this: if the fork closed every gap in
`FORK_GAPS.md` and the wire reached the entire Live Object Model, would
Seshat be able to use it without the tool list following the LOM's size?
Yes — **if tools are shaped by noun, not by property.**

The LOM is roughly fifteen object types carrying hundreds of properties
between them. Property count is unbounded in practice; object count is not:

`Song · Track (return and master folded in) · ClipSlot · Clip · Scene ·
Device · DeviceParameter · Rack / Chain / DrumPad · Browser · View · Groove ·
CuePoint · MidiMap · Arrangement`

Shape per noun: one `get_X` that reads many fields in one call, one `set_X`
that takes an optional property bag, and the few verbs that are genuinely
verbs (`fire`, `delete`, `duplicate`, `quantize`). A newly exposed property
is one more key inside `set_X` — no new name. `get_clip_properties` /
`set_clip_properties` is already this shape at twelve properties; a full
`Clip` would be forty, still one tool. `set_mixer` is the Track noun. The
device tools already carry `target`.

Rough ceiling with the **entire** LOM exposed: fifteen nouns × three or four
shapes ≈ 50–60 tools. Add the generation and AX tools above and the surface
sits at **75–85** — at the review line, never past it. The current pattern
reaches 300 on the same surface.

Three things follow from the shape:

- **Session state absorbs the read side.** A property with a listener is a
  line in `get_session_state`, never a `get_*` tool. That is how the mirror
  already works for the mixer, and how #22 (device list per track) would
  retire the device tools' verifying re-reads.
- **Nested objects need an addressing scheme, not a tool per depth.** Rack →
  Chain → DrumPad → Device is one `path` parameter (`[track, device, chain,
  pad]`) on the device tools, decided once, not four tool families.
- **Property bags keep validation by construction** — `Validation` reads
  bounds per key — as long as no value's type depends on a sibling (the
  "don't merge on property" rule above).

### Where the ceiling moves to

With count under control, the constraint becomes **per-tool description
size**. `set_clip_properties` is 3.4KB at twelve properties, most of it
enum tables (`launch_mode: 0=Trigger, 1=Gate…`). Forty properties at that
density is ~10KB, and attention inside one description degrades the way
selection between names does. In order of preference:

1. **Enums as strings.** `"trigger"` rather than `0`; the table leaves the
   description and lives in the schema's `enum`, where a client can render
   it. `quantize_clip` already does this (`"1/16"`, `"1/8T"`).
2. **Replies teach, descriptions don't.** The `search_library` pattern:
   `get_X` names the valid values and current state in its reply; the
   description says what the tool is for and stops.
3. **Split a noun by facet only when the facet has its own workflow.** A
   `set_clip_launch` beside `set_clip_properties` only if launch settings
   become something users batch separately. Never pre-emptively.

And one non-goal: full LOM is not the target — full *useful* LOM is. "The
LLM does the resolving, tools stay dumb" and "Session view first" already
decline Arrangement, take lanes and parameter listeners, and that stays true
however cheap a property becomes to expose.

## Mechanisms other than tools

Three more angles, each of which delivers capability with zero tools. None
is free of an open question about client support, and each question is
answerable the way the 2,048-character cap was — one measurement against
Claude Desktop.

### MCP prompts and resources

The protocol has two model-facing primitives besides tools. **Prompts** are
named, parameterised text templates the user picks in the client; **resources**
are addressable content the client can attach to a conversation. Producer
personas (#15) are the textbook case: a persona is a document, chosen by the
user, loaded at a moment of their choosing, that changes how the model
behaves. That is an MCP prompt named after the producer, or a resource under
`persona://volt-kessler`. It costs nothing on the tool list *and* nothing on
the instructions budget, which is the constraint the roadmap item is stuck
on. The catalog's tag vocabulary (#2) has the same shape as a resource. Anubis
1.10 supports both (`send_prompts_list_changed/0`,
`send_resources_list_changed/0` exist beside the tools one in
`Anubis.Server`).

**Open question:** how Claude Desktop surfaces prompts and resources to the
user, and whether attaching one changes model behaviour as strongly as
server instructions do. Measure before planning #15 around it.

### Modal tool sets — `tools/list_changed`

Anubis exposes `Anubis.Server.send_tools_list_changed/0`, so the server can
change which tools it advertises mid-session. That makes a modal surface
possible: a core set always present, and an `improvise` set that appears
when a collaboration session starts and disappears when it stops. It is the
one lever that lets the total *definable* surface exceed the selection
ceiling, because the model only ever sees the active subset.

It is also the most expensive lever: it complicates the parity tests that
pin generated components against `Definitions`, and a client that ignores
the notification would leave the model calling tools that no longer exist.
**Do not reach for it before the consolidation above has landed** — with the
audit's 52 plus the recommended ~10 the surface sits near 60 with the whole
generation epic built, and no mode switch is needed. Record it as the lever
for the day the count passes ~90, and measure Desktop's handling of the
notification before then.

### Replies as guidance, session state as capability

Two existing habits that already avoid tools, worth naming so they keep
being used:

- **Reply-carried guidance.** `search_library` teaches tag vocabulary in its
  reply; `record_clip` will name the input routing in its reply (#10). A
  reply is delivered exactly when the model needs it and costs nothing in the
  schema. When a capability is "know X at the moment you do Y," it is a reply
  on Y, not a `get_x` tool.
- **Mirror, don't query.** Every value promoted into `Session.State` retires
  a potential `get_*` tool. #21 (device list per track) is this pattern and
  would let the device tools skip their verifying re-reads.

## Architecture boundary — complete capability, bounded intent

The fork, the AX helper, and the model-facing tool surface are allowed to grow
at radically different rates. Completing every entry in
`priv/AbletonOSC/FORK_GAPS.md` may add hundreds of OSC addresses. AX may gain
dozens of bounded native commands, and generation may combine several models,
services and Live-native operations. **None of those counts is a tool-count
target.**

The stable architecture is three layers:

```text
Model-facing intentions (small, stable, producer vocabulary)
                            ↓
Domain operations (validation, sequencing, undo, verification)
                            ↓
OSC fork | AX commands | generation providers (large capability inventory)
```

- **Capability adapters answer “what can the machine do?”** AbletonOSC exposes
  the LOM; the native helper exposes individually reviewed UI operations; a
  provider adapter exposes generation or streaming primitives. Completeness is
  desirable here.
- **Domain operations answer “what action is Seshat performing?”** They own
  cross-field validation, target resolution after the model has supplied an
  index, ordering, partial-failure wording, one-action/one-undo semantics, and
  independent read-back. Substantial logic belongs in focused modules behind
  the dispatch clause; `Handlers` remains the only name dispatcher, not the
  eventual home of every algorithm and backend workflow. `Registry` remains
  the executor for bounded `%Command{}` OSC sequences, not a generic workflow
  engine; a domain operation may compose Registry, OSC reads, AX and provider
  adapters.
- **Tools answer “what intention should the model choose?”** They use producer
  vocabulary and remain bounded. Provider names, OSC address names, native
  helper command names and LOM member names are implementation details unless
  the producer genuinely chooses between them.

Closing a fork gap therefore triggers a routing decision, not a new tool:

1. Does it become another property or target of an existing tool?
2. Is it only an internal step, verification read, or `Session.State` field?
3. Does it complete a high-level operation the user already thinks of as one
   action?
4. Only if none of those fit: is there a genuinely new producer intention that
   deserves a name?

`FORK_GAPS.md` already states the reciprocal rule: it inventories bridge
capability, not tool-layer priority. Full LOM coverage and a small Seshat
surface are compatible precisely because publication is a separate decision.

### Cohesion limits inside a consolidated tool

Consolidation can merely move bloat from the list into one schema. A property
bag or action enum stays one tool only while its members share all of these:

- the same user-visible noun or workflow;
- the same targeting shape and discovery path;
- compatible safety, undo and verification semantics;
- a description short enough that the model can choose the value reliably.

Split by workflow or noun when those stop being true. Do not split merely
because a backend has another method, and do not merge unrelated operations
merely because one backend happens to implement all of them. In particular,
`run_live_command` is a closed family of verified Live transformations, not a
generic home for every AX action; settings remain a separate noun.

Conditional schemas are the pressure point. `set_mixer` can afford a small
handler-side support matrix because JSON Schema cannot express its conditional
`track` requirement through the subset Seshat supports. If this pattern repeats,
extract one shared preflight convention before a third bespoke implementation:
collect every missing, conflicting or target-unsupported field; reject the
whole call before transport; name every problem and the accepted fields. Tool
count has not improved if it is replaced by dozens of inconsistent validators.

### Generation keeps the same boundary

Generation tools are named after reversible producer actions, never providers
or pipeline stages. `generate_parts` may resolve sounds, call several models,
create tracks and clips, and verify the result; those remain one action and one
undo step. A bake-off changing the winning backend changes an adapter, not
`Definitions`. Revision becomes another tool only if users experience it as a
different workflow; otherwise it is an action or parameter on the same
operation. Continuous improvisation gets a separate status/read side because a
long-lived collaboration session has lifecycle state that a one-shot generation
does not.

### Measure the surface, not only its count

The 80-tool line is a review trigger, not the success metric. Every surface-
changing plan records before/after:

- advertised tool count and serialized `tools/list` bytes;
- the largest individual schema/description and whether it remains cohesive;
- names added, removed, and near-neighbours the model must discriminate;
- conditional combinations that the schema cannot express and the preflight
  tests that cover them;
- representative fresh-conversation prompts for selection and first-call
  success.

Pure tests defend count, schema parity, bounds and refusal behavior. A real MCP
handshake measures the actual advertised bytes. Conversation smoke tests defend
selection quality; a repeatable prompt corpus should replace one-off judgment
before the surface or generation epic approaches the review line. A lower count
does not excuse a worse selection result.

## The rule going forward

One test, applied in `/add-tool` before a name is minted:

> **A new tool name is justified only when the model must choose between
> this and an existing tool — different verb, or different noun. The same
> verb aimed elsewhere is a `target` value. The same noun's other property is
> an optional parameter. A sequence the user thinks of as one action is one
> tool whose handler composes the primitives.**

And a budget: **80 tools is the review line.** A test should stop an unreviewed
81st definition; an approved plan can move the line only after recording the
measurements above and explaining why consolidation no longer fits. Past ~90,
build the modal set if the client measurement proves it reliable.

## Recommended sequence

1. **Consolidate now, before the next tool lands** — one PR: `set_mixer`,
   the two return folds, the `set_clip_name` fold, `edit_notes` replacing
   `remove_notes`, and the description diet. 67 → 52, no capability lost.
   Update the smoke tests that name the old tools in the same PR. This is a
   morning's work at the Elixir layer and a breaking change to nothing that
   is deployed.
2. **Write the rule into `.claude/docs/adding-a-tool.md` and `/add-tool`**,
   with the budget line. Cheap, and it is what stops the count creeping back.
3. **Re-shape the roadmap items that add surface** as they are planned, not
   now: #11 → `edit_notes` (already done by step 1), #15 → MCP prompt with a
   Desktop measurement as its first task, #10 → reply on `record_clip`, #18
   routing → one tool.
4. **Measure Claude Desktop once**, in the same session as the persona
   measurement: does it honour `tools/list_changed`; does it expose prompts
   and resources; is there a tool-count or tool-list-byte limit. Three
   questions, one afternoon, and every later plan stops guessing.
5. **Build a repeatable tool-selection prompt corpus before the first
   generative tool lands** — realistic utterances covering the nearest name
   collisions, recorded expected tool/action/target and first-call success.
   The consolidation's conversation smoke test is the seed, not the finished
   harness. [automated-conversation-routing-evals.md](automated-conversation-routing-evals.md)
   evaluates a headless client plus record-only MCP server as the automation
   route. Put this on the roadmap when generation itself is promoted from
   research to roadmap work, as its gate rather than as cleanup after the new
   surface ships.
6. **Plan the generation epic with its tool surface fixed up front** —
   `generate_parts`, `improvise` + `improvise_status`, `run_live_command`.
   Four names for the whole programme. The bake-off changes handlers, never
   `Definitions`.

Projected surface with everything above built: **52 + ~5 roadmap + ~5
generation ≈ 60–62 tools** — fewer than today, doing several times as much.

## What not to do

- **Don't turn fork completeness into tool publication.** Closing every LOM
  gap is compatible with adding zero names; most addresses should extend an
  existing property/target, support a domain operation, verify a mutation, or
  feed the mirror.
- **Don't let `Handlers` become the second bloated surface.** It owns dispatch
  and simple wire calls; substantial algorithms, provider workflows and
  lifecycle state belong in focused domain modules behind its clauses.
- **Don't declare victory from count alone.** A smaller surface that produces
  larger incoherent schemas or worse first-call selection is a regression.
- **Don't merge on property with a polymorphic value** (`set_track_property(
  property: "volume" | "mute", value: …)`). `Validation` reads bounds out of
  the schema per key; a value whose type depends on a sibling field defeats
  that by construction and puts the range check back into handler code.
- **Don't merge `show_view`/`hide_view`**, or `bypass_device`/`delete_device`.
  Where two tools differ in *what can go wrong*, the separate name is the
  guard.
- **Don't build the modal tool set as the first move.** It solves a problem
  the consolidation removes for the foreseeable roadmap, at the highest
  cost of any lever here.
- **Don't count on the client having no tool-list cap.** Measure it.
