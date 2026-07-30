# Plan — Isolate tests from live Ableton, and correct the safety documentation

ROADMAP #1. Two halves of one problem: `mix test` sends real mutation packets
to a running Live set, and `README.md` tells contributors it doesn't. Findings
#2 and #10 in [../REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md).

## Context

`config/test.exs` sets `start_osc: false`, so the *application* never starts the
transport in tests. Two test files opt back in by hand with
`start_supervised!(Seshat.OSC.Transport)`, and `Transport` hardcodes its ports:
it binds UDP 11001 and sends to `127.0.0.1:11000` — exactly AbletonOSC's pair.
With Live open, a test run drives the real set.

**What the suite actually sends today.** Verified by reading every one of the 20
test files, not inferred from the review:

| Site | Address | Args |
|---|---|---|
| `handlers_test.exs:13` | `/live/track/set/panning` | `[0, -1.0]` |
| `handlers_test.exs:19` | `/live/track/set/panning` | `[1, 0.0]` |
| `handlers_test.exs:25` | `/live/track/set/volume` | `[0, 0.5]` |
| `handlers_test.exs:30` | `/live/track/set/volume` | `[2, 1.0]` |
| `handlers_test.exs:36,41` | `/live/track/set/mute` | `[0, 1]` then `[0, 0]` |
| `handlers_test.exs:47,52` | `/live/track/set/solo` | `[0, 1]` then `[0, 0]` |
| `handlers_test.exs:75` | `/live/track/set/panning` | `[0, -1.0]` |
| `handlers_test.exs:1041,1048` | `/live/clip/set/name` | `[0, 1, "Bass"]` ×2 |
| `agent_test.exs:29` | `/live/track/set/panning` | `[0, -1.0]` |
| `agent_test.exs:96,102` | `/live/track/set/mute` | `[0, 1]`, `[1, 1]` |
| `agent_test.exs:159` | `/live/track/set/panning` | `[0, 0.5]` |
| `transport_test.exs:44` | `/seshat/test/ping` | `[]` (deliberately not a real address) |

Two things the review did not have:

- **The clip rename is a mutation nobody counted.** `name_captured_clip/2`
  calls `maybe_name_clip/3`, which sends `/live/clip/set/name`. Two tests hit
  it, so the suite renames the clip in track 0 / slot 1 to `"Bass"`.
- **That test's own comment is wrong.** `handlers_test.exs:1034` says
  "Transport isn't started in test (config/test.exs sets start_osc: false), so
  the rename send hits `:noproc`" — but the module's `setup_all` starts
  Transport, so the send lands for real and the `catch :exit` guard it claims to
  exercise is never reached. The comment is why this went unnoticed: it reads as
  a deliberate safety argument.

`agent_test.exs:102` mutes track 1 with no paired unmute, and ExUnit randomises
order by seed, so the end state is nondeterministic run to run.

**The table above is exhaustive, checked mechanically.** `handlers_test.exs`
reaches `Seshat.Tools.Handlers` at 21 `call/2` sites and through 29 public
helper functions, and each was classified rather than sampled:

- Of the 21 `call/2` sites, **10 send** (the four setter describes plus
  `param key normalisation`'s first test). One (`get_session_state`,
  `handlers_test.exs:61`) exits on `Session.State` being unstarted, which the
  test already tolerates. Four `search_library` calls touch only `Catalog` (ETS)
  — `handlers.ex:1718-1742` has no `Transport` in it. Six error in
  transport-free validation before any send: `record_clip`'s `ensure_bars/1` is
  the first step of its `with` (`handlers.ex:1262`), and
  `set_clip_properties`'s `ensure_clip_changes/1` and `validate_clip_pairs/1`
  are the first two of its own (`handlers.ex:1537-1538`). The last is the
  unknown-tool fallback.
- Of the 29 public helpers, **exactly one reaches the wire**:
  `name_captured_clip/2` (`handlers.ex:2236`), via the `defp maybe_name_clip/3`
  above. Established by walking every `def` in `handlers.ex` for a transitive
  call to `Transport`/`FollowCam` or to any of the sending private helpers — not
  by eye. Every other helper the tests call is a pure formatter, parser or
  validator.

