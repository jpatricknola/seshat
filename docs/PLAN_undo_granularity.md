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
   notes and name, as one step), the second removed the track. This proves
   per-tool-call granularity; it does not make Live's history selective.
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
funnel — so a multi-message tool (`write_midi_notes` is a create-clip +
add-notes + name sequence through `Registry`) reverts as a unit because the
wrap encloses the whole dispatch, not each datagram.

Here **action means one tool call, not one user message**. A request such as
"create 20 tracks" can fan out into 20 `create_track` calls and therefore 20
undo steps. Seshat never receives the original Desktop prompt or a user-turn
identifier — only those individual MCP calls — although the model retains the
calls and results in its conversation. Part 3 therefore teaches the model that
"undo that request" means one `undo` call per mutating call that changed Live;
Seshat cannot infer or reconstruct that batch boundary server-side.

The boundary methods leave Live's history strictly last-in, first-out. The
installed LOM exposes `undo`, `redo`, `can_undo`, `can_redo`, and the two step
boundary methods, but no API for naming, deleting, or skipping an older history
entry. If `quantize_clip` is followed by another mutation, the next `undo`
necessarily reverts that later mutation first. Replaying the later calls after
undoing through the quantize is not a general inverse: destructive calls,
recording/capture, index-shifting operations, and browser loads cannot be
re-executed safely or identically.

That is not a shortfall — **Live has no selective revert either.** Its undo is
a plain linear stack with no history palette, so top-of-stack is what a
producer's hands already expect. The roadmap's first user story was narrowed
to say so on 2026-08-01; "Approach considered and rejected" records the
design that would have gone further and why it was turned down.

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
(submodule commit + pin bump here), plus `CLAUDE.md` and
`.claude/rules/osc.md` in the parent repo.

- Add `"begin_undo_step"` and `"end_undo_step"` to the methods list in
  `SongHandler.init_api` (top of the list, matching the probe that was
  measured). No other Python changes — `_call_method` and the loop do the
  rest.
- Add both to `SESHAT.md` under "Additions to upstream's code", noting they
  are method-list entries invisible to the literal-grep (the `swing_amount`
  precedent) and what breaks if an upstream merge drops them: undo reverts
  whole conversations again, silently.
- Update `CLAUDE.md`'s `priv/AbletonOSC` module-map row and fork-extension list,
  and `.claude/rules/osc.md`'s inventory of additions inside upstream files, to
  name the two `song.py` methods. Both currently describe the four `view.py`
  routes as the only address additions living in an upstream file; that stops
  being true after this change.
- Two commits: one in the submodule, one bumping the pin (bundled with the
  Elixir side so pin and dependent code move together).

This puts `mix abletonosc.install` + a Live restart on the user, and nothing
in `mix test` executes it — the live-Ableton verification is Part 5.

## Part 2 — Elixir: wrap every dispatch in its own undo step

**File:** `lib/seshat/tools/handlers.ex`.

In `call/2`, after validation passes, route dispatch through the wrap:

- Derive a compile-time `@tool_names` `MapSet` from `Definitions.all/0`, using
  the same pattern as `Seshat.MCP.Server`, and add `Definitions` to the aliases.
  Validation intentionally accepts unknown names, so this membership check is
  what distinguishes a real tool from the catch-all without hand-maintaining a
  second tool list.
- **Serialize every known-tool dispatch globally**, including `undo`/`redo`,
  with `:global.trans({{__MODULE__, :undo_step}, self()}, fun, [node()])` around
  the branch below. Anubis serializes calls only within one MCP session; two
  Desktop sessions can still overlap. Live's `begin_undo_step` is measured not
  to refcount, so without this lock one caller's `end` can close another
  caller's step. The resource id is shared and `self()` is the caller-specific
  lock owner; OTP releases the lock if that process dies.
