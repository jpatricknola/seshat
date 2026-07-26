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
    test "one line per return in send order, then the master" do
      returns = [
        %{index: 0, name: "A-Reverb", volume: 0.85},
        %{index: 1, name: "B-Delay", volume: 0.7}
      ]

      result = Handlers.format_return_tracks(returns, %{volume: 0.85})

      assert result =~ ~s{Return 0 "A-Reverb" (send A): volume=0.85}
      assert result =~ ~s{Return 1 "B-Delay" (send B): volume=0.7}
      assert result =~ "Master: volume=0.85"
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
      result = Handlers.format_return_tracks([], %{volume: 0.6})

      assert result =~ "No return tracks"
      assert result =~ "create_return_track"
      assert result =~ "Master: volume=0.6"
    end
  end

  # Every one of these guards Ableton before mutating, so on a machine with no
  # Ableton (CI, and most dev runs) each hits its guard timeout in ~2s and must
  # report a useful error rather than claiming a success that never happened.
  #
  # A success is *also* valid, and deliberately allowed: run this suite on the
  # developer's own machine with Live open and the guard genuinely answers. What
  # is pinned here is the error wording, which is the part that would otherwise
  # rot unnoticed — never "there is no Ableton", which isn't ours to assert.
  # Happy-path behaviour belongs to /smoke-test.
  describe "sends and returns when the guard doesn't answer" do
    defp assert_guarded_error(result, expected_fragments) do
      case result do
        {:error, message} ->
          for fragment <- expected_fragments do
            assert message =~ fragment
          end

        {:ok, message} ->
          # A live Ableton answered the guard. Nothing to check but that the
          # clause returned a report rather than a raw term.
          assert is_binary(message)
      end
    end

    test "set_track_send names the send index and get_track_sends" do
      Handlers.call("set_track_send", %{"track" => 2, "send" => 1, "value" => 0.4})
      |> assert_guarded_error([
        "send 1 on track 2",
        "get_track_sends",
        "nothing further was sent"
      ])
    end

    test "get_track_sends points at the install task" do
      Handlers.call("get_track_sends", %{"track" => 0})
      |> assert_guarded_error(["mix abletonosc.install"])
    end

    test "create_return_track points at the install task and says nothing was created" do
      Handlers.call("create_return_track", %{"name" => "Space"})
      |> assert_guarded_error(["mix abletonosc.install", "nothing was created"])
    end

    test "delete_return_track explains that return indices are their own space" do
      Handlers.call("delete_return_track", %{"return_track" => 0})
      |> assert_guarded_error([
        "return track 0",
        "0-based and separate from regular track indices"
      ])
    end

    test "set_return_track_volume does not claim the fader moved" do
      Handlers.call("set_return_track_volume", %{"return_track" => 0, "value" => 0.85})
      |> assert_guarded_error(["volume of return track 0", "mix abletonosc.install"])
    end

    test "set_master_volume does not claim the fader moved" do
      Handlers.call("set_master_volume", %{"value" => 0.7})
      |> assert_guarded_error(["master volume", "mix abletonosc.install", "nothing was changed"])
    end
  end

  describe "unknown tool" do
    test "returns error for unknown tool name" do
      assert {:error, msg} = Handlers.call("nonexistent_tool", %{})
      assert msg =~ "Unknown tool"
    end
  end
end