Everything else is already clean and stays that way: `registry_test.exs`,
`follow_cam_test.exs`, `state_test.exs` and the rest never start Transport
(`follow_cam_test.exs:216` deliberately asserts `steer/2` survives its absence).

**The fix, and why this one.** Give `Transport` configurable ports and point the
test env at a throwaway pair. The review offered a transport behaviour plus an
injected fake; that is a production-code abstraction bought to protect four
tests, and it would leave the real `:gen_udp` path untested. Config makes the
whole test *environment* safe by default: any test that starts Transport — now
or in future, sync or async — is isolated without remembering to do anything.
An injected fake only protects the tests that remember to inject it.

Two riders that belong in this change:

- `.claude/rules/testing.md` forbids reaching `Transport.query/3` and never
  thought to forbid *sending*. That gap is how this drifted in; it is widened
  here, in the same commit as the code that makes the new rule true.
- The README's guarantee is corrected, and only then restored as a real one —
  the two-step sequencing the review asked for.

## OSC contract

**No new addresses, and no Python.** `priv/AbletonOSC` is untouched, so there is
no submodule commit, no pin bump, no `mix abletonosc.install`, and no Live
restart. Everything here is `lib/`, `test/`, `config/` and docs.

What is load-bearing instead is the *port* contract, verified against
[abletonosc-api-docs.md](abletonosc-api-docs.md) (lines 10–11) and
`priv/AbletonOSC/abletonosc/constants.py:5-6`:

| Port | Owner | Direction |
|---|---|---|
| 11000 | AbletonOSC (`OSC_LISTEN_PORT`) | Seshat → Live |
| 11001 | Seshat `Transport` (`OSC_RESPONSE_PORT`) | Live → Seshat, replies **and** listener pushes |

AbletonOSC replies to 11001 as a fixed destination, not to the sender's port
(see [ableton-osc-reference.md](../.claude/docs/ableton-osc-reference.md) and
[osc-port-contention.md](osc-port-contention.md)). Two consequences shape this
plan:

1. **Changing only the send port would not be enough for safety, but is enough
   for isolation.** A test bound to 11001 while Live runs steals that instance's
   replies and pushes. So both ports move in the test env.
2. **The reply port must stay a fixed, known number in tests**, not `0`
   (ephemeral): `transport_test.exs` pre-binds it to exercise the
   `:eaddrinuse` → deaf fallback, and `:gen_udp.open(0, …)` can never return
   `:eaddrinuse`.

Chosen test pair: **31000** (send) / **31001** (reply). Deliberately far from
11000/11001 rather than adjacent, so a one-digit slip in either direction lands
on nothing; below the ephemeral range (49152+) so a fixed bind can't collide
with a kernel-assigned port; unassigned by IANA.

---

## Part 1 — `Transport` reads its ports from config

`lib/seshat/osc/transport.ex`.

1. Replace `@ableton_port 11000` / `@client_port 11001` with defaults —
   `@default_send_port 11000`, `@default_reply_port 11001` — and two private
   readers:

   ```elixir
   defp send_port, do: Application.get_env(:seshat, :osc_send_port, @default_send_port)
   defp reply_port, do: Application.get_env(:seshat, :osc_reply_port, @default_reply_port)
   ```

   Naming follows the canonical docs' own words ("Send port: 11000 / Reply
   port: 11001") and the flat-key house style of `:catalog_path` / `:start_osc`.
2. `init/1` resolves both **once** and stores them in state
   (`%{socket:, pending:, deaf:, send_port:, reply_port:}`), so a config change
   mid-run can't split a running transport's behaviour between two ports.
   `open_deaf/0` takes the resolved ports as arguments rather than reading
   config a second time.
3. Every use of the old attributes moves to state: `:gen_udp.open(reply_port,
   …)` in `init/1`, `:gen_udp.send(socket, @host, state.send_port, message)` in
   both `handle_call({:send, …})` and `handle_call({:query, …})`, and the two
   `#{@client_port}` interpolations in the deaf error log.
