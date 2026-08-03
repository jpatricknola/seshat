# Plan: Echo checks at every raw reply decode

> **Archived 2026-08-03 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. All seven parts landed —
> shared echo-aware decoding (`query_correlated/4` and the length-check
> variant `query_scene_names/2` uses) now covers all six sites this plan
> named, `query_scene_names/1` moved onto the bulk
> `/live/song/get/scenes/name` address, and the remaining verified sites each
> carry the comment Part 7 asked for. PR review surfaced one follow-up outside
> this plan's scope — a regular-track `set_device_parameter` call now loses
> Live's real rejection message behind a generic "did not confirm it" — queued
> in [../ROADMAP.md](../ROADMAP.md) as "`set_device_parameter` on a regular
> track loses Live's rejection message".

Roadmap item: **"Echo checks at every raw reply decode — a straggler must not
impersonate an answer"**.

## Context

`Seshat.OSC.Transport` serializes queries but correlates replies **by address
alone** — request IDs on the wire are settled-rejected
([transport.ex:31-55](../../lib/seshat/osc/transport.ex#L31-L55)). A reply
abandoned by an earlier timeout can therefore answer the next query on the
same address, and the *only* defence is caller-side: compare the indices the
reply echoes against the request that was made. Transport's own doc names the
echo checks in `Seshat.Tools.Handlers.query_echoed/5` as that defence — but
the 2026-08-03 integration review
([abletonosc-integration-review.md](../evaluating/abletonosc-integration-review.md)
§2, corrected by the PR #62 counter-review) found six call sites that receive
echoed correlation data and **discard it**, each now `TODO!`-marked in
[handlers.ex](../../lib/seshat/tools/handlers.ex):

1. **`get_track_devices`** (regular tracks, handlers.ex:2875) — three list
   replies assembled into parallel lists, echoed track discarded three times.
   The three lists can describe two different chains.
2. **`get_device_parameters`** (regular tracks, handlers.ex:2920) — same at
   worse odds: five replies, echoed track *and* device discarded.
3. **`get_clip_notes`** (handlers.ex:2566) — three replies, echoed track/slot
   discarded; one clip's name can be paired with another clip's notes.
4. **`set_device_parameter`'s confirming read** (regular tracks,
   handlers.ex:2996) — discards `_t, _d, _p` and then presents `display` as
   proof the write landed. A straggler here is a **fabricated confirmation**,
   the exact thing the read-back exists to prevent.
5. **`list_browser_items`** (handlers.ex:2697) — the reply echoes the category
   and filter searched; both are discarded, on the 15s `@browse_timeout` — the
   widest straggler window in the file.
6. **`query_scene_names/1`** (handlers.ex:3497) — one query per scene, echoed
   scene index discarded. Pays N serialized round trips (~100ms each) and gets
   neither the single-reply economy nor the echo verification.

The fix pattern already exists five times over in the same file —
`query_echoed/5`, `read_device_names/2`, `query_vendored_list/4`,
`read_back_value/2`, `read_all_notes/4` — each hand-rolling the same
split-echo / compare / reissue-once shape with different payload handling and
different error wording. The roadmap entry asks for the durable version:
**shared echo-aware decoding** that all raw `Transport.query/3` call sites in
`Handlers` ride, so the next reader adds a correlated query in one line
instead of hand-rolling a sixth variant.

**The full audit.** Every raw `Transport.query/3` site in `lib/` was
enumerated for this plan. Besides the six above, every other site either
already verifies its echo or has no echo to verify:

| Site | Status |
|---|---|
| `load_device` family (handlers.ex:2740/2777/2811 → `load_outcome/2`) | verified — echo + uri checked, stale error envelope rejected too |
| `read_device_names/2`, `query_vendored_list/4`, `read_back_value/2`, `query_vendored_delete/4`, `confirm_device_count/2`, `confirm_device_enabled_at/5`, `read_all_notes/4`, `confirm_view_hidden/2`, `query_echoed/5` and everything riding it | verified — each spells out the echo check |
| `num_tracks`/`num_scenes` (handlers.ex:3263), follow-cam counts (:3314), tempo (:3373), `track_data` (:3523), `return_track/get/count` (:3813), `master/get/volume` (:3828), master getters (:3847), `can_undo`/`can_redo` (`history_guard/2`, :5238) | **no echo exists in the reply** — nothing to check; each already carries (or gains, Part 7) a comment saying so. `history_guard` argues its collision classes explicitly; `track_data`'s missing echo is exactly why `ensure_midi_track` refuses to use it (handlers.ex:4805-4815) |
| `Seshat.Commands.Registry` (`ensure_clip/4`, count reads), `Seshat.Session.State` (`query_string/4` etc.), `Seshat.Library.Catalog` (`/live/browser/export`) | verified in place — each named by Transport's doc as an existing echo-check site, or (export) validates the pathed reply through its own dedicated guards |

So this plan is: one shared decode (Part 1), the six fixes riding it (Parts
2–6), and the sweep that makes the file's remaining raw sites say why they
stand apart (Part 7). No Python change, no submodule commit, no
`mix abletonosc.install`, no Live restart — every address involved is already
registered and documented.

## OSC contract

All verified against [docs/abletonosc-api-docs.md](../abletonosc-api-docs.md)
(line refs below) **and** against the fork source in `priv/AbletonOSC` at the
current pin. The load-bearing column is **Echoed prefix** — what the shared
decode must compare, which is *not always the full request*.

| Address | Request args | Reply | Echoed prefix | Source |
|---|---|---|---|---|
| `/live/track/get/devices/name` | `track` | `track, name…` | `[track]` | docs:501, upstream `track.py` |
| `/live/track/get/devices/type` | `track` | `track, type…` | `[track]` | docs:502 |
| `/live/track/get/devices/class_name` | `track` | `track, class…` | `[track]` | docs:503 |
| `/live/device/get/name` | `track, device` | `track, device, name` | `[track, device]` | docs:830 |
| `/live/device/get/parameters/name` | `track, device` | `track, device, name…` | `[track, device]` | docs:834 |
| `/live/device/get/parameters/value` | `track, device` | `track, device, value…` | `[track, device]` | docs:835 |
| `/live/device/get/parameters/min` | `track, device` | `track, device, value…` | `[track, device]` | docs:836 |
| `/live/device/get/parameters/max` | `track, device` | `track, device, value…` | `[track, device]` | docs:837 |
| `/live/device/get/parameter/value_string` | `track, device, parameter` | `track, device, parameter, string` | `[track, device, parameter]` | docs:841 |
| `/live/clip/get/name` | `track, slot` | `track, slot, name` | `[track, slot]` | docs:576 |
| `/live/clip/get/length` | `track, slot` | `track, slot, length` | `[track, slot]` | docs:581 |
| `/live/clip/get/notes` | `track, slot[, start_pitch, pitch_span, start_time, time_span]` | `track, slot, (pitch, start, dur, vel, mute)…` | `[track, slot]` — **the range args are not echoed** | docs:568; verified in [clip.py:37-62](../../priv/AbletonOSC/abletonosc/clip.py#L37-L62), `create_clip_callback` returns `(track_index, clip_index, *rv)` |
| `/live/browser/get/items` | `category, filter, max_results` | `category, filter, "ok", returned, total, (name, path, uri)…` or `category, filter, "error", message` | `[category, filter]` — **string echoes, verbatim; `max_results` is not echoed**, and the error arm echoes both too | docs:868-869; verified in [browser.py:185-218](../../priv/AbletonOSC/abletonosc/browser.py#L185-L218) |
| `/live/song/get/scenes/name` | *(none)* or `index_min, index_max` (half-open) | `name…` | **nothing** — the reply is names only | docs:231, 240-247; verified in [song.py:233-239](../../priv/AbletonOSC/abletonosc/song.py#L233-L239): no args → full range, names in index order |
| `/live/scene/get/name` | `scene` | `scene, name` | `[scene]` | docs:768 — **removed from `lib/` by Part 6**; this is its only call site |

Two wire-type facts the decode relies on, both already proven by the existing
helpers: integer indices echo back as integers and `indices_match?/2` compares
with `==` (so a float index that cast fine on the way out still matches), and
the browser's string echoes are `str()` round-trips of what was sent —
identity for the schema-validated strings Seshat sends.

## Part 1 — the shared correlated decode

[lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex), next to
`query_echoed/5` (:4999).

Two pieces, split so the decision is pure and testable without a socket:

**1a. A public pure decode**, tested directly (the `unwrap_payload/1` /
`load_outcome/2` precedent):

```elixir
@doc false
# Splits a reply into {echoed prefix, payload} and verifies the prefix.
# `:stale` on any mismatch — including a reply too short to contain the
# prefix, which Enum.zip would silently truncate past (the existing
# `load_outcome/2` guards this explicitly; `indices_match?/2` alone does not).
@spec correlate_reply(list(), list()) :: {:ok, payload :: list()} | :stale
def correlate_reply(values, echo)
```

The length guard is load-bearing and easy to miss: `Enum.zip([1], [1, 2])`
truncates, so a one-element reply to a two-index request would pass a bare
`indices_match?/2`. Check `length(values) >= length(echo)` first, exactly as
`load_outcome/2` (handlers.ex:3895-3904) does.

**1b. A private querying wrapper** owning the reissue-once policy:

```elixir
# One correlated query: send, split off and verify the echoed prefix,
# reissue once on a stale or unreadable reply. Options:
#   echo:    the prefix the reply must echo (default: `args` — differs for
#            /live/clip/get/notes and /live/browser/get/items, see the
#            OSC contract table)
#   timeout: passed to Transport.query/3 (default: Transport's own 5s)
#   decode:  fun applied to the post-echo payload, returning
#            {:ok, term} | {:error, message} | :unexpected_shape
#            (default &{:ok, &1} — the raw list)
defp query_correlated(address, args, opts \\ [], reissued? \\ false)
```

Behaviour, each point checkable:

- A verified echo with a decodable payload returns `{:ok, decoded}`.
- `:stale` from `correlate_reply/2` **or** `:unexpected_shape` from the decode
  reissues the identical query once; a second failure returns
  `{:error, {:stale, values}}` for the caller to word (the reissue is
  mitigation, not a guarantee — same caveat `query_echoed/5` documents).
- `{:error, {:live_error, message}}` and transport errors pass through
  untouched — wording stays at the call site, where the subject and
  consequence are known.
- **Timeouts are not caught here.** `Transport.query/3` exits on timeout;
  every call site already has a `catch :exit` with tool-specific wording, and
  the helper must not eat that. (`query_echoed/5` keeps its own internal
  `catch :exit` because its callers rely on it — see below.)

**1c. Refit the existing generic helpers onto the core** so there is one
decode, not six: `query_echoed/5` becomes a thin wrapper (its
`unwrap_payload/1` as the `decode:`, `@guard_timeout`, its subject/hint
wording and internal `catch :exit` kept exactly as they are — no caller
changes), and `read_device_names/2` and `query_vendored_list/4` collapse onto
`query_correlated` with their wording kept. `read_back_value/2` also moves
onto the core, which gives the vendored read-backs the reissue-once defence
they currently lack — on the second mismatch it still returns `:unconfirmed`,
never a "nothing was sent" claim. The bespoke sites that verify *more* than an
echo (`load_outcome/2`'s uri+envelope, `query_vendored_delete/4`'s remaining
count, `confirm_device_count/2`'s expected-count pattern match,
`confirm_view_hidden/2`'s string-echo envelope, `read_all_notes/4`'s phase
wording) **stay as they are** — each gains only a one-line comment naming the
shared core and why it stands apart. Rewriting verified, tested,
bespoke-worded code is risk with no correctness gain.

**1d. Generalize `stale_reply_error/2`'s wording** (:5073): it currently
hardcodes "were not about the track or slot asked for", which is wrong for a
browser search or a device read. Change to "were not about the … asked for"
built from the subject, keeping the two-sentence shape and the `consequence`
parameter. Update any test pinning the old wording.

## Part 2 — `get_track_devices` / `get_device_parameters`, regular tracks

handlers.ex:2875 and :2920.

Route all eight queries through `query_correlated`:

- `get_track_devices`: three list queries, `echo: [track]` (the default),
  payload = the raw list. On `{:stale, _}`: error via the generalized
  `stale_reply_error` with subject "the devices on track #{track}",
  default consequence (read-only tool — nothing was mutated).
- `get_device_parameters`: `/live/device/get/name` decodes a single value
  (`unwrap_payload/1`); the four `parameters/*` queries decode raw lists.
  Subject "device #{device} on track #{track}".

Keep each site's current timeout (Transport's 5s default — these are the
tools' primary reads, not guards) and keep each `do_call`'s existing
`catch :exit` wording. Delete both `TODO!` blocks. The cross-reply coherence
hazard (three verified replies that are still three snapshots) is reduced to
the same residual every multi-query read has; the combined-endpoint decision
that would close it entirely belongs to "Bulk reads vs. per-address queries"
(roadmap), not here.

## Part 3 — `get_clip_notes`

handlers.ex:2566.

Three `query_correlated` calls: name and length with `echo: [track, slot]`
(the default) and `unwrap_payload/1`; notes with args
`[track, slot | note_range_args(params)]` and an explicit `echo:
[track, slot]` — the one site where the echo is a strict prefix of the
request. The notes payload feeds `parse_clip_notes/1` unchanged (a
non-note-shaped tail already fails loudly there; it does not need to be the
decode fun). Stale wording: subject "the clip in slot #{slot} on track
#{track}", default consequence. Existing guards (`ensure_clip`,
`ensure_midi_clip`) and the `catch :exit` stay. Delete the `TODO!`.

## Part 4 — `set_device_parameter`'s confirming read

handlers.ex:2996.

Replace the raw query with `read_back_value/2` — the helper the vendored
paths already use for exactly this read, which verifies the echo and answers
`:unconfirmed` instead of fabricating (and gains reissue-once in Part 1c).
On `:unconfirmed` the clause returns an error in the vendored path's wording:
"The set was sent but reading it back did not confirm it — verify with
get_device_parameters." — never the "it now reads '…'" confirmation. Two
deliberate behaviour shifts ride along, both toward the vendored paths'
existing shape: the read-back now runs on `@guard_timeout` (2s, what
`read_back_value/2` uses) instead of Transport's 5s default, and
`read_back_value/2` catches the timeout internally as `:unconfirmed` — so the
clause's existing `catch :exit` ("The set was sent but reading the value back
timed out…") stays as a residual guard but is no longer the read-back's
timeout path; the unconfirmed wording covers that case. Checkable: no path in this clause may interpolate a `display`
value that arrived with mismatched indices. Delete the `TODO!`.

## Part 5 — `list_browser_items`

handlers.ex:2697.

One `query_correlated` call with `echo: [category, filter]` (the request also
carries `max_results`, which is not echoed) and `@browse_timeout`. The decode
fun owns the envelope: `["ok", returned, total | triples]` → `{:ok, {total,
triples}}`, `["error", message]` → `{:error, message}`, anything else →
`:unexpected_shape`. Two points worth stating:

- **The error arm is echo-checked too.** A stale error envelope would report
  a failure that never happened to this search — the same reason
  `load_outcome/2` rejects a mismatched error (pinned at
  handlers_test.exs:1326). `query_correlated` gives this for free, since the
  echo is verified before the decode fun ever runs.
- **The reissue can cost a second browse** (up to 15s more, worst case). Accepted:
  it only happens on a stale reply, the second walk of an already-indexed
  category is fast (browser.py caches its index), and the alternative —
  presenting another search's results — is the defect this item exists to
  kill. The `catch :exit` wording already covers the slow-retry case.

Stale wording: subject "the browser search for #{category}", consequence
advising a plain retry (nothing was mutated). Delete the `TODO!`.

## Part 6 — scene names: one bulk reply, length-checked

handlers.ex:3497, `query_scene_names/1` (sole caller: `get_clip_slots`).

Switch from N × `/live/scene/get/name` to **one no-arg query** on
`/live/song/get/scenes/name` — the roadmap entry's recorded first option. The
reply echoes nothing, so the length check stands in for the echo check:

- Send no args (full range — verified in song.py:233-238; the `-1` trap
  documented at docs:240-247 is thereby never reachable from `lib/`).
- Accept the reply only when `length(names) == num_scenes` (the count
  `get_clip_slots` just read). On mismatch, reissue once; on a second
  mismatch, error: the scene list changed underneath the read (or a straggler
  answered) — re-run `get_clip_slots`. This is honest either way: if the count
  genuinely changed mid-read, the `track_data` half of the grid snapshot is
  stale too, and "re-read" is the only correct advice.
- `num_scenes >= 1` is guaranteed by the caller (`snapshot_tracks/2` returns
  the empty grid without ever calling this).

Why this beats keeping the loop and checking N echoes: one serialized round
trip instead of N (~100ms each — 1.6s saved on a 16-scene set, inside a tool
that already pays for `track_data` batches), and the verification strength is
equivalent in practice — a same-length straggler carrying different names
would have passed the per-scene echo checks too, since index echoes can't see
renames. The residual it accepts (a straggler full-range reply from an
*earlier* `get_clip_slots` against an unchanged scene count) can only be
stale by scene *renames* landed between the two calls — narrower than what
the discarded-echo loop accepts today, at 1/N the cost. This also removes the
`"/live/scene/get/name"` literal from `lib/` (this was its only call site) —
`vendored_addresses_test` checks lib→registered, so a removed literal is
fine, and `/live/song/get/scenes/name` is upstream-registered and documented,
so the new literal passes both directions. Delete the `TODO!` and the
now-historical comment above the function; keep one line citing the docs'
no-echo caveat as the reason for the length check. Two more comments go stale
with the switch and must be updated in the same stroke: the `do_call`
comment above `get_clip_slots` ("plus one tiny query per scene name",
handlers.ex:3151-3152) and `snapshot_grid`'s scene-names rationale ("they
cost one query per scene", handlers.ex:3255-3257 — its occupancy-only
justification survives; its per-scene cost claim does not).

**Reply size**: scene names ride one datagram; Transport's 64KB socket buffer
comfortably fits any realistic scene count (hundreds of scenes at typical
name lengths), and an oversized reply fails exactly like today's oversized
notes replies — a decode-less silence the existing `catch :exit` reports.

## Part 7 — the sweep

- Delete all six `TODO!` blocks (the four in Parts 2–5, `query_scene_names`'s,
  and nothing else — the `TODO!`s at handlers.ex:1987 (`set_track_send`),
  :2328 (`track_data` bulk premise) and :3923 (`read_sends` mirror reuse)
  belong to other roadmap items and **stay**).
- Every remaining raw `Transport.query/3` site in `Handlers` gets (or already
  has) a one-line comment saying why it does not ride `query_correlated` —
  "no echo exists in this reply" for the no-arg getters and `track_data`,
  "verifies more than an echo" for the bespoke confirmations. Checkable by
  grepping `Transport.query(` in handlers.ex: every hit is either inside
  `query_correlated`/a Part 1c wrapper, or commented.
- Update Transport's "Query serialization" doc note (transport.ex:53-55) to
  name the shared helper as the caller-side defence, alongside the
  Registry/State helpers it already cites.

No tool descriptions change, no schema changes, no new tool — so no
`definitions_test.exs` count bump and no MCP surface impact. Reply *wording*
changes only on failure paths (new stale errors, generalized
`stale_reply_error`); success replies are byte-identical.

## Testing

All pure — nothing here needs Ableton, per
[.claude/rules/testing.md](../../.claude/rules/testing.md); the sink-answered
handler-test exception (the `undo`/`redo` guard and `hide_view` precedents)
covers the wire-shaped cases.

**`correlate_reply/2` directly** (new describe in `handlers_test.exs`):

1. Exact echo match → `{:ok, payload}`, payload is everything after the prefix.
2. Mismatched index → `:stale`.
3. **Reply shorter than the echo → `:stale`** — the `Enum.zip` truncation trap;
   this test is the reason `correlate_reply/2` is public.
4. Integer echo against the float index that was sent (`1` vs `1.0`) → match
   (the `==` tolerance `query_echoed/5` documents).
5. String echoes (category/filter) match verbatim and mismatch on case.

**Sink-driven, per site** (the `guarded_trace`/`reply_datagram` pattern —
each test's own `OSCSink` answers, so nothing waits on Ableton):

6. `get_track_devices`: first reply echoes the wrong track, reissue is
   answered correctly → `{:ok, _}` with the *second* reply's chain, and the
   wire trace shows the address twice. Wrong twice → error containing the
   stale wording, and no device list in the reply.
7. `get_device_parameters`: `parameters/value` reply echoes another device →
   reissued; the assembled output never mixes the two.
8. `get_clip_notes`: name reply echoes another slot twice → stale error;
   guards (`has_clip`, `is_midi_clip`) answered `true` by the sink.
9. `set_device_parameter` (regular track): read-back echoes another parameter
   twice → reply is the unconfirmed error, and **does not** contain "it now
   reads" — the fabricated-confirmation tripwire.
10. `list_browser_items`: reply echoes a different category twice → stale
    error, no results presented. A mismatched *error* envelope is also
    rejected as stale rather than reported as this search's failure.
11. `get_clip_slots`: sink answers `num_tracks`/`num_scenes`/`track_data`,
    then `scenes/name` with the wrong number of names, then the right number
    on reissue → names land; wrong twice → error advising a re-read. Assert
    the wire shows **one** `scenes/name` query per attempt and zero
    `/live/scene/get/name` datagrams.
12. Happy-path regression: each of the six sites with correctly-echoed
    replies → success reply unchanged from today's (pins that the echo check
    doesn't reject legitimate replies).

**Existing tests**: any pinning `stale_reply_error`'s "track or slot" wording
updated (Part 1d); the `query_echoed`/`read_device_names`/
`query_vendored_list`/`read_back_value` refits must leave every currently
passing test green — they are wording-preserving refactors.

## Live verification

Nothing in `mix test` reaches Live. Run the automated half with `/smoke-test`.
The mismatch branches themselves are suite-fed (a straggler cannot be
provoked in Live on demand — see Uncovered), so the live checks prove the
other half: real replies still pass the new checks, and the one address newly
sent from `lib/` behaves as the source says.

- `smoke_tests/auto/clips.md § Scene names ride one bulk reply` — **new test,
  written with this plan** — first production use of
  `/live/song/get/scenes/name`; names correct, in order, after a rename.

  *PR review 2026-08-03 — passed.* 8-scene set, all unnamed. `set_scene_name`
  1 → "Chorus" then 5 → "Outro"; `get_clip_slots` reported
  `8 scene(s): 0 "", 1 "Chorus", 2 "", 3 "", 4 "", 5 "Outro", 6 "", 7 ""` —
  every scene present, in index order, both renames on the right rows,
  unnamed scenes rendered as `""` rather than holes or errors. No re-read
  advice, so the length check matched `num_scenes` first time. Both names
  cleared afterwards and re-read as `""`.

- `smoke_tests/auto/devices.md § Browser search echoes the search it ran` —
  **new test, written with this plan** — `list_browser_items` happy path
  through the new envelope decode, plus its clean unknown-category error.

  *PR review 2026-08-03 — passed on the happy path; the unknown-category step
  did not exercise what it claims.* `audio_effects` + `reverb` returned
  "Showing 25 of 158 matches" with plausible items and uris — the real echo
  passed the check and `total` survived the `browser_items_payload/1` decode.
  The unknown-category step (`sounds_typo`) produced an immediate, clean error
  listing the valid categories, but from `Seshat.Tools.Validation`'s schema
  enum, **not** from `browser.py`'s echoed error arm — `category` is an enum in
  `Definitions`, so no datagram is ever sent. The echo-checked error arm is
  therefore unreachable from the tool surface and is covered only by the pure
  test at `handlers_test.exs` ("an error envelope about another search is
  stale"). The test text should say so.

- `smoke_tests/auto/devices.md § Parameter 0 is the 'Device On' switch,
  displaying 'On'/'Off'` — `get_device_parameters` and `set_device_parameter`'s
  read-back on real replies; a false-positive echo rejection would fail here.

  *PR review 2026-08-03 — passed on all three device kinds.* On a scratch MIDI
  track: stock Hybrid Reverb (54 params), Instrument Rack preset "E-Piano
  Basic".adg (18), AU plugin Apple AUDelay (4). Parameter 0 read "Device On"
  (range 0.0–1.0) on each, and the five correlated replies assembled coherently
  (names, values, mins, maxes all aligned). `set_device_parameter` on Hybrid
  Reverb's Dry/Wet (53) → 0.75 replied "it now reads '75 %'", so
  `read_back_value/2` verified a real echo and produced the confirmation
  wording unchanged. `bypass_device` off/on on all three, no refusal.

- `smoke_tests/auto/devices.md § Device error paths are errors, not stalls` —
  bad indices through the refitted decode still fail fast and cleanly.

  *PR review 2026-08-03 — passed, all three paths ≤0.27s (whole `mcp_call.py`
  round trip).* `delete_device` device 7 on a 3-device chain → "There are 3
  device(s) on track 1 (indices 0–2) — there is no device 7. Chain: 0: E-Piano
  Basic, 1: Hybrid Reverb, 2: AUDelay." (0.27s). Device 0 on an empty chain →
  "There are no devices on track 0, so there is nothing to delete…" (0.19s).
  Track 99 → "Ableton rejected the request: Index out of range" (0.19s) —
  that one runs through the refitted `read_device_names/1`, so the
  `{:live_error, _}` passthrough is confirmed on the new core.

- `smoke_tests/auto/bridge.md § A rejected query fails fast, and says rejected`
  — the `{:live_error, _}` passthrough survives the refactor.

  *PR review 2026-08-03 — passed.* `get_track_devices` track 99 → "Ableton
  rejected the request: Index out of range" in 0.24s. Also checked the two
  other refitted read paths: `get_device_parameters` track 99 → same wording
  in 0.19s, and `get_clip_notes` track 99 → "Index out of range. Nothing
  further was sent…" in 0.19s (its guard rejects first, as this test's own
  note records). No guard-timeout wording anywhere, no 5s stall.

- `smoke_tests/auto/bridge.md § Live's Log.txt stays clean during ordinary
  work` — the sequence exercises `get_clip_slots` (now the bulk scene read)
  and ranged `get_clip_notes`; a raise from the no-arg `scenes/name` form
  would land in the log.

  *PR review 2026-08-03 — passed.* Baselined `Live 12.4.3/Log.txt` at
  6,290,538 bytes, then ran create_track → write_midi_notes → get_clip_slots →
  duplicate_clip → ranged get_clip_notes (start_time 0, time_span 2,
  start_pitch 60, pitch_span 8 → the expected 2 of 3 notes) → delete_clip ×2 →
  delete_track. 106 new log lines, **zero** tracebacks, ERROR lines or "Error
  handling OSC message" lines. The no-arg `/live/song/get/scenes/name` form
  does not raise in Live.

**Preflight for the runs above:** the installed Remote Scripts copy differs
from `priv/AbletonOSC/abletonosc` at the pin in exactly one place — a comment
block in `track.py` — so the loaded bridge is functionally identical and the
fork-dependent results stand. The running Seshat instance was confirmed to be
serving this branch (its `set_device_parameter` read-back failure now reads
"…did not confirm it", wording that exists only here). Session restored: no
scratch track, scenes back to unnamed, tempo and time signature untouched.

**Uncovered:** the stale/reissue branches against real Ableton — a straggler
needs a timed-out query immediately followed by a same-address query, which
cannot be provoked deterministically in Live (⚠️ suite-fed guard branch, per
the smoke-write rules); and reply-size limits on `scenes/name` (no set with
enough scenes to threaten 64KB exists here). Both are argued in the plan body
and covered pure.

## Out of scope

- **Vendored combined endpoints for regular-track device reads** (one query
  instead of 3–5) — that is the "Bulk reads vs. per-address queries" roadmap
  item, which should be decided with measurements. The echo checks here don't
  preclude it; if it lands, Parts 2's call sites collapse onto
  `query_vendored_list` and the shared decode still verifies the echoes.
- **`set_track_send`'s asserted outcome** — its own roadmap item, "`set_track_send`
  reports a request, not an outcome"; the `TODO!` at handlers.ex:1987 stays.
- **`read_sends`' redundant name queries** (handlers.ex:3923) — already
  echo-checked via `query_echoed`; the mirror-reuse optimisation belongs to
  the bulk-reads item.
- **Refactoring the bespoke verified sites** (`load_outcome`,
  `query_vendored_delete`, `confirm_device_count`, `confirm_device_enabled_at`,
  `confirm_view_hidden`, `read_all_notes`, `history_guard`) onto the shared
  core — each verifies more than an echo or carries load-bearing wording;
  Part 1c leaves them with a comment, not a rewrite.
- **`Session.State` / `Registry` / `Catalog` query helpers** — already
  verified in place (see the audit table); unifying them across module
  boundaries buys no correctness.
- **No-echo replies gaining correlation** (`track_data`, the no-arg getters)
  — impossible without a wire change, which is settled-rejected. `track_data`'s
  consumers already handle this (`ensure_midi_track` refuses it; the grid
  snapshot length-checks via `parse_track_data/3`).

## Open questions

None remain open. Three were candidates and each was closed during planning
rather than deferred:

1. **Does `/live/song/get/scenes/name` return the full range with no args, in
   index order?** Closed by reading the fork source
   ([song.py:233-239](../../priv/AbletonOSC/abletonosc/song.py#L233-L239)): zero
   params → `0, len(song.scenes)`, names generated in `range()` order. The
   installed Remote Scripts copy matches the pin (last installed and
   smoke-verified 2026-08-03), and the address predates the fork upstream, so
   even a stale install serves it.
2. **Does `/live/clip/get/notes` echo its range arguments?** Closed the same
   way ([clip.py:37-62](../../priv/AbletonOSC/abletonosc/clip.py#L37-L62)): the
   callback wrapper echoes exactly `(track_index, clip_index)` regardless of
   extra args — hence Part 3's explicit `echo:` option.
3. **Are the browser's category/filter echoes verbatim?** Closed at
   [browser.py:185-218](../../priv/AbletonOSC/abletonosc/browser.py#L185-L218):
   both arms return `str()` round-trips of the request's own strings, and
   `max_results` is never echoed.

Live is running and was available for measurement, but nothing above needed
it: each answer is determined by the Python that Live executes, read from the
fork at the pin.
