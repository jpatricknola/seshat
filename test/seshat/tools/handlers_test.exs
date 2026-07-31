defmodule Seshat.Tools.HandlersTest do
  use ExUnit.Case, async: false

  alias Seshat.Tools.Handlers

  # Only the describes that reach the wire own a socket. The sink binds the
  # test send port first, so it is listening before the first datagram — and
  # every mutation below is then asserted where it landed, which is provably
  # not Ableton (config/test.exs).
  defp osc_sink(_context) do
    start_supervised!({Seshat.Test.OSCSink, forward_to: self()})
    start_supervised!(Seshat.OSC.Transport)
    :ok
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

    # MCP delivers Peri-validated params with atom keys; the Anthropic API
    # delivers string keys. Both must reach the same clause.
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

    # Validation runs on the stringified map, so both entry shapes are held to
    # the same schema — MCP mode must not be the lenient one.
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

    # A fabricated "Return 1" is worse than a guessed number: the user may try
    # to address the return by that name.
    test "a return whose name query went unanswered says so instead of guessing" do
      returns = [%{index: 1, name: nil, volume: 0.7}]

      result = Handlers.format_return_tracks(returns, %{volume: 0.85})

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
      assert unknown_text =~ "refresh: true"
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
  describe "format_session_state/4" do
    @explanation "Unknown values mean Ableton did not answer"

    defp known_returns, do: [%{index: 0, name: "A-Reverb", volume: 0.7}]

    defp compose(overrides \\ %{}) do
      args =
        Map.merge(
          %{
            song: song(),
            tracks: [mirrored_track()],
            return_tracks: known_returns(),
            master: %{volume: 0.85}
          },
          overrides
        )

      Handlers.format_session_state(args.song, args.tracks, args.return_tracks, args.master)
    end

    test "a fully known session gets no trailing explanation" do
      reply = compose()

      assert reply =~ "120.0 BPM, 4/4, stopped, key: C Major"
      assert reply =~ ~s{Track 0 "Drums"}
      assert reply =~ ~s{Return 0 "A-Reverb"}
      assert reply =~ "Master: volume=0.85"
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
      assert compose(%{return_tracks: [%{index: 0, name: nil, volume: 0.7}]}) =~ @explanation
    end

    test "an unknown return volume triggers the explanation" do
      assert compose(%{return_tracks: [%{index: 0, name: "A-Reverb", volume: nil}]}) =~
               @explanation
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
          return_tracks: [%{index: 0, name: nil, volume: nil}],
          master: nil
        })

      assert length(String.split(reply, @explanation)) == 2
    end

    test "the explanation tells the model how to recover" do
      reply = compose(%{tracks: nil})

      assert reply =~ "refresh: true"
      assert reply =~ "AbletonOSC"
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
    # rejects that shape in `call/2` for both modes, so this pins the direct
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
    # No socket and no sink on purpose: a zero amount is rejected before the
    # first guard, so nothing may reach Transport at all. If this test ever
    # starts timing out, the early return has been lost.
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
    end
  end

  describe "unknown tool" do
    test "returns error for unknown tool name" do
      assert {:error, msg} = Handlers.call("nonexistent_tool", %{})
      assert msg =~ "Unknown tool"
    end
  end
end
