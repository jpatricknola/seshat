# Plan — Per-clip properties: loop brace, markers, launch settings

> **Archived 2026-07-29 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. `get_clip_properties` and
> `set_clip_properties` live in `Seshat.Tools.Definitions` / `Handlers`
> (`clip_property_writes/2` is the pure, unit-tested write-orderer). No
> Python changed, so nothing here has run `mix abletonosc.install` or
> touched a live Ableton — the plan's four open questions and its Testing
> section's seven smoke items are all still unconfirmed and now belong to
> `/smoke-test`. PR review (2026-07-29) additionally found that the
> pair-context read driving the write order runs *before* a `looping`
> toggle in the same call, which can see stale (pre-toggle) values on a
> clip whose stored loop brace differs from its play markers — recorded as
> a known wart on `set_clip_properties` in
> [TOOL_AUDIT.md](../TOOL_AUDIT.md) §05, to confirm and fix alongside smoke
> item 2. The roadmap issue this shipped is gone from
> [ROADMAP.md](../ROADMAP.md); its former follow-on, session record, is now
> #1.

Roadmap #1. Two new tools — `get_clip_properties` and `set_clip_properties` —
covering a clip's own loop brace (`looping`, `loop_start`, `loop_end`), its
play markers (`start_marker`, `end_marker`), its launch behaviour
(`launch_mode`, `launch_quantization`, `legato`, `velocity_amount`), and, for
audio clips, `gain`, `warp_mode`, and `warping`. **No fork changes and no
`mix abletonosc.install`** — research found every address already registered
in the fork's `clip.py`, including `looping`, which the roadmap entry believed
missing (see Context). Pure Elixir plus one row added to the canonical
address docs.

## Context

