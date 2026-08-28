# Handoff: the tool surface after PR #77

_Written 2026-08-28 against PR #77 `consolidation-continued`, head
`6d9083f65ec8a35d42b992c71ce63f5afb466377`. Suggested home:
`docs/HANDOFF_tool_surface.md`._

Two things are in here: a review of PR #77 with the one change I'd make before
merging, and the problem PR #77 does **not** solve — which is the one that
prompted it.

Every line number below is at head `6d9083f` and will drift. Grep the function
name, not the line.

---

## Verdict on PR #77

**Merge it, after fix #1 below.** The consolidation axis is right and the
implementation is sound on independent re-derivation.

### Land it as a quality fix, not as the scaling fix

This matters more than it sounds, so it goes above the findings rather than
below them.

PR #77 was ranked #1 as the answer to tool-surface growth. **It is not one.** It
removed fifteen tools and the roadmap plus the generation epic will add ~30, so
the count goes 52 → ~82 — past the 80-tool review line in
`.claude/docs/adding-a-tool.md`. What the PR actually fixed is *selection
accuracy*: the model picking wrong among confusable names, silently. That is a
real and worthwhile fix. It is a different fix.

The risk in merging it under the original banner is specific: the scaling item
gets marked done, the real work gets deferred, and the surface arrives at ~82
tools with everyone believing this was solved in August 2026. When updating
`docs/ROADMAP.md`, say what shipped (confusable-name selection errors, closed)
and leave the tool-count question **explicitly open** as its own entry. Do not
let "Consolidate the tool surface — 67 tools to 52" read as the end of the
subject.

Be accurate about what it buys, because the PR description and ROADMAP entry
oversell one axis and undersell the other:

- **Selection accuracy: real win.** `set_track_volume` /
  `set_return_track_volume` / `set_master_volume` is the textbook confusable
  triple, and the failure was silent — pan track 0 when the master was asked
  for. The merge does not eliminate that discrimination, it moves it from tool
  name to `target` enum. That is an improvement for three specific reasons, and
  the third is load-bearing:
  1. the contrast is stated in one place ("returns have no arm; the master has
     volume and pan only") instead of being implicit across thirteen
     descriptions the model never sees adjacently;
  2. a wrong `target` gets a refusal naming what that target actually has;
  3. `ensure_mixer_supported/2` runs **pre-send**, all-or-nothing.
  Without (3) this would be a wash. Do not remove that pre-flight check in
  future refactors without re-deciding this.
- **Context budget: marginal, and do not quote it as a win.** Like-for-like
  Elixir-side, 62,784 → 57,450 bytes: ~8%, for fifteen tools removed. The
  descriptions absorbed what the names gave back — `set_mixer`'s description is
  ~1.4KB and `set_clip_properties` is 3,585 bytes, 6% of the whole surface in
  one tool. The client-visible `stats` number (58,709) is the one to quote and
  is not comparable to the 62,784 planning baseline; `docs/smoke_tests/auto/mcp-surface.md`
  already says this correctly.

---

## 1. Blocking: `set_mixer` silently drops unrecognized property keys

**The defect.** A call mixing good and misspelled keys applies the good ones and
says nothing about the rest.

`{"track": 0, "volume": 0.6, "panning": -0.5}` sets volume, drops `panning`, and
replies with a confident success line for volume only. The model has no signal
that half its call evaporated, and neither does the producer — who asked for pan.

**Why it gets through.** Two layers, neither of which reports.

`lib/seshat/tools/validation.ex`, `violations/3` iterates the *schema's*
properties, so extra params are never examined:

```elixir
# Params not named in the schema are ignored: handler clauses already ignore
# unknown keys, and Peri governs the MCP wire.
defp violations(%{properties: properties} = schema, params, path) when is_map(params) do
```

Then `handlers.ex:1789` takes only the known keys:

```elixir
defp do_call("set_mixer", params) do
  target = Map.get(params, "target", "track")
  changes = Map.take(params, @mixer_properties)
```

`@mixer_properties` (handlers.ex:213) is `~w(volume pan mute solo arm name)`.
`panning` is not in it and not in the schema, so `Map.take/2` discards it
without a trace. `mixer_reply/4` then builds the reply from what was *written*,
so the omission is invisible in the result too.

**The one place it is caught is the unreachable one.**
`ensure_mixer_changes/1` (handlers.ex:4280) fires only when `changes` is
**empty** — every key garbage:

```elixir
defp ensure_mixer_changes(changes) when map_size(changes) == 0 do
  {:error,
   "Nothing to set — pass at least one of #{Enum.join(@mixer_properties, ", ")}. Keys the " <>
     "schema does not name are dropped before this point, so if you did send a value, " <>
     "check its spelling against that list. Nothing was sent."}
end
```

That message is well written. It cannot fire for the realistic case.

**Why this is worth blocking on.** It is a failure mode the thirteen setters did
not have — `set_track_pan` with a bad key was a schema error, not a half-applied
write. And it contradicts the decision the rest of this PR is built on: a
property the *target* lacks is refused by name with nothing sent, but a property
the *schema* lacks is dropped in silence. Same class of error, opposite
handling, in the same function chain.

**The fix.** Reject unknown keys the same way, before anything is sent.

- In `do_call("set_mixer", params)` (handlers.ex:1789), add a check ahead of
  `ensure_mixer_changes/1` that diffs `Map.keys(params)` against
  `@mixer_properties ++ ~w(target track)` and errors naming the offenders.
  Reuse the existing wording pattern — name the keys, name the legal set, end
  with "Nothing was sent."
- Keep `ensure_mixer_changes/1` for the genuinely-empty case; the new check
  makes its "check its spelling" sentence redundant, so trim that clause.
- Same treatment for `set_clip_properties` and `edit_notes`, which have the same
  optional-property-bag shape and therefore the same hole. Check before
  assuming — I only verified `set_mixer`.

**Test.** `test/seshat/tools/handlers_test.exs`: a `set_mixer` call carrying one
valid and one invalid property returns `{:error, _}` naming the invalid key, and
`Seshat.Test.OSCSink` recorded **zero** messages. The zero-sends assertion is
the point; a test that only checks the string would pass on a partial write.

**Smoke test.** Add to `docs/smoke_tests/auto/mixer.md` beside "A property the
target lacks is refused with nothing sent" — same shape, misspelled key instead
of unsupported one.

---

## 2. Non-blocking: "all-or-nothing" is true pre-flight, false on the wire

`apply_mixer/3` stops at first failure, so a multi-property call to a return can
land partially. `mixer_partial_error/5` reports that honestly — it names what
"was already sent and may have landed" — so the behaviour is fine. The module
comment at handlers.ex:219–224 frames it as all-or-nothing without qualifying
that this covers only the property pre-check. Tighten the wording so the next
reader does not trust an atomicity that is not there.

---

## 3. Non-blocking: `handlers.ex` is at 6,432 lines and `set_mixer` is spread across three regions

- attributes at handlers.ex:208–235
- the `do_call` clause at 1789–1811
- the helper block at 4278–4619, of which `mixer_write/4` is 14 clauses / ~172
  lines (4432–4599)

The attributes sit ~4,000 lines from the code that uses them. The dispatch
itself is *good* — the target×property matrix is data (`@mixer_supported`,
handlers.ex:225), not control flow, so adding a strip is one map entry plus its
clauses and nothing existing changes. This is not a thicket; it is a
well-shaped thing in the wrong file. `Seshat.Tools.Mixer` is the natural next
extraction, on exactly the principle that already justified pulling out
`NoteEdit`. Do it when the next mixer change lands, not as its own PR.

The shallow duplication worth knowing about: the `"volume … — was …"` reply
strings recur across the return/master/cue clauses, and the `query_echoed`
guard-read boilerplate repeats five times for returns. ~60 lines of near-
duplicate text — the place to expect drift.

Note also: the consolidation pattern makes each *tool* bigger, so this file-size
pressure compounds with every future merge. Worth a line in
`.claude/docs/adding-a-tool.md` next to the naming rule.

---

## Verified correct — no action, recorded so it is not re-litigated

- **`edit_notes` undo wrapping is genuine.** `edit_notes` is not in
  `@unstepped_names`, so dispatch routes through `undo_stepped/2`
  (handlers.ex:382) under `:global.trans` (handlers.ex:340). The remove and the
  add both run inside the `try`, so one Live undo entry covers both, and the
  `after` closes the step even on an exception. The failure message at
  handlers.ex:5645 tells the model to "Call undo immediately to put them back"
  — that advice actually works. It is untested (ROADMAP "Pin the wording of
  `edit_notes`' partial-failure message"), which is defensible: the branch
  cannot be provoked through the harness because `:gen_udp.send/4` does not
  return `{:error, _}` in practice.
- **`edit_notes` conflicting keys are refused, not silently resolved.**
  `NoteEdit.validate/1` runs first in the `with` at handlers.ex:2527.
  `velocity` + `velocity_delta` → refused. `delete: true` + any delta → refused,
  naming the offending keys. `delete: false` alone → refused. `duration` +
  `shift` is correctly *not* a conflict; they touch different fields.
- **`edit_notes` confirms both directions.** `confirm_edited_notes/8` checks
  every edited note is present *and* no matched original survived, so a
  duplicated phrase cannot be reported as a transpose.
- **`set_mixer` missing `track` is a clean error.** `required: []` in the schema
  is compensated in `mixer_index/2` (handlers.ex:4312): no defaulting to 0, the
  parameter is named, the message is target-aware, nothing is sent.
- **Minor, no action:** `mixer_index/2` accepts a float and `trunc`s it.
  Unreachable over the wire — `Validation` rejects a float against
  `type: "integer"` first — so it only fires on direct in-process `call/2`.

---

## The problem PR #77 does not solve

Three things get conflated under "too many tools," and only one of them is the
actual constraint.

1. **Bytes.** ~58KB, call it 15k tokens. Annoying, not fatal.
2. **Selection accuracy.** Picking wrong among confusable options. This is what
   PR #77 fixed.
3. **Attention dilution.** Even with perfectly distinct names, a model reasoning
   over 80 tools reasons worse about all of them than over 20.

Merging helps (1) and (2). It does nothing for (3), because a merged tool still
occupies a slot in the list the model scans. The trajectory is 52 now, plus
~30 from the roadmap and the generation epic on the *new* pattern, so ~82 —
past the 80-tool review line `.claude/docs/adding-a-tool.md` sets. **PR #77 buys
one round, not a ceiling**, and another merge pass will not rescue it.

### Why both, and not just scoping — settled 2026-08-28

The obvious objection is that if scoping is coming, PR #77 was wasted work.
Recorded here because it will be raised again:

**Scoping and merging do not substitute for each other, and they fail to in
exactly the case that matters.** Scoping cuts *across* domains — mixing in one
set, note editing in another, library in a third. Confusability lives *within* a
domain. `set_track_volume` / `set_return_track_volume` / `set_master_volume` are
confusable precisely because they are one verb on neighbouring targets, which
means every plausible scoping scheme puts all three in the same set. The
reduction scoping buys removes the tools that were never going to be confused
with each other. The confusable triple survives every phase split you would
design.

So scoping reduces attention dilution; merging reduces selection error.
Different failure modes, and the merged one is the silent one.

Three supporting reasons for this ordering:

- **Scoping is not yet known to be viable.** Whether Claude Desktop honours
  `list_changed` mid-conversation is unanswered (next step 7). PR #77 is
  verified green against Live 12.4.5. Do not trade a known improvement for an
  unvalidated one.
- **Phase sets are designed over units.** Cutting them around 67 units and then
  re-cutting around 52 is the same work twice.
- **The original ranking argument gets stronger.** The ROADMAP put this above
  its quotient because every tool added afterwards would be added on the wrong
  pattern. ~30 are about to be added. Deferring means minting all of them on
  one-thing-one-tool and consolidating later against a bigger surface.

The honest cost of merging, recorded so it is not discovered as a surprise:
property-bag tools carry new failure modes, and §1 is the proof. That tax
recurs with every future merge. It is worth paying because the alternative is
not "no tax" — it is the silent wrong-target write.

### Mechanisms, assessed

- **Server-scoped tool sets + `notifications/tools/list_changed`.** Shipped and
  spec-blessed: declare the `listChanged` capability, change what `tools/list`
  returns, notify, client re-fetches. **Verify Claude Desktop and Claude Code
  honour it before building on it** — ecosystem support has been uneven and a
  silent no-op would be hard to notice. This is the recommended direction.
- **Tool search (`find_tool` + `call_tool`).** Proven, but it costs a round trip
  before every unfamiliar action, and a producer is sitting at Live waiting.
  Right for a long tail, wrong for the hot path.
- **`tools/list` filtering as a protocol feature.** Proposed (SEP-1821: a
  `query` param plus `ServerCapabilities.tools.filtering`), not shipped. Track
  it alongside ROADMAP "Adopt MCP `2026-07-28` when Anubis supports it". Do not
  wait for it.
- **Pagination.** Red herring. Transport, not context — clients page through
  everything and hand it all to the model.
- **Code mode** (one `run_code` tool over a generated API). Biggest token lever,
  worst fit here. It dissolves `Validation` reading bounds out of `Definitions`,
  and it breaks the standing decision that tools name reversible producer
  actions with one undo step. **Rule it out explicitly** rather than leaving it
  open for someone to re-propose.

### The shape I'd build

A permanent core of ~20 — transport, `get_session_state`, view and selection,
`create_track` / `delete_track` / `set_mixer`, clip fire/stop, `undo` / `redo`
— plus coarse phase sets: notes-and-clips, devices, library, routing. That is
~60% off the hot path, and the core alone covers most of a session.

### The trap — do not do this

Seshat has something almost no MCP server has: a live session mirror and a
follow cam that already knows *and controls* which pane is showing. It is very
tempting to scope the tool set reactively off Live's own state.

**Don't.** Tool definitions sit at the front of the context, so every list
change invalidates the prompt-cache prefix and everything downstream of it.
Thrashing the list on every view change costs more in re-processing than it
saves in tools. Change the set rarely, at coarse declared boundaries, never
reactively.

### The prerequisite

Scoping without usage data is guessing which tools are hot. The plan already
notes that a repeatable tool-selection prompt corpus becomes a gate when
generation moves onto the roadmap. This makes it a **prerequisite**, not a gate.

The reason is specific: unlike the mixer merge, a wrong scoping decision fails
*invisibly* — the capability is simply absent and the model reports it cannot do
the thing. That is precisely the failure class `set_mixer`'s refusal path was
built to eliminate, reintroduced one level up. Scoping without an eval corpus
trades a loud failure for a quiet one.

---

## Suggested next steps, in order

1. **Fix the unknown-key hole in `set_mixer`** (§1), with the zero-sends test.
   Check `set_clip_properties` and `edit_notes` for the same shape.
2. **Tighten the all-or-nothing comment** (§2). One-line change.
3. **Merge PR #77**, and write the ROADMAP entry as a *selection-accuracy* fix
   with the tool-count question left open as its own entry. See "Land it as a
   quality fix" above — this is the step most likely to be skipped, and skipping
   it is how the surface reaches ~82 tools with the problem marked solved.
4. **Run the manual `conversation.md` routing check** — "Mixer and note edits
   route to one call each." It is the whole bet of the PR and it is the one
   verification still needing a person. Everything else went green 2026-08-28.
5. **Clear the two known carry-overs**: `priv/AbletonOSC/FORK_GAPS.md`'s
   note-modification row still points at the removed "Modify a note in place";
   the fork clone was on an unmerged branch when this shipped.
6. **Build the tool-selection eval corpus** before the next batch of tools, not
   after. It is the prerequisite for everything below it.
7. **Probe `list_changed` against Claude Desktop and Claude Code.** A one-
   afternoon spike: flip a tool in and out of `Definitions.all()`, fire the
   notification, see whether the client re-fetches and whether the model's
   available set actually changes mid-conversation. The whole scoping direction
   depends on the answer, and the answer is cheap.
8. **Then** design the core-plus-phases split, informed by 6 and 7.

## Open questions

- Does Claude Desktop re-fetch on `list_changed` mid-conversation, or only at
  session start? Unverified. Step 7 answers it.
- Which tools are actually hot? Unmeasured. The ~20-tool core above is a guess
  from reading `Definitions`, not from usage.
- Do `set_clip_properties` and `edit_notes` share the unknown-key hole? Likely
  from their shape, but only `set_mixer` was read closely.
