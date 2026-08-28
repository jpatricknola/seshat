defmodule Seshat.Eval.RecorderTest do
  use ExUnit.Case, async: true

  alias Seshat.Eval.Fixture
  alias Seshat.Eval.Recorder
  alias Seshat.Eval.Surface

  @base_path Path.expand("../../../priv/routing_eval/surfaces/base-c3096d6.json", __DIR__)

  setup do
    recorder =
      Recorder.new(Surface.load!(@base_path), Fixture.load!("named_tracks_and_reverb"))

    {:ok, recorder: recorder}
  end

  # Drives a list of requests through the pure handler, collecting the replies.
  defp exchange(recorder, requests) do
    Enum.map_reduce(requests, recorder, fn request, state ->
      Recorder.handle(request, state)
    end)
  end

  defp request(id, method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp call(id, name, arguments) do
    request(id, "tools/call", %{"name" => name, "arguments" => arguments})
  end

  describe "the handshake" do
    test "initialize echoes the protocol and carries the snapshot's instructions", %{
      recorder: recorder
    } do
      {[reply], _state} =
        exchange(recorder, [request(1, "initialize", %{"protocolVersion" => "2025-06-18"})])

      assert reply["id"] == 1
      assert reply["result"]["protocolVersion"] == "2025-06-18"
      assert reply["result"]["serverInfo"] == %{"name" => "seshat_eval", "version" => "0.1.0"}
      assert reply["result"]["capabilities"] == %{"tools" => %{}}
      assert reply["result"]["instructions"] == recorder.surface.instructions
    end

    test "a notification gets no reply at all", %{recorder: recorder} do
      {[reply], _state} =
        exchange(recorder, [%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}])

      assert reply == nil
    end

    test "ping answers empty and tools/list serves the snapshot verbatim", %{recorder: recorder} do
      {[ping, list], _state} = exchange(recorder, [request(1, "ping"), request(2, "tools/list")])

      assert ping["result"] == %{}
      assert list["result"]["tools"] == recorder.surface.tools
    end

    test "an unknown method is a JSON-RPC method-not-found", %{recorder: recorder} do
      {[reply], _state} = exchange(recorder, [request(9, "resources/list")])

      assert reply["error"]["code"] == -32_601
      assert reply["error"]["message"] =~ "resources/list"
    end
  end

  describe "tools/call" do
    test "a valid call is answered from the fixture and recorded", %{recorder: recorder} do
      {[reply], state} = exchange(recorder, [call(1, "get_session_state", %{})])

      assert reply["result"]["isError"] == false
      assert [%{"type" => "text", "text" => text}] = reply["result"]["content"]
      assert text =~ "120.0 BPM"

      assert [entry] = state.trace
      assert entry["seq"] == 1
      assert entry["name"] == "get_session_state"
      assert entry["kind"] == "read"
      assert entry["schema_valid"] == true
      assert entry["is_error"] == false
    end

    # `schema_valid` is recorded separately from `is_error` so a report can say
    # "the first call was malformed" without inferring it from reply text.
    test "a schema-invalid call is refused and recorded as invalid", %{recorder: recorder} do
      {[reply], state} = exchange(recorder, [call(1, "set_master_volume", %{"value" => 2.5})])

      assert reply["result"]["isError"] == true
      assert [%{"text" => text}] = reply["result"]["content"]
      assert text =~ "Invalid parameters for set_master_volume"
      assert text =~ "must be at most 1.0 (got 2.5)"

      assert [%{"schema_valid" => false, "is_error" => true}] = state.trace
    end

    # The single most interesting failure this harness can record: the model
    # reaching for a name the surface under test removed.
    test "a tool this surface does not have is a readable tool error", %{recorder: recorder} do
      {[reply], state} = exchange(recorder, [call(1, "set_mixer", %{"target" => "master"})])

      assert reply["result"]["isError"] == true
      assert [%{"text" => text}] = reply["result"]["content"]
      assert text =~ "Unknown tool: set_mixer"

      assert [%{"name" => "set_mixer", "schema_valid" => false}] = state.trace
    end

    test "the trace has one entry per call, in order, numbered from one", %{recorder: recorder} do
      {_replies, state} =
        exchange(recorder, [
          call(1, "get_session_state", %{}),
          call(2, "set_master_volume", %{"value" => 0.7}),
          call(3, "set_return_track_mute", %{"return_track" => 0, "muted" => true})
        ])

      assert Enum.map(state.trace, & &1["seq"]) == [1, 2, 3]

      assert Enum.map(state.trace, & &1["name"]) == [
               "get_session_state",
               "set_master_volume",
               "set_return_track_mute"
             ]

      assert Enum.map(state.trace, & &1["kind"]) == ["read", "mutation", "mutation"]

      assert Enum.map(state.trace, & &1["arguments"]) == [
               %{},
               %{"value" => 0.7},
               %{"return_track" => 0, "muted" => true}
             ]
    end

    test "a call with no arguments key is treated as an empty argument map", %{
      recorder: recorder
    } do
      {[reply], state} =
        exchange(recorder, [request(1, "tools/call", %{"name" => "get_session_state"})])

      assert reply["result"]["isError"] == false
      assert [%{"arguments" => %{}}] = state.trace
    end

    test "a call missing its name is a JSON-RPC error, not a crash", %{recorder: recorder} do
      {[reply], state} =
        exchange(recorder, [request(1, "tools/call", %{"arguments" => %{}})])

      assert reply["error"]["code"] == -32_602
      assert state.trace == []
    end

    test "a call whose arguments decoded to a JSON array is a JSON-RPC error, not a crash", %{
      recorder: recorder
    } do
      {[reply], state} =
        exchange(recorder, [
          request(1, "tools/call", %{"name" => "get_session_state", "arguments" => []})
        ])

      assert reply["error"]["code"] == -32_602
      assert state.trace == []
    end
  end

  describe "Stdio.serve/2" do
    # The real loop, driven through a StringIO group leader: `:stdio` resolves
    # to the group leader, so this exercises the same read/decode/write/append
    # path Claude Code drives, without spawning anything.
    @tag :tmp_dir
    test "answers on stdout and appends one trace line per call", context do
      trace_path = Path.join([context.tmp_dir, "nested", "trace.jsonl"])

      input =
        Enum.map_join(
          [
            request(1, "initialize", %{"protocolVersion" => "2025-06-18"}),
            %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
            call(2, "get_session_state", %{}),
            call(3, "set_master_volume", %{"value" => 0.7})
          ],
          "",
          &(Jason.encode!(&1) <> "\n")
        )

      recorder = Recorder.new(Surface.load!(@base_path), Fixture.load!("named_tracks_and_reverb"))

      # `encoding: :latin1` makes StringIO a byte pipe rather than a character
      # device, which is what a real stdout pipe is. In the default unicode mode
      # it would re-encode whatever it is handed, hiding the very bug this
      # arrangement is here to catch.
      {:ok, io} = StringIO.open(input, encoding: :latin1)

      Task.async(fn ->
        Process.group_leader(self(), io)
        Recorder.Stdio.serve(recorder, trace_path)
      end)
      |> Task.await()

      {_in, out} = StringIO.contents(io)
      replies = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert Enum.map(replies, & &1["id"]) == [1, 2, 3]

      assert replies |> hd() |> get_in(["result", "instructions"]) ==
               recorder.surface.instructions

      lines = trace_path |> File.read!() |> String.split("\n", trim: true)

      assert Enum.map(lines, &Jason.decode!(&1)["name"]) == [
               "get_session_state",
               "set_master_volume"
             ]
    end

    @tag :tmp_dir
    test "an em-dash reaches the client as UTF-8 bytes, not as an escape", context do
      trace_path = Path.join(context.tmp_dir, "trace.jsonl")
      input = Jason.encode!(call(1, "get_clip_notes", %{"track" => 1})) <> "\n"

      recorder = Recorder.new(Surface.load!(@base_path), Fixture.load!("named_tracks_and_reverb"))

      # `encoding: :latin1` makes StringIO a byte pipe rather than a character
      # device, which is what a real stdout pipe is. In the default unicode mode
      # it would re-encode whatever it is handed, hiding the very bug this
      # arrangement is here to catch.
      {:ok, io} = StringIO.open(input, encoding: :latin1)

      Task.async(fn ->
        Process.group_leader(self(), io)
        Recorder.Stdio.serve(recorder, trace_path)
      end)
      |> Task.await()

      {_in, out} = StringIO.contents(io)
      reply = out |> String.trim() |> Jason.decode!()

      assert [%{"text" => text}] = reply["result"]["content"]
      assert text =~ "—"
      refute text =~ "x{2014}"
    end
  end
end