`set_loop` moves the *song's* arrangement loop. A clip's own loop brace — the
thing that answers "loop the good two bars" — is unreachable, which leaves
`capture_midi` half-usable: Live infers a length and brace for a captured
clip, and nothing can trim it to the part that was good. The same gap will
greet every recorded take once session record (roadmap #2) ships, which is why
this comes first. It also closes the standing audit gap that a clip's length
can't be changed after creation ([TOOL_AUDIT.md](TOOL_AUDIT.md) §02).

Three findings from research that shape the plan:

- **`looping` exists upstream after all.** The roadmap entry said the loop
  on/off toggle was not exposed and budgeted a possible fork commit for it.
  It is in fact registered: `priv/AbletonOSC/abletonosc/clip.py` lists
  `"looping"` in `properties_rw` (line 116), from upstream commit `a1eedf9`
  ("introduces new clip properties", Sep 2024 — an upstream contribution, not
  a Seshat divergence; `SESHAT.md` correctly doesn't list it). The 2026-07-29
  check was made against [abletonosc-api-docs.md](abletonosc-api-docs.md),
  which omits the row. So the fix is a docs row, not Python — the whole
  feature rides on addresses the installed bridge already serves.
- **`loop_start`/`loop_end` alias the play markers while looping is off.**
  Live's object model documents `Clip.loop_start` as "for looped clips: loop
  start; for unlooped clips: clip start" (and `loop_end` likewise). Two
  consequences: the setter must write `looping` *before* the loop points when
  both are given, and the tool descriptions must teach that the loop brace
  only means "loop brace" while looping is on. ⚠️ Confirmed against LOM
  documentation, not against a running Live — smoke-test item 2.
- **Loop points and markers carry an ordering invariant.** Live requires
  start < end at all times, so writing a new brace one property at a time can
  pass through an invalid intermediate state (new start beyond the old end).
  Whether Live clamps or raises is unverifiable without Ableton (⚠️ smoke
  item 3) — but it doesn't need to be known: the setter reads the current
  values first and orders the two writes so the invariant holds throughout
  (see Part 4). Setters are fire-and-forget, so an in-Live raise would be
  *silent* — the ordering plus the read-back verification is what makes the
  write honest.

Everything else follows settled house patterns: single-object tools live in
`Handlers` and call `Transport` directly (no `%Command{}` — Registry is for
multi-step sequences like create-then-name); silent setters verify by
re-reading and echoing what Live actually applied (the `set_track_send`
precedent); type guards error cleanly instead of no-opping (the
`write_midi_notes` precedent); and nothing new goes into `Session.State` —
per-clip detail stays query-on-demand, per the standing clip-grid decision
([archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md),
roadmap #21).

## OSC contract

All addresses upstream, all already served by the fork at `priv/AbletonOSC`
(`clip.py` `properties_r`/`properties_rw`) and — except `looping` and
`gain_display_string`, both Part 1 — already in
[abletonosc-api-docs.md](abletonosc-api-docs.md). Getters reply
with the two indices echoed ahead of the bare value, which is exactly what
`Handlers.query_echoed/4` verifies. Setters never reply.

| Address | Request | Reply | Notes |
|---|---|---|---|
| `/live/clip_slot/get/has_clip` | `track_id, clip_id` | `track_id, clip_id, has_clip` | Existing `ensure_clip/3` guard |
| `/live/clip/get/is_midi_clip` | `track_id, clip_id` | `track_id, clip_id, is_midi_clip` | Type branch for audio-only properties |
| `/live/clip/get/name` | `track_id, clip_id` | `track_id, clip_id, name` | Reader only |
| `/live/clip/get/length` | `track_id, clip_id` | `track_id, clip_id, length` | Read-only property — there is no length setter, in Live or here |
| `/live/clip/get\|set/looping` | get: `track_id, clip_id` · set: `+ looping` | get: `track_id, clip_id, looping` | 1=on, 0=off. Docs row missing — Part 1 |
| `/live/clip/get\|set/loop_start` | set: `+ loop_start` (beats, float) | get: `+ loop_start` | Aliases `start_marker` while looping is off |
| `/live/clip/get\|set/loop_end` | set: `+ loop_end` (beats, float) | get: `+ loop_end` | Aliases `end_marker` while looping is off |
| `/live/clip/get\|set/start_marker` | set: `+ start_marker` (beats, float) | get: `+ start_marker` | Where playback begins on launch |
| `/live/clip/get\|set/end_marker` | set: `+ end_marker` (beats, float) | get: `+ end_marker` | Where a non-looping clip ends |
| `/live/clip/get\|set/launch_mode` | set: `+ launch_mode` (int) | get: `+ launch_mode` | 0=Trigger 1=Gate 2=Toggle 3=Repeat |
| `/live/clip/get\|set/launch_quantization` | set: `+ launch_quantization` (int) | get: `+ launch_quantization` | 0=Global 1=None 2=8 bars 3=4 bars 4=2 bars 5=1 bar 6=1/2 7=1/2T 8=1/4 9=1/4T 10=1/8 11=1/8T 12=1/16 13=1/16T 14=1/32 |
| `/live/clip/get\|set/legato` | set: `+ legato` (1/0) | get: `+ legato` | |
| `/live/clip/get\|set/velocity_amount` | set: `+ velocity_amount` (float 0–1) | get: `+ velocity_amount` | |
| `/live/clip/get\|set/gain` | set: `+ gain` (float 0–1, nonlinear) | get: `+ gain` | **Audio clips only** |
| `/live/clip/get/gain_display_string` | `track_id, clip_id` | `track_id, clip_id, string` | Audio only, read-only — the human-readable dB for `gain`. Docs row missing — Part 1 |
| `/live/clip/get\|set/warp_mode` | set: `+ warp_mode` (int) | get: `+ warp_mode` | Audio only. 0=Beats 1=Tones 2=Texture 3=Re-Pitch 4=Complex 6=Complex Pro (5 unused) |
| `/live/clip/get\|set/warping` | set: `+ warping` (1/0) | get: `+ warping` | Audio only |

Reading an audio-only property on a MIDI clip makes the Python callback raise
(`Clip` has no such attribute), which upstream swallows — no reply, a 2 s
guard timeout. Both tools therefore branch on `is_midi_clip` *before*
touching the audio-only set, and the setter rejects audio-only properties on
a MIDI clip with a real error (never a silent no-op, never a timeout burned
on a known answer).

## Tool granularity — one setter, one reader

The roadmap asked for the call: per-property tools vs. one
`set_clip_properties`. One setter + one reader, for three reasons:

- The audit's granular-by-object finding ([TOOL_AUDIT.md](TOOL_AUDIT.md) §01)
  cuts *against* polymorphic tools spanning objects, not against one tool
  owning one object's properties — its only merge candidate was three
  same-object toggles. Both new tools address exactly one object, the clip.
- The headline sentence — "loop the good two bars" — is one intent touching
  four properties (`looping`, `loop_start`, `loop_end`, `start_marker`).
  Per-property tools would burn four calls and re-open the ordering hazard
  on every one of them; one call lets the handler order the writes correctly
  once.
- `set_loop` is the in-house precedent: one tool, one object (the song
  loop), several optional properties.

The reader is separate from `get_clip_slots` deliberately: the grid tool
answers "what's where" across the whole session; this answers "what is this
one clip's playback setup" in ~14 targeted reads. Folding per-clip detail
into the grid would multiply its cost by tracks × scenes.

## Parts

### Part 1 — docs: add the missing `looping` and `gain_display_string` rows

**File:** [docs/abletonosc-api-docs.md](abletonosc-api-docs.md)

Add `/live/clip/get/looping` and `/live/clip/set/looping` rows to the Clip
API table (alongside the `loop_start`/`loop_end` rows, matching their
format): request `track_id, clip_id [, looping]`, reply
`track_id, clip_id, looping`, description "Clip loop on/off (1=on, 0=off)".
Also add `/live/clip/get/gain_display_string` (alongside the `gain` rows):
request `track_id, clip_id`, reply `track_id, clip_id, gain_display_string`,
description "Human-readable gain as dB string (audio clips only, read-only)"
— registered in `clip.py`'s `properties_r` but likewise never listed
(plan-review finding, 2026-07-29). Plain upstream rows — no Seshat-extension
marker; this is upstream code the docs simply never listed. This part goes
first because the docs are canonical and their absence already misled the
roadmap entry.

### Part 2 — `Seshat.Tools.Definitions`: two tools + one cross-reference

**File:** [lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex)

Append both tools next to the other clip tools. Draft descriptions (prompt
text for a model that can't see the code — index base, units, enums, the
looping-off aliasing, and the verify-the-echo instruction all belong here):

`get_clip_properties`:

> Read one clip's playback properties: clip type (MIDI/audio), name, length
> in beats, loop on/off and loop brace (loop_start/loop_end), play markers
> (start_marker/end_marker), launch mode and quantization, legato, velocity
> amount — plus gain (with its dB display value), warp mode, and warping for
> audio clips. Track and clip_slot are 0-based; slot N sits in scene N. All
> beat positions count from the clip's own start (beat 0). Use
> get_clip_slots first to find which slots hold clips, and this tool before
> set_clip_properties to see the current values — e.g. what length and loop
> brace Live inferred for a captured clip.

`set_clip_properties`:

> Set a clip's own loop brace, play markers, launch behavior, or (audio
> clips only) gain/warp. This is the clip's OWN loop — distinct from
> set_loop, which moves the song's global arrangement loop. Track and
> clip_slot are 0-based; slot N sits in scene N. All properties are
> optional — send only what you're changing, at least one. Positions are in
> beats from the clip's start. To loop a section: set looping true with
> loop_start/loop_end, and usually start_marker to the loop start so launch
> begins there — note loop_start/loop_end only act as the loop brace while
> looping is on (while off, Live treats them as the play start/end markers).
> To trim or extend a non-looping clip, set start_marker/end_marker. There
> is no direct length setter — length follows from the markers (or the loop
> while looping), and the reply echoes every value Live actually applied
> (each write is verified by re-read): check it matched the intent.
> launch_mode: 0=Trigger, 1=Gate, 2=Toggle, 3=Repeat. launch_quantization:
> 0=Global, 1=None, 2=8 bars, 3=4 bars, 4=2 bars, 5=1 bar, 6=1/2, 7=1/2T,
> 8=1/4, 9=1/4T, 10=1/8, 11=1/8T, 12=1/16, 13=1/16T, 14=1/32.
> velocity_amount is 0.0–1.0. Audio only — gain: nonlinear 0.0–1.0, trust
> the dB the reply echoes rather than the number; warp_mode: 0=Beats,
> 1=Tones, 2=Texture, 3=Re-Pitch, 4=Complex, 6=Complex Pro; warping: on/off.
> Audio-only properties on a MIDI clip are rejected with an error. Use
> get_clip_properties first to see current values.

Parameters:

- `get_clip_properties`: `track` (integer), `clip_slot` (integer), both
  required. Same wording as the other clip tools.
- `set_clip_properties`: required `track`, `clip_slot` (integers); optional
  `looping` (boolean), `loop_start`, `loop_end`, `start_marker`,
  `end_marker` (number, `minimum: 0`, beats), `launch_mode` (integer,
  `enum: [0, 1, 2, 3]`), `launch_quantization` (integer, `minimum: 0`,
  `maximum: 14`), `legato` (boolean), `velocity_amount` (number, 0.0–1.0),
  `gain` (number, 0.0–1.0), `warp_mode` (integer,
  `enum: [0, 1, 2, 3, 4, 6]`), `warping` (boolean). Each property's
  one-line description restates its unit/enum compactly.

Also amend `set_loop`'s description (currently "Turn looping on or off…") to
open with "the song's global loop" and point at `set_clip_properties` for a
clip's own brace — the two tools are now each other's most likely
mis-selection, and the audit already draws the distinction on both its
`set_loop` rows ([TOOL_AUDIT.md](TOOL_AUDIT.md) §02 gap table, §05
inventory), so the descriptions should state it on both sides too.

### Part 3 — `Seshat.Tools.Handlers`: `get_clip_properties`

**File:** [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex)

New `do_call/2` clause (above the catch-all), string keys only:

1. `ensure_clip(track, slot)` — existing guard; empty slot gets the existing
   "slot N is empty" error instead of fourteen timeouts.
2. `query_flag("/live/clip/get/is_midi_clip", …)` to pick the property set.
3. Read the common set via `query_echoed/4` with indices `[track, slot]`:
   `name`, `length`, `looping`, `loop_start`, `loop_end`, `start_marker`,
   `end_marker`, `launch_mode`, `launch_quantization`, `legato`,
   `velocity_amount`.
4. Audio clips additionally: `gain`, `gain_display_string`, `warp_mode`,
   `warping`. MIDI clips: skip — reading them would time out (see OSC
   contract).
5. Format a compact human-readable reply, enums decoded to their names,
   booleans as on/off, e.g.:

   ```
   Clip 'good two bars' — track 1, slot 0 — MIDI, 8.0 beats
   Loop: on, from beat 4.0 to 8.0 (4.0 beats)
   Play markers: start 0.0, end 8.0
   Launch: Trigger, quantization Global, legato off, velocity amount 0.0
   ```

   (audio clips get a second line: `Audio: gain -3.2 dB, warp on, mode
   Beats`). Decoding maps (`launch_mode`, `launch_quantization`,
   `warp_mode` value → name) live as module attributes shared with Part 4's
   echo.

Any `query_echoed` failure short-circuits with that property's error — the
existing `{:error, message}` plumbing and `@clip_index_hint` wording apply
unchanged. Reads are sequential single-value getters by design: the one
in-flight-query-per-address correlation hazard is what `query_echoed`
already handles, and the bulk `track_data` reply carries no index echo (see
the comment above `ensure_midi_track/1`).

### Part 4 — `Seshat.Tools.Handlers`: `set_clip_properties` + pure write plan

**File:** [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex)

The clause:

1. Split params into recognised property writes; reject an empty set
   ("nothing to set — pass at least one property") before touching the
   transport.
2. Static validation, also transport-free: `loop_start < loop_end` when both
   given, `start_marker < end_marker` when both given.
3. `ensure_clip(track, slot)`.
4. If any audio-only property (`gain`, `warp_mode`, `warping`) is present:
   `is_midi_clip` check; on a MIDI clip, error naming the offending
   properties ("gain/warp apply to audio clips; track N slot M holds a MIDI
   clip — nothing was set"). The `write_midi_notes` guard precedent: an
   explicit error, never a silent drop.
5. Read the current values needed to order and validate the paired writes:
   current `loop_start`/`loop_end` if either is being written, current
   `start_marker`/`end_marker` likewise (also feeds the "was → now" echo).
6. Compute the write list with a **pure, public, unit-tested** helper:

   ```elixir
   @doc since-silent-setters rationale…
   @spec clip_property_writes(current :: map(), changes :: map()) ::
           {:ok, [{String.t(), number()}]} | {:error, String.t()}
   def clip_property_writes(current, changes)
   ```

   Ordering rules it encodes (the invariant: start < end must hold after
   every individual OSC message, because Live may reject an inverted state
   and the rejection would be silent):
   - `looping` first, before any loop point — while looping is off the loop
     points alias the markers, so writing them before the toggle would move
     the wrong thing.
   - For each pair with both sides changing, given current `{s0, e0}` and
     target `{s1, e1}` (already validated `s1 < e1`): if `s1 >= e0` write
     end-then-start (both intermediate states valid), else start-then-end.
   - One side changing alone must be valid against the current other side:
     `s1 < e0` / `e1 > s0`, else an error that *names the current value*
     ("loop_start 16.0 is not before the current loop_end 8.0 — pass
     loop_end too to move the whole brace").
   - Scalars (`launch_mode`, `gain`, …) last, any order.
   - Value coercion: beats/gain/velocity_amount as floats (`/ 1.0`),
     enums as integers, booleans as `1`/`0` — the house wire conventions.
7. Send each write with `Transport.send_message("/live/clip/set/<prop>", [track, slot, value])`.
   Address strings stay inline literals (the `"/live/` greppability rule);
   the property list is small and closed, so a literal per property — a
   `case`/cond mapping property name → address — not interpolation.
8. Re-read every written property (`query_echoed`), plus
   `gain_display_string` when `gain` was written and `length` when any
   loop/marker property was, and build the echo from what Live *reports*,
   not what was sent: "Loop brace now 4.0–8.0 (was 0.0–16.0), looping on;
   clip length 4.0 beats". A re-read that comes back different from what was
   sent is reported as such, not hidden — that is the only place a silent
   in-Live rejection can surface.
9. `FollowCam.steer("set_clip_properties", %{track: track, slot: slot})` on
   success (Part 5).

`catch :exit` wraps the clause like `write_midi_notes`' — a transport death
mid-sequence reports which properties were already sent (the write list makes
that knowable) rather than blaming the indices.

### Part 5 — `Seshat.Tools.FollowCam`: steer to the clip

**File:** [lib/seshat/tools/follow_cam.ex](../lib/seshat/tools/follow_cam.ex)

Add `"set_clip_properties"` to the existing clip-steering clause
(`write_midi_notes`/`remove_notes`/`duplicate_clip`/`capture_midi`) — same
four messages, selection then panes. The judgment call, recorded: the module
doc says parameter tweaks don't steer, and a launch-quantization nudge is
arguably one — but the tool's headline use is reshaping a clip's audible
extent right after a capture, the moved brace in the note editor *is* the
confirmation (the exact validation-run finding the follow cam exists for),
and the steer target is the clip the user is already talking about, so the
jump-on-a-volume-nudge failure mode doesn't apply. Classify it as a write.
One line in the module doc's settled-decision paragraph so the rule text
stays true. (`get_clip_properties` is a read; reads never steer.)

### Part 6 — tests

**Files:**
[test/seshat/tools/definitions_test.exs](../test/seshat/tools/definitions_test.exs),
[test/seshat/tools/handlers_test.exs](../test/seshat/tools/handlers_test.exs),
[test/seshat/tools/follow_cam_test.exs](../test/seshat/tools/follow_cam_test.exs)

- Definitions count `49` → `51` (the deliberate tripwire).
  `Seshat.MCP.ToolsTest` parity and schema round-trip come free.
- `clip_property_writes/2` unit tests: looping-first ordering; end-first
  when the brace moves past the old end; start-first otherwise; the
  marker pair independently of the loop pair; single-sided writes validated
  against current values, error message naming the current value; boolean
  and enum coercion; scalars appended.
- `set_clip_properties` transport-free error paths through
  `Handlers.call/2`: no properties given; `loop_start >= loop_end` both
  given; `start_marker >= end_marker` both given. (Everything past the
  static checks reaches `Transport.query` — not testable, per the testing
  rules; that's the smoke list.)
- `FollowCam.calls/2`: `set_clip_properties` with `%{track: t, slot: s}`
  returns the four-message clip sequence; existing catch-all test keeps
  `get_clip_properties` returning `[]`.
- `mix precommit` green.

### Part 7 — docs: TOOL_AUDIT inventory

**File:** [docs/TOOL_AUDIT.md](TOOL_AUDIT.md)

Add both tools to the §05 inventory (Clips section, verdict Keep) and mark
the §02 "Per-clip properties" gap row ADDRESSED in the house strikethrough
style, noting what stays out (below). Update the at-a-glance tool count.
ROADMAP entry removal itself stays with `/ship`, per the skill.

## Testing

Covered pure (no Ableton): everything in Part 6 — definitions/schema parity,
the whole write-ordering decision (`clip_property_writes/2`), static
validation errors, follow-cam decisions.

Needs Ableton (`/smoke-test` additions — every setter here is
fire-and-forget, so only Live can confirm the writes land):

1. **The headline sentence:** capture or write an 8-beat clip, "loop beats
   4–8" → brace visibly moves in the note editor, playback loops the
   section, reply echoes 4.0–8.0 and the new length.
2. **Looping-off aliasing:** with looping off, `get_clip_properties` shows
   loop points tracking the markers; setting `looping` + points in one call
   produces the intended brace (write order held).
3. **Ordering/invalid states:** move a brace entirely past the old one in
   one call (end-first path) — lands correctly; single-sided invalid write
   errors with the current-value message and Live state is untouched.
4. **Audio clip:** set `gain` — echo shows a plausible dB from
   `gain_display_string`; change `warp_mode`/`warping` — visible in the clip
   view; `velocity_amount`/`legato` read and write without timeouts (⚠️ they
   are assumed present on audio clips).
5. **MIDI guard:** `gain` on a MIDI clip errors cleanly, nothing sent.
6. **Reader:** `get_clip_properties` on a freshly captured clip reports the
   length/brace Live inferred; on an audio clip includes the audio line; on
   an empty slot errors via `ensure_clip`.
7. **Follow cam:** a brace edit lands with the clip selected and the note
   editor open.

## Out of scope

- **`muted`, `color`/`color_index`, `ram_mode`, `position`, `pitch_coarse`/
  `pitch_fine`** — registered upstream but not this feature: mute/color are
  cosmetic-or-niche (roadmap #22 grab bag territory), `position` is
  redundant with `loop_start`, audio transpose (`pitch_*`) is musically real
  but its own small tool when a workflow asks (add to #22).
- **`/live/clip/duplicate_loop`** ("double the loop") — a method, not a
  property; useful someday, goes to the #22 grab bag, not here.
- **Promoting clip properties into `Session.State`** — stays with the
  standing query-on-demand decision (roadmap #21).
- **Arrangement-view clip properties** — Session view only, per the standing
  scope decision (ROADMAP "Deliberately not planned").
- **Clip-property listeners / live position following** — parameter
  listeners are deliberately not planned.

## Open questions

1. **Does Live clamp or raise on an inverted loop point?** (⚠️ Part 4 /
   Context.) Unresolvable without a running Live — setter errors are
   swallowed by upstream's callback, so even a smoke test only shows the
   *effect*. The plan makes the answer immaterial in normal operation:
   static validation plus current-value reads plus ordered writes keep every
   intermediate state valid, and the read-back echo surfaces any silent
   rejection that slips through. Smoke item 3 observes the behaviour for the
   record.
2. **Looping-off aliasing of `loop_start`/`loop_end`.** Stated by LOM
   documentation and assumed by the write order (looping first) and both
   descriptions; needs Live to confirm the fork's build behaves as
   documented. Smoke item 2. If it turns out wrong, the only change is
   softening two description sentences — the write order is correct either
   way.
3. **Are `velocity_amount`/`legato` present on audio clips?** Assumed yes
   (they sit in Live's Launch box for both clip types, and `clip.py` exposes
   them unconditionally). If wrong, reading them on an audio clip times out;
   the fix is moving them to the MIDI-only branch of the reader — two lines.
   Smoke item 4 settles it.
4. **`gain`'s curve and unity point.** Genuinely unknown without Live (the
   0–1 float's dB mapping is undocumented), and deliberately sidestepped:
   the tool never claims a mapping — the description says "nonlinear, trust
   the echoed dB" and the handler echoes `gain_display_string` after every
   gain write. No implementation decision depends on the curve.
