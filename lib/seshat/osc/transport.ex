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
  That was settled when the queue was built; do not resurrect it. Two residual
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

  The remaining defense against both is caller-side: the echo checks in
  `Seshat.Tools.Handlers.query_echoed/5`, `Seshat.Commands.Registry.ensure_clip/4`
  and `Seshat.Session.State`'s query helpers compare the indices a reply echoes
  against the ones asked for, and refuse a mismatch. Keep them.

  A reply whose address does *not* match the in-flight request is broadcast and
  answers nobody — not suppressed, because the mirror turns those into free
  freshness.

  `MIX_ENV=test` points both keys at throwaway ports (`config/test.exs`), so the
  suite cannot reach a running Ableton.

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
  caller" — see the module's "Query serialization" section for the two residual
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

  # Both ports are resolved once, here, and carried in state: a config change
  # mid-run must not split a running transport's behaviour across two ports.
  @impl true
  def init(_opts) do
    send_port = send_port()
    reply_port = reply_port()

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
           reply_port: reply_port
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
        usually a second Seshat instance (an MCP server and `mix phx.server` \
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

  def handle_call({:query, address, args, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    # A call can be handled after its own deadline whenever the server's mailbox
    # is backed up. Drop it here — unsent, unqueued and untimed — or the branch
    # below would put the datagram on the wire after the caller's budget was
    # spent. The caller waits against this same absolute deadline and exits
    # independently; nothing is owed a reply.
    if deadline <= now do
      {:noreply, state}
    else
      request = %{
        ref: make_ref(),
        from: from,
        address: address,
        args: args,
        deadline: deadline
      }

      # Armed for the *remaining* time, so the server's timer tracks the
      # caller's deadline instead of restarting the clock: a request queued
      # behind a 30s browser export with a 5s timeout expires at 5s, unsent.
      timer = Process.send_after(self(), {:query_timeout, request.ref}, deadline, abs: true)
      request = Map.put(request, :timer, timer)

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
  defp dispatch(address, args, %{in_flight: %{address: expected} = request} = state)
       when address == expected do
    # `false` means the `{:query_timeout, ref}` message is already in the
    # mailbox; the unmatched-ref clause of `handle_info/2` absorbs it.
    Process.cancel_timer(request.timer)
    GenServer.reply(request.from, {:ok, {address, args}})
    broadcast(address, args)
    advance(%{state | in_flight: nil})
  end

  defp dispatch(address, args, state) do
    broadcast(address, args)
    state
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

  defp send_request(request, state) do
    message = Seshat.OSC.Message.encode(request.address, request.args)
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
