defmodule Seshat.Tools.HandlersTest do
  use ExUnit.Case, async: false

  alias Seshat.OSC.Message
  alias Seshat.Test.OSCSink
  alias Seshat.Tools.Handlers

  # Every describe that dispatches a *known* tool name owns a socket, whether or
  # not the tool itself reaches the wire: `Handlers.call/2` wraps every known
  # dispatch in a begin/end undo step, so even a tool that rejects its params
  # before doing anything now talks to Transport. The sink binds the test send
  # port first, so it is listening before the first datagram — and every
  # mutation below is then asserted where it landed, which is provably not
  # Ableton (config/test.exs).
  defp osc_sink(_context) do
    sink = start_supervised!({Seshat.Test.OSCSink, forward_to: self()})
    start_supervised!({Seshat.OSC.Transport, send_port: OSCSink.port(sink), reply_port: 0})

    %{sink: sink}
  end

  # Datagrams in *arrival* order. `assert_receive` scans past what it doesn't
  # match, so it can prove a message arrived but never that it arrived second —
  # and the undo wrap is only correct if `begin` precedes the mutation and `end`
  # follows it.
  defp osc_trace(timeout \\ 200) do
    receive do
      {:osc_out, address, args} -> [{address, args} | osc_trace(timeout)]
    after
      timeout -> []
    end
  end

  # `undo`/`redo` read `can_undo`/`can_redo` before sending, and block on the
  # reply — so a tool call that nothing answers spends the full 2s guard timeout.
  # `record_clip`'s pre-fire chain and post-fire echo read the same way, so they
  # are answered by the same helper.
  @guard_addresses [
    "/live/song/get/can_undo",
    "/live/song/get/can_redo",
    "/live/clip_slot/get/has_clip",
    "/live/track/get/arm",
    "/live/clip_slot/get/will_record_on_start",
    "/live/clip/get/is_recording",
    "/live/clip_slot/get/is_triggered"
  ]

  # Datagrams in arrival order, playing AbletonOSC for the guard as they go by.
  #
  # `assert_receive` cannot do this job: it removes the guard query from the
  # mailbox, which is precisely the ordering evidence these tests exist to keep.
  # So the tool call runs in a `Task` and the test process drains and answers in
  # one pass, spending one entry of `replies` per guard query: `true`/`false`
  # for the OSC boolean Live's own property yields, a list of args for any other
  # shape, or `:silence` to leave that attempt unanswered. Replies run out
  # silently, which is what an unanswered attempt looks like anyway.
  defp guarded_trace(sink, replies, timeout \\ 200) do
    receive do
      {:osc_out, address, args} ->
        [{address, args} | guarded_trace(sink, answer_guard(sink, address, replies), timeout)]
    after
      timeout -> []
    end
  end

  defp answer_guard(sink, address, [reply | rest]) when address in @guard_addresses do
    case reply do
      :silence -> :ok
      flag when is_boolean(flag) -> reply_datagram(sink, encode_flag(address, flag))
      args when is_list(args) -> reply_datagram(sink, Message.encode(address, args))
    end

    rest
  end

  defp answer_guard(_sink, _address, replies), do: replies

  # `guarded_trace/3` widened to answer *any* address, which the echo-check tests
  # need: they play Live's side of a whole tool's read sequence, not just the
  # pre-mutation guards, and the reply they are about is usually not one of
  # `@guard_addresses`.
  #
  # `replies` is a list of `{address, args}` in the order the answers should be
  # given; each is spent on the next query for that address, so a reissue after a
  # stale reply consumes the next entry for the same address — which is exactly
  # how "wrong once, right on the retry" is expressed here. A query with no entry
  # left goes unanswered, the same as running `guarded_trace/3` out of replies.
  defp scripted_trace(sink, replies, timeout \\ 200) do
    receive do
      {:osc_out, address, args} ->
        [{address, args} | scripted_trace(sink, answer_scripted(sink, address, replies), timeout)]
    after
      timeout -> []
    end
  end

  defp answer_scripted(sink, address, replies) do
    case Enum.split_while(replies, fn {addr, _args} -> addr != address end) do
      {_unmatched, []} ->
        replies

      {unmatched, [{_addr, reply} | rest]} ->
        reply_datagram(sink, Message.encode(address, reply))
        unmatched ++ rest
    end
  end

  defp count_queries(trace, address) do
    Enum.count(trace, fn {addr, _args} -> addr == address end)
  end

  defp reply_datagram(sink, binary) do
    reply_port = :sys.get_state(Seshat.OSC.Transport).reply_port
    :ok = OSCSink.send_datagram(sink, reply_port, binary)
  end

  # `Message.encode/2` has no boolean clause, because nothing in Seshat ever
  # sends one — but AbletonOSC's `_get_property` hands Live's raw Python value
  # to its own encoder, so `can_undo` arrives as OSC's payload-free `T`/`F` type
  # tag. Built by hand for exactly the reason `OSCSink.send_datagram/3` takes raw
  # binary: it is a byte sequence our encoder cannot produce.
  defp encode_flag(address, flag) do
    pad = fn string ->
      terminated = string <> <<0>>
      terminated <> :binary.copy(<<0>>, rem(4 - rem(byte_size(terminated), 4), 4))
    end

    pad.(address) <> pad.(if flag, do: ",T", else: ",F")
  end

  describe "set_track_pan" do
    setup :osc_sink

    test "returns ok with valid params" do
      assert {:ok, msg} = Handlers.call("set_track_pan", %{"track" => 0, "value" => -1.0})
      assert msg =~ "pan"
      assert msg =~ "track 0"
      assert_receive {:osc_out, "/live/track/set/panning", [0, -1.0]}
    end

    test "pans to center" do
      assert {:ok, _msg} = Handlers.call("set_track_pan", %{"track" => 1, "value" => 0.0})
      # `+0.0` not `0.0`: OTP 27+ warns that a bare 0.0 pattern matches only
      # positive zero anyway, and centre pan encodes as +0.0.
      assert_receive {:osc_out, "/live/track/set/panning", [1, +0.0]}
    end
  end

  describe "set_track_volume" do
    setup :osc_sink

    test "returns ok with valid params" do
      assert {:ok, msg} = Handlers.call("set_track_volume", %{"track" => 0, "value" => 0.5})
      assert msg =~ "volume"
      assert_receive {:osc_out, "/live/track/set/volume", [0, 0.5]}
    end

    test "sets volume to max" do
      assert {:ok, _msg} = Handlers.call("set_track_volume", %{"track" => 2, "value" => 1.0})
      assert_receive {:osc_out, "/live/track/set/volume", [2, 1.0]}
    end
  end

  describe "set_track_mute" do
    setup :osc_sink

    test "mutes a track" do
      assert {:ok, msg} = Handlers.call("set_track_mute", %{"track" => 0, "muted" => true})
      assert msg =~ "Muted track 0"
      assert_receive {:osc_out, "/live/track/set/mute", [0, 1]}
    end

    test "unmutes a track" do
      assert {:ok, _msg} = Handlers.call("set_track_mute", %{"track" => 0, "muted" => false})
      assert_receive {:osc_out, "/live/track/set/mute", [0, 0]}
    end
  end

  describe "set_track_solo" do
    setup :osc_sink

    test "solos a track" do
      assert {:ok, msg} = Handlers.call("set_track_solo", %{"track" => 0, "soloed" => true})
      assert msg =~ "Soloed track 0"
      assert_receive {:osc_out, "/live/track/set/solo", [0, 1]}
    end

    test "unsolos a track" do
      assert {:ok, _msg} = Handlers.call("set_track_solo", %{"track" => 0, "soloed" => false})
      assert_receive {:osc_out, "/live/track/set/solo", [0, 0]}
    end
  end

  describe "set_time_signature" do
    setup :osc_sink

    test "sends both halves as integers and states the quarter-note bar length" do
      assert {:ok, msg} =
               Handlers.call("set_time_signature", %{"numerator" => 6, "denominator" => 8})

      assert msg =~ "6/8"
      assert msg =~ "3.0 beats"

      # Integers, not floats: Live's signature properties are int, and
      # `_set_property` swallows a type rejection without a word on the wire.
      assert_receive {:osc_out, "/live/song/set/signature_numerator", [6]}
      assert_receive {:osc_out, "/live/song/set/signature_denominator", [8]}
    end

    test "a bar of 3/4 is three quarter-note beats" do
      assert {:ok, msg} =
               Handlers.call("set_time_signature", %{"numerator" => 3, "denominator" => 4})

      assert msg =~ "3/4"
      assert msg =~ "3.0 beats"
      assert_receive {:osc_out, "/live/song/set/signature_numerator", [3]}
      assert_receive {:osc_out, "/live/song/set/signature_denominator", [4]}
    end
  end

  describe "set_swing_amount" do
    setup :osc_sink

    # 0.25 rather than a rounder-looking 0.2 because OSC floats are 32-bit: 0.2
    # comes back off the wire as 0.20000000298023224 and would need a delta to
    # assert on. The values that survive exactly are the binary fractions.
    test "sends a float and tells the model quantizing is what applies it" do
      assert {:ok, msg} = Handlers.call("set_swing_amount", %{"amount" => 0.25})

      assert msg =~ "0.25"
      assert msg =~ "quantize"
      # Floats, not int32: `setattr` on a float LOM property must not be handed
      # an integer, and `_set_property` would swallow the rejection silently.
      assert_receive {:osc_out, "/live/song/set/swing_amount", [0.25]}
    end

    # Fork-only address: a Remote Scripts copy predating the pin drops it
    # indistinguishably from success, so the hint has to ride the reply.
    test "the reply names the reinstall as the fix when nothing swings" do
      assert {:ok, msg} = Handlers.call("set_swing_amount", %{"amount" => 0.0})

      assert msg =~ "mix abletonosc.install"
      assert_receive {:osc_out, "/live/song/set/swing_amount", [+0.0]}
    end

    test "an integer amount still goes on the wire as a float" do
      assert {:ok, _msg} = Handlers.call("set_swing_amount", %{"amount" => 1})
      assert_receive {:osc_out, "/live/song/set/swing_amount", [1.0]}
    end
  end

  describe "set_groove_amount" do
    setup :osc_sink

    test "sends a float and says it only scales already-assigned grooves" do
      assert {:ok, msg} = Handlers.call("set_groove_amount", %{"amount" => 0.75})

      assert msg =~ "0.75"
      assert msg =~ "Groove Pool"
      assert_receive {:osc_out, "/live/song/set/groove_amount", [0.75]}
    end

    # 1.3 is the dial's 130%, above swing's ceiling — the value that proves the
    # two bounds were not harmonised. It is not exactly representable in the
    # 32-bit float OSC puts on the wire, hence the delta rather than a match.
    test "the dial's maximum reaches the wire" do
      assert {:ok, _msg} = Handlers.call("set_groove_amount", %{"amount" => 1.3})
      assert_receive {:osc_out, "/live/song/set/groove_amount", [sent]}
      assert_in_delta sent, 1.3, 1.0e-6
    end

    test "an integer amount still goes on the wire as a float" do
      assert {:ok, _msg} = Handlers.call("set_groove_amount", %{"amount" => 1})
      assert_receive {:osc_out, "/live/song/set/groove_amount", [1.0]}
    end
  end

  describe "get_session_state" do
    # A read-only tool still gets its (empty, free) undo step, so this needs a
    # socket even though nothing here asserts on the wire.
    setup :osc_sink

    test "returns session info or handles missing Ableton" do
      # Session.State crashes on startup when Ableton isn't running,
      # so this call may exit. Both outcomes are valid.
      try do
        case Handlers.call("get_session_state", %{}) do
          {:ok, msg} -> assert is_binary(msg)
          {:error, _reason} -> :ok
        end
      catch
        :exit, _ -> :ok
      end
    end
  end

  describe "param key normalisation" do
    setup :osc_sink

    # MCP delivers Peri-validated params with atom keys, while direct callers
    # may use string keys. Both must reach the same clause.
    test "accepts atom-keyed params" do
      assert {:ok, msg} = Handlers.call("set_track_pan", %{track: 0, value: -1.0})
      assert msg =~ "pan"
      assert_receive {:osc_out, "/live/track/set/panning", [0, -1.0]}
    end

    test "normalises atom keys nested inside lists" do
      notes = [%{pitch: 60, start_beat: 0.0, duration: 1.0, velocity: 100}]

      assert Handlers.stringify_keys(%{track: 0, notes: notes}) == %{
               "track" => 0,
               "notes" => [
                 %{
                   "pitch" => 60,
                   "start_beat" => 0.0,
                   "duration" => 1.0,
                   "velocity" => 100
                 }
               ]
             }
    end

    test "leaves string-keyed params untouched" do
      params = %{"track" => 0, "value" => -1.0}
      assert Handlers.stringify_keys(params) == params
    end

    # Validation runs on the stringified map, so both key shapes are held to
    # the same schema.
    test "atom-keyed params are validated identically" do
      assert {:error, message} = Handlers.call("set_track_pan", %{track: 0, value: 2.0})
      assert message =~ "- value: must be at most 1.0 (got 2.0)"
      refute_receive {:osc_out, _, _}
    end
  end

  describe "parameter validation" do
    setup :osc_sink

    # The point of the central validator: a value outside its declared range
    # never becomes a datagram. `track: -1` is the case that motivated it —
    # AbletonOSC's Python would have deleted the *last* track and echoed
    # "track -1" as though that were the target.
    test "an out-of-range value is rejected before anything is sent" do
      assert {:error, message} =
               Handlers.call("set_track_pan", %{"track" => 0, "value" => 2.0})

      assert message =~ "Invalid parameters for set_track_pan"
      assert message =~ "nothing was sent to Ableton"
      refute_receive {:osc_out, _, _}
    end

    test "a negative track index is rejected before anything is sent" do
      assert {:error, message} = Handlers.call("delete_track", %{"track" => -1})
      assert message =~ "- track: must be at least 0 (got -1)"
      refute_receive {:osc_out, _, _}
    end

    test "a missing required param names the param, not the tool" do
      assert {:error, message} = Handlers.call("set_track_mute", %{"track" => 0})
      assert message =~ "- muted: required but missing"
      refute message =~ "Unknown tool"
      refute_receive {:osc_out, _, _}
    end

    test "valid params still reach the wire" do
      assert {:ok, _msg} = Handlers.call("set_track_pan", %{"track" => 0, "value" => 1.0})
      assert_receive {:osc_out, "/live/track/set/panning", [0, 1.0]}
    end
  end

  # Live decides undo-step boundaries for a control-surface script by its own
  # activity-sensitive rules — measured on 12.4.3, a create_track plus a
  # write_midi_notes collapsed into one step whose undo deleted the whole track.
  # `call/2` wraps every known dispatch in an explicit begin/end pair so one tool
  # call is one undo step. None of this can be seen in Live from here; what these
  # tests pin is the wire shape the Python half depends on.
  describe "one tool call, one undo step" do
    setup :osc_sink

    test "a wrapped tool sends begin, then its mutation, then end" do
      assert {:ok, _msg} = Handlers.call("set_tempo", %{"bpm" => 120.0})

      assert [
               {"/live/song/end_undo_step", []},
               {"/live/song/begin_undo_step", []},
               {"/live/song/set/tempo", [120.0]},
               {"/live/song/end_undo_step", []}
             ] = osc_trace()
    end

    # The leading `end` is not decoration. `begin` does not refcount, so a step
    # leaked by a BEAM death or a failed `end` send is still open when the next
    # call runs: without closing first, that call's `begin` is a no-op and its
    # own `end` closes one step holding both the leak's partial work and this
    # call's mutation — one `undo` would revert two tool calls, which is exactly
    # the guarantee the wrap exists to make. Nothing here can open a real step in
    # Live, so what this pins is the wire shape that keeps the boundary correct:
    # every wrapped call closes before it opens, on every path.
    test "every wrapped call closes any leaked step before opening its own" do
      assert {:ok, _msg} = Handlers.call("set_tempo", %{"bpm" => 120.0})
      assert {:error, _msg} = Handlers.call("search_library", %{"query" => "bass"})
      assert {:ok, _msg} = Handlers.call("set_track_volume", %{"track" => 0, "value" => 0.5})

      trace = osc_trace()

      # Each wrapped dispatch begins with `end` and never sends `begin` first.
      assert {"/live/song/end_undo_step", []} == hd(trace)

      refute Enum.any?(Enum.chunk_every(trace, 2, 1, :discard), fn
               [{"/live/song/begin_undo_step", []}, {"/live/song/begin_undo_step", []}] -> true
               _ -> false
             end),
             "a begin followed by another begin means a step was opened without closing the " <>
               "previous one: #{inspect(trace)}"

      # And every `begin` is immediately preceded by the defensive `end`.
      for {{"/live/song/begin_undo_step", []}, i} <- Enum.with_index(trace) do
        assert {"/live/song/end_undo_step", []} == Enum.at(trace, i - 1),
               "begin at #{i} was not preceded by a defensive end: #{inspect(trace)}"
      end
    end

    # The `end` lives in an `after` block precisely so a failing tool still
    # closes its step. `search_library` is the cheap error path: the catalog is
    # not started in the test env, so it returns before touching Ableton and
    # without spending a query timeout.
    test "an error path still closes the step it opened" do
      assert {:error, msg} = Handlers.call("search_library", %{"query" => "bass"})
      assert msg =~ "reindex_library"

      assert [
               {"/live/song/end_undo_step", []},
               {"/live/song/begin_undo_step", []},
               {"/live/song/end_undo_step", []}
             ] = osc_trace()
    end

    # An undo inside an open step is a state this design never creates, so undo
    # is never wrapped. The lone `end` is defensive: it closes a step leaked by a
    # BEAM death mid-call, and is measured harmless when no step is open.
    #
    # The `can_undo` guard's position is load-bearing and is why this pins the
    # order rather than three separate `assert_receive`s: closing a leaked step
    # can itself add an entry to Live's history, so a guard read *before* that
    # `end` would answer about a history state that no longer exists by the time
    # the undo is sent.
    test "undo sends a defensive end, then its guard, then the undo", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("undo", %{}) end)
      trace = guarded_trace(sink, [true])

      assert {:ok, _msg} = Task.await(call)

      assert [
               {"/live/song/end_undo_step", []},
               {"/live/song/get/can_undo", []},
               {"/live/song/undo", []}
             ] = trace
    end

    test "redo has the same unwrapped shape", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("redo", %{}) end)
      trace = guarded_trace(sink, [true])

      assert {:ok, _msg} = Task.await(call)

      assert [
               {"/live/song/end_undo_step", []},
               {"/live/song/get/can_redo", []},
               {"/live/song/redo", []}
             ] = trace
    end

    # Validation deliberately passes an unknown name through to the catch-all,
    # so membership in the tool list is what gates the wrap. A tool that doesn't
    # exist must not put anything on the wire — and pure tests that call `call/2`
    # with no Transport running depend on it too.
    test "an unknown tool name sends nothing at all" do
      assert {:error, msg} = Handlers.call("nonexistent_tool", %{})
      assert msg =~ "Unknown tool"

      assert [] == osc_trace()
    end

    # The tripwire for cross-session interleaving. Anubis serializes calls within
    # one MCP session, but two Desktop clients can overlap — and `begin_undo_step`
    # is measured *not* to refcount, so one caller's `end` would close the other's
    # step and both actions would land in one undo. `hide_view` is the hold: it
    # sends, then blocks on a query this test answers by hand.
    test "a second caller cannot enter an open undo step", %{sink: sink} do
      first = Task.async(fn -> Handlers.call("hide_view", %{"view" => "Browser"}) end)

      assert_receive {:osc_out, "/live/song/end_undo_step", []}
      assert_receive {:osc_out, "/live/song/begin_undo_step", []}
      assert_receive {:osc_out, "/live/view/hide_view", ["Browser"]}
      assert_receive {:osc_out, "/live/view/get/is_view_visible", ["Browser"]}

      second = Task.async(fn -> Handlers.call("set_tempo", %{"bpm" => 140.0}) end)

      # Nothing from the second caller reaches Ableton while the step is open —
      # not its mutation, not its own `begin`, and not even its defensive `end`,
      # which is what stops it closing the first caller's step from outside.
      refute_receive {:osc_out, "/live/song/begin_undo_step", []}, 300
      refute_receive {:osc_out, "/live/song/end_undo_step", []}, 0
      refute_receive {:osc_out, "/live/song/set/tempo", _}, 0

      # Play AbletonOSC and release the first call.
      :ok =
        OSCSink.send_datagram(
          sink,
          :sys.get_state(Seshat.OSC.Transport).reply_port,
          Message.encode("/live/view/get/is_view_visible", ["Browser", "ok", 0])
        )

      assert {:ok, _msg} = Task.await(first)
      assert {:ok, _msg} = Task.await(second)

      # And once it is closed, the second caller runs its own complete step —
      # the first `end` here is the first caller's, the second is the second
      # caller's own defensive close.
      assert [
               {"/live/song/end_undo_step", []},
               {"/live/song/end_undo_step", []},
               {"/live/song/begin_undo_step", []},
               {"/live/song/set/tempo", [140.0]},
               {"/live/song/end_undo_step", []}
             ] = osc_trace()
    end
  end

  # `/live/song/undo` and `/live/song/redo` never reply, so the old "Undone" /
  # "Redone" asserted an outcome nothing had observed: measured 2026-08-02, a
  # `redo` against an exhausted redo stack reported success while Live had not
  # moved. What is checkable from here is that no reply claims history moved,
  # and that a `can_undo`/`can_redo` answer of `false` — confirmed once, because
  # Transport correlates by address alone and a song property has no index to
  # echo — stops the send instead of dressing it up.
  describe "undo and redo report the request, not the outcome" do
    setup :osc_sink

    test "a confirmed no-step-available refuses, and nothing reaches the wire", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("undo", %{}) end)
      trace = guarded_trace(sink, [false, false])

      assert {:error, message} = Task.await(call)

      # Observational wording: this reports what Live said, not an independently
      # known history state — the reissue is stale-reply mitigation, not
      # correlation.
      assert message =~ "Live reported no undo step available, so no undo was sent"
      assert message =~ "Do not retry unless history has changed"

      assert [
               {"/live/song/end_undo_step", []},
               {"/live/song/get/can_undo", []},
               {"/live/song/get/can_undo", []}
             ] = trace
    end

    test "an available step sends the undo and claims nothing about history", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("undo", %{}) end)
      trace = guarded_trace(sink, [true])

      assert {:ok, message} = Task.await(call)

      assert message =~ "Undo requested"
      assert message =~ "not that history moved"
      assert message =~ "get_session_state"
      refute message =~ "Undone"

      assert {"/live/song/undo", []} in trace
    end

    # The tripwire for the same-address straggler defence: a `false` that the
    # reissue contradicts belonged to an earlier query, and must not refuse.
    test "a false answer contradicted by the reissue still sends", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("undo", %{}) end)
      trace = guarded_trace(sink, [false, true])

      assert {:ok, message} = Task.await(call)
      assert message =~ "Undo requested"
      refute message =~ "did not answer"

      assert [
               {"/live/song/end_undo_step", []},
               {"/live/song/get/can_undo", []},
               {"/live/song/get/can_undo", []},
               {"/live/song/undo", []}
             ] = trace
    end

    # Slow by construction — 2s of guard timeout — and worth it: refusing here
    # would turn a dropped datagram into a failed undo, a worse regression than
    # the dishonest reply this replaces. Called synchronously because nothing is
    # going to answer.
    test "an unanswered guard sends anyway and states the uncertainty" do
      assert {:ok, message} = Handlers.call("undo", %{})

      assert message =~ "Undo requested"
      assert message =~ "did not answer the can_undo check"
      assert message =~ "unknown"

      assert_receive {:osc_out, "/live/song/undo", []}
    end

    test "a reply shape the guard cannot read is not an answer", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("undo", %{}) end)
      trace = guarded_trace(sink, [["yes"]])

      assert {:ok, message} = Task.await(call)
      assert message =~ "did not answer the can_undo check"

      assert {"/live/song/undo", []} in trace
    end

    # A `false` whose reissue goes unanswered has one recognized answer, and one
    # is not the two the refusal requires.
    # `assert_receive` rather than the trace helper: the second attempt spends
    # the full 2s guard timeout, and a drain window wide enough to outlast it
    # would then idle that long again after the undo landed. Ordering is already
    # pinned above.
    test "a false whose reissue is unanswered takes the uncertain path", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("undo", %{}) end)

      assert_receive {:osc_out, "/live/song/get/can_undo", []}
      :ok = reply_datagram(sink, encode_flag("/live/song/get/can_undo", false))

      assert {:ok, message} = Task.await(call, 5_000)
      assert message =~ "did not answer the can_undo check"

      assert_receive {:osc_out, "/live/song/undo", []}
    end

    # `_get_property` hands Live's raw value to the encoder, so the flag may
    # arrive as OSC T/F or as an int. Both shapes are read, exactly as
    # `Session.State.query_song_int/2` reads them — which is why the exact
    # encoding never had to be measured.
    test "an integer 0 refuses just as a bool false does", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("undo", %{}) end)
      trace = guarded_trace(sink, [[0], [0]])

      assert {:error, message} = Task.await(call)
      assert message =~ "Live reported no undo step available"
      refute {"/live/song/undo", []} in trace
    end

    test "an integer 1 sends just as a bool true does", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("undo", %{}) end)
      trace = guarded_trace(sink, [[1]])

      assert {:ok, _message} = Task.await(call)
      assert {"/live/song/undo", []} in trace
    end

    test "redo refuses on a confirmed empty redo stack", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("redo", %{}) end)
      trace = guarded_trace(sink, [false, false])

      assert {:error, message} = Task.await(call)

      assert message =~ "Live reported no redo step available, so no redo was sent"
      # Redo's history is the one an unrelated edit can wipe, so its refusal
      # says so where undo's does not.
      assert message =~ "any new edit can clear Live's redo history"

      refute {"/live/song/redo", []} in trace
    end

    test "redo sends and reports only the request when a step is available", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("redo", %{}) end)
      trace = guarded_trace(sink, [[1]])

      assert {:ok, message} = Task.await(call)

      assert message =~ "Redo requested"
      assert message =~ "not that history moved"
      refute message =~ "Redone"

      assert {"/live/song/redo", []} in trace
    end

    test "redo's reissue contradicting a false still sends", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("redo", %{}) end)
      trace = guarded_trace(sink, [false, true])

      assert {:ok, _message} = Task.await(call)
      assert {"/live/song/redo", []} in trace
    end

    test "redo states the uncertainty when its guard cannot be read", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("redo", %{}) end)
      trace = guarded_trace(sink, [["maybe"]])

      assert {:ok, message} = Task.await(call)
      assert message =~ "did not answer the can_redo check"
      assert message =~ "anything to redo is unknown"

      assert {"/live/song/redo", []} in trace
    end
  end

  # AbletonOSC answers a request whose index has gone with a structured
  # /live/error rather than with the property, and Transport turns that into
  # `{:error, {:live_error, message}}`. A pre-mutation guard must treat it the
  # way it treats the vendored envelope's error arm — the index doesn't exist,
  # so nothing further is sent — rather than leaking the tuple through
  # `inspect/1`.
  describe "a guard query Ableton rejects" do
    setup :osc_sink

    test "fails the tool in Live's own words and sends no mutation", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("set_track_send", %{"track" => 9, "send" => 0, "value" => 0.5})
        end)

      assert_receive {:osc_out, "/live/track/get/send", [9, 0]}

      reply_datagram(
        sink,
        Message.encode(
          "/live/error",
          ["request", "/live/track/get/send", "Index out of range", 2, 9, 0]
        )
      )

      assert {:error, message} = Task.await(call)
      assert message =~ "Index out of range"
      assert message =~ "Nothing further was sent"
      assert message =~ "get_session_state"

      # The whole point of the guard: the value is never written to a track
      # index Live has just told us it doesn't have.
      refute Enum.any?(osc_trace(), fn {address, _args} ->
               address == "/live/track/set/send"
             end)
    end
  end

  # `/live/track/set/send` is silent and no listener anywhere pushes a send's
  # accepted value, so the read-back below is the only account of the outcome
  # there is. These pin that no `{:ok, …}` leaves the clause without an
  # answered, correlated read agreeing with what was sent.
  describe "set_track_send's confirming read-back" do
    setup :osc_sink

    test "reports the level as confirmed, after reading it back", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("set_track_send", %{"track" => 0, "send" => 0, "value" => 0.37})
        end)

      trace =
        scripted_trace(sink, [
          {"/live/track/get/send", [0, 0, 0.0]},
          {"/live/track/get/send", [0, 0, 0.37]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "Set send A on track 0 to 0.37"
      assert message =~ "(was 0.0)"
      assert message =~ "confirmed by reading it back"

      # Guard, then the set, then the read-back — in that order. The read-back
      # only means anything if it followed the set onto the wire.
      assert Enum.flat_map(trace, fn {address, _args} ->
               if String.starts_with?(address, "/live/track/"), do: [address], else: []
             end) == [
               "/live/track/get/send",
               "/live/track/set/send",
               "/live/track/get/send"
             ]

      assert [{_address, [0, 0, sent]}] =
               Enum.filter(trace, fn {address, _args} -> address == "/live/track/set/send" end)

      assert Float.round(sent, 4) == 0.37
    end

    # OSC's `f` is 32 bits and Elixir's floats are not, so a value that isn't
    # exactly representable comes back widened — here spelled out literally,
    # though `Message.encode/2` does the same thing to the reply above. An `==`
    # comparison would call this a failed set.
    test "the wire's float32 widening still confirms", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("set_track_send", %{"track" => 0, "send" => 0, "value" => 0.37})
        end)

      scripted_trace(sink, [
        {"/live/track/get/send", [0, 0, 0.0]},
        {"/live/track/get/send", [0, 0, 0.3700000047683716]}
      ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "confirmed by reading it back"
    end

    # The dropped-datagram case: the read-back answers, correlates, and reports
    # the value the send had all along.
    test "a level that did not move is an error naming both values", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("set_track_send", %{"track" => 0, "send" => 0, "value" => 0.37})
        end)

      scripted_trace(sink, [
        {"/live/track/get/send", [0, 0, 0.0]},
        {"/live/track/get/send", [0, 0, 0.0]}
      ])

      assert {:error, message} = Task.await(call)
      assert message =~ "0.37"
      assert message =~ "Live reports 0.0"
      assert message =~ "did not land"
      refute message =~ "Set send"
    end

    test "a read-back echoing another send is reissued, not believed", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("set_track_send", %{"track" => 0, "send" => 0, "value" => 0.37})
        end)

      trace =
        scripted_trace(sink, [
          {"/live/track/get/send", [0, 0, 0.0]},
          {"/live/track/get/send", [9, 0, 0.9]},
          {"/live/track/get/send", [0, 0, 0.37]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "confirmed by reading it back"
      refute message =~ "0.9"

      # Guard plus the read-back plus its reissue.
      assert count_queries(trace, "/live/track/get/send") == 3
    end

    test "two mis-echoed read-backs are unconfirmed, never an ok", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("set_track_send", %{"track" => 0, "send" => 0, "value" => 0.37})
        end)

      trace =
        scripted_trace(sink, [
          {"/live/track/get/send", [0, 0, 0.0]},
          {"/live/track/get/send", [9, 0, 0.9]},
          {"/live/track/get/send", [9, 0, 0.9]}
        ])

      assert {:error, message} = Task.await(call)
      assert message =~ "The set was sent"
      assert message =~ "did not confirm it"
      assert message =~ "get_track_sends"
      refute message =~ "0.9"

      # The honest wording is about a set that really is on the wire.
      assert Enum.any?(trace, fn {address, _args} -> address == "/live/track/set/send" end)
    end
  end

  # Every property in one burst rather than one query per property. `count` here
  # is the honest measure of the change: what used to be 13–17 serialized round
  # trips is a guard plus one batch, and the trace proves the datagrams went out
  # together rather than the reply merely looking right.
  describe "get_clip_properties in one batch" do
    setup :osc_sink

    @midi_clip_replies [
      {"/live/clip_slot/get/has_clip", [0, 0, 1]},
      {"/live/clip/get/is_midi_clip", [0, 0, 1]},
      {"/live/clip/get/name", [0, 0, "Verse"]},
      {"/live/clip/get/length", [0, 0, 4.0]},
      {"/live/clip/get/looping", [0, 0, 1]},
      {"/live/clip/get/loop_start", [0, 0, 0.0]},
      {"/live/clip/get/loop_end", [0, 0, 4.0]},
      {"/live/clip/get/start_marker", [0, 0, 0.0]},
      {"/live/clip/get/end_marker", [0, 0, 4.0]},
      {"/live/clip/get/launch_mode", [0, 0, 0]},
      {"/live/clip/get/launch_quantization", [0, 0, 0]},
      {"/live/clip/get/legato", [0, 0, 0]},
      {"/live/clip/get/velocity_amount", [0, 0, 0.0]}
    ]

    test "a MIDI clip costs the guard plus one batch", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("get_clip_properties", %{"track" => 0, "clip_slot" => 0})
        end)

      trace = scripted_trace(sink, @midi_clip_replies)

      assert {:ok, message} = Task.await(call)
      assert message =~ "Clip 'Verse' — track 0, slot 0 — MIDI, 4.0 beats"
      assert message =~ "Loop: on, from beat 0.0 to 4.0"

      # One datagram per property, once — and nothing audio-only, because
      # `is_midi_clip` rode the same batch that answered the rest.
      assert count_queries(trace, "/live/clip_slot/get/has_clip") == 1
      assert count_queries(trace, "/live/clip/get/is_midi_clip") == 1
      assert count_queries(trace, "/live/clip/get/name") == 1
      assert count_queries(trace, "/live/clip/get/velocity_amount") == 1
      assert count_queries(trace, "/live/clip/get/gain") == 0
    end

    test "an audio clip pays one more batch for its audio-only properties", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("get_clip_properties", %{"track" => 0, "clip_slot" => 0})
        end)

      audio =
        List.keyreplace(
          @midi_clip_replies,
          "/live/clip/get/is_midi_clip",
          0,
          {"/live/clip/get/is_midi_clip", [0, 0, 0]}
        )

      trace =
        scripted_trace(
          sink,
          audio ++
            [
              {"/live/clip/get/gain", [0, 0, 0.5]},
              {"/live/clip/get/gain_display_string", [0, 0, "-6.0 dB"]},
              {"/live/clip/get/warp_mode", [0, 0, 0]},
              {"/live/clip/get/warping", [0, 0, 1]}
            ]
        )

      assert {:ok, message} = Task.await(call)
      assert message =~ "audio, 4.0 beats"
      assert message =~ "Audio: gain -6.0 dB (0.5), warp on, mode Beats"

      # The four audio-only reads, once each, in a batch of their own.
      assert count_queries(trace, "/live/clip/get/gain") == 1
      assert count_queries(trace, "/live/clip/get/gain_display_string") == 1
      assert count_queries(trace, "/live/clip/get/warp_mode") == 1
      assert count_queries(trace, "/live/clip/get/warping") == 1
      assert count_queries(trace, "/live/clip/get/name") == 1
    end

    # A rejection lands per entry, so the property that failed is the one named
    # — in Live's own words, on the guard's timescale rather than the deadline's.
    test "a property Live rejects is reported rather than waited out", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("get_clip_properties", %{"track" => 0, "clip_slot" => 0})
        end)

      scripted_trace(
        sink,
        List.keydelete(@midi_clip_replies, "/live/clip/get/velocity_amount", 0)
      )

      reply_datagram(
        sink,
        Message.encode(
          "/live/error",
          ["request", "/live/clip/get/velocity_amount", "Clip does not exist", 2, 0, 0]
        )
      )

      assert {:error, message} = Task.await(call)
      assert message =~ "Clip does not exist"
      assert message =~ "Nothing further was sent"
    end

    # A reply Live actually sent, correlated to the right entry, but shaped in
    # a way `unwrap_payload/1` has no clause for — distinct from the rejection
    # envelope above, which *is* a shape this code reads.
    test "a reply shaped like nothing this code recognises is named, not decoded blindly", %{
      sink: sink
    } do
      call =
        Task.async(fn ->
          Handlers.call("get_clip_properties", %{"track" => 0, "clip_slot" => 0})
        end)

      replies =
        List.keyreplace(
          @midi_clip_replies,
          "/live/clip/get/name",
          0,
          {"/live/clip/get/name", [0, 0, "unexpected", "extra"]}
        )

      scripted_trace(sink, replies)

      assert {:error, message} = Task.await(call)
      assert message =~ "the name of the clip in slot 0 on track 0"
      assert message =~ "was not a shape this can read"
    end

    # Slow by construction — the batch's own 2s guard timeout — and worth
    # pinning: `read_clip_properties/3` now catches its own `:exit`, so a
    # pre-write timeout renders this wording rather than propagating to
    # `do_call`'s "Timed out reading the properties … nothing is known about
    # it" clause, which used to be the only source of this error and is now
    # dead for this path (still live for a timeout on `ensure_clip` itself).
    test "an unanswered batch times out in its own words, not the tool's stale ones", %{
      sink: sink
    } do
      call =
        Task.async(fn ->
          Handlers.call("get_clip_properties", %{"track" => 0, "clip_slot" => 0})
        end)

      assert_receive {:osc_out, "/live/clip_slot/get/has_clip", [0, 0]}
      :ok = reply_datagram(sink, Message.encode("/live/clip_slot/get/has_clip", [0, 0, 1]))

      assert {:error, message} = Task.await(call, 5_000)
      assert message =~ "Timed out checking the properties of the clip in slot 0 on track 0"
      assert message =~ "nothing further was sent"
      refute message =~ "nothing is known about it"
    end
  end

  # One count query, then every return's name and this track's level into it in
  # a single burst. The pairing is what the echo prefix buys: two entries share
  # `/live/return_track/get/name` and two share `/live/track/get/send`, and only
  # the index each reply echoes says which is which.
  describe "get_track_sends in one batch" do
    setup :osc_sink

    test "names and levels come back paired, one datagram each", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_track_sends", %{"track" => 0}) end)

      trace =
        scripted_trace(sink, [
          {"/live/return_track/get/count", [2]},
          {"/live/track/get/name", [0, "Drums"]},
          {"/live/return_track/get/name", [0, "ok", "Reverb"]},
          {"/live/track/get/send", [0, 0, 0.5]},
          {"/live/return_track/get/name", [1, "ok", "Delay"]},
          {"/live/track/get/send", [0, 1, 0.25]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "2 send(s) on track 0"
      assert message =~ ~s{send 0 (A) → "Reverb": 0.5}
      assert message =~ ~s{send 1 (B) → "Delay": 0.25}

      # The count, then 2N+1 entries in one breath — one datagram each, no
      # per-return round trip and no reissue.
      assert count_queries(trace, "/live/return_track/get/count") == 1
      assert count_queries(trace, "/live/track/get/name") == 1
      assert count_queries(trace, "/live/return_track/get/name") == 2
      assert count_queries(trace, "/live/track/get/send") == 2
    end

    test "a track index Live rejects fails the read, not the batch's deadline", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_track_sends", %{"track" => 9}) end)

      scripted_trace(sink, [
        {"/live/return_track/get/count", [1]},
        {"/live/return_track/get/name", [0, "ok", "Reverb"]},
        {"/live/track/get/send", [9, 0, 0.5]}
      ])

      reply_datagram(
        sink,
        Message.encode(
          "/live/error",
          ["request", "/live/track/get/name", "Index out of range", 1, 9]
        )
      )

      assert {:error, message} = Task.await(call)
      assert message =~ "Index out of range"
      assert message =~ "get_session_state"
    end

    test "a set with no returns keeps its single guard query", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_track_sends", %{"track" => 0}) end)

      trace =
        scripted_trace(sink, [
          {"/live/return_track/get/count", [0]},
          {"/live/track/get/name", [0, "Drums"]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "This set has no return tracks"

      # No batch at all on this branch: the track index is still checked, and
      # that is the only read.
      assert count_queries(trace, "/live/track/get/name") == 1
      assert count_queries(trace, "/live/return_track/get/name") == 0
      assert count_queries(trace, "/live/track/get/send") == 0
    end

    # `entries` is `2 * count + 1`, and `Transport.query_batch/2` raises past
    # its 64-entry cap. Live 12 caps return tracks at 12, so 32 is unreachable
    # through the UI — this pins that the raise is turned into a sentence
    # rather than escaping the handler uncaught.
    test "a return count too large for one batch fails without reaching the wire", %{
      sink: sink
    } do
      call = Task.async(fn -> Handlers.call("get_track_sends", %{"track" => 0}) end)

      trace = scripted_trace(sink, [{"/live/return_track/get/count", [32]}])

      assert {:error, message} = Task.await(call)
      assert message =~ "32 return tracks"
      assert message =~ "bug"

      # `validate_batch!/1` raises before `query_batch/2` ever calls
      # `:gen_server.send_request/2`, so nothing past the count query reaches
      # the wire.
      assert count_queries(trace, "/live/return_track/get/count") == 1
      assert count_queries(trace, "/live/track/get/name") == 0
    end
  end

  # The six reads that used to discard the correlation data Live handed them.
  # Each test plays AbletonOSC's side on one address with an echo belonging to
  # somebody else. What is being pinned is that a straggler never reaches the
  # reply the model reads, and that a legitimate reply still sails through
  # unchanged.
  describe "get_track_devices and the straggler on its address" do
    setup :osc_sink

    # Batched, the straggler no longer has anything to consume: it matches no
    # entry, so nothing is reissued and the entry's own reply — late — still
    # resolves it. That is the same protection the reissue used to buy, minus
    # the extra round trip and minus the window where the true reply landed
    # between the rejection and the reissue.
    test "a reply echoing another track resolves nothing and is simply ignored", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_track_devices", %{"track" => 1}) end)

      trace =
        scripted_trace(sink, [
          {"/live/track/get/devices/name", [0, "Operator"]},
          {"/live/track/get/devices/type", [1, 2]},
          {"/live/track/get/devices/class_name", [1, "Reverb"]}
        ])

      # One datagram per entry and no reissue behind the mismatched reply.
      assert count_queries(trace, "/live/track/get/devices/name") == 1

      reply_datagram(sink, Message.encode("/live/track/get/devices/name", [1, "Reverb"]))

      assert {:ok, message} = Task.await(call)
      assert message =~ ~s(Device 0 "Reverb")
      refute message =~ "Operator"
    end

    # A rejection is per entry too: Live raises on the bad index, the fork sends
    # the request back on /live/error, and Transport fails that entry alone — so
    # the read reports Live's own words rather than waiting out a deadline.
    test "an entry Live rejects fails the read in Live's own words", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_track_devices", %{"track" => 9}) end)

      scripted_trace(sink, [
        {"/live/track/get/devices/type", [9, 2]},
        {"/live/track/get/devices/class_name", [9, "Reverb"]}
      ])

      reply_datagram(
        sink,
        Message.encode(
          "/live/error",
          ["request", "/live/track/get/devices/name", "Index out of range", 1, 9]
        )
      )

      assert {:error, message} = Task.await(call)
      assert message =~ "Index out of range"
      assert message =~ "Nothing further was sent"
    end

    test "a correctly echoed chain reads exactly as it did before the check", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_track_devices", %{"track" => 1}) end)

      trace =
        scripted_trace(sink, [
          {"/live/track/get/devices/name", [1, "Reverb"]},
          {"/live/track/get/devices/type", [1, 2]},
          {"/live/track/get/devices/class_name", [1, "Reverb"]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "1 device(s) on track 1"
      assert message =~ "Device 0 \"Reverb\" — audio effect (Reverb)"
      assert count_queries(trace, "/live/track/get/devices/name") == 1
    end
  end

  describe "get_device_parameters and the straggler on its address" do
    setup :osc_sink

    # Five replies assembled into parallel lists: the failure this rules out is
    # one device's values printed against another device's parameter names. The
    # entries all echo the same pair of indices, so the mismatched value list
    # matches none of them.
    test "a value list echoing another device is never merged in", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("get_device_parameters", %{"track" => 0, "device" => 1})
        end)

      trace =
        scripted_trace(sink, [
          {"/live/device/get/name", [0, 1, "Reverb"]},
          {"/live/device/get/parameters/name", [0, 1, "Device On", "Dry/Wet"]},
          {"/live/device/get/parameters/value", [0, 2, 0.0, 0.25]},
          {"/live/device/get/parameters/min", [0, 1, 0.0, 0.0]},
          {"/live/device/get/parameters/max", [0, 1, 1.0, 1.0]}
        ])

      assert count_queries(trace, "/live/device/get/parameters/value") == 1

      reply_datagram(
        sink,
        Message.encode("/live/device/get/parameters/value", [0, 1, 1.0, 0.5])
      )

      assert {:ok, message} = Task.await(call)
      assert message =~ "Dry/Wet = 0.5"
      refute message =~ "0.25"
    end

    test "an entry Live rejects names the device that was asked about", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("get_device_parameters", %{"track" => 0, "device" => 1})
        end)

      scripted_trace(sink, [
        {"/live/device/get/parameters/name", [0, 1, "Device On"]},
        {"/live/device/get/parameters/value", [0, 1, 1.0]},
        {"/live/device/get/parameters/min", [0, 1, 0.0]},
        {"/live/device/get/parameters/max", [0, 1, 1.0]}
      ])

      reply_datagram(
        sink,
        Message.encode(
          "/live/error",
          ["request", "/live/device/get/name", "Index out of range", 2, 0, 1]
        )
      )

      assert {:error, message} = Task.await(call)
      assert message =~ "Index out of range"
      refute message =~ "Delay"
    end
  end

  describe "get_clip_notes and the straggler on its address" do
    setup :osc_sink

    # The clip guards echo too, so the sink has to answer them about the slot
    # actually asked for before the read under test is even reached.
    test "a name reply about another slot twice is an error, not a clip", %{sink: sink} do
      call =
        Task.async(fn -> Handlers.call("get_clip_notes", %{"track" => 0, "clip_slot" => 1}) end)

      scripted_trace(sink, [
        {"/live/clip_slot/get/has_clip", [0, 1, 1]},
        {"/live/clip/get/is_midi_clip", [0, 1, 1]},
        {"/live/clip/get/name", [0, 2, "Somebody else's clip"]},
        {"/live/clip/get/name", [0, 2, "Somebody else's clip"]}
      ])

      assert {:error, message} = Task.await(call)
      assert message =~ "the clip in slot 1 on track 0"
      refute message =~ "Somebody else's clip"
    end

    # The one read in the file whose echo is a strict prefix of its request:
    # `/live/clip/get/notes` echoes the track and slot and never the range it was
    # given, so a reply that repeated the range would be the surprise here.
    test "the ranged notes read verifies the track and slot it echoes", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("get_clip_notes", %{
            "track" => 0,
            "clip_slot" => 1,
            "start_time" => 0,
            "time_span" => 4
          })
        end)

      trace =
        scripted_trace(sink, [
          {"/live/clip_slot/get/has_clip", [0, 1, 1]},
          {"/live/clip/get/is_midi_clip", [0, 1, 1]},
          {"/live/clip/get/name", [0, 1, "Loop"]},
          {"/live/clip/get/length", [0, 1, 4.0]},
          {"/live/clip/get/notes", [0, 1, 60, 0.0, 1.0, 100, 0]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ ~s(Clip "Loop" on track 0, slot 1)
      assert message =~ "C4 (60)"

      # The range really did go out, and really was not echoed back.
      assert {"/live/clip/get/notes", [0, 1, 0, 128, 0.0, 4.0]} in trace
    end
  end

  describe "set_device_parameter's confirming read" do
    setup :osc_sink

    # The fabricated-confirmation tripwire: a read-back that answers about
    # another parameter must never be dressed up as proof this write landed.
    test "an unverified read-back is reported as unconfirmed, never as a value", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("set_device_parameter", %{
            "track" => 0,
            "device" => 1,
            "parameter" => 2,
            "value" => 0.5
          })
        end)

      trace =
        scripted_trace(sink, [
          {"/live/device/get/parameter/value_string", [0, 1, 3, "-inf dB"]},
          {"/live/device/get/parameter/value_string", [0, 1, 3, "-inf dB"]}
        ])

      assert {:error, message} = Task.await(call)
      assert message =~ "parameter 2 of device 1 on track 0"
      assert message =~ "did not confirm it"
      assert message =~ "get_device_parameters"
      refute message =~ "it now reads"
      refute message =~ "-inf dB"

      # The set itself is on the wire either way — that is what the honest
      # wording above is about.
      assert {"/live/device/set/parameter/value", [0, 1, 2, 0.5]} in trace
    end

    test "a read-back about the parameter that was written still confirms it", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("set_device_parameter", %{
            "track" => 0,
            "device" => 1,
            "parameter" => 2,
            "value" => 0.5
          })
        end)

      scripted_trace(sink, [{"/live/device/get/parameter/value_string", [0, 1, 2, "50 %"]}])

      assert {:ok, message} = Task.await(call)
      assert message == "Set parameter 2 of device 1 on track 0 to 0.5 — it now reads '50 %'"
    end
  end

  describe "list_browser_items and the straggler on its address" do
    setup :osc_sink

    test "results from another category are refused, not presented", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("list_browser_items", %{
            "category" => "audio_effects",
            "filter" => "reverb"
          })
        end)

      trace =
        scripted_trace(sink, [
          {"/live/browser/get/items",
           ["instruments", "reverb", "ok", 1, 1, "Operator", "Instruments/Operator", "query:1"]},
          {"/live/browser/get/items",
           ["instruments", "reverb", "ok", 1, 1, "Operator", "Instruments/Operator", "query:1"]}
        ])

      assert {:error, message} = Task.await(call)
      assert message =~ "the browser search for audio_effects"
      assert message =~ "run the search again"
      refute message =~ "Operator"
      assert count_queries(trace, "/live/browser/get/items") == 2
    end

    # The echo is verified before the decode fun ever runs, so a stale *error*
    # envelope is rejected rather than reported as this search's failure — the
    # same call `load_outcome/2` makes.
    test "an error envelope about another search is stale, not this search's failure", %{
      sink: sink
    } do
      call =
        Task.async(fn ->
          Handlers.call("list_browser_items", %{
            "category" => "audio_effects",
            "filter" => "reverb"
          })
        end)

      scripted_trace(sink, [
        {"/live/browser/get/items", ["samples", "reverb", "error", "Unknown category: samples"]},
        {"/live/browser/get/items", ["samples", "reverb", "error", "Unknown category: samples"]}
      ])

      assert {:error, message} = Task.await(call)
      assert message =~ "the browser search for audio_effects"
      refute message =~ "Unknown category"
    end

    test "an error envelope about this search is still relayed in Live's words", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("list_browser_items", %{
            "category" => "audio_effects",
            "filter" => "reverb"
          })
        end)

      scripted_trace(sink, [
        {"/live/browser/get/items",
         ["audio_effects", "reverb", "error", "Browser category unavailable"]}
      ])

      assert Task.await(call) == {:error, "Browser category unavailable"}
    end

    test "a correctly echoed search reads exactly as it did before the check", %{sink: sink} do
      call =
        Task.async(fn ->
          Handlers.call("list_browser_items", %{
            "category" => "audio_effects",
            "filter" => "reverb"
          })
        end)

      trace =
        scripted_trace(sink, [
          {"/live/browser/get/items",
           [
             "audio_effects",
             "reverb",
             "ok",
             1,
             1,
             "Reverb",
             "Audio Effects/Reverb",
             "query:AudioFx#Reverb"
           ]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "Reverb"
      assert message =~ "query:AudioFx#Reverb"

      # max_results rides the request and is deliberately absent from the echo.
      assert {"/live/browser/get/items", ["audio_effects", "reverb", 25]} in trace
    end
  end

  describe "get_clip_slots reads every scene name in one reply" do
    setup :osc_sink

    # One track, two scenes: `track_data` answers 3 + 5 × 2 values for it, and
    # the scene names then arrive as one bulk reply that echoes nothing at all —
    # which is why the count it was read against stands in for the echo check.
    @track_data ["Drums", 1, 0, 1, 0, "Loop", "", 4.0, 0.0, 0, 0, 0, 0]

    test "a reply carrying the wrong number of names is reissued", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_clip_slots", %{}) end)

      trace =
        scripted_trace(sink, [
          {"/live/song/get/num_tracks", [1]},
          {"/live/song/get/num_scenes", [2]},
          {"/live/song/get/track_data", @track_data},
          {"/live/song/get/scenes/name", ["Intro"]},
          {"/live/song/get/scenes/name", ["Intro", "Verse"]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "2 scene(s): 0 \"Intro\", 1 \"Verse\""

      assert count_queries(trace, "/live/song/get/scenes/name") == 2
      assert count_queries(trace, "/live/scene/get/name") == 0
    end

    test "a second disagreement says re-read the grid rather than guessing", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_clip_slots", %{}) end)

      scripted_trace(sink, [
        {"/live/song/get/num_tracks", [1]},
        {"/live/song/get/num_scenes", [2]},
        {"/live/song/get/track_data", @track_data},
        {"/live/song/get/scenes/name", ["Intro"]},
        {"/live/song/get/scenes/name", ["Intro"]}
      ])

      assert {:error, message} = Task.await(call)
      assert message =~ "did not carry 2 names"
      assert message =~ "get_clip_slots"
      refute message =~ "Intro"
    end

    test "the matching reply is read straight through, one query for the lot", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("get_clip_slots", %{}) end)

      trace =
        scripted_trace(sink, [
          {"/live/song/get/num_tracks", [1]},
          {"/live/song/get/num_scenes", [2]},
          {"/live/song/get/track_data", @track_data},
          {"/live/song/get/scenes/name", ["Intro", "Verse"]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "Track 0 \"Drums\" (MIDI)"
      assert message =~ "Loop"

      assert count_queries(trace, "/live/song/get/scenes/name") == 1
      assert count_queries(trace, "/live/scene/get/name") == 0
    end
  end

  describe "show_view" do
    setup :osc_sink

    # /live/view/show_view never replies and a name Live rejects is only logged
    # inside Live, so the wire is the only place these can be checked at all.
    # All six are exercised because three of them (Arranger, Browser, bare
    # Detail) have never been sent by Seshat before — the follow cam only ever
    # used Session and the two Detail children.
    @views [
      {"Browser", "Live's browser"},
      {"Arranger", "Arrangement view"},
      {"Session", "Session view"},
      {"Detail", "the detail panel"},
      {"Detail/Clip", "the clip editor"},
      {"Detail/DeviceChain", "the device chain"}
    ]

    for {view, label} <- @views do
      test "sends #{view} and reports it as #{label}" do
        view = unquote(view)
        label = unquote(label)

        assert {:ok, msg} = Handlers.call("show_view", %{"view" => view})
        assert msg =~ label
        assert_receive {:osc_out, "/live/view/show_view", [^view]}
      end
    end

    # The enum is the only thing standing between a misspelled pane and a silent
    # no-op inside Live, so the "nothing was sent" half is proved here, where a
    # transport exists. "Arrangement" is the name a user would say.
    test "an unknown view never reaches the wire" do
      assert {:error, message} = Handlers.call("show_view", %{"view" => "Arrangement"})
      assert message =~ "Invalid parameters for show_view"
      refute_receive {:osc_out, _, _}
    end

    # @views above is hand-maintained; this tripwire is derived straight from
    # the schema so a seventh enum value (Open question 1 coming back "Live
    # renamed a pane") can't add a `Definitions` enum entry without a matching
    # `view_label/1` clause. Without this, the gap is invisible until runtime:
    # validation passes the new value through and `do_call/2` raises
    # FunctionClauseError inside `view_label/1`. Same pattern as
    # `grid_quantization/1`'s "covers exactly the grids the tool schema
    # offers" test.
    test "covers exactly the views the tool schema offers" do
      offered =
        Seshat.Tools.Definitions.all()
        |> Enum.find(&(&1.name == "show_view"))
        |> get_in([:parameters, :properties, "view", :enum])

      for view <- offered do
        assert {:ok, _msg} = Handlers.call("show_view", %{"view" => view}),
               "show_view offers #{inspect(view)} but view_label/1 has no clause"
      end
    end
  end

  describe "hide_view's enum" do
    # The hide_view and get_view_state do_call clauses aren't driven through
    # Handlers.call/2 anywhere in this file, for the same reason delete_device
    # and bypass_device aren't: both read Live back over Transport.query, which
    # needs a live Ableton. The pure halves are covered instead — the enum here,
    # the summary below.

    # hide_view's enum is narrower than show_view's on purpose (only Browser and
    # Detail measurably hide), but its replies still go through view_label/1, and
    # that function is only proved total against show_view's six above. A name
    # offered by hide_view alone would raise FunctionClauseError at runtime, on a
    # path no repository test can execute.
    test "is a subset of show_view's, so view_label/1 covers it" do
      offered = fn name ->
        Seshat.Tools.Definitions.all()
        |> Enum.find(&(&1.name == name))
        |> get_in([:parameters, :properties, "view", :enum])
      end

      assert offered.("hide_view") == ["Browser", "Detail"]

      for view <- offered.("hide_view") do
        assert view in offered.("show_view"),
               "hide_view offers #{inspect(view)}, which show_view's tested enum doesn't cover"
      end
    end
  end

  describe "get_view_state's queried views" do
    # @view_names drives which panes get_view_state reads and is a third
    # hand-maintained copy of the same six names as show_view's enum — with no
    # tripwire if it drifts. A dropped or renamed entry leaves the visibility
    # map missing a key, and main_view_line(nil, false) has no clause: a
    # FunctionClauseError instead of a graceful failure. Same shape as
    # hide_view's subset test above, but set equality rather than a subset,
    # since get_view_state means to cover every pane show_view can show.
    test "matches show_view's enum exactly" do
      offered =
        Seshat.Tools.Definitions.all()
        |> Enum.find(&(&1.name == "show_view"))
        |> get_in([:parameters, :properties, "view", :enum])

      assert Enum.sort(Handlers.view_names()) == Enum.sort(offered)
    end
  end

  describe "view_state_summary/1" do
    # Live's panes overlap rather than partition, so this formatter is where the
    # six flags become one honest sentence: the main view is *derived* from the
    # Session/Arranger pair, and the detail panel's tab from the Detail/* pair.
    defp visibility(overrides) do
      Map.merge(
        %{
          "Browser" => false,
          "Arranger" => false,
          "Session" => true,
          "Detail" => false,
          "Detail/Clip" => false,
          "Detail/DeviceChain" => false
        },
        overrides
      )
    end

    test "reports Session as the main view" do
      summary = Handlers.view_state_summary(visibility(%{}))
      assert summary =~ "Main view: Session."
    end

    test "reports Arrangement as the main view, in the user's word for it" do
      summary = Handlers.view_state_summary(visibility(%{"Session" => false, "Arranger" => true}))

      assert summary =~ "Main view: Arrangement."
      refute summary =~ "Arranger"
    end

    test "reports the browser open and closed" do
      assert Handlers.view_state_summary(visibility(%{"Browser" => true})) =~
               "Live's browser: open."

      assert Handlers.view_state_summary(visibility(%{})) =~ "Live's browser: closed."
    end

    test "names the detail panel's active tab" do
      assert Handlers.view_state_summary(visibility(%{"Detail" => true, "Detail/Clip" => true})) =~
               "Detail panel: open, showing the clip editor."

      assert Handlers.view_state_summary(
               visibility(%{"Detail" => true, "Detail/DeviceChain" => true})
             ) =~ "Detail panel: open, showing the device chain."
    end

    # Detail/Clip and Detail/DeviceChain are measured mutually exclusive (only
    # one tab active at a time), so this read should be impossible too — same
    # rule as the Session/Arranger disagreement below: say so rather than pick
    # a tab that wasn't reported.
    test "states the uncertainty when Detail/Clip and Detail/DeviceChain both read true" do
      summary =
        Handlers.view_state_summary(
          visibility(%{"Detail" => true, "Detail/Clip" => true, "Detail/DeviceChain" => true})
        )

      assert summary =~
               "Detail panel: open, but Live reports both the clip editor and the device chain active."
    end

    test "reports the detail panel closed, and says nothing about a tab" do
      summary = Handlers.view_state_summary(visibility(%{}))

      assert summary =~ "Detail panel: closed."
      refute summary =~ "clip editor"
      refute summary =~ "device chain"
    end

    # Measured never to happen (2026-07-31: the panel is open with neither tab
    # flagged in no reading taken), but the formatter must not invent a tab it
    # wasn't told about.
    test "reports the detail panel open without naming a tab when neither flag is set" do
      assert Handlers.view_state_summary(visibility(%{"Detail" => true})) ==
               "Main view: Session. Live's browser: closed. Detail panel: open."
    end

    # Session and Arranger measured strictly complementary, so this read should
    # be impossible — which is exactly why the formatter must say so rather than
    # pick the likelier half. A guess rendered in the same confident sentence as
    # a real reading is the failure this whole tool exists to remove.
    test "states the uncertainty when Session and Arranger disagree with reality" do
      both = Handlers.view_state_summary(visibility(%{"Session" => true, "Arranger" => true}))
      assert both =~ "Live reports both Session and Arrangement visible."
      refute both =~ "Main view:"

      neither = Handlers.view_state_summary(visibility(%{"Session" => false}))
      assert neither =~ "Live reports neither Session nor Arrangement visible."
      refute neither =~ "Main view:"
    end

    test "renders one line, in main view / browser / detail order" do
      summary =
        Handlers.view_state_summary(
          visibility(%{"Browser" => true, "Detail" => true, "Detail/Clip" => true})
        )

      assert summary ==
               "Main view: Session. Live's browser: open. " <>
                 "Detail panel: open, showing the clip editor."
    end
  end

  describe "format_browser_items/2" do
    # The do_call clauses for list_browser_items/load_device aren't tested here:
    # they go through Transport.query, which needs a live Ableton.
    test "formats name/path/uri triples one per line" do
      triples = [
        "Operator",
        "",
        "query:Instruments#Operator",
        "808 Drifter",
        "Bass/808 & Sub",
        "query:Sounds#Bass:FileId_5200"
      ]

      result = Handlers.format_browser_items(triples, 2)

      assert result =~ "2 match(es)"
      assert result =~ "Operator — uri: query:Instruments#Operator"
      assert result =~ "808 Drifter [Bass/808 & Sub] — uri: query:Sounds#Bass:FileId_5200"
      refute result =~ "refine the filter"
    end

    test "flags truncation when total exceeds what was returned" do
      triples = ["Operator", "", "query:Instruments#Operator"]

      result = Handlers.format_browser_items(triples, 87)

      assert result =~ "Showing 1 of 87 matches"
      assert result =~ "refine the filter"
    end

    test "returns a friendly message when there are no matches" do
      result = Handlers.format_browser_items([], 0)

      assert result =~ "No matching browser items"
      refute result =~ "uri:"
    end

    test "ignores a trailing partial triple" do
      triples = ["Operator", "", "query:Instruments#Operator", "Truncated"]

      result = Handlers.format_browser_items(triples, 2)

      refute result =~ "Truncated"
    end
  end

  describe "format_catalog_entries/3" do
    defp entry(overrides) do
      Map.merge(
        %{
          uri: "query:Sounds#Bass:FileId_5200",
          uris: ["query:Sounds#Bass:FileId_5200"],
          name: "808 Drifter.adg",
          categories: ["sounds"],
          paths: ["Bass/808 & Sub"],
          tags: ["808 Bass", "Punchy", "Sub"],
          tag_source: :ableton,
          description: nil,
          use_count: 0,
          last_loaded_at: nil
        },
        overrides
      )
    end

    test "leads with the tags, since they are what the model picks on" do
      result = Handlers.format_catalog_entries([entry(%{})], 1, [])

      assert result =~ "1 match(es)"

      assert result =~
               "808 Drifter.adg — 808 Bass, Punchy, Sub [Bass/808 & Sub] " <>
                 "(query:Sounds#Bass:FileId_5200)"
    end

    test "says so when an item has no tags at all" do
      result = Handlers.format_catalog_entries([entry(%{tags: [], paths: [""]})], 1, [])

      assert result =~ "808 Drifter.adg — no tags (query:Sounds#Bass:FileId_5200)"
    end

    test "lists every place Live files a preset, as one result" do
      # A folded preset keeps all its locations: which devices can play it is
      # real information for choosing, and it is still one sound, not four.
      result =
        Handlers.format_catalog_entries(
          [
            entry(%{
              name: "Sweet Lead.adg",
              tags: ["Lead"],
              paths: ["Analog/Synth Lead", "Operator/Synth Lead", "Synth Lead"]
            })
          ],
          1,
          []
        )

      assert result =~
               "Sweet Lead.adg — Lead [Analog/Synth Lead · Operator/Synth Lead · Synth Lead]"

      assert result =~ "1 match(es)"
    end

    test "a truncated result offers the tags that would narrow it" do
      # The vocabulary is per-machine, so the reply is the only honest place to
      # advertise it — and a truncated result is where the model needs it.
      result =
        Handlers.format_catalog_entries(
          [entry(%{})],
          127,
          [{"Analog", 40}, {"FM", 22}, {"Evolving", 18}]
        )

      assert result =~
               "Showing 1 of 127 matches — top tags among them: Analog (40), FM (22), " <>
                 "Evolving (18). Add one as a tag to narrow."
    end

    test "falls back to generic advice when there are no narrowing tags" do
      result = Handlers.format_catalog_entries([entry(%{})], 42, [])

      assert result =~ "Showing 1 of 42 matches — narrow the query or add a tag"
    end

    test "a search that found nothing routes the model to tags that would work" do
      # The recovery the ≥1 tag filter is predicated on: one wasted call, then a
      # retry against named tags rather than another guess.
      result =
        Handlers.format_catalog_entries([], 0, %{
          query: "guitar",
          query_matches: 187,
          category: nil,
          category_matches: nil,
          narrowing_tags: [{"Snappy", 38}, {"Acoustic", 20}],
          tags: [%{tag: "Warm", matches: 0, nearest: []}]
        })

      assert result =~
               "No catalog matches. Tag 'Warm' matches nothing in this library. Query 'guitar' " <>
                 "alone matches 187. Real tags on those: Snappy (38), Acoustic (20) — retry " <>
                 "with one of them rather than abandoning the search."
    end

    test "a search that found nothing names the tag that killed it" do
      result =
        Handlers.format_catalog_entries([], 0, %{
          query: "bass",
          query_matches: 412,
          category: nil,
          category_matches: nil,
          narrowing_tags: [],
          tags: [
            %{tag: "Warm", matches: 0, nearest: [{"Warmth", 12}, {"Warp", 4}]},
            %{tag: "Analog", matches: 638, nearest: []}
          ]
        })

      assert result =~
               "No catalog matches. Tag 'Warm' matches nothing in this library — nearest real " <>
                 "tags: Warmth (12), Warp (4). 'Analog' alone matches 638. Query 'bass' alone " <>
                 "matches 412. Drop the query down to just the kind of sound, or search with " <>
                 "fewer tags."

      assert result =~ "reindex_library"
    end

    test "when every constraint matches alone, it says the combination is the problem" do
      result =
        Handlers.format_catalog_entries([], 0, %{
          query: "bass",
          query_matches: 412,
          category: "drums",
          category_matches: 88,
          narrowing_tags: [{"Kick", 22}, {"Sub", 19}],
          tags: [%{tag: "Analog", matches: 638, nearest: []}]
        })

      assert result =~ "'Analog' alone matches 638."
      assert result =~ "Query 'bass' alone matches 412."
      assert result =~ "Category 'drums' alone matches 88."

      # Why it failed and what to send next are separate things the model needs;
      # neither should swallow the other.
      assert result =~
               "Every constraint matches something on its own, so it is the combination that " <>
                 "fails. Real tags on those: Kick (22), Sub (19) — retry with one of them"
    end

    test "a tag with no near neighbours is still named" do
      result =
        Handlers.format_catalog_entries([], 0, %{
          query: nil,
          query_matches: nil,
          category: nil,
          category_matches: nil,
          narrowing_tags: [],
          tags: [%{tag: "Zzz", matches: 0, nearest: []}]
        })

      assert result =~ "Tag 'Zzz' matches nothing in this library."
      refute result =~ "nearest real tags"
      refute result =~ "Query"
    end

    test "an empty catalog gets no diagnosis to report" do
      # search_library reports the unbuilt catalog before it ever formats a
      # result, so this is only the belt-and-braces path.
      result = Handlers.format_catalog_entries([], 0, [])

      assert result ==
               "No catalog matches. If the catalog has never been built, run " <>
                 "reindex_library."
    end

    # The 2026-07-28 validation run had "No 'Warm' tag exists in your library"
    # relayed verbatim to a musician who never asked about tags. The steering
    # text is for the model's next search; the marker says so where the text is,
    # rather than in the tool description far from the point of use.
    test "a diagnosis marks itself model-internal" do
      result =
        Handlers.format_catalog_entries([], 0, %{
          query: "guitar",
          query_matches: 187,
          category: nil,
          category_matches: nil,
          narrowing_tags: [{"Snappy", 38}],
          tags: [%{tag: "Warm", matches: 0, nearest: []}]
        })

      assert result =~ "present results musically; don't mention tags to the user"
    end

    test "a truncated result with facets marks its tag advice model-internal" do
      result = Handlers.format_catalog_entries([entry(%{})], 127, [{"Analog", 40}])

      assert result =~ "Add one as a tag to narrow."
      assert result =~ "present results musically; don't mention tags to the user"
    end

    test "a complete result has nothing to leak, so carries no marker" do
      refute Handlers.format_catalog_entries([entry(%{})], 1, []) =~ "don't mention tags"
    end

    test "a truncated result without facets names no tags, so carries no marker" do
      refute Handlers.format_catalog_entries([entry(%{})], 42, []) =~ "don't mention tags"
    end

    test "an empty catalog carries no marker — there is no diagnosis to misread" do
      refute Handlers.format_catalog_entries([], 0, []) =~ "don't mention tags"
    end
  end

  describe "reindex_library reply" do
    test "reports the library's real tag vocabulary" do
      # Where the model learns the local tags, exactly when they change.
      assert Handlers.format_reindex_summary(%{
               items: 5795,
               tagged: 5760,
               distinct_tags: 214,
               top_tags: [{"One Shot", 2483}, {"Punchy", 861}]
             }) ==
               "Reindexed the sound catalog: 5795 item(s), 5760 of them tagged by Ableton. " <>
                 "214 distinct tags — most common: One Shot (2483), Punchy (861), … " <>
                 "search_library is ready."
    end

    test "a catalog with no tags at all says nothing about tags" do
      result =
        Handlers.format_reindex_summary(%{
          items: 3,
          tagged: 0,
          distinct_tags: 0,
          top_tags: []
        })

      assert result ==
               "Reindexed the sound catalog: 3 item(s), 0 of them tagged by Ableton. " <>
                 "search_library is ready."
    end

    # The failure nothing else would ever mention: search works all session, and
    # the loss only shows up as an empty library after the next restart.
    test "a reindex that could not be saved says so, and says what to do" do
      result =
        Handlers.format_reindex_summary(%{
          items: 3,
          tagged: 0,
          distinct_tags: 0,
          top_tags: [],
          persisted: {:error, :enospc}
        })

      assert result =~ "Reindexed the sound catalog: 3 item(s)"
      assert result =~ "could not be saved to disk (:enospc)"
      assert result =~ "newly indexed results will be lost when Seshat restarts"
      assert result =~ "an older saved catalog may be restored instead"
      assert result =~ "run reindex_library again"
    end

    test "a saved reindex says nothing about saving" do
      result =
        Handlers.format_reindex_summary(%{
          items: 3,
          tagged: 0,
          distinct_tags: 0,
          top_tags: [],
          persisted: :ok
        })

      assert result ==
               "Reindexed the sound catalog: 3 item(s), 0 of them tagged by Ableton. " <>
                 "search_library is ready."
    end
  end

  describe "search_library" do
    # The undo wrap runs before the catalog is even consulted, so this needs a
    # socket now. The catalog assertions below are unchanged.
    setup :osc_sink

    test "explains itself when the catalog has never been built" do
      # The catalog is not started in the test env, so this is exactly the
      # first-run case a user hits.
      assert {:error, msg} = Handlers.call("search_library", %{"query" => "bass"})

      assert msg =~ "empty"
      assert msg =~ "reindex_library"
    end
  end

  # The clause's own wiring — which reply shape a search resolves to — is not
  # covered by formatting these by hand. It is all ETS, so it costs nothing to
  # drive the real dispatch. The catalog is started under its real name because
  # that is the table the handler reads.
  describe "search_library against a populated catalog" do
    setup :osc_sink

    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "seshat-handlers-catalog-#{System.unique_integer([:positive])}"
        )

      path = Path.join(root, "catalog.json")
      db_dir = Path.join(root, "ableton-db")
      db_path = Path.join(db_dir, "Live-files-12300.db")
      File.mkdir_p!(db_dir)
      File.write!(db_path, "mtime marker")
      File.touch!(db_path, {{2020, 1, 1}, {0, 0, 0}})

      server =
        start_supervised!({Seshat.Library.Catalog, path: path, ableton_db_dir: db_dir})

      _ = :sys.get_state(server)

      {:ok, _summary} =
        GenServer.call(
          server,
          {:replace,
           [
             catalog_entry("Nylon Guitar.adg", "q:1", ["Acoustic", "Soft"]),
             catalog_entry("Steel Guitar.adg", "q:2", ["Acoustic", "Bright"]),
             catalog_entry("Glass Pad.adg", "q:3", ["Pad"])
           ]}
        )

      on_exit(fn -> File.rm_rf(root) end)

      %{catalog_path: path, catalog_server: server, db_path: db_path}
    end

    test "a zero-result search comes back diagnosed, not merely empty" do
      # 'Warm' is not a tag here, so the ≥1 filter zeroes the search — and the
      # reply has to make the retry obvious rather than ending the thread.
      assert {:ok, reply} =
               Handlers.call("search_library", %{"query" => "guitar", "tags" => ["Warm"]})

      assert reply =~ "Tag 'Warm' matches nothing in this library."
      assert reply =~ "Query 'guitar' alone matches 2."
      assert reply =~ "Real tags on those: Bright (1), Soft (1)"
    end

    test "a search that matches comes back as a listing, with no diagnosis" do
      assert {:ok, reply} = Handlers.call("search_library", %{"query" => "guitar"})

      assert reply =~ "2 match(es)"
      assert reply =~ "Nylon Guitar.adg — Acoustic, Soft"
      refute reply =~ "matches nothing"
      refute reply =~ "Catalog freshness notice"
    end

    test "a truncated search offers the tags that would narrow it" do
      assert {:ok, reply} =
               Handlers.call("search_library", %{"query" => "guitar", "max_results" => 1})

      assert reply =~ "Showing 1 of 2 matches — top tags among them:"
    end

    test "a stale catalog returns results and tells the model to offer a warned reindex", %{
      db_path: db_path
    } do
      File.touch!(db_path, {{2100, 1, 1}, {0, 0, 0}})

      assert {:ok, reply} = Handlers.call("search_library", %{"query" => "guitar"})

      assert reply =~ "2 match(es)"
      assert reply =~ "Ableton's library has changed since this catalog was built"
      assert reply =~ "offer to run reindex_library"
      assert reply =~ "up to a minute"
      assert reply =~ "Live's UI may be temporarily unresponsive"
      assert reply =~ "get confirmation"
    end

    test "a missing saved catalog returns in-memory results with rebuild guidance", %{
      catalog_path: catalog_path
    } do
      File.rm!(catalog_path)

      assert {:ok, reply} = Handlers.call("search_library", %{"query" => "guitar"})

      assert reply =~ "2 match(es)"
      assert reply =~ "saved catalog is missing"
      assert reply =~ "results exist only in the current Seshat process"
      assert reply =~ "offer to run reindex_library"
    end

    test "an unavailable Ableton database does not spoil offline search", %{db_path: db_path} do
      File.rm!(db_path)

      assert {:ok, reply} = Handlers.call("search_library", %{"query" => "guitar"})

      assert reply =~ "2 match(es)"
      refute reply =~ "Catalog freshness notice"
    end

    test "a busy Catalog writer cannot delay or take down the ETS search", %{
      catalog_server: server
    } do
      :ok = :sys.suspend(server)

      try do
        started_at = System.monotonic_time(:millisecond)

        assert {:ok, reply} = Handlers.call("search_library", %{"query" => "guitar"})

        assert System.monotonic_time(:millisecond) - started_at < 1_000
        assert reply =~ "2 match(es)"
        refute reply =~ "Catalog freshness notice"
      after
        :ok = :sys.resume(server)
      end
    end
  end

  defp catalog_entry(name, uri, tags) do
    %{
      uri: uri,
      uris: [uri],
      name: name,
      categories: ["sounds"],
      paths: ["Test"],
      tags: tags,
      tag_source: :ableton,
      description: nil,
      use_count: 0,
      last_loaded_at: nil
    }
  end

  describe "chain_label/1" do
    # The whole reason the device formatters take a chain descriptor instead of
    # a bare integer: return 0 and track 0 are different objects, and rendering
    # one as the other would be a *wrong* reply rather than a vague one.
    test "the three index spaces never collide" do
      assert Handlers.chain_label({:track, 0}) == "track 0"
      assert Handlers.chain_label({:return, 0}) == "return track 0"
      assert Handlers.chain_label(:master) =~ "master track"
    end

    test "the master names itself the way Live 12 labels it on screen" do
      assert Handlers.chain_label(:master) =~ "Main in Live 12"
    end
  end

  describe "load_outcome/2" do
    # Transport correlates replies by address alone, so a load abandoned by an
    # earlier timeout can answer the next load on the same address. On a getter
    # that costs a wrong reading; on a load it would record the wrong URI, steer
    # by another chain's device index, and claim a device landed where it didn't.
    test "accepts a reply that echoes the return index and uri it was sent" do
      reply = [1, "query:AudioFx#Reverb", "ok", "B-Reverb", "Reverb", 0]

      assert Handlers.load_outcome(reply, [1, "query:AudioFx#Reverb"]) ==
               {:loaded, ["B-Reverb", "Reverb", 0]}
    end

    test "rejects a reply carrying another return's index as stale" do
      reply = [0, "query:AudioFx#Reverb", "ok", "A-Reverb", "Reverb", 0]

      assert Handlers.load_outcome(reply, [1, "query:AudioFx#Reverb"]) == :stale
    end

    test "rejects a reply carrying another uri as stale" do
      reply = [1, "query:AudioFx#Delay", "ok", "B-Delay", "Delay", 0]

      assert Handlers.load_outcome(reply, [1, "query:AudioFx#Reverb"]) == :stale
    end

    # The error envelope is as forgeable by a straggler as the success one, and a
    # stale error would report a failure that never happened to this call.
    test "rejects a mismatched error envelope as stale rather than reporting it" do
      reply = [0, "query:AudioFx#Reverb", "error", "Return track 0 does not exist"]

      assert Handlers.load_outcome(reply, [1, "query:AudioFx#Reverb"]) == :stale
    end

    test "reports a matched error envelope as a remote error" do
      reply = [1, "query:AudioFx#Reverb", "error", "Return track 1 does not exist"]

      assert Handlers.load_outcome(reply, [1, "query:AudioFx#Reverb"]) ==
               {:remote_error, "Return track 1 does not exist"}
    end

    test "matches the master reply, which echoes only the uri" do
      assert Handlers.load_outcome(["query:AudioFx#EQ", "ok", "EQ Eight", 0], ["query:AudioFx#EQ"]) ==
               {:loaded, ["EQ Eight", 0]}

      assert Handlers.load_outcome(["query:AudioFx#Other", "ok", "EQ Eight", 0], [
               "query:AudioFx#EQ"
             ]) == :stale
    end

    test "treats a reply too short to carry the echo as unexpected, not a match" do
      assert Handlers.load_outcome(["query:AudioFx#EQ"], [1, "query:AudioFx#EQ"]) == :unexpected
      assert Handlers.load_outcome([], ["query:AudioFx#EQ"]) == :unexpected
    end

    test "treats an unreadable payload as unexpected" do
      reply = [1, "query:AudioFx#Reverb", "maybe", "Reverb"]

      assert Handlers.load_outcome(reply, [1, "query:AudioFx#Reverb"]) == :unexpected
    end

    # The regular-track load echoes the same two fields, and is the busiest of the
    # three paths — an ordinary load_device call goes through it — so it is the
    # likeliest place for a straggler to be picked up, not the least.
    test "guards the regular-track load, whose echo has the same shape" do
      assert Handlers.load_outcome([2, "query:Synths#Operator", "ok", "Operator", 0], [
               2,
               "query:Synths#Operator"
             ]) == {:loaded, ["Operator", 0]}

      assert Handlers.load_outcome([5, "query:Synths#Operator", "ok", "Operator", 0], [
               2,
               "query:Synths#Operator"
             ]) == :stale
    end

    # An older installed fork replies without the device index. That is a shorter
    # payload, not a mismatched echo, and the caller still needs to tell the two
    # apart to keep its self-diagnosing message.
    test "keeps the older fork's index-less reply distinguishable from a stale one" do
      assert Handlers.load_outcome([2, "query:Synths#Operator", "ok", "Operator"], [
               2,
               "query:Synths#Operator"
             ]) == {:loaded, ["Operator"]}
    end
  end

  describe "format_device_chain/4" do
    # The do_call clauses for the device tools aren't tested here: they go
    # through Transport.query, which needs a live Ableton.
    # The type ints are Live's own, measured 2026-07-31: an instrument reports 1
    # and an audio effect reports 2, not the reverse. Reading them the wrong way
    # round is what made every chain call its instruments audio effects, so this
    # fixture uses the values Live actually sends for an Analog and a Reverb.
    test "formats one line per device with index, type label, and class" do
      result =
        Handlers.format_device_chain(
          {:track, 0},
          ["Analog", "Reverb"],
          [1, 2],
          ["InstrumentVector", "Reverb"]
        )

      assert result =~ "2 device(s) on track 0"
      assert result =~ ~s{Device 0 "Analog" — instrument (InstrumentVector)}
      assert result =~ ~s{Device 1 "Reverb" — audio effect (Reverb)}
    end

    test "labels MIDI effects and unknown types" do
      result =
        Handlers.format_device_chain({:track, 1}, ["Arpeggiator", "Weird"], [4, 9], ["Arp", "X"])

      assert result =~ "MIDI effect"
      assert result =~ "type 9"
    end

    test "explains an empty chain and points at load_device" do
      result = Handlers.format_device_chain({:track, 2}, [], [], [])

      assert result =~ "No devices on track 2"
      assert result =~ "load_device"
    end

    test "a return chain says return track, never track" do
      result = Handlers.format_device_chain({:return, 0}, ["Reverb"], [1], ["Reverb"])

      assert result =~ "1 device(s) on return track 0"
      refute result =~ "on track 0"
    end

    test "an empty return chain explains that its sends are silent" do
      result = Handlers.format_device_chain({:return, 1}, [], [], [])

      assert result =~ "No devices on return track 1"
      assert result =~ "every send into it is silent"
      assert result =~ "target: 'return'"
    end

    test "the master chain names the master, not a numbered track" do
      result = Handlers.format_device_chain(:master, ["EQ Eight"], [1], ["Eq8"])

      assert result =~ "1 device(s) on the master track"
      refute result =~ "track 0"
    end

    test "an empty master chain says the mix passes through untouched" do
      assert Handlers.format_device_chain(:master, [], [], []) =~ "passes through untouched"
    end
  end

  describe "parse_device_chain/1" do
    test "splits the flat tail into parallel name/type/class lists" do
      assert {:ok, {names, types, classes}} =
               Handlers.parse_device_chain([2, "Reverb", 1, "Reverb", "Delay", 1, "Delay"])

      assert names == ["Reverb", "Delay"]
      assert types == [1, 1]
      assert classes == ["Reverb", "Delay"]
    end

    test "an empty chain is a legitimate answer, not an error" do
      assert {:ok, {[], [], []}} = Handlers.parse_device_chain([0])
    end

    test "rejects a tail that isn't a whole number of triples" do
      assert {:error, message} = Handlers.parse_device_chain([1, "Reverb", 1])

      assert message =~ "declared 1 device(s) but sent 2 value(s)"
      assert message =~ "mix abletonosc.install"
    end

    # The count and the tail length can disagree while the tail is still a
    # whole number of triples — a truncated datagram is exactly that shape.
    test "rejects a triple count that disagrees with the declared count" do
      assert {:error, message} =
               Handlers.parse_device_chain([2, "Reverb", 1, "Reverb"])

      assert message =~ "declared 2 device(s) but sent 3 value(s)"
    end

    test "rejects a reply that doesn't start with a count" do
      assert {:error, message} = Handlers.parse_device_chain(["Reverb", 1, "Reverb"])

      assert message =~ "does not start with a device count"
    end
  end

  describe "parse_device_parameters/1" do
    test "splits the flat tail into parallel name/value/min/max lists" do
      assert {:ok, {device_name, names, values, mins, maxes}} =
               Handlers.parse_device_parameters([
                 "Reverb",
                 2,
                 "Device On",
                 1.0,
                 0.0,
                 1.0,
                 "Dry/Wet",
                 0.3,
                 0.0,
                 1.0
               ])

      assert device_name == "Reverb"
      assert names == ["Device On", "Dry/Wet"]
      assert values == [1.0, 0.3]
      assert mins == [0.0, 0.0]
      assert maxes == [1.0, 1.0]
    end

    test "rejects a tail that isn't a whole number of quadruples" do
      assert {:error, message} =
               Handlers.parse_device_parameters(["Reverb", 1, "Device On", 1.0, 0.0])

      assert message =~ "declared 1 parameter(s) but sent 3 value(s)"
    end

    test "rejects a quadruple count that disagrees with the declared count" do
      assert {:error, message} =
               Handlers.parse_device_parameters(["Reverb", 2, "Device On", 1.0, 0.0, 1.0])

      assert message =~ "declared 2 parameter(s) but sent 4 value(s)"
    end

    test "rejects a reply missing its device name and count" do
      assert {:error, message} = Handlers.parse_device_parameters([1.0, 0.0, 1.0])

      assert message =~ "does not start with a device name"
    end
  end

  describe "device_out_of_range_error/3" do
    # The delete_device / bypass_device do_call clauses aren't tested here: both
    # lead with a guarded Transport read, which needs a live Ableton.
    test "names the real index range and prints the chain" do
      result = Handlers.device_out_of_range_error({:track, 2}, 3, ["Operator", "Reverb"])

      assert result =~ "2 device(s) on track 2 (indices 0–1)"
      assert result =~ "there is no device 3"
      assert result =~ "Chain: 0: Operator, 1: Reverb."
    end

    test "an empty chain gets its own message" do
      result = Handlers.device_out_of_range_error({:track, 0}, 0, [])

      assert result =~ "no devices on track 0"
      assert result =~ "nothing to delete (asked for device 0)"
      assert result =~ "get_track_devices"
    end

    test "a return chain is never reported as a regular track" do
      result = Handlers.device_out_of_range_error({:return, 0}, 2, ["Reverb"])

      assert result =~ "on return track 0"
      refute result =~ "on track 0"
    end

    test "the master is never reported as a numbered track" do
      assert Handlers.device_out_of_range_error(:master, 1, []) =~ "on the master track"
    end
  end

  describe "deleted_device_reply/3" do
    test "names the deleted device and re-indexes what is left" do
      result =
        Handlers.deleted_device_reply({:track, 2}, 1, ["Operator", "Compressor", "Reverb"])

      assert result =~ "Deleted 'Compressor' (device 1) from track 2"
      assert result =~ "Remaining chain: 0: Operator, 1: Reverb"
      assert result =~ "shifted down by one"
    end

    test "says so when the last device is gone" do
      result = Handlers.deleted_device_reply({:track, 0}, 0, ["Reverb"])

      assert result =~ "Deleted 'Reverb' (device 0) from track 0"
      assert result =~ "device chain is now empty"
      refute result =~ "Remaining chain"
    end

    test "a return delete says return track" do
      result = Handlers.deleted_device_reply({:return, 0}, 0, ["Reverb"])

      assert result =~ "from return track 0"
      refute result =~ "from track 0"
    end

    test "a master delete names the master" do
      assert Handlers.deleted_device_reply(:master, 0, ["EQ Eight"]) =~ "from the master track"
    end
  end

  describe "ensure_on_off_switch/2" do
    test "accepts On/Off case-insensitively" do
      assert :ok = Handlers.ensure_on_off_switch("Reverb", "On")
      assert :ok = Handlers.ensure_on_off_switch("Reverb", "off")
      assert :ok = Handlers.ensure_on_off_switch("Reverb", "ON")
    end

    test "refuses anything else, printing what it actually found" do
      assert {:error, message} = Handlers.ensure_on_off_switch("Weird Rack", "1.0")

      assert message =~ "Parameter 0 of 'Weird Rack' reads '1.0', not On/Off"
      assert message =~ "nothing was changed"
      assert message =~ "get_device_parameters"
    end
  end

  describe "bypass_device replies" do
    test "the off reply says bypassed with settings kept" do
      result = Handlers.bypass_reply("Compressor", {:track, 2}, 1, false)

      assert result == "'Compressor' (device 1 on track 2) is now Off — bypassed, settings kept."
    end

    test "the on reply" do
      assert Handlers.bypass_reply("Compressor", {:track, 2}, 1, true) ==
               "'Compressor' (device 1 on track 2) is now On."
    end

    test "the no-op reply names the unchanged state and claims no change" do
      result = Handlers.bypass_noop_reply("Compressor", {:track, 2}, 1, false)

      assert result =~ "was already Off — nothing to do"
      refute result =~ "is now"
    end

    test "a return's device is never reported as being on a regular track" do
      assert Handlers.bypass_reply("Reverb", {:return, 0}, 0, false) =~
               "(device 0 on return track 0)"

      assert Handlers.bypass_noop_reply("Reverb", {:return, 0}, 0, true) =~ "on return track 0"
    end

    test "the master's device names the master" do
      assert Handlers.bypass_reply("EQ Eight", :master, 0, true) =~ "on the master track"
    end
  end

  describe "format_device_parameters/7" do
    test "formats one line per parameter with value and range" do
      result =
        Handlers.format_device_parameters(
          {:track, 0},
          1,
          "Analog",
          ["Device On", "Filter Freq"],
          [1.0, 0.8500000238418579],
          [0.0, 0.0],
          [1.0, 1.0]
        )

      assert result =~ ~s{Device 1 "Analog" on track 0 — 2 parameter(s)}
      assert result =~ "0. Device On = 1.0 (range 0.0–1.0)"
      assert result =~ "1. Filter Freq = 0.85 (range 0.0–1.0)"
    end

    test "leaves integer values untouched" do
      result = Handlers.format_device_parameters({:track, 0}, 0, "Op", ["Mode"], [3], [0], [7])

      assert result =~ "0. Mode = 3 (range 0–7)"
    end

    test "a return's device is located on the return, not on track N" do
      result =
        Handlers.format_device_parameters({:return, 1}, 0, "Reverb", ["Dry/Wet"], [0.3], [0.0], [
          1.0
        ])

      assert result =~ ~s{Device 0 "Reverb" on return track 1}
      refute result =~ "on track 1"
    end

    test "the master's device is located on the master" do
      result =
        Handlers.format_device_parameters(:master, 0, "EQ Eight", ["Gain"], [0.5], [0.0], [1.0])

      assert result =~ "on the master track"
    end
  end

  describe "parse_clip_notes/1" do
    # The get_clip_notes do_call clause itself isn't tested here: it goes
    # through Transport.query, which needs a live Ableton.
    test "chunks the flat reply tail into one map per note" do
      fields = [36, 0.0, 0.5, 100, false, 43, 0.5, 0.25, 90, true]

      assert {:ok, notes} = Handlers.parse_clip_notes(fields)

      assert notes == [
               %{pitch: 36, start_time: 0.0, duration: 0.5, velocity: 100, mute: false},
               %{pitch: 43, start_time: 0.5, duration: 0.25, velocity: 90, mute: true}
             ]
    end

    test "accepts the float velocities Live 11+ can send" do
      assert {:ok, [note]} = Handlers.parse_clip_notes([60, 0.0, 1.0, 99.5, 0])
      assert note.velocity == 99.5
    end

    test "treats an integer mute flag as a boolean" do
      assert {:ok, [note]} = Handlers.parse_clip_notes([60, 0.0, 1.0, 100, 1])
      assert note.mute == true
    end

    test "an empty tail is an empty clip, not an error" do
      assert {:ok, []} = Handlers.parse_clip_notes([])
    end

    test "fails loudly when the tail isn't a whole number of notes" do
      assert {:error, msg} = Handlers.parse_clip_notes([60, 0.0, 1.0, 100])

      assert msg =~ "4 value(s)"
      assert msg =~ "not a whole number of notes"
    end
  end

  describe "format_clip_notes/5" do
    defp note(overrides) do
      Map.merge(
        %{pitch: 60, start_time: 0.0, duration: 1.0, velocity: 100, mute: false},
        overrides
      )
    end

    test "formats one line per note with the note name beside the pitch" do
      notes = [
        note(%{pitch: 36, start_time: 0.0, duration: 0.5}),
        note(%{pitch: 43, start_time: 0.5, duration: 0.25, velocity: 90})
      ]

      result = Handlers.format_clip_notes(1, 0, "Bassline", 4.0, notes)

      assert result =~ ~s{Clip "Bassline" on track 1, slot 0 — 4.0 beats, 2 note(s):}
      assert result =~ "C2 (36)"
      assert result =~ "start=0.0"
      assert result =~ "dur=0.5"
      assert result =~ "vel=100"
      assert result =~ "G2 (43)"
      refute result =~ "[muted]"
    end

    test "flags muted notes" do
      result = Handlers.format_clip_notes(0, 0, "Drums", 4.0, [note(%{mute: true})])

      assert result =~ "[muted]"
    end

    test "sorts by start time, then pitch, so chords read as blocks" do
      notes = [
        note(%{pitch: 67, start_time: 1.0}),
        note(%{pitch: 64, start_time: 0.0}),
        note(%{pitch: 60, start_time: 0.0})
      ]

      [_header, _blank | lines] =
        Handlers.format_clip_notes(0, 0, "Chords", 4.0, notes) |> String.split("\n")

      assert Enum.map(lines, &(&1 |> String.trim() |> String.split(" ") |> hd())) ==
               ["C4", "E4", "G4"]
    end

    test "an empty clip is a success, not an error" do
      result = Handlers.format_clip_notes(2, 1, "Empty", 8.0, [])

      assert result =~ ~s{Clip "Empty" on track 2, slot 1 — 8.0 beats, no notes}
      assert result =~ "the clip exists but is empty"
    end
  end

  describe "parse_track_data/3" do
    # The get_clip_slots do_call clause itself isn't tested here: it goes
    # through Transport.query, which needs a live Ableton. This exercises the
    # pure chunking of the flat track_data reply.
    #
    # Per track, with 2 scenes: name, has_midi_input, is_foldable, then
    # has_clip x2, clip.name x2, clip.length x2, is_playing x2,
    # is_recording x2 = 13 values. Empty slots carry nil for clip.* values.
    test "chunks the flat reply into one map per track, empty slots as nil" do
      values =
        ["Drums", true, false] ++
          [true, false] ++
          ["Beat A", nil] ++
          [4.0, nil] ++
          [true, nil] ++
          [false, nil] ++
          ["Vox", false, false] ++
          [false, true] ++
          [nil, "Take 3"] ++ [nil, 16.0] ++ [nil, false] ++ [nil, true]

      assert {:ok, [drums, vox]} = Handlers.parse_track_data(values, 2, 2)

      assert drums == %{
               name: "Drums",
               midi?: true,
               group?: false,
               slots: [
                 %{name: "Beat A", length: 4.0, playing?: true, recording?: false},
                 nil
               ]
             }

      assert vox.name == "Vox"
      assert vox.midi? == false
      assert [nil, %{name: "Take 3", length: 16.0, playing?: false, recording?: true}] = vox.slots
    end

    test "treats integer flags as booleans" do
      values = ["Bass", 1, 0] ++ [1] ++ ["Line"] ++ [8.0] ++ [0] ++ [0]

      assert {:ok, [bass]} = Handlers.parse_track_data(values, 1, 1)

      assert bass.midi? == true
      assert bass.group? == false
      assert [%{name: "Line", length: 8.0, playing?: false, recording?: false}] = bass.slots
    end

    test "fails loudly when the reply length doesn't match tracks x scenes" do
      assert {:error, msg} = Handlers.parse_track_data(["Drums", true, false], 2, 2)

      assert msg =~ "3 value(s)"
      assert msg =~ "expected 26"
      assert msg =~ "track_data"
    end
  end

  describe "format_clip_slots/2" do
    defp grid_track(overrides) do
      Map.merge(%{name: "Track", midi?: true, group?: false, slots: []}, overrides)
    end

    defp slot(overrides) do
      Map.merge(%{name: "Clip", length: 4.0, playing?: false, recording?: false}, overrides)
    end

    test "lists scenes with indices, then one block per track" do
      scenes = ["Intro", "Verse", "Chorus", ""]

      tracks = [
        grid_track(%{
          name: "Drums",
          slots: [
            slot(%{name: "Beat A", playing?: true}),
            slot(%{name: "Beat B", length: 8.0}),
            nil,
            nil
          ]
        }),
        grid_track(%{name: "Bass", slots: [nil, nil, nil, nil]}),
        grid_track(%{
          name: "Vox",
          midi?: false,
          slots: [nil, nil, slot(%{name: "Take 3", length: 16.0, recording?: true}), nil]
        })
      ]

      result = Handlers.format_clip_slots(scenes, tracks)

      assert result =~ ~s{4 scene(s): 0 "Intro", 1 "Verse", 2 "Chorus", 3 ""}
      assert result =~ ~s{Track 0 "Drums" (MIDI):}
      assert result =~ ~s{slot 0: "Beat A" — 4.0 beats [playing]}
      assert result =~ ~s{slot 1: "Beat B" — 8.0 beats}
      assert result =~ "slots 2-3: empty"
      assert result =~ ~s{Track 1 "Bass" (MIDI): all 4 slot(s) empty}
      assert result =~ ~s{Track 2 "Vox" (audio):}
      assert result =~ ~s{slot 2: "Take 3" — 16.0 beats [recording]}
      assert result =~ "slots 0-1, 3: empty"
    end

    test "labels group tracks and a single empty slot without a range" do
      tracks = [
        grid_track(%{name: "All Drums", group?: true, slots: [slot(%{name: "Row"}), nil]})
      ]

      result = Handlers.format_clip_slots(["A", "B"], tracks)

      assert result =~ ~s{Track 0 "All Drums" (group):}
      assert result =~ "slot 1: empty"
      refute result =~ "slots 1"
    end

    test "prints (unnamed) for clips with empty names" do
      tracks = [grid_track(%{slots: [slot(%{name: ""})]})]

      result = Handlers.format_clip_slots(["A"], tracks)

      assert result =~ "slot 0: (unnamed) — 4.0 beats"
      refute result =~ ~s{""  —}
    end

    test "a recording clip shows only [recording], not [playing] too" do
      tracks = [grid_track(%{slots: [slot(%{playing?: true, recording?: true})]})]

      result = Handlers.format_clip_slots(["A"], tracks)

      assert result =~ "[recording]"
      refute result =~ "[playing]"
    end
  end

  describe "record_length_beats/3" do
    # The record_clip clause itself isn't tested here: every guard goes through
    # Transport.query, which needs a live Ableton. This is the one piece of it
    # that is pure — and the one whose being wrong produces a clip of the wrong
    # length rather than an error.
    test "a bar is the signature's beats when the beat is a quarter note" do
      assert Handlers.record_length_beats(8, 4, 4) == 32.0
      assert Handlers.record_length_beats(4, 3, 4) == 12.0
      assert Handlers.record_length_beats(1, 7, 4) == 7.0
    end

    # record_length counts Live song-time beats (quarter notes), not signature
    # beats, so two bars of 6/8 is six quarter notes rather than twelve.
    test "eighth-note signatures are converted to quarter-note beats" do
      assert Handlers.record_length_beats(2, 6, 8) == 6.0
      assert Handlers.record_length_beats(1, 7, 8) == 3.5
    end

    test "half-note signatures and fractional bars" do
      assert Handlers.record_length_beats(2, 2, 2) == 8.0
      assert Handlers.record_length_beats(0.5, 4, 4) == 2.0
    end

    test "always returns a float, so the OSC argument is never an integer" do
      assert is_float(Handlers.record_length_beats(8, 4, 4))
    end
  end

  describe "record_length_from/2" do
    defp song(overrides \\ %{}) do
      Map.merge(
        %{
          tempo: 120.0,
          time_sig_numerator: 4,
          time_sig_denominator: 4,
          is_playing: false,
          root_note: 0,
          scale_name: "Major",
          groove_amount: 0.0,
          swing_amount: 0.16
        },
        overrides
      )
    end

    test "a known signature converts bars to beats" do
      assert Handlers.record_length_from(8, song()) == {:ok, 32.0}

      assert Handlers.record_length_from(
               2,
               song(%{time_sig_numerator: 6, time_sig_denominator: 8})
             ) ==
               {:ok, 6.0}
    end

    # An open-ended take needs no signature at all, so it must keep working
    # against a mirror that couldn't read one.
    test "no bars is open-ended regardless of the signature" do
      assert Handlers.record_length_from(nil, song()) == {:ok, nil}
      assert Handlers.record_length_from(nil, song(%{time_sig_numerator: nil})) == {:ok, nil}

      assert Handlers.record_length_from(
               nil,
               song(%{time_sig_numerator: nil, time_sig_denominator: nil})
             ) == {:ok, nil}
    end

    # Without the guard this is an ArithmeticError inside the tool call — a
    # crash where a refusal belongs, and the refusal has to say how to recover.
    test "an unknown numerator refuses rather than crashing" do
      assert {:error, message} = Handlers.record_length_from(4, song(%{time_sig_numerator: nil}))

      assert message =~ "time signature isn't known"
      assert message =~ "refresh: true"
      assert message =~ "nothing was recorded"
    end

    test "an unknown denominator refuses too" do
      assert {:error, message} =
               Handlers.record_length_from(4, song(%{time_sig_denominator: nil}))

      assert message =~ "time signature isn't known"
    end

    test "the refusal names the bars actually asked for" do
      assert {:error, message} = Handlers.record_length_from(16, song(%{time_sig_numerator: nil}))

      assert message =~ "16-bar"
    end
  end

  describe "record_clip validation" do
    # Only the transport-free error path: a bad `bars` value never reaches
    # Ableton — same precedent as "set_clip_properties validation" above.
    # Everything else in record_clip's guard chain queries Ableton and belongs
    # in the smoke test.
    #
    # Since `bars` gained `minimum: 0.01`, the central schema validator in
    # `Handlers.call/2` catches these before `ensure_bars/1` does, so the
    # message is the schema one. `ensure_bars/1` stays as a belt, but its error
    # branch is now unreachable through `call/2` — `bars` is either absent or
    # already known to be a number ≥ 0.01 — so nothing below exercises it, and
    # no test here can.
    test "rejects a zero bars count before touching Ableton" do
      assert {:error, message} =
               Handlers.call("record_clip", %{"track" => 0, "clip_slot" => 0, "bars" => 0})

      assert message =~ "- bars: must be at least 0.01"
      assert message =~ "got 0"
    end

    test "rejects a negative bars count before touching Ableton" do
      assert {:error, message} =
               Handlers.call("record_clip", %{"track" => 0, "clip_slot" => 0, "bars" => -4})

      assert message =~ "- bars: must be at least 0.01"
      assert message =~ "got -4"
    end

    test "rejects a non-numeric bars value before touching Ableton" do
      assert {:error, message} =
               Handlers.call("record_clip", %{"track" => 0, "clip_slot" => 0, "bars" => "four"})

      assert message =~ "- bars: must be a number"
      assert message =~ ~s(got "four")
    end
  end

  # The one guard in record_clip's chain that had no coverage at all, which is
  # how it shipped 2026-07-29 refusing every call for ten months.
  #
  # `will_record_on_start` was read as "would firing this slot record?" and used
  # to gate the fire. It isn't that: measured 2026-08-03 on Live 12.4.3, it
  # returns `False` on an armed MIDI track with an empty slot that
  # `/live/clip_slot/fire` then records immediately — and stays `False` with the
  # transport stopped or playing and `session_record` off or on. So a `false`
  # must reach the *reply*, never the control flow. `bars` is omitted throughout:
  # that is the one path where `record_length/1` short-circuits without reading
  # `State.song()`, leaving a chain made purely of OSC the sink can answer.
  describe "record_clip and the unreliable will_record_on_start reading" do
    setup :osc_sink

    test "a false reading still fires, and is disclosed in the reply", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("record_clip", %{"track" => 2, "clip_slot" => 0}) end)

      # Indexed getters must echo the indices they were asked about or
      # `query_echoed/4` rejects the reply, so these are arg lists rather than
      # the bare `T`/`F` an index-free song property answers with. In order:
      # has_clip 0 (slot empty), arm 1 (already armed), will_record **0**, then
      # the post-fire echo — has_clip 1, is_recording 1.
      trace = guarded_trace(sink, [[2, 0, 0], [2, 1], [2, 0, 0], [2, 0, 1], [2, 0, 1]])

      assert {:ok, message} = Task.await(call)

      assert {"/live/clip_slot/fire", [2, 0]} in trace,
             "a false will_record_on_start must not stop the fire"

      assert message =~ "Recording into track 2, slot 0 until stop_recording."
      assert message =~ "might not capture input"
      assert message =~ "fired anyway"
      assert message =~ "check the track's input routing"
    end

    test "a true reading fires with no input caveat in the reply", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("record_clip", %{"track" => 2, "clip_slot" => 0}) end)
      trace = guarded_trace(sink, [[2, 0, 0], [2, 1], [2, 0, 1], [2, 0, 1], [2, 0, 1]])

      assert {:ok, message} = Task.await(call)

      assert {"/live/clip_slot/fire", [2, 0]} in trace
      refute message =~ "might not capture input"
      refute message =~ "input routing"
    end
  end

  # Measured 2026-08-03 on Live 12.4.3: `has_clip` reads `False` the instant the
  # fire is processed and `True` 99ms later. The echo used to take that first
  # `False` at face value and report a take that had already started as
  # "Queued" — provable because it did so even with launch quantization set to
  # None, where there is no boundary to be queued for.
  describe "record_clip echo and the has_clip materialisation race" do
    setup :osc_sink

    test "a clip that appears on the re-read reports recording, not queued", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("record_clip", %{"track" => 2, "clip_slot" => 0}) end)

      # Pre-fire: slot empty, armed, will_record true. Post-fire echo: has_clip
      # **0 then 1** — the race — then is_recording 1.
      trace =
        guarded_trace(sink, [[2, 0, 0], [2, 1], [2, 0, 1], [2, 0, 0], [2, 0, 1], [2, 0, 1]])

      assert {:ok, message} = Task.await(call)

      assert {"/live/clip_slot/fire", [2, 0]} in trace
      assert message =~ "Recording now."
      refute message =~ "Queued"
    end

    # The re-read must not paper over a genuine wait: a take fired into a playing
    # transport has no clip for up to a bar, so `has_clip` stays false across
    # both reads and `is_triggered` is what says it is coming.
    test "a slot with no clip on either read is still reported as queued", %{sink: sink} do
      call = Task.async(fn -> Handlers.call("record_clip", %{"track" => 2, "clip_slot" => 0}) end)

      # has_clip 0, 0 (both reads), then is_triggered 1.
      trace =
        guarded_trace(sink, [[2, 0, 0], [2, 1], [2, 0, 1], [2, 0, 0], [2, 0, 0], [2, 0, 1]])

      assert {:ok, message} = Task.await(call)

      assert {"/live/clip_slot/fire", [2, 0]} in trace
      assert message =~ "Queued"
      refute message =~ "Recording now."
    end
  end

  describe "capture_diff/2" do
    # The capture_midi do_call clause itself isn't tested here: it goes through
    # Transport.query, which needs a live Ableton. This exercises the pure diff
    # of two snapshot_grid/0 results, which is the tool's only evidence that
    # anything was captured (/live/song/capture_midi never replies).
    defp capture_track(name, slots) do
      %{name: name, midi?: true, group?: false, slots: slots}
    end

    defp capture_clip(overrides \\ %{}) do
      Map.merge(%{name: "", length: 4.0, playing?: false, recording?: false}, overrides)
    end

    defp capture_grid(num_scenes, tracks), do: %{num_scenes: num_scenes, tracks: tracks}

    test "reports nothing when the grid is unchanged" do
      grid = capture_grid(2, [capture_track("Keys", [capture_clip(), nil])])

      assert Handlers.capture_diff(grid, grid) == {[], 0}
    end

    test "finds a single newly occupied slot" do
      before_grid = capture_grid(2, [capture_track("Keys", [nil, nil])])

      after_grid =
        capture_grid(2, [
          capture_track("Keys", [nil, capture_clip(%{name: "Keys", length: 8.0, playing?: true})])
        ])

      assert {[clip], 0} = Handlers.capture_diff(before_grid, after_grid)

      assert clip.track_index == 0
      assert clip.track_name == "Keys"
      assert clip.slot_index == 1
      assert clip.clip.length == 8.0
      assert clip.clip.playing? == true
    end

    test "ignores slots that were already occupied" do
      before_grid = capture_grid(1, [capture_track("Keys", [capture_clip(%{name: "Old"})])])
      after_grid = capture_grid(1, [capture_track("Keys", [capture_clip(%{name: "Old"})])])

      assert Handlers.capture_diff(before_grid, after_grid) == {[], 0}
    end

    test "finds new clips on two tracks at once, in track order" do
      before_grid =
        capture_grid(1, [capture_track("Keys", [nil]), capture_track("Drums", [nil])])

      after_grid =
        capture_grid(1, [
          capture_track("Keys", [capture_clip()]),
          capture_track("Drums", [capture_clip()])
        ])

      assert {[first, second], 0} = Handlers.capture_diff(before_grid, after_grid)

      assert {first.track_index, first.track_name} == {0, "Keys"}
      assert {second.track_index, second.track_name} == {1, "Drums"}
    end

    test "counts a clip landing in a scene that didn't exist before" do
      before_grid = capture_grid(1, [capture_track("Keys", [capture_clip(%{name: "Old"})])])

      after_grid =
        capture_grid(2, [capture_track("Keys", [capture_clip(%{name: "Old"}), capture_clip()])])

      assert {[clip], 1} = Handlers.capture_diff(before_grid, after_grid)
      assert clip.slot_index == 1
    end

    test "treats everything as new when the before-grid was empty" do
      before_grid = capture_grid(0, [])
      after_grid = capture_grid(1, [capture_track("Keys", [capture_clip()])])

      assert {[clip], 1} = Handlers.capture_diff(before_grid, after_grid)
      assert clip.track_index == 0
    end
  end

  describe "captured_reply/4" do
    defp captured_clip(overrides \\ %{}) do
      Map.merge(
        %{
          track_index: 0,
          track_name: "Keys",
          slot_index: 1,
          clip: %{name: "", length: 8.0, playing?: false, recording?: false}
        },
        overrides
      )
    end

    test "names the track, slot, length and playing state" do
      reply = Handlers.captured_reply([captured_clip()], 0, 120.0, 120.0)

      assert reply =~ "Captured 1 new clip(s):"
      assert reply =~ ~s{Track 0 "Keys", slot 1: (unnamed) — 8.0 beats}
      refute reply =~ "[playing]"
      refute reply =~ "tempo"
      refute reply =~ "scene"
    end

    test "flags a clip Live started playing, and a clip Live named" do
      clip =
        captured_clip(%{clip: %{name: "Keys", length: 4.0, playing?: true, recording?: false}})

      reply = Handlers.captured_reply([clip], 0, 120.0, 120.0)

      assert reply =~ ~s{"Keys" — 4.0 beats [playing]}
    end

    test "reports an added scene" do
      reply = Handlers.captured_reply([captured_clip()], 1, 120.0, 120.0)

      assert reply =~ "Live added 1 scene(s) to hold it."
    end

    test "reports Live's inferred tempo, rounded to one decimal" do
      reply = Handlers.captured_reply([captured_clip()], 0, 120.0, 97.6543)

      assert reply =~ "Live set the tempo to 97.7 BPM to match the playing (was 120.0)."
    end

    test "one line per clip when several were captured" do
      clips = [captured_clip(), captured_clip(%{track_index: 1, track_name: "Drums"})]

      reply = Handlers.captured_reply(clips, 0, 120.0, 120.0)

      assert reply =~ "Captured 2 new clip(s):"
      assert reply =~ ~s{Track 0 "Keys"}
      assert reply =~ ~s{Track 1 "Drums"}
    end
  end

  describe "nothing_captured_reply/2" do
    test "explains the causes when the tempo didn't move" do
      reply = Handlers.nothing_captured_reply(120.0, 120.0)

      assert reply =~ "no new clip appeared"
      assert reply =~ "armed or monitoring its input"
      assert reply =~ "Arrangement view"
      refute reply =~ "did change the tempo"
    end

    test "a tempo change with no clip is evidence the capture landed elsewhere" do
      reply = Handlers.nothing_captured_reply(120.0, 97.6543)

      assert reply =~ "Live did change the tempo (120.0 → 97.7 BPM), so something *was* captured"
      assert reply =~ "Arrangement view"
    end
  end

  describe "name_captured_clip/2" do
    setup :osc_sink

    test "substitutes the name without a round trip, and fires the rename" do
      clip = captured_clip(%{clip: %{name: "", length: 8.0, playing?: false, recording?: false}})

      named = Handlers.name_captured_clip(clip, "Bass")

      assert named.clip.name == "Bass"
      assert named.track_index == clip.track_index
      assert named.slot_index == clip.slot_index
      assert_receive {:osc_out, "/live/clip/set/name", [0, 1, "Bass"]}
    end

    test "capture_midi's reply prints the model-supplied name" do
      named = Handlers.name_captured_clip(captured_clip(), "Bass")

      reply = Handlers.captured_reply([named], 0, 120.0, 120.0)

      assert reply =~ ~s{"Bass"}
    end
  end

  # No `setup :osc_sink` here, deliberately: with no Transport running, the
  # rename send exits :noproc and maybe_name_clip/3's `catch :exit` has to
  # swallow it (review round 2, finding 2). The old version of this test
  # claimed to cover that while a module-wide `setup_all` kept Transport alive,
  # so the guard was never reached — and the sends went to the real Ableton.
  describe "name_captured_clip/2 with no transport running" do
    test "leaves the clip untouched when capture_midi got no name" do
      clip = captured_clip()

      assert Handlers.name_captured_clip(clip, nil) == clip
    end

    test "still returns the named map when the rename cannot be sent" do
      clip = captured_clip(%{clip: %{name: "", length: 8.0, playing?: false, recording?: false}})

      named = Handlers.name_captured_clip(clip, "Bass")

      assert named.clip.name == "Bass"
      assert named.track_index == clip.track_index
      assert named.slot_index == clip.slot_index
    end
  end

  describe "captured_steer_target/1" do
    test "nil when nothing was captured" do
      assert Handlers.captured_steer_target([]) == nil
    end

    test "picks the first clip, in the track-then-slot order capture_diff/2 produces" do
      clips = [
        captured_clip(%{track_index: 0, slot_index: 3}),
        captured_clip(%{track_index: 1, slot_index: 0})
      ]

      assert Handlers.captured_steer_target(clips) == %{track: 0, slot: 3}
    end
  end

  describe "note_range_args/1" do
    # AbletonOSC's handler raises unless it gets exactly 0 or 4 range args.
    test "sends nothing when no range param was given" do
      assert Handlers.note_range_args(%{"track" => 0, "clip_slot" => 0}) == []
    end

    test "fills in all four when only one range param was given" do
      assert Handlers.note_range_args(%{"start_pitch" => 36}) == [36, 128, 0.0, 9999.0]
    end

    test "coerces integer beat positions to floats" do
      args = Handlers.note_range_args(%{"start_time" => 4, "time_span" => 8})

      assert args == [0, 128, 4.0, 8.0]
    end
  end

  describe "volume_display/1" do
    # Live's fader is not linear and 1.0 is not the ceiling — the whole point of
    # echoing dB is that "set it to full" means 0.85, not 1.0.
    test "0.85 is unity gain" do
      assert Handlers.volume_display(0.85) == "≈ 0 dB"
    end

    test "1.0 is +6 dB, not the maximum the raw value suggests" do
      assert Handlers.volume_display(1.0) == "≈ +6 dB"
    end

    test "0.4 is the bottom of the near-linear range" do
      assert Handlers.volume_display(0.4) == "≈ -18 dB"
    end

    test "below the linear range it gives a bound rather than a wrong number" do
      assert Handlers.volume_display(0.2) == "≈ below -18 dB"
    end

    test "zero is silence" do
      assert Handlers.volume_display(0.0) == "silence"
      assert Handlers.volume_display(0) == "silence"
    end

    test "rounds to one decimal" do
      assert Handlers.volume_display(0.9) == "≈ +2 dB"
      assert Handlers.volume_display(0.5) == "≈ -14 dB"
      assert Handlers.volume_display(0.83) == "≈ -0.8 dB"
    end
  end

  describe "pan_display/1" do
    test "hard left and hard right in Live's own notation" do
      assert Handlers.pan_display(-1.0) == "50L"
      assert Handlers.pan_display(1.0) == "50R"
    end

    test "centre" do
      assert Handlers.pan_display(0.0) == "C"
      assert Handlers.pan_display(0) == "C"
    end

    test "partial pans" do
      assert Handlers.pan_display(-0.5) == "25L"
      assert Handlers.pan_display(0.5) == "25R"
    end

    test "a pan too small to register reads as centre, not 0L" do
      assert Handlers.pan_display(-0.001) == "C"
    end
  end

  describe "send_letter/1" do
    test "send index maps to the letter Live prints on the send" do
      assert Handlers.send_letter(0) == "A"
      assert Handlers.send_letter(1) == "B"
      assert Handlers.send_letter(11) == "L"
    end

    test "past the alphabet it falls back to a number rather than punctuation" do
      assert Handlers.send_letter(26) == "#27"
    end
  end

  describe "format_track_sends/2" do
    test "one line per send, with the letter and the return it feeds" do
      sends = [
        %{index: 0, return: "A-Reverb", value: 0.35},
        %{index: 1, return: "B-Delay", value: 0.0}
      ]

      result = Handlers.format_track_sends(2, sends)

      assert result =~ "2 send(s) on track 2:"
      assert result =~ ~s{send 0 (A) → "A-Reverb": 0.35}
      assert result =~ ~s{send 1 (B) → "B-Delay": 0.0}
    end

    test "no returns means no sends, and says how to make one" do
      result = Handlers.format_track_sends(0, [])

      assert result =~ "no return tracks"
      assert result =~ "create_return_track"
    end
  end

  describe "format_return_tracks/2" do
    defp return(overrides \\ %{}) do
      Map.merge(
        %{index: 0, name: "A-Reverb", volume: 0.85, pan: 0.0, mute: false, solo: false},
        overrides
      )
    end

    defp master(overrides \\ %{}) do
      Map.merge(%{volume: 0.85, pan: 0.0, cue_volume: 0.85}, overrides)
    end

    test "one line per return in send order, then the master" do
      returns = [
        return(),
        return(%{index: 1, name: "B-Delay", volume: 0.7, pan: -0.5})
      ]

      result = Handlers.format_return_tracks(returns, master())

      assert result =~ ~s{Return 0 "A-Reverb" (send A): volume=0.85, pan=0.0}
      assert result =~ ~s{Return 1 "B-Delay" (send B): volume=0.7, pan=-0.5}
      assert result =~ "Master (shown as Main in Live 12): volume=0.85, pan=0.0, cue volume=0.85"
    end

    test "a muted or soloed return is flagged the way a regular track line is" do
      returns = [return(%{mute: true}), return(%{index: 1, name: "B-Delay", solo: true})]

      result = Handlers.format_return_tracks(returns, master())

      assert result =~ ~s{"A-Reverb" (send A): volume=0.85, pan=0.0 [muted]}
      assert result =~ ~s{"B-Delay" (send B): volume=0.85, pan=0.0 [solo]}
    end

    # nil master means the extension never answered, which looks identical to a
    # set with no returns unless it is called out.
    test "a nil master reports the extension as unavailable, not as silence" do
      result = Handlers.format_return_tracks([], nil)

      assert result =~ "unavailable"
      assert result =~ "mix abletonosc.install"
      refute result =~ "volume="
    end

    test "an answering extension with no returns still reports the master" do
      result = Handlers.format_return_tracks([], master(%{volume: 0.6}))

      assert result =~ "No return tracks"
      assert result =~ "create_return_track"
      assert result =~ "Master (shown as Main in Live 12): volume=0.6"
    end

    # A guessed fader position reads as real, and the model does relative moves
    # off it — "turn the delay down a bit" from a fictional 0.85 is an increase.
    test "a return whose volume query went unanswered says so instead of guessing" do
      returns = [return(), return(%{index: 1, name: "B-Delay", volume: nil})]

      result = Handlers.format_return_tracks(returns, master())

      assert result =~ ~s{Return 0 "A-Reverb" (send A): volume=0.85}
      assert result =~ ~s{Return 1 "B-Delay" (send B): volume unknown}
      refute result =~ ~s{"B-Delay" (send B): volume=}
    end

    test "an unanswered return pan is stated, not centred" do
      result = Handlers.format_return_tracks([return(%{pan: nil})], master())

      assert result =~ ~s{"A-Reverb" (send A): volume=0.85, pan unknown}
      refute result =~ ~s{"A-Reverb" (send A): volume=0.85, pan=}
    end

    # One marker for the pair, matching format_track_line/1: two unanswered flag
    # queries are one lost refresh, not two facts worth reporting separately.
    test "unanswered mute/solo gets one shared marker, never a silent false" do
      result = Handlers.format_return_tracks([return(%{mute: nil, solo: nil})], master())

      assert result =~ "[mute/solo unknown]"
      refute result =~ "[muted]"
    end

    test "an unanswered master pan or cue level is stated, not guessed" do
      result = Handlers.format_return_tracks([], master(%{pan: nil, cue_volume: nil}))

      assert result =~ "pan unknown"
      assert result =~ "cue unknown"
    end

    # A fabricated "Return 1" is worse than a guessed number: the user may try
    # to address the return by that name.
    test "a return whose name query went unanswered says so instead of guessing" do
      returns = [return(%{index: 1, name: nil, volume: 0.7})]

      result = Handlers.format_return_tracks(returns, master())

      assert result =~ "Return 1 (name unknown) (send B): volume=0.7"
    end
  end

  # The unknown-rendering half of `get_session_state`. The mirror only ever
  # holds `nil` after a refresh that reached Ableton and got silence, which
  # `mix test` cannot reach (testing.md: nothing goes through Transport.query),
  # so these formatters are the whole pure surface of that behaviour.
  describe "format_song_line/1" do
    test "a fully known song renders every field and flags nothing" do
      assert {line, false} = Handlers.format_song_line(song())
      assert line == "120.0 BPM, 4/4, stopped, key: C Major, groove 0.0, swing 0.16"
    end

    test "a playing song says so" do
      assert {line, false} = Handlers.format_song_line(song(%{is_playing: true}))
      assert line =~ "playing"
    end

    test "an all-unknown song names each unknown and flags it" do
      unknown =
        song(%{
          tempo: nil,
          time_sig_numerator: nil,
          time_sig_denominator: nil,
          is_playing: nil,
          root_note: nil,
          scale_name: nil,
          groove_amount: nil,
          swing_amount: nil
        })

      assert {line, true} = Handlers.format_song_line(unknown)

      assert line ==
               "tempo unknown, time signature unknown, playing state unknown, key unknown, " <>
                 "groove unknown, swing unknown"
    end

    # Per field, not per line: one lost tempo reply must not cost the signature.
    test "a known tempo survives an unknown signature" do
      assert {line, true} = Handlers.format_song_line(song(%{time_sig_denominator: nil}))
      assert line =~ "120.0 BPM"
      assert line =~ "time signature unknown"
      refute line =~ "4/"
    end

    test "an unknown tempo leaves the rest intact" do
      assert {line, true} = Handlers.format_song_line(song(%{tempo: nil}))
      assert line =~ "tempo unknown"
      assert line =~ "4/4"
      assert line =~ "key: C Major"
    end

    # Pitch.pitch_class_name(nil) quietly returns "", which would print
    # "key:  Major" and read as a key we just forgot to name.
    test "a nil root note never reaches the pitch namer" do
      assert {line, true} = Handlers.format_song_line(song(%{root_note: nil}))
      assert line =~ "key unknown"
      refute line =~ "key: "
    end

    test "a nil scale name is an unknown key too" do
      assert {line, true} = Handlers.format_song_line(song(%{scale_name: nil}))
      assert line =~ "key unknown"
    end

    # root_note 0 is C, and 0 is not nil — the obvious truthiness bug.
    test "root note zero is C, not unknown" do
      assert {line, false} = Handlers.format_song_line(song(%{root_note: 0}))
      assert line =~ "key: C Major"
    end

    # Raw floats, matching what set_swing_amount and set_groove_amount accept —
    # a percentage here would read back as a number the tools would reject.
    test "groove and swing render as the numbers their setters take" do
      assert {line, false} = Handlers.format_song_line(song(%{groove_amount: 1.3}))
      assert line =~ "groove 1.3"
      assert line =~ "swing 0.16"
    end

    # An install predating the fork pin never answers /live/song/get/swing_amount,
    # so this is the state the reply must be honest about rather than show 0.0.
    test "an unknown swing is stated, not guessed, and flags the line" do
      assert {line, true} = Handlers.format_song_line(song(%{swing_amount: nil}))
      assert line =~ "swing unknown"
      assert line =~ "groove 0.0"
    end

    test "an unknown groove is stated too" do
      assert {line, true} = Handlers.format_song_line(song(%{groove_amount: nil}))
      assert line =~ "groove unknown"
      assert line =~ "swing 0.16"
    end

    # 0.0 is straight/off, and it is not nil — the truthiness bug one field over.
    test "zero groove and zero swing are values, not unknowns" do
      assert {line, false} =
               Handlers.format_song_line(song(%{groove_amount: 0.0, swing_amount: 0.0}))

      assert line =~ "groove 0.0"
      assert line =~ "swing 0.0"
    end
  end

  describe "format_track_summary/1" do
    defp mirrored_track(overrides \\ %{}) do
      Map.merge(
        %{index: 0, name: "Drums", volume: 0.85, pan: 0.0, mute: false, solo: false},
        overrides
      )
    end

    test "known tracks render as before and flag nothing" do
      tracks = [mirrored_track(), mirrored_track(%{index: 1, name: "Bass", mute: true})]

      assert {text, false} = Handlers.format_track_summary(tracks)
      assert text =~ ~s{Track 0 "Drums": pan=0.0, volume=0.85}
      assert text =~ ~s{Track 1 "Bass": pan=0.0, volume=0.85 [muted]}
    end

    # An unreachable Ableton presented as a set with no tracks is the exact
    # fabrication this change exists to stop, so the two texts must differ.
    test "an unknown track list is not an empty one" do
      assert {unknown_text, true} = Handlers.format_track_summary(nil)
      assert {empty_text, false} = Handlers.format_track_summary([])

      assert unknown_text =~ "unknown, not empty"
      refute unknown_text =~ "refresh: true"
      assert empty_text =~ "No tracks in current session"
      assert unknown_text != empty_text
    end

    test "a track with only its volume unknown keeps every other field" do
      assert {text, true} = Handlers.format_track_summary([mirrored_track(%{volume: nil})])
      assert text == ~s{Track 0 "Drums": pan=0.0, volume unknown}
    end

    test "an unnamed track is addressed by index rather than a made-up name" do
      assert {text, true} = Handlers.format_track_summary([mirrored_track(%{name: nil})])
      assert text =~ "Track 0 (name unknown): pan=0.0, volume=0.85"
      refute text =~ ~s{"Track 1"}
    end

    test "an unknown pan says so" do
      assert {text, true} = Handlers.format_track_summary([mirrored_track(%{pan: nil})])
      assert text =~ "pan unknown"
    end

    # Two unanswered flag queries are one lost refresh, so they get one marker.
    test "unknown mute and solo collapse into a single marker" do
      assert {text, true} =
               Handlers.format_track_summary([mirrored_track(%{mute: nil, solo: nil})])

      assert text =~ " [mute/solo unknown]"
      refute text =~ "[muted]"
      assert length(String.split(text, "[mute/solo unknown]")) == 2
    end

    test "a known solo still renders alongside an unknown mute" do
      assert {text, true} =
               Handlers.format_track_summary([mirrored_track(%{mute: nil, solo: true})])

      assert text =~ " [solo]"
      assert text =~ " [mute/solo unknown]"
    end

    test "a fully known track list flags nothing even when one track is muted and soloed" do
      assert {_text, false} =
               Handlers.format_track_summary([mirrored_track(%{mute: true, solo: true})])
    end
  end

  # The trailing explanation is asserted here and nowhere else: it is a property
  # of the whole reply, and appending it per formatter would print it twice on a
  # session that is degraded in more than one place.
  describe "format_session_state/5" do
    @explanation "Unknown values mean Ableton did not answer"
    @settling "A structural change is still settling"

    defp known_returns, do: [return(%{volume: 0.7})]

    defp compose(overrides \\ %{}) do
      args =
        Map.merge(
          %{
            song: song(),
            tracks: [mirrored_track()],
            return_tracks: known_returns(),
            master: master(),
            refresh_pending?: false
          },
          overrides
        )

      Handlers.format_session_state(
        args.song,
        args.tracks,
        args.return_tracks,
        args.master,
        args.refresh_pending?
      )
    end

    test "a fully known session gets no trailing explanation" do
      reply = compose()

      assert reply =~ "120.0 BPM, 4/4, stopped, key: C Major"
      assert reply =~ ~s{Track 0 "Drums"}
      assert reply =~ ~s{Return 0 "A-Reverb"}
      assert reply =~ "Master (shown as Main in Live 12): volume=0.85"
      refute reply =~ @explanation
    end

    test "a verified-empty session is still fully known" do
      refute compose(%{tracks: []}) =~ @explanation
    end

    test "an unknown song field triggers the explanation" do
      assert compose(%{song: song(%{tempo: nil})}) =~ @explanation
    end

    test "an unknown track field triggers the explanation" do
      assert compose(%{tracks: [mirrored_track(%{pan: nil})]}) =~ @explanation
    end

    test "an unknown track list triggers the explanation" do
      assert compose(%{tracks: nil}) =~ @explanation
    end

    test "an unknown return name triggers the explanation" do
      assert compose(%{return_tracks: [return(%{name: nil})]}) =~ @explanation
    end

    test "an unknown return volume triggers the explanation" do
      assert compose(%{return_tracks: [return(%{volume: nil})]}) =~ @explanation
    end

    test "an unknown return pan or mute/solo triggers the explanation" do
      assert compose(%{return_tracks: [return(%{pan: nil})]}) =~ @explanation
      assert compose(%{return_tracks: [return(%{mute: nil})]}) =~ @explanation
      assert compose(%{return_tracks: [return(%{solo: nil})]}) =~ @explanation
    end

    # A master whose volume answered but whose pan didn't is *not* the
    # extension-missing case, so it has to be flagged the same way any other
    # lost field is rather than passing as fully known.
    test "an unknown master pan or cue level triggers the explanation" do
      assert compose(%{master: master(%{pan: nil})}) =~ @explanation
      assert compose(%{master: master(%{cue_volume: nil})}) =~ @explanation
    end

    # A reply that says "return/master state unavailable" and explains nothing
    # is the same half-told story as a nil tempo with no explanation.
    test "an unavailable master triggers the explanation" do
      reply = compose(%{master: nil})

      assert reply =~ "unavailable"
      assert reply =~ @explanation
    end

    # The assertion the double-append bug fails.
    test "unknowns in song, tracks and returns produce exactly one explanation" do
      reply =
        compose(%{
          song: song(%{tempo: nil, scale_name: nil}),
          tracks: [mirrored_track(%{volume: nil, mute: nil})],
          return_tracks: [return(%{name: nil, volume: nil})],
          master: nil
        })

      assert length(String.split(reply, @explanation)) == 2
    end

    test "the explanation prevents automatic retry loops" do
      reply = compose(%{tracks: nil})

      assert reply =~ "Do not call get_session_state again automatically"
      refute reply =~ "refresh: true"
      assert reply =~ "AbletonOSC"
    end

    # A read served inside the debounce window is known to be behind on
    # structure. The sentence exists so the reply says so instead of asserting a
    # layout it has reason to doubt — measured 2026-08-01, where three creates
    # and a plain read in one model response returned the pre-burst track list
    # with nothing marking it.
    test "a pending rebuild appends the settling sentence exactly once" do
      reply = compose(%{refresh_pending?: true})

      assert length(String.split(reply, @settling)) == 2
      assert reply =~ "new entries can be absent and deleted entries can still appear"
      assert reply =~ "Do not re-read automatically"
    end

    test "no pending rebuild leaves the reply exactly as it was" do
      settled = compose()

      refute settled =~ @settling
      assert compose(%{refresh_pending?: true}) == settled <> "\n\n" <> settling_sentence()
    end

    # Two different facts — "Ableton didn't answer" and "Ableton answered, we
    # haven't asked yet" — so a reply that is both says both, once each, rather
    # than collapsing them into one hedge.
    test "a degraded and pending reply carries both sentences once each" do
      reply = compose(%{tracks: nil, refresh_pending?: true})

      assert length(String.split(reply, @explanation)) == 2
      assert length(String.split(reply, @settling)) == 2
      assert reply =~ "The track list could not be read from Ableton"
    end

    defp settling_sentence do
      compose(%{refresh_pending?: true})
      |> String.split("\n\n")
      |> List.last()
    end
  end

  # Transport correlates replies by address alone, so the prefix a reply echoes
  # is the only thing on the wire separating this call's answer from one
  # abandoned by an earlier timeout. `correlate_reply/2` is that whole decision,
  # pure and therefore checkable without a socket.
  describe "correlate_reply/2" do
    test "hands back what is behind a matching echo" do
      assert Handlers.correlate_reply([1, 2, "Reverb"], [1, 2]) == {:ok, ["Reverb"]}

      assert Handlers.correlate_reply([1, "Operator", "Reverb"], [1]) ==
               {:ok, ["Operator", "Reverb"]}
    end

    test "rejects a reply that echoes another index" do
      assert Handlers.correlate_reply([3, 2, "Reverb"], [1, 2]) == :stale
      assert Handlers.correlate_reply([1, 5, "Reverb"], [1, 2]) == :stale
    end

    # The `Enum.zip/2` truncation trap, and the reason this function is public:
    # zipping a one-element reply against a two-index request compares one pair,
    # finds it equal, and reports a match having checked nothing.
    test "rejects a reply too short to carry the echo at all" do
      assert Handlers.correlate_reply([1], [1, 2]) == :stale
      assert Handlers.correlate_reply([], [0]) == :stale
    end

    # A float index casts to an int inside Live and echoes back as one, so the
    # reply really is ours — `==` rather than a pin.
    test "matches an integer echo against the float index that was sent" do
      assert Handlers.correlate_reply([1, "Reverb"], [1.0]) == {:ok, ["Reverb"]}
    end

    # The browser echoes strings rather than indices, as `str()` round-trips of
    # what it was sent — identity for the schema-validated strings Seshat sends,
    # so nothing here should be case-folded or trimmed.
    test "compares string echoes verbatim" do
      assert Handlers.correlate_reply(
               ["audio_effects", "reverb", "ok", 1, 1],
               ["audio_effects", "reverb"]
             ) == {:ok, ["ok", 1, 1]}

      assert Handlers.correlate_reply(
               ["audio_effects", "Reverb", "ok", 1, 1],
               ["audio_effects", "reverb"]
             ) == :stale
    end

    test "an empty echo takes the whole reply as payload" do
      assert Handlers.correlate_reply([1, 2, 3], []) == {:ok, [1, 2, 3]}
    end
  end

  describe "unwrap_payload/1" do
    test "an upstream getter's bare value" do
      assert Handlers.unwrap_payload([0.42]) == {:ok, 0.42}
      assert Handlers.unwrap_payload(["A-Reverb"]) == {:ok, "A-Reverb"}
    end

    test "the vendored extension's ok envelope" do
      assert Handlers.unwrap_payload(["ok", 0.85]) == {:ok, 0.85}
    end

    # This is the whole point of the envelope: a bad index answers immediately
    # and distinguishably, instead of the silence that would be indistinguishable
    # from a missing `mix abletonosc.install`.
    test "the vendored extension's error envelope carries the message back" do
      assert Handlers.unwrap_payload(["error", "Return track 4 does not exist"]) ==
               {:error, "Return track 4 does not exist"}
    end

    # A return track named "ok" must not be mistaken for an envelope, and vice
    # versa — the arity is what separates them, not the string.
    test "a value that happens to read like an envelope tag is still a value" do
      assert Handlers.unwrap_payload(["ok"]) == {:ok, "ok"}
      assert Handlers.unwrap_payload(["ok", "error"]) == {:ok, "error"}
    end

    test "anything else is a shape this code can't read, not an answer" do
      assert Handlers.unwrap_payload([]) == :unexpected_shape
      assert Handlers.unwrap_payload(["error", 42]) == :unexpected_shape
      assert Handlers.unwrap_payload([1, 2, 3]) == :unexpected_shape
    end
  end

  # The six sends/returns/master tools each guard Ableton with a
  # `Transport.query/3` before mutating (see handlers.ex), so an automated test
  # of that guard's error path would have to reach a real Ableton. Per
  # .claude/rules/testing.md ("never write tests that reach Transport.query/3
  # — they need a live Ableton and will time out"), that path is exercised by
  # /smoke-test instead, not here — see docs/PLAN_send_levels.md's Testing
  # section, steps 3-7. An earlier version of this suite called these tools
  # directly: on a machine with Live and the return_track.py extension
  # installed and running, the guard answers for real and the calls mutate
  # the open set (creating/deleting return tracks, changing a send or fader)
  # while asserting nothing about the result. That is exactly the failure
  # mode the rule above exists to prevent, so the tests were removed rather
  # than patched.

  # Every clip setter is fire-and-forget, so Live's own rejection of an invalid
  # loop range would be silent. The whole ordering decision therefore lives in
  # this pure function, and this is the only place it can be checked: anything
  # past the static validation in `set_clip_properties` reaches
  # `Transport.query/3` and belongs to /smoke-test.
  describe "clip_property_writes/2" do
    test "looping is written before any loop point" do
      assert {:ok, writes} =
               Handlers.clip_property_writes(
                 %{"loop_start" => 0.0, "loop_end" => 16.0},
                 %{"looping" => true, "loop_start" => 4.0, "loop_end" => 8.0}
               )

      assert [{"looping", 1} | _rest] = writes
    end

    test "looping is written before a single-sided loop point too" do
      assert Handlers.clip_property_writes(
               %{"loop_start" => 0.0, "loop_end" => 16.0},
               %{"looping" => true, "loop_end" => 8.0}
             ) == {:ok, [{"looping", 1}, {"loop_end", 8.0}]}
    end

    # New brace entirely past the old one: writing the start first would leave
    # Live holding start 16.0 against end 8.0.
    test "a brace moving past the old end is written end-first" do
      assert {:ok, writes} =
               Handlers.clip_property_writes(
                 %{"loop_start" => 0.0, "loop_end" => 8.0},
                 %{"loop_start" => 16.0, "loop_end" => 24.0}
               )

      assert writes == [{"loop_end", 24.0}, {"loop_start", 16.0}]
    end

    test "a brace tightening inside the old one is written start-first" do
      assert {:ok, writes} =
               Handlers.clip_property_writes(
                 %{"loop_start" => 0.0, "loop_end" => 16.0},
                 %{"loop_start" => 4.0, "loop_end" => 8.0}
               )

      assert writes == [{"loop_start", 4.0}, {"loop_end", 8.0}]
    end

    test "the marker pair is ordered independently of the loop pair" do
      assert {:ok, writes} =
               Handlers.clip_property_writes(
                 %{
                   "loop_start" => 0.0,
                   "loop_end" => 16.0,
                   "start_marker" => 0.0,
                   "end_marker" => 4.0
                 },
                 %{
                   "loop_start" => 2.0,
                   "loop_end" => 6.0,
                   "start_marker" => 8.0,
                   "end_marker" => 12.0
                 }
               )

      assert writes == [
               {"loop_start", 2.0},
               {"loop_end", 6.0},
               {"end_marker", 12.0},
               {"start_marker", 8.0}
             ]
    end

    test "a single-sided write is validated against the current other side" do
      assert {:error, message} =
               Handlers.clip_property_writes(
                 %{"loop_start" => 0.0, "loop_end" => 8.0},
                 %{"loop_start" => 16.0}
               )

      assert message =~ "loop_start 16.0"
      assert message =~ "current loop_end 8.0"
      assert message =~ "Nothing was set"
    end

    test "a single-sided end write is validated the same way" do
      assert {:error, message} =
               Handlers.clip_property_writes(
                 %{"start_marker" => 4.0, "end_marker" => 8.0},
                 %{"end_marker" => 2.0}
               )

      assert message =~ "end_marker 2.0"
      assert message =~ "current start_marker 4.0"
    end

    test "a single-sided write that stays valid needs no partner" do
      assert Handlers.clip_property_writes(
               %{"loop_start" => 0.0, "loop_end" => 8.0},
               %{"loop_start" => 4.0}
             ) == {:ok, [{"loop_start", 4.0}]}
    end

    test "an inverted pair is rejected before ordering is even considered" do
      assert {:error, message} =
               Handlers.clip_property_writes(%{}, %{"loop_start" => 8.0, "loop_end" => 4.0})

      assert message =~ "loop_start 8.0 is not before loop_end 4.0"
    end

    test "booleans go on the wire as 1/0 and enums as integers" do
      assert {:ok, writes} =
               Handlers.clip_property_writes(%{}, %{
                 "looping" => false,
                 "legato" => true,
                 "warping" => false,
                 "launch_mode" => 2,
                 "launch_quantization" => 5,
                 "warp_mode" => 6
               })

      assert writes == [
               {"looping", 0},
               {"launch_mode", 2},
               {"launch_quantization", 5},
               {"legato", 1},
               {"warp_mode", 6},
               {"warping", 0}
             ]
    end

    # Every non-nil term is truthy in Elixir, so a bare `if` would turn a
    # boolean spelled as `0` into 1 — the opposite of intent. `Validation` now
    # rejects that shape in `call/2`, so this pins the direct
    # caller of the public `clip_property_writes/2`, which does not go through
    # it.
    test "a boolean spelled as 0/1 is not inverted" do
      assert Handlers.clip_property_writes(%{}, %{"looping" => 0, "legato" => 1}) ==
               {:ok, [{"looping", 0}, {"legato", 1}]}
    end

    test "scalars are coerced to floats and appended after the ranges" do
      assert {:ok, writes} =
               Handlers.clip_property_writes(
                 %{"loop_start" => 0.0, "loop_end" => 16.0},
                 %{"velocity_amount" => 1, "gain" => 0, "loop_end" => 8.0}
               )

      assert writes == [{"loop_end", 8.0}, {"velocity_amount", 1.0}, {"gain", 0.0}]
    end

    test "no recognised changes means no writes" do
      assert Handlers.clip_property_writes(%{}, %{}) == {:ok, []}
    end
  end

  # Only the error paths that stop before the first Ableton query: everything
  # past them queries. The undo wrap means these are no longer transport-free —
  # a begin/end pair still goes out — so the sink is what keeps them from
  # exiting, and `refute_receive` on the clip addresses is what still proves the
  # rejection came before anything was set.
  describe "set_clip_properties validation" do
    setup :osc_sink

    test "rejects a call that changes nothing" do
      assert {:error, message} =
               Handlers.call("set_clip_properties", %{"track" => 0, "clip_slot" => 0})

      assert message =~ "Nothing to set"
      assert message =~ "loop_start"
      refute_receive {:osc_out, "/live/clip" <> _, _}
    end

    test "rejects an inverted loop brace before touching Ableton" do
      assert {:error, message} =
               Handlers.call("set_clip_properties", %{
                 "track" => 0,
                 "clip_slot" => 0,
                 "loop_start" => 8.0,
                 "loop_end" => 4.0
               })

      assert message =~ "loop_start 8.0 is not before loop_end 4.0"
      assert message =~ "nothing was set"
      refute_receive {:osc_out, "/live/clip" <> _, _}
    end

    test "rejects inverted play markers before touching Ableton" do
      assert {:error, message} =
               Handlers.call("set_clip_properties", %{
                 "track" => 0,
                 "clip_slot" => 0,
                 "start_marker" => 4.0,
                 "end_marker" => 4.0
               })

      assert message =~ "start_marker 4.0 is not before end_marker 4.0"
      refute_receive {:osc_out, "/live/clip" <> _, _}
    end
  end

  # `read_clip_pair_context/3` collapses to an empty entry list whenever a
  # change touches neither ordered pair, and `read_clip_properties/3`'s
  # `[]` clause exists precisely so that never reaches
  # `Transport.query_batch/2` — which raises on an empty batch. This is that
  # path, live: "looping" alone is a range property but not a pair key, so
  # the pair-context read is empty.
  describe "set_clip_properties in one batch" do
    setup :osc_sink

    test "a change touching neither pair skips the pair-context read without raising", %{
      sink: sink
    } do
      call =
        Task.async(fn ->
          Handlers.call("set_clip_properties", %{
            "track" => 0,
            "clip_slot" => 0,
            "looping" => false
          })
        end)

      trace =
        scripted_trace(sink, [
          {"/live/clip_slot/get/has_clip", [0, 0, 1]},
          {"/live/clip/get/looping", [0, 0, 0]},
          {"/live/clip/get/length", [0, 0, 4.0]}
        ])

      assert {:ok, message} = Task.await(call)
      assert message =~ "looping"
      assert message =~ "clip length is now 4.0 beats"

      # No pair-property getter went out — the pair-context read was skipped
      # rather than reaching Transport with an empty batch.
      assert count_queries(trace, "/live/clip/get/loop_start") == 0
      assert count_queries(trace, "/live/clip/get/loop_end") == 0
      assert count_queries(trace, "/live/clip/get/start_marker") == 0
      assert count_queries(trace, "/live/clip/get/end_marker") == 0
      assert {"/live/clip/set/looping", [0, 0, 0]} in trace
    end
  end

  describe "grid_quantization/1" do
    # These six integers were MEASURED AGAINST A RUNNING LIVE on 2026-07-31 —
    # one clip per enum value, probe notes chosen so each candidate grid lands
    # somewhere distinguishable, read back with /live/clip/get/notes.
    #
    # docs/abletonosc-api-docs.md and the fork's clip.py comment both used to say
    # `5=1/2, 6=1/4, 7=1/8, 8=1/16, 9=1/32`, and every row of that was wrong.
    # Both have since been corrected to match this table. If you are here because
    # some other document disagrees with these numbers, the instrument won: do
    # not "fix" this back. The address never replies, so a wrong integer here is
    # silent everywhere except in Live, where notes land on the wrong grid.
    test "maps every offered grid string to its measured GridQuantization int" do
      assert Handlers.grid_quantization("1/4") == 1
      assert Handlers.grid_quantization("1/8") == 2
      assert Handlers.grid_quantization("1/8T") == 3
      assert Handlers.grid_quantization("1/16") == 5
      assert Handlers.grid_quantization("1/16T") == 6
      assert Handlers.grid_quantization("1/32") == 8
    end

    test "covers exactly the grids the tool schema offers" do
      offered =
        Seshat.Tools.Definitions.all()
        |> Enum.find(&(&1.name == "quantize_clip"))
        |> get_in([:parameters, :properties, "grid", :enum])

      for grid <- offered do
        assert is_integer(Handlers.grid_quantization(grid)),
               "quantize_clip offers grid #{inspect(grid)} but grid_quantization/1 has no clause"
      end
    end
  end

  describe "send_quantize/4" do
    setup :osc_sink

    # The one test this tool cannot ship without. /live/clip/quantize never
    # replies, so a typo'd address or a swapped grid/amount argument order passes
    # grid_quantization/1, passes format_quantize_result/7, passes the Python
    # tripwire in vendored_addresses_test, and then fails silently inside Live.
    # Only the wire shows it.
    #
    # Safe at this layer despite the no-Transport.query/3 rule: send_message/2 is
    # fire-and-forget, so the guards and notes reads are never entered.
    test "puts the address, the measured grid int and a float amount on the wire" do
      assert :ok = Handlers.send_quantize(0, 0, "1/16", 0.5)
      assert_receive {:osc_out, "/live/clip/quantize", [0, 0, 5, 0.5]}
    end

    test "forces float encoding even when the amount arrives as an integer" do
      assert :ok = Handlers.send_quantize(2, 3, "1/8T", 1)
      assert_receive {:osc_out, "/live/clip/quantize", [2, 3, 3, 1.0]}
    end
  end

  # `quantize_clip` reads the notes either side of a fire-and-forget quantize, so
  # the two reads cannot make the same claim when they fail. Before the datagram
  # goes out "nothing further was sent" is true; after it, the mutation is on the
  # wire and may have landed. The tool's `catch :exit` clause has always drawn
  # that line by hand — these pin it for the rejection path, which only became
  # reachable when a correlated `/live/error` started failing a read in
  # milliseconds instead of never.
  #
  # Answering the sink's queries in order is what the no-`Transport.query/3` rule
  # permits (testing.md): nothing waits on Ableton, and the guards *are* the
  # behaviour under test.
  describe "quantize_clip when a read is rejected" do
    setup :osc_sink

    defp reply(sink, address, args) do
      reply_datagram(sink, Message.encode(address, args))
    end

    defp quantize_task do
      Task.async(fn ->
        Handlers.call("quantize_clip", %{
          "track" => 0,
          "clip_slot" => 0,
          "grid" => "1/16",
          "amount" => 1.0
        })
      end)
    end

    defp answer_quantize_guards(sink) do
      assert_receive {:osc_out, "/live/clip_slot/get/has_clip", [0, 0]}
      reply(sink, "/live/clip_slot/get/has_clip", [0, 0, 1])

      assert_receive {:osc_out, "/live/clip/get/is_midi_clip", [0, 0]}
      reply(sink, "/live/clip/get/is_midi_clip", [0, 0, 1])

      assert_receive {:osc_out, "/live/clip/get/name", [0, 0]}
      reply(sink, "/live/clip/get/name", [0, 0, "Keys"])
    end

    # The failure the reviewer of the /live/error work found: the clip survives
    # every guard, the quantize goes out, and only then does the track vanish.
    test "the after-read never claims nothing was sent", %{sink: sink} do
      task = quantize_task()
      answer_quantize_guards(sink)

      assert_receive {:osc_out, "/live/clip/get/notes", [0, 0]}
      reply(sink, "/live/clip/get/notes", [0, 0, 60, 0.0, 1.0, 100, 0])

      assert_receive {:osc_out, "/live/clip/quantize", [0, 0, 5, 1.0]}

      assert_receive {:osc_out, "/live/clip/get/notes", [0, 0]}

      reply(sink, "/live/error", [
        "request",
        "/live/clip/get/notes",
        "Index out of range",
        2,
        0,
        0
      ])

      assert {:error, message} = Task.await(task)

      assert message =~ "Index out of range"
      assert message =~ "The quantize was already sent"
      assert message =~ "get_clip_notes on track 0, slot 0"

      refute message =~ "Nothing further was sent",
             "the quantize datagram was already on the wire: #{message}"
    end

    # The other side of the same line — here the claim is true and must survive.
    test "the before-read still says nothing further was sent", %{sink: sink} do
      task = quantize_task()
      answer_quantize_guards(sink)

      assert_receive {:osc_out, "/live/clip/get/notes", [0, 0]}

      reply(sink, "/live/error", [
        "request",
        "/live/clip/get/notes",
        "Index out of range",
        2,
        0,
        0
      ])

      assert {:error, message} = Task.await(task)

      assert message =~ "Index out of range"
      assert message =~ "Nothing further was sent"
      refute_receive {:osc_out, "/live/clip/quantize", _}, 0
    end
  end

  describe "format_quantize_result/7" do
    # note/1 is the shared builder from "format_clip_notes/5" above.
    test "reports how many of the clip's notes moved, and names the clip" do
      before_notes = [
        note(%{pitch: 60, start_time: 0.09}),
        note(%{pitch: 62, start_time: 1.37}),
        note(%{pitch: 64, start_time: 2.0})
      ]

      after_notes = [
        note(%{pitch: 60, start_time: 0.0}),
        note(%{pitch: 62, start_time: 1.25}),
        note(%{pitch: 64, start_time: 2.0})
      ]

      result =
        Handlers.format_quantize_result(1, 0, "Keys", "1/16", 0.6, before_notes, after_notes)

      assert result =~ ~s{Quantized "Keys" (track 1, slot 0)}
      assert result =~ "2 of 3 note(s) moved toward the 1/16 grid at 60% strength"
      assert result =~ "undo reverses it"
    end

    test "falls back to the indices when the name read failed" do
      result =
        Handlers.format_quantize_result(
          1,
          0,
          nil,
          "1/16",
          1.0,
          [note(%{start_time: 0.09})],
          [note(%{start_time: 0.0})]
        )

      assert result =~ "Quantized the clip in slot 0 on track 1"
      assert result =~ "100% strength"
    end

    test "hedges the no-change case toward a stale AbletonOSC install" do
      notes = [note(%{pitch: 60, start_time: 0.0}), note(%{pitch: 64, start_time: 1.0})]

      result = Handlers.format_quantize_result(0, 0, "Keys", "1/16", 0.5, notes, notes)

      assert result =~ "no note changed"
      assert result =~ "may already sit on the 1/16 grid"
      assert result =~ "mix abletonosc.install"
      refute result =~ "moved toward"
    end

    test "states the merge when same-pitch notes collided on one grid point" do
      before_notes = [
        note(%{pitch: 64, start_time: 2.02, velocity: 100}),
        note(%{pitch: 64, start_time: 2.10, velocity: 110}),
        note(%{pitch: 60, start_time: 0.0})
      ]

      after_notes = [
        note(%{pitch: 64, start_time: 2.0, velocity: 110}),
        note(%{pitch: 60, start_time: 0.0})
      ]

      result =
        Handlers.format_quantize_result(2, 1, "Hats", "1/16", 1.0, before_notes, after_notes)

      assert result =~ "2 of 3 note(s) moved"
      assert result =~ "now has 2 note(s) rather than 3"
      assert result =~ "merged into the note there, keeping the later velocity"
      assert result =~ "Undo restores them"
    end

    test "states the trim when the count held but a note got shorter" do
      before_notes = [
        note(%{pitch: 64, start_time: 2.02, duration: 0.5}),
        note(%{pitch: 64, start_time: 2.40, duration: 0.5})
      ]

      after_notes = [
        note(%{pitch: 64, start_time: 2.0, duration: 0.25}),
        note(%{pitch: 64, start_time: 2.25, duration: 0.5})
      ]

      result =
        Handlers.format_quantize_result(0, 0, "Bass", "1/16", 1.0, before_notes, after_notes)

      assert result =~ "2 of 2 note(s) moved"
      assert result =~ "Some note lengths changed too"
      assert result =~ "trimmed the earlier one"
    end

    test "does not count a note whose start held as moved, when only its duration was trimmed" do
      before_notes = [
        note(%{pitch: 64, start_time: 2.0, duration: 0.5}),
        note(%{pitch: 64, start_time: 2.40, duration: 0.5})
      ]

      after_notes = [
        note(%{pitch: 64, start_time: 2.0, duration: 0.25}),
        note(%{pitch: 64, start_time: 2.25, duration: 0.5})
      ]

      result =
        Handlers.format_quantize_result(0, 0, "Bass", "1/16", 1.0, before_notes, after_notes)

      assert result =~ "1 of 2 note(s) moved"
      assert result =~ "Some note lengths changed too"
      assert result =~ "trimmed the earlier one"
    end

    test "says so rather than inventing a reason when the count grew" do
      result =
        Handlers.format_quantize_result(
          0,
          0,
          "Keys",
          "1/8",
          1.0,
          [note(%{pitch: 60, start_time: 0.09})],
          [note(%{pitch: 60, start_time: 0.0}), note(%{pitch: 62, start_time: 0.5})]
        )

      assert result =~ "quantize is not expected to add notes"
      assert result =~ "get_clip_notes"
    end
  end

  describe "quantize_clip" do
    setup :osc_sink

    # The sink exists only for the undo wrap's begin/end pair — a zero amount is
    # rejected before the first guard, so nothing *else* may reach the wire. The
    # trace assertion is what says so: if this ever grows a clip query, the early
    # return has been lost.
    test "rejects 0% strength before touching Ableton" do
      assert {:error, message} =
               Handlers.call("quantize_clip", %{
                 "track" => 0,
                 "clip_slot" => 0,
                 "grid" => "1/16",
                 "amount" => 0.0
               })

      assert message =~ "0% strength"
      assert message =~ "try 0.5"

      assert [
               {"/live/song/end_undo_step", []},
               {"/live/song/begin_undo_step", []},
               {"/live/song/end_undo_step", []}
             ] = osc_trace()
    end

    test "rejects an integer 0 the same way" do
      assert {:error, message} =
               Handlers.call("quantize_clip", %{
                 "track" => 0,
                 "clip_slot" => 0,
                 "grid" => "1/16",
                 "amount" => 0
               })

      assert message =~ "0% strength"
      refute_receive {:osc_out, "/live/clip" <> _, _}
    end
  end

  describe "unknown tool" do
    test "returns error for unknown tool name" do
      assert {:error, msg} = Handlers.call("nonexistent_tool", %{})
      assert msg =~ "Unknown tool"
    end
  end
end
