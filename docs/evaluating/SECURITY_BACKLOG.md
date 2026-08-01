# Security backlog

Three open items. **All three are dormant** — they describe the HTTP surface,
which today binds loopback only and is reachable by nobody but this machine's
user. None of them is worth building until [the gate](#the-gate) fires, and
when it fires they all activate together.

**Scheduling lives in [ROADMAP.md](../ROADMAP.md), not here.** The gated items are
deliberately absent from that queue — putting them there would rank work that
cannot pay off yet against work that can. This doc holds the evidence, the
triggers, and the reasoning; the roadmap holds the order.

The one principle that keeps this honest: **exposure that already exists is not
a deployment concern.** Anything reachable *right now* belongs in ROADMAP.md as
ordinary work, not behind a gate. The gate is for surface that requires an act
of deployment to exist at all. When in doubt, ask whether an attacker could
reach it today; if yes, it is not gated.

## The gate

The queue below activates when **either** of these becomes true:

- **The HTTP endpoint binds beyond loopback** — `MIX_ENV=prod`, a tunnel, a
  reverse proxy, or `ip: {0,0,0,0}` in dev "just to test from my phone".
- **A second human gets an address to point a client at** — an invited user, a
  collaborator, a demo.

Either trigger activates **all** of the gated items, not the subset that looks
relevant. They compose: the missing auth is only reachable because of the
public bind, and rate limiting is meaningless without either. Shipping #4
alone past the gate leaves a working attack; shipping #5 alone leaves the
surface open to anyone already inside the network.

---

# The queue

Ranked by impact-per-effort, matching [ROADMAP.md](../ROADMAP.md)'s convention.
Numbering starts at #4 because #1–#3 were the pre-gate items, now
[resolved](#resolved) — the gap is deliberate, so that references in the
archived plans still point at what they meant.

## #4 · Nothing authenticates `/mcp` or the assistant UI

**Severity past the gate: critical.** This is the item the gate exists for.

**What's wrong:** [router.ex:13-33](../../lib/seshat_web/router.ex#L13-L33) puts
`live "/", AssistantLive` behind the plain `:browser` pipeline and forwards
`/mcp` to Anubis with no auth plug in front of either.
[no_auth_discovery.ex](../../lib/seshat_web/plugs/no_auth_discovery.ex) exists
specifically to tell probing MCP clients that there is no OAuth here — the
absence is deliberate and documented, which is correct for a loopback tool and
indefensible past the gate.

**Reachable consequences:** `/mcp` is the full destructive tool surface —
create, delete, rename, overwrite clips, load devices, transport. `/` is worse
per request: an anonymous visitor drives Live *and* spends the configured
Anthropic key.

**Fix:** a shared-secret bearer token checked in a plug ahead of both scopes is
enough for a first version — this is not a product with accounts. The MCP
spec's OAuth flow is the heavier option and probably premature.

**Blocked on:** [the multi-user decision](#the-non-security-blocker-in-the-same-gate)
below — it determines whether auth guards *access* or *identity*, which changes
the shape of the fix.

**Effort:** Medium.

## #5 · Production binds every interface, and starting that way is silent

**Severity past the gate: high** — and it is the most likely way the gate fires
*by accident*, since it needs no decision from anyone, just a first deploy.

**What's wrong:** [runtime.exs:52-61](../../config/runtime.exs#L52-L61) is the
untouched `phx.new` default — `ip: {0,0,0,0,0,0,0,0}`, all IPv6 interfaces,
generator comment still attached. Combined with #4 that is the whole tool
surface open to the network, and nothing warns.

**Why it is still dormant:** it applies only under `MIX_ENV=prod`, which this
project has never run. Dev binds loopback
([dev.exs:12](../../config/dev.exs#L12)).

**Fix:** default prod to loopback, and **refuse to boot** when a non-loopback
bind is configured without an auth secret present. Fail-closed is the point —
the failure mode being guarded against is someone deploying without reading
this file.

**Effort:** Low.

## #6 · No rate limiting or request-size caps

**Severity past the gate: medium.** Denial of service against a single-user
music tool, not data loss — but the expensive calls are unusually expensive.

**What's wrong:** nothing bounds request rate or body size on `/mcp` or the
LiveView. A single expensive call is enough to matter here: `reindex_library`
walks Live's whole browser on the UI thread and freezes it for up to a minute,
and `search_library` full-scans ETS per query.

**Fix:** body-size limit in the endpoint, and a per-token rate limit on `/mcp`.
Give the genuinely expensive tools (`reindex_library`, browser export) a
stricter bucket than the rest.

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
#4 can be specced.

---

## What belongs here, and what doesn't

**Correctness bugs with no security dimension do not belong here** — they live
in [ROADMAP.md](../ROADMAP.md), which ranks them alongside everything else. Several
are easy to mistake for security items because they touch the same files:

| Finding | Why it isn't a security item |
|---|---|
| Agent iteration limit discards executed commands | Correctness. |
| Unbounded LiveView conversation growth | A single local user can exhaust the context window on catalog output alone. |

The general shape: a bad value reaching a tool comes from **the model**, not an
attacker, so bounds and index validation are correctness work no matter how
much they read like input sanitisation.

## Already in place

Not to be re-litigated when this queue is picked up:

- **Dev binds loopback** — [dev.exs:12](../../config/dev.exs#L12).
- **`force_ssl` with HSTS is configured for prod** — [prod.exs:13-20](../../config/prod.exs#L13-L20).
- **Prod refuses to boot without `SECRET_KEY_BASE`** — [runtime.exs:41-46](../../config/runtime.exs#L41-L46).
  The checked-in dev/test secrets are public in git, which is fine *because* dev
  is loopback-only; that stops being true if #5 is ever loosened by hand.
- **LiveDashboard is dev-only** — gated on `dev_routes`, set solely in
  [dev.exs:59](../../config/dev.exs#L59).
- **`Handlers` is the single dispatch point** for both entry modes, so an auth
  or validation layer has exactly one seam to cover rather than two.
- **The OSC layer is loopback-only end to end** — see [Resolved](#resolved).

## Deliberately not planned

- **Auth on the OSC layer itself.** OSC has no authentication story worth
  building on. If Seshat ever needs remote control, it goes behind the
  authenticated HTTP gateway (#4) with OSC staying loopback-only — not a
  homegrown token in a UDP packet.
- **Sandboxing the Remote Script.** It runs inside Live's process by definition;
  there is nothing to sandbox it from.
- **Signing or verifying the catalog file.** `~/.seshat/catalog.json` is
  local-user data with the same trust level as the rest of the home directory.

---

## Resolved

Kept short on purpose — the reasoning lives in the archived plans linked on each
row. All three came from the 2026-07-29 external review, and all three were
reachable *before* any deployment, which is why they were never gated.

| # | Finding | Resolved | Where |
|---|---|---|---|
| #1 | AbletonOSC bound `0.0.0.0:11000` and retargeted its reply stream to whichever host last sent a datagram | 2026-07-30 | Fork: [osc_server.py](../../priv/AbletonOSC/abletonosc/osc_server.py) binds `127.0.0.1` and `process()` no longer reassigns `_remote_addr`. Plan: [PLAN_abletonosc_loopback_and_safe_exports.md](../archive/PLAN_abletonosc_loopback_and_safe_exports.md) |
| #2 | `/live/browser/export` opened any caller-supplied path with Live's privileges | 2026-07-30 | Fork: the address now takes no arguments and writes under `~/.seshat/browser-exports/`; `Catalog.validated_export_path/2` checks the returned path. Same plan as #1 |
| #3 | The Elixir listener bound the wildcard, trusted any source, and crashed on a malformed datagram | 2026-07-30 | [transport.ex](../../lib/seshat/osc/transport.ex) binds loopback and accepts datagrams only from the fork's endpoint; [message.ex](../../lib/seshat/osc/message.ex) is a strict non-crashing decoder. Plan: [PLAN_harden_osc_listener.md](../archive/PLAN_harden_osc_listener.md) |

Two of these carry ongoing cost worth remembering. #1 **changes** upstream
behaviour rather than extending it, so it will conflict on an AbletonOSC merge
— `vendored_addresses_test` greps for it because losing it would be completely
invisible. And if a networked OSC controller is ever genuinely wanted, the move
is to make the bind address a constant in the fork, never to revert to the
wildcard.
