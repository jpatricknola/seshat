defmodule Seshat.Test.OSCSink do
  @moduledoc """
  A UDP socket standing in for AbletonOSC in tests.

  Binds the port `Seshat.OSC.Transport` sends to in `MIX_ENV=test`
  (`config :seshat, :osc_send_port`, 31000 — never AbletonOSC's 11000), so a
  test that starts Transport provably cannot reach a running Live.

  With `forward_to: pid` every datagram is decoded and delivered as
  `{:osc_out, address, args}`, which turns isolation from a claim into an
  assertion:

      start_supervised!({Seshat.Test.OSCSink, forward_to: self()})
      start_supervised!(Seshat.OSC.Transport)
      # ...
      assert_receive {:osc_out, "/live/track/set/panning", [0, -1.0]}

  Start the sink *before* Transport, so it is bound before the first datagram.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    port =
      Keyword.get_lazy(opts, :port, fn -> Application.fetch_env!(:seshat, :osc_send_port) end)

    case :gen_udp.open(port, [:binary, active: true]) do
      {:ok, socket} -> {:ok, %{socket: socket, forward_to: opts[:forward_to]}}
      {:error, reason} -> {:stop, reason}
    end
  end

  # Without a `:forward_to`, the sink exists only to absorb the datagram — don't
  # decode it, which would buy nothing and crash the sink on a malformed packet.
  @impl true
  def handle_info({:udp, _socket, _ip, _port, _data}, %{forward_to: nil} = state) do
    {:noreply, state}
  end

  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    {address, args} = Seshat.OSC.Message.decode(data)
    send(state.forward_to, {:osc_out, address, args})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_udp.close(socket)
  end
end
