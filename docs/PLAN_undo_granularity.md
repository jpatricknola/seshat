# Plan: one Seshat action, one undo step

Roadmap — `undo` can revert far more than the last action.

## Context

Live groups mutations driven by a control-surface script into one undo step,
and the boundaries of that grouping are not under our control. The roadmap's
reproduction held up when measured on the running Live (12.4.3, 2026-08-01):
`create_track` → `write_midi_notes` → one `undo` deleted the **entire track**,
notes, clip and all. The same sequence run minutes earlier with an intervening
timed-out call and a `get_clip_slots` query landed as *two* undo steps — so
the implicit grouping is activity-sensitive and unpredictable, which is worse
than being consistently coarse: the user cannot learn what one undo will do,
and neither can the model.

The Live Object Model has the fix, and it is the same one Ableton's own Push
script uses (`pushbase/undo_step_handler.pyc` in Live's shipped Remote
Scripts): `Song.begin_undo_step()` / `Song.end_undo_step()` demarcate an undo
step explicitly. Everything a script changes between the two calls becomes
exactly one step. Neither method has an OSC address in AbletonOSC today, so
this plan has a Python half — two entries in the fork's `song.py` method
list, the same one-line shape as `swing_amount`.

All of the load-bearing behaviour was **measured against the running Live
12.4.3** with the probe rig (temporary edit to the installed `song.py`,
`/live/api/reload`, restored with `mix abletonosc.install` and verified gone):

1. **Wrapping works.** `begin` → `create_track` → `end`, `begin` →
   `write_midi_notes` → `end`: the first undo reverted only the write (clip,
   notes and name, as one step), the second removed the track. Exactly the
   granularity the roadmap asks for.
2. **Empty pairs are free.** Three `begin`/`end` pairs with nothing between
   them left the undo history untouched — the next undo reverted the real
   change before them. So read-only tools can be wrapped too, and no
   mutating-tool list needs to exist or be kept in sync.
3. **An unmatched `end` is harmless.** Logged as an ordinary method call, no
   exception, no history effect.
4. **`begin` does not refcount.** With two `begin`s outstanding, the first
   `end` closed the step (a change made after it was its own step). A leaked
   `begin` therefore self-heals at the next wrapped call's `end`.
5. **A leaked `begin` is real but bounded.** Changes made while a `begin` is
   open — including by other tool calls — group into one step until an `end`
   arrives. This is why the Elixir side must send `end` in an `after` block,
   and why `undo`/`redo` send a defensive lone `end` first.

The wrap lives in `Seshat.Tools.Handlers.call/2` — the single MCP dispatch
funnel — so a
multi-message tool (`write_midi_notes` is a create-clip + add-notes + name
sequence through `Registry`) reverts as a unit because the wrap encloses the
whole dispatch, not each datagram.

## OSC contract

Both addresses are fork additions to upstream's own
`abletonosc/song.py`, registered through its existing generic method loop
(`"/live/song/%s" % method` → `_call_method`), exactly like `undo`:

| Address | Request args | Reply |
|---|---|---|
| `/live/song/begin_undo_step` | none | none (send-only) |
| `/live/song/end_undo_step` | none | none (send-only) |

Verified live: `Song.begin_undo_step()` and `Song.end_undo_step()` exist on
Live 12.4.3's Song object and behave as measured above when called through
`_call_method` with no params.

Existing addresses used unchanged: `/live/song/undo`, `/live/song/redo`.

## Part 1 — Python: register the two methods

**Files:** `priv/AbletonOSC/abletonosc/song.py`, `priv/AbletonOSC/SESHAT.md`
(submodule commit + pin bump here).

- Add `"begin_undo_step"` and `"end_undo_step"` to the methods list in
  `SongHandler.init_api` (top of the list, matching the probe that was
  measured). No other Python changes — `_call_method` and the loop do the
  rest.
- Add both to `SESHAT.md` under "Additions to upstream's code", noting they
  are method-list entries invisible to the literal-grep (the `swing_amount`
  precedent) and what breaks if an upstream merge drops them: undo reverts
  whole conversations again, silently.
- Two commits: one in the submodule, one bumping the pin (bundled with the
  Elixir side so pin and dependent code move together).

This puts `mix abletonosc.install` + a Live restart on the user, and nothing
in `mix test` executes it — the live-Ableton verification is Part 5.

## Part 2 — Elixir: wrap every dispatch in its own undo step

**File:** `lib/seshat/tools/handlers.ex`.

In `call/2`, after validation passes, route dispatch through the wrap:

- **Known tool, not `undo`/`redo`:** send `/live/song/begin_undo_step` (fire
  and forget), run `do_call/2` inside `try`, send `/live/song/end_undo_step`
  in the `after` — so an error reply, a raise, or a mid-sequence timeout
  still closes the step and the partial work reverts as one unit.
