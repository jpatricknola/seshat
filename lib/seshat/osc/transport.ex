defmodule Seshat.OSC.Transport do
  @moduledoc """
  GenServer that owns a UDP socket for bidirectional OSC communication with AbletonOSC.

  Binds to @client_port (11001) so AbletonOSC knows where to send responses and
  push notifications. Incoming messages are broadcast via Phoenix.PubSub so any
  process can react — notably Session.State for listener updates.

  All OSC traffic goes through here — nothing sends UDP directly.
  """

  use GenServer, restart: :permanent

  require Logger

  @host {127, 0, 0, 1}
  @ableton_port 11000
  @client_port 11001
  @pubsub Seshat.PubSub
  @topic "osc:in"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send an OSC message fire-and-forget. Returns :ok or {:error, reason}."
  @spec send_message(String.t(), list()) :: :ok | {:error, term()}
  def send_message(address, args) do
    GenServer.call(__MODULE__, {:send, address, args})
  end

  @doc "Send an OSC message and wait for a response matching the same address."
  @spec query(String.t(), list()) :: {:ok, {String.t(), list()}} | {:error, term()}
  def query(address, args) do
    GenServer.call(__MODULE__, {:query, address, args}, 5000)
  end

  @impl true
  def init(_opts) do
    case :gen_udp.open(@client_port, [:binary, active: true]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        Logger.info("OSC Transport listening on UDP port #{port}")
        {:ok, %{socket: socket, pending: nil}}

      {:error, :eaddrinuse} ->
        Logger.warning("Port #{@client_port} already in use, binding to ephemeral port")

        case :gen_udp.open(0, [:binary, active: true]) do
          {:ok, socket} ->
            {:ok, port} = :inet.port(socket)
            Logger.info("OSC Transport listening on UDP port #{port}")
            {:ok, %{socket: socket, pending: nil}}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, address, args}, _from, %{socket: socket} = state) do
    message = Seshat.OSC.Message.encode(address, args)
    result = :gen_udp.send(socket, @host, @ableton_port, message)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:query, address, args}, from, %{socket: socket} = state) do
    message = Seshat.OSC.Message.encode(address, args)

    case :gen_udp.send(socket, @host, @ableton_port, message) do
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
