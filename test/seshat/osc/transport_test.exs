defmodule Seshat.OSC.TransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Seshat.OSC.Message
  alias Seshat.OSC.Transport
  alias Seshat.Test.OSCSink

  # The reply port Transport binds in this env — never AbletonOSC's 11001.
  # `compile_env!/2` rather than `fetch_env!/2` because this is a module
  # attribute: a runtime config read in a module body is a warning, and
  # `mix precommit` compiles with --warnings-as-errors in :test.
  @reply_port Application.compile_env!(:seshat, :osc_reply_port)

  # The deaf-mode setup: occupy the reply port so Transport cannot bind it.
  #
  # AbletonOSC replies to a fixed port, so when something else already holds it —
  # a second Seshat instance, typically — Transport can send but never hear back,
  # and says so immediately instead of waiting out a timeout for a reply another
  # process is receiving.
  #
  # The port only has to be occupied, by this socket or by a concurrent `mix
  # test` on the machine, which is why binding it is allowed to fail.
  #
  # Load-bearing for the isolation, not just for the port-contention message:
  # a Transport still binding 11001 fails here either way — free, it never goes
  # deaf and both tests below break; held, it goes deaf but logs 11001 instead
  # of the configured port.
  #
  # It lives in the describes that need it, not at module level: the
  # accepted-source tests below need Transport to bind the port for real.
  defp start_deaf(_context) do
    case :gen_udp.open(@reply_port, [:binary, active: false]) do
      {:ok, socket} -> on_exit(fn -> :gen_udp.close(socket) end)
      {:error, :eaddrinuse} -> :ok
    end

    # The sink absorbs the send below, so nothing goes at whatever holds 11000.
    start_supervised!({OSCSink, forward_to: self()})

    log = capture_log(fn -> start_supervised!(Transport) end)

    {:ok, log: log}
  end

  describe "test-environment isolation" do
    # `fetch_env!/2` on purpose: `get_env/2` would return nil for a deleted key,
    # and `nil not in [11000, 11001]` would let this pass while Transport fell
    # back to its production defaults and drove a real set. Exact equality also
    # catches a partial change — one port moved, the other left on Ableton's.
    test "the suite never targets AbletonOSC's ports" do
      assert Application.fetch_env!(:seshat, :osc_send_port) == 31000
      assert Application.fetch_env!(:seshat, :osc_reply_port) == 31001
    end
  end

  describe "when the OSC reply port belongs to another process" do
    setup :start_deaf

    test "it says so loudly at startup", %{log: log} do
      assert log =~ "already bound by another process"
      assert log =~ "#{@reply_port}"
    end

    test "queries fail immediately rather than stalling on a reply that cannot arrive" do
      # A short timeout on purpose: were this to go back to waiting, the call
      # would exit here instead of quietly passing five seconds later.
      assert Transport.query("/live/song/get/tempo", [], 200) ==
               {:error, :reply_port_unavailable}
    end

    test "sends still go out" do
      # Deliberately not a real /live/ address — belt and braces on top of the
      # test send port, so even a misconfigured run moves nothing in Ableton.
      assert Transport.send_message("/seshat/test/ping", []) == :ok
      assert_receive {:osc_out, "/seshat/test/ping", []}
    end
  end

  # Everything AbletonOSC says arrives here. The sink stands in for it: bound to
  # the configured send port, it is the only socket in the suite whose source
  # endpoint Transport accepts.
  #
  # Known accepted risk: these need the configured reply port actually free, so a
  # concurrent `mix test` on the same machine forces deaf mode and fails them.
  # One committer, one machine — acceptable.
  describe "receiving datagrams" do
    setup do
      sink = start_supervised!({OSCSink, forward_to: self()})
      start_supervised!(Transport)
      :ok = Phoenix.PubSub.subscribe(Seshat.PubSub, "osc:in")
      {:ok, sink: sink}
    end

    test "a well-formed datagram from AbletonOSC's endpoint is broadcast", %{sink: sink} do
      packet = Message.encode("/live/song/get/tempo", [120.0])
      assert :ok = OSCSink.send_datagram(sink, @reply_port, packet)

      assert_receive {:osc_message, "/live/song/get/tempo", [120.0]}
    end

    test "a malformed datagram is dropped and the transport survives it", %{sink: sink} do
      # No null terminator: the old decoder raised on this, taking Transport
      # down with it and orphaning any pending query to its full timeout.
      log =
        capture_log(fn ->
          assert :ok = OSCSink.send_datagram(sink, @reply_port, "/live/song/get/tempo")

          # Same source socket, so it is queued behind the garbage: receiving
          # this proves the transport processed both, with no sleeping.
          packet = Message.encode("/live/song/get/tempo", [120.0])
          assert :ok = OSCSink.send_datagram(sink, @reply_port, packet)

          assert_receive {:osc_message, "/live/song/get/tempo", [120.0]}
        end)

      assert log =~ "Dropped malformed OSC datagram"
      assert log =~ "unterminated_string"
    end

    test "a well-formed datagram from any other source port is dropped", %{sink: sink} do
      {:ok, foreign} = :gen_udp.open(0, [:binary, active: false])
      on_exit(fn -> :gen_udp.close(foreign) end)

      log =
        capture_log(fn ->
          spoofed = Message.encode("/live/song/get/tempo", [666.0])
          :ok = :gen_udp.send(foreign, {127, 0, 0, 1}, @reply_port, spoofed)

          # A datagram from the accepted endpoint, sent after it: its arrival is
          # the synchronisation point for asserting the spoof never arrived.
          legit = Message.encode("/live/song/get/tempo", [120.0])
          :ok = OSCSink.send_datagram(sink, @reply_port, legit)

          assert_receive {:osc_message, "/live/song/get/tempo", [120.0]}
        end)

      refute_received {:osc_message, "/live/song/get/tempo", [666.0]}
      assert log =~ "Dropped OSC datagram from unexpected source"
    end
  end
end
