# Security — active work and the deployment gate

This doc holds two different things, and the distinction is the whole point:

- **[Fix now](#fix-now)** — the OSC surface is *already* exposed beyond
  loopback. AbletonOSC binds `0.0.0.0` every time Live runs with the Remote
  Script installed, and Seshat's own reply socket binds the wildcard address
  too. Nothing about these waits on a deployment; they are live on any
  networked machine today. All three are cheap.
- **[Deployment-gated](#deployment-gated)** — the HTTP surface genuinely is
  dormant. It requires an act of deployment to become reachable, and until then
  fixing it buys nothing.

**Scheduling lives in [ROADMAP.md](ROADMAP.md), not here.** The three Fix-now
items are ranked there as **#1** (AbletonOSC loopback bind), **#2** (browser
export path) and **#3** (Elixir listener and decoder) — #1 and #2 ship as one
submodule commit and one `mix abletonosc.install`. The gated items are
deliberately absent from that queue. This doc is the evidence and the reasoning.

> **Corrected 2026-07-30.** The first version of this doc gated *everything*
> behind "anything binds beyond loopback", while simultaneously recording that
> AbletonOSC already binds `0.0.0.0` — a self-refuting gate that deferred three
> cheap fixes which are reachable right now. The split above is the correction,
> raised by the original reviewer. The error came from filing the OSC items with
> the HTTP items because both were "security"; they are not the same shape.
> **Exposure that already exists is not a deployment concern.**

## The gate

The second section activates when either of these becomes true:

- **The HTTP endpoint binds beyond loopback** — `MIX_ENV=prod`, a tunnel, a
  reverse proxy, or `ip: {0,0,0,0}` in dev "just to test from my phone".
- **A second human gets an address to point a client at** — an invited user, a
  collaborator, a demo.

Either trigger activates all of the gated items, not the subset that looks
relevant. They compose: the missing auth is only reachable because of the public
bind, and rate limiting is meaningless without either.

Source: the 2026-07-29 external review
([REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md)), re-verified against the code,
plus that reviewer's 2026-07-30 response. Ranked by impact-per-effort, matching
[ROADMAP.md](ROADMAP.md)'s convention.

## What this doc is not

**Correctness bugs with no security dimension do not belong here** — they live in
[REPOSITORY_REVIEW.md](../REPOSITORY_REVIEW.md), which is the active correctness
backlog. Several are easy to mistake for security items because they touch the
same files:

| Finding | Why it isn't a security item |
|---|---|
| `mix test` sends real mutations to an open Live set | Damages your own unsaved work. No attacker involved. |
| Single `pending` slot in `OSC.Transport` corrupts concurrent query/reply | A structure-listener re-read racing a tool call is a same-machine bug. |
| Missing `minimum: 0` on track/clip/scene indices | The realistic caller is a model hallucinating Python's `-1 == last`. |
| Numeric bounds dropped in `MCP.Schema` | Bad values come from the model, and API-key mode has no validation layer at all. |
| `create_track` returns an unverified index | Correctness. |
| Agent iteration limit discards executed commands | Correctness. |
| Unbounded LiveView conversation growth | A single local user can exhaust the context window on catalog output alone. |

Malformed-datagram decoding used to appear in this table. It doesn't any more:
it is one finding with the source-validation work, and that whole finding is now
item #3 below.

---

# Fix now

Reachable today on any networked machine. Total effort across all three is
roughly an afternoon, most of it the fork round-trip.

## #1 · AbletonOSC listens on `0.0.0.0` and retargets replies to the last sender

**What's wrong:** [osc_server.py:15](../priv/AbletonOSC/abletonosc/osc_server.py#L15)
binds the wildcard address, and [osc_server.py:189](../priv/AbletonOSC/abletonosc/osc_server.py#L189)
reassigns `self._remote_addr` to whoever most recently sent a packet, so any
sender can redirect the listener push stream to itself. There is no
authentication at this layer at all — the Live API is directly exposed to
anything that can reach UDP 11000.

**Why it is first:** it is the exposure that makes #2 remotely reachable, and
it is one line. Do not count on the macOS application firewall as a mitigation —
relying on it is the same reasoning this correction exists to remove.

**This is upstream's deliberate design, not a bug.** It is how people drive Live
from a TouchOSC iPad; upstream's own comment acknowledges the trade
("prevents registering listeners from different IPs"). Seshat needs none of it —
confirmed 2026-07-30 that nothing else here speaks OSC to Live. (A Maschine MK3,
planned as a controller, is USB MIDI end to end and is unaffected.)

**Fix:** bind `127.0.0.1` and drop the reply-address retargeting; Seshat's reply
port is fixed at 11001 on localhost, so the dynamic behaviour is pure liability.

**Cost to carry:** this *changes* upstream behaviour rather than extending it, so
unlike our other divergences it will conflict on merges. Record it in the fork's
`SESHAT.md`. Needs the two-commit fork sequence plus `mix abletonosc.install`
and a Live restart — see [.claude/rules/osc.md](../.claude/rules/osc.md).

**If a networked OSC controller is ever wanted**, make the bind address a
constant in the fork rather than reverting to the wildcard.

**Plan:** [PLAN_abletonosc_loopback_and_safe_exports.md](PLAN_abletonosc_loopback_and_safe_exports.md)
— shared with the browser-export restriction so both fork changes land in one
install.

**Effort:** Low to write, ongoing to carry.

## #2 · `/live/browser/export` writes to any caller-supplied path

**What's wrong:** [browser.py:228-279](../priv/AbletonOSC/abletonosc/browser.py#L228-L279)
takes `dest_path` straight off the wire, runs `os.makedirs` on its directory,
and opens it `"w"`. Arbitrary file overwrite with Ableton Live's privileges.

**Why it stays active even after #1:** #1 makes it unreachable from the network,
but it remains reachable from any local process, and this is **our** code, not
upstream's — the fix carries no merge cost. Defence in depth on the one item
here we fully own.

**Fix:** stop accepting a caller-selected location at all. Python creates a
unique file under `~/.seshat/browser-exports/` and echoes its resolved absolute
path; Elixir validates that the returned path is a regular file directly under
that root before reading or deleting it.

**The scope is two-sided — Elixir changes too.**
[`Catalog.reindex/1`](../lib/seshat/library/catalog.ex#L240-L255) builds a full
path under `System.tmp_dir!()`, passes it to
[`export_browser/1`](../lib/seshat/library/catalog.ex#L879-L893), reads that
exact path back, and `File.rm`s it in an `after` block. All four steps have to
move to the new contract. The path validation is load-bearing until the Elixir
listener/source-hardening item ships: a forged reply must never turn into an
arbitrary Elixir read or delete.

**Plan:** [PLAN_abletonosc_loopback_and_safe_exports.md](PLAN_abletonosc_loopback_and_safe_exports.md)
— shared with the loopback bind so both fork changes land in one install.

**Effort:** Low, but touches two languages and needs the fork round-trip plus
`mix abletonosc.install`.

## #3 · The Elixir OSC listener trusts any source and crashes on malformed input

Originally finding #7 of the review, kept whole — its two halves are one fix in
one module.

**What's wrong:** [transport.ex:56](../lib/seshat/osc/transport.ex#L56) opens
11001 with no `ip:` option, so it binds the wildcard, and nothing checks the
source of an inbound datagram before
[dispatch/3](../lib/seshat/osc/transport.ex#L133-L143) uses it to satisfy a
pending query or broadcast it into `Session.State`. Separately,
[message.ex](../lib/seshat/osc/message.ex) decodes with no safe error return:
`find_null/2` recurses until `:binary.at` raises, `decode_arg/2` has no
catch-all clause (no `b`, `d`, `h` type tags), and `decode/1` returns a bare
tuple. Any datagram it can't parse crashes `Transport` and orphans the pending
caller.

**The crash half needs no attacker.** A music machine is full of OSC-speaking
software, and a stray broadcast to 11001 is an ordinary accident. That is why
this is active work rather than gated hardening — the security framing is the
smaller half of the reason to fix it.

**Fix:** `ip: {127,0,0,1}` in `@socket_opts`; match `_ip`/`_port` in
`handle_info` against the known AbletonOSC endpoint instead of discarding them;
make `Message.decode/1` return `{:ok, message}` / `{:error, reason}` and
validate lengths, type tags, padding and trailing data, logging and dropping
malformed packets instead of raising.

**Note:** the loopback bind does most of the security work here; source
validation is belt-and-braces against local processes. The decode hardening is
the part with independent value.

**Effort:** Low. All in `lib/`, no fork round-trip, and testable without Ableton
— which none of the other items are.

---

# Deployment-gated

Dormant until one of the two triggers above fires. Do not pre-build these.

## #4 · Nothing authenticates `/mcp` or the assistant UI

**What's wrong:** [router.ex:13-33](../lib/seshat_web/router.ex#L13-L33) puts
`live "/", AssistantLive` behind the plain `:browser` pipeline and forwards
`/mcp` to Anubis with no auth plug in front of either.
[no_auth_discovery.ex](../lib/seshat_web/plugs/no_auth_discovery.ex) exists
specifically to tell probing MCP clients that there is no OAuth here — the
absence is deliberate and documented, which is correct for a loopback tool and
indefensible past the gate.

**Reachable consequences:** `/mcp` is the full destructive tool surface — create,
delete, rename, overwrite clips, load devices, transport. `/` is worse per
request: an anonymous visitor drives Live *and* spends the configured Anthropic
key.

**Fix:** a shared-secret bearer token checked in a plug ahead of both scopes is
enough for a first version — this is not a product with accounts. The MCP spec's
OAuth flow is the heavier option and probably premature.

**Blocked on:** the multi-user decision below.

**Effort:** Medium.

## #5 · Production binds every interface, and starting that way is silent

**What's wrong:** [runtime.exs:52-61](../config/runtime.exs#L52-L61) is the
untouched `phx.new` default — `ip: {0,0,0,0,0,0,0,0}`, all IPv6 interfaces,
generator comment still attached. Combined with #4 that is the whole tool surface
open to the network, and nothing warns.

**Why this one really is dormant:** it applies only under `MIX_ENV=prod`, which
this project has never run. Dev binds loopback
([dev.exs:12](../config/dev.exs#L12)).

**Fix:** default prod to loopback, and **refuse to boot** when a non-loopback
bind is configured without an auth secret present. Fail-closed is the point — the
failure mode being guarded against is someone deploying without reading this
file.

**Effort:** Low.

## #6 · No rate limiting or request-size caps

**What's wrong:** nothing bounds request rate or body size on `/mcp` or the
LiveView. A single expensive call is enough to matter here: `reindex_library`
walks Live's whole browser on the UI thread and freezes it for up to a minute,
and `search_library` full-scans ETS per query.

**Fix:** body-size limit in the endpoint, and a per-token rate limit on `/mcp`.
Give the genuinely expensive tools (`reindex_library`, browser export) a stricter
bucket than the rest.

**Effort:** Low-Medium.

## The non-security blocker in the same gate

Worth stating once so it doesn't get discovered late: **authentication does not
make Seshat multi-user.** There is one `OSC.Transport`, one `Session.State`
mirror, and one Ableton instance behind them, and AbletonOSC replies to a fixed
port so a second Seshat process is deaf by construction (see
[osc-port-contention.md](osc-port-contention.md)). Two authenticated users would
be two people driving the same DAW through one shared mirror, with no notion of
whose track is whose.

Whatever "inviting other users" turns out to mean — one host with guest
observers, or per-user Ableton instances — that shape has to be decided before
#4 can be specced, because it determines whether auth guards *access* or
*identity*.

---

## Already in place

Not to be re-litigated when this queue is picked up:

- **Dev binds loopback** — [dev.exs:12](../config/dev.exs#L12).
- **`force_ssl` with HSTS is configured for prod** — [prod.exs:13-20](../config/prod.exs#L13-L20).
- **Prod refuses to boot without `SECRET_KEY_BASE`** — [runtime.exs:41-46](../config/runtime.exs#L41-L46).
  The checked-in dev/test secrets are public in git, which is fine *because* dev
  is loopback-only; that stops being true if #5 is ever loosened by hand.
- **LiveDashboard is dev-only** — gated on `dev_routes`, set solely in
  [dev.exs:59](../config/dev.exs#L59).
- **`Handlers` is the single dispatch point** for both entry modes, so an auth
  or validation layer has exactly one seam to cover rather than two.

## Deliberately not planned

- **Auth on the OSC layer itself.** OSC has no authentication story worth
  building on. If Seshat ever needs remote control, it goes behind the
  authenticated HTTP gateway (#4) with OSC staying loopback-only (#1, #3) — not
  a homegrown token in a UDP packet.
- **Sandboxing the Remote Script.** It runs inside Live's process by definition;
  there is nothing to sandbox it from.
- **Signing or verifying the catalog file.** `~/.seshat/catalog.json` is
  local-user data with the same trust level as the rest of the home directory.
