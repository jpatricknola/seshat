# Plan: Batched pipelined queries — the measured lever for the N+1 reads

Roadmap item: **"Bulk reads vs. per-address queries — benchmark, then pick
the lever"** (currently #1).

## Context

Several read tools were designed against a latency figure that was wrong by
two orders of magnitude. Comments in `Seshat.Tools.Handlers` used to justify
N+1 query patterns as "sub-millisecond loopback round trips"; the measured
figure is ~100ms per serialized round trip, which makes
`get_clip_properties` a ~1.5s tool (13–17 queries per clip, 400+ round trips
to survey an 8×4 grid) and `get_track_sends` up to ~2.5s (1 + 2 per return),
with every one of those queries also head-of-line blocking every other
tool's OSC traffic behind Transport's single serialized queue. Both sites
carry a `TODO!` ([handlers.ex:2353](../lib/seshat/tools/handlers.ex#L2353),
[handlers.ex:4031](../lib/seshat/tools/handlers.ex#L4031)); the option space
is §2–§3 of
[abletonosc-integration-review.md](evaluating/abletonosc-integration-review.md).

The roadmap item's instruction was: benchmark first, then pick between three
candidate levers — fork bulk endpoints, per-address query lanes in
Transport, or freshness-gated mirror reuse. **The benchmark was run at plan
time (2026-08-04, below), and it collapses the choice.** The ~100ms is not
per-datagram cost; it is AbletonOSC's scheduling quantum. `manager.py`
schedules `tick()` once per 100ms on Live's main thread, and each tick's
`osc_server.process()` drains *every* datagram queued on the socket,
answering each inline ([manager.py:139-148](../priv/AbletonOSC/manager.py#L139-L148),
[osc_server.py:190-234](../priv/AbletonOSC/abletonosc/osc_server.py#L190-L234)).
So a query costs one tick *because it waits for the next tick* — and any
number of queries already on the socket when the tick fires cost that same
one tick, together.

### The measurements (2026-08-04, Live 12 + installed AbletonOSC, loopback)

Method: a throwaway Python harness bound `127.0.0.1:11001` (the Seshat
server was not running — it must be stopped for this, since AbletonOSC
replies only to that fixed port) and sent read-only getters to `:11000`,
timing replies with a monotonic clock. Large-burst runs were done at 9
tracks — 8 temporary MIDI tracks created for the run and deleted afterwards,
count verified back to the original 1.

| Test | Result |
|---|---|
| Serialized same-address getter ×20 (`/live/song/get/tempo`) | 99.6–100.4ms each (median 99.9) — exactly one tick per query |
| Serialized alternating addresses ×20 | identical: 99.1–100.4ms each |
| Burst of 10 different-address song getters, 3 trials | all 10 answered in **one tick**; spread between first and last reply 1.1–1.9ms |
| Burst of 45 (5 mixer getters × 9 tracks, mixed addresses) ×3 | 45/45 answered in one tick, spread 11.7–13.0ms |
| Burst of 63 (song scalars + 8 scene names + 45 track reads) | 63/63 in one tick, spread 14.2ms, zero drops |
| Same-address burst (`/live/track/get/name` × 9 tracks at once) | 9/9 in one tick, replies in send order, distinguished by echoed index |
| Bulk endpoints (`track_names`, `scenes/name`, `track_data`) | one tick each — **identical latency to a burst** |
| Single query at random phase ×10 | uniform 15–100ms — RTT is time-to-next-tick, nothing else |

Replies within a tick arrive in datagram arrival order; per-message
processing inside a tick is ~0.25ms.

### The decision

**Pipelined batches in `Seshat.OSC.Transport` — no fork change.** The other
levers lose on the numbers:

- **Fork bulk endpoints** (review §3.1–§3.3) buy *zero latency* over a
  batch: a bulk reply costs one tick, and so does a 63-datagram burst. What
  they'd buy is fewer datagrams (irrelevant at ≤26 datagrams on loopback)
  at the price of new Python per site, two commits each, a
  `mix abletonosc.install` + Live restart, `SESHAT.md` +
  `vendored_addresses_test` churn, and a permanently wider fork divergence.
  Three or four endpoints to cover what one Elixir primitive covers.
- **Per-exact-address in-flight lanes** don't fix the same-address loops
  that dominate two of the hot sites (`/live/return_track/get/name` × N,
  `/live/track/get/send` × N in `read_sends`; every per-track loop), and
  they trade the queue's one-in-flight simplicity for permanent concurrent
  bookkeeping. A batch pipelines same-address entries too, because entries
  are matched by echoed-argument prefix, not address alone.
- **Freshness-gated mirror reuse for `read_sends`' return names** (the
  gating the `TODO!` at handlers.ex:4031 sketches) becomes moot: batched,
  the name queries ride the same tick as the send values, so reusing the
  mirror would add the staleness ceremony the TODO warns about to save
  nothing.

One correctness note the batch inherits by construction: matching a reply to
a batch entry requires echo verification *inside* Transport (address +
echoed-argument prefix), which is the same defence `query_correlated/4`
bolts on caller-side today. A straggler with different arguments matches no
entry and answers nobody — strictly better than today's serialized path,
where it consumes the in-flight slot and forces a reissue. A straggler with
*identical* address and arguments is accepted, exactly today's residual
class 1; a listener push on a batched getter's address with a matching index
prefix is accepted, exactly today's class 2. Neither gets worse.

## OSC contract

**No new addresses, no fork change, no `mix abletonosc.install`.** Every
address below is already documented in
[abletonosc-api-docs.md](abletonosc-api-docs.md) and already sent by the
sites being converted. What the batch relies on — checkable per row — is the
reply echoing the request's arguments as a prefix:

| Address | Request | Reply | Echo prefix |
|---|---|---|---|
| `/live/clip/get/<property>` (the 11 `@clip_common_reads` + `is_midi_clip` + 4 `@clip_audio_reads`) | `track_id, clip_id` | `track_id, clip_id, value` | `[track, slot]` |
| `/live/track/get/name` | `track_id` | `track_id, name` | `[track]` |
| `/live/return_track/get/name` | `return_index` | `return_index, "ok", name` (vendored envelope) | `[index]`, tail `["ok", name]` |
| `/live/track/get/send` | `track_id, send_id` | `track_id, send_id, value` | `[track, send]` |
| `/live/track/get/devices/name` / `type` / `class_name` | `track_id` | `track_id, [values…]` | `[track]` |
| `/live/device/get/parameters/name` / `value` / `min` / `max` / `is_quantized` | `track_id, device_id` | `track_id, device_id, [values…]` | `[track, device]` |

Failure paths: upstream getters raise on a bad index and reply nothing —
the fork's structured `/live/error` (`["request", address, message,
arg_count, …args]`) names the failing request, and Transport already
correlates it by address + full wire-typed arguments. The batch extends that
per-entry. Vendored getters (`/live/return_track/get/name`) never raise;
their error arm is the `[index, "error", message]` envelope, decoded
caller-side as today.

Tick-model facts the design depends on, all measured above: one 100ms
processing tick; a burst queued before a tick is fully answered within it
(≤63 datagrams measured, zero drops, ≤15ms in-tick spread); replies arrive
in datagram order; bulk endpoints cost the same tick a burst does.

## Parts

### 1. `Seshat.OSC.Transport.query_batch/1,2`

**File:** [lib/seshat/osc/transport.ex](../lib/seshat/osc/transport.ex)

```elixir
@spec query_batch([{String.t(), list()}], non_neg_integer()) ::
        {:ok, [{:ok, list()} | {:error, {:live_error, String.t()}}]}
        | {:error, term()}
def query_batch(entries, timeout \\ 5000)
```

- **One queue slot.** A batch is a single entry in the existing FIFO — it
  occupies `in_flight` exactly as a single query does, with one absolute
  deadline and one timer. `in_flight` grows a second shape (single vs.
  batch); the deadline-drop-at-dequeue, deaf-transport
  (`{:error, :reply_port_unavailable}`), and expired-never-sent rules all
  carry over unchanged.
- **All datagrams sent back-to-back at dequeue.** A `:gen_udp.send/4` error
  mid-burst fails the whole batch with `{:error, reason}` (entries already
  sent are reads; nothing was mutated).
- **Reply matching:** a reply resolves the first *unresolved* entry whose
  address equals the reply's and whose request args are a wire-typed prefix
  of the reply args — integer/string equality, floats compared after the
  32-bit round trip, reusing the existing `wire_arg_match?/2`. The entry
  stores `{:ok, tail}` where `tail` is the reply args after the echoed
  prefix. Every inbound datagram is still broadcast on `"osc:in"` exactly as
  today, matched or not.
- **Structured `/live/error`** is matched against unresolved entries by
  address + exact full args (the existing `failed_request/2` check applied
  per entry); a match resolves that entry as
  `{:error, {:live_error, message}}` and the batch continues. A batch aimed
  at a vanished clip therefore fails *fast*: every entry's error arrives in
  the same tick.
- **Completion:** when every entry is resolved, reply `{:ok, results}` in
  entry order. **On deadline the server never replies** — the caller exits
  with the same shape as `query/3`, keeping the contract the ~20
  `catch :exit` sites are written against. Partial results are deliberately
  not delivered: at one tick per batch, "some answered" means Live stopped
  mid-tick, and the callers' timeout wording already covers that honestly.
- **Validation, raising `ArgumentError`** (programmer error, same class as a
  typo'd address): empty entry list; more than 64 entries (largest measured
  burst 63; largest planned batch 25 entries — the sends batch at Live's
  12-return cap); two entries with identical
  `{address, args}`; or one entry's args being a wire-prefix of another's on
  the same address (ambiguous matching). Entries with args `[]` are legal
  when their address is unique in the batch (reply matched by address, as
  `query/3` does today).
- **Reads only, by contract.** The moduledoc says so: batching a mutator is
  forbidden — a batch can time out with datagrams already on the wire, which
  is only harmless when nothing in it mutates.
- Extend the "Query serialization" moduledoc section with the batch
  semantics and the two inherited hazard classes (identical-args straggler,
  listener push), noting the mismatched-straggler case is strictly *better*
  than the serial path (answers nobody, consumes nothing, no reissue
  needed).

### 2. `get_clip_properties` — 13–17 queries → guard + 1–2 batches

**File:** [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex)

- Reimplement `read_clip_properties/3` over `query_batch`: entries
  `{clip_get_address(property), [track, slot]}`, each tail decoded with the
  existing `unwrap_payload/1`; the per-property error wording ("the
  #{property} of the clip in slot …") stays at this call site. First
  `{:error, {:live_error, message}}` in the results renders through the
  existing error paths.
- `do_call("get_clip_properties", …)` becomes: `ensure_clip/2` guard
  (unchanged — an empty slot still costs one fast error, not a batch of
  errors), then **one batch** of `"is_midi_clip"` + the 11
  `@clip_common_reads`, then a second batch of the 4 `@clip_audio_reads`
  only when the clip is audio. Net: ~2 ticks for MIDI, ~3 for audio, down
  from 13/17. The separate `clip_is_midi/2` call disappears from this flow
  (the helper itself stays — `ensure_midi_clip` and others use it).
- **Riders, at no extra work:** `read_clip_pair_context/3` and
  `read_clip_writeback/3` call the same helper, so `set_clip_properties`'
  pre-read and write-back shrink too. Ordering semantics are untouched: the
  pair context is still read in full before any write goes out, and the
  write-back still runs after all writes — only the datagram count changes.
  (The known `looping`-ordering wart is roadmap item "`set_clip_properties`
  reads the loop pair before the `looping` toggle lands", untouched here.)
- Delete the `TODO!` block at handlers.ex:2353; replace the comment with the
  tick-model reasoning (one batch, echo-checked in Transport, ~1 tick).

### 3. `get_track_sends` — 1 + 2N queries → count + 1 batch

**File:** [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex)

- `return_track_count/0` stays (it is also the vendored-extension probe).
- `read_sends/2` for `count >= 1` becomes one batch of `2N + 1` entries:
  `{"/live/track/get/name", [track]}` (the track-index guard, now riding
  the same tick instead of being implied by the first send read), plus per
  return `{"/live/return_track/get/name", [i]}` (envelope tail decoded via
  `unwrap_payload/1`) and `{"/live/track/get/send", [track, i]}`. At Live's
  12-return cap that is 25 entries, one tick. The `count < 1` branch keeps
  its existing single name-guard query.
- Error rendering: a `live_error` on the track-name entry uses the existing
  `@track_index_hint` wording; return-name envelope errors and send-entry
  errors keep their current hints (`@return_extension_hint`,
  `@send_index_hint`).
- Delete the `TODO!` block at handlers.ex:4031 — the mirror-reuse idea it
  gates is superseded (recorded in this plan); the replacement comment says
  why the names are queried rather than mirrored (same tick, no staleness
  ceremony).
- `set_track_send`'s guard and `confirm_send/5` read-back are **not**
  batched — they are ordered reads around a mutation, one query each, and
  their sequencing is the point.

### 4. Regular-track device reads — 3/5 queries → 1 batch each

**File:** [lib/seshat/tools/handlers.ex](../lib/seshat/tools/handlers.ex)

- `do_call("get_track_devices", %{"track" => track})` (the regular-track
  clause): one batch of the three `/live/track/get/devices/*` entries, echo
  `[track]`. The parallel-list zip stays; the batch guarantees all three
  lists came from replies echoing this track, which is what the three
  `query_correlated/4` calls verify today one at a time.
- `do_call("get_device_parameters", …)` regular-track clause: one batch of
  the five `/live/device/get/parameters/*` entries, echo `[track, device]`.
- The vendored `target: "return"` / `"master"` paths are already single
  combined queries — untouched.
- The reissue-once policy `query_correlated/4` applies is not replicated for
  batched entries: a mismatched straggler no longer consumes the reply slot
  (it matches no entry), so the reissue's reason to exist doesn't arise;
  a genuinely missing reply is a batch timeout, which the existing
  `catch :exit` wording already covers. Sites not converted keep
  `query_correlated/4` unchanged.

### 5. Comments, docs, and the decision record

- [handlers.ex](../lib/seshat/tools/handlers.ex): rewrite the file-header
  latency note (~line 30–40) and the comment at ~4933 to the tick model
  (~100ms *per serialized round trip* stays true; add that batches
  collapse a group to one tick). Grep `sub-milli` to catch any remnant.
- [state.ex](../lib/seshat/session/state.ex): one-line edit to the
  `read_tracks/2` doc (~line 905): the replacement for the per-index loop,
  if that item is ever bought, is `query_batch` (echo-checked per entry) —
  not the fork bulk-snapshot endpoint the review recommended before the
  benchmark existed. No behaviour change here.
- [abletonosc-api-docs.md](abletonosc-api-docs.md): add a short **"Round
  trips cost ticks, not datagrams"** measured subsection (beside the
  existing 2026-08-04 send-read-back measurements): the 100ms tick, burst →
  one tick (63 measured, zero drops, ≤15ms spread), replies in arrival
  order, bulk endpoints cost the same tick a burst does, serialized queries
  cost one tick each.
- [abletonosc-integration-review.md](evaluating/abletonosc-integration-review.md):
  dated resolution notes on §2's efficiency finding and §3's endpoint
  recommendation — benchmark run 2026-08-04, batching chosen, fork bulk
  endpoints not pursued (latency-equivalent, strictly more maintenance);
  §3.4's replying mutators explicitly unaffected (they belong to roadmap
  "Verify destructive mutations before reporting success").
- No `Definitions` change: no tool schema or description asserts a query
  count or a timing. No MCP surface change, no count bump in
  `definitions_test.exs`.

### 6. Tests

**Files:** [test/seshat/osc/transport_test.exs](../test/seshat/osc/transport_test.exs),
[test/seshat/tools/handlers_test.exs](../test/seshat/tools/handlers_test.exs)
(or a sibling file if handlers_test is at size), all against
`Seshat.Test.OSCSink` — nothing touches a live Ableton.

Transport (`query_batch`):
- happy path: N entries, replies delivered out of order, results in entry
  order with correct tails;
- same-address entries distinguished by echoed index (the sends shape);
- a reply matching no entry (wrong args) is broadcast, answers nothing, and
  the true reply still resolves its entry;
- per-entry structured `/live/error` resolves only its entry as
  `{:error, {:live_error, message}}`, others still answer;
- float32 prefix comparison (a `0.37`-style arg still matches its echo);
- deadline: caller exits, slot reclaimed, next queued request advances;
- wire order: all batch datagrams are on the sink before any reply is sent
  (the pipelining is real, not N serialized sends);
- `ArgumentError` on: empty batch, >64 entries, duplicate `{address, args}`,
  same-address prefix-ambiguous entries;
- a batch queued behind an in-flight single query waits its turn (FIFO
  preserved), and vice versa.

Handlers (converted sites):
- `get_clip_properties`: happy MIDI path is `ensure_clip` + one batch (sink
  asserts the datagram set), audio path adds the audio batch; a
  `live_error` on one property renders the existing error wording; timeout
  wording unchanged.
- `get_track_sends`: happy path is count + one 2N+1 batch; bad track index
  → track hint; zero returns keeps the single-guard path.
- `get_track_devices` / `get_device_parameters` (regular): one batch each,
  parallel lists zipped from one tick's replies.
- `set_clip_properties`: pair-context and write-back still produce correct
  ordered writes (existing ordering tests keep passing — they are the
  regression net for the rider).

## Testing

Everything above is pure: `OSCSink` receives the datagrams and scripts the
replies, so batching, correlation, error arms and wire order are all
assertable without Ableton. Nothing tests through `Transport.query/3`
against a live set. `mix precommit` before declaring done.

## Live verification

Nothing in `mix test` reaches any of this — every converted site goes
through `Transport.query_batch/2` on a real wire only here, so treat the
batched reads as having **zero** prior live coverage. No reinstall
precondition: this plan changes no Python, and every batched address is
already answered by the installed copy. Run the automated half with
`/smoke-test`.

- [smoke_tests/auto/clips.md](smoke_tests/auto/clips.md) § Clip properties
  read in one breath, and read true — *written for this change*: the MIDI
  batch reads back just-confirmed values (correctness of the echo matching
  now living in Transport), the empty slot still fails once and fast, and
  the timed call pins the pipelining itself (~1.5s serialized before; well
  under a second batched — right answers arriving slowly would mean the
  batch quietly serialized).
- [smoke_tests/auto/clips.md](smoke_tests/auto/clips.md) § The loop pair
  with looping off — the `set_clip_properties` rider (pair-context and
  write-back now ride the shared batched helper); its known-wart
  expectations are unchanged and any drift is a finding.
- [smoke_tests/auto/sends.md](smoke_tests/auto/sends.md) § Reading a
  track's sends labels each return correctly — *written for this change*:
  two returns at distinct confirmed levels, so a mispaired name/level (the
  exact hazard echo-prefix matching exists for) is detectable; plus the bad
  track index failing fast through per-entry `/live/error`.
- [smoke_tests/auto/sends.md](smoke_tests/auto/sends.md) § A send set is
  confirmed by its own read-back — regression net that the *unbatched*
  ordered guard/read-back around `set_track_send` still behaves beside the
  new batch path.
- [smoke_tests/auto/devices.md](smoke_tests/auto/devices.md) § Chain and
  parameter reads pair the right values — *written for this change*: the
  two regular-track batch conversions, judged by pairing (lists describing
  one chain; parameters under the device that was asked for).
- [smoke_tests/auto/devices.md](smoke_tests/auto/devices.md) § Device error
  paths are errors, not stalls — a bad index on a batched read still
  arrives as a fast structured `/live/error` (this run also proves the
  per-entry error path is reachable in Live, not just fed to itself by the
  test suite).
- [smoke_tests/manual/engineered-state.md](smoke_tests/manual/engineered-state.md)
  § An audio clip's audio-only properties still read — *written for this
  change*: the audio arm (the second batch) needs an audio clip, which no
  tool can create; a person drags a sample in and checks gain/warp against
  the clip's own view.

**Uncovered:** bursts above 63 datagrams (capped at 64 by construction; the
largest converted batch is 25 entries, the tool's 26th datagram being its
separate count query) — deliberately unmeasured; the
listener-push-during-batch collision (class 2 — unprovokable on demand,
same standing gap the serial path has); Live's 12-return ceiling for the
sends batch (the two-return check catches mispairing, which does not scale
with N).

## Out of scope

- **`Session.State.do_refresh/1` / `read_tracks/2` / the mirror rebuild.**
  The 4.6s rebuild ([mirror.md](smoke_tests/auto/mirror.md)) is this same
  disease at ~73 queries, but the mirror's degraded/reconciliation
  semantics are deliberately delicate and owned by roadmap "Monitored
  refresh worker for `Session.State`" — which is *gated on re-measurement
  anyway*. `query_batch` is the tool that item should reach for first: a
  batched rebuild (~3 ticks) would shrink the blocking window ~15× with no
  worker, likely retiring the item. Recorded there via the roadmap, not
  built here.
- **Fork bulk endpoints** (review §3.1–§3.3) — evaluated and not built; the
  benchmark shows them latency-equivalent to a batch at strictly higher
  maintenance cost. Reopen only if a read ever needs >64 datagrams or an
  atomic multi-tick snapshot.
- **Replying variants for destructive mutators** (review §3.4) — belongs to
  roadmap "Verify destructive mutations before reporting success",
  unchanged by this plan.
- **Per-address in-flight lanes** — rejected on the benchmark (doesn't fix
  same-address loops; permanent concurrency complexity for no latency win
  over batching).
- **Batching any mutation, or the ordered reads around one**
  (`set_track_send`'s guard/read-back, `quantize_clip`'s before/after
  reads, `set_device_parameter`'s confirm) — sequencing is their point;
  the batch contract is reads-only.
- **`get_clip_slots` / grid-survey macro-tools** — each per-clip call gets
  cheaper; whether a grid survey deserves its own tool is a separate
  feature question for the roadmap if usage demands it.

## Open questions

None left open — the ones planning raised were closed by measurement or by
construction, recorded here:

1. **Is the ~100ms per-query figure scheduling or processing?** Closed by
   measurement: it is AbletonOSC's 100ms tick; in-tick processing is
   ~0.25ms per message. Serialized = one tick each; burst = one tick total.
2. **Do large bursts drop datagrams?** 63 measured with zero drops (both
   socket directions are 64KB-buffered; ~40-byte requests, ~60-byte
   replies). The 64-entry cap keeps every batch inside the measured
   envelope; the largest converted batch is 25 entries.
3. **Do bulk endpoints beat pipelining?** Closed by measurement: identical
   one-tick latency (`track_names`, `scenes/name`, `track_data` all
   measured). They save only datagram count, which is not the scarce
   resource.
4. **Do the batched addresses echo their request args?** Verified per
   address against [abletonosc-api-docs.md](abletonosc-api-docs.md) (table
   above) — and the same-address burst measured the echo doing its job
   (9 `name` replies distinguished by index, arrival order = send order).
5. **Does the benchmark reflect the fork at the pin?** The harness ran
   against the *installed* Remote Scripts copy, but every measured address
   and the tick loop itself are upstream code identical at the pin; nothing
   measured touches the fork's divergences.