4. `@host {127, 0, 0, 1}` stays hardcoded — loopback either way, and the bind
   address is ROADMAP #4's business, which edits the same `:gen_udp.open/2`
   call. Nothing here blocks it.
5. Moduledoc: state that the ports are `config :seshat, :osc_send_port` /
   `:osc_reply_port`, defaulting to AbletonOSC's 11000/11001, and that
   `MIX_ENV=test` points them elsewhere so the suite cannot reach Live.

Checkable: the old `@ableton_port` / `@client_port` attributes are gone, and
no `:gen_udp.open/2` or `:gen_udp.send/4` call in `lib/` contains a literal
`11000` or `11001`. The literals remain only as the two production defaults
and in explanatory documentation.

## Part 2 — The test env points at throwaway ports

`config/test.exs`, next to the existing `start_osc: false` block:

```elixir
# The suite must be safe to run with Live open and unsaved work. AbletonOSC
# listens on 11000 and replies to a fixed 11001; these are deliberately neither.
# Any test that starts Seshat.OSC.Transport therefore talks to a test-local
# socket (Seshat.Test.OSCSink) and cannot reach Ableton — asserted by
# test/seshat/osc/transport_test.exs.
config :seshat, :osc_send_port, 31000
config :seshat, :osc_reply_port, 31001
```

This is the whole safety property. Everything after it is proof and hygiene.

## Part 3 — A sink that absorbs the packets and proves where they went

New `test/support/osc_sink.ex` (`test/support` is already on
`elixirc_paths(:test)`), module `Seshat.Test.OSCSink`:

- `start_link/1` opens `:gen_udp` on `Application.fetch_env!(:seshat,
  :osc_send_port)` (overridable with `:port`) in `active: true` mode.
- `handle_info({:udp, …, data})` decodes with `Seshat.OSC.Message.decode/1` and,
  when a `:forward_to` pid was given, sends it `{:osc_out, address, args}`.
- `terminate/2` closes the socket.

Two reasons this earns its ~35 lines rather than leaving the port unbound:

