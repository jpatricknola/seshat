# Repository Review

Review date: 2026-07-29

Scope: Production code, tests, configuration, scripts, CI workflows, and the
AbletonOSC submodule. The review traced the major HTTP, LiveView, MCP, OSC,
catalog, and Ableton runtime flows and included the safe setup, compilation,
formatting, static-analysis, and test commands available in the repository.

> **This document is the evidence, not the queue.** As of 2026-07-30 every
> accepted finding below is ranked in [docs/ROADMAP.md](docs/ROADMAP.md), which
> now holds features, defects and security work in one impact-per-effort list —
> the review's defects occupy its top seven. Come here for the file:line
> evidence and for the *Reviewer response* on each finding, which records what
> was accepted, narrowed, or rejected. Work is scheduled there; it is justified
> here. Security findings live in
> [docs/SECURITY_BACKLOG.md](docs/SECURITY_BACKLOG.md) on the same basis.

> **Edited 2026-07-30**, in two passes. Nothing in the original review's text has
> been reworded; every addition is marked.
>
> 1. **Security findings moved** to
>    [docs/SECURITY_BACKLOG.md](docs/SECURITY_BACKLOG.md): the two Critical
>    findings (AbletonOSC's unauthenticated network surface and arbitrary file
>    overwrite; unauthenticated production HTTP), the High finding on the Elixir
>    OSC listener accepting forged and malformed datagrams, and the two security
>    entries from the priority list. **Three of those are active work, not
>    deferred** — the OSC sockets are already bound beyond loopback today, so the
>    listener finding (whole, both halves) and the two AbletonOSC items sit in
>    that doc's "Fix now" section. Only the HTTP items are gated.
> 2. **Responses added, and declined items moved to the bottom.** Every finding
>    was re-verified against the code; each carries a *Reviewer response* block
>    where the repo side agrees, disagrees, or narrows the recommended fix. Three
>    items judged not worth acting on moved to
>    [Declined](#declined--not-planned), with reasons. Findings were renumbered.
>
> **Corrections applied after the original reviewer's 2026-07-30 response**, who
> was right on every point: the claim about deterministic post-test Ableton state
> (finding #2) was wrong and is corrected; the "no concurrent readers" rationale
> (finding #7) contradicted this document's own finding #1 and is rewritten; the
> speculative risk on unbounded LiveView growth was wrongly filed as
> security-only and is restored below; and the security doc's self-refuting gate
> is fixed there.

## Confirmed defects

### High

#### 1. The OSC transport corrupts concurrent query/reply routing

Files:

- `lib/seshat/osc/transport.ex:37-51`
- `lib/seshat/osc/transport.ex:112-143`
- `lib/seshat/tools/handlers.ex:2073-2083`

What is wrong: `Transport` has one `pending` slot. A second query overwrites the
first caller, and replies are correlated only by OSC address. Timed-out callers
also remain pending until another query overwrites them.

Realistic failure scenario: A session refresh, HTTP MCP request, and LiveView
agent request overlap. The second query steals the first query's reply. One
caller gets another request's data while another times out; a late reply can
then satisfy a later request to the same address.

Why it matters: All major read and multi-step mutation flows depend on these
queries. Incorrect state can lead to subsequent commands targeting the wrong
index.

Recommended fix: Serialize queries through a real queue, sending only one query
at a time. Track an internal timer and caller monitor, discard late replies, and
only dequeue the next request after completion. A stronger long-term fix is
adding request identifiers to the AbletonOSC protocol.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed, minus the long-term suggestion.**
> Confirmed: `handle_call` returns `{:noreply, ...}` after storing one
> `{from, address}`, so the GenServer accepts the next query immediately, and
> `dispatch/3` matches on address alone. The moduledoc at
> `transport.ex:43-47` explicitly reasons that nothing needs cleaning up —
> sound for sequential callers, unsound the moment two overlap.
>
> The review undersells the trigger. Multi-client MCP is not the realistic
> collision; `Session.State` re-reading every track name when the structure
> listener fires *is*, because that runs asynchronously from a different
> process than whatever tool call is in flight. Two overlapping queries to the
> *same* address with different arguments is the bad case — caller B silently
> receives A's data rather than timing out.
>
> **Serialize in Elixir; do not add request identifiers to the protocol.**
> That would mean a wire-format divergence on every address, carried against
> upstream forever, to solve what a queue already solves.

#### 2. The normal ExUnit suite sends real mutation commands to Ableton Live

Files:

- `test/seshat/tools/handlers_test.exs:6-52`
- `test/seshat/agent_test.exs:6-8`
- `test/seshat/agent_test.exs:15-55`
- `test/seshat/agent_test.exs:82-124`
- `README.md:203-211`

What is wrong: Tests start the real transport on production ports and exercise
pan, volume, mute, and solo handlers. The README incorrectly says the tests
avoid the live transport and require no Ableton.

Realistic failure scenario: A developer runs `mix test` while Live is open. The
suite changes the current set without warning. During this review, Live was
listening on UDP port 11000, so the test run sent mutation packets to the active
instance.

Why it matters: A supposedly safe unit-test command can silently damage unsaved
work.

Recommended fix:

- Introduce an OSC transport behaviour and inject a fake in tests.
- Alternatively, bind tests to an isolated UDP receiver on a non-Ableton port.
- Disable production OSC startup in `MIX_ENV=test`.
- Move all real-Live tests behind an explicit opt-in integration tag and safety
  confirmation.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed; this is the top item in practice.**
> Confirmed and worse than the "High" label suggests. `config/test.exs` already
> sets `start_osc: false`, so the *application* is clean — the two test files
> opt back in by hand with `start_supervised!(Seshat.OSC.Transport)`.
>
> **Correction (2026-07-30):** an earlier version of this response claimed a
> specific end state ("track 0 at pan centre and volume 0.5, track 1 centred,
> track 2 at +6 dB"). That was wrong — it came from reading part of one file.
> The suite sends more mutations than that: `handlers_test.exs:75` pans track 0
> to `-1.0` again, and `agent_test.exs` drives real mutations through the
> stubbed loop (pan `-1.0` at line 29 and `0.5` at line 159 on track 0, mute on
> tracks 0 and 1 at lines 96 and 102). **`agent_test.exs:102` mutes track 1 and
> never unmutes it** — unlike `handlers_test.exs`, there is no paired restore.
> And because ExUnit randomises order by seed, the resulting state is
> nondeterministic run to run. "Sends all of these; final state unpredictable"
> is both the accurate claim and the stronger one.
>
> This also drifted through a gap in our own rules:
> [.claude/rules/testing.md](.claude/rules/testing.md) forbids reaching
> `Transport.query/3` and never thought to forbid sending mutations. Widen that
> rule as part of the fix.
>
> **Narrower fix than any of the four offered:** give `Transport` a
> configurable target port and point tests at a throwaway one. Bullet 3 is
> already done. A transport behaviour plus a fake is more machinery than four
> tests justify.

#### 3. Negative indices pass validation and target objects from the end of Python collections

Files:

- `lib/seshat/tools/definitions.ex:19-30`
- `lib/seshat/tools/definitions.ex:131-190`
- `lib/seshat/tools/definitions.ex:193-229`
- `priv/AbletonOSC/abletonosc/track.py:10-28`
- `priv/AbletonOSC/abletonosc/clip.py:48-62`
- `priv/AbletonOSC/abletonosc/scene.py:13-23`

What is wrong: Many track, scene, and clip indices lack `minimum: 0`. Python
then uses those values directly as list indexes, where `-1` means the last
element.

Realistic failure scenario: A caller submits `track: -1` to delete, rename,
mute, or alter a track. The command operates on the last track while the
response reports that track `-1` was changed.

Why it matters: Invalid input becomes a valid but unintended destructive
operation.

Recommended fix:

- Add `minimum: 0` to every index except fields where `-1` is deliberately
  defined as "append."
- Centralize index validation in the Elixir handlers.
- Add explicit Python bounds checks before indexing Live collections.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed on the first two bullets; third
> declined.** Confirmed, and the shape is *inconsistency*, not absence:
> `minimum: 0` is present on the newer tools (`definitions.ex:518-561`,
> `1140-1267`) and missing on the older ones — `set_track_pan`,
> `set_track_volume`, `delete_track`, `duplicate_track`, `set_track_name`. The
> codebase already knows the right pattern.
>
> Drop the security framing; the realistic caller is a model hallucinating
> Python's `-1 == last` convention, which is entirely plausible, not an
> attacker.
>
> **Bullet 3 is declined:** explicit Python bounds checks means diverging three
> upstream files (`track.py`, `clip.py`, `scene.py`) permanently, when the
> Elixir side is the only caller and bullets 1–2 close the hole completely.
> Not worth the merge cost.
>
> **Doc consequence:** [docs/TOOL_AUDIT.md](docs/TOOL_AUDIT.md) §03 currently
> reads "Indexing is clean — strong. 0-based everywhere, consistently
> documented." That verdict audited whether the *convention* was applied
> consistently and never asked whether the schemas enforce it. It needs
> correcting.

#### 4. Numeric bounds disappear when tool definitions are converted to runtime validation

Files:

- `lib/seshat/mcp/schema.ex:34-45`
- `lib/seshat/tools/definitions.ex:19-30`
- `lib/seshat/tools/definitions.ex:45-57`
- `lib/seshat/tools/definitions.ex:232-242`
- `lib/seshat/tools/handlers.ex:1033-1044`
- `lib/seshat/tools/handlers.ex:1169-1173`

What is wrong: Integer schemas retain ranges, but every JSON Schema `number`
becomes an unconstrained `{:either, {:float, :integer}}`. A runtime validation
probe confirmed that `set_track_pan` accepts `2.0` despite its declared maximum
of `1.0`.

Realistic failure scenario: A direct MCP caller sends invalid pan, volume,
tempo, note timing, or similar values. Live may clamp, reject, or log the
request, while Seshat reports success using the requested value.

Why it matters: The advertised schema and enforced contract differ,
undermining both safety and response accuracy.

Recommended fix: Apply range constraints to both branches of the numeric union
or implement a custom numeric validator. Add parity tests that submit values
immediately outside every declared bound.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed, and it understates the problem.**
> Confirmed at `schema.ex:45`. But the framing — bounds lost *in the MCP
> conversion* — implies API-key mode is fine. It isn't: that path has no
> validation layer at all, and the Anthropic API does not enforce tool schemas
> either. Bounds are advisory in **both** modes.
>
> So the fix must land in `Handlers`, which is the single dispatch point both
> modes share, rather than only in `MCP.Schema`. Fixing the Peri conversion
> alone would leave half the surface unguarded while appearing to close the
> issue. Same seam as #3's second bullet — do them together.

### Medium

#### 5. Mutation handlers report success when only the UDP send succeeded

Files:

- `lib/seshat/tools/handlers.ex:1033-1062`
- `lib/seshat/tools/handlers.ex:1136-1173`
- `lib/seshat/tools/handlers.ex:1462-1499`
- `lib/seshat/tools/handlers.ex:1567-1624`
- `priv/AbletonOSC/abletonosc/handler.py:27-45`

What is wrong: Most setters and destructive operations return success after
`:gen_udp.send/4`. Python catches Live API exceptions and only logs them; it
sends no failure acknowledgement.

Realistic failure scenario: A stale track index is deleted after another user
changes the Live set. Live rejects the operation, but the MCP response says it
succeeded and FollowCam steers to an assumed destination.

Why it matters: The control plane cannot distinguish applied actions from
dropped or rejected actions, making agent decisions and user recovery
unreliable.

Recommended fix: Extend mutation endpoints to return structured success/error
acknowledgements. For destructive operations, validate the target immediately
before mutation and verify the resulting count or property afterward.

Confidence: **High**

> **Reviewer response (2026-07-30) — observation agreed; recommended fix
> rejected as written.** The first sentence of the fix ("extend mutation
> endpoints to return structured success/error acknowledgements") reverses a
> settled and documented decision. From
> [.claude/rules/osc.md](.claude/rules/osc.md): *"Setters stay silent — each is
> guarded by its getter first, and nothing waits on one."* Making every setter
> await a reply adds a round-trip to every mutation and multiplies the exposure
> in #1, for a failure mode that is rare on a local socket.
>
> **The second sentence is the right scope, and is already house style** —
> `delete_device` bounds-checks then verifies by re-count, `set_clip_properties`
> verifies each write by re-read. Extend that to the remaining destructive
> operations and leave parameter setters fire-and-forget.
>
> The scenario as written can't happen: it turns on "another user changes the
> Live set," and there is no other user. The reachable version is a *stale
> model-held index* — same outcome, different cause.
>
> **Doc consequence:** TOOL_AUDIT §04 already names this failure class
> ("Silent failure is the worst failure mode — I'd report success on a write
> that never happened") but scoped it to two tools and marked them FIXED. Its
> "0 correctness fixes outstanding" line needs revisiting.

#### 6. `create_track` can return a nonexistent index and silently fail to name it

File:

- `lib/seshat/commands/registry.ex:203-216`

What is wrong: The flow reads the old count, sends create and rename messages,
and returns that count without verifying that the track count increased.

Realistic failure scenario: The create packet is dropped or Live refuses the
create. The subsequent rename targets an invalid index, yet Seshat returns
`{:ok, count}` and follows the view to that index.

Why it matters: Subsequent device loads or note writes can target the wrong
track or fail after the user was told creation succeeded.

Recommended fix: Use the same pre-count/post-count verification already
implemented for return-track creation, then name the verified new index and
confirm the name.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed as written.** Confirmed, and the
> recommendation is exactly right: `Registry.ensure_created/2` sits *directly
> above* `create_and_name_track/2` in the same file doing precisely this for
> return tracks. This is applying an existing local pattern, not designing one.
>
> **Doc consequence:** TOOL_AUDIT's inventory row for `create_track` reads
> "Keep · —" with no wart recorded, while the `create_return_track` row
> correctly documents its guard. That row should carry this.

#### 7. Session refresh blocks the state server and can combine fabricated song data with stale tracks

Files:

- `lib/seshat/session/state.ex:100-110`
- `lib/seshat/session/state.ex:334-388`
- `lib/seshat/tools/handlers.ex:2000-2029`

What is wrong: Refresh performs sequential synchronous OSC calls inside the
`GenServer`. Failed song queries use plausible defaults, while a failed
track-count query preserves the prior track list.

Realistic failure scenario: Ableton disconnects during refresh. State calls are
blocked across multiple timeouts, then `get_session_state` reports 120 BPM, 4/4,
C Major alongside tracks retained from the previous set.

Why it matters: Consumers cannot tell fresh state, stale state, and fabricated
fallback state apart. During a long refresh, other process messages and reads
are delayed.

Recommended fix: Perform refresh in a monitored worker under one overall
deadline. Retain the last complete snapshot atomically and attach freshness,
connection, and last-error metadata. Do not replace unknown values with
plausible musical defaults after initialization.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed on the last sentence; the rest is
> gold-plating at one user.** The fabricated defaults at `state.ex:337-344` are
> the real defect and the cheap fix. The harm is sharper than stated: the model
> doesn't merely *report* 120 BPM and 4/4 — it writes bar lengths and note
> positions against them. A stated unknown is strictly better than a plausible
> wrong number.
>
> **Corrected rationale (2026-07-30):** an earlier version of this response
> justified deferring the blocking half with "a single user and no concurrent
> readers to starve." That contradicts this document's own finding #1, where
> concurrency between listener-driven re-reads and in-flight tool calls is the
> argument for taking that finding seriously. Both cannot be true. Overlap does
> happen with one human at the keyboard.
>
> The scope reduction still holds, on honest grounds: the blocking window is
> short, it has never been observed, and #1's queue will change the contention
> picture anyway. **Do the defaults now; treat the blocking refresh as a
> deferred risk** — revisit the monitored worker, the overall deadline, and the
> freshness/connection/last-error metadata if it is ever actually seen.

#### 8. Catalog replacement reports success after persistence failure and writes non-atomically

Files:

- `lib/seshat/library/catalog.ex:130-152`
- `lib/seshat/library/catalog.ex:823-838`
- `lib/seshat/library/catalog.ex:1002-1012`

What is wrong: The ETS table is cleared before replacement; concurrent searches
can observe an empty catalog. A disk-write failure is logged but returned as
`{:ok, summary}`. `File.write/2` can leave a truncated catalog after a crash.

Realistic failure scenario: Reindex succeeds in memory while the disk is full.
The UI reports success, but restart restores an old or empty catalog. A
concurrent search during replacement returns no results.

Why it matters: Catalog durability and search consistency are falsely
represented to callers.

Recommended fix: Write a temporary file, sync it, and atomically rename it
before reporting durable success. Return persistence failures. Replace the
searchable table using a new ETS generation and atomic table-reference swap.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed on durability; the ETS half is
> over-engineering.** Confirmed at `catalog.ex:831-838`: the write failure is
> logged and then returned as `{:ok, summary}`. Temp-file-plus-rename and
> returning persistence failures are both cheap and correct — take them.
>
> **Skip the ETS generation swap.** `search/1` reads the table directly from
> the caller process, so the window is real, but reindex is a rare,
> user-initiated operation that freezes Live's UI for up to a minute and that
> the user is actively waiting on. A few milliseconds of empty results inside
> that window is not a failure anyone can observe.
>
> **Sequencing note:** this touches the same writer as
> [docs/ROADMAP.md](docs/ROADMAP.md)'s catalog staleness check, whose planner
> note already calls for a built-at timestamp in `catalog.json`. Do them in one
> pass.

#### 9. Hitting the agent iteration limit hides already-executed mutations

Files:

- `lib/seshat/agent.ex:73-85`
- `lib/seshat/agent.ex:103-126`
- `lib/seshat_web/live/assistant_live.ex:27-42`

What is wrong: At the iteration limit, `Agent` returns only a generic error and
discards its accumulated commands and conversation. The LiveView error branch
leaves history unchanged.

Realistic failure scenario: Nine or ten tool rounds successfully alter the set,
but the model requests one more round. The UI reports an error with no record of
the completed actions. Retrying can repeat them.

Why it matters: Partial side effects become invisible precisely when recovery
information is most important.

Recommended fix: Return a structured partial result containing executed
commands and updated history. Show a warning that actions occurred, and persist
the conversation even on terminal loop errors.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed as written.** Confirmed at
> `agent.ex:83-86`: the guard clause drops both `executed` and `messages`.
> This is the best product-level finding in the review — ten rounds of real
> mutations land, the UI says "error," the conversation isn't kept, and the
> obvious user response (retry) duplicates all of it.
>
> Scoped to API-key mode, which is the dev/fallback path, so it ranks below the
> items above — but the fix is small and the failure is silent, which is the
> combination worth clearing.

### Low

#### 10. Development documentation gives a false safety guarantee

File:

- `README.md:203-211`

What is wrong: It claims 83 tests and says tests avoid the live transport. The
current suite has 337 tests and directly sends Live mutation commands.

Realistic failure scenario: A contributor trusts the documented guarantee and
runs tests against an unsaved Live set.

Why it matters: The incorrect statement increases the chance of silent data
loss.

Recommended fix: Correct the documentation immediately, then replace the
warning with a true guarantee once test transport isolation is implemented.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed as written, and it is the cheapest
> item here.** Labelled Low, but it is the finding that makes #2 dangerous:
> without the false guarantee, a contributor might not run the suite with a
> live set open. Fix the text now and restore a real guarantee after #2 lands —
> the two-step sequencing in the recommendation is correct.

## Speculative risks

These are grounded in code and OTP semantics, but the triggering failures were
not reproduced.

### Medium risk: An MCP supervisor crash permanently removes MCP service

File:

- `lib/seshat/application.ex:62-81`

Risk: The nested MCP supervisor's root child spec uses `restart: :temporary`. If
it exits abnormally, the application supervisor will not restart it, while the
Phoenix endpoint remains healthy.

Recommended fix: Use `:permanent` or `:transient` restart semantics and add a
kill/recovery supervision test.

Confidence: **High**

> **Reviewer response (2026-07-30) — agreed, but take `:transient`, not
> `:permanent`.** Confirmed at `application.ex:80`. The two options are not
> equivalent: `:permanent` would take the whole application down when Anubis
> genuinely cannot start, which is very likely why `:temporary` was chosen in
> the first place. `:transient` restarts on abnormal exit only, which is
> exactly the case described and keeps the original intent intact.

### Low risk: LiveView conversation state grows without bounds

_Restored 2026-07-30. This was moved to the security backlog on the assumption
that it only mattered with untrusted visitors; the original reviewer correctly
objected that a single local user can hit it alone._

Files:

- `lib/seshat/agent.ex:73-80`
- `lib/seshat/agent.ex:121-126`
- `lib/seshat_web/live/assistant_live.ex:6-7`
- `lib/seshat_web/live/assistant_live.ex:27-37`

Risk: Full tool inputs, outputs, API messages, and UI log entries accumulate for
the lifetime of the LiveView. Large catalog/device results can eventually
exceed Anthropic context limits or materially increase LiveView memory.

Recommended fix: Set explicit context and log budgets, summarize old turns, and
cap large tool-result payloads.

Confidence: **Medium**

> **Reviewer response (2026-07-30) — agreed, and it is a local operational risk,
> not a security one.** Filing this behind the deployment gate was a mistake: one
> person can exhaust the Anthropic context window on their own, and
> `search_library` and `get_device_parameters` results are exactly the payloads
> large enough to do it. The multi-user framing (unbounded spend against one key)
> is a *consequence* of the same defect, not its only reachable form.
>
> Stays Low: it is scoped to API-key mode, which is the dev/fallback path — MCP
> mode is primary and keeps no history in this process. Capping large
> tool-result payloads before they enter `messages` is the cheap majority of the
> fix; summarising old turns is the part to skip until needed.

## Architecture summary

The application has five principal runtime domains:

1. **Phoenix/LiveView boundary**
   - `/` hosts `AssistantLive`.
   - `Seshat.Agent` calls Anthropic using `Req`, executes model tool calls, and
     stores conversation state in the LiveView process.
2. **MCP boundary**
   - Anubis exposes generated tools over streamable HTTP at `/mcp`.
   - A separate `mix mcp` path supports stdio.
   - Both MCP and the agent route through the same tool definitions and
     handlers.
3. **BEAM process boundary**
   - Root supervision starts Telemetry, DNSCluster, PubSub, optional OSC
     transport/state, optional catalog, optional MCP, and the Phoenix endpoint.
   - `Seshat.OSC.Transport` owns a single UDP socket and the single pending
     query slot.
   - `Seshat.Session.State` maintains an in-memory mirror of Live song, track,
     return, and master state.
   - `Seshat.Library.Catalog` owns ETS state and JSON persistence.
4. **Ableton boundary**
   - Commands cross UDP to the AbletonOSC Python Remote Script on port 11000.
   - Replies and listeners return to port 11001.
   - The Python handlers execute inside Ableton Live's process/UI scheduling
     environment.
   - The browser exporter and custom return/song/view handlers extend the
     upstream AbletonOSC submodule.
5. **Filesystem/external-service boundary**
   - Catalog data is persisted as JSON.
   - Reindexing uses a browser export produced by the Remote Script and
     supplements it from Ableton's read-only SQLite library database.
   - The assistant communicates with Anthropic over HTTPS.

Major flows traced:

- MCP request -> Anubis validation -> tool handler -> OSC send/query ->
  AbletonOSC -> Live API.
- LiveView submission -> Anthropic tool loop -> same handlers -> updated UI
  history.
- OSC listener update -> Transport decode -> PubSub -> Session.State mirror.
- Structural mutation -> optional state refresh and FollowCam steering.
- Catalog reindex -> Ableton browser export -> Elixir normalization/merge ->
  ETS and JSON persistence.

## Commands run

| Command | Result |
|---|---|
| `mix setup` | Passed after sandbox approval; dependencies and frontend assets built |
| `MIX_ENV=test mix deps.unlock --check-unused` | Passed |
| `MIX_ENV=test mix compile --warnings-as-errors` | Passed |
| `mix format --check-formatted` | Passed |
| `mix test` | **337 tests, 0 failures**; also sent real OSC mutations because Live was active |
| `mix xref warnings` | Unsupported by the installed Elixir version |
| `mix xref graph --format cycles --label compile-connected` | Passed; no compile-connected cycles |
| `mix hex.audit` | Passed; no retired Hex packages |
| Runtime MCP validation probe | Confirmed out-of-range `set_track_pan` value `2.0` is accepted |
| Python `compile()` over 42 `.py` files | Passed with one invalid-escape `SyntaxWarning` |
| `git status --short` | Clean before this report was added |

`mix precommit` was not run directly because its alias includes modifying
`mix format` and dependency-lock cleanup. Its safe read-only equivalents were
run individually. Credo and Dialyzer are not configured as project
dependencies/tasks.

## Test coverage gaps

- No concurrency, timeout cleanup, late-reply, forged-source, or
  malformed-packet tests for `OSC.Transport`.
- No controlled tests for Session.State startup, failed refreshes, freshness,
  PubSub restart, or prolonged Ableton outage.
- No authentication, production-binding, concurrent-client, or MCP-supervisor
  recovery tests.
- Mutation tests verify local UDP send success, not Live-side application or
  postconditions.
- No automated tests for the custom Python browser export, return-track,
  song-structure, and view extensions.
- Python tests require a prepared live session and perform mutation during
  collection.
- No agent tests for maximum iterations, partial side effects, API timeouts,
  malformed responses, or context growth.
- No catalog tests for disk failure, truncated writes, atomic replacement, or
  concurrent search during reindex.
- No measured coverage report was generated because rerunning the current suite
  would issue further Live mutations.

> **Reviewer response (2026-07-30):** accurate as a list of what is untested,
> but it should not be read as a work queue. Several entries describe tests for
> behaviour that is deliberately out of scope (authentication,
> production-binding) or for failures that only matter past the deployment gate
> — see [docs/SECURITY_BACKLOG.md](docs/SECURITY_BACKLOG.md). The entries worth
> acting on are the `OSC.Transport` concurrency and timeout-cleanup tests
> (finding #1) and the agent maximum-iteration test (finding #9). Note also the
> standing constraint in
> [.claude/rules/testing.md](.claude/rules/testing.md): anything reaching
> `Transport.query/3` needs a live Ableton, so several of these are only
> testable against the pure layer or a fake.

## Where each finding is scheduled

**[docs/ROADMAP.md](docs/ROADMAP.md) is the canonical order** — one
impact-per-effort queue covering features, defects and security work together.
This table maps findings to their rank there; the roadmap entry carries the
accepted scope, including the parts of a recommendation that were rejected.

This table names the roadmap item each finding became. It deliberately carries no
rank column: ranks renumber on every ship, and a stale rank silently points at an
unrelated item. Find the item by title — the roadmap is ordered, so its position
is the current rank.

| Finding | Roadmap item |
|---|---|
| #2 tests mutate a live set, #10 README | **Shipped 2026-07-30** — see [docs/archive/PLAN_test_isolation.md](docs/archive/PLAN_test_isolation.md) |
| #7 fabricated session state | Stop fabricating session state after OSC failures |
| #1 single pending query slot | Serialize OSC queries and clean up timed-out callers |
| #3 negative indices, #4 numeric bounds | **Shipped 2026-07-30** — see [docs/archive/PLAN_enforce_tool_ranges.md](docs/archive/PLAN_enforce_tool_ranges.md) |
| #6 `create_track` unverified index | Verify `create_track` actually succeeds |
| #9 agent iteration limit | Preserve partial agent results at the tool-iteration limit |
| #8 catalog persistence | Make catalog persistence atomic and report write failures |
| #5 mutations report success on send | Verify destructive mutations before reporting success |
| MCP supervisor `:temporary` | Restart the MCP supervisor after abnormal failure |
| LiveView conversation growth | Cap large tool-result payloads in API-key mode |
| The three declined findings | Not scheduled — see [Declined](#declined--not-planned) |

The security findings removed from this review are all shipped as of 2026-07-30
(test isolation, AbletonOSC's loopback bind, the browser-export path restriction,
and the Elixir listener/decoder hardening); their evidence is in
[docs/SECURITY_BACKLOG.md](docs/SECURITY_BACKLOG.md).

### Original: three highest-priority fixes

_Historical. Superseded by the list above._ Security items were removed to
[docs/SECURITY_BACKLOG.md](docs/SECURITY_BACKLOG.md); the original list held two
of them above these three.

1. Replace the single pending OSC query slot with serialized, timeout-aware
   query management.
2. Isolate all unit tests from the real Ableton ports and make live integration
   tests explicitly opt-in.
3. Enforce numeric ranges and non-negative indices consistently in MCP
   validation, handlers, and Python.

## Areas not validated

- Real Ableton behavior against a controlled disposable Live set.
- Vendored Python `pytest`, because collection reloads AbletonOSC and the tests
  destructively manipulate Live.
- Live-side success and error acknowledgements for every custom OSC endpoint.
- Real Anthropic API behavior; agent tests use `Req.Test`.
- Windows-specific Remote Script behavior.
- Production reverse-proxy, TLS, IPv6 exposure, and deployment configuration.
- Runtime behavior under actual PubSub or MCP supervisor crashes.
- Quantitative code coverage and Dialyzer/Credo output.

> **Reviewer response (2026-07-30):** Windows is deliberately out of scope
> (see [docs/ROADMAP.md](docs/ROADMAP.md), "Deliberately not planned"), and
> deployment configuration is gated. The gap worth closing is the first one —
> real Ableton behaviour against a disposable set — which is what the
> `/smoke-test` skill and [docs/validation-script.md](docs/validation-script.md)
> exist for and which no automated suite will ever replace.

---

# Declined — not planned

Findings below were verified as accurate and are **not being addressed**. They
were moved here from the body of the review on 2026-07-30; each keeps its
original text, followed by the reason for declining.

## Collecting the vendored Python test suite reloads AbletonOSC as an import side effect

_Originally Medium, finding #10._

File:

- `priv/AbletonOSC/tests/__init__.py:16-30`

What is wrong: Importing the tests immediately creates a client and sends
`/live/api/reload`, outside a fixture and before any test selection.

Realistic failure scenario: Running `pytest --collect-only` or importing the
package reloads the Remote Script in an active Live session. A failed reload can
leave control handlers unavailable.

Why it matters: Test discovery itself changes external runtime state.

Recommended fix: Remove all module-level network activity. Put reload behind an
explicit, opt-in session fixture that verifies the expected test environment.

Confidence: **High**

> **Declined (2026-07-30) — accurate, but it is upstream's harness and we never
> run it.** Confirmed: the module-level `c.send_message("/live/api/reload")` is
> real. But `mix test` never imports it — the Elixir suite only *greps* the
> vendored Python (`vendored_addresses_test`), and nothing in this project
> invokes `pytest`. Fixing it means carrying a divergence in a file we do not
> execute, through every upstream merge, forever. That trade is backwards for a
> fork whose merge cost we actively manage
> ([docs/fork-options.md](docs/fork-options.md)).
>
> **Instead:** note it in the fork's `SESHAT.md` as a known upstream hazard and
> do not run `pytest` against a Live session that matters. Reconsider only if we
> ever adopt the Python suite as part of our own verification.

## Vendored OSC dispatcher contains an invalid Python escape sequence

_Originally Low, finding #11._

File:

- `priv/AbletonOSC/pythonosc/dispatcher.py:145-157`

What is wrong: `'[\w|\+]*'` uses invalid string escapes and emits a
`SyntaxWarning`. The character class also treats `|` as a literal member.

Realistic failure scenario: A future Python version promotes the warning or
changes escape handling, preventing Remote Script loading or altering wildcard
matching.

Why it matters: This code runs inside the Python version bundled with Live,
where version changes are outside Seshat's control.

Recommended fix: Use a raw string and correct the intended expression, for
example `r"[\w+]*"` if slash exclusion is not required.

Confidence: **High**

> **Declined (2026-07-30) — third-party vendored code; the fix costs about what
> the divergence costs.** This is `pythonosc`, vendored inside AbletonOSC, which
> is itself vendored inside our fork — two levels away from code we own. The
> stated risk is real but distant: invalid escapes have been warned about for
> years and Live bundles its own interpreter, so the version change is not on a
> schedule we need to anticipate. Editing it adds a `SESHAT.md` divergence entry
> and a merge conflict surface to silence one `SyntaxWarning`.
>
> **Reconsider if** an Ableton release actually bumps the bundled Python to a
> version where this is an error, or if the same file needs changing for another
> reason — at which point fix it in passing. Upstream `pythonosc` is the right
> owner.

## PubSub restart leaves session state permanently unsubscribed

_Originally a speculative Medium risk._

Files:

- `lib/seshat/application.ex:14-40`
- `lib/seshat/session/state.ex:100-103`

Risk: `Phoenix.PubSub` and `Session.State` are siblings under `:one_for_one`.
State subscribes only during `init/1`. If PubSub crashes and restarts, State
remains alive with a subscription to the old process state and may stop
receiving OSC broadcasts.

Recommended fix: Put dependency-ordered children under `:rest_for_one`, or
monitor PubSub and re-subscribe after replacement.

Confidence: **Medium**

> **Declined (2026-07-30) — sound reasoning, but the first fix is worse than
> the disease and the trigger effectively never happens.** The mechanism is
> correct: `Session.State` subscribes in `init/1`, so a PubSub restart would
> leave it holding a registration in a dead registry and permanently deaf.
>
> But `:rest_for_one` at `application.ex:39` would, given the current child
> order, restart Transport, Session.State, Catalog, the MCP supervisor **and the
> Phoenix endpoint** on any PubSub blip — trading a hypothetical failure for a
> guaranteed heavy one. And `Phoenix.PubSub` crashing is close to unheard of;
> nothing in this project has ever seen it.
>
> **Reconsider if it is ever actually observed**, in which case take the
> second option (monitor and re-subscribe), which is targeted and cheap. Note
> that `get_session_state`'s `refresh: true` already exists as a manual backstop
> for a mirror that has gone stale for any reason.
