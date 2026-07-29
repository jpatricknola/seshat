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

  # The clause's own wiring — which reply shape a search resolves to — is not
  # covered by formatting these by hand. It is all ETS, so it costs nothing to
  # drive the real dispatch. The catalog is started under its real name because
  # that is the table the handler reads.
  describe "search_library against a populated catalog" do
    setup do
      path =
        Path.join([
          System.tmp_dir!(),
          "seshat-handlers-catalog-#{System.unique_integer([:positive])}",
          "catalog.json"
        ])

      server = start_supervised!({Seshat.Library.Catalog, path: path})
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

      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      :ok
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
    end

    test "a truncated search offers the tags that would narrow it" do
      assert {:ok, reply} =
               Handlers.call("search_library", %{"query" => "guitar", "max_results" => 1})

      assert reply =~ "Showing 1 of 2 matches — top tags among them:"
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

  describe "device_out_of_range_error/3" do
    # The delete_device / bypass_device do_call clauses aren't tested here: both
    # lead with a guarded Transport read, which needs a live Ableton.
    test "names the real index range and prints the chain" do
      result = Handlers.device_out_of_range_error(2, 3, ["Operator", "Reverb"])

      assert result =~ "Track 2 has 2 device(s) (indices 0–1)"
      assert result =~ "there is no device 3"
      assert result =~ "Chain: 0: Operator, 1: Reverb."
    end

    test "an empty chain gets its own message" do
      result = Handlers.device_out_of_range_error(0, 0, [])

      assert result =~ "Track 0 has no devices"
      assert result =~ "nothing to delete (asked for device 0)"
      assert result =~ "get_track_devices"
    end
  end

  describe "deleted_device_reply/3" do
    test "names the deleted device and re-indexes what is left" do
      result = Handlers.deleted_device_reply(2, 1, ["Operator", "Compressor", "Reverb"])

      assert result =~ "Deleted 'Compressor' (device 1) from track 2"
      assert result =~ "Remaining chain: 0: Operator, 1: Reverb"
      assert result =~ "shifted down by one"
    end

    test "says so when the last device is gone" do
      result = Handlers.deleted_device_reply(0, 0, ["Reverb"])

      assert result =~ "Deleted 'Reverb' (device 0) from track 0"
      assert result =~ "device chain is now empty"
      refute result =~ "Remaining chain"
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
      result = Handlers.bypass_reply("Compressor", 2, 1, false)

      assert result == "'Compressor' (device 1 on track 2) is now Off — bypassed, settings kept."
    end

    test "the on reply" do
      assert Handlers.bypass_reply("Compressor", 2, 1, true) ==
               "'Compressor' (device 1 on track 2) is now On."
    end

    test "the no-op reply names the unchanged state and claims no change" do
      result = Handlers.bypass_noop_reply("Compressor", 2, 1, false)

      assert result =~ "was already Off — nothing to do"
      refute result =~ "is now"
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
    test "leaves the clip untouched when capture_midi got no name" do
      clip = captured_clip()

      assert Handlers.name_captured_clip(clip, nil) == clip
    end

    # Transport isn't started in test (config/test.exs sets start_osc: false),
    # so the rename send hits :noproc — this also exercises maybe_name_clip/3's
    # exit guard (review round 2, finding 2): it must not crash the caller.
    test "substitutes the name without a round trip, and survives the transport being down" do
      clip = captured_clip(%{clip: %{name: "", length: 8.0, playing?: false, recording?: false}})

      named = Handlers.name_captured_clip(clip, "Bass")

      assert named.clip.name == "Bass"
      assert named.track_index == clip.track_index
      assert named.slot_index == clip.slot_index
    end

    test "capture_midi's reply prints the model-supplied name" do
      named = Handlers.name_captured_clip(captured_clip(), "Bass")

      reply = Handlers.captured_reply([named], 0, 120.0, 120.0)

      assert reply =~ ~s{"Bass"}
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

    # A guessed fader position reads as real, and the model does relative moves
    # off it — "turn the delay down a bit" from a fictional 0.85 is an increase.
    test "a return whose volume query went unanswered says so instead of guessing" do
      returns = [
        %{index: 0, name: "A-Reverb", volume: 0.85},
        %{index: 1, name: "B-Delay", volume: nil}
      ]

      result = Handlers.format_return_tracks(returns, %{volume: 0.85})

      assert result =~ ~s{Return 0 "A-Reverb" (send A): volume=0.85}
      assert result =~ ~s{Return 1 "B-Delay" (send B): volume unknown}
      refute result =~ ~s{"B-Delay" (send B): volume=}
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

  # Only the transport-free error paths: everything past them queries Ableton.
  describe "set_clip_properties validation" do
    test "rejects a call that changes nothing" do
      assert {:error, message} =
               Handlers.call("set_clip_properties", %{"track" => 0, "clip_slot" => 0})

      assert message =~ "Nothing to set"
      assert message =~ "loop_start"
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
    end
  end

  describe "unknown tool" do
    test "returns error for unknown tool name" do
      assert {:error, msg} = Handlers.call("nonexistent_tool", %{})
      assert msg =~ "Unknown tool"
    end
  end
end
