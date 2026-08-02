defmodule Seshat.Test.OSCSink do
  @moduledoc """
  A UDP socket standing in for AbletonOSC in tests.

  By default, binds an OS-assigned ephemeral port and exposes it through
  `port/1`. Tests inject that port into `Seshat.OSC.Transport`, so concurrent
  test BEAMs never compete for a process-wide fixed port and no test can reach
  a running Live.

  With `forward_to: pid` every datagram is decoded and delivered as
  `{:osc_out, address, args}`, which turns isolation from a claim into an
  assertion:

      sink = start_supervised!({Seshat.Test.OSCSink, forward_to: self()})
      start_supervised!(
        {Seshat.OSC.Transport, send_port: Seshat.Test.OSCSink.port(sink), reply_port: 0}
      )
      # ...
      assert_receive {:osc_out, "/live/track/set/panning", [0, -1.0]}

  Start the sink *before* Transport, so it is bound before the first datagram.

  It also plays AbletonOSC in the other direction, via `send_datagram/3`. Since
  the sink holds the configured send port, its socket is the only source whose
  *port* satisfies the source check in `Seshat.OSC.Transport.handle_info/2` — so
  a test can stand in for a real reply, or for a malformed one, from an accepted
  endpoint.
  """

  use GenServer

  @host {127, 0, 0, 1}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send `binary` from the sink's socket to `to_port` on loopback.

  Raw binary on purpose: tests need byte sequences `Seshat.OSC.Message.encode/2`
  cannot produce.
  """
  @spec send_datagram(pid(), :inet.port_number(), binary()) :: :ok | {:error, term()}
  def send_datagram(pid, to_port, binary) do
    GenServer.call(pid, {:send_datagram, to_port, binary})
  end

  @doc "Return the UDP port this sink owns."
  @spec port(pid()) :: :inet.port_number()
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 0)

    case :gen_udp.open(port, [:binary, active: true]) do
      {:ok, socket} ->
        {:ok, actual_port} = :inet.port(socket)
        {:ok, %{socket: socket, port: actual_port, forward_to: opts[:forward_to]}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_call({:send_datagram, to_port, binary}, _from, state) do
    {:reply, :gen_udp.send(state.socket, @host, to_port, binary), state}
  end

  # Without a `:forward_to`, the sink exists only to absorb the datagram — don't
  # decode it, which would buy nothing and crash the sink on a malformed packet.
  @impl true
  def handle_info({:udp, _socket, _ip, _port, _data}, %{forward_to: nil} = state) do
    {:noreply, state}
  end

  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    # Matching `{:ok, _}` on purpose: this side only ever receives our own
    # encoder's output, so malformed bytes here mean a broken encoder and the
    # sink should fail loudly rather than swallow them.
    {:ok, {address, args}} = Seshat.OSC.Message.decode(data)
    send(state.forward_to, {:osc_out, address, args})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_udp.close(socket)
  end
end