- **Known tool, not `undo`/`redo`:** require a successful
  `/live/song/begin_undo_step` send before calling the handler; if that send
  returns an error, return the error without dispatching an unprotected
  mutation. Run `do_call/2` inside `try`, and send
  `/live/song/end_undo_step` in the `after` — so an error reply, a raise, or a
  mid-sequence timeout still closes the step and the partial work reverts as
  one unit. An `after` block cannot change the call's return value, so a
  failed `end` send is **logged at `:warning`** rather than swallowed: it
  means a step was left open, and the only other trace of it would be the
  user's next undo behaving strangely. It self-heals at the next wrapped
  call's `end` (measurement 4) and at the defensive `end` below, so logging is
  the whole of the response — no error is manufactured for a tool whose own
  work succeeded.
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
forgot to join it — the exact failure mode this codebase avoids. The global
lock prevents another Seshat caller from entering the open step. The remaining
trade-off is a caveat, not a bug: while a long tool holds a step open (a 30s
`load_device`, a `reindex_library` export), a *simultaneous* hand-edit in
Live's UI joins that step. Rare, bounded to one step, and the per-datagram
alternative has the same window. A second Seshat caller waits outside the lock;
behind a tool that consumes the MCP request timeout it may time out without
dispatching, which is safer than interleaving two global undo steps.

The two address strings appear as literals (never interpolated) —
`vendored_addresses_test`'s grep is the tripwire.

## Part 3 — Definitions: make `undo`/`redo` say what a step is

**File:** `lib/seshat/tools/definitions.ex`. No new tool, so no count bump —
the MCP components regenerate from these descriptions automatically.

- `undo`: "Undo exactly one Ableton undo step. Each mutating Seshat tool call
  that changes Live creates one step — not each user message — and a
  multi-part call such as write_midi_notes is still one step. If the user asks
  to undo or revert the previous request, review the tool calls used to fulfill
  it and call undo once for every call that changed Live, newest first; include
  a partially completed call, but do not count read-only, validation-rejected,
  or no-change calls. Use undo only when the change to reverse is at the top of
  Live's undo history. To reverse an older action while preserving later work,
  use the relevant domain tool with the prior value or state when that is exact
  and safe; never call undo through unrelated later work. If no exact inverse
  exists — quantize_clip cannot restore the original note timing by quantizing
  again — explain the limitation instead of risking other changes. Manual edits
  in Live share the same history, so before performing multiple undos, warn or
  clarify if the conversation indicates the user edited Live since that
  request."
- `redo`: "Redo exactly one undone Ableton step. If the user asks to redo a
  whole request that required several mutating tool calls, call redo once per
  step that was undone, in the original order. Any new edit can clear Live's
  redo history."

No `Seshat.Instructions` change: this guidance only matters when using these
tools, so per the division rule it belongs in the descriptions, not the
capped instructions budget.

## Part 4 — Tests (pure, no Ableton)

- **`test/seshat/tools/handlers_test.exs`** (OSCSink at the wire):
  - A wrapped tool (`set_tempo` is convenient) produces
    `begin_undo_step` → mutation → `end_undo_step`, in that order.
  - `search_library` with the catalog unstarted returns its existing error but
    still produces `begin_undo_step` → `end_undo_step`, proving the `after`
    closes an error path without adding a slow query timeout.
  - `undo` sends exactly `end_undo_step` then `/live/song/undo` — no
    `begin`. Same shape for `redo`.
  - An unknown tool name sends nothing.
  - A concurrency regression holds one known call at a controlled OSC query
    after its `begin`, starts `set_tempo` from a second task, and proves no
    second `begin` or tempo mutation arrives until the first call emits `end`;
    the second call then emits its complete three-message sequence. This is the
    tripwire for cross-session action interleaving.
  - Add `:osc_sink` setup to the existing `get_session_state` and
    `search_library` dispatch describes (including the populated-catalog
    describe). They currently run deliberately without `Transport`; wrapping
    every known read-only tool makes that old setup invalid even though their
    catalog/state assertions are otherwise unchanged.
- **`test/seshat/osc/vendored_addresses_test.exs`**: a new describe block on
  the `swing_amount` pattern asserting `song.py` still contains
  `~s("begin_undo_step")` and `~s("end_undo_step")` — the method list is a
  loop registration, invisible to both of the suite's generic checks, and
  losing an entry in an upstream merge would be silent. Update the module
  commentary too: it currently counts only the two `song_structure.py`
  addresses under upstream's `/live/song/` prefix and says `view.py` holds the
  only upstream-file additions.
