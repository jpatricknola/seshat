# Implementation Plan: Harden the Elixir OSC listener and decoder

Roadmap #1 / [SECURITY_BACKLOG.md](SECURITY_BACKLOG.md) #3 — the last item of
the security backlog's "Fix now" section, and the only one entirely in `lib/`:
no fork commit, no `mix abletonosc.install`, no Live restart, and every piece
of it unit-testable without Ableton.

## Context

`Seshat.OSC.Transport` is the single UDP endpoint for everything Ableton says
to Seshat — query replies, listener pushes, `/live/startup`. Two independent
weaknesses live in that path, and they are two halves of one fix because they
guard the same datagram at the same seam:

1. **It listens to the world and believes anyone.**
   [transport.ex](../lib/seshat/osc/transport.ex) opens the reply port (11001)
   with no `ip:` option, so the socket binds the wildcard address, and
   `handle_info`/`dispatch/3` discard the sender's `ip` and `port` entirely —
   any datagram that arrives can satisfy a pending `query/3` caller or be
   broadcast on the `"osc:in"` PubSub topic, where `Session.State` writes it
   into the mirror the model plans against. The AbletonOSC fork's loopback
   bind (shipped 2026-07-30) closed the *command* direction; this closes the
   reply direction.

2. **One malformed datagram crashes the transport.**
   [message.ex](../lib/seshat/osc/message.ex) decodes with no error return:
   `find_null/2` recurses until `:binary.at/2` raises on a string with no
   null terminator, `binary_part/3` raises when padding runs past the end of
   the packet, `decode_arg/2` has no clause for type tags AbletonOSC doesn't
   send (`b`, `d`, `h`, …) and no clause for a truncated payload, and
   `decode/1` returns a bare tuple so there is no seam to catch any of it.
   The raise crashes `Transport` mid-`handle_info`, and any pending `query/3`
   caller is orphaned to its full timeout while the supervisor restarts the
   socket.

The crash half needs no attacker: a music machine is full of OSC-speaking
software (TouchOSC bridges, controller editors, other DAW tooling), and a
stray broadcast to 11001 is an ordinary accident. That is why this ranks
above the feature queue — the security framing is the smaller half of the
reason.

**Key constraint research settled:** the legitimate sender is fully
deterministic. The fork's `OSCServer` binds exactly one socket, to
`('127.0.0.1', 11000)` (`abletonosc/osc_server.py`, `__init__`), and every
reply and push — callback replies in `process_message`, listener pushes,
`/live/startup`, `/live/error` — goes out through `self._socket.sendto(...)`.
So every datagram Seshat should ever accept comes from source
`127.0.0.1:11000` — in config terms, `@host` and `state.send_port`. Source
validation can therefore check IP *and* port, not just IP.

