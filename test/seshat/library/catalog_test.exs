defmodule Seshat.Library.CatalogTest do
  use ExUnit.Case, async: true

  alias Seshat.Library.Catalog

  @export %{
    "sounds" => [
      %{
        "name" => "808 Drifter.adg",
        "path" => "Bass/808 & Sub",
        "uri" => "query:Sounds#Bass:FileId_5200"
      },
      %{"name" => "Glass Pad.adg", "path" => "Pad/Soft", "uri" => "query:Sounds#Pad:FileId_6000"},
      %{
        "name" => "Orphan Preset.adv",
        "path" => "Lead/Bright",
        "uri" => "query:Sounds#Lead:FileId_9999"
      }
    ],
    "instruments" => [
      %{"name" => "Analog", "path" => "", "uri" => "query:Synths#Analog"}
    ]
  }

  @db_index %{
    5200 => %{
      name: "808 Drifter.adg",
      tags: ["808 Bass", "Punchy", "Sub"],
      description: "Created by: Comakid",
      device_id: nil
    },
    6000 => %{
      name: "Glass Pad.adg",
      tags: ["Pad", "Soft", "Evolving"],
      description: nil,
      device_id: nil
    },
    49 => %{
      name: "Analog",
      tags: ["Analog", "Synth"],
      description: nil,
      device_id: "device:ableton:instr:Analog"
    }
  }

  describe "file_id/1" do
    test "pulls the database key a preset uri embeds" do
      assert Catalog.file_id("query:Sounds#Bass:FileId_5200") == 5200
    end

    test "is nil for a core device uri, which carries no key" do
      assert Catalog.file_id("query:Synths#Analog") == nil
      assert Catalog.file_id(nil) == nil
    end
  end

  describe "merge/2" do
    setup do
      {:ok, entries: Map.new(Catalog.merge(@export, @db_index), &{&1.uri, &1})}
    end

    test "joins a preset on the FileId in its uri", %{entries: entries} do
      entry = entries["query:Sounds#Bass:FileId_5200"]

      assert entry.tags == ["808 Bass", "Punchy", "Sub"]
      assert entry.tag_source == :ableton
      assert entry.description == "Created by: Comakid"
      assert entry.category == "sounds"
      assert entry.path == "Bass/808 & Sub"
    end

    test "joins a FileId-less core device by name", %{entries: entries} do
      entry = entries["query:Synths#Analog"]

      assert entry.tags == ["Analog", "Synth"]
      assert entry.tag_source == :ableton
    end

    test "falls back to path-derived tags when nothing matches", %{entries: entries} do
      entry = entries["query:Sounds#Lead:FileId_9999"]

      assert entry.tags == ["Lead", "Bright"]
      assert entry.tag_source == :path
      assert entry.description == nil
    end

    test "starts every entry with a zeroed usage record", %{entries: entries} do
      for {_uri, entry} <- entries do
        assert entry.use_count == 0
        assert entry.last_loaded_at == nil
      end
    end

    test "an empty tag database still yields a complete, path-tagged catalog" do
      entries = Catalog.merge(@export, %{})

      assert length(entries) == 4
      assert Enum.all?(entries, &(&1.tag_source == :path))
    end

    test "skips rows without a usable uri" do
      export = %{"sounds" => [%{"name" => "Nameless", "path" => "", "uri" => ""}]}

      assert Catalog.merge(export, %{}) == []
    end
  end

  describe "carry_over_usage/2" do
    test "a reindex keeps what the user has actually loaded" do
      fresh = normalized()

      previous = [
        %{
          uri: "query:Sounds#Bass:FileId_5200",
          uris: ["query:Sounds#Bass:FileId_5200"],
          use_count: 7,
          last_loaded_at: "2026-07-26T00:00:00Z"
        },
        %{
          uri: "query:Gone#Away",
          uris: ["query:Gone#Away"],
          use_count: 3,
          last_loaded_at: "2026-07-26T00:00:00Z"
        }
      ]

      carried = Map.new(Catalog.carry_over_usage(fresh, previous), &{&1.uri, &1})

      assert carried["query:Sounds#Bass:FileId_5200"].use_count == 7
      assert carried["query:Sounds#Bass:FileId_5200"].last_loaded_at == "2026-07-26T00:00:00Z"
      assert carried["query:Synths#Analog"].use_count == 0
    end

    test "entries the previous catalog never had are left untouched" do
      fresh = normalized()

      assert Catalog.carry_over_usage(fresh, []) == fresh
    end

    test "a counter follows its preset when the canonical uri shifts" do
      # Installing a Pack can add a browser location that sorts ahead of the
      # old canonical pick. The count belongs to the preset, not to whichever
      # of its uris won last time.
      fresh = normalized()

      previous = [
        %{
          uri: "query:Sounds#Bass:FileId_5200_OLD",
          uris: ["query:Sounds#Bass:FileId_5200_OLD", "query:Sounds#Bass:FileId_5200"],
          use_count: 4,
          last_loaded_at: "2026-07-26T00:00:00Z"
        }
      ]

      carried = Map.new(Catalog.carry_over_usage(fresh, previous), &{&1.uri, &1})

      assert carried["query:Sounds#Bass:FileId_5200"].use_count == 4
    end
  end

  describe "normalize/1" do
    test "folds a preset's browser locations into one entry" do
      rows = [
        %{
          uri: "query:Synths#Operator:Pad:FileId_77",
          name: "Ghost.adg",
          category: "instruments",
          path: "Operator/Pad",
          tags: ["Pad", "Soft"],
          tag_source: :ableton,
          description: nil,
          use_count: 0,
          last_loaded_at: nil
        },
        %{
          uri: "query:Sounds#Pad:FileId_77",
          name: "Ghost.adg",
          category: "sounds",
          path: "Pad",
          tags: ["Pad", "Soft"],
          tag_source: :ableton,
          description: nil,
          use_count: 0,
          last_loaded_at: nil
        }
      ]

      assert [entry] = Catalog.normalize(rows)

      assert entry.categories == ["instruments", "sounds"]
      assert entry.paths == ["Operator/Pad", "Pad"]
      assert length(entry.uris) == 2
      assert entry.uri in entry.uris
      assert entry.tags == ["Pad", "Soft"]
    end

    test "rows without a FileId are left alone rather than merged by name" do
      # Core devices carry no FileId. Drum Rack really is one device under two
      # browser roots, but guessing identity from a name is not safe in the
      # plugin territory this has never been measured against.
      rows =
        for {cat, uri} <- [
              {"drums", "query:Drums#Drum%20Rack"},
              {"instruments", "query:Synths#Drum%20Rack"}
            ] do
          %{
            uri: uri,
            name: "Drum Rack",
            category: cat,
            path: "",
            tags: [],
            tag_source: :path,
            description: nil,
            use_count: 0,
            last_loaded_at: nil
          }
        end

      assert length(Catalog.normalize(rows)) == 2
    end

    test "is deterministic, so a rebuilt catalog diffs cleanly" do
      rows = Catalog.merge(@export, @db_index)

      assert Catalog.normalize(rows) == rows |> Enum.reverse() |> Catalog.normalize()
    end
  end

  describe "search/1" do
    setup :start_catalog

    test "matches terms across name, path, tags and description", %{opts: opts} do
      assert {[%{name: "808 Drifter.adg"}], 1, []} = Catalog.search([query: "drifter"] ++ opts)
      assert {[%{name: "808 Drifter.adg"}], 1, []} = Catalog.search([query: "comakid"] ++ opts)
      assert {[%{name: "Glass Pad.adg"}], 1, []} = Catalog.search([query: "glass"] ++ opts)
    end

    test "every query term must match", %{opts: opts} do
      # "punchy sub" are two tags on one preset; "punchy pad" are on none.
      assert {[%{name: "808 Drifter.adg"}], 1, []} = Catalog.search([query: "punchy sub"] ++ opts)
      assert {[], 0, []} = Catalog.search([query: "punchy evolving"] ++ opts)
    end

    test "category restricts the scan", %{opts: opts} do
      assert {[%{name: "Analog"}], 1, []} = Catalog.search([category: "instruments"] ++ opts)
    end

    test "reports the full match count alongside the truncated page", %{opts: opts} do
      assert {results, 4, _facets} = Catalog.search([max_results: 2] ++ opts)
      assert length(results) == 2
    end

    test "ranks a name hit above a hit buried in the path or tags", %{opts: opts} do
      {[first | _], total, _facets} = Catalog.search([query: "pad"] ++ opts)

      assert total == 1
      assert first.name == "Glass Pad.adg"
    end

    test "an empty catalog answers empty rather than raising" do
      assert {[], 0, []} = Catalog.search(table: :seshat_catalog_missing_table)
    end
  end

  # A strict AND meant one tag the library doesn't have zeroed the whole search,
  # and the advertised vocabulary was a guess by construction. Tags now filter at
  # ≥1 and do their real work in the score.
  describe "tag matching" do
    setup :start_catalog

    test "at least one requested tag is enough", %{opts: opts} do
      # Punchy is on the 808, Evolving on the pad. Under the old strict AND this
      # pair matched nothing at all.
      assert {results, 2, _facets} = Catalog.search([tags: ["Punchy", "Evolving"]] ++ opts)

      assert Enum.map(results, & &1.name) |> Enum.sort() == [
               "808 Drifter.adg",
               "Glass Pad.adg"
             ]
    end

    test "a tag the library has never heard of no longer zeroes the search", %{opts: opts} do
      # The exact failure from the tool description's own worked example: 'Warm'
      # is not a real tag anywhere, and it used to take the search down with it.
      assert {[%{name: "808 Drifter.adg"}], 1, []} =
               Catalog.search([query: "808", tags: ["Punchy", "Warm"]] ++ opts)
    end

    test "every requested tag missing still means no match", %{opts: opts} do
      # ≥1 is a real filter, not a no-op: tags still mean something, and the
      # zero-result diagnosis is what recovers from this in one step.
      assert {[], 0, []} = Catalog.search([tags: ["Warm", "Wide"]] ++ opts)
    end

    test "matching is case- and punctuation-insensitive on both sides" do
      opts = start_with([preset(%{name: "Kit Hat.adv", tags: ["Closed Hihat", "Punchy"]})])

      # The ROADMAP's 'Hi-hat' case: the real tags are 'Closed Hihat' /
      # 'Open Hihat', and the hyphen used to be fatal.
      assert {[%{name: "Kit Hat.adv"}], 1, []} = Catalog.search([tags: ["hi-hat"]] ++ opts)
    end

    test "a plural request reaches a singular tag" do
      opts = start_with([preset(%{name: "Glass.adg", tags: ["Pad", "Soft"]})])

      assert {[%{name: "Glass.adg"}], 1, []} = Catalog.search([tags: ["pads"]] ++ opts)
    end

    test "a tag still matches as a substring, so 'bass' finds '808 Bass'", %{opts: opts} do
      assert {[%{name: "808 Drifter.adg"}], 1, []} = Catalog.search([tags: ["bass"]] ++ opts)
    end

    test "the depluralized form matches whole tags only, never as a substring" do
      # 'Bass' strips to 'bas', which is a prefix of 'Basic' — the fifth most
      # common tag in a real library. Substring-matching the stripped form put
      # 491 hi-hats, kicks and pads into an 820-match 'Bass' search, two of them
      # in the first three slots.
      opts = start_with([preset(%{name: "Atom Kit.adg", tags: ["Basic", "Hybrid Kit"]})])

      assert {[], 0, []} = Catalog.search([tags: ["Bass"]] ++ opts)
    end

    test "the depluralized form still reaches one word of a multi-word tag" do
      # The other half of the rule above: 'bas' is not a word of 'Basic', but
      # 'hihat' *is* a word of 'Closed Hihat'. Without this a plural is a dead
      # end against every multi-word tag in the library — 'hi-hats' reaching
      # nothing while 'hi-hat' reaches 395, and 'guitars' finding 4 of 39.
      opts =
        start_with([
          preset(%{uri: uri(1), name: "Kit Hat.adv", tags: ["Closed Hihat"]}),
          preset(%{uri: uri(2), name: "Steel.adg", tags: ["Electric Guitar"]})
        ])

      assert {[%{name: "Kit Hat.adv"}], 1, []} = Catalog.search([tags: ["hi-hats"]] ++ opts)
      assert {[%{name: "Steel.adg"}], 1, []} = Catalog.search([tags: ["guitars"]] ++ opts)
    end
  end

  # Asserted component by component on hand-built entries: the whole point of the
  # new weights is that ties become rare, and a tie is exactly what a coarse
  # score can't tell apart.
  describe "score/2" do
    test "a whole-token name hit beats a mere substring" do
      assert Catalog.score(preset(%{name: "Pad.adg"}), query: "pad") >
               Catalog.score(preset(%{name: "Padlock.adg"}), query: "pad")
    end

    test "all query terms in the name beats only some of them" do
      assert Catalog.score(preset(%{name: "Analog Bass.adg"}), query: "analog bass") >
               Catalog.score(preset(%{name: "Analog Pad.adg"}), query: "analog bass")
    end

    test "how many requested tags matched dominates" do
      two = preset(%{tags: ["Analog", "Soft"]})
      one = preset(%{tags: ["Analog", "Bright"]})

      assert Catalog.score(two, tags: ["Analog", "Soft"]) -
               Catalog.score(one, tags: ["Analog", "Soft"]) == 4
    end

    test "an exact tag hit outscores a substring one" do
      exact = preset(%{tags: ["Bass"]})
      substring = preset(%{tags: ["808 Bass"]})

      assert Catalog.score(exact, tags: ["bass"]) > Catalog.score(substring, tags: ["bass"])
    end

    test "a term found in the tags beats one found only in the folder path" do
      # The words for what a sound *is* live in its name and tags; the path and
      # the "Created by:" credit line are weaker evidence.
      in_tags = preset(%{name: "Ghost.adg", tags: ["Pad"], paths: ["Misc"]})
      in_path = preset(%{name: "Ghost.adg", tags: ["Lead"], paths: ["Pad/Soft"]})

      assert Catalog.score(in_tags, query: "pad") > Catalog.score(in_path, query: "pad")
    end

    test "tags written by Ableton edge out tags inferred from the folder path" do
      assert Catalog.score(preset(%{tag_source: :ableton}), []) -
               Catalog.score(preset(%{tag_source: :path}), []) == 1
    end

    test "usage is recency-decayed rather than flat" do
      now = ~U[2026-07-27 12:00:00Z]

      recent = preset(%{use_count: 1, last_loaded_at: "2026-07-24T12:00:00Z"})
      lapsed = preset(%{use_count: 1, last_loaded_at: "2026-06-01T12:00:00Z"})
      stale = preset(%{use_count: 1, last_loaded_at: "2025-01-01T12:00:00Z"})
      never = preset(%{use_count: 0})

      assert Catalog.score(recent, now: now) - Catalog.score(lapsed, now: now) == 1
      assert Catalog.score(lapsed, now: now) - Catalog.score(stale, now: now) == 1
      assert Catalog.score(stale, now: now) - Catalog.score(never, now: now) == 1
    end

    test "an unparseable timestamp scores no recency rather than raising" do
      assert Catalog.score(preset(%{last_loaded_at: "sometime"}), now: ~U[2026-07-27 12:00:00Z]) ==
               Catalog.score(preset(%{}), now: ~U[2026-07-27 12:00:00Z])
    end
  end

  # A good scorer still leaves tied bands on a broad query, and taking a tie in
  # sort order hands every remaining slot to one corner of the library.
  describe "slate diversity at the cut line" do
    test "a tied band wider than the cap rotates across device roots" do
      entries =
        for {root, index} <- [{"Operator", 1}, {"Operator", 2}, {"AUv2", 3}, {"AUv2", 4}],
            do: tied(index, ["#{root}/Bass"])

      opts = start_with(entries)

      assert {results, 4, _facets} = Catalog.search([max_results: 2] ++ opts)
      assert Enum.map(results, &device_root/1) == ["Operator", "AUv2"]
    end

    test "the root is the device, not whichever path sorts first" do
      # Both Operator presets and both Wavetable ones are also filed under the
      # bare `sounds` folder "Bass". Grouping on the first path would see one
      # group and rotate across nothing; grouping on the first device-prefixed
      # path sees two devices.
      opts =
        start_with([
          tied(1, ["Bass", "Operator/Bass"]),
          tied(2, ["Bass", "Operator/Bass"]),
          tied(3, ["Bass", "Wavetable/Bass"]),
          tied(4, ["Bass", "Wavetable/Bass"])
        ])

      assert {results, 4, _facets} = Catalog.search([max_results: 2] ++ opts)
      assert Enum.map(results, & &1.uri) == [uri(1), uri(3)]
    end

    test "presets with no device-prefixed path at all still group and still rank" do
      opts =
        start_with([
          tied(1, ["Synth Lead"]),
          tied(2, ["Synth Lead"]),
          tied(3, ["Bass"]),
          tied(4, ["Bass"])
        ])

      assert {results, 4, _facets} = Catalog.search([max_results: 2] ++ opts)
      assert Enum.map(results, &device_root/1) == ["Synth Lead", "Bass"]
    end

    test "the rotation is deterministic" do
      entries = for index <- 1..9, do: tied(index, ["Device#{rem(index, 3)}/Bass"])
      opts = start_with(entries)

      assert Catalog.search([max_results: 4] ++ opts) ==
               Catalog.search([max_results: 4] ++ opts)
    end

    test "bands wholly above the cut are taken in score order, untouched" do
      # One clear winner and a tied band behind it: the winner keeps its slot
      # regardless of which root it belongs to.
      opts =
        start_with([
          preset(%{
            uri: uri(9),
            uris: [uri(9)],
            name: "Deep Bass.adg",
            paths: ["Operator/Bass"],
            tags: ["Bass"]
          }),
          tied(1, ["Operator/Bass"]),
          tied(2, ["AUv2/Bass"])
        ])

      # "Deep Bass" has "bass" as a whole token in its name; the tied pair only
      # carry it as a tag. The winner takes its slot before any rotation, even
      # though its uri sorts last.
      assert {[first | _], 3, _facets} = Catalog.search([query: "bass", max_results: 2] ++ opts)

      assert first.name == "Deep Bass.adg"
    end
  end

  describe "facets" do
    test "a truncated result reports the tags that would narrow it" do
      entries =
        for index <- 1..10 do
          extra =
            cond do
              index <= 4 -> ["Analog"]
              index <= 7 -> ["FM"]
              true -> ["Sub"]
            end

          # "One Shot" is on 8 of 10 — too common to narrow anything.
          common = if index <= 8, do: ["One Shot"], else: []

          tied(index, ["Operator/Bass"], ["Bass"] ++ common ++ extra)
        end

      opts = start_with(entries)

      assert {_results, 10, facets} = Catalog.search([tags: ["bass"], max_results: 2] ++ opts)

      # Bass was requested, One Shot is on 80% of the matches: neither narrows.
      assert facets == [{"Analog", 4}, {"FM", 3}, {"Sub", 3}]
    end

    test "an untruncated result needs no narrowing help" do
      opts = start_with([tied(1, ["Operator/Bass"], ["Bass", "Analog"])])

      assert {_results, 1, []} = Catalog.search([tags: ["bass"]] ++ opts)
    end
  end

  describe "diagnose/1" do
    test "a tag the library doesn't have is named, with the nearest real ones" do
      opts =
        start_with([
          preset(%{uri: uri(1), tags: ["Analog", "Soft"]}),
          preset(%{uri: uri(2), tags: ["Analog"]})
        ])

      diagnosis = Catalog.diagnose([tags: ["Anlaog"]] ++ opts)

      # A typo, not a different word: Soft is in the vocabulary and stays out of
      # the suggestions.
      assert [%{tag: "Anlaog", matches: 0, nearest: [{"Analog", 2}]}] = diagnosis.tags
    end

    test "the tags on what the query alone matches are what makes a retry possible" do
      # 'Warm' has no near neighbour in a stock vocabulary — string similarity
      # can't rescue a word the library has no spelling of. The real tags on the
      # guitars the query *did* reach can.
      opts =
        start_with([
          preset(%{uri: uri(1), name: "Nylon Guitar.adg", tags: ["Acoustic", "Soft"]}),
          preset(%{uri: uri(2), name: "Steel Guitar.adg", tags: ["Acoustic", "Bright"]}),
          preset(%{uri: uri(3), name: "Glass Pad.adg", tags: ["Pad"]})
        ])

      diagnosis = Catalog.diagnose([query: "guitar", tags: ["Warm"]] ++ opts)

      assert [%{tag: "Warm", matches: 0, nearest: []}] = diagnosis.tags
      assert diagnosis.query_matches == 2

      # Acoustic is on both guitars — 100% of the scope, so it narrows nothing
      # and stays out. Soft and Bright each narrow to one.
      assert diagnosis.narrowing_tags == [{"Bright", 1}, {"Soft", 1}]
    end

    test "with no query at all, the whole catalog's vocabulary is the hint" do
      opts =
        start_with([
          preset(%{uri: uri(1), tags: ["Analog", "Soft"]}),
          preset(%{uri: uri(2), tags: ["Analog", "Bright"]}),
          preset(%{uri: uri(3), tags: ["Pad"]})
        ])

      diagnosis = Catalog.diagnose([tags: ["Warm"]] ++ opts)

      assert diagnosis.query_matches == nil
      assert diagnosis.narrowing_tags == [{"Bright", 1}, {"Pad", 1}, {"Soft", 1}]
    end

    test "a requested tag that is a longer form of a real one gets suggested back" do
      # The substring matcher only looks one way — 'Warmth' can't reach 'Warm' —
      # so containment in the other direction is what rescues it here.
      opts = start_with([preset(%{tags: ["Warm"]})])

      diagnosis = Catalog.diagnose([tags: ["Warmth"]] ++ opts)

      assert [%{tag: "Warmth", matches: 0, nearest: [{"Warm", 1}]}] = diagnosis.tags
    end

    test "a tag that does match reports how much it matches on its own" do
      opts = start_with([preset(%{uri: uri(1), tags: ["Analog"]})])

      diagnosis = Catalog.diagnose([query: "nothing like this", tags: ["Analog"]] ++ opts)

      assert [%{tag: "Analog", matches: 1, nearest: []}] = diagnosis.tags
      assert diagnosis.query_matches == 0
    end

    test "constraints that were never set report nil, not zero" do
      opts = start_with([preset(%{})])

      diagnosis = Catalog.diagnose(opts)

      assert diagnosis.query_matches == nil
      assert diagnosis.category_matches == nil
      assert diagnosis.tags == []
    end

    test "the query and category counts come back per constraint" do
      opts =
        start_with([
          preset(%{uri: uri(1), name: "Warm Bass.adg", categories: ["sounds"]}),
          preset(%{uri: uri(2), name: "Cold Pad.adg", categories: ["instruments"]})
        ])

      diagnosis = Catalog.diagnose([query: "bass", category: "instruments"] ++ opts)

      assert diagnosis.query_matches == 1
      assert diagnosis.category_matches == 1
    end

    test "the ROADMAP's 'a warm analog bass' now returns the Analog matches" do
      # The tool description's own worked example used to return nothing. It
      # should reach the Analog bass and leave the unrelated pad behind.
      opts =
        start_with([
          preset(%{uri: uri(1), name: "Basic Analog Bass.adg", tags: ["Synth Bass", "Analog"]}),
          preset(%{uri: uri(2), name: "Glass Pad.adg", tags: ["Pad", "Soft"]})
        ])

      assert {[%{name: "Basic Analog Bass.adg"}], 1, []} =
               Catalog.search([query: "bass", tags: ["Analog", "Warm"]] ++ opts)
    end

    test "an empty catalog diagnoses empty rather than raising" do
      diagnosis = Catalog.diagnose(table: :seshat_catalog_missing_table, tags: ["Analog"])

      assert [%{tag: "Analog", matches: 0, nearest: []}] = diagnosis.tags
    end
  end

  describe "persistence" do
    setup :start_catalog

    test "a catalog written by one run is read back by the next", %{path: path} do
      assert File.exists?(path)

      # A fresh process reading the same file — this is what happens on boot.
      %{opts: reloaded} = start_catalog(%{path: path})

      assert Catalog.count(reloaded[:table]) == 4
      assert {[entry], 1, []} = Catalog.search([query: "drifter"] ++ reloaded)
      assert entry.tags == ["808 Bass", "Punchy", "Sub"]
      assert entry.tag_source == :ableton
      assert entry.description == "Created by: Comakid"
    end

    test "record_load/2 bumps the counter, and a reindex preserves it", %{
      opts: opts,
      server: server
    } do
      :ok = Catalog.record_load("query:Sounds#Bass:FileId_5200", server)
      _ = :sys.get_state(server)

      assert {[entry], 1, []} = Catalog.search([query: "drifter"] ++ opts)
      assert entry.use_count == 1
      assert entry.last_loaded_at != nil

      {:ok, _} = GenServer.call(server, {:replace, normalized()})

      assert {[entry], 1, []} = Catalog.search([query: "drifter"] ++ opts)
      assert entry.use_count == 1
    end

    test "record_load/2 ignores a uri the catalog has never seen", %{server: server} do
      assert :ok = Catalog.record_load("query:Nothing#Here", server)
      assert :sys.get_state(server)
    end

    test "record_load/2 on a catalog that isn't running is a no-op, not a crash" do
      assert :ok = Catalog.record_load("query:Anything", :seshat_catalog_not_running)
    end

    test "a corrupt catalog file is ignored rather than fatal" do
      path = tmp_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")

      %{opts: opts} = start_catalog(%{path: path})

      assert {[], 0, []} = Catalog.search(opts)
    end
  end

  # The fixture above is hand-written and deliberately tiny, which makes the
  # assertions above exact and readable — but it is not shaped like anything
  # Ableton actually produces. These run against 28 entries lifted verbatim
  # from a real 8,222-entry catalog (stock factory content only), picked to
  # cover every category, both tag sources, empty paths, punctuated names, and
  # the aliasing below. Regenerate by sampling a real catalog.json; the
  # assertions here are about shape, not about which presets someone owns.
  describe "a real catalog" do
    setup do
      # Copied out of the repo first — the catalog persists on write, and a
      # test has no business editing its own fixture.
      path = tmp_path()
      File.mkdir_p!(Path.dirname(path))
      File.cp!("test/support/fixtures/catalog.json", path)

      start_catalog(%{path: path})
    end

    test "28 browser rows load as 25 presets", %{opts: opts} do
      assert Catalog.count(opts[:table]) == 25
    end

    test "a preset filed in several places is one result, not four", %{opts: opts} do
      # Live files the same .adg under each device that can open it and bakes
      # the path into the uri, so "Sweet Lead" arrives as four rows across two
      # categories behind one FileId. ~30% of a real catalog is these aliases,
      # and unfolded they crowd the candidate slate the user has to choose
      # from. One preset, one row, every location kept.
      assert {[entry], 1, []} = Catalog.search([query: "sweet lead"] ++ opts)

      assert entry.name == "Sweet Lead.adg"
      assert entry.categories == ["instruments", "sounds"]
      assert length(entry.uris) == 4
      assert length(entry.paths) == 4

      # The canonical uri is one Live actually gave us, never a synthesised
      # one — load_device has to be able to resolve it.
      assert entry.uri in entry.uris

      # All four uris are the same underlying file.
      assert entry.uris |> Enum.map(&Catalog.file_id/1) |> Enum.uniq() |> length() == 1
    end

    test "folding away aliases costs no recall", %{opts: opts} do
      # Only one of Sweet Lead's four uris survives, but every path it was
      # filed under stays searchable — so the device names still find it.
      # (Other entries may match these terms too; what matters is that folding
      # did not lose the three locations whose uris were dropped.)
      for term <- ["operator", "analog", "instrument rack", "synth lead"] do
        {results, _total, _facets} = Catalog.search([query: term, max_results: 100] ++ opts)

        assert "Sweet Lead.adg" in Enum.map(results, & &1.name),
               ~s{"#{term}" no longer finds Sweet Lead — a folded path stopped being searchable}
      end
    end

    test "the scorer, not the alphabet, decides the order", %{opts: opts} do
      # Five of these match "guitar". Four carry it as a word in their name; the
      # Amp device carries it only as a tag. Sorted alphabetically — which is what
      # the old scorer effectively did, since all five landed in one band — "Amp"
      # came first. It should now come last.
      {results, 5, _facets} = Catalog.search([query: "guitar", max_results: 100] ++ opts)
      names = Enum.map(results, & &1.name)

      assert List.last(names) == "Amp"
      assert Enum.all?(Enum.drop(names, -1), &String.contains?(&1, "Guitar"))
    end

    test "'sweet lead' still ranks its preset first", %{opts: opts} do
      {[first | _], _total, _facets} =
        Catalog.search([query: "lead", max_results: 100] ++ opts)

      assert first.name == "Sweet Lead.adg"
    end

    test "an entry with no tags at all is still searchable by name", %{opts: opts} do
      # Exactly one entry in 8,222 has an empty tag list — an empty path gives
      # the path fallback nothing to derive from.
      assert {[entry], 1, []} = Catalog.search([query: "tremolo"] ++ opts)

      assert entry.name == "Auto Pan-Tremolo"
      assert entry.tags == []
      assert entry.paths == [""]
    end

    test "tag_source survives the JSON round-trip", %{opts: opts} do
      {all, 25, []} = Catalog.search([max_results: 100] ++ opts)

      assert Enum.frequencies_by(all, & &1.tag_source) == %{ableton: 21, path: 4}
    end

    test "every category holds something findable", %{opts: opts} do
      # These sum to 26, not 25: Sweet Lead is filed under two categories and a
      # filter on either has to find it.
      for {category, count} <- %{
            "audio_effects" => 14,
            "drums" => 2,
            "instruments" => 5,
            "midi_effects" => 2,
            "sounds" => 3
          } do
        assert {_, ^count, _} = Catalog.search([category: category, max_results: 100] ++ opts)
      end
    end

    test "punctuation in a name neither breaks the query nor the match", %{opts: opts} do
      assert {[%{name: "Jimi's Feedback Guitar.adg"}], 1, []} =
               Catalog.search([query: "jimi's"] ++ opts)

      assert {[%{name: "Plug In & Wail.adg"}], 1, []} = Catalog.search([query: "wail"] ++ opts)

      # Ampersands are everywhere in Live's factory naming ("Piano & Keys",
      # "Ambient & Evolving") and must survive as a literal search term.
      assert {_, 7, _} = Catalog.search([query: "&", max_results: 100] ++ opts)
    end

    test "record_load via an alias uri still bumps its preset", %{opts: opts, server: server} do
      # The table is keyed by canonical uri, but load_device can be handed any
      # alias — from list_browser_items, or remembered from before a reindex
      # shifted the canonical pick. The counter belongs to the preset.
      assert {[entry], 1, []} = Catalog.search([query: "sweet lead"] ++ opts)
      alias_uri = Enum.find(entry.uris, &(&1 != entry.uri))

      :ok = Catalog.record_load(alias_uri, server)
      _ = :sys.get_state(server)

      assert {[bumped], 1, []} = Catalog.search([query: "sweet lead"] ++ opts)
      assert bumped.uri == entry.uri
      assert bumped.use_count == 1
    end

    test "stored paths are decoded, not the uri's percent-escaped form", %{opts: opts} do
      # Most of these uris carry %20 in a segment. `paths` arrives as its own
      # field on the browser export and is what search reads — the uri is not
      # in the haystack at all. So "20" finds nothing here, where it would
      # match nearly everything if the escaped form became the searchable text.
      assert {_, 0, _} = Catalog.search([query: "20"] ++ opts)

      {all, _total, _facets} = Catalog.search([max_results: 100] ++ opts)
      refute Enum.any?(all, fn e -> Enum.any?(e.paths, &String.contains?(&1, "%")) end)
    end
  end

  # Starts a catalog with its own ETS table and its own file, so these tests
  # stay async. Given a `:path`, it loads whatever is already there; otherwise
  # it starts empty and gets the fixture catalog installed.
  defp start_catalog(context) do
    table = :"catalog_test_#{System.unique_integer([:positive])}"
    path = Map.get(context, :path, tmp_path())

    server =
      start_supervised!(
        {Catalog, name: :"#{table}_server", table: table, path: path},
        id: table
      )

    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

    # ETS is read directly by callers, so wait out the boot-time load before
    # anyone looks at the table.
    _ = :sys.get_state(server)

    unless Map.has_key?(context, :path) do
      {:ok, _} = GenServer.call(server, {:replace, normalized()})
    end

    %{opts: [table: table], path: path, server: server}
  end

  # Starts a catalog holding exactly these entries. The fixtures above are shaped
  # like Ableton's output, which is what makes them awkward for asserting one
  # scoring or grouping rule at a time.
  defp start_with(entries) do
    %{server: server, opts: opts} = start_catalog(%{})
    {:ok, _summary} = GenServer.call(server, {:replace, entries})

    opts
  end

  defp preset(overrides) do
    Map.merge(
      %{
        uri: uri(0),
        uris: [uri(0)],
        name: "Test Preset.adg",
        categories: ["sounds"],
        paths: ["Test"],
        tags: [],
        tag_source: :ableton,
        description: nil,
        use_count: 0,
        last_loaded_at: nil
      },
      overrides
    )
  end

  # An entry that scores identically to its siblings, so what's under test is the
  # tie-breaking rather than the ranking. Uris are ordered so the expected
  # rotation is written out rather than inferred.
  defp tied(index, paths, tags \\ ["Bass"]) do
    preset(%{
      uri: uri(index),
      uris: [uri(index)],
      name: "Tied #{index}.adg",
      paths: paths,
      tags: tags
    })
  end

  defp uri(index), do: "query:Sounds#Test:FileId_#{100 + index}"

  # The plan's rule, restated in the test so a change to the private one has to
  # be deliberate: the first device-prefixed path, or the first path if a preset
  # has only bare character folders.
  defp device_root(entry) do
    path = Enum.find(entry.paths, &String.contains?(&1, "/")) || hd(entry.paths)

    path |> String.split("/") |> hd()
  end

  # The indexing pipeline as `reindex/1` runs it: rows out of the export, then
  # folded into one entry per preset.
  defp normalized, do: @export |> Catalog.merge(@db_index) |> Catalog.normalize()

  defp tmp_path do
    Path.join([
      System.tmp_dir!(),
      "seshat-catalog-test-#{System.unique_integer([:positive])}",
      "catalog.json"
    ])
  end
end
