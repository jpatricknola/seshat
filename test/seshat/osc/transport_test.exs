defmodule Seshat.OSC.TransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Seshat.OSC.Transport

  @client_port 11001

  # The one query test that needs no live Ableton: AbletonOSC replies to a fixed
  # port, so when something else already holds it — a second Seshat instance,
  # typically — Transport can send but never hear back, and says so immediately
  # instead of waiting out a timeout for a reply another process is receiving.
  #
  # The port only has to be occupied, by this socket or by an instance already
  # running on the machine, which is why binding it is allowed to fail.
  setup do
    case :gen_udp.open(@client_port, [:binary, active: false]) do
      {:ok, socket} -> on_exit(fn -> :gen_udp.close(socket) end)
      {:error, :eaddrinuse} -> :ok
    end

    log = capture_log(fn -> start_supervised!(Transport) end)

    {:ok, log: log}
  end

  describe "when the OSC reply port belongs to another process" do
    test "it says so loudly at startup", %{log: log} do
      assert log =~ "already bound by another process"
      assert log =~ "#{@client_port}"
    end

    test "queries fail immediately rather than stalling on a reply that cannot arrive" do
      # A short timeout on purpose: were this to go back to waiting, the call
      # would exit here instead of quietly passing five seconds later.
      assert Transport.query("/live/song/get/tempo", [], 200) ==
               {:error, :reply_port_unavailable}
    end

    test "sends still go out" do
      # Deliberately not a real /live/ address — the suite must not move
      # anything in an Ableton that happens to be running on this machine.
      assert Transport.send_message("/seshat/test/ping", []) == :ok
    end
  end
end
