defmodule Seshat.OSC.TransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Seshat.OSC.Transport

  # The reply port Transport binds in this env — never AbletonOSC's 11001.
  # `compile_env!/2` rather than `fetch_env!/2` because this is a module
  # attribute: a runtime config read in a module body is a warning, and
  # `mix precommit` compiles with --warnings-as-errors in :test.
  @reply_port Application.compile_env!(:seshat, :osc_reply_port)

  # The one query test that needs no live Ableton: AbletonOSC replies to a fixed
  # port, so when something else already holds it — a second Seshat instance,
  # typically — Transport can send but never hear back, and says so immediately
  # instead of waiting out a timeout for a reply another process is receiving.
  #
  # The port only has to be occupied, by this socket or by a concurrent `mix
  # test` on the machine, which is why binding it is allowed to fail.
  #
  # Load-bearing for the isolation, not just for the port-contention message:
  # a Transport still binding 11001 fails here either way — free, it never goes
  # deaf and both tests below break; held, it goes deaf but logs 11001 instead
  # of the configured port.
  setup do
    case :gen_udp.open(@reply_port, [:binary, active: false]) do
      {:ok, socket} -> on_exit(fn -> :gen_udp.close(socket) end)
      {:error, :eaddrinuse} -> :ok
    end

    # The sink absorbs the send below, so nothing goes at whatever holds 11000.
    start_supervised!({Seshat.Test.OSCSink, forward_to: self()})

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
end