- **`test/seshat/tools/definitions_test.exs`**: tool count unchanged (no new
  tools), and pin the load-bearing prompt contract: `undo` says one step is one
  mutating tool call rather than one user message and instructs repeated calls
  for a multi-call request; it also routes an older reversible action to its
  domain tool and forbids undoing through unrelated later work, naming
  `quantize_clip` as non-invertible. `redo` states the symmetric repeated-call
  rule.
- **`docs/abletonosc-api-docs.md`**: add both addresses to the song methods
  table, marked as fork additions, and update the View API note that currently
  calls its four rows the only Seshat addresses living in an upstream file.

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

Separately from the `/smoke-test` checklist, run one acceptance check through
the actual Claude Desktop client: ask for three named tracks in one user
message, then say "undo that request." Confirm the model issues three `undo`
calls and all three tracks disappear. This checks the model-facing description;
a smoke agent following an explicit checklist would only prove that the agent
can obey the checklist, not that Desktop infers the repeated calls from the
tool description.

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

## Approach considered and rejected

A rival plan proposed everything above **plus** a quantize-only compensating
tool, to revert an earlier quantize while preserving work done after it — what
the roadmap's first user story asked for before it was narrowed: a bounded
in-memory journal (32 entries, LRU) inside the fork's `clip.py`, two new
vendored addresses (`/live/clip/quantize_journaled`,
`/live/clip/rollback_quantize`), an opaque rollback token returned by
`quantize_clip`, and a new `rollback_quantize` MCP tool. The journal would
snapshot all nine extended note fields either side of `Clip.quantize`, pair
before/after notes by `note_id`, and apply a three-way inverse that preserves
later non-conflicting edits and refuses on conflict.

It was rejected because the narrowed requirement deliberately matches Live's
linear undo stack. The alternative would add a second model-facing undo
mechanism, cross-call mutable state in the Python bridge, and conflict-sensitive
note restoration that `mix test` could not execute. Restoring notes would also
be a new mutation and therefore a new Live undo step, rather than behaving like
the host's own undo. That cost is disproportionate once selective rollback is
no longer the goal.

Two useful details were retained: a failed `end_undo_step` is logged rather
than swallowed, and the tool count remains unchanged because this plan adds no
new MCP tool. The original plan's known-tool check, global serialization, and
unwrapped `undo`/`redo` branches remain because they cover failure modes the
alternative did not.

## Open questions

1. ⚠️ **Generality beyond Live 12.4.3.** Every measurement above is from one
   Live version on one machine; grouping internals are undocumented, and
   whether an older or future Live refcounts `begin`, tolerates unmatched
   `end`, or prices empty steps the same cannot be measured on this rig.
   No available resource answers this — the project's stance (current setup
   only, no compat paths) makes it acceptable: assume 12.4.3 behaviour is
   the contract, and re-run the Part 5 smoke item after any Live upgrade.
2. ✅ **Selective rollback conflicts with Live's stack API — resolved by
   scoping, 2026-08-01.** The roadmap's first user story ("undo the
   quantize" preserving mutations that came after it) cannot be served by
   Live's history: no installed LOM member targets an older undo entry, and
   replaying later arbitrary tools is not a general inverse. The roadmap's
   **Goal** line is explicitly either/or and the step-granularity branch is
   the one this plan takes, so this is no longer a blocking question:
   **implement against conventional top-of-stack undo.** Live has no undo
   history palette and no selective revert either, so this matches the host
   rather than falling short of it — the roadmap's user story was narrowed to
   say so on 2026-08-01, and "Approach considered and rejected" above records
   the design that was turned down and why.

Everything else the plan relies on was closed by measurement on 2026-08-01
(see Context): the reproduction, the fix, empty-pair cost, unmatched-`end`
safety, non-refcounting, and leaked-`begin` behaviour.
