# Seshat ↔ AbletonOSC integration review (2026-08-03)

> **Provenance and corrections.** This review was written from the *fork
> repo's* working tree (jpatricknola/AbletonOSC), so "this repo" below means
> the fork, and the fork-side documents it cites — `IMPLEMENTATION_PLAN.md`,
> `HANDOFF.md`, `issues.md` (and their issue numbers, #1–#23) — exist only in
> the fork repo's tree, not in Seshat and not at the submodule pin. In Seshat
> the fork's files live under `priv/AbletonOSC/`. It was moved here because
> its findings drive Seshat-side work. Corrections were applied 2026-08-03
> after a counter-review of PR #62, marked **Correction** inline: the §2
> echo-gap list was incomplete, §2's "only lever" claim was overstated, §1's
> Tier B justification was wrong for sends, the §2 latency evidence is now
> attributed to the measurement that supports it, and §4a's clip listener
> count was 70, not 68. The 19 doc gaps in §4a were closed by PR #62 the same
> day; §4a stands as the record of the diff.

An architecture review of how the Seshat repo (`~/seshat`) consumes this fork,
prompted by reviewer feedback on the fork repo's `IMPLEMENTATION_PLAN.md`:
structured `/live/error` improves diagnostics but cannot make fire-and-forget
mutations honestly report failure, because Seshat's `Transport.send_message/2`
returns once UDP transmission succeeds. This review asks the broader questions
that observation raises: is the current integration efficient and proper, and
should this fork's architecture change to better accommodate Seshat?

**Verdict: keep the architecture; change the endpoint strategy.** The settled
design decisions on both sides are right for the constraints. The measured pain
is round-trip count against Seshat's serialized query queue, and the lever that
attacks it without violating any settled constraint lives in this repo: bulk
endpoints and replying mutators, extending the pattern `return_track.py`
already proves.

File/line references into Seshat are against `~/seshat` at the time of review
(fork submodule pinned at `4584e13`). They will drift; the findings are the
durable part.

---

## 1. How Seshat uses this fork

### Transport

`Seshat.OSC.Transport` (`lib/seshat/osc/transport.ex`) is the sole UDP owner —
a repo rule, verified by grep: no other `:gen_udp` call site. Loopback only,
send port 11000, reply port 11001, 64KB socket buffers (a truncated
`/live/browser/get/items` reply otherwise surfaces as a mystery timeout).

- **`send_message/2` is fire-and-forget** and deliberately bypasses the query
  queue ("fire-and-forget setters must not wait behind a 30s device load").
  `:ok` means bytes left the local socket, nothing more.
- **`query/3` is strictly serialized** — exactly one request in flight, FIFO
  queue behind it, absolute monotonic deadlines that bound total wait
  including queue time. An expired request is never sent. No transport-level
  retries; retries are caller-side only.
- **Correlation is by address alone.** A reply on the in-flight address
  resolves the query. Request IDs on the wire were considered and permanently
  refused (`transport.ex:31-35`): they would be a wire-format divergence on
  every address, carried against upstream forever. Three residual collision
  classes are documented (stragglers on the same address, listener pushes
  sharing a getter's address, delayed structured errors), and the defense is
  caller-side: `query_echoed/5` and related helpers verify echoed indices.
- **Structured `/live/error` correlation works as designed.** A
  `("request", address, message, arg_count, *args)` payload fails the
  in-flight query only when the address matches *and* every echoed argument
  matches by value and wire type, floats compared after a 32-bit round trip.
  `("log", …)` and legacy payloads never resolve anything — broadcast only.
  Strictness rationale: a false negative costs a timeout (status quo ante); a
  false positive fails the wrong caller's query. Ten transport tests pin this.
- Every inbound datagram, matched or not, is also broadcast on Phoenix PubSub
  topic `"osc:in"`, so the state mirror gets free freshness from query replies.

### State mirror

`Seshat.Session.State` (`lib/seshat/session/state.ex`) is the only cache of
Live state: a GenServer holding a plain map, push-fed by this fork's
listeners — per-track `panning volume mute solo name`, eight song scalars,
return/master mixer values, and the fork-only structure pushes
`/live/song/get/tracks` / `return_tracks`. Discipline is notably good:
initial state is all-`nil` ("unknown"), `nil` never means empty, booleans are
normalized at the boundary, a track list that cannot be fully read is nil'd
wholesale rather than partially fabricated, refreshes are trailing-edge
debounced at 1s, and `stop_listen` is never sent (correctness depends on this
fork's `_stop_listen`-through-`listener_objects` fix, grep-guarded).

**The mirror's boundary is the expensive stuff.** Clips (existence, names,
notes, all properties), device chains and parameters, scenes, sends, and view
state are *not* mirrored — re-queried from scratch on every tool call.
Seshat's roadmap items #21/#23 acknowledge this as a latency/token cost.

### Write patterns — three tiers

- **Tier A — pure fire-and-forget (~25 tools).** `set_tempo`, track mixer
  setters, `set_track_arm`, transport controls, `delete_track`, scene
  operations, clip fire/stop/delete/duplicate, `set_time_signature`,
  `remove_notes`, and more. Success is reported when `:gen_udp.send` returns
  `:ok`. Some carry honest hedges (`undo`/`redo`: "this confirms the request
  was sent, not that history moved").
- **Tier B — guard before, no read-back after.** Sends, return/master mixer
  setters: the pre-read proves the index exists and yields the "was" value,
  but the reply presents the *requested* value as achieved. For the
  return/master mixer setters this is softened by listeners — Live pushes its
  accepted value into the mirror (though the tool result the LLM reads does
  not wait for that push). **Correction (2026-08-03): the original
  justification is false for sends** — `track.py` registers only `get/send`
  and `set/send`, no send listener exists, and sends are outside the mirror
  (see the boundary note above) — so a rejected `set_track_send` is never
  corrected anywhere. Sends are Tier A with a guard, not Tier B.
- **Tier C — verified.** `set_device_parameter` (reads `value_string` back),
  `delete_device` (count sandwich; the vendored variant *replies* with the
  remaining count), `bypass_device`, `set_clip_properties` (full write-back
  read), `create_track`/`create_return_track` (count-before/count-after in
  `Seshat.Commands.Registry`), `record_clip`, `capture_midi` (grid diff),
  `hide_view`.

Every tool dispatch — read-only included — is wrapped in
`end_undo_step`/`begin_undo_step`/…/`end_undo_step` using this fork's undo
endpoints (three extra fire-and-forget datagrams per call; deliberate, so no
mutating-tool list must be kept in sync, and measured to be harmless).

### Vendoring and merge guards

Git submodule at `priv/AbletonOSC`; `mix abletonosc.install` replaces the
Remote Scripts install wholesale. `vendored_addresses_test.exs` (no Ableton
needed) checks both directions (every address Seshat sends is
registered here; every address registered here is documented), pins exact
endpoint counts per module, and greps for every merge hazard SESHAT.md names:
the loopback bind, the removed reply retargeting, the structured-error payload
and its `osc_request_error` marker, `listener_objects` resolution,
`swing_amount`, the undo-step methods, and the browser-export destination
guards. This is the mechanism the implementation plan's Phase 2c must update
(the guard greps for the exact `("request", message.address, detail, …)`
fragment the dispatcher refactor will move).

---

## 2. Assessment

### Proper architecture? Yes.

The integration is unusually deliberate. Every non-obvious decision is written
down with its rationale, most are pinned by tests, and the failure-mode
analysis (collision classes, deaf mode on port contention, source filtering,
strict decode) is the kind usually missing from OSC integrations. The
alternatives were genuinely evaluated and correctly declined:

- **On-wire request IDs** — permanent divergence on every address; settled.
- **TCP / Max-for-Live WebSocket bridge** — evaluated in Seshat's
  `docs/evaluating/bridge-options.md`; would fix "UDP silence" (wrong address,
  dropped packet, dead Ableton all look identical) but costs Suite-only
  dependency and a rewrite; declined, revisit only if a Remote Script
  fundamentally cannot do something.
- **Structured acks from every setter** — declined in Seshat's roadmap (#4):
  adds a round trip to every mutation on a queue that serializes every OSC
  request.

The reviewer's fire-and-forget observation is therefore correct **and already
a recorded, deliberate policy** on the Seshat side — not an oversight this
fork's error work was supposed to fix. The implementation plan's Phase 2c
wording ("improves diagnostics and wire consistency, does not make
fire-and-forget mutations honestly report failure") is the right framing.

### Efficient? Partially — and the inefficiency is measured, not theoretical.

Seshat's own artifacts contain two irreconcilable per-round-trip figures.
Several N+1 patterns are justified by comments claiming "sub-millisecond
loopback round trips" (`handlers.ex:35`, `:2308`, `:4724`), while the repo's
measurements support **roughly 100ms per serialized round trip**: a 9-track
mirror rebuild measured at **4.6s** over its `Song:` → `Loaded` log window
(`docs/smoke_tests/auto/mirror.md:145`), and 1.0–1.8s independently cited in
`state.ex:29`. **Correction (2026-08-03):** this paragraph originally also
cited `recording.md:96`'s `has_clip` transition (+0ms → +99ms) as a
round-trip measurement — that test measures Live materialising a clip after
a fire, not OSC RTT — and labelled the 4.6s as covering all ~73 of the
rebuild's queries, when the measured window spans roughly 46 of them
(`num_tracks` + 5 × 9 tracks; returns and master fall outside it). The
~100ms-per-serialized-query conclusion survives both corrections. At real
latency:

| Pattern | Cost |
|---|---|
| `Session.State.do_refresh/1` — 5 queries per track, serial, inside the GenServer | ~73 queries on 9 tracks, of which the measured 4.6s window covers ~46; blocks every mirror read and queues every other tool's queries behind it (measured head-of-line stall on `create_track` during a rebuild) |
| `get_clip_properties` — 13 (MIDI) / 17 (audio) queries per clip | ~1–1.7s per clip; 400+ round trips to survey an 8×4 grid |
| `get_track_devices` / `get_device_parameters`, regular tracks — 3 / 5 separate list queries | 3–5× the vendored equivalents, plus the correctness gap below |
| `get_track_sends` — 1 + 2 per return | up to 25 round trips at 12 returns |
| `query_scene_names/1` — one query per scene | N round trips beside a bulk endpoint that already exists (see §4) |

Head-of-line blocking is a property of Seshat's serialized transport.
**Correction (2026-08-03):** this section originally claimed relaxing
serialization would require wire-level correlation, making bulk endpoints
"the only lever compatible with every settled constraint". That is
overstated. Replies already carry their address and structured errors echo
the failing request, so Transport could hold one in-flight request per
*exact address* — serializing only same-address requests — and let
different-address queries overlap without any wire-format change. The 13–17
different-address clip reads and the 3–5 device reads would pipeline;
same-address stragglers and listener pushes remain exactly as hazardous as
today and still need echo checks. Bulk endpoints may still win — fewer
datagrams, an atomic-ish snapshot, no per-lane bookkeeping — but the two
approaches should be compared and benchmarked, not the lanes declared
impossible. Reducing query counts remains the lever that needs no Transport
redesign at all.

### One genuine correctness gap (Seshat side)

`get_track_devices` and `get_device_parameters` for **regular tracks**
(`handlers.ex:2821-2827`, `:2861-2871`) assemble parallel lists from 3–5
separate replies and **discard the echoed index**, on a transport that
correlates by address alone. A straggler from an earlier timed-out query can
supply another track's names, and the separate replies can describe two
different devices. This is precisely the hazard Seshat's own API docs cite as
the reason this fork's combined return/master endpoints exist
(`docs/abletonosc-api-docs.md:1020-1032`). The fix already exists for
returns/master; regular tracks never got it.

**Correction (2026-08-03):** this section originally called those two "the
only multi-index reads in the file that skip the echo check". They are not.
At least these also discard correlation data: `get_clip_notes` (track/slot
echoes across three replies), `set_device_parameter`'s confirming
`value_string` read (all three indices — it can present another parameter's
display value as verification), `query_scene_names/1` (the scene-index
echo), and `list_browser_items` (the echoed category/filter, on the widest
timeout in the file). Each site now carries a TODO!, and the durable fix is
a systematic audit of every raw `Transport.query/3` call with shared
echo-aware reply decoding — the combined endpoints close only the device
pair.

---

## 3. Recommended fork work: bulk endpoints and replying mutators

The pattern is already established in this repo and documented in
[SESHAT.md](../../priv/AbletonOSC/SESHAT.md): `return_track.py`'s `get/devices` collapses three
upstream round trips into one reply, `device/get/parameters` collapses five,
and its `delete_device` *replies* (`[…, "ok", remaining]`) where upstream's is
silent, "because it is a method with a real failure path." Extend that
philosophy, prioritized by Seshat's measured hotspots:

1. **Combined device endpoints for regular tracks**, mirroring the vendored
   return/master reply shapes (`count, (name, type, class_name)×N` and
   `device_name, count, (name, value, min, max)×N`). Closes the parallel-list
   correctness gap and cuts 3–5× round trips per device read. Highest
   value-to-effort.
2. **A bulk mirror-snapshot endpoint** — one query (chunked like
   `song/get/track_data` if needed) returning name/volume/pan/mute/solo for
   all tracks plus returns and master. Turns the roughly 73-query rebuild into
   two or three queries (the measured 4.6s window covers roughly 46 of those)
   and softens Seshat's roadmap #6 (rebuild blocking)
   without Seshat restructuring anything. Note: `track_data` already reaches
   `track.name`/`mute`/`solo` via `getattr`, but volume/panning live on
   `mixer_device`, so a purpose-built endpoint is cleaner than contorting
   `track_data`.
3. **A bulk clip-properties endpoint** — one reply carrying the 11–15
   properties `get_clip_properties` currently reads one at a time.
4. **Replying variants for destructive mutators without listeners behind
   them** — `delete_track`, scene create/delete/duplicate, and similar,
   following the vendored `delete_device` precedent. This is the honest,
   bounded answer to the reviewer's fire-and-forget point: not
   acks-on-every-setter (correctly declined), but per-endpoint replies on
   operations with real failure paths. For mixer-style setters no fork change
   is needed at all — listeners already push Live's *accepted* value into
   Seshat's mirror, so honesty there is a Seshat-side choice about what the
   tool result claims, not a protocol gap.

### Interactions with the existing backlog

- **Issue #15 (declarative endpoint manifest) becomes materially more
  valuable** if this endpoint track proceeds: every addition widens a contract
  surface currently duplicated across registration code, README, SESHAT.md,
  Seshat's decoder, and `vendored_addresses_test.exs`.
- **Issue #3 (multi-track wildcard getter reply shape) should be decided with
  these bulk endpoints in mind**, so the repo does not end up with two
  competing aggregation conventions (per-item replies vs. one aggregate
  reply). The vendored precedent is aggregate-with-count.
- The current plan (issues #1, #2, #4, #5, #7) proceeds unchanged — the
  dispatch/error boundary work stands on wire-consistency grounds alone, with
  Phase 2c's calibrated expectations about fire-and-forget already correct.

---

## 4. Seshat-side findings (no fork change needed)

Recorded here so they are not misfiled as fork work; they belong in Seshat's
backlog.

1. **`/live/song/get/scenes/name [min,max]` already exists**
   ([abletonosc/song.py:239](../../priv/AbletonOSC/abletonosc/song.py#L239)) and returns every scene
   name in one reply. Seshat's `query_scene_names/1` (`handlers.ex:3417-3429`)
   does one query per scene beside a comment asserting "No bulk scene-name
   address exists." The endpoint is also missing from
   `docs/abletonosc-api-docs.md`, which is presumably how the comment
   survived. **Resolved in PR #62:** the endpoint is now documented.
2. **`/live/song/get/track_names` is registered and documented but used
   nowhere in Seshat** — `read_tracks/2` queries `/live/track/get/name` per
   track instead.
3. **`read_send/2` re-queries return names** the mirror already holds
   push-fresh; `return_track_label/1` reads them from the mirror a few lines
   away. Up to 12 redundant round trips per full send read.
4. **Correct the "sub-millisecond" latency claims** (`handlers.ex:35`,
   `:2308`, `:4724`) to the measured ~100ms before re-judging any design
   decision that rests on them — in particular the 13–17-query
   `get_clip_properties` design.
5. **Add echo checks (or adopt the future combined endpoints) in
   `get_track_devices` / `get_device_parameters`** for regular tracks (§2's
   correctness gap).
6. **Two Tier-A setters sit inside the spirit of roadmap #4's accepted
   subset but are not called out there:** `set_track_arm` returns
   "Armed track N" unverified while `record_clip`'s internal `arm_track/1`
   exists precisely because Live can refuse to arm; `set_time_signature`
   fires two independent messages and can report a plain error with the
   signature half-applied.
7. **Resolved in PR #62:** `vendored_addresses_test.exs` justified the
   browser-export stale-sweep age gate with "Transport does not serialize
   queries," which contradicted the current serialized design. The assertion
   remains; its rationale now describes the serialized query followed by the
   caller's file read.

### 4a. Full doc-coverage diff (`docs/abletonosc-api-docs.md` vs. registered addresses)

A static AST extraction of every `add_handler` registration in this fork
(literal calls plus the `properties_r`/`properties_rw`/`methods` loop
expansions — 567 unique addresses, zero unresolved call sites) was diffed
against the doc. The doc documents listeners generically per family
("Listen via `/live/<family>/start_listen/<property>`") for **song, track,
clip_slot, and scene**, so listener addresses in those families count as
documented when their getter is. Applying that convention:

**Registered but absent from the doc — 19 non-listener addresses** *(all
documented 2026-08-03 in PR #62; this table stands as the record of the
diff)*:

| Address | Notes |
|---|---|
| `/live/song/get/scenes/name` | Bulk scene names, optional `[min, max)` range; reply does not echo the range. The gap behind `handlers.ex:3417`'s false "no bulk address exists" comment |
| `/live/device/get/parameter/name` | Single-parameter name getter |
| `/live/song/set/root_note` | Getter is documented; setter is not |
| `/live/song/set/scale_name` | Getter is documented; setter is not |
| `/live/song/get/is_ableton_link_enabled` | Whole Link property undocumented (get, set, both listeners) |
| `/live/song/set/is_ableton_link_enabled` | " |
| `/live/song/capture_and_insert_scene` | Upstream method |
| `/live/song/set_or_delete_cue` | Upstream method |
| `/live/song/force_link_beat_time` | Upstream method |
| `/live/song/re_enable_automation` | Upstream method |
| `/live/track/delete_clip` | Upstream method |
| `/live/track/get/devices/can_have_chains` | Sibling `devices/name`/`type`/`class_name` are documented |
| `/live/clip/get/end_time` | |
| `/live/clip/get/is_triggered` | (clip_slot and scene `is_triggered` are documented; clip's is not) |
| `/live/clip/remove_notes_by_id` | |
| `/live/clips/filter` | Experimental; this repo's issue #19 recommends removal — document as unsupported or delete the routes |
| `/live/clips/unfilter` | " |
| `/live/song/export/structure` | The hazardous old export (issue #12) — absence may be deliberate; either document with its risks or remove the endpoint |
| `/live/application/get/average_process_usage` | Also the source of the stray startup datagram (issue #18) |

Plus `/live/song/{start,stop}_listen/is_ableton_link_enabled`, whose getter is
also undocumented (same Link gap).

**Families with no generic listener statement:**

- **clip** — 70 listen addresses (35 properties × start/stop — 15 read-only
  plus 20 read/write; this doc originally said 68/34) are invisible;
  only `playing_position`'s pair is listed explicitly. One "Listen via
  `/live/clip/start_listen/<property> <track_id> <clip_id>`" line fixes all
  of them.
- **device** — the `class_name`/`name`/`type` listener pairs and
  `/live/device/stop_listen/parameter/value` are undocumented
  (`start_listen/parameter/value` is documented; its stop is not).

**Documented but not registered: nothing real.** After excluding the
deliberately documented outbound addresses (`/live/error`, `/live/startup`,
`/live/song/get/beat`, and the push-only `/live/song/get/tracks` /
`return_tracks`), every remaining doc-side string is a prose fragment or
family prefix, not a phantom endpoint. The doc's `beat` entry was verified
against [song.py:286-295](../../priv/AbletonOSC/abletonosc/song.py#L286-L295): pushes really do go
out on `/live/song/get/beat`.

**Why the guard missed all of this:** the "every registered address is in the
canonical docs" test in `vendored_addresses_test.exs` extracts addresses only
from the vendored files (browser.py, return_track.py, song_structure.py, and
the exact-match song/view lists). Upstream registrations in song.py, clip.py,
track.py, device.py, clip_slot.py, scene.py, and application.py have no doc
coverage check. Extending `registered_addresses()` to all handler files —
with the loop-generated property routes expanded — closes the loophole.

**Scope caveat:** this diff checks address *presence* only. Argument and
response shapes of documented entries were spot-checked during review (all
accurate where checked) but not exhaustively audited.

---

## 5. What was explicitly considered and rejected

For the next reader who wonders why the "obvious" fixes are absent:

- **Request IDs on the wire** — settled, permanent divergence; the caller-side
  echo checks are the compensating control. Do not resurrect.
- **TCP or Max-for-Live bridge** — evaluated in Seshat
  (`docs/evaluating/bridge-options.md`); declined for dependency and rewrite
  cost. The cheaper named alternatives — verify-after-set and ack
  conventions — are exactly what §3.4 and Tier C already implement piecemeal.
- **Structured acks on every setter** — declined (queue load on a serialized
  transport). Replying endpoints are added per-operation where the failure
  path warrants it, not wholesale.
- **Universal read-back after every mutation** — the mirror's listener pushes
  already deliver accepted values for mixer-class properties; duplicating
  that with explicit reads costs serial queue time for nothing.

---

## Sources

Fork side: [SESHAT.md](../../priv/AbletonOSC/SESHAT.md), plus `HANDOFF.md`,
`issues.md` and `IMPLEMENTATION_PLAN.md` (fork repo only — not present at the
submodule pin).
Seshat side (at submodule pin `4584e13`): `lib/seshat/osc/transport.ex`,
`lib/seshat/osc/message.ex`, `lib/seshat/session/state.ex`,
`lib/seshat/tools/handlers.ex`, `lib/seshat/commands/registry.ex`,
`test/seshat/osc/transport_test.exs`,
`test/seshat/osc/vendored_addresses_test.exs`, `docs/ROADMAP.md`,
`docs/abletonosc-api-docs.md`, `docs/evaluating/bridge-options.md`,
`docs/evaluating/osc-port-contention.md`, `docs/smoke_tests/auto/mirror.md`,
`docs/smoke_tests/auto/recording.md`, `.claude/rules/osc.md`.
