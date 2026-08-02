defmodule Seshat.OSC.TransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Seshat.OSC.Message
  alias Seshat.OSC.Transport
  alias Seshat.Test.OSCSink

  defp start_transport(sink, opts \\ []) do
    opts = Keyword.merge([send_port: OSCSink.port(sink), reply_port: 0], opts)
    start_supervised!({Transport, opts})
  end

  defp transport_reply_port do
    :sys.get_state(Transport).reply_port
  end

  # The deaf-mode setup: occupy the reply port so Transport cannot bind it.
  #
  # AbletonOSC replies to a fixed port, so when something else already holds it —
  # a second Seshat instance, typically — Transport can send but never hear back,
  # and says so immediately instead of waiting out a timeout for a reply another
  # process is receiving.
  #
  # Load-bearing for the isolation, not just for the port-contention message:
  # a Transport still binding 11001 never goes deaf and both tests below break.
  #
  # It lives in the describes that need it, not at module level: the
  # accepted-source tests below need Transport to bind the port for real.
  defp start_deaf(_context) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, occupied_port} = :inet.port(socket)
    on_exit(fn -> :gen_udp.close(socket) end)

    # The sink absorbs the send below, so nothing goes at whatever holds 11000.
    sink = start_supervised!({OSCSink, forward_to: self()})

    log = capture_log(fn -> start_transport(sink, reply_port: occupied_port) end)

    {:ok, log: log, occupied_port: occupied_port}
  end

  describe "test-environment isolation" do
    # `fetch_env!/2` on purpose: `get_env/2` would return nil for a deleted key,
    # and `nil not in [11000, 11001]` would let this pass while Transport fell
    # back to its production defaults and drove a real set. Exact equality also
    # catches a partial change — one port moved, the other left on Ableton's.
    test "the suite never targets AbletonOSC's ports" do
      assert Application.fetch_env!(:seshat, :osc_send_port) == 0
      assert Application.fetch_env!(:seshat, :osc_reply_port) == 0
    end
  end

  describe "when the OSC reply port belongs to another process" do
    setup :start_deaf

    test "it says so loudly at startup", %{log: log, occupied_port: occupied_port} do
      assert log =~ "already bound by another process"
      assert log =~ "#{occupied_port}"
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
  describe "receiving datagrams" do
    setup do
      sink = start_supervised!({OSCSink, forward_to: self()})
      start_transport(sink)
      :ok = Phoenix.PubSub.subscribe(Seshat.PubSub, "osc:in")
      {:ok, sink: sink}
    end

    test "a well-formed datagram from AbletonOSC's endpoint is broadcast", %{sink: sink} do
      packet = Message.encode("/live/song/get/tempo", [120.0])
      assert :ok = OSCSink.send_datagram(sink, transport_reply_port(), packet)

      assert_receive {:osc_message, "/live/song/get/tempo", [120.0]}
    end

    test "a malformed datagram is dropped and the transport survives it", %{sink: sink} do
      # No null terminator: the old decoder raised on this, taking Transport
      # down with it and orphaning any pending query to its full timeout.
      log =
        capture_log(fn ->
          assert :ok =
                   OSCSink.send_datagram(sink, transport_reply_port(), "/live/song/get/tempo")

          # Same source socket, so it is queued behind the garbage: receiving
          # this proves the transport processed both, with no sleeping.
          packet = Message.encode("/live/song/get/tempo", [120.0])
          assert :ok = OSCSink.send_datagram(sink, transport_reply_port(), packet)

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
          :ok = :gen_udp.send(foreign, {127, 0, 0, 1}, transport_reply_port(), spoofed)

          # A datagram from the accepted endpoint, sent after it: its arrival is
          # the synchronisation point for asserting the spoof never arrived.
          legit = Message.encode("/live/song/get/tempo", [120.0])
          :ok = OSCSink.send_datagram(sink, transport_reply_port(), legit)

          assert_receive {:osc_message, "/live/song/get/tempo", [120.0]}
        end)

      refute_received {:osc_message, "/live/song/get/tempo", [666.0]}
      assert log =~ "Dropped OSC datagram from unexpected source"
    end
  end

  # The one place in the suite allowed to call `Transport.query/3` (see
  # .claude/rules/testing.md): the sink plays AbletonOSC and supplies the reply,
  # or the test is asserting the timeout path with a sub-second timeout. Nothing
  # here needs a live Ableton.
  #
  # Every synchronisation point is a message — `{:osc_out, ...}` from the sink
  # for "this datagram went out", the caller's `:DOWN` for "this query timed
  # out", `await_queue_depth/2` for "accepted but not yet sent". No sleeps.
  describe "query serialization" do
    setup do
      sink = start_supervised!({OSCSink, forward_to: self()})
      start_transport(sink)
      {:ok, sink: sink}
    end

    test "a second query is held until the first is answered", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 2000) end)
      assert_receive {:osc_out, "/live/song/get/tempo", []}

      b = Task.async(fn -> Transport.query("/live/song/get/num_tracks", [], 2000) end)
      await_queue_depth(1)
      refute_received {:osc_out, "/live/song/get/num_tracks", []}

      reply(sink, "/live/song/get/tempo", [120.0])
      assert {:ok, {"/live/song/get/tempo", [120.0]}} = Task.await(a)

      assert_receive {:osc_out, "/live/song/get/num_tracks", []}
      reply(sink, "/live/song/get/num_tracks", [4])
      assert {:ok, {"/live/song/get/num_tracks", [4]}} = Task.await(b)
    end

    # Depth 1 has no order to get wrong — with one entry queued, LIFO and FIFO
    # are indistinguishable. Two entries is the smallest queue that pins the
    # direction.
    test "queued requests are sent in the order they were accepted", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 2000) end)
      assert_receive {:osc_out, "/live/song/get/tempo", []}

      b = Task.async(fn -> Transport.query("/live/track/get/name", [1], 2000) end)
      await_queue_depth(1)

      c = Task.async(fn -> Transport.query("/live/track/get/name", [2], 2000) end)
      await_queue_depth(2)

      reply(sink, "/live/song/get/tempo", [120.0])
      assert {:ok, _} = Task.await(a)

      # The sink forwards in receive order, so C ahead of B would have put
      # `[2]` in the mailbox first and this refute would catch it.
      assert_receive {:osc_out, "/live/track/get/name", [1]}
      refute_received {:osc_out, "/live/track/get/name", [2]}

      reply(sink, "/live/track/get/name", [1, "Bass"])
      assert {:ok, {_, [1, "Bass"]}} = Task.await(b)

      assert_receive {:osc_out, "/live/track/get/name", [2]}
      reply(sink, "/live/track/get/name", [2, "Keys"])
      assert {:ok, {_, [2, "Keys"]}} = Task.await(c)
    end

    # `advance/1`'s "drop the expired head, then send the one behind it"
    # recursion, which only runs while the expired entry's `{:query_timeout, _}`
    # is still unprocessed — so the reply datagram has to reach the server's
    # mailbox *ahead* of that timer message, which is what suspending across
    # both arrivals stages. A machine slow enough to expire B before the suspend
    # still passes; it just takes the ordinary filter path instead.
    test "an expired queued request is skipped and the one behind it is sent", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 3000) end)
      assert_receive {:osc_out, "/live/song/get/tempo", []}

      {pid, ref} = spawn_query("/live/track/get/name", [3], 300)
      await_queue_depth(1)

      c = Task.async(fn -> Transport.query("/live/song/get/num_tracks", [], 3000) end)
      await_queue_depth(2)

      :sys.suspend(Transport)
      reply(sink, "/live/song/get/tempo", [120.0])
      assert_receive {:DOWN, ^ref, :process, ^pid, {:timeout, {GenServer, :call, _}}}, 1000
      :sys.resume(Transport)

      assert {:ok, _} = Task.await(a)
      assert_receive {:osc_out, "/live/song/get/num_tracks", []}
      refute_received {:osc_out, "/live/track/get/name", [3]}

      reply(sink, "/live/song/get/num_tracks", [4])
      assert {:ok, {_, [4]}} = Task.await(c)
    end

    # The headline defect, as a regression test. With a single `pending` slot the
    # second query overwrote the first, and whichever reply came back first was
    # handed to the wrong caller.
    test "two overlapping queries to the same address each get their own reply", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/track/get/name", [0], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [0]}

      b = Task.async(fn -> Transport.query("/live/track/get/name", [3], 2000) end)
      await_queue_depth(1)

      reply(sink, "/live/track/get/name", [0, "Drums"])
      assert {:ok, {_, [0, "Drums"]}} = Task.await(a)

      assert_receive {:osc_out, "/live/track/get/name", [3]}
      reply(sink, "/live/track/get/name", [3, "Bass"])
      assert {:ok, {_, [3, "Bass"]}} = Task.await(b)
    end

    test "a timed-out query frees the pipeline for the one behind it", %{sink: sink} do
      {pid, ref} = spawn_query("/live/song/get/tempo", [], 150)
      assert_receive {:osc_out, "/live/song/get/tempo", []}

      b = Task.async(fn -> Transport.query("/live/song/get/num_tracks", [], 2000) end)
      await_queue_depth(1)

      # The reason is load-bearing: `:normal` would mean the transport had
      # replied `{:error, :timeout}` and the caller returned instead of exiting,
      # which is the contract break the request wrapper must never cause.
      assert_receive {:DOWN, ^ref, :process, ^pid, {:timeout, {GenServer, :call, _}}}, 1000

      assert_receive {:osc_out, "/live/song/get/num_tracks", []}
      reply(sink, "/live/song/get/num_tracks", [4])
      assert {:ok, {_, [4]}} = Task.await(b)
    end

    test "a late reply on another address is broadcast, not delivered", %{sink: sink} do
      :ok = Phoenix.PubSub.subscribe(Seshat.PubSub, "osc:in")

      {pid, ref} = spawn_query("/live/track/get/name", [0], 150)
      assert_receive {:osc_out, "/live/track/get/name", [0]}
      assert_receive {:DOWN, ^ref, :process, ^pid, {:timeout, {GenServer, :call, _}}}, 1000

      b = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 2000) end)
      assert_receive {:osc_out, "/live/song/get/tempo", []}

      reply(sink, "/live/track/get/name", [0, "Drums"])
      assert_receive {:osc_message, "/live/track/get/name", [0, "Drums"]}

      reply(sink, "/live/song/get/tempo", [120.0])
      assert {:ok, {"/live/song/get/tempo", [120.0]}} = Task.await(b)
    end

    test "a queued request whose deadline passes is removed unsent", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/song/get/num_tracks", [], 3000) end)
      assert_receive {:osc_out, "/live/song/get/num_tracks", []}

      {pid, ref} = spawn_query("/live/track/get/name", [3], 150)
      await_queue_depth(1)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:timeout, {GenServer, :call, _}}}, 1000

      reply(sink, "/live/song/get/num_tracks", [4])
      assert {:ok, {_, [4]}} = Task.await(a)

      # The fence has to be another `:osc_out`, not A's reply: A's reply reaches
      # A's caller on a different channel than the sink's forwarding, so a
      # `refute_received` right after it could pass before a wrongly-sent
      # datagram had been forwarded. Transport would have sent B before C, and
      # the sink forwards in receive order, so C arriving without B proves B was
      # never sent.
      c = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 2000) end)
      assert_receive {:osc_out, "/live/song/get/tempo", []}
      refute_received {:osc_out, "/live/track/get/name", [3]}

      reply(sink, "/live/song/get/tempo", [120.0])
      assert {:ok, _} = Task.await(c)
    end

    test "sends bypass the queue", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 2000) end)
      assert_receive {:osc_out, "/live/song/get/tempo", []}

      assert Transport.send_message("/live/song/set/tempo", [124.0]) == :ok
      assert_receive {:osc_out, "/live/song/set/tempo", [124.0]}

      reply(sink, "/live/song/get/tempo", [120.0])
      assert {:ok, _} = Task.await(a)
    end

    # Characterisation, not aspiration: residual collision class 1 from the
    # moduledoc. A straggler on the *in-flight* address is indistinguishable
    # from that request's own fresh reply, so it is delivered. If a future
    # change makes this fail, update the moduledoc's residual-class paragraph —
    # it is not a bug report.
    test "a late reply on the in-flight address is delivered to the wrong query", %{sink: sink} do
      {pid, ref} = spawn_query("/live/track/get/name", [0], 150)
      assert_receive {:osc_out, "/live/track/get/name", [0]}
      assert_receive {:DOWN, ^ref, :process, ^pid, {:timeout, {GenServer, :call, _}}}, 1000

      b = Task.async(fn -> Transport.query("/live/track/get/name", [3], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [3]}

      reply(sink, "/live/track/get/name", [0, "Drums"])
      assert {:ok, {_, [0, "Drums"]}} = Task.await(b)
    end

    # The enqueue-path deadline check. Suspending the server is the one way to
    # stage a mailbox backlog on purpose: the call sits unhandled until after
    # its own deadline has passed.
    test "a request that expires before the server handles it is dropped unsent", %{sink: sink} do
      :sys.suspend(Transport)

      {pid, ref} = spawn_query("/live/track/get/name", [7], 100)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:timeout, {GenServer, :call, _}}}, 1000

      :sys.resume(Transport)

      c = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 2000) end)
      assert_receive {:osc_out, "/live/song/get/tempo", []}
      refute_received {:osc_out, "/live/track/get/name", [7]}

      reply(sink, "/live/song/get/tempo", [120.0])
      assert {:ok, _} = Task.await(c)
    end
  end

  # AbletonOSC sends no reply at all when a handler callback raises — the fork
  # sends the failing request back on /live/error instead, so the query can fail
  # now rather than after its full timeout. Everything here feeds those payloads
  # from the sink; nothing needs a live Ableton.
  #
  # The "not delivered" tests all prove the negative the same way: send the
  # non-matching error, then send the query's *real* reply and assert the caller
  # got that. A delivered error would have failed the query before the reply
  # arrived.
  describe "failed-query correlation" do
    setup do
      sink = start_supervised!({OSCSink, forward_to: self()})
      start_transport(sink)
      {:ok, sink: sink}
    end

    test "a structured error for the in-flight request fails it at once", %{sink: sink} do
      # 2s timeout with no reply ever sent: were correlation to stop working,
      # this exits on the timeout instead of quietly returning two seconds later.
      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      live_error(sink, "/live/track/get/name", [5], "Index out of range")

      assert {:error, {:live_error, "Index out of range"}} = Task.await(a)
    end

    test "the queue advances as soon as a query fails", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      b = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 2000) end)
      await_queue_depth(1)
      refute_received {:osc_out, "/live/song/get/tempo", []}

      live_error(sink, "/live/track/get/name", [5], "Index out of range")
      assert {:error, {:live_error, _}} = Task.await(a)

      assert_receive {:osc_out, "/live/song/get/tempo", []}
      reply(sink, "/live/song/get/tempo", [120.0])
      assert {:ok, {"/live/song/get/tempo", [120.0]}} = Task.await(b)
    end

    test "a structured error for another address is broadcast, not delivered", %{sink: sink} do
      :ok = Phoenix.PubSub.subscribe(Seshat.PubSub, "osc:in")

      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      live_error(sink, "/live/clip/get/name", [5, 0], "Index out of range")
      assert_receive {:osc_message, "/live/error", ["request", "/live/clip/get/name" | _]}

      reply(sink, "/live/track/get/name", [5, "Bass"])
      assert {:ok, {_, [5, "Bass"]}} = Task.await(a)
    end

    # The straggler case from the roadmap entry: the same getter, a different
    # index. Address alone would fail the wrong caller here, which is why
    # correlation compares every argument.
    test "a structured error with different arguments is not delivered", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      live_error(sink, "/live/track/get/name", [9], "Index out of range")

      reply(sink, "/live/track/get/name", [5, "Bass"])
      assert {:ok, {_, [5, "Bass"]}} = Task.await(a)
    end

    test "a structured error whose arg_count disagrees with its tail is not delivered", %{
      sink: sink
    } do
      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      # Right address, right argument, wrong count: a malformed structured
      # payload is a non-match, never a guess.
      raw_error(sink, ["request", "/live/track/get/name", "Index out of range", 2, 5])

      reply(sink, "/live/track/get/name", [5, "Bass"])
      assert {:ok, {_, [5, "Bass"]}} = Task.await(a)
    end

    test "a structured error whose arg_count is not an integer is not delivered", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      # Right address, right argument, but `arg_count` came back as a string —
      # the `is_integer(arg_count)` guard must reject this rather than let
      # `length(echoed) == arg_count` coerce it into a false match.
      raw_error(sink, ["request", "/live/track/get/name", "Index out of range", "1", 5])

      reply(sink, "/live/track/get/name", [5, "Bass"])
      assert {:ok, {_, [5, "Bass"]}} = Task.await(a)
    end

    test "an echoed argument of a different wire type never matches", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      # Same address and count, but the echoed argument is a float where an
      # integer was sent — `wire_arg_match?/2`'s type-checked clauses must fall
      # through to the catch-all non-match rather than comparing across types.
      raw_error(sink, ["request", "/live/track/get/name", "Index out of range", 1, 5.0])

      reply(sink, "/live/track/get/name", [5, "Bass"])
      assert {:ok, {_, [5, "Bass"]}} = Task.await(a)
    end

    test "legacy and log-tagged error payloads are never delivered", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      # Upstream's one-string payload, and the fork's tag for an error with no
      # originating request. Neither carries an address to correlate on.
      raw_error(sink, ["Error handling OSC message: Index out of range"])
      raw_error(sink, ["log", "Error handling OSC message: Index out of range"])

      reply(sink, "/live/track/get/name", [5, "Bass"])
      assert {:ok, {_, [5, "Bass"]}} = Task.await(a)
    end

    test "an error with no query in flight leaves the transport untouched", %{sink: sink} do
      :ok = Phoenix.PubSub.subscribe(Seshat.PubSub, "osc:in")

      live_error(sink, "/live/track/get/name", [5], "Index out of range")
      assert_receive {:osc_message, "/live/error", ["request" | _]}
      assert :sys.get_state(Transport).in_flight == nil

      a = Task.async(fn -> Transport.query("/live/song/get/tempo", [], 2000) end)
      assert_receive {:osc_out, "/live/song/get/tempo", []}
      reply(sink, "/live/song/get/tempo", [120.0])
      assert {:ok, {_, [120.0]}} = Task.await(a)
    end

    # OSC `f` is 32-bit and an Elixir float is 64-bit, so what Live echoes back
    # for 0.1 is not `0.1`. The sink hands the test the round-tripped value the
    # decoder produced, which is exactly what a real echo would carry — a naive
    # `==` matcher fails this test and nothing else.
    test "a float argument matches after its 32-bit round-trip", %{sink: sink} do
      a = Task.async(fn -> Transport.query("/live/clip/get/notes", [0, 0, 0.1], 2000) end)
      assert_receive {:osc_out, "/live/clip/get/notes", [0, 0, echoed]}
      assert echoed != 0.1

      live_error(sink, "/live/clip/get/notes", [0, 0, echoed], "Index out of range")

      assert {:error, {:live_error, "Index out of range"}} = Task.await(a)
    end

    test "a matched error is still broadcast", %{sink: sink} do
      :ok = Phoenix.PubSub.subscribe(Seshat.PubSub, "osc:in")

      a = Task.async(fn -> Transport.query("/live/track/get/name", [5], 2000) end)
      assert_receive {:osc_out, "/live/track/get/name", [5]}

      live_error(sink, "/live/track/get/name", [5], "Index out of range")
      assert {:error, {:live_error, _}} = Task.await(a)

      assert_receive {:osc_message, "/live/error",
                      ["request", "/live/track/get/name", "Index out of range", 1, 5]}
    end
  end

  describe "describe_error/1" do
    test "renders a live error as a sentence and everything else as before" do
      assert Transport.describe_error({:live_error, "Index out of range"}) ==
               "Ableton rejected the request: Index out of range"

      assert Transport.describe_error(:reply_port_unavailable) == ":reply_port_unavailable"
    end
  end

  defp live_error(sink, address, args, message) do
    raw_error(sink, ["request", address, message, length(args) | args])
  end

  defp raw_error(sink, args), do: reply(sink, "/live/error", args)

  # A query issued from a process that is expected to *exit* on its timeout.
  # `Task.async/1` is a trap for those: the exit propagates over the link and
  # kills the test process.
  defp spawn_query(address, args, timeout) do
    spawn_monitor(fn -> Transport.query(address, args, timeout) end)
  end

  defp reply(sink, address, args) do
    :ok =
      OSCSink.send_datagram(sink, transport_reply_port(), Message.encode(address, args))
  end

  # "Accepted but not yet sent" is a state assertion, not a message: the query
  # is issued from another process, so there is no ordering between its request
  # landing and anything the test does. Polling the server's
  # own queue is the direct statement of what the test means, and a query that
  # was wrongly sent instead of queued fails here rather than hanging.
  # Bounded by wall clock, not by attempt count: the loop is racing another
  # process's request landing, so a loaded machine needs *more*
  # attempts, not fewer — a fixed count gives up soonest exactly when the thing
  # it waits for is slowest. Still no sleep; each iteration is a `:sys.get_state`
  # round-trip, so the server paces the loop.
  defp await_queue_depth(expected, timeout \\ 1000) do
    await_until_depth(expected, System.monotonic_time(:millisecond) + timeout, timeout)
  end

  defp await_until_depth(expected, deadline, timeout) do
    depth = :queue.len(:sys.get_state(Transport).queue)

    cond do
      depth == expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("queue depth stayed at #{depth}, expected #{expected} within #{timeout}ms")

      true ->
        await_until_depth(expected, deadline, timeout)
    end
  end
end
