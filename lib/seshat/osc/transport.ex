defmodule Seshat.OSC.Transport do
  @moduledoc """
  GenServer that owns a UDP socket for bidirectional OSC communication with AbletonOSC.

  Both ports come from config — `config :seshat, :osc_send_port` (where messages
  go) and `:osc_reply_port` (what we bind) — defaulting to AbletonOSC's 11000 and
  11001. Binding the reply port is what tells AbletonOSC where to send responses
  and push notifications, since it replies to a fixed port rather than to the
  sender. The socket binds `127.0.0.1` explicitly, not the wildcard address:
  every OSC address controls Live and nothing on the wire authenticates
  anything, so a datagram from off the machine must not be receivable in the
  first place.

  On top of that bind, an accepted datagram must come from the one endpoint
  AbletonOSC can send from. The fork binds a single socket to
  `127.0.0.1:<send_port>` and pushes every reply, listener update and
  `/live/startup` through it, so the legitimate source is exactly
  `@host:send_port`. Anything else — and anything that fails
  `Seshat.OSC.Message.decode/1` — is logged at `warning` and dropped: it never
  satisfies the in-flight query and never reaches PubSub, where `Session.State`
  would write it into the mirror the model plans against.

  Incoming messages that survive both checks are broadcast via Phoenix.PubSub so
  any process can react — notably Session.State for listener updates.

  ## Query serialization

  Exactly one query is in flight at a time; the rest wait in a FIFO queue, and
  a reply is matched against the in-flight request's address only. That removes
  the collision where two overlapping queries overwrote a single slot and one
  caller got the other's data. It does not remove every collision, because
  correlation is still by address alone — there is no request id on the wire and
  none is coming: adding one means a wire-format divergence on every address,
  carried against upstream forever, to solve what this queue already solves.
  That was settled when the queue was built; do not resurrect it. Three residual
  classes remain:

  1. **A straggler on the in-flight address answers the wrong query.** Query A
     on address X times out; its reply is still in transit when the queue
     advances to query B on the same X with different arguments. B's caller
     receives it, because by construction it is indistinguishable from B's own
     fresh reply. Narrower than the old overwrite — it needs a timeout *and*
     address adjacency *and* a straggler landing in the window — but real.
  2. **Listener pushes share the getter's address.** A push on
     `/live/track/get/volume` can satisfy an in-flight query for the same
     property. No queue can remove that.
  3. **A structured `/live/error` delayed past a timeout fails the next
     identical request.** Same shape as class 1, and strictly safer: the caller
     gets a refusal it can retry rather than wrong data that looks right. It
     needs the same conjunction — a timeout, address adjacency, *and* identical
     arguments, since correlation here is by address **and** every argument.

  The remaining defense against all three is caller-side: the echo checks in
  `Seshat.Tools.Handlers.correlate_reply/2` — which every correlated read in
  `Handlers` rides via its `query_correlated/4` wrapper — plus
  `Seshat.Commands.Registry.ensure_clip/4` and `Seshat.Session.State`'s query
  helpers compare the values a reply echoes against the ones asked for, and refuse
  a mismatch. Keep them. A reply with nothing to echo (an index-free song
  property, `track_data`) has no caller-side defence available at all; each such
  site says so where it is written.

  A reply whose address does *not* match the in-flight request is broadcast and
  answers nobody — not suppressed, because the mirror turns those into free
  freshness. The one exception is `/live/error`, below.

  ## Batched queries

  `query_batch/2` puts several *reads* on the wire back-to-back and waits for
  all of them. It exists because the round trip's cost is AbletonOSC's
  scheduling quantum, not the datagram: `manager.py` schedules `tick()` once
  per 100ms, and each tick's `osc_server.process()` drains everything already
  queued on the socket and answers it inline. Measured 2026-08-04 against Live
  12 (recorded in `priv/AbletonOSC/API.md`): a serialized query costs one
  tick each, a burst of 63 costs *one tick between them*, and the fork's bulk
  endpoints cost exactly the same one tick a burst does. So a group of reads
  that has to be serialized here pays 100ms per member for nothing.

  A batch is **one entry in the same FIFO queue** — it holds `in_flight` the
  way a single query does, with one absolute deadline and one timer, and every
  rule around it (dropped-if-expired at enqueue and at dequeue, deaf transport
  answering `{:error, :reply_port_unavailable}` at once) is unchanged. What
  differs is only what goes on the wire at dequeue and what has to arrive
  before the caller is released.

  Correlation is per entry, and it is stronger than the single-query path: a
  reply resolves the first *unresolved* entry whose address matches **and**
  whose request arguments the reply echoes back as a prefix. That is the same
  check `Seshat.Tools.Handlers.correlate_reply/2` performs caller-side, moved
  in here because a batch's callers can no longer do it themselves — several
  entries may share an address, and the echoed index is the only thing telling
  their replies apart. The two hazard classes above survive, neither worse:

  - an identical-address, identical-argument straggler is accepted (class 1,
    unchanged — it is indistinguishable from the entry's own reply);
  - a listener push on a batched getter's address whose index prefix matches is
    accepted (class 2, unchanged).

  A straggler with *different* arguments is strictly better off here than on
  the serial path: it matches no entry, so it consumes nothing and forces no
  reissue, where serially it would have answered the query outright.

  **Reads only.** A batch can reach its deadline with every datagram already
  sent, which is harmless exactly when nothing in it mutates. Batching a setter
  is forbidden; sequencing around a mutation is what the ordered single queries
  are for.

  ## Failed-query correlation

  A callback that raises inside AbletonOSC sends no reply at all, so without
  help the query pays a full timeout to learn what Live already announced. The
  fork therefore sends the failing request back with the error (see
  `priv/AbletonOSC/SESHAT.md`):

      /live/error ["request", address, message, arg_count, ...request_args]
      /live/error ["log", message]

  Only the first shape is correlatable, and only against the in-flight request
  whose address **and** every argument it echoes match. Matching releases the
  caller with `{:error, {:live_error, message}}` and advances the queue at once,
  exactly as a real reply would. Everything else — a `"log"` payload, a legacy
  one-string payload, a mismatch of address, arity or arguments, or any
  `/live/error` with nothing in flight — is broadcast and answers nobody, i.e.
  today's behaviour. Strictness is deliberate: a false negative costs a timeout,
  which is what happens today anyway, while a false positive fails the wrong
  caller's query.

  All knowledge of `/live/error`'s payload lives in this module. Callers see
  only `{:error, {:live_error, message}}`, and `describe_error/1` renders it.

  **Never send an OSC wildcard through `query/3`.** The reason is response
  cardinality, not error handling. AbletonOSC fans a `*` pattern out across
  every registered address it matches and replies once per match on each
  *concrete* address; `query/3` waits on exactly one reply, on the one address
  it sent. So even a wildcard that succeeds completely is already broken here —
  no reply carries the address being waited on, every one of them falls through
  to broadcast, and the query pays a full timeout having discarded all N
  answers. That was true before any of this module's error correlation existed.

  The one thing correlation changes is the failure's shape. A structured error
  from any single match carries the *pattern* back in its address slot, which
  does match, so the clause above fails the query on the first bad endpoint
  rather than timing out — a wrong-looking error instead of a slow one. Louder
  is better than silent, but neither is usable. `query_batch/2` is the way to
  read several properties in one tick: same single AbletonOSC tick a wildcard
  would have cost, and each reply correlated to its own entry.

  `MIX_ENV=test` uses port `0` as a safe fallback and injects OS-assigned
  ephemeral ports into each supervised Transport, so concurrent test BEAMs
  cannot collide and the suite cannot reach a running Ableton.

  All OSC traffic goes through here — nothing sends UDP directly.
  """

  use GenServer, restart: :permanent

  require Logger

  @host {127, 0, 0, 1}
  @default_send_port 11000
  @default_reply_port 11001
  @pubsub Seshat.PubSub
  @topic "osc:in"

  # 64KB buffers: a /live/browser/get/items reply carrying 100 name/path/uri
  # triples can exceed the ~8KB default, and a datagram bigger than the buffer
  # is silently truncated — which surfaces as a mystery query timeout.
  #
  # `ip: @host` binds loopback rather than the wildcard address, so nothing off
  # this machine can reach the listener at all. Both open paths share these
  # options, so `open_deaf/2`'s ephemeral socket is loopback-only too.
  @socket_opts [:binary, active: true, ip: @host, recbuf: 65_536, buffer: 65_536]

  # One above the largest burst measured to survive a single AbletonOSC tick
  # intact (63 datagrams, zero drops, 14.2ms in-tick spread — 2026-08-04). The
  # cap is not where the wire breaks; it is where the evidence stops. Both
  # socket directions carry 64KB buffers against ~40-byte requests and ~60-byte
  # replies, so there is room above this — measure before raising it.
  @max_batch_entries 64

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send an OSC message fire-and-forget. Returns :ok or {:error, reason}."
  @spec send_message(String.t(), list()) :: :ok | {:error, term()}
  def send_message(address, args) do
    GenServer.call(__MODULE__, {:send, address, args})
  end

  @doc """
  Send an OSC message and wait for a response matching the same address.

  `timeout` is per call because how long a reply takes varies wildly: reading a
  track property is instant, while walking Live's device browser for the first
  time can take many seconds. Defaults to 5s.

  Queries are **serialized**: one is in flight at a time and the rest wait in a
  FIFO queue, so a reply can only ever be handed to the request it is in flight
  for. `timeout` bounds the caller's *total* wait — queue time plus flight time
  — and is carried to the server as an absolute monotonic deadline. The caller
  sends with `:gen_server.send_request/2`, then waits only for the time remaining
  until that same deadline; Transport arms its timer at the absolute deadline
  directly. Scheduler delay before either side starts waiting therefore spends
  the same budget instead of creating two relative timers that cannot be
  ordered.

  An expired request is **never sent**. It is dropped at enqueue if its deadline
  has already passed by the time the server handles the call, removed from the
  queue by its own timer, or dropped at dequeue — whichever comes first.

  On timeout the caller exits with the same reason shape as
  `GenServer.call/3`; the transport never returns `{:error, :timeout}`. Its
  internal timer exists solely to reclaim the entry and free the pipeline,
  never to reply — the ~20 `catch :exit` sites across `Handlers`, `Registry`,
  `Catalog` and `Session.State` are written against exits.

  `:infinity` is deliberately not in the contract: an entry with no deadline
  whose caller has died would block the head of the queue forever.

  A reply whose address does not match the in-flight request is broadcast
  without answering anyone. That is not the same as "late replies never reach a
  caller" — see the module's "Query serialization" section for the three residual
  collision classes that survive.
  """
  @spec query(String.t(), list(), non_neg_integer()) ::
          {:ok, {String.t(), list()}} | {:error, term()}
  def query(address, args, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    request = {:query, address, args, deadline}
    request_id = :gen_server.send_request(__MODULE__, request)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_server.receive_response(request_id, remaining) do
      {:reply, reply} ->
        reply

      {:error, {reason, server_ref}} ->
        exit({reason, {GenServer, :call, [server_ref, request, timeout]}})

      :timeout ->
        exit({:timeout, {GenServer, :call, [__MODULE__, request, timeout]}})
    end
  end

  @doc """
  Send several read requests back-to-back and wait for all of their replies.

  `entries` is a list of `{address, args}` in the order the results come back:
  the reply is `{:ok, results}` with one result per entry, positionally. Each
  result is `{:ok, tail}` — the reply's arguments *after* the prefix it echoed
  back — or `{:error, {:live_error, message}}` when the fork's structured
  `/live/error` named that exact request.

  Every entry is matched by address **and** echoed-argument prefix, so entries
  sharing an address (a send level per return, a property per clip) are told
  apart by the index they echo. See the module's "Batched queries" section for
  why this beats N serialized queries by ~100ms each and what it does not fix.

  `timeout` bounds the caller's total wait — queue time plus flight time — as
  an absolute deadline, exactly as `query/3` does. **On the deadline the server
  never replies and the caller exits**, the same shape `query/3` produces, so
  the `catch :exit` sites already written against it need no second form.
  Partial results are deliberately not delivered: at one tick per batch, "some
  answered" means Live stopped mid-tick, which is not a state any caller can
  report more precisely than its existing timeout wording does.

  `:gen_udp.send/4` failing part-way through the burst fails the whole batch
  with `{:error, reason}`. That is safe only because the contract is
  reads-only — the entries already on the wire changed nothing.

  Raises `ArgumentError` — programmer error, the same class as a typo'd
  address — on an empty batch, more than #{@max_batch_entries} entries, two
  entries with the same address and arguments, or two entries on one address
  where one's arguments are a prefix of the other's, which no reply could
  disambiguate.
  """
  @spec query_batch([{String.t(), list()}], non_neg_integer()) ::
          {:ok, [{:ok, list()} | {:error, {:live_error, String.t()}}]} | {:error, term()}
  def query_batch(entries, timeout \\ 5000) do
    validate_batch!(entries)

    deadline = System.monotonic_time(:millisecond) + timeout
    request = {:query_batch, entries, deadline}
    request_id = :gen_server.send_request(__MODULE__, request)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_server.receive_response(request_id, remaining) do
      {:reply, reply} ->
        reply

      {:error, {reason, server_ref}} ->
        exit({reason, {GenServer, :call, [server_ref, request, timeout]}})

      :timeout ->
        exit({:timeout, {GenServer, :call, [__MODULE__, request, timeout]}})
    end
  end

  # Ambiguity is checked in the caller's process, before anything reaches the
  # wire: a batch whose replies could resolve the wrong entry is a bug in the
  # call site, and it must fail where that call site is on the stack rather
  # than a tick later as a mismatched result.
  defp validate_batch!([]) do
    raise ArgumentError, "query_batch/2 needs at least one entry"
  end

  defp validate_batch!(entries) when length(entries) > @max_batch_entries do
    raise ArgumentError,
          "query_batch/2 accepts at most #{@max_batch_entries} entries, got #{length(entries)}. " <>
            "The largest burst measured against AbletonOSC answered 63 in one tick; beyond " <>
            "that nothing is known, so split the read."
  end

  defp validate_batch!(entries) do
    Enum.each(entries, fn
      {address, args} when is_binary(address) and is_list(args) ->
        :ok

      other ->
        raise ArgumentError, "query_batch/2 entries are {address, args}, got #{inspect(other)}"
    end)

    duplicates = entries -- Enum.uniq(entries)

    if duplicates != [] do
      raise ArgumentError,
            "query_batch/2 entries must be distinct — #{inspect(hd(duplicates))} appears twice, " <>
              "and one reply cannot resolve two identical entries"
    end

    Enum.each(entries, fn {address, args} ->
      Enum.each(entries -- [{address, args}], fn {other_address, other_args} ->
        if other_address == address and echo_prefix?(other_args, args) do
          raise ArgumentError,
                "query_batch/2 cannot tell #{address} #{inspect(args)} from " <>
                  "#{address} #{inspect(other_args)} — the first echoes a prefix of the second, " <>
                  "so a reply matches both"
        end
      end)
    end)
  end

  @doc """
  Render a `query/3` error reason as a sentence for a tool result.

  `{:live_error, message}` is this module's own term — Live rejected the request
  and said why — so its human rendering lives beside it rather than being taught
  to every caller separately. Every other reason keeps the `inspect/1` rendering
  callers used before, so this is a drop-in replacement for `inspect(reason)` at
  any query error site.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:live_error, message}), do: "Ableton rejected the request: #{message}"
  def describe_error(reason), do: inspect(reason)

  # Both ports are resolved once, here, and carried in state: a config change
  # mid-run must not split a running transport's behaviour across two ports.
  # Explicit options are primarily test seams; production starts with no opts
  # and therefore keeps the configured AbletonOSC ports.
  @impl true
  def init(opts) do
    send_port = Keyword.get_lazy(opts, :send_port, &send_port/0)
    reply_port = Keyword.get_lazy(opts, :reply_port, &reply_port/0)

    case :gen_udp.open(reply_port, @socket_opts) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        Logger.info("OSC Transport listening on UDP port #{port}")

        {:ok,
         %{
           socket: socket,
           in_flight: nil,
           queue: :queue.new(),
           deaf: false,
           send_port: send_port,
           reply_port: port
         }}

      {:error, :eaddrinuse} ->
        open_deaf(send_port, reply_port)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp send_port, do: Application.get_env(:seshat, :osc_send_port, @default_send_port)
  defp reply_port, do: Application.get_env(:seshat, :osc_reply_port, @default_reply_port)

  # AbletonOSC replies to a fixed port rather than to the sender, so a socket
  # bound anywhere but the reply port can send and never hear back — whoever
  # holds it receives our replies. Binding an ephemeral port keeps
  # fire-and-forget setters working, and `deaf: true` makes every query fail
  # immediately instead of stalling a full timeout on a reply that is being
  # delivered elsewhere.
  defp open_deaf(send_port, reply_port) do
    case :gen_udp.open(0, @socket_opts) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)

        Logger.error("""
        OSC reply port #{reply_port} is already bound by another process — \
        usually a second Seshat instance (`mix mcp` and `mix phx.server` \
        running at once).

        AbletonOSC sends every reply and listener update to #{reply_port}, so \
        this instance (bound to #{port}) will receive none of them. Reads will \
        fail fast and session state will not mirror Ableton; sets still go \
        through. Stop the other instance and restart for a working session.\
        """)

        {:ok,
         %{
           socket: socket,
           in_flight: nil,
           queue: :queue.new(),
           deaf: true,
           send_port: send_port,
           reply_port: reply_port
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Deliberately outside the query queue: fire-and-forget setters must not wait
  # behind a 30s device load. Ordering *within* a caller is preserved anyway
  # because callers are sequential — a guard's `query/3` has returned before its
  # `send_message/2` is issued — and cross-caller UDP interleaving is no
  # different from today's.
  @impl true
  def handle_call({:send, address, args}, _from, %{socket: socket} = state) do
    message = Seshat.OSC.Message.encode(address, args)
    result = :gen_udp.send(socket, @host, state.send_port, message)
    {:reply, result, state}
  end

  # No reply can reach a deaf transport, so answer now rather than after the
  # caller's full timeout. Every caller already handles `{:error, reason}`.
  # Ahead of the queue clause on purpose: a deaf query is never enqueued.
  @impl true
  def handle_call({:query, _address, _args, _deadline}, _from, %{deaf: true} = state) do
    {:reply, {:error, :reply_port_unavailable}, state}
  end

  def handle_call({:query_batch, _entries, _deadline}, _from, %{deaf: true} = state) do
    {:reply, {:error, :reply_port_unavailable}, state}
  end

  def handle_call({:query, address, args, deadline}, from, state) do
    enqueue(
      %{kind: :single, address: address, args: args},
      from,
      deadline,
      state
    )
  end

  # A batch occupies exactly one queue slot. `entries` carry their own result
  # once resolved; the caller is released when none is left `nil`.
  def handle_call({:query_batch, entries, deadline}, from, state) do
    entries =
      Enum.map(entries, fn {address, args} -> %{address: address, args: args, result: nil} end)

    enqueue(%{kind: :batch, entries: entries}, from, deadline, state)
  end

  defp enqueue(request, from, deadline, state) do
    now = System.monotonic_time(:millisecond)

    # A call can be handled after its own deadline whenever the server's mailbox
    # is backed up. Drop it here — unsent, unqueued and untimed — or the branch
    # below would put the datagram on the wire after the caller's budget was
    # spent. The caller waits against this same absolute deadline and exits
    # independently; nothing is owed a reply.
    if deadline <= now do
      {:noreply, state}
    else
      ref = make_ref()

      # Armed for the *remaining* time, so the server's timer tracks the
      # caller's deadline instead of restarting the clock: a request queued
      # behind a 30s browser export with a 5s timeout expires at 5s, unsent.
      timer = Process.send_after(self(), {:query_timeout, ref}, deadline, abs: true)

      request =
        Map.merge(request, %{ref: ref, from: from, deadline: deadline, timer: timer})

      case state.in_flight do
        nil ->
          case send_request(request, state) do
            :ok ->
              {:noreply, %{state | in_flight: request}}

            {:error, reason} ->
              Process.cancel_timer(timer)
              {:reply, {:error, reason}, state}
          end

        _in_flight ->
          {:noreply, %{state | queue: :queue.in(request, state.queue)}}
      end
    end
  end

  # The internal deadline never `GenServer.reply/2`s. The caller waits against
  # the same absolute deadline and produces the promised exit itself; all this
  # does is reclaim the entry and free the pipeline.
  @impl true
  def handle_info({:query_timeout, ref}, %{in_flight: %{ref: ref}} = state) do
    {:noreply, advance(%{state | in_flight: nil})}
  end

  def handle_info({:query_timeout, ref}, state) do
    # Either a queued entry expiring before it was ever sent — removed here, its
    # datagram never goes out — or the benign race where a reply cancelled the
    # timer after its message was already in the mailbox, in which case the
    # filter matches nothing and this is a no-op.
    {:noreply, %{state | queue: :queue.filter(&(&1.ref != ref), state.queue)}}
  end

  # AbletonOSC sends from exactly one socket, bound to `@host:send_port`, so any
  # other source is either another OSC-speaking program on the machine that
  # picked the wrong port or something deliberately feeding us state. Either way
  # it is dropped before it can answer a query or reach the mirror. The log line
  # carries the source and the size, never the payload.
  def handle_info({:udp, _socket, ip, port, data}, state)
      when ip != @host or port != :erlang.map_get(:send_port, state) do
    Logger.warning(
      "Dropped OSC datagram from unexpected source #{source(ip, port)} " <>
        "(#{byte_size(data)} bytes) — only #{source(@host, state.send_port)} is accepted"
    )

    {:noreply, state}
  end

  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    case Seshat.OSC.Message.decode(data) do
      {:ok, {address, args}} ->
        Logger.debug("OSC in: #{address} #{inspect(args)}")
        {:noreply, dispatch(address, args, state)}

      # Dropping is the whole recovery: state is untouched, and the in-flight
      # query whose reply this claimed to be waits out its deadline instead of
      # the transport crashing under it. The reason and byte preview are logged
      # so a check that ever fires on legitimate traffic can be loosened
      # precisely.
      {:error, reason} ->
        Logger.warning(
          "Dropped malformed OSC datagram (#{byte_size(data)} bytes): #{inspect(reason)} — " <>
            "first bytes #{inspect(binary_part(data, 0, min(byte_size(data), 64)))}"
        )

        {:noreply, state}
    end
  end

  defp source(ip, port), do: "#{:inet.ntoa(ip)}:#{port}"

  # Ahead of the address-match clause on purpose. Nothing ever queries
  # `/live/error`, so the two can't actually collide — ordering it first makes
  # that a non-question rather than a fact a reader has to establish.
  defp dispatch("/live/error" = address, args, %{in_flight: %{kind: :single} = request} = state) do
    case failed_request(args, request) do
      {:match, message} ->
        Process.cancel_timer(request.timer)
        GenServer.reply(request.from, {:error, {:live_error, message}})
        broadcast(address, args)
        advance(%{state | in_flight: nil})

      :no_match ->
        broadcast(address, args)
        state
    end
  end

  # Per entry, against the same address-and-every-argument test a single query
  # gets. A batch aimed at a vanished clip therefore fails fast in full: Live
  # raises once per request and every rejection lands in the same tick.
  defp dispatch("/live/error" = address, args, %{in_flight: %{kind: :batch} = request} = state) do
    resolved =
      resolve_entry(request, fn entry ->
        case failed_request(args, entry) do
          {:match, message} -> {:ok, {:error, {:live_error, message}}}
          :no_match -> :no_match
        end
      end)

    broadcast(address, args)
    settle(resolved, state)
  end

  # Answer the in-flight query if the response address matches, otherwise
  # broadcast only — today's handling of listener pushes and unsolicited
  # traffic, and the fate of every late reply that doesn't collide with the
  # in-flight address.
  #
  # No deadline check here, deliberately: the UDP datagram and deadline timer
  # are serialized through this process's mailbox. If the datagram is handled
  # first it is the request's answer; if the timer is handled first there is no
  # in-flight match left. A second wall-clock comparison here would override
  # that arrival ordering without making correlation any stronger.
  defp dispatch(
         address,
         args,
         %{in_flight: %{kind: :single, address: expected} = request} = state
       )
       when address == expected do
    # `false` means the `{:query_timeout, ref}` message is already in the
    # mailbox; the unmatched-ref clause of `handle_info/2` absorbs it.
    Process.cancel_timer(request.timer)
    GenServer.reply(request.from, {:ok, {address, args}})
    broadcast(address, args)
    advance(%{state | in_flight: nil})
  end

  # The batch's own correlation: same address *and* the request's arguments
  # echoed back as a prefix. That prefix is what tells two entries on one
  # address apart, and what makes a straggler carrying different indices match
  # nothing at all rather than answering the wrong entry.
  defp dispatch(address, args, %{in_flight: %{kind: :batch} = request} = state) do
    resolved =
      resolve_entry(request, fn entry ->
        if entry.address == address and echo_prefix?(args, entry.args),
          do: {:ok, {:ok, Enum.drop(args, length(entry.args))}},
          else: :no_match
      end)

    broadcast(address, args)
    settle(resolved, state)
  end

  defp dispatch(address, args, state) do
    broadcast(address, args)
    state
  end

  # First *unresolved* entry the matcher accepts, so a second reply for an
  # entry already answered falls through to the next one waiting on the same
  # address rather than overwriting a result.
  defp resolve_entry(request, matcher) do
    hit =
      request.entries
      |> Enum.with_index()
      |> Enum.find_value(fn {entry, index} ->
        with nil <- entry.result,
             {:ok, result} <- matcher.(entry) do
          {index, result}
        else
          _ -> nil
        end
      end)

    case hit do
      nil ->
        :no_match

      {index, result} ->
        entries = List.update_at(request.entries, index, &%{&1 | result: result})
        %{request | entries: entries}
    end
  end

  defp settle(:no_match, state), do: state

  defp settle(request, state) do
    if Enum.any?(request.entries, &is_nil(&1.result)) do
      %{state | in_flight: request}
    else
      Process.cancel_timer(request.timer)
      GenServer.reply(request.from, {:ok, Enum.map(request.entries, & &1.result)})
      advance(%{state | in_flight: nil})
    end
  end

  # What the batch requires of a reply, and deliberately looser than
  # `wire_args_match?/2` next door. That one compares a structured
  # `/live/error`'s verbatim echo of what Seshat put on the wire, so wire type
  # is part of the identity. This compares what *Live* reports back, and Live
  # normalises: a `1.0` index arrives as device 1 and is echoed as the integer
  # 1 (`Seshat.Tools.Handlers.correlate_reply/2` documents the same tolerance,
  # which is the check this replaces). Floats still get the 32-bit round trip,
  # since OSC `f` is 32-bit and an Elixir float is not.
  defp echo_prefix?(reply_args, sent) when length(reply_args) >= length(sent) do
    reply_args
    |> Enum.zip(sent)
    |> Enum.all?(fn {reply, asked} -> echo_arg_match?(reply, asked) end)
  end

  defp echo_prefix?(_reply_args, _sent), do: false

  defp echo_arg_match?(reply, asked) when is_number(reply) and is_number(asked),
    do: reply == asked or float32(reply / 1.0) == float32(asked / 1.0)

  defp echo_arg_match?(reply, asked), do: reply == asked

  # A structured `/live/error` belongs to the in-flight request only when it
  # names the same address and echoes back exactly the arguments that were sent.
  # `arg_count` is on the wire so the variable tail is explicit; disagreeing
  # with the tail's actual length means the payload is malformed, which is a
  # non-match rather than a guess.
  defp failed_request(["request", address, message, arg_count | echoed], %{
         address: address,
         args: sent
       })
       when is_binary(message) and is_integer(arg_count) and length(echoed) == arg_count do
    if wire_args_match?(echoed, sent), do: {:match, message}, else: :no_match
  end

  defp failed_request(_args, _request), do: :no_match

  defp wire_args_match?(echoed, sent) when length(echoed) == length(sent) do
    Enum.zip(echoed, sent) |> Enum.all?(fn {e, s} -> wire_arg_match?(e, s) end)
  end

  defp wire_args_match?(_echoed, _sent), do: false

  # Same value *and* same wire type. A float needs the 32-bit round-trip: OSC
  # `f` is 32-bit and an Elixir float is 64-bit, so `0.1` comes back as the
  # widening of its 32-bit truncation and plain `==` would call a real match a
  # mismatch. Anything else — an echoed boolean or nil, which Seshat never
  # sends, or an integer against a float — is a non-match by falling through.
  defp wire_arg_match?(echoed, sent) when is_integer(echoed) and is_integer(sent),
    do: echoed == sent

  defp wire_arg_match?(echoed, sent) when is_binary(echoed) and is_binary(sent),
    do: echoed == sent

  defp wire_arg_match?(echoed, sent) when is_float(echoed) and is_float(sent),
    do: echoed == float32(sent)

  defp wire_arg_match?(_echoed, _sent), do: false

  defp float32(value) do
    <<truncated::big-float-32>> = <<value::big-float-32>>
    truncated
  end

  # Pop the next request and put it on the wire. Invariant afterwards:
  # `in_flight == nil` implies the queue is empty.
  defp advance(state) do
    case :queue.out(state.queue) do
      {:empty, queue} ->
        %{state | in_flight: nil, queue: queue}

      {{:value, request}, queue} ->
        state = %{state | queue: queue}

        # This check, not the timer arithmetic at enqueue, is what makes "an
        # expired request is never sent" true: `{:query_timeout, ref}` can sit in
        # the mailbox behind the very datagram that completed the in-flight
        # query, so a popped entry can be expired with its timer message
        # unprocessed. One comparison keeps the documented contract honest.
        if request.deadline <= System.monotonic_time(:millisecond) do
          Process.cancel_timer(request.timer)
          advance(state)
        else
          case send_request(request, state) do
            :ok ->
              %{state | in_flight: request}

            {:error, reason} ->
              Process.cancel_timer(request.timer)
              GenServer.reply(request.from, {:error, reason})
              advance(state)
          end
        end
    end
  end

  defp send_request(%{kind: :single} = request, state) do
    send_datagram(request.address, request.args, state)
  end

  # Back-to-back, with nothing waited on between them: the whole point is that
  # they are all on AbletonOSC's socket before its next tick drains it. A
  # mid-burst send failure fails the batch outright — safe only because a batch
  # is reads-only, so the datagrams already out changed nothing.
  defp send_request(%{kind: :batch, entries: entries}, state) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case send_datagram(entry.address, entry.args, state) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp send_datagram(address, args, state) do
    message = Seshat.OSC.Message.encode(address, args)
    :gen_udp.send(state.socket, @host, state.send_port, message)
  end

  defp broadcast(address, args) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:osc_message, address, args})
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_udp.close(socket)
  end
end
