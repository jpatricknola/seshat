# Plan — `quantize_clip`: the most common MIDI cleanup

> **Archived 2026-07-31 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. `quantize_clip` lives in
> `Seshat.Tools.Definitions`/`Seshat.Tools.Handlers`, backed by the fork's
> already-shipped `/live/clip/quantize`; the corrected `GridQuantization`
> table it depends on is in `docs/abletonosc-api-docs.md` and the fork's
> `clip.py` comment. The one remaining follow-up — groove/swing — is
> "Groove amount" on [../ROADMAP.md](../ROADMAP.md).

Roadmap item "`quantize_clip` — the most common MIDI cleanup" (top of the queue
at time of writing). One new tool — `quantize_clip` — that snaps a MIDI clip's
notes toward a rhythmic grid with a strength amount, via the Live Object
Model's `Clip.quantize(grid, amount)`.

**No Python behaviour change.** The fork already ships `/live/clip/quantize`
(from upstream PR #198, taken into `abletonosc/clip.py`'s generic methods list
— see the fork's `SESHAT.md` under "Additions to upstream's code"), so the
feature itself is pure Elixir. Two caveats, both added after the 2026-07-31
measurements:

- The documented `GridQuantization` table **is wrong in every row** (see "OSC
  contract"). Correcting `abletonosc-api-docs.md` is part of this work, and the
  matching comment in the fork's `clip.py` is corrected with it — a
  comment-only submodule commit, so the two-commit dance and a reinstall apply
  ([osc.md](../../.claude/rules/osc.md)) even though no Python behaviour moves.
- A tripwire test (part 4) keeps an upstream merge from dropping the method
  silently.

## Context

The play-and-keep arc is three-quarters built: `capture_midi` keeps what the
user noodled, `record_clip`/`stop_recording` land a deliberate take, and
`get_clip_properties`/`set_clip_properties` shape the clip afterwards. What's
missing is the single most common thing a producer does to played MIDI next:
"tighten the timing." Today that takes a full `get_clip_notes` → decide →
`remove_notes` → `write_midi_notes` round trip by hand — many tool calls,
model-side beat math, and it reimplements arithmetic Live already does. The
roadmap entry records that read→snap→rewrite alternative as deliberately
rejected — zero install surface but worse results — and the work here only
strengthened the case, from an unexpected direction: an Elixir-side snap would
have had to hardcode grid arithmetic, and **every published description of
Live's grid enum turned out to be wrong** (see research point 2). Calling
Live's own quantize means never having to be right about that. The roadmap's
swing rationale is *not* repeated here — see research point 4 for why it is
unverified.

Research confirmed the roadmap entry's claims against the real sources:

1. **The address exists and never replies.** `abletonosc/clip.py` lists
   `"quantize"` in its generic methods list; `create_clip_callback` casts the
   two leading indices to int and passes the remaining params raw to
   `AbletonOSCHandler._call_method`, which calls `clip.quantize(grid, amount)`
   inside a try/except that **logs and swallows every exception** (deliberate
   upstream-style behaviour, kept by the fork so one bad message can't abort a
   queued sequence). Success, a bad grid value, and an old installed copy that
   predates the fork are all identical on the wire: silence. The tool's
   honesty therefore has to come from reading state back, exactly as
   `capture_midi` (grid snapshot diff) and `set_clip_properties` (per-write
   read-back) already do.
2. **The grid enum is the confusion hazard the roadmap flags, and it is worse
   than anyone thought — the documented table is simply false.** Measured
   against Live on 2026-07-31 (method and full table under "OSC contract"),
   `1/16` is **5**, not the documented `8`; `8` is a 1/32 grid; `9` is not a
   grid at all and does nothing; triplet grids exist at 3/4 and 6/7; and there
   are no bar-length or 1/2 grids anywhere in the valid range. The hazard is
   therefore not just "two integer codes for 1/16 in adjacent tools"
   (`launch_quantization` says `12`, the docs say `8`, Live means `5`) — it is
   that the docs, the fork's own code comment, and this plan's first draft all
   agreed with each other and all disagreed with the instrument. Part 1's
   **string enum** (`"1/16"`, `"1/8T"`, …) is what contains the damage: the
   integer never reaches the model, so the correction lives in one private
   function.
3. **Verification can reuse the note-reading plumbing wholesale.**
   `get_clip_notes` already turns `/live/clip/get/notes` replies into note
   maps (`parse_clip_notes/1` in
   [lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)), and the
   empty-slot / audio-clip guards (`ensure_clip/3`, `ensure_midi_clip/2`)
   exist. AbletonOSC processes datagrams in arrival order and
   `clip.quantize()` runs synchronously inside the callback, so a notes query
   sent after the quantize message reads the post-quantize state — the same
   ordering argument `capture_midi`'s tempo re-read and `delete_device`'s
   count re-read already rely on.
4. **Triplet grids do exist** — 1/8T and 1/16T, measured. The docs' and the
   fork comment's "there are no triplet grids: swing comes from the song's
   `swing_amount`, which quantize honours" is wrong in its first clause, so the
   tool offers `"1/8T"` and `"1/16T"`. Its second clause is **unverified and
   deliberately not relied on**: nothing in this work tested whether
   `swing_amount` colours the result, and the bridge exposes no
   `swing_amount` address to set it with (`grep swing priv/AbletonOSC/abletonosc/`
   finds only that comment). So the description no longer advertises swing
   handling. If it matters later it is a smoke-test question with a manual
   swing setting, not a claim to inherit from a comment that was wrong about
   the sentence it shares.

## OSC contract

| Address | Args sent | Reply | Notes |
|---|---|---|---|
| `/live/clip/quantize` | `track_id (int), clip_id (int), grid (int, GridQuantization), amount (float 0.0–1.0)` | **none, ever** | Fork-only (upstream PR #198 taken into `clip.py`). Exceptions inside the callback are logged in Live and swallowed — silence is also what success looks like |
| `/live/clip_slot/get/has_clip` | `track_id, clip_id` | `track_id, clip_id, has_clip` | Guard (existing `ensure_clip/3`) |
| `/live/clip/get/is_midi_clip` | `track_id, clip_id` | `track_id, clip_id, is_midi_clip` | Guard (existing `ensure_midi_clip/2`) |
| `/live/clip/get/name` | `track_id, clip_id` | `track_id, clip_id, name` | So the reply can speak music ("Quantized 'Keys' …") |
| `/live/clip/get/notes` | `track_id, clip_id` (no range args = whole clip) | `track_id, clip_id, [pitch, start_time, duration, velocity, mute] * n` | Read before and after the quantize; the diff is the verification and the reply's content |

`GridQuantization` mapping — **measured against Live on 2026-07-31, because the
documented table is wrong**:

| Enum int | Actual grid | Enum int | Actual grid |
|---|---|---|---|
| 0 | no grid (nothing moves) | 5 | **1/16** (0.25 beat) |
| 1 | 1/4 (1.0 beat) | 6 | 1/16 triplet (1/6 beat) |
| 2 | 1/8 (0.5 beat) | 7 | 1/16 triplet (1/6 beat) |
| 3 | 1/8 triplet (1/3 beat) | 8 | 1/32 (0.125 beat) |
| 4 | 1/8 triplet (1/3 beat) | ≥9 | **invalid — nothing happens at all** |

[abletonosc-api-docs.md](../abletonosc-api-docs.md) and the comment in the fork's
`clip.py` both claim `1=8 bars … 5=1/2, 6=1/4, 7=1/8, 8=1/16, 9=1/32`. Every
one of those rows is false. Had the plan shipped as first written, its string
enum would have mapped `"1/16"` to `8` — a **1/32** grid — `"1/8"` to `7`, a
**1/16 triplet** that swings a straight part, and `"1/32"` to `9`, which does
nothing whatsoever while the tool reports success. That is precisely the silent
wrong-grid failure this tool exists to prevent, arrived at by trusting the
documentation instead of the instrument.

Three consequences for the tool's own enum:

- **There is no `1/2` grid and there are no bar-length grids.** Nothing in
  0–8 is coarser than a 1/4 note, so `"1/2"`, `"1 bar"`, `"2 bars"`, `"4 bars"`
  and `"8 bars"` cannot be offered — there is no integer to send for them.
- **Triplet grids exist**, at 3/4 and 6/7. The docs' "there are no triplet
  grids" is exactly backwards: triplets are reachable, and a triplet quantize
  is only reachable this way.
- **3 and 4 are duplicates, as are 6 and 7.** Reproduced across separate rounds
  and both meters, five probe notes each. Reason unknown; harmless, since the
  tool only ever sends the lower of each pair.

Measurement method, so this is re-checkable rather than folklore: five notes at
0.09, 1.37, 1.9, 5.2 and 10.4 beats, chosen so that every candidate grid
(straight, triplet, and bar-length) produces a distinct set of landing
positions; one clip per enum value; `amount` 1.0; read back with
`get_clip_notes`. Run once in **6/8** and again in **4/4** — the results were
identical, so **the mapping is not meter-dependent** and a static table in the
handler is sound.

## Numbered parts

### 1. Define the tool — `lib/seshat/tools/definitions.ex`

Append to `@tools`:

```elixir
%{
  name: "quantize_clip",
  description:
    "Quantize a MIDI clip's notes toward a rhythmic grid using Live's own " <>
      "quantize — one call replaces the read→remove→rewrite dance, and a " <>
      "single undo reverses it. Track and " <>
      "clip_slot are 0-based; slot N sits in scene N. grid is the note value " <>
      "to snap to — \"1/16\" is the usual choice for played parts, and the " <>
      "T values are triplet grids for shuffled or triplet-feel playing that " <>
      "a straight grid would flatten. Only note starts move: a note keeps " <>
      "its length unless the move lands it on another note of the same " <>
      "pitch, which merges the pair. " <>
      "amount is how far each note moves toward the grid: 1.0 " <>
      "lands exactly on it, which sounds mechanical on a played take; " <>
      "0.5–0.8 tightens the timing while keeping the human feel — start " <>
      "around 0.5 after capture_midi or record_clip, listen, and repeat or " <>
      "undo. The reply reports how many notes moved. MIDI clips only: an " <>
      "audio clip is rejected with an error, not warped.",
  parameters: %{
    type: "object",
    properties: %{
      "track" => %{type: "integer", minimum: 0, description: "0-indexed track number"},
      "clip_slot" => %{type: "integer", minimum: 0, description: "0-indexed scene/clip slot"},
      "grid" => %{
        type: "string",
        enum: ["1/32", "1/16T", "1/16", "1/8T", "1/8", "1/4"],
        description:
          "Note value to quantize to. \"1/16\" suits most played parts. " <>
            "The T values are triplet grids — use them for parts played in " <>
            "triplet or shuffle feel, which a straight grid would flatten. " <>
            "Grids coarser than 1/4 are not available."
      },
      "amount" => %{
        type: "number",
        minimum: 0.0,
        maximum: 1.0,
        description:
          "Quantize strength: 1.0 = exactly on the grid (mechanical), " <>
            "0.5–0.8 = tightened but still human"
      }
    },
    required: ["track", "clip_slot", "grid", "amount"]
  }
}
```

Decisions folded in, so they don't reopen during implementation:

- **`grid` is a string enum, not the raw integer** — and the measurement above
  turned this from a nicety into the thing that saves the tool. The house
  precedent for Live enums is an integer with the mapping in the description
  (`launch_quantization` in `set_clip_properties`), which would have put a
  *documented-but-false* integer table in front of the model:
  `launch_quantization`'s 1/16 is `12`, the docs' `GridQuantization` 1/16 is
  `8`, and the real one is `5`. With a string enum the model never sees an
  integer, so correcting the table is a one-line change in one private function
  rather than a re-education of every caller. `create_track`'s `track_type` is
  the string-enum precedent; `Seshat.Tools.Validation` and `MCP.Schema` both
  already handle `enum` (validation_test and the Peri `{:enum, values}`
  branch), so nothing new is needed to enforce it.
- **`amount` is required, not defaulted.** Live's own dialog makes you choose a
  strength; defaulting to 1.0 would make the mechanical-sounding full quantize
  the silent default — the opposite of what the roadmap says the tool should
  teach. Forcing the parameter forces the musical decision, and the
  description says where to start.
- The description deliberately repeats the "0-based, slot N sits in scene N"
  phrasing of the other clip tools, and routes audio clips away instead of
  promising warp-marker behaviour nobody has verified (see Out of scope).

### 2. Handle it — `lib/seshat/tools/handlers.ex`

One `do_call/2` clause, Transport-direct (single logical operation; `%Command{}`
/ Registry stays for the three multi-step sequences it owns). Shape:

```elixir
defp do_call("quantize_clip", %{
       "track" => track,
       "clip_slot" => slot,
       "grid" => grid,
       "amount" => amount
     }) do
  with :ok <- reject_zero_amount(amount),           # 0% strength: nothing sent
       :ok <- ensure_clip(track, slot),
       :ok <- ensure_midi_clip(track, slot),
       {:ok, clip_name} <- ...,                      # /live/clip/get/name via query_echoed
       {:ok, before_notes} <- read_all_notes(track, slot),
       :ok <- check_has_notes(before_notes, ...),    # empty clip: report, send nothing
       :ok <- send_quantize(track, slot, grid, amount),
       {:ok, after_notes} <- read_all_notes(track, slot) do
    FollowCam.steer("quantize_clip", %{track: track, slot: slot})
    {:ok, format_quantize_result(track, slot, clip_name, grid, amount, before_notes, after_notes)}
  else
    {:error, reason} when is_binary(reason) -> {:error, reason}
    {:error, reason} -> {:error, inspect(reason)}
  end
catch
  :exit, _ -> {:error, "Lost contact with the OSC transport while quantizing ..."}
end
```

Specifics:

- **`send_quantize/4`** maps the grid string to its enum int
  (`grid_quantization/1`, one clause per string so the mapping is greppable
  and exhaustively testable) — using the **measured** table, i.e.
  `"1/4" → 1`, `"1/8" → 2`, `"1/8T" → 3`, `"1/16" → 5`, `"1/16T" → 6`,
  `"1/32" → 8`, with a comment saying these were verified against Live on
  2026-07-31 and that `abletonosc-api-docs.md` disagreed and was wrong — and
  sends
  `Transport.send_message("/live/clip/quantize", [track, slot, grid_int, amount / 1.0])`.
  The `/ 1.0` forces float encoding — `getattr(clip, "quantize")(*params)`
  passes OSC-decoded values straight through, and an int32 `1` reaching Live
  where a float is expected is not a risk worth taking for free. The address
  is a string literal (the `"/live/` greppability rule).
- **Verification is a before/after note diff, not trust.** `read_all_notes/2`
  queries `/live/clip/get/notes` with no range args (Python defaults to the
  whole clip) and reuses `parse_clip_notes/1`. It **checks the echoed track and
  slot indices and reissues once on mismatch**, following `read_device_names/2`
  rather than `get_clip_notes`'s destructure — that clause discards `_t, _s`
  ([handlers.ex:1866](../../lib/seshat/tools/handlers.ex#L1866)) and inherits the
  reply-correlation hazard `query_echoed/5` exists to blunt. It can't ride
  `query_echoed/4` for the same reason `read_device_names/2` can't:
  `unwrap_payload/1` reads single-value payloads and this reply is a whole
  list. Know what the check does and does not buy, and say so in the comment:
  it catches a *cross-clip* straggler (a notes query abandoned by an earlier
  timeout — plausible here, since a truncated oversized reply surfaces as a
  timeout, see open question 4) and nothing else. The hazard specific to this
  tool is two identical back-to-back queries: a late or duplicate answer to the
  *before* read satisfying the *after* read carries the same indices, passes any
  echo check, and reads as "nothing moved". Only the hedged nothing-moved
  wording stands against that — don't describe the echo check as closing it.
  The diff is multiset-style —
  `moved = before -- after` — deliberately **not** paired note tracking, and
  the measurements confirm why. Live's collision handling was observed
  directly (2026-07-31): two same-pitch notes landing on the *same* grid point
  **merge into one**, the later note's velocity surviving, so the count
  shrinks; two same-pitch notes landing on *different* points that now overlap
  leave the count alone but **trim the earlier note's duration** to end where
  the later one starts (0.5 → 0.25 beats, measured). Paired tracking would
  have to model both, and would still be guessing; a multiset diff reports
  both correctly as "changed". Count is therefore allowed to change and the
  reply states it when it does. No
  Elixir-side "was it off-grid?" math — modelling target positions here is
  exactly the beat math this tool exists to retire, and after the enum finding
  it is also the last thing that should be duplicating Live's own arithmetic.
- **Reply drafts** (the model reads these to decide what to do next):
  - Moved: `Quantized 'Keys' (track 1, slot 0): 14 of 23 notes moved toward
    the 1/16 grid at 60% strength. Listen back — undo reverses it if the feel
    went stiff.`
  - Nothing moved: `Quantize sent, but no note changed — the clip may already
    sit on the 1/16 grid at this strength. If the timing audibly didn't
    change, the installed AbletonOSC may predate /live/clip/quantize: run
    mix abletonosc.install and restart Live.` (The second half matters: this
    is a fork-only method dispatched with no reply, so a stale Remote Scripts
    copy is indistinguishable from an already-tight clip. This mirrors
    `@return_extension_hint`'s reasoning, but can't reuse it verbatim — here
    silence is *normal*, so the hint attaches to the no-change case instead
    of a timeout.)
  - Notes merged: `Quantized 'Hats' (track 2, slot 1): 9 of 11 notes moved
    toward the 1/16 grid at 100% strength, and 2 notes of the same pitch
    landed on the same spot and were merged into one — the clip now has 10
    notes. Undo restores both.` Wording is now measured fact, not a hedge:
    same-point collisions merge (later velocity wins) and post-move overlaps
    trim the earlier note. Say which happened when the count moves.
  - No notes: `The clip in slot 0 on track 1 has no notes to quantize.` —
    detected from the *before* read, quantize never sent.
  - Zero strength: `amount 0 is 0% strength, which cannot move any note — try
    0.5 to tighten the timing while keeping the feel.` Sent nowhere: the
    handler returns before the guards, like the no-notes case. This is the
    same argument that keeps `no_grid=0` out of the grid enum — an input that
    provably does nothing is a trap, not an option — and it has to live in the
    handler because `Seshat.Tools.Validation` reads only `:minimum`
    ([validation.ex:124](../../lib/seshat/tools/validation.ex#L124)), with no
    `exclusiveMinimum` branch to reject 0.0 at the schema. Without this the
    zero case falls through to the nothing-moved reply and tells the user their
    AbletonOSC install may be stale, which at 0% strength is a fabrication.
- **Guards use the existing helpers** and therefore `@guard_timeout` and
  `@clip_index_hint`; the two notes reads use the default 5s query timeout,
  matching `get_clip_notes`. The `catch :exit` clause reports honestly that
  the quantize may or may not have been applied (the `set_clip_properties`
  precedent: after the send is on the wire, "nothing was done" would be a
  lie).
- The name read goes through `query_echoed/4` like every other single-value
  clip read (reply-correlation hazard); the notes reads follow
  `get_clip_notes`'s existing destructure. If the name read fails, proceed
  with the indices-only wording rather than failing the tool — the name is
  garnish.

### 3. Follow cam — `lib/seshat/tools/follow_cam.ex`

Add `"quantize_clip"` to the clip-write clause (the
`write_midi_notes`/`remove_notes`/`set_clip_properties`/… group): it is a
write to clip contents, and the notes visibly snapping in the note editor *is*
the confirmation. No new addresses, no new clause shape.

### 4. Tripwire for the fork method — `test/seshat/osc/vendored_addresses_test.exs`

`/live/clip/quantize` is invisible to the existing vendored-address checks by
construction: `clip.py` registers its addresses in a loop
(`"/live/clip/%s" % method`), so the literal-grep `registered_addresses/1`
can't see it, and `/live/clip/` is not a vendored prefix, so the Elixir-side
literal isn't swept into `used_addresses` either. Losing `"quantize"` from the
methods list in an upstream merge would be exactly as silent as the
`duplicate_clip_to` rename hazard the docs already record.

Add a small describe block in the grep style of "the base-class listener fix":
assert `File.read!("priv/AbletonOSC/abletonosc/clip.py")` contains the methods-
list entry. **Match the double-quoted literal `"quantize"`, not the bare word**
— `quantize` appears three times in `clip.py` (lines 72 and 79 are prose
comments about the method, line 82 is the list entry), so a grep for the bare
word passes even after the entry is deleted, which is precisely the regression
this test exists to catch. The quoted form appears exactly once and is
format-stable. Failure message points at `SESHAT.md`'s divergence entry and
this tool. Do
**not** try to fold `clip.py` into `@handler_files` — its loop registration
would make `registered_addresses/1` under-report and trip the docs test
falsely.

### 5. Tests

- **`test/seshat/tools/definitions_test.exs`** — bump the count assertion
  `53 → 54`. (Its existing integer-minimum and enum sweeps then cover the new
  schema by construction.) Add `quantize_clip` to the hand-maintained
  expected-name list, and while there add the three tools already missing from
  it — `capture_midi`, `get_clip_properties`, `set_clip_properties` — so the
  list is an inventory again rather than a spot-check that silently fell behind
  the count assertion.
- **`test/seshat/tools/validation_test.exs`** — two cases in the existing
  style: a `grid` outside the enum is rejected naming the parameter, and
  `amount: 1.5` is rejected with the bound. Use **`"1/2"`** as the invalid
  grid, not `"1/16T"` — the triplet grids are real and valid now, and `"1/2"`
  is both a plausible model guess and a value Live genuinely cannot do, which
  is exactly the case worth pinning.
- **`test/seshat/tools/handlers_test.exs`** — pure pieces only (nothing may
  reach `Transport.query/3`): `grid_quantization/1` maps all six strings to
  `1, 2, 3, 5, 6, 8`. This test is the guardrail on the enum finding, so its
  comment must say the ints were **measured against Live on 2026-07-31** and
  that `abletonosc-api-docs.md` said otherwise and was wrong — a future reader
  comparing code to docs will otherwise "fix" this back into silence.
  `format_quantize_result/7` covers moved / nothing-moved / zero-strength /
  merged / trimmed wording. Expose the helpers the way `format_browser_items/2`
  and friends already are for exactly this purpose.
- **The wire assertion — the one test this tool cannot ship without.** Expose
  `send_quantize/4` and, with `Transport` and `Seshat.Test.OSCSink` started,
  assert `{:osc_out, "/live/clip/quantize", [0, 0, 5, 0.5]}` for grid
  `"1/16"` — note the `5`. This is safe at
  this layer and does not break the no-`Transport.query/3` rule:
  `send_message/2` is fire-and-forget, so the guards and notes reads are never
  entered. It is also the only check that can catch anything here — the address
  never replies, so a typo'd address or a swapped grid/amount argument order
  passes `grid_quantization/1`, passes `format_quantize_result/7`, passes the
  Python tripwire (which only proves `"quantize"` is still registered), and
  fails silently in Live. [testing.md](../../.claude/rules/testing.md) asks for
  wire assertions over reply strings for exactly this reason; a send-only
  address is the case it was written for.
- **`test/seshat/tools/follow_cam_test.exs`** — `calls("quantize_clip", %{track: t, slot: s})`
  returns the clip-write steering sequence.
- **MCP parity** (`Seshat.MCP.ToolsTest`) is generated coverage — no work, but
  it's the check that the string enum survives Peri conversion.

### 6. Bookkeeping

- **`docs/TOOL_AUDIT.md`** — add `quantize_clip` to the inventory table with a
  verdict, and drop the "Quantize notes" row from the coverage-gap table.
- **`.claude/skills/smoke-test/SKILL.md`** — its "If the change touches an
  address with no tool yet" section currently names `/live/clip/quantize` as
  tool-less and drives it by raw `python3` OSC
  ([SKILL.md:78–98](../../.claude/skills/smoke-test/SKILL.md#L78-L98)). Move the
  quantize checks into the normal MCP flow, driven through `quantize_clip`
  (`undo` then amount 0.5 moves notes halfway; before/after note counts match
  the reply) — and leave only browser preview in the raw-OSC section. Leaving
  it would tell the next smoke run to bypass the tool being smoke-tested.
  **Its raw-OSC snippet is also actively wrong** and must not simply be moved:
  its comment reads `# track 0, clip 0, 1/16, full` for grid `8`, which is a
  1/32 grid, and its prose says "Grid `8` is sixteenths — if it lands on half
  notes, the handler took the wrong enum". Both encode the false table. Delete
  them with the section rather than carrying them forward.
- **`docs/abletonosc-api-docs.md` — ✅ already corrected (2026-07-31).** Every
  row of the published `GridQuantization` table was wrong, and it is the
  canonical file the OSC rules send everyone to before touching an address, so
  it was fixed at measurement time rather than left to ship with the tool: the
  measured table, the method behind it, and the contradicted claims are now
  recorded there. Nothing left to do here — but read it, don't re-derive it.
- **The fork's `priv/AbletonOSC/abletonosc/clip.py` comment — still to do,
  and it is the last copy of the false table.** Lines 74–79 spell the wrong
  enum out in full (`5 g_half  6 g_quarter  7 g_eighth  8 g_sixteenth /
  9 g_thirtysecond`, then "so sixteenths is 8. There are no triplet grids —
  swing comes from the song's swing_amount, which quantize honours"). Replace
  the enum listing with the measured table, drop the triplet claim, and mark
  the swing sentence unverified.

  **Do it in the implementation commit, not before.** Unlike the docs fix,
  this one is not free: `priv/AbletonOSC` is a submodule, so it costs the full
  sequence in [osc.md](../../.claude/rules/osc.md) — `git -C priv/AbletonOSC
  checkout master` first, commit and push inside the submodule, then
  `git add priv/AbletonOSC` from the root **in the same Seshat commit as the
  Elixir side** — plus `mix abletonosc.install` and a Live restart so the copy
  Live actually loads matches the pin. Nothing here changes Python
  *behaviour*, so the reinstall is only about keeping the installed copy and
  the pin honest.

  Worth the ceremony rather than skipping: it is the upstream source the
  docs and this plan both inherited the error from, it sits three lines above
  the methods-list entry part 4's tripwire greps, and a wrong comment left
  next to a right implementation is how someone "corrects" the handler back
  into silence six months from now.
- No change to `Seshat.Instructions` (everything the model needs rides in the
  description — the 2,048-char budget stays untouched), no change to
  `Session.State` (nothing here is read repeatedly).

## Testing

Covered pure (no Ableton): definitions count and schema sweeps, validation of
grid/amount, the grid-string → enum-int mapping, the outgoing address and
argument order asserted at the wire through `OSCSink`, reply formatting for
every outcome, follow-cam steering, MCP schema parity.

Needs `/smoke-test` with Ableton open (nothing in `mix test` executes the
Python or the Live API):

Items 1, 2 and 5 below were **already run on 2026-07-31** by raw OSC while
answering the open questions — the numbers are in this doc. They stay on the
list because none of them has yet been run *through the tool*, which is where
the string→int mapping, the diff and the reply wording actually get exercised.

1. Quantize a played clip at `"1/16"`, amount 1.0 — notes land on the grid in
   the editor, reply counts match what visibly moved. **Check the landing
   positions are 1/16ths (0.25-beat spacing) and not 1/32nds**: that single
   observation is what caught the enum error, and it is the regression test for
   ever "fixing" the table back toward the docs.
2. Partial amount (0.5) — notes move toward but not onto the grid; reply still
   counts them. (Measured: linear — a note at 1.37 with target 1.25 landed at
   1.31.)
3. Already-quantized clip — "no note changed" reply, no false install warning
   confusion.
4. Each triplet grid (`"1/8T"`, `"1/16T"`) on a straight part — notes land on
   thirds/sixths of a beat, confirming the tool reaches the triplet values the
   docs claimed did not exist.
5. Full quantize stacking two same-pitch notes — count-change wording fires.
   (Measured: same-point collision merges to one note keeping the *later*
   velocity; a post-move overlap instead trims the earlier note's duration.)
6. Audio clip — clean rejection from `ensure_midi_clip`, no warp markers moved.
7. `undo` after a quantize restores the take in one step.
8. A clip in a non-4/4 meter — the mapping measured identical in 6/8 and 4/4,
   so this is a cheap confirmation that nothing meter-dependent crept in.

## Out of scope

- **Audio-clip quantize (warp markers).** The LOM's `Clip.quantize` reportedly
  aligns warp markers on audio clips, but nothing verifies that here, the
  notes-diff verification is meaningless for audio, and the play-and-keep arc
  is about MIDI. The tool rejects audio clips explicitly. If a real workflow
  wants it, it's a new roadmap entry with its own verification design.
- **Per-pitch quantize** (`Clip.quantize_pitch` — e.g. "just tighten the
  hi-hats"). Real Live API, real use case, not in the roadmap entry; stays on
  the roadmap's grab-bag if wanted.
- **Groove amount** ("make it swing") — its own roadmap item, next in the arc.
- **Elixir-side snap fallback** — rejected in the roadmap entry; recorded
  there deliberately, not resurrected here.

## Open questions

**All three behavioural questions were answered against Live on 2026-07-31**,
before implementation, by driving `/live/clip/quantize` with raw send-only OSC
and reading back with `get_clip_notes`. Answers are recorded here; the design
changes they forced are already folded into the parts above. Nothing below is
still open.

1. **✅ Does `Clip.quantize` move note starts only, or also durations/ends?**
   **Starts only.** Every note in every probe kept its exact duration —
   including deliberately non-grid lengths (0.43 and 0.37 beats) whose *ends*
   sat off-grid and stayed there. The two-arg LOM call does not touch note
   ends. **One exception, and it is not end-quantization**: when the move
   creates a same-pitch overlap, Live trims the earlier note so it ends where
   the later one begins (0.5 → 0.25 beats, measured). So the reply may
   legitimately report a duration change, but only as collision fallout.
2. **✅ What does Live do with same-pitch notes stacked by a full quantize?**
   **Merge, keeping the later note.** Two E4s at 2.02 and 2.10 quantized to
   1/16 both landed on 2.0 and came back as **one** note carrying the *second*
   note's velocity (110, not 100). The count shrinks. Distinct from the
   overlap case in Q1: same landing point merges, different landing points
   with overlapping tails trims. The count-changed wording now states which.
3. **✅ Can a sub-precision move read back as unchanged?** **No, not at any
   strength worth worrying about.** A note at 3.02 quantized with `amount`
   0.01 — a move of 0.0002 beats — read back as 3.0198, exactly the linear
   prediction. Amount is plain linear interpolation toward the target
   (`new = old + amount × (target − old)`, confirmed again at 0.5: 1.37 → 1.31
   for a 1.25 target), and the read-back resolves far finer than any move a
   user would ask for. The hedge in the nothing-moved reply stays, but it is
   now insurance rather than a known gap.
4. **Very large clips share `get_clip_notes`'s existing datagram ceiling.** A
   notes reply approaching the transport's 64KB socket buffer (~2,000 notes)
   truncates and surfaces as a timeout — pre-existing, shared with
   `get_clip_notes`, and not made worse here (two reads instead of one just
   hits the same wall twice). Not really open — recorded so the implementer
   doesn't discover it and widen scope; if it ever bites, the fix (ranged
   reads) belongs to the notes tools as a family.