- **`undo` and `redo`:** never wrapped (an undo inside an open step is a
  state this design never creates). Each sends one defensive
  `/live/song/end_undo_step` *before* its own dispatch — measured harmless
  when no step is open — so a `begin` leaked by a BEAM death mid-call can't
  fold the user's next undo into stale grouping; wrapped calls self-heal the
  same leak via their own `end` (measurement 4).
- **Unknown tool name:** straight to `do_call/2`'s catch-all, no OSC traffic
  — validation deliberately passes unknown names through, and a nonexistent
  tool must not touch the wire (this also keeps pure tests that call
  `call/2` without a running `Transport` alive).

Wrapping read-only tools is deliberate: empty steps are measured-free, and a
maintained mutating-tool list would fail silently the first time a new tool
forgot to join it — the exact failure mode this codebase avoids. The trade-off
is a caveat, not a bug: while a long tool holds a step open (a 30s
`load_device`, a `reindex_library` export), a *simultaneous* hand-edit in
Live's UI joins that step. Rare, bounded to one step, and the
per-datagram alternative has the same window.

The two address strings appear as literals (never interpolated) —
`vendored_addresses_test`'s grep is the tripwire.

## Part 3 — Definitions: make `undo`/`redo` say what a step is

**File:** `lib/seshat/tools/definitions.ex`. No new tool, so no count bump —
the MCP components regenerate from these descriptions automatically.

- `undo`: "Undo the last action in Ableton Live. Every Seshat action is its
  own undo step, so one undo reverts exactly one earlier action — a
  multi-part write like write_midi_notes comes back as a unit. Edits the
  user makes by hand in Live are separate steps in the same history, so an
  undo may revert their latest manual change if it came after Seshat's."
- `redo`: "Redo the last undone action in Ableton Live. Steps mirror undo's:
  one redo restores exactly one reverted action."

No `Seshat.Instructions` change: this guidance only matters when using these
tools, so per the division rule it belongs in the descriptions, not the
capped instructions budget.

## Part 4 — Tests (pure, no Ableton)

- **`test/seshat/tools/handlers_test.exs`** (OSCSink at the wire):
  - A wrapped tool (`set_tempo` is convenient) produces
    `begin_undo_step` → mutation → `end_undo_step`, in that order.
  - A tool whose handler returns an error after `begin` still sends `end`
    (pick any clause with a reachable error path that emits OSC first, or
    assert via a raising path that `after` fired).
  - `undo` sends exactly `end_undo_step` then `/live/song/undo` — no
    `begin`. Same shape for `redo`.
  - An unknown tool name sends nothing.
- **`test/seshat/osc/vendored_addresses_test.exs`**: a new describe block on
  the `swing_amount` pattern asserting `song.py` still contains
  `~s("begin_undo_step")` and `~s("end_undo_step")` — the method list is a
  loop registration, invisible to both of the suite's generic checks, and
  losing an entry in an upstream merge would be silent.
- **`test/seshat/tools/definitions_test.exs`**: tool count unchanged (no new
  tools).
- **`docs/abletonosc-api-docs.md`**: add both addresses to the song methods
  table, marked as fork additions.

## Part 5 — Live verification (smoke test)

**File:** `.claude/skills/smoke-test/SKILL.md` — add an undo-granularity
check. Nothing in `mix test` executes the Python half or proves real
grouping; only Ableton can. After `mix abletonosc.install` + Live restart:

1. `create_track` → `write_midi_notes` → `undo`: only the clip and notes
   disappear; the track stays.
2. `undo` again: the track goes.
3. `redo` twice: both come back, one step at a time.

(The identical sequence was measured working through the probe on
2026-08-01; the smoke item confirms the shipped wiring end to end.)

## Out of scope

- **Warning before a destructive undo** ("this will take the whole track") —
  the roadmap's fallback for an unfixable grouping. The grouping is fixable;
  a warning flow adds a round trip to every undo for a problem that no
  longer exists. Not added to the roadmap.
- **Exposing `can_undo`/`can_redo` as a tool or in session state** — nothing
  needs it yet; stays off the roadmap until something does.
- **Multi-step undo** ("undo the last three things") — the model can call
  `undo` repeatedly, and each call now means one action. Stays as-is.
- **Grouping several tool calls into one step on request** ("treat this
  whole 8-bar build as one undo") — possible later with the same two
  addresses exposed as their own tool pair, but it reintroduces exactly the
  leaked-`begin` hazards this plan closes. Roadmap material if a real
  session ever asks for it.

## Open questions

1. ⚠️ **Generality beyond Live 12.4.3.** Every measurement above is from one
   Live version on one machine; grouping internals are undocumented, and
   whether an older or future Live refcounts `begin`, tolerates unmatched
   `end`, or prices empty steps the same cannot be measured on this rig.
   No available resource answers this — the project's stance (current setup
   only, no compat paths) makes it acceptable: assume 12.4.3 behaviour is
   the contract, and re-run the Part 5 smoke item after any Live upgrade.

Everything else the plan relies on was closed by measurement on 2026-08-01
(see Context): the reproduction, the fix, empty-pair cost, unmatched-`end`
safety, non-refcounting, and leaked-`begin` behaviour.
