# Plan — Stop fabricating session state after OSC failures

> **Archived 2026-07-30 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. The fix lives in
> `Seshat.Session.State` (failed queries yield `nil`, never a fabricated
> default) and `Seshat.Tools.Handlers` (`get_session_state`'s formatters
> render `nil` as stated unknowns, plus `record_length_from/2` refuses a
> `bars` request against an unknown time signature). Review approved with
> nits, none blocking: one real low-severity gap survives —
> `return_track_label/1` still renders a `nil` return name as `("")` instead
> of omitting the label, now tracked as a grab-bag follow-up in
> [../ROADMAP.md](../ROADMAP.md); the other two nits were stale comments
> describing removed fallback behavior, left as-is since they don't mislead
> about current code once this banner and the roadmap item exist.

Roadmap item "Stop fabricating session state after OSC failures".
Evidence: finding #7 in
[../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md), whose reviewer response
narrows the fix to exactly this — delete the plausible defaults; defer the
monitored-worker/freshness-metadata half as a risk to revisit only if the
blocking window is ever observed.

## Context

When a refresh query goes unanswered, `Seshat.Session.State` invents an
answer. `do_refresh/1`
([state.ex:337-344](../lib/seshat/session/state.ex#L337-L344)) falls back to
120.0 BPM, 4/4, not-playing, root note 0 (C) and "Major" on any failed song
query; `read_tracks/2` fabricates per-track values the same way (volume 0.85,
pan 0.0, mute/solo off, name "Track N"), `read_return_tracks/2` a "Return N"
name; and a failed `/live/song/get/num_tracks` probe keeps the *previous*
track list — after a set load, the previous **set's** track list.

The model cannot tell any of this from fresh state, and it doesn't merely
repeat it: it writes bar lengths and note positions against the fabricated
time signature, and makes relative mixer moves against the fabricated 0.85
("turn the delay down a bit" from a fictional 0.85 is an *increase*). A
stated unknown is strictly better than a plausible wrong number — but it has
to read as one in `get_session_state`'s reply, which is the second half of
this plan.

The representation already exists in this module and is documented as policy:
a return track's `volume` is `nil` when its one query went unanswered
("never a guessed number"), `master` is `nil` when unreadable ("`nil` is
'unknown', never 'zero'"), and `Handlers.volume_field/1` renders that `nil`
honestly. This plan extends that one rule to every mirrored value: **a query
that fails yields `nil`, and `nil` renders as unknown.**

Two constraints research surfaced, both making the cheap fix safe:

- **`nil` self-heals whenever Ableton is actually alive.** Every refresh
  re-subscribes all listeners, and the fork's `AbletonOSCHandler._start_listen`
  ([handler.py:94-97](../priv/AbletonOSC/abletonosc/handler.py#L94-L97))
  immediately pushes the current value on subscription. So a field nil'd by
  one lost query reply is repopulated milliseconds later by the
  subscription's own push — `nil` persists only while Ableton genuinely
  isn't answering, which is exactly when a guess is most dangerous.
- **Consumers are few.** `State.song()` is read in exactly two places in
  `Handlers` (`serve_session_state/0` at
  [handlers.ex:2000](../lib/seshat/tools/handlers.ex#L2000) and
  `record_length/1` at
  [handlers.ex:2312](../lib/seshat/tools/handlers.ex#L2312));
  `State.tracks()` only in `serve_session_state/0`. Nothing in
  `AssistantLive`, `Registry`, or `FollowCam` reads song or track state.
  The blast radius of `nil` is those three call sites plus this module's own
  internals.

## OSC contract

**No new addresses and no Python half** — this plan changes what Elixir does
when these existing queries *fail*, not the wire protocol. Reply shapes below
verified against [abletonosc-api-docs.md](abletonosc-api-docs.md); listed
because the pattern-match clauses in the query helpers must keep accepting
exactly these shapes while their failure branch changes from a default to
`nil`.

| Address | Request args | Reply | Failure handling after this plan |
|---|---|---|---|
| `/live/song/get/tempo` | — | `tempo_bpm` | `nil`, was 120.0 |
| `/live/song/get/signature_numerator` | — | `numerator` | `nil`, was 4 |
| `/live/song/get/signature_denominator` | — | `denominator` | `nil`, was 4 |
| `/live/song/get/is_playing` | — | `is_playing` | `nil`, was false |
| `/live/song/get/root_note` | — | `root_note` | `nil`, was 0 (C) |
| `/live/song/get/scale_name` | — | `scale_name` | `nil`, was "Major" |
| `/live/song/get/num_tracks` | — | `num_tracks` | `tracks: nil`, was: keep previous list |
| `/live/track/get/name` | `track_id` | `track_id, name` | `nil`, was "Track N" |
| `/live/track/get/volume` | `track_id` | `track_id, volume` | `nil`, was 0.85 |
| `/live/track/get/panning` | `track_id` | `track_id, panning` | `nil`, was 0.0 |
| `/live/track/get/mute` | `track_id` | `track_id, mute` | `nil`, was false |
| `/live/track/get/solo` | `track_id` | `track_id, solo` | `nil`, was false |
| `/live/return_track/get/name` | `return_index` | `return_index, "ok", name` | `nil`, was "Return N" |

`/live/return_track/get/volume`, `/live/return_track/get/count`, and
`/live/master/get/volume` already answer failure with `nil`/flag — unchanged,
and deliberately absent from the table above, which lists only what changes.
Two of them aren't even reachable by Part 1's refactor: `get/count` and
`/live/master/get/volume` go through `probe/4`, not the query helpers. The
third, `/live/return_track/get/volume`, is a `query_float` call that already
passes `nil` as its default ([state.ex:445-452](../lib/seshat/session/state.ex#L445-L452)),
so it only loses an argument — its behaviour is the model for this whole plan,
not a change in it.

---

## Part 1 — `Session.State`: a failed query yields `nil`, everywhere

All in [lib/seshat/session/state.ex](../lib/seshat/session/state.ex).

1. Drop the `default` parameter from `query_string/5`, `query_float/5`,
   `query_int/5` and from `query_song_float/3`, `query_song_string/3`,
   `query_song_int/3`; their fall-through clause returns `nil`. Removing the
   parameter (rather than passing `nil` at call sites) closes the seam a
   future caller could quietly reopen with a new plausible constant.
2. `read_tracks/2` and `read_return_tracks/2` follow: no more `"Track #{i + 1}"`,
   `0.85`, `0.0`, `"Return #{i}"` arguments. Mute/solo become
   `nil` on failure — add `defp to_bool(nil), do: nil` so the
   `query_int(...) |> to_bool()` pipes pass unknown through (wire pushes never
   carry `nil`, so no live shape gains a nil path).
3. `is_playing` in `do_refresh/1` likewise: `nil` when
   `/live/song/get/is_playing` doesn't answer, via the same `to_bool(nil)`.
4. `init/1`'s `initial_song` becomes the all-`nil` map. Callers can't observe
   it (`handle_continue(:setup, ...)` runs before any `handle_call`), but it
   is the last fabricated constant in the file and keeping it invites reuse.
5. The two `Logger.info` lines in `do_refresh/1` interpolate song fields and
   track names — make them nil-safe (render `nil` as `"unknown"`; a tiny
   private formatter or `inspect/1` is fine, they're logs).
6. Update the moduledoc and the `song`/`tracks` accessor docs to state the
   rule once: *a mirrored value is `nil` when the last read couldn't get it —
   unknown, never a guess* — matching the wording already on
   `return_tracks/0` and `master/0`.
7. [test/seshat/session/state_test.exs](../test/seshat/session/state_test.exs):
   the `state/1` fixture and push tests stand unchanged (they model a
   *mirrored* session, which legitimately holds concrete values).

## Part 2 — A failed track-list read is unknown, not the previous set

Also [lib/seshat/session/state.ex](../lib/seshat/session/state.ex).
`tracks: nil` means "could not read"; `tracks: []` keeps meaning "verified
zero tracks" (`read_tracks/2`'s `count < 1` clause).

1. In `do_refresh/1`, the failure branch of the `/live/song/get/num_tracks`
   probe becomes `%{state | song: song, tracks: nil}` (keep the existing
   warning log). The success branch is unchanged, including
   `subscribe_listeners/1` staying inside it.
2. `stale?/2` gains a first clause: `def stale?(nil, _live_names), do: true`.
   An unknown mirror is stale against *any* pushed list, so the next
   `song_structure.py` push triggers the authoritative re-read — the failed
   refresh heals itself the moment Live pushes. Document the clause; it's a
   public function.
3. `update_track/4` no-ops when `state.tracks` is `nil` (a scalar push for a
   list we don't hold is dropped, the same way a push for an absent index
   already is). `update_return/4` needs no change — `return_tracks` keeps its
   existing `[] + returns_readable?` representation, which is already honest.
4. `reconcile/4`'s not-reproduced warning interpolates
   `Enum.map(Map.fetch!(refreshed, key), & &1.name)` — nil-safe it (render
   the mirror side as `"unknown"` when the list is `nil`). The `unreconciled`
   brake logic itself needs no change: with `stale?(nil, _)` true, a refresh
   that comes back with `tracks: nil` records the pushed list and the brake
   holds exactly as designed.
5. `state_test.exs` additions (all pure `handle_info`/`stale?` paths):
   `stale?(nil, [])` and `stale?(nil, ["Drums"])` are stale; a
   `/live/track/get/name` push onto `tracks: nil` is a no-op; the
   unreconciled brake still holds when the mirror side is `nil`
   (pre-set `unreconciled: %{tracks: [...]}`, `tracks: nil`, push the same
   list → state unchanged, `do_refresh` never called).

## Part 3 — `get_session_state` renders unknown as unknown

In [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex). The
reply has to *read* as unknown — that is the roadmap entry's one design
requirement.

1. Extract the whole reply body from `serve_session_state/0` into public, pure,
   `@doc`'d functions, placed with the existing public formatting helpers around
   `format_return_tracks/2` (handlers.ex:944 — note that section is ~1,000 lines
   above `serve_session_state/0`, not adjacent):

   - `format_song_line/1` — the song map → `{one line, unknown?}`.
   - `format_track_summary/1` — the tracks list-or-`nil` →
     `{the track block, unknown?}`.
   - `format_session_state/4` — `(song, tracks, return_tracks, master)` →
     the complete reply string. It calls the three formatters above
     (including the existing `format_return_tracks/2`), joins them, and
     decides the one trailing sentence in Part 3.4.

   The `unknown?` flags exist for 3.4 — see there for why the composition, not
   the formatter, owns the sentence.

   `serve_session_state/0` becomes: read the four `State` accessors, hand them
   to `format_session_state/4`, `catch`. The aggregator exists because the
   "exactly one trailing sentence for the whole reply" rule is a property of
   the *composition*, not of any one formatter — with composition left inside
   a private function that reads a GenServer, the rule has no reachable test
   and a literal reading of 3.4 + 3.7 could append the sentence twice.
2. `format_song_line/1` renders per field, any `nil` component making its
   phrase unknown:
   - tempo: `"120.0 BPM"` / `"tempo unknown"`
   - time signature: `"4/4"` / `"time signature unknown"` (either field `nil`)
   - playing: `"playing"` / `"stopped"` / `"playing state unknown"`
   - key: `"key: C Major"` / `"key unknown"` (either field `nil`; never call
     `Pitch.pitch_class_name(nil)` — it quietly returns `""`)
3. `format_track_summary/1`:
   - `nil` → `"The track list could not be read from Ableton — it is unknown,
     not empty. Pass refresh: true to re-read."` This message must be
     distinct from the `[]` one, which keeps its current "No tracks in
     current session" text.
   - Per-track `nil` fields render short: name `nil` →
     `Track 2 (name unknown):`, `"pan unknown"`, `"volume unknown"`, and
     mute/solo `nil` → one trailing `" [mute/solo unknown]"`. Known fields
     render exactly as today.
4. In `format_session_state/4`: when *anything* in the reply was unknown,
   append one trailing sentence to the whole reply:
   `"Unknown values mean Ableton did not answer when the mirror was last
   read — pass refresh: true to re-read, and check Ableton is running with
   AbletonOSC enabled."` One sentence for the whole reply, not per field —
   the per-field strings stay short so a half-degraded session doesn't
   drown the readable half.

   "Anything" is the complete list, returns and master included: any `nil`
   song field; any `nil` per-track field; `tracks: nil`; any `nil` return
   name; any `nil` return volume (already rendered by `volume_field/1`); and
   `master: nil` / the `returns_readable?` unavailable path. A reply that
   says "master volume unavailable" and then explains nothing is the same
   half-told story this part exists to close — the *explanation* is what the
   sentence adds, and it is worth as much there as it is for a nil tempo.

   Deciding this in one place is why the formatters hand the unknown-ness back
   rather than only a string: `format_session_state/4` `or`s the two
   `{text, unknown?}` flags together (for returns and master
   the aggregator can inspect the input structs directly — it holds them, and
   `format_return_tracks/2`'s signature stays as it is). Substring-sniffing
   the composed text for `"unknown"` would work today and break the first time
   a track is legitimately *named* "unknown".
5. `format_return_tracks/2` gains the name-`nil` rendering
   (`Return 1 (name unknown) (send B): ...`); its volume handling
   (`volume_field/1`) already does the right thing — leave its wording alone.
6. The `catch :exit` clause of `serve_session_state/0` currently returns
   `{:ok, "No tracks in current session (Ableton may not be connected)"}` —
   an unreachable mirror presented as an empty session, the same lie in a
   different coat. Make it
   `{:error, "The session mirror did not answer — it may be mid-refresh
   against an unresponsive Ableton. Try again shortly, and check Ableton is
   running with AbletonOSC enabled."}`. (`maybe_refresh/1`'s catch already
   errors honestly; unchanged.)
7. [test/seshat/tools/handlers_test.exs](../test/seshat/tools/handlers_test.exs),
   two layers:
   - **The formatters** (`format_song_line/1`, `format_track_summary/1`) —
     all-known, all-`nil`, and partial (tempo known + signature `nil`; one
     track with `volume: nil` only): assert the per-field phrasing and the
     returned `unknown?` flag, and that `nil`-track-list and empty-track-list
     produce different texts.
   - **The composed reply** (`format_session_state/4`) — this is where the
     trailing sentence is asserted, never in the formatter tests. Fully known
     input → the sentence is absent. Each unknown *source* in isolation
     (a song field, a track field, `tracks: nil`, a return name, a return
     volume, `master: nil`) → present. And unknowns in song *and* tracks
     *and* returns simultaneously → present **exactly once**, which is the
     assertion the double-append bug fails.

## Part 4 — `record_clip` refuses `bars` against an unknown time signature

`record_length/1` ([handlers.ex:2312-2317](../lib/seshat/tools/handlers.ex#L2312))
feeds `song.time_sig_numerator/denominator` straight into
`record_length_beats/3`; with `nil` that's an `ArithmeticError` crashing the
tool call — worse than today's wrong-length take.

1. Make the decision pure and public: `record_length_from(bars, song)`
   in `Handlers`, returning `{:ok, beats}` (`{:ok, nil}` when `bars` is
   `nil`) or `{:error, message}` when `bars` is given and either signature
   field is `nil`. `record_length/1` becomes a thin
   `record_length_from(bars, State.song())`.
2. Error text draft (interpolate the actual `bars` value — don't hardcode
   "4"): `"The time signature isn't known (Ableton did not answer when the
   session was last read), so a #{bars}-bar length can't be converted to
   beats and nothing was recorded. Call get_session_state with refresh: true
   first, or omit bars to record open-ended and stop_recording when done."`
   It keeps the guard's position before any OSC send, so "nothing was
   recorded" stays true.
3. Unit-test `record_length_from/2` beside the existing
   `record_length_beats/3` tests: known signature passes through, `nil` bars
   → `{:ok, nil}` regardless, `bars` + nil numerator or denominator → error
   mentioning refresh.

## Part 5 — Tell the model unknowns exist

In [lib/seshat/tools/definitions.ex](../lib/seshat/tools/definitions.ex),
`get_session_state`'s description: after the "pass refresh: true only if the
state it reports ever looks wrong" sentence, add one clause:
`"Values reported as unknown could not be read from Ableton — pass refresh:
true to re-read before relying on them."` No schema change, no new tool, no
count bump in `definitions_test.exs`; the MCP component regenerates.

## Part 6 — Smoke-test coverage for the failure path

Nothing in `mix test` executes `do_refresh/1` (it reaches
`Transport.query/3` by design). Add one section to
[.claude/skills/smoke-test/SKILL.md](../.claude/skills/smoke-test/SKILL.md)
(alongside the existing push-based session-state checks around line 295):

With the Seshat server running, quit Ableton Live (or toggle AbletonOSC off).
Then, in order:

1. **Force a failed refresh.** `get_session_state` with `refresh: true` once →
   the 30s timeout error from `maybe_refresh/1`. The GenServer is *still
   refreshing* when that error arrives: against a dead Ableton `do_refresh/1`
   takes ~37s (six song queries at 5s, the 5s `num_tracks` probe, the 2s
   returns probe) versus the caller's 30s, so ~7s of it remain.
2. **Read immediately** (inside those ~7s), plain, no refresh → Part 3.6's
   mid-refresh error: the call queues behind the running refresh and exits its
   own 5s call timeout. **This is a required check, not a caveat** — it is the
   only live exercise of that message, and it must read as "try again shortly",
   never as an empty session. (If the timing is missed the call simply
   succeeds; retry from step 1 rather than treating a success as a failure.)
3. **Wait ≥10s, then read again**, plain, no refresh → the unknown-state reply:
   tempo, signature, key and playing state all unknown, the track list
   unknown-not-empty, and the trailing explanation sentence present once.
   **It must not say 120 BPM, 4/4, C Major, or list the previous set's
   tracks.**
4. Still with Live closed: `record_clip` with `bars: 4` → the
   time-signature-unknown error, not a crash and not a timeout message.
5. Start Live again → `/live/startup` refresh fires; `get_session_state`
   shows real values with no unknown remnants and no trailing sentence (the
   listener re-subscription push repopulates anything a lost datagram nil'd).

## Testing

- **Pure (`mix test`)**: everything in Parts 1–5 that doesn't cross
  `Transport.query/3` — the `stale?/2` nil clause, pushes onto a `nil`
  mirror, the unreconciled brake with a `nil` mirror side
  (`state_test.exs`); `format_song_line/1`, `format_track_summary/1`,
  `format_session_state/4` (the trailing sentence, exactly once),
  `format_return_tracks/2` name-nil, `record_length_from/2`
  (`handlers_test.exs`). `mix precommit` before done.
- **Ableton only (`/smoke-test`, Part 6)**: the entire `do_refresh/1` failure
  path — nil-on-timeout, `tracks: nil` on a failed count probe, recovery via
  `/live/startup` and listener re-subscription pushes. ⚠️ No test in this
  repo executes any of it; Part 6's checklist is the verification, by
  construction.

## Out of scope

- **Monitored refresh worker, overall deadline, freshness/connection/
  last-error metadata** — review #7's larger recommendation, explicitly
  deferred by the roadmap entry ("do the defaults only"); revisit only if the
  blocking window is actually observed. The queue in roadmap item "Serialize
  OSC queries and clean up timed-out callers" changes the contention picture
  anyway.
- **Transport query serialization / timed-out-caller cleanup** — roadmap item
  "Serialize OSC queries and clean up timed-out callers", its own item.
- **Structured (JSON) `get_session_state` reply** — the reply stays prose;
  structured setter acknowledgements were already rejected in the review
  response.
- **Return-track/master unknown semantics** — already honest
  (`nil` volume, `nil` master, `returns_readable?` latch); this plan only
  adds the name-`nil` rendering in Part 3.5.
- **Roadmap entry removal** — `/ship`'s job when this lands.
- **Clearing the TOOL_AUDIT.md wart** — also `/ship`'s job, and it is real
  work, not a no-op: [TOOL_AUDIT.md](TOOL_AUDIT.md)'s §05 row for
  `get_session_state` records this exact defect ("substitutes plausible
  defaults (120 BPM, 4/4, C Major)... Finding #7") and must lose that note
  once this ships. The `/ship` skill gained a TOOL_AUDIT step for it; if a
  future `/ship` run doesn't touch that file, flag it rather than skip it.

## Open questions

1. ⚠️ **The failure path is smoke-verified only.** Every changed branch in
   `do_refresh/1` needs an Ableton that stops answering mid-conversation to
   exercise; `mix test` can't reach it (testing rule: nothing tests through
   `Transport.query/3`). Unresolvable at planning time by construction —
   Part 6 is the check, and an implementer should run it before trusting the
   recovery story.
2. ⚠️ **Recovery-by-push after a transient hiccup is inferred from source,
   not observed.** `_start_listen` provably pushes the current value on
   subscription (handler.py:94-97), so a field nil'd by one lost reply should
   repopulate on the same refresh's re-subscription — but whether a *half*-
   responsive Ableton (queries timing out, pushes arriving) occurs in
   practice, and how quickly `/live/startup` heals a full restart, only live
   Ableton shows. The plan assumes the worst case is a `nil` that persists
   until `refresh: true` — which is the designed, honest behavior, so nothing
   hinges on the answer; it only decides how often users see "unknown".

Decisions made rather than left open (recorded per the plan skill): a failed
mid-session refresh **nils** a previously known value rather than keeping it —
refreshes run exactly when staleness is suspected (`/live/startup` means a new
song; `refresh: true` means the mirror looked wrong), so carrying the old
value forward is the previous set's data more often than not, and the
subscription push repopulates within milliseconds when Ableton is alive.
Track *names* get no placeholder either — one rule for every field beats a
special case, `stale?/2` works fine with `nil` names (a `nil` never equals a
pushed name, keeping the mirror reconcilable), and `(name unknown)` misleads
nobody, unlike a fabricated "Track 3" the user may try to address. Unknowns
render per-field with one shared trailing explanation, not per-field hints —
keeps a half-degraded reply readable.
