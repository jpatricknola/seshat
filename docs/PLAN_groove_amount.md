# Plan — Groove amount: "make it swing"

Roadmap item "Groove amount — \"make it swing\"". Two new tools —
`set_groove_amount` and `set_swing_amount` — plus both values mirrored into
`Seshat.Session.State`, so `get_session_state` is the read side the roadmap's
"read/set" asks for.

**One-line Python half.** The roadmap entry assumed this was pure upstream —
for `groove_amount` it is, but research showed the item as literally scoped
cannot deliver its own title (see Context), and the property that *can* —
`Song.swing_amount` — is not exposed by AbletonOSC. Adding it is one line in
the fork's [abletonosc/song.py](../priv/AbletonOSC/abletonosc/song.py)
(`properties_rw` generates get/set/listen handlers per entry), which lands as
a submodule commit plus a pin bump here, puts `mix abletonosc.install` and a
Live restart on the user, and is executed by nothing in `mix test` — its
behavioural verification is `/smoke-test` by construction.

## Context

The play-and-keep arc's editing vocabulary ends at quantize; this item is the
humanize/swing leg. Research against the Live Object Model reference
(docs.cycling74.com apiref, Song object) reshaped the obvious approach:

1. **`groove_amount` alone cannot "make it swing".** The LOM describes it as
   "the groove amount from the current set's groove pool (0. - 1.0)" — a
   *scaler* over grooves already assigned to clips. (That stated range is
   wrong, or at least partial; the real one is 0.0–1.3, established under
   [Evidence](#evidence-live-12-suites-own-scripts).) A clip with no groove
   assigned is untouched at any amount, and Seshat cannot assign grooves:
   `Clip.groove` is a LOM object AbletonOSC can't serialize (commented out in
   the fork's [abletonosc/clip.py](../priv/AbletonOSC/abletonosc/clip.py) TODO
   list — "Infered arg_value type is not supported"). In a session where the
   user hasn't dragged a groove on by hand, the roadmap's single property is a
   knob wired to nothing.
2. **`Song.swing_amount` is the knob the arc actually needs.** LOM: float,
   get/set/observe, 0.0–1.0, "affects MIDI Recording Quantization and all
   direct calls to `Clip.quantize`". That is precisely the played-MIDI
   cleanup flow: set the swing, then `quantize_clip`
   ([archive/PLAN_quantize_clip.md](archive/PLAN_quantize_clip.md), shipped
   2026-07-31, ahead of this plan) —
   and the swing rides record quantization for future takes too. Our own
   docs already point at it: the GridQuantization note in
   [abletonosc-api-docs.md](abletonosc-api-docs.md) and the fork's `clip.py`
   comment both say "swing comes from the song's `swing_amount`, which
   `quantize` honours" — but no OSC address serves it, so today the model
   would be directed toward a dial only the user's mouse can reach.
3. **Both are plain listenable song scalars**, exactly like `tempo`:
   `properties_rw` entries get `/get`, `/set`, `/start_listen`,
   `/stop_listen` generated, `_start_listen` pushes the current value on
   subscription, and pushes land on the same `/live/song/get/<prop>` address
   the mirror already pattern-matches. So the read side is the house pattern:
   mirror both in `Session.State`, render them in `get_session_state`'s song
   line, add no getter tool ("a dedicated getter would duplicate the
   mirror").
4. **Setters are silent and swallow rejection** (`_set_property` logs and
   swallows Live API exceptions; a set never replies). Same posture as
   [PLAN_set_time_signature.md](PLAN_set_time_signature.md): schema bounds
   make invalid values unrepresentable, the setter stays fire-and-forget per
   [.claude/rules/osc.md](../.claude/rules/osc.md), and the listener echo into
   the mirror is the verification channel.

So the plan delivers both knobs, each honest about what it does: swing for
"make it swing" on plain MIDI (with quantize as the applicator), groove
amount for scaling grooves the user has assigned — with descriptions that
route the model correctly between them instead of letting it promise swing
from a no-op.

## OSC contract

| Address | Args sent | Reply | Notes |
|---|---|---|---|
| `/live/song/set/groove_amount` | `amount (float 0.0–1.3)` | **none, ever** | Upstream (`properties_rw` in `song.py`). `_set_property` swallows rejections — silence is also success |
| `/live/song/get/groove_amount` | — | `[amount (float)]` | Upstream. Also the push address for the listener; the mirror consumes both identically |
| `/live/song/start_listen/groove_amount` | — | push on `/live/song/get/groove_amount`, immediately and on change | Upstream. Subscribed by `Session.State`'s existing property loop |
| `/live/song/set/swing_amount` | `amount (float 0.0–1.0)` | **none, ever** | ⚠️ **Fork-added by this plan** — one `properties_rw` entry generates all four handlers |
| `/live/song/get/swing_amount` | — | `[amount (float)]` | ⚠️ Fork-added, as above |
| `/live/song/start_listen/swing_amount` | — | push on `/live/song/get/swing_amount` | ⚠️ Fork-added, as above (`stop_listen` generated too; unused directly) |

Both values go on the wire as floats (`amount / 1.0`, the `set_tempo`
coercion) — `setattr` on a float LOM property should not be handed an int32.

**Ranges, settled against Live 12 Suite's own shipped code** (see
[Evidence](#evidence-live-12-suites-own-scripts)) rather than the apiref's
"0.0 - 1.0", which understates `groove_amount`:

- **`groove_amount`: 0.0–1.3.** `1.0` is exactly 100% on the Groove Pool
  dial and the dial's 130% is `1.3` — Ableton's own Move script clamps the
  property to `GROOVE_AMOUNT_MAX = 1.3125` and renders it as
  `round(min(groove_amount, 1.3) * 100)` percent. Capping the schema at 1.0
  would put the top 30% of Live's real range out of reach for no reason.
- **`swing_amount`: 0.0–1.0** (the apiref range, kept). Worth knowing:
  Push's own swing encoder clamps the property into **0.0–0.5**, so half the
  LOM range is territory Ableton's hardware never drives into. That belongs
  in the description as guidance, not in the schema as a bound — 1.0 is the
  documented range and inventing a tighter cap than Live enforces is the
  kind of thing that gets "fixed" back later.

## Numbered parts

### 1. Fork: expose `swing_amount` — `priv/AbletonOSC/abletonosc/song.py` + `SESHAT.md`

Add `"swing_amount",` to `properties_rw` (alphabetical slot: after
`"signature_numerator"`, before `"tempo"`). That single line registers all
four addresses via the existing generation loop — no new handler code.

Record it in the fork's `SESHAT.md` under **"Additions to upstream's code"**
(the `clip.py` `quantize` entry is the template: what was added, why —
"`set_swing_amount`/the session mirror need it; upstream exposes
`groove_amount` but not `swing_amount`" — and the LOM reference).

This is the two-commit dance from [.claude/rules/osc.md](../.claude/rules/osc.md):
checkout `master` in the submodule first (worktrees leave it detached),
commit and push inside `priv/AbletonOSC`, then stage the new pin in the same
Seshat commit as the Elixir side. The user must run `mix abletonosc.install`
and restart Live before any of part 4's swing behaviour exists — a green
suite on unreinstalled Python is no evidence.

### 2. Document the new addresses — `docs/abletonosc-api-docs.md`

Add to the Song getters table (alphabetical, near `signature_numerator`):

```
| `/live/song/get/swing_amount` | `swing_amount` | Global swing amount (0.0-1.0); applied by MIDI record quantization and `/live/clip/quantize` |
```

and to the Song setters table:

```
| `/live/song/set/swing_amount` | `swing_amount` | Set global swing amount (0.0-1.0) |
```

The prose note in the Quantization grid section ("swing comes from the song's
`swing_amount`") already exists and becomes accurate rather than aspirational.

`groove_amount`'s rows already exist but say only "Groove amount" / "Set
groove amount" — rewrite both to carry the range and the assigned-groove
semantics this plan depends on:

```
| `/live/song/get/groove_amount` | `groove_amount` | Groove Pool amount (0.0-1.3; 1.0 = the dial's 100%, 1.3 = its 130% maximum); scales how strongly each clip's *assigned* groove applies — no effect on clips without one |
| `/live/song/set/groove_amount` | `groove_amount` | Set Groove Pool amount (0.0-1.3); 0 = assigned grooves off |
```

Not cosmetic: these two properties are constantly confused with each other,
they will sit adjacent in the same table, and this file is what CLAUDE.md
sends you to *before using any address*. Documenting swing richly while
leaving its sibling bare is how the confusion the two tools exist to prevent
gets re-imported through the docs.

### 3. Tripwire — `test/seshat/osc/vendored_addresses_test.exs`

`song.py` registers by loop (`"/live/song/get/%s" % prop`), so the
literal-grep `registered_addresses/1` cannot see the new addresses and
`song.py` must **not** join `@handler_files` (it would under-report and trip
the docs test falsely) — nor do the addresses join `@vendored_song_addresses`
(the used→registered test would fail for the same reason). This is exactly
the `clip.py` `quantize` situation, and the guard is the same shape as
[archive/PLAN_quantize_clip.md](archive/PLAN_quantize_clip.md) part 4: a grep
test asserting `File.read!("priv/AbletonOSC/abletonosc/song.py")` contains
`"swing_amount"`
(one line, appears exactly once), with a failure message pointing at
`SESHAT.md`'s divergence entry and this tool — because an upstream merge that
drops the line is otherwise invisible: every other song address still
answers, and swing sets go back to failing the way all OSC fails. Quantize's
tripwire describe block has already landed
(`test/seshat/osc/vendored_addresses_test.exs`) — sit beside it.

### 4. Define the tools — `lib/seshat/tools/definitions.ex`

Insert both next to `set_tempo` (the transport/song group). Descriptions are
the load-bearing half — they must route "make it swing" to the right knob and
stop the model promising groove where none is assigned:

```elixir
%{
  name: "set_swing_amount",
  description:
    "Set Ableton Live's global swing amount (0.0-1.0; 0 = straight). This " <>
      "is the \"make it swing\" knob for played or written MIDI — but it is " <>
      "applied only when notes are quantized: set the swing, then " <>
      "quantize_clip the clip to hear it (it also shapes record " <>
      "quantization on future takes). It does not audibly change a clip by " <>
      "itself. Start subtle (around 0.10-0.20) and adjust by ear; 0.5 is as " <>
      "far as Ableton's own Push hardware will drive it, so treat the upper " <>
      "half of the range as extreme. The current value shows in " <>
      "get_session_state.",
  parameters: %{
    type: "object",
    properties: %{
      "amount" => %{
        type: "number",
        minimum: 0.0,
        maximum: 1.0,
        description: "Swing amount, 0.0 (straight) to 1.0 (maximum)"
      }
    },
    required: ["amount"]
  }
},
%{
  name: "set_groove_amount",
  description:
    "Set Ableton Live's global groove amount (0.0-1.3, where 1.0 is 100% " <>
      "and 1.3 is the dial's 130% maximum) — the Groove Pool's " <>
      "Amount dial, scaling how strongly every clip's assigned groove is " <>
      "applied (0 = grooves off). It only affects clips that already have " <>
      "a groove assigned from Live's Groove Pool, which Seshat cannot do — " <>
      "if the user hasn't assigned grooves by hand, this changes nothing; " <>
      "use set_swing_amount plus quantize_clip to swing plain MIDI " <>
      "instead. The current value shows in get_session_state.",
  parameters: %{
    type: "object",
    properties: %{
      "amount" => %{
        type: "number",
        minimum: 0.0,
        maximum: 1.3,
        description: "Groove amount, 0.0 (off) to 1.3 (the dial's 130% maximum); 1.0 = 100%"
      }
    },
    required: ["amount"]
  }
}
```

Decisions folded in, so they don't reopen during implementation:

- **Two tools, not one.** Swing and groove are different Live concepts with
  different preconditions (one needs a follow-up quantize, the other needs
  grooves assigned); a merged tool with two optional params would need an
  "at least one" rule the schema can't express and would blur exactly the
  routing the descriptions exist to teach.
- **`amount` required, no default** — same reasoning as `quantize_clip`'s
  `amount`: the value *is* the musical decision.
- **Bounds differ between the two, and that is deliberate**: swing 0.0–1.0,
  groove 0.0–**1.3**. Not a typo to be tidied — the apiref says 0.0–1.0 for
  both, but Live's own Move script clamps `groove_amount` to 1.3125 and
  displays it as a percentage, so 1.0 is 100% and the dial's 130% is 1.3
  (see [Evidence](#evidence-live-12-suites-own-scripts)). Under-bounding here
  costs real range and would be invisible: the silent `_set_property` makes
  an over-bound value a no-op, not an error.
- Both descriptions name `quantize_clip`, so this ships **after**
  [archive/PLAN_quantize_clip.md](archive/PLAN_quantize_clip.md), which has
  now shipped — the tool exists and the description can name it safely.

### 5. Handle them — `lib/seshat/tools/handlers.ex`

Two `do_call/2` clauses next to `set_tempo`, Transport-direct,
fire-and-forget, replies carrying the next-move teaching forward:

```elixir
defp do_call("set_swing_amount", %{"amount" => amount}) do
  case Transport.send_message("/live/song/set/swing_amount", [amount / 1.0]) do
    :ok ->
      {:ok,
       "Set the global swing amount to #{amount}. Swing is applied when notes " <>
         "are quantized — quantize the clip to hear it. If nothing changes even " <>
         "after quantizing, the installed AbletonOSC may predate swing support: " <>
         "run mix abletonosc.install and restart Live."}

    {:error, reason} ->
      {:error, inspect(reason)}
  end
end

defp do_call("set_groove_amount", %{"amount" => amount}) do
  case Transport.send_message("/live/song/set/groove_amount", [amount / 1.0]) do
    :ok ->
      {:ok,
       "Set the global groove amount to #{amount}. This scales grooves already " <>
         "assigned to clips from the Groove Pool — clips without a groove are " <>
         "unaffected."}

    {:error, reason} ->
      {:error, inspect(reason)}
  end
end
```

- The swing reply's install hint matters because `/live/song/set/swing_amount`
  is fork-only and silent: a stale Remote Scripts copy drops it on the floor
  indistinguishably from success. Mirroring `quantize_clip`'s no-change-hint
  reasoning, the hint rides the reply (there is no no-change branch to attach
  it to — the setter never replies), and `get_session_state` showing
  "swing unknown" is the corroborating symptom (the getter is equally absent).
- No `FollowCam.steer/2` — song-level setter, no pane to show; `set_tempo`
  precedent, same as `set_time_signature`.

### 6. Mirror both values — `lib/seshat/session/state.ex`

- `@listened_song_properties` — append `groove_amount swing_amount`. The
  existing `subscribe_song_listeners/0` loop then subscribes both on every
  refresh (interpolated address is fine here: these are loop-registered in
  Python, invisible to the vendored tripwire in both directions, same as
  `tempo`).
- `initial_song` in `init/1` — add `groove_amount: nil, swing_amount: nil`
  (unknown, never a guess).
- Two `handle_info` clauses above the catch-all, the `tempo` shape:

  ```elixir
  def handle_info({:osc_message, "/live/song/get/groove_amount", [value]}, state) do
    {:noreply, update_song(state, :groove_amount, value)}
  end

  def handle_info({:osc_message, "/live/song/get/swing_amount", [value]}, state) do
    {:noreply, update_song(state, :swing_amount, value)}
  end
  ```

- `do_refresh/1`'s song map — add
  `groove_amount: query_song_float(Transport, "/live/song/get/groove_amount")`
  and the same for `swing_amount`. On a Live whose AbletonOSC predates the
  fork pin, the swing query times out to `nil` → rendered as a stated
  unknown, which is the honest signal to re-run the install. That timeout is
  the standard `@query_timeout` (5s), **deliberately not** the shorter
  `@return_probe_timeout` the file uses for the other fork-only addresses:
  the +5s per refresh exists only in the not-yet-reinstalled state, which
  smoke item 1 catches immediately and the reply text tells the user to fix,
  whereas a 2s probe risks a false "swing unknown" on a healthy install.
  Don't "fix" this to the probe timeout when the neighbouring comment
  suggests it.
- Update `song/0`'s @doc key list. Leave `do_refresh`'s log line alone —
  tempo/signature/key is the at-a-glance summary; groove and swing aren't
  worth log noise on every refresh.

### 7. Render in the song line — `lib/seshat/tools/handlers.ex` (`format_song_line/1`)

Extend the composed line with two fields, per-field unknown like the rest:
`"groove " <> value` and `"swing " <> value`, `nil` → `"groove unknown"` /
`"swing unknown"`, both OR'd into the `unknown?` flag. Raw floats, not
percentages — the house rendering for volume/pan/sends, and it keeps the
number the model reads equal to the number the tools accept. Example line:

```
120.0 BPM, 4/4, stopped, key: C Major, groove 0.0, swing 0.16
```

### 8. Tests

- **`test/seshat/tools/definitions_test.exs`** — bump the count assertion by
  **two** from wherever it stands when this lands (53 today; the two earlier
  plans in this run each add one, so 55 → 57 in roadmap order). Also add
  `set_swing_amount` and `set_groove_amount` to the `expected` name list
  beside `set_tempo` — the count assertion can't see a rename, that list is
  the only thing that can, and it has quietly fallen three tools behind
  (`capture_midi`, `get_clip_properties`, `set_clip_properties` are all
  missing) because nothing asserts it is exhaustive. Don't fix that here;
  just don't widen the gap. Existing schema sweeps cover the new bounds by
  construction.
- **`test/seshat/tools/validation_test.exs`** — existing style, and the one
  place the differing maxima get pinned: `set_swing_amount` rejects
  `amount: 1.5`, `set_groove_amount` rejects `amount: 1.4` **but accepts
  `1.2`** (the case that fails if someone later "harmonises" the two bounds
  at 1.0), both reject `amount: -0.1` and a non-number.
- **`test/seshat/tools/handlers_test.exs`** —
  - OSCSink describe (`setup :osc_sink`), `set_track_pan` pattern: each tool
    returns `{:ok, msg}` with the teaching phrase (`msg =~ "quantize"` /
    `msg =~ "Groove Pool"`), and the datagram lands float-typed:
    `assert_receive {:osc_out, "/live/song/set/swing_amount", [0.2]}` (and
    groove likewise) — proving the `/ 1.0` coercion.
  - `format_song_line/1` describe: add the new keys to the `song()` fixture;
    known values render (`=~ "swing 0.16"`), each `nil` renders unknown and
    flips the flag — the existing per-field cases as the template.
- **`test/seshat/session/state_test.exs`** — the existing push-handling
  style, which does **not** run the GenServer: that file deliberately never
  starts it (`init` queries Live), so call `State.handle_info/2` directly via
  the file's `push/3` helper and assert on the returned state —
  `push(state(), "/live/song/get/swing_amount", [0.25]).song.swing_amount ==
  0.25`, same for groove. `Session.State.song()` is a `GenServer.call` and
  has no process to reach here. Add `groove_amount: nil, swing_amount: nil`
  to the `state/1` fixture's song map too, so it keeps mirroring
  `initial_song`.
- **Part 3's tripwire** in `vendored_addresses_test.exs`.
- **MCP parity** (`Seshat.MCP.ToolsTest`) is generated coverage — no work;
  it's the check that both bounds survive Peri conversion.

### 9. Bookkeeping

- **`docs/TOOL_AUDIT.md`** — add both tools to the inventory table with
  verdicts; in the coverage-gap table, trim "swing/groove" out of the
  "Groups · routing/IO · automation · groove" row (retitle to
  "Groups · routing/IO · automation").
- No change to `Seshat.Instructions` (routing rides the descriptions; the
  2,048-char budget stays untouched). No change to `FollowCam`.
- ROADMAP link for this plan is added by the planning run itself; the entry
  shrinks only at `/ship`.

## Testing

Covered pure (no Ableton): definitions count and schema sweeps, validation of
both bounds, both datagrams asserted float-typed at the OSCSink, reply
wording, song-line rendering including per-field unknowns, mirror updates
from simulated pushes, the `song.py` grep tripwire, MCP schema parity.

Needs `/smoke-test` with Ableton open — **after `mix abletonosc.install` and
a Live restart** (nothing in `mix test` executes the Python or the Live API):

1. **First:** `get_session_state` shows numeric groove *and* swing values.
   Live 12 Suite *has* `Song.swing_amount` (Resolved question 1), so "swing
   unknown" here means the wire, not the property: almost certainly
   `mix abletonosc.install` not run or Live not restarted. Fix that before
   anything else — every item below depends on it.
2. `set_swing_amount 0.25`, then `get_session_state` **without**
   `refresh: true` — mirror shows 0.25 via the listener echo.
3. Set swing, then `quantize_clip` at `"1/8"` on a straight clip — notes land
   *off* the straight grid on swung positions (the end-to-end "make it
   swing"; also exercises the quantize plan's smoke item 4 from the other
   side). Judge by ear whether 0.10–0.20 reads "subtle" and adjust the
   description's suggested range (Resolved question 3 — the one still open).
4. Assign a groove to a clip by hand in Live, `set_groove_amount 0.0` then
   `1.0` then `1.3` — audible change, and the Groove Pool's Amount dial
   follows. Expect the dial to read **100%** at 1.0 and **130%** at 1.3
   (Resolved question 2); anything else means the mapping moved in this Live
   version and the groove schema max needs revisiting.
5. `set_groove_amount` with **no** grooves assigned — nothing changes
   audibly, and the model's reply (fed by the description) says so rather
   than promising swing.

## Out of scope

- **Assigning a groove to a clip.** `Clip.groove` is an unserializable LOM
  object (the fork's `clip.py` TODO records the failed attempt), so this
  needs real fork design work (e.g. an index into `Song.groove_pool.grooves`)
  and has no roadmap entry. If a workflow demands it, it's a new roadmap item
  — worth writing down then that the groove *pool* itself (loading `.agr`
  files, per-groove timing/quantize/random amounts) is part of the same
  design.
- **`midi_recording_quantization`** — upstream rw property, adjacent knob
  (whether record quantize is on and at what grid), different feature.
  Grab-bag material ("Small OSC breadth").
- **Per-clip `has_groove` surfacing** in `get_clip_properties` — would let
  the model check groove assignment before promising `set_groove_amount`
  effects; nice, not needed for the descriptions to be honest. Grab-bag.
- **Percent-styled rendering or per-clip swing** — no such LOM surface;
  rendering stays in the volume/pan float convention.

## Evidence: Live 12 Suite's own scripts

Three of the four open questions below were settled without Ableton running,
by reading the Python Ableton ships *inside Live 12 Suite* — the same
`MIDI Remote Scripts` API surface AbletonOSC executes against, so it answers
"does this property exist here, and what values does Ableton itself write to
it" directly. The `.pyc` files are Python 3.11 bytecode; `marshal.loads` past
the 16-byte header gives the code objects, and the constant/name tables are
readable without a decompiler.

Sources, all under
`/Applications/Ableton Live 12 Suite.app/Contents/App-Resources/MIDI Remote Scripts/`:

- **`_MxDCore/LomTypes.pyc`** — the Max for Live LOM type table. Its Song
  member list contains `swing_amount`, alphabetically between `stop_playing`
  and `tap_tempo`, and `groove_amount`.
- **`pushbase/quantization_component.pyc`** —
  `QuantizationSettingsComponent` reads and writes `self.song.swing_amount`,
  exposes it as a `listenable_property`, and holds a
  `@listens('swing_amount')` slot (`__on_swing_amount_changed`). Its encoder
  handler is `clamp(...)` over the constants `0.0` and `0.5`.
- **`Move/transport.pyc`** — `GROOVE_AMOUNT_MAX = 1.3125`;
  `groove_string` renders `'Groove\n{}%'.format(round(min(groove_amount, 1.3)
  * 100))`; `increment_groove` clamps into `(0, GROOVE_AMOUNT_MAX)` and bails
  to `GROOVE_POOL_EMPTY = "Live's Groove Pool is empty"` when
  `song.groove_pool.grooves` is empty.

If a future Live upgrade makes any of this stale, it is re-derivable in one
command per file — nothing here needs to be taken on trust.

## Resolved questions

1. **✅ Does the running Live expose `Song.swing_amount`? Yes.** It is in this
   machine's Live 12 Suite LOM table, and Ableton's own Push code both reads
   and writes it on `song`. The plan's riskiest dependency — an entire fork
   change and tool that would have to be severed if the property were absent —
   is no longer a gamble. Smoke item 1 stays, demoted from "stop and
   investigate" to a wire-level confirmation that the reinstalled fork serves
   what Live has.
2. **✅ Where does `groove_amount = 1.0` land Live's 0–130% dial? At 100%.**
   The property is a plain fraction-of-percent scale: Move renders it as
   `round(min(x, 1.3) * 100)` percent and clamps its own writes at 1.3125.
   So the dial's 130% is `1.3`, the apiref's "0.0 - 1.0" is an understatement
   rather than a limit, and the schema max is **1.3** (folded into part 4).
   Smoke item 4 now *checks* the mapping rather than discovering it.
   Bonus, from the same file: Move refuses to touch groove at all when the
   Groove Pool is empty and says so on its display — Ableton's own UI
   concedes the point `set_groove_amount`'s description makes.
3. **⚠️ Still open — how strong does a given swing value sound?** Narrowed,
   not answered: Push clamps user-driven `swing_amount` to **0.5**, so the
   suggested 0.10–0.20 sits in the lower half of what Ableton's own hardware
   will produce, which is at least evidence the range isn't absurd. Whether
   it reads as "subtle" is still ears-only (smoke item 3); the fix, if any,
   is description wording.
4. **✅ Do these properties support listeners? Yes — for both.** The residual
   risk in the original question was that `_start_listen` calls
   `add_<prop>_listener` and would simply fail on a non-observable property.
   Live's own code registers on both: Push via `@listens('swing_amount')`,
   Move via a `register_slot(song, ..., 'groove_amount')`. What remains is
   only the generic assumption every mirrored property already rests on —
   that Live notifies listeners for API-driven writes as well as UI ones,
   which `tempo` demonstrates daily. Smoke item 2 is still the check;
   `refresh: true` remains the backstop.