Out of scope by prior decision (see [ROADMAP.md](ROADMAP.md) #3): the single
`pending` slot, reply correlation by address, and timed-out-caller cleanup.
This plan leaves query semantics untouched — after it, a garbled reply means
the caller times out instead of the transport crashing, and the queue work
remains its own item.

## The inbound contract

No new OSC addresses. The "contract" this plan is checkable against is the
shape of what AbletonOSC can put on the wire, verified in the fork's source
(`priv/AbletonOSC`, our canonical copy — not the installed Remote Script):

| Property | Value | Evidence |
|---|---|---|
| Source endpoint | `127.0.0.1:11000` (prod config; `@host`/`state.send_port` generally) | `osc_server.py` binds one socket to `local_addr` and all sends use `self._socket.sendto` |
| Packet kind | Single OSC messages, never bundles | `OSCServer.send` builds via `OscMessageBuilder`, which only produces messages |
| Address | Always starts with `/` | Every registered address; builder writes it verbatim |
| Type tags | Exactly `i`, `f`, `s`, `T`, `F`, `N` in practice | `OscMessageBuilder._get_arg_type` inference: str→`s`, int→`i`, float→`f`, bool→`T`/`F`, None→`N`. Handlers only return those Python types. Int overflow splits: `bit_length() == 32` (e.g. 2³¹ ≤ v < 2³²) is tagged `i` and dies in `write_int`'s `struct.pack('>i')` as `BuildError`, never reaching the wire; `bit_length()` 33–64 is tagged `h` and *would* go out via `write_int64` — no Live property returns values that large, and if one ever did, the strict decoder's drop-and-log is the designed backstop |
| String padding | Null terminator always present, padded to a 4-byte boundary with `\x00` | `osc_types.write_string` |
| Trailing bytes after the last argument | None | `build()` concatenates exactly address + tags + payloads |

Consequence: a **strict** decoder — reject unknown tags, non-zero padding,
trailing data, missing terminators — accepts everything AbletonOSC emits in
practice; the one theoretical exception (an int of magnitude ≥ 2³² tagged
`h`, see the table) is unreachable from Live's API and lands on drop-and-log
by design.
Dropping loudly is the designed behaviour, not a compatibility risk. In
particular the supported type-tag set deliberately stays exactly the current
`{i, f, s, T, F, N}`: decoding `d`/`h`/`b` would produce values no downstream
code was written against, from a sender that cannot be AbletonOSC.

## Parts

### 1. `Message.decode/1` returns tagged tuples and validates everything

File: [lib/seshat/osc/message.ex](../lib/seshat/osc/message.ex)

Change the spec from `binary() -> {String.t(), list()}` to:

```elixir
@spec decode(binary()) :: {:ok, {String.t(), list()}} | {:error, term()}
```

Rework the decode path (a `with` chain reads naturally here) so that every
malformed input returns `{:error, reason}` and nothing raises:

- `read_string/1` returns `{:ok, str, rest}` or an error. Find the null with
  `:binary.match/2` (no more hand-rolled `find_null/2` raising off the end);
  verify the padded length fits inside the binary; verify the padding bytes
  between the terminator and the 4-byte boundary are all zero.
- The address must be non-empty and start with `"/"` — this also rejects
  `#bundle` packets with a clear reason (AbletonOSC never sends bundles).
- The type-tag string must start with `","` (reject its absence — pythonosc
  always writes it).
- Each type tag decodes via clauses that *return* errors: keep the six
  supported tags, add a catch-all for unknown tags
  (`{:error, {:unsupported_type_tag, tag}}`) and handle payload exhaustion
  (`{:error, {:truncated_payload, tag}}`). Note the `"f"` clause's
  `<<val::big-float-32, ...>>` match also fails on NaN/±Infinity — that
  falls into an error return rather than a crash (see Open questions).
- After the last argument, the remaining binary must be empty:
  `{:error, {:trailing_data, byte_count}}` otherwise.

Exact error-reason atoms are the implementer's call — they exist to be
logged, nothing matches on them — but each distinct failure mode above gets a
distinguishable reason.

`encode/2` is unchanged: its inputs come from our own handler code, and
raising on a bad argument type is the correct behaviour there.

Update the moduledoc: it currently documents encoding only; state the decode
contract and that strictness is deliberate (the inbound contract above).

### 2. `Transport` binds loopback, validates the source, survives bad packets

File: [lib/seshat/osc/transport.ex](../lib/seshat/osc/transport.ex)

- **Bind:** add `ip: {127, 0, 0, 1}` to `@socket_opts` (use `@host`). Both
  open paths — the normal reply-port bind and `open_deaf/2`'s ephemeral
  bind — share `@socket_opts`, so both become loopback-only.
- **Source validation:** `handle_info({:udp, _socket, ip, port, data}, state)`
  accepts the datagram only when `ip == @host and port == state.send_port`
  (the deterministic sender established above; in `MIX_ENV=test` that is the
  OSCSink's 31000). Anything else is logged at `warning` — source and byte
  size only, not payload — and dropped: it must neither satisfy `pending`
  nor reach PubSub.
- **Decode failure:** on `{:error, reason}`, log at `warning` with the reason
  and a truncated preview of the bytes (e.g. `inspect/1` of the first 64),
  and drop. `Transport` state is untouched; a pending query simply waits out
  its timeout if the garbage claimed to be its reply.
- The happy path is unchanged: `Logger.debug`, `dispatch/3`, PubSub
  broadcast, pending-reply matching all stay as they are.
- Update the moduledoc: the "Binding the reply port" paragraph gains the
  loopback bind and the accepted-source rule, and states the drop-and-log
  policy for everything else.

### 3. Update `OSCSink` — the one other `decode/1` caller — and let tests send

File: [test/support/osc_sink.ex](../test/support/osc_sink.ex)

- Its `handle_info` matches the new shape:
  `{:ok, {address, args}} = Seshat.OSC.Message.decode(data)` — a crash on
  malformed bytes is correct in test support, where the input is our own
  encoder's output.
- Add a small helper (e.g. `send_datagram(pid, to_port, binary)`) that sends
  a raw binary from the sink's own socket. Because the sink is bound to the
  configured send port, this is the only way a test can emit a datagram whose
  *source port* matches what `Transport` now requires — it serves both roles:
  legitimate AbletonOSC stand-in (valid bytes) and malformed-input source
  (garbage bytes from the right endpoint). Raw binary on purpose, so tests
  can send byte sequences `encode/2` cannot produce.

### 4. Tests

Files: [test/seshat/osc/message_test.exs](../test/seshat/osc/message_test.exs),
[test/seshat/osc/transport_test.exs](../test/seshat/osc/transport_test.exs)

**`message_test.exs`** — update the three existing decode tests to the
`{:ok, ...}` shape, and add error cases, one per failure mode:

- empty binary; address with no null terminator; padding running past the
  end of the packet
- non-zero padding bytes inside a string's pad
- address not starting with `/` (including a `#bundle` header)
- packet ending after the address (no type-tag string)
- type-tag string not starting with `,`
- unsupported type tag (`b` is the realistic one — pythonosc would emit it
  for a bytes return)
- truncated payload (`i` with two bytes left)
- trailing bytes after the last decoded argument
- encode → corrupt one byte → decode returns `{:error, _}`, never raises

**`transport_test.exs`** — restructure so the current module-level setup
(which deliberately occupies the reply port to force deaf mode) moves into
the describes that need it; the isolation-config describe needs none of it.
Add a new describe where `Transport` binds its port for real, with the sink
(`forward_to` + the new send helper) and a PubSub subscription to `"osc:in"`:

- a valid datagram sent from the sink's socket is broadcast as
  `{:osc_message, address, args}` — the accepted-source happy path
- a malformed datagram from the sink's socket is dropped with a logged
  warning, and a valid datagram sent *afterwards* still arrives — proving
  the transport survived (ordering via the same source socket; assert the
  second broadcast rather than sleeping)
- a valid datagram from a *different* local socket (ephemeral source port)
  is never broadcast (`refute_receive`) — source-port validation
- wrong source *IP* is untestable from a loopback-bound test socket; the
  kernel-level `ip:` bind covers that direction and is asserted only
  indirectly (see Testing)

Known accepted risk: the new describe needs the configured reply port
actually free, so a *concurrent* `mix test` run on the same machine could
force deaf mode and fail it. The existing file already documents that
scenario for the deaf tests; one committer, one machine — acceptable.

### 5. Mark SECURITY_BACKLOG #3 resolved

File: [docs/SECURITY_BACKLOG.md](SECURITY_BACKLOG.md)

When the code lands, add the same style of "Resolved" banner #1 and #2
carry — dated, naming `@socket_opts`' loopback bind, the source check in
`handle_info`, and `Message.decode/1`'s tagged-tuple contract — and update
the doc's intro lines that currently describe #3 as open ("remains open and
is reachable from any local process today"). The ROADMAP entry itself is
removed by `/ship`, not here.

## Testing

Covered pure (no Ableton, all in `mix test`):

- every decoder failure mode, plus round-trip of everything `encode/2`
  produces (part 4)
- transport survival across a malformed datagram, source-port rejection,
  and the accepted-source broadcast path — all through the real UDP socket
  against `Seshat.Test.OSCSink`, never through `Transport.query/3`
- deaf-mode behaviour, unchanged, still covered by the existing tests

Needs the `/smoke-test` checklist with Ableton open (behavioural, not
address-level — no new addresses):

- ⚠️ a normal session pass (state refresh, browser search with a large reply,
  `get_clip_slots`-style `track_data` replies carrying `N` tags, a listener
  push from renaming a track in Live, and a Live restart for
  `/live/startup`) produces **zero** dropped-datagram warnings in the server
  log — the end-to-end proof that the strict decoder and the source check
  accept every real AbletonOSC reply shape. The inbound-contract table says
  they must; only live traffic closes the loop.

`mix precommit` green before declaring done.

## Out of scope

- **Query serialization, late-reply discard, timed-out-caller cleanup** —
  ROADMAP #3, deliberately separate; its planner notes already rule the
  design. Nothing here changes `pending` semantics.
- **Fabricated session-state defaults on failed refresh** — ROADMAP #2.
- **Decoding type tags AbletonOSC cannot emit** (`d`, `h`, `b`, arrays,
  bundles) — rejected above with reasoning; revisit only if an upstream
  merge changes what the builder can produce.
- **Any change to `encode/2`** — its callers are our own code.
- **HTTP-side auth, binding, rate limiting** — deployment-gated, per
  [SECURITY_BACKLOG.md](SECURITY_BACKLOG.md); the gate has not fired.
- **Auth on the OSC layer itself** — "Deliberately not planned" in the
  security backlog; loopback + source check is the whole design.

## Open questions

1. ⚠️ **Does live traffic ever violate the strict decoder?** Resolved as far
   as source reading can: pythonosc's builder provably emits spec-compliant
   padding, single messages, and only the six supported tags (the
   inbound-contract table). What cannot be verified without Ableton is the
   absence of surprises end to end — hence the zero-warnings smoke item
   above. Assumption until then: strict is safe. If a warning ever fires on
   legitimate traffic, the log line carries the reason and byte preview
   needed to loosen exactly the failed check.
2. ⚠️ **NaN/±Infinity float payloads.** `<<_::big-float-32>>` cannot match
   them, so a packet carrying one is dropped whole (logged), where today it
   crashes the transport. Whether Live can ever push a NaN parameter value
   is unknowable from source and not worth pre-building for. Assumption:
   drop-and-log is acceptable; revisit (per-arg `nil`?) only if the warning
   is ever observed in practice.
