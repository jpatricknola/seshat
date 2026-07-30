# Plan — Verify `create_track` actually succeeds

Roadmap item: "Verify `create_track` actually succeeds".
Evidence: finding #6 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md),
whose reviewer response agrees with the recommendation as written: apply the
pre-count/post-count verification that `Registry.ensure_created/2` already
performs for return tracks, sitting *directly above* the defective code in
the same file. This is applying an existing local pattern, not designing one.

## Context

`create_and_name_track/2`
([registry.ex:203-217](../lib/seshat/commands/registry.ex#L203)) reads the
pre-create track count, fires `/live/song/create_midi_track` (or
`_audio_`) with `-1` (append), fires the rename at that count, and returns
`{:ok, count}` — all without ever checking the count rose. The create is a
fire-and-forget method call, and Python's `_call_method`
([priv/AbletonOSC/abletonosc/handler.py:27-35](../priv/AbletonOSC/abletonosc/handler.py#L27))
deliberately catches Live API exceptions and only logs them, so a refused or
dropped create is invisible on the wire. When that happens today:

- The rename targets an index one past the last track — AbletonOSC's
  `track.py` indexes `song.tracks` directly, so it raises inside the
  callback, gets logged in Live, and nothing comes back.
- Seshat replies `"Created midi track '<name>' at index N"` and the follow
  cam steers to index N, which either doesn't exist or is someone else's
  track.
- The model now holds a bogus index; subsequent `load_device` or
  `write_midi_notes` calls target the wrong track — mutation against wrong
  state, downstream of a reported success.

The sibling flow ten lines up, `create_return_track`, already does this
right: count before, create, count after, `ensure_created/2` decides from
the two counts, and only then the rename. This plan makes the regular-track
flow symmetric. Two asymmetries surfaced by research keep it from being a
pure copy:

- **The count address differs in provenance.** The return probe is Seshat's
  own extension, so its 2s `@return_probe_timeout` doubles as an
  "is `return_track.py` installed?" check. `/live/song/get/num_tracks` is
  upstream — a timeout there means Live isn't answering at all, the same
  condition every other upstream query faces, so it uses Transport's default
  5s and its timeout messages talk about Ableton, not `mix
  abletonosc.install`.
- **The cap branch doesn't transfer.** Live caps returns at 12 in every
  edition, which is why `ensure_created/2` can name the limit and point at
  `delete_return_track`. Regular tracks are uncapped in Standard/Suite and
  capped only in Intro/Lite (⚠️ — see Open questions), and nothing on the
  wire reveals the edition. The track variant therefore has no confident
  cap branch: an unchanged count gets one honest message that names both
  possible causes.

There is also a latent bug the rewrite removes for free: the current `with`
has no `else`, so a malformed `num_tracks` reply (anything other than a
single value the pattern `[count]` matches — or a stale straggler carrying
the wrong shape) falls through unmatched… and `{:ok, {addr, args}}` *does*
match the handler's `{:ok, index}` clause, producing
`"Created midi track 'x' at index {...}"` with a tuple interpolated as the
index. The new count helper pattern-guards `is_integer(count)` and returns
an explicit error otherwise, exactly as `return_track_count/1` does.

## OSC contract

**No new addresses, no Python half, no pin bump, no
`mix abletonosc.install`.** Every address below is already in use in this
file and verified against
[abletonosc-api-docs.md](abletonosc-api-docs.md):

| Address | Request args | Reply | Notes |
|---|---|---|---|
| `/live/song/get/num_tracks` | — | `[count]` | Upstream; regular tracks only (excludes returns/master). Bare count, **no echo** — see the correlation note below |
| `/live/song/create_midi_track` | `[-1]` | none | Method call; `-1` appends. Failure is logged in Live, silent on the wire |
| `/live/song/create_audio_track` | `[-1]` | none | Same |
| `/live/track/set/name` | `[track_index, name]` | none | Silent setter, per the settled rule; now guarded by the count check |

Ordering: the post-create count query is sent after the create datagram on
the same loopback socket, and `osc_server.py` processes datagrams in receive
order; `song.create_midi_track` is synchronous in the LOM, so the post-count
reflects the create. This is not an assumption — it is exactly the ordering
the shipped `create_return_track` flow has relied on live since 2026-07.

Correlation caveat (documented, accepted): `num_tracks` replies carry no
echo, so a straggler reply from an earlier abandoned query (e.g. a
`Session.State` refresh probe) could in principle satisfy the pre- or
post-count with a stale number. That is residual collision class 1 of
[PLAN_serialize_osc_queries.md](archive/PLAN_serialize_osc_queries.md)
("Serialize OSC queries", shipped 2026-07-30), which narrows it to a timeout-plus-adjacency
window but cannot remove it without a wire request id (declined permanently).
With the `+1` guard below, a stale count yields at worst a false "did not
create" or "count changed by more than one" — both of which honestly tell the
user to check `get_session_state` — rather than the status quo's unverified
success. No extra machinery is warranted; this plan neither depends on that
plan nor blocks it.

## Part 1 — `Registry`: count both sides of the create

All in [lib/seshat/commands/registry.ex](../lib/seshat/commands/registry.ex).

1. **New private `track_count/1`**, mirroring `return_track_count/1`'s
   shape: queries `/live/song/get/num_tracks` with Transport's default
   timeout (no explicit timeout arg — upstream address, not an install
   probe; say so in a comment, since the neighbouring helper's 2s constant
   invites copying), pattern-guards `is_integer(count)`, returns
   `{:ok, count}` / `{:error, "Unexpected reply from
   /live/song/get/num_tracks: <inspect(args)>"}`, and catches `:exit` with a
   context-specific message:
   - `:pre_create` → `"Timed out reading the track count, so nothing was
     created. Check that Ableton Live is running with AbletonOSC enabled."`
   - `:post_create` → `"Sent the create, but timed out confirming the new
     track count afterwards — a track may have been created but could not
     be confirmed or named. Check get_session_state for an unnamed extra
     track before creating another."`
2. **Rewrite `create_and_name_track/2`** as the return flow's twin:

   ```
   with {:ok, before_count} <- track_count(:pre_create),
        :ok <- Transport.send_message(osc_address, [-1]),
        {:ok, after_count} <- track_count(:post_create),
        :ok <- ensure_track_created(before_count, after_count),
        :ok <- Transport.send_message("/live/track/set/name", [before_count, name]) do
     {:ok, before_count}
   end
   ```

   The "pre-create count *is* the new track's index" comment stays — still
   true, still the reason the create sends `-1`, and now only reached when
   the count rose by exactly one. `execute/1`'s `:create_track` clause is
   unchanged: it already wraps this in `Session.State.refresh()` and returns
   `{:ok, index}`.
3. **New public `ensure_track_created/2`**, pure, `@spec` and `@doc` like
   its sibling — public for the same reason: it is the pure half of a
   sequence that otherwise needs a live Ableton to reach. Three clauses:
   - `after_count == before_count + 1` → `:ok`. **Exactly one**, not "went
     up": `before_count` is only the new track's index if ours is the sole
     track that appeared. The user's own hands in Live are the realistic
     second writer here — Seshat can't easily race itself (Transport
     serializes queries through one `pending` slot), but a Command-T in the
     Live window while the tool runs is entirely ordinary for this product,
     and a stale count reply (accepted above) has the same shape. Renaming
     index `before_count` after a jump of two would rename *the user's*
     track.
   - `after_count > before_count + 1` → `{:error, "The track count went from
     <before> to <after> — more than one track appeared, so Seshat can't
     tell which one it created. Nothing was renamed. Check
     get_session_state and rename the new track by hand, or delete the
     extras and try again."}` No index is returned, so no downstream
     mutation targets a guess.
   - Otherwise (unchanged or decreased) → `{:error, "Ableton did not create
     a track — the count went from <before> to <after>. Nothing was renamed.
     Some Live editions (Intro/Lite) cap the number of tracks; otherwise the
     create message may not have landed. Check get_session_state and try
     again."}` One clause for both, always reporting both numbers (the
     registry test file's "reports both numbers honestly" rationale applies
     verbatim).

   ⚠️ The `+1` guard tightens attribution; it does not close it. A count of
   `before + 1` still doesn't *prove* the new track is ours — the user could
   add one by hand in the same window that our create silently failed. That
   residue is what a name read-back would catch, and why the Out of scope
   entry on it records a gap rather than a non-issue.
4. **Rename the return sibling `ensure_created/2` →
   `ensure_return_created/2`, and give it the same `+1` guard.** With two of
   these side by side, the generic name stops meaning anything. Grep confirms
   exactly two reference sites: its call in `execute/1`'s
   `:create_return_track` clause and the four assertions in
   [test/seshat/commands/registry_test.exs](../test/seshat/commands/registry_test.exs).
   Backwards compatibility is a non-goal (CLAUDE.md), and the rename keeps
   the pair self-describing.

   The guard change is a **deliberate, minimal widening of this plan's
   blast radius** (flagged here so `/pr-review` reads it as planned, not as
   drift): the return flow has the identical hazard — returns can be added
   by hand in Live — and leaving `>` there while the track twin uses
   `== + 1` would trade the asymmetry this plan exists to remove for a new
   one. Its clause order becomes: exact `+1` → `:ok`; jump of more than one
   → the ambiguity error, worded for returns; `before_count >= 12` → the
   existing cap message, untouched; fallback → the existing below-the-cap
   message, untouched. The ambiguity clause sits *above* the cap clause;
   both existing cap paths are unchanged in wording and still reachable
   (a jump past the cap is not a real state).
5. **Moduledoc**: add `/live/song/get/num_tracks  [] → [count]` to the
   address list, which currently omits it despite the file using it.

## Part 2 — `Handlers`: stop `inspect`-wrapping the new string errors

In [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex), the
`create_track` clause (~1065) funnels every error through
`{:error, inspect(reason)}` — fine while Registry could only return
Transport's atom/tuple errors, wrong once it returns crafted user-facing
strings (they'd arrive quote-wrapped with escaped internals). Add the
`{:error, reason} when is_binary(reason) -> {:error, reason}` clause ahead
of the `inspect` fallback, exactly as the `create_return_track` clause
(~1342-1357) already has it. Success branch, reply text, and
`FollowCam.steer/2` are untouched — steering on `{:ok, index}` is now
steering onto a *verified* track, which is the point.

**No change to `Definitions`, no tool count bump, no MCP component work** —
this is a behaviour fix inside an existing tool, not a new tool. The tool's
description already promises nothing about verification, so it stands.

## Part 3 — Tests

In [test/seshat/commands/registry_test.exs](../test/seshat/commands/registry_test.exs)
(pure layer only — `execute/1` reaches `Transport.query/3` and stays
untested, per [.claude/rules/testing.md](../.claude/rules/testing.md); the
file's moduledoc already says exactly this):

1. Update the existing `describe "ensure_created/2"` block to the new
   `ensure_return_created/2` name. The four existing assertions all still
   hold as written — `(0, 1)` and `(2, 3)` are both exactly `+1`, and the
   three error cases are unaffected — so only the name changes. Add one
   test: `(3, 5)` → `{:error, message}` asserting both numbers and
   `refute message =~ "limit of 12"`, since an ambiguous jump is not a cap
   problem.
2. New `describe "ensure_track_created/2"`:
   - count rose by exactly one → `:ok` (e.g. `(0, 1)`, `(7, 8)`).
   - **count jumped by more than one → `{:error, message}`** (e.g.
     `(3, 5)`); assert both numbers appear, `"Nothing was renamed"`, and
     that the message says more than one track appeared. This is the
     concurrent-mutation case: a `>` comparison would have returned `:ok`
     here and renamed index 3, which may be the user's track.
   - unchanged count → `{:error, message}`; assert both numbers appear
     ("went from 3 to 3"), `"Nothing was renamed"`, the edition-cap hedge,
     and `refute message =~ "limit of 12"` — the return cap must not leak
     into track messages.
   - count went down → `{:error, message}` reporting both numbers ("went
     from 3 to 2"), same honest-reporting rationale as the return tests.

No new test files; no test touches Transport.

## Part 4 — Docs that record the wart

1. [docs/TOOL_AUDIT.md](TOOL_AUDIT.md), `create_track` inventory row
   (line ~166): replace the **Known wart** note with a fixed record in the
   style of the `create_return_track` row, e.g. `Verifies the count rose
   before naming and reporting the index (finding #6, fixed 07/2026); an
   unchanged count errors honestly instead of returning a bogus index.`
2. Same file, the "At a glance" line (~78): drop `create_track
   verification` from the outstanding list and adjust the count — the other
   three items stay (their plans handle their own rows when they ship).
3. [REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md) is a dated record —
   leave finding #6 as written; the roadmap entry's deletion at `/ship`
   time is the closure signal, per the roadmap's own header.

## Testing

- **Pure (`mix test`)**: Part 3 covers the decision function completely;
  the count-helper and sequencing changes are shape-identical to the
  already-shipped return flow. `mix precommit` before done.
- **Live Ableton (one-time sanity, not a new `/smoke-test` item)**: with
  Live open, `create_track` a MIDI and an audio track — expect the same
  success replies as today, correct indices, correct names, follow cam on
  the new track; the added cost is one `num_tracks` round-trip (~ms on
  loopback). ⚠️ The *failure* branch cannot be triggered on demand on a
  Suite install (no reachable track cap, and a dropped loopback datagram
  can't be arranged) — the error path's realism rests on the unit tests
  plus the return-track precedent. `create_track` is already exercised by
  [validation-script.md](validation-script.md) and the smoke checklist;
  nothing new to add there.

## Out of scope

(Verification anchors for `/pr-review` — any of these in the diff is a plan
violation.)

- **No Python, no submodule pin bump** — nothing under `priv/AbletonOSC`
  changes.
- **No name-echo verification after the rename** — a recorded gap, not a
  non-issue. `/live/track/get/name` exists and echoes its index, so the
  check is mechanically available (the `ensure_clip/4` echo pattern in this
  same file is the shape it would take). It stays out for three reasons, in
  order of weight:
  1. **It doesn't serve this item's harm model.** What made finding #6
     matter is the model holding a *bogus index* and mutating against it —
     `load_device` and `write_midi_notes` address tracks by index, not by
     name. A correct index with an unconfirmed name causes no wrong-target
     mutation, and the follow cam has already selected the track for the
     user to see.
  2. **Exact-name matching would invent false failures.** `create_track`'s
     `name` param has no emptiness or shape validation, and Live substitutes
     its own default for an empty name, so a strict echo comparison would
     hard-fail a create that genuinely worked.
  3. **Symmetry.** `create_return_track` doesn't verify its rename either.
     Verifying the mutation landed across every create/rename/delete flow is
     "Verify destructive mutations before reporting success" — that item's
     scope, not this one's, and its response separately rejects structured
     OSC acknowledgements (a Python-side change; a read-back getter is not
     that, which is why this is a scope call rather than a settled no).

  If it is ever taken, the shape is **degraded success, never a hard
  error**: return `{:ok, index}` with "the track exists at index N, its name
  couldn't be confirmed", in both create flows at once. Note that the plan
  does *not* lean on `.claude/rules/osc.md`'s "setters are guarded by their
  getter first" here — that rule covers the create, which the count check
  now guards, and it does not settle the rename either way.
- **Other structural mutations** (`duplicate_track`, `create_scene`,
  `duplicate_scene`, the deletes) — that is the "Verify destructive
  mutations before reporting success" item, a broad slog deliberately
  ranked apart from this near-free fix. Do not grow into it.
- **Transport correlation changes** — the "Serialize OSC queries" plan
  ([PLAN_serialize_osc_queries.md](archive/PLAN_serialize_osc_queries.md)); the
  stale-count residual is accepted above, not solved here.
- **`Session.State` refresh semantics** — the "Stop fabricating session
  state" plan
  ([PLAN_stop_fabricating_session_state.md](PLAN_stop_fabricating_session_state.md))
  owns `do_refresh/1`'s `num_tracks` failure branch; this plan's calls to
  `Session.State.refresh/0` are unchanged and neither plan conflicts with
  the other in `registry.ex` (the fabrication plan touches it nowhere; the
  serialization plan touches only the `ensure_clip/4` comment).
- **No `Session.State.refresh/0` on the new failure paths.** Tempting, and
  wrong about how the mirror works: the mirror is kept fresh by *push*, not
  by that call. `song_structure.py`'s tracks listener fires on any add or
  delete and pushes `/live/song/get/tracks`, which `Session.State` treats as
  a change signal ([state.ex:160](../lib/seshat/session/state.ex#L160)), so
  a track that was created but couldn't be confirmed is already in the
  mirror with no refresh at all. `execute/1`'s existing call is a backstop
  for the lost-datagram case, not the mechanism. For the same reason the
  error messages say "check `get_session_state`" and deliberately **don't**
  say `refresh: true` — that would buy a full re-query round trip against a
  mirror that is already current.
- **CLAUDE.md "Current focus" / roadmap renumbering** — `/ship`'s job when
  this lands.

## Open questions

1. ⚠️ **What Live Intro/Lite actually does at its track cap.** Whether the
   LOM raises (caught and logged by `_call_method`) or silently no-ops at
   the edition's track limit is undocumented and untestable here — the dev
   machine runs Suite, which has no cap. Unresolvable without an Intro/Lite
   install, and deliberately not worth resolving: either behaviour yields
   an unchanged count, which is the observable truth the check reads, and
   the error message already hedges by naming the edition cap as one of two
   possible causes rather than asserting it. Nothing in the implementation
   depends on the answer.
2. ⚠️ **Post-create count timing against a real Live.** That the post-count
   reflects a synchronous create is verified by precedent (the shipped
   return-track flow) and by `osc_server.py`'s in-order processing, but
   only the one-time live sanity check in Testing can confirm it for the
   regular-track addresses on this machine. If it ever proved flaky the
   symptom would be false "did not create" errors on visibly created
   tracks — loud, honest, and diagnosable, not silent. The plan assumes
   the precedent holds.

Decisions made rather than left open (recorded per the plan skill): **two
functions, not one parameterised one** — the return variant has a
confident 12-cap branch naming `delete_return_track`, the track variant
must hedge; forcing them through one function means threading kind-specific
caps and tool names through arguments for no reuse worth having.
**Default 5s timeout for `track_count/1`**, not the sibling's 2s — the 2s
constant exists to fail fast on a *missing extension*, which cannot be the
failure mode of an upstream address. **Rename `ensure_created/2` →
`ensure_return_created/2`** — two call sites, no compat obligation, and
the symmetric pair documents itself. **Exactly `+1`, not "went up"**, in
both twins — `before_count` is a *claim about which index is ours*, not just
a did-it-happen check, and only an increase of exactly one supports that
claim; the cost is one extra clause and the failure it prevents is renaming
a track the user made by hand. **The handler's success reply text is
unchanged** — it was always the right message; it just wasn't always true.
