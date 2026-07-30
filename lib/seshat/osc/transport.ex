defmodule Seshat.OSC.Transport do
  @moduledoc """
  GenServer that owns a UDP socket for bidirectional OSC communication with AbletonOSC.

  Both ports come from config — `config :seshat, :osc_send_port` (where messages
  go) and `:osc_reply_port` (what we bind) — defaulting to AbletonOSC's 11000 and
  11001. Binding the reply port is what tells AbletonOSC where to send responses
  and push notifications, since it replies to a fixed port rather than to the
  sender. Incoming messages are broadcast via Phoenix.PubSub so any process can
  react — notably Session.State for listener updates.

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
  @socket_opts [:binary, active: true, recbuf: 65_536, buffer: 65_536]

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

  On timeout the caller exits (standard `GenServer.call/3` behaviour) and its
  `from` is left behind in `pending`. Nothing needs cleaning up: the next query
  overwrites `pending`, and a late `GenServer.reply/2` to a caller that already
  gave up is a no-op.
  """
  @spec query(String.t(), list(), timeout()) :: {:ok, {String.t(), list()}} | {:error, term()}
  def query(address, args, timeout \\ 5000) do
    GenServer.call(__MODULE__, {:query, address, args}, timeout)
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
           pending: nil,
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
         %{socket: socket, pending: nil, deaf: true, send_port: send_port, reply_port: reply_port}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, address, args}, _from, %{socket: socket} = state) do
    message = Seshat.OSC.Message.encode(address, args)
    result = :gen_udp.send(socket, @host, state.send_port, message)
    {:reply, result, state}
  end

  # No reply can reach a deaf transport, so answer now rather than after the
  # caller's full timeout. Every caller already handles `{:error, reason}`.
  @impl true
  def handle_call({:query, _address, _args}, _from, %{deaf: true} = state) do
    {:reply, {:error, :reply_port_unavailable}, state}
  end

  def handle_call({:query, address, args}, from, %{socket: socket} = state) do
    message = Seshat.OSC.Message.encode(address, args)

    case :gen_udp.send(socket, @host, state.send_port, message) do
      :ok ->
        {:noreply, %{state | pending: {from, address}}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    {address, args} = Seshat.OSC.Message.decode(data)
    Logger.debug("OSC in: #{address} #{inspect(args)}")
    state = dispatch(address, args, state)
    {:noreply, state}
  end

  # Reply to a pending query if the response address matches, otherwise broadcast.
  defp dispatch(address, args, %{pending: {from, expected}} = state)
       when address == expected do
    GenServer.reply(from, {:ok, {address, args}})
    broadcast(address, args)
    %{state | pending: nil}
  end

  defp dispatch(address, args, state) do
    broadcast(address, args)
    state
  end

  defp broadcast(address, args) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:osc_message, address, args})
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_udp.close(socket)
  end
end
