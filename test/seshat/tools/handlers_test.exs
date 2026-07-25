defmodule Seshat.Tools.HandlersTest do
  use ExUnit.Case, async: false

  alias Seshat.Tools.Handlers

  setup_all do
    start_supervised!(Seshat.OSC.Transport)
    :ok
  end

  describe "set_track_pan" do
    test "returns ok with valid params" do
      assert {:ok, msg} = Handlers.call("set_track_pan", %{"track" => 0, "value" => -1.0})
      assert msg =~ "pan"
      assert msg =~ "track 0"
    end

    test "pans to center" do
      assert {:ok, _msg} = Handlers.call("set_track_pan", %{"track" => 1, "value" => 0.0})
    end
  end

  describe "set_track_volume" do
    test "returns ok with valid params" do
      assert {:ok, msg} = Handlers.call("set_track_volume", %{"track" => 0, "value" => 0.5})
      assert msg =~ "volume"
    end

    test "sets volume to max" do
      assert {:ok, _msg} = Handlers.call("set_track_volume", %{"track" => 2, "value" => 1.0})
    end
  end

  describe "set_track_mute" do
    test "mutes a track" do
      assert {:ok, msg} = Handlers.call("set_track_mute", %{"track" => 0, "muted" => true})
      assert msg =~ "mute"
    end

    test "unmutes a track" do
      assert {:ok, _msg} = Handlers.call("set_track_mute", %{"track" => 0, "muted" => false})
    end
  end

  describe "set_track_solo" do
    test "solos a track" do
      assert {:ok, msg} = Handlers.call("set_track_solo", %{"track" => 0, "soloed" => true})
      assert msg =~ "solo"
    end

    test "unsolos a track" do
      assert {:ok, _msg} = Handlers.call("set_track_solo", %{"track" => 0, "soloed" => false})
    end
  end

  describe "get_session_state" do
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
    # MCP delivers Peri-validated params with atom keys; the Anthropic API
    # delivers string keys. Both must reach the same clause.
    test "accepts atom-keyed params" do
      assert {:ok, msg} = Handlers.call("set_track_pan", %{track: 0, value: -1.0})
      assert msg =~ "pan"
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
  end

  describe "format_browser_items/2" do
    # The do_call clauses for list_browser_items/load_device aren't tested here:
    # they go through Transport.query, which needs a live Ableton.
    test "formats name/uri pairs one per line" do
      pairs = ["Operator", "query:Instruments#Operator", "Analog", "query:Instruments#Analog"]

      result = Handlers.format_browser_items(pairs, 2)

      assert result =~ "2 match(es)"
      assert result =~ "Operator — uri: query:Instruments#Operator"
      assert result =~ "Analog — uri: query:Instruments#Analog"
      refute result =~ "refine the filter"
    end

    test "flags truncation when total exceeds what was returned" do
      pairs = ["Operator", "query:Instruments#Operator"]

      result = Handlers.format_browser_items(pairs, 87)

      assert result =~ "Showing 1 of 87 matches"
      assert result =~ "refine the filter"
    end

    test "returns a friendly message when there are no matches" do
      result = Handlers.format_browser_items([], 0)

      assert result =~ "No matching browser items"
      refute result =~ "uri:"
    end

    test "ignores a dangling name with no uri" do
      pairs = ["Operator", "query:Instruments#Operator", "Truncated"]

      result = Handlers.format_browser_items(pairs, 2)

      refute result =~ "Truncated"
    end
  end

  describe "unknown tool" do
    test "returns error for unknown tool name" do
      assert {:error, msg} = Handlers.call("nonexistent_tool", %{})
      assert msg =~ "Unknown tool"
    end
  end
end