1. **It turns "isolated" from a claim into an assertion.** A test can say
   `assert_receive {:osc_out, "/live/track/set/panning", [0, -1.0]}` — the
   datagram provably arrived at a test-local socket, and as a bonus the four
   setter tests now verify the address and argument list they send instead of
   only their own reply string. `/live/track/set/panning` is not guessable from
   the address name (ROADMAP #7's neighbourhood: naming is irregular), so this
   is real coverage, not ceremony.
2. **It removes a platform question.** Sending to an unbound loopback port
   provokes ICMP port-unreachable; unconnected UDP sockets ignore it on macOS
   and Linux, but with a listener bound the question never arises.

Note for ROADMAP #4: when `Message.decode/1` gains an `{:ok, …}` /
`{:error, …}` return, this is one extra call site to update.

## Part 4 — Rework the two offending test files (and tighten one more)

### `test/seshat/tools/handlers_test.exs`

1. **Delete the module-level `setup_all`.** 125 of this file's 135 tests never
   reach the wire and have no business owning a UDP socket. Add a private
   helper and attach it only where a send happens:

   ```elixir
   defp osc_sink(_context) do
     start_supervised!({Seshat.Test.OSCSink, forward_to: self()})
     start_supervised!(Seshat.OSC.Transport)
     :ok
   end
   ```

   Sink first, so it is bound before the first datagram.
2. `setup :osc_sink` inside the five describes that send: `set_track_pan`,
   `set_track_volume`, `set_track_mute`, `set_track_solo`, and
   `param key normalisation`.
3. Each of those tests gains an `assert_receive {:osc_out, address, args}` for
   the exact address and arguments from the table in Context. (The
   `param key normalisation` describe's two `stringify_keys/1` tests send
   nothing; only its first test needs the assertion.)
4. **Split the `name_captured_clip/2` describe in two**, which is what makes the
   stale comment true again:
   - A describe *with* `setup :osc_sink`: naming a captured clip substitutes the
     name into the returned map **and** fires
     `/live/clip/set/name [0, 1, "Bass"]` — now asserted at the sink.
   - A describe *without* Transport, carrying the corrected comment: with no
     transport running, `maybe_name_clip/3`'s `catch :exit` must swallow the
     `:noproc` and `name_captured_clip/2` must still return the named map. This
     is the guard the current comment claims to cover and doesn't.
   - `name_captured_clip(clip, nil)` needs neither.

### `test/seshat/agent_test.exs`

5. Delete the `setup_all`; start the sink and Transport in the existing `setup`
   block alongside `Req.Test.verify_on_exit!()`. Three of its nine tests execute
   tools, so per-test is honest and cheap.
6. Assert the wire in all three tool-executing tests:
   `{:osc_out, "/live/track/set/panning", [0, -1.0]}` in the single-tool test,
   both mutes in the multiple-tool test, and
   `{:osc_out, "/live/track/set/panning", [0, 0.5]}` in the multi-step test.
   The unpaired mute of track 1 stops being a hazard because there is nothing
   on the other end — and the assertions record what the tests meant.

### `test/seshat/osc/transport_test.exs`

7. Replace `@client_port 11001` with the configured reply port so the deaf-path
   setup binds the test port, not Ableton's. **Use
   `Application.compile_env!(:seshat, :osc_reply_port)`, not `fetch_env!/2`**:
   the value is read in a module attribute, and `Application.get_env/fetch_env`
   in a module body emits "is discouraged in the module body, use
   `Application.compile_env/3` instead" — which `mix precommit` turns into a
   build failure, since `compile --warnings-as-errors` runs in `:test`
   (`preferred_envs: [precommit: :test]`, `mix.exs:30`). The runtime reads
   elsewhere in this plan are all inside function bodies and are unaffected.
   Keep the `:eaddrinuse` tolerance: a
   second concurrent `mix test` on the machine leaves the port occupied, and
   either branch satisfies what the test needs (the port is held by someone
   else).
8. Give it the sink too, so `"sends still go out"` no longer fires
   `/seshat/test/ping` at whatever holds 11000.
9. **Add the tripwire** — the test that makes the README's restored guarantee
   enforceable rather than aspirational:

   ```elixir
   describe "test-environment isolation" do
     test "the suite never targets AbletonOSC's ports" do
       assert Application.fetch_env!(:seshat, :osc_send_port) == 31000
       assert Application.fetch_env!(:seshat, :osc_reply_port) == 31001
     end
   end
   ```

   `fetch_env!/2` is load-bearing: `get_env/2` would return `nil` if someone
   deleted either config entry, and `nil not in [11000, 11001]` would let the
   supposed tripwire pass while `Transport` fell back to its production
   default. Exact equality also catches a partial or accidental port change.
   If someone reverts `config/test.exs`, the suite fails loudly instead of
   silently accepting the regression — which is precisely the failure mode
   this whole item exists to end.

   **What the tripwire does not cover, and what does.** It asserts the *config*,
   not that `Transport` honours it — a half-done Part 1 (one `:gen_udp.send/4`
   left on a literal) would pass it while packets still reached Live. Both
   halves are covered elsewhere, which is worth knowing before anyone
   "simplifies" either:
   - **Send port** — Part 4's `assert_receive {:osc_out, …}` assertions. A
     datagram arriving at the sink is proof it went to the configured port,
     because that is the only port the sink is bound to.
   - **Reply port** — this file's own deaf-path tests (items 7–8). They pre-bind
     the configured reply port and require `Transport` to come up deaf, and both
     branches catch a `Transport` still binding 11001. If 11001 is free it does
     not go deaf at all, so `"already bound by another process"` never appears
     and `"queries fail immediately"` times out. If 11001 is *held* — the normal
     state on this machine, since `.mcp.json` points clients at a running server
     that owns it — it goes deaf but logs 11001, and item 7's
     `assert log =~ "#{@client_port}"` is now asserting the configured 31001.
     Either way the file fails. That test is load-bearing for the isolation, not
     just for the port-contention message it was written for.

## Part 5 — Widen `.claude/rules/testing.md`

Add a rule immediately above the existing `Transport.query/3` one (the
Seshat-specific list), since it is the more fundamental of the two:

> - **Never let a test send OSC to a real Ableton.** The suite must be safe to
>   run with Live open and unsaved work. In `MIX_ENV=test`, `Transport` sends to
>   `config :seshat, :osc_send_port` and binds `:osc_reply_port`
>   ([config/test.exs](../../config/test.exs)) — deliberately not AbletonOSC's
>   11000/11001 — so any test that starts `Seshat.OSC.Transport` reaches a
>   test-local socket. Don't hardcode 11000 or 11001 in a test, don't override
>   those config keys, and start
>   [`Seshat.Test.OSCSink`](../../test/support/osc_sink.ex) alongside Transport
>   so mutations are asserted at the wire (`assert_receive {:osc_out, address,
>   args}`) rather than only through the handler's reply string.

The existing `Transport.query/3` bullet stays as-is: unchanged in force, and
now with a milder failure mode (a stray query test times out against a dead
port instead of reading a real set).

## Part 6 — Documentation

`README.md`, Development section (lines 203–211):

1. Drop the hardcoded test count. It said 83 when there were 337 — a number
   that goes stale by construction is what produced finding #10. Replace with a
   claim that stays true:

   ```
   mix precommit    # compile --warnings-as-errors, deps.unlock --unused, format, test
   mix test         # no Ableton required — and safe to run with Live open
   ```

2. Replace the false guarantee with the real one, naming its mechanism so a
   reader can check it:

   > `mix test` cannot reach Ableton. In `MIX_ENV=test` the OSC transport sends
   > to a throwaway UDP port and binds another (`config/test.exs`), never
   > AbletonOSC's 11000/11001 — `test/seshat/osc/transport_test.exs` fails if
   > that is ever pointed back at Live. Nothing in the suite reaches
   > `Transport.query/3` either: those need a live Ableton and would time out
   > (5 seconds by default).

3. **Rider — four broken links in the same file's Docs table.**
   `docs/PLAN_remaining_osc_tools.md`, `docs/PLAN_sound_catalog.md`,
   `docs/architecture-evaluation.md` and `docs/tool-use-migration-plan.md` all
   moved to [archive/](archive/) and the table still points at the old paths.
   Fix the paths, mark them as archived, and point the "what's not built yet"
   row at [ROADMAP.md](ROADMAP.md), which is the living list. Included because
   this item's goal is that the README stops making false statements, and these
   are in the same two sections being edited.

`CLAUDE.md`, Verification section: extend the `mix test` bullet from "full
suite, no Ableton required" to also state that the transport is pointed at a
throwaway port in `MIX_ENV=test`, so the suite is safe with Live open.

---

## Testing

**Implementation order matters here.** Parts 1 and 2 land before anything is
run: until `config/test.exs` names the test ports, `mix test` is still the
hazard this plan exists to remove. Either do those two first, or close Live.

Covered pure, no Ableton (the whole of it — this item has no Python half and
touches no `Transport.query/3` path):

- `mix precommit`. Tool count unchanged (53), so no `definitions_test.exs` bump.
- The five reworked describes in `handlers_test.exs` and the three
  tool-executing tests in `agent_test.exs` now assert the exact OSC address and
  arguments at the sink —
  strictly more coverage than before, on a socket that cannot reach Live.
- `handlers_test.exs`'s transport-free `name_captured_clip/2` test genuinely
  exercises `maybe_name_clip/3`'s `catch :exit` for the first time.
- `transport_test.exs`'s deaf-path tests keep working against the test reply
  port, and the new tripwire asserts the isolation itself.
- Sanity check by grep, not by eye: in `lib/`, `11000` / `11001` appear only
  in `Transport`'s two default attributes and explanatory documentation; in
  `test/`, they appear only in the isolation tripwire and the unrelated
  `log_filter_test.exs` log-text fixture. No send or bind call hardcodes either
  production port.

**The verification that matters, and it is manual:** with Ableton Live open on
a scratch set, run `mix test` and confirm nothing moves — no pan, no volume, no
mute, no solo, no clip rename. That is the claim the README will make, and no
automated test can make it. Note the scratch set: **Live is running on this
machine right now** (PID 625 on UDP 11000, checked 2026-07-30), so this check
must not be run against work worth keeping until the change is in. It is a
single check, so it goes at the top of the `/smoke-test` run for this change
rather than into the checklist permanently.
Everything else needing Live is unaffected: `/smoke-test`'s existing items run
the app in dev, where the ports are AbletonOSC's as always.

## Out of scope

- **An OSC transport behaviour and an injected fake.** Rejected above; the
  review's own preferred fix. Reopen only if something needs to simulate
  *replies* in tests, which would mean testing through `Transport.query/3` —
  itself forbidden.
- **A `@tag :integration` opt-in lane for real-Live tests.** Nothing wants to
  live there: the tests being isolated all assert reply strings and wire
  content, both of which are better checked against a sink. Live-only
  behaviour is `/smoke-test`'s job and stays there.
- **Loopback bind (`ip:`) and sender validation on `Transport`, and
  `Message.decode/1`'s safe error return** — ROADMAP #4, same module and even
  the same `:gen_udp.open/2` call. Kept separate because #4 is security work
  with its own test surface; this item is test isolation. Note the one
  interaction: #4's decode signature change touches `Seshat.Test.OSCSink`.
- **Binding AbletonOSC itself to loopback** — ROADMAP #2/#3, a submodule
  commit. Unrelated to `mix test`.
- **The rest of `README.md`.** Only the Development section's guarantee and the
  Docs table's broken paths are corrected; no restructuring.

## Open questions

1. **The suite has not been run against this plan** — ⚠️ deliberately, and it
   cannot be until Parts 1–2 land or Live is closed. **Checked 2026-07-30:**
   `lsof -nP -iUDP:11000` shows `Live` (PID 625) bound to UDP 11000 on this
   machine right now, so `mix test` at this moment would drive the open set.
   That is the roadmap item's premise confirmed by measurement, not an
   assumption.

   **Narrowed as far as static analysis reaches.** The worry underneath this
   question was a test whose pass depends on Transport being alive module-wide
   (`handlers_test.exs`'s `setup_all`) that reading might miss. Every one of the
   21 `Handlers.call/2` sites and 29 public helper entry points in that file is
   now classified in Context, mechanically rather than by eye: 10 sends, one
   tolerated `:exit`, and the rest transport-free. `agent_test.exs`'s three
   tool-executing tests all send through those same setter clauses. So the
   describes needing `setup :osc_sink` are known, not guessed.

   **What is irreducibly left for the first run:** that `mix test` is green
   after the rework — ExUnit mechanics (a `setup` in a `describe`, per-test
   `start_supervised!` of two processes, `assert_receive` timing on a loopback
   datagram) rather than anything about which tests touch the wire. Close Live
   for that run, or land Parts 1–2 first, which is why the Testing section
   fixes the implementation order.
2. ~~**Repeated bind/unbind of a fixed UDP port within one run.**~~
   **Resolved during planning (2026-07-30).** The sink is started per test in
   seven describes, so port 31000 is bound and released roughly a dozen times
   per run. Measured directly on this machine (macOS 24.6): 15 consecutive
   `:gen_udp.open(31000, …)` → send → `close` cycles, all clean — UDP has no
   `TIME_WAIT`. Also measured: two consecutive sends to an *unbound* loopback
   port both return `:ok`, so the ICMP concern behind Part 3's second
   justification is not a hazard on this platform either; the sink is bought for
   the wire assertions, which is the better reason anyway. Fallback if it ever
   flakes on another machine: one sink per file in `setup_all`. Not a design
   choice to make now.

Question 1 does not need the user's decision — it is "confirm on the first run",
after Parts 1–2 are in place.
