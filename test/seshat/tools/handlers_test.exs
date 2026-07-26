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
      assert msg =~ "Muted track 0"
    end

    test "unmutes a track" do
      assert {:ok, _msg} = Handlers.call("set_track_mute", %{"track" => 0, "muted" => false})
    end
  end

  describe "set_track_solo" do
    test "solos a track" do
      assert {:ok, msg} = Handlers.call("set_track_solo", %{"track" => 0, "soloed" => true})
      assert msg =~ "Soloed track 0"
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

  describe "format_catalog_entries/2" do
    defp entry(overrides) do
      Map.merge(
        %{
          uri: "query:Sounds#Bass:FileId_5200",
          name: "808 Drifter.adg",
          category: "sounds",
          path: "Bass/808 & Sub",
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
      result = Handlers.format_catalog_entries([entry(%{})], 1)

      assert result =~ "1 match(es)"

      assert result =~
               "808 Drifter.adg — 808 Bass, Punchy, Sub [Bass/808 & Sub] " <>
                 "(query:Sounds#Bass:FileId_5200)"
    end

    test "says so when an item has no tags at all" do
      result = Handlers.format_catalog_entries([entry(%{tags: [], path: ""})], 1)

      assert result =~ "808 Drifter.adg — no tags (query:Sounds#Bass:FileId_5200)"
    end

    test "flags truncation" do
      result = Handlers.format_catalog_entries([entry(%{})], 42)

      assert result =~ "Showing 1 of 42 matches"
    end

    test "tells the model how to loosen a search that found nothing" do
      result = Handlers.format_catalog_entries([], 0)

      assert result =~ "No catalog matches"
      assert result =~ "reindex_library"
    end
  end

  describe "search_library" do
    test "explains itself when the catalog has never been built" do
      # The catalog is not started in the test env, so this is exactly the
      # first-run case a user hits.
      assert {:error, msg} = Handlers.call("search_library", %{"query" => "bass"})

      assert msg =~ "empty"
      assert msg =~ "reindex_library"
    end
  end

  describe "format_device_chain/4" do
    # The do_call clauses for the device tools aren't tested here: they go
    # through Transport.query, which needs a live Ableton.
    test "formats one line per device with index, type label, and class" do
      result =
        Handlers.format_device_chain(
          0,
          ["Analog", "Reverb"],
          [2, 1],
          ["InstrumentVector", "Reverb"]
        )

      assert result =~ "2 device(s) on track 0"
      assert result =~ ~s{Device 0 "Analog" — instrument (InstrumentVector)}
      assert result =~ ~s{Device 1 "Reverb" — audio effect (Reverb)}
    end

    test "labels MIDI effects and unknown types" do
      result = Handlers.format_device_chain(1, ["Arpeggiator", "Weird"], [4, 9], ["Arp", "X"])

      assert result =~ "MIDI effect"
      assert result =~ "type 9"
    end

    test "explains an empty chain and points at load_device" do
      result = Handlers.format_device_chain(2, [], [], [])

      assert result =~ "No devices on track 2"
      assert result =~ "load_device"
    end
  end

  describe "format_device_parameters/7" do
    test "formats one line per parameter with value and range" do
      result =
        Handlers.format_device_parameters(
          0,
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
      result = Handlers.format_device_parameters(0, 0, "Op", ["Mode"], [3], [0], [7])

      assert result =~ "0. Mode = 3 (range 0–7)"
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

  describe "unknown tool" do
    test "returns error for unknown tool name" do
      assert {:error, msg} = Handlers.call("nonexistent_tool", %{})
      assert msg =~ "Unknown tool"
    end
  end
end
