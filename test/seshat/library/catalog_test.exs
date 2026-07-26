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
      assert {[%{name: "808 Drifter.adg"}], 1} = Catalog.search([query: "drifter"] ++ opts)
      assert {[%{name: "808 Drifter.adg"}], 1} = Catalog.search([query: "comakid"] ++ opts)
      assert {[%{name: "Glass Pad.adg"}], 1} = Catalog.search([query: "glass"] ++ opts)
    end

    test "every query term must match", %{opts: opts} do
      # "punchy sub" are two tags on one preset; "punchy pad" are on none.
      assert {[%{name: "808 Drifter.adg"}], 1} = Catalog.search([query: "punchy sub"] ++ opts)
      assert {[], 0} = Catalog.search([query: "punchy evolving"] ++ opts)
    end

    test "tag filters are strict and case-insensitive", %{opts: opts} do
      assert {[%{name: "808 Drifter.adg"}], 1} = Catalog.search([tags: ["punchy"]] ++ opts)
      assert {[], 0} = Catalog.search([tags: ["Punchy", "Evolving"]] ++ opts)
    end

    test "a tag filter matches as a substring, so 'bass' finds '808 Bass'", %{opts: opts} do
      assert {[%{name: "808 Drifter.adg"}], 1} = Catalog.search([tags: ["bass"]] ++ opts)
    end

    test "category restricts the scan", %{opts: opts} do
      assert {[%{name: "Analog"}], 1} = Catalog.search([category: "instruments"] ++ opts)
    end

    test "reports the full match count alongside the truncated page", %{opts: opts} do
      assert {results, 4} = Catalog.search([max_results: 2] ++ opts)
      assert length(results) == 2
    end

    test "ranks a name hit above a hit buried in the path or tags", %{opts: opts} do
      {[first | _], total} = Catalog.search([query: "pad"] ++ opts)

      assert total == 1
      assert first.name == "Glass Pad.adg"
    end

    test "an empty catalog answers empty rather than raising" do
      assert {[], 0} = Catalog.search(table: :seshat_catalog_missing_table)
    end
  end

  describe "persistence" do
    setup :start_catalog

    test "a catalog written by one run is read back by the next", %{path: path} do
      assert File.exists?(path)

      # A fresh process reading the same file — this is what happens on boot.
      %{opts: reloaded} = start_catalog(%{path: path})

      assert Catalog.count(reloaded[:table]) == 4
      assert {[entry], 1} = Catalog.search([query: "drifter"] ++ reloaded)
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

      assert {[entry], 1} = Catalog.search([query: "drifter"] ++ opts)
      assert entry.use_count == 1
      assert entry.last_loaded_at != nil

      {:ok, _} = GenServer.call(server, {:replace, normalized()})

      assert {[entry], 1} = Catalog.search([query: "drifter"] ++ opts)
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

      assert {[], 0} = Catalog.search(opts)
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
      assert {[entry], 1} = Catalog.search([query: "sweet lead"] ++ opts)

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
        {results, _} = Catalog.search([query: term, max_results: 100] ++ opts)

        assert "Sweet Lead.adg" in Enum.map(results, & &1.name),
               ~s{"#{term}" no longer finds Sweet Lead — a folded path stopped being searchable}
      end
    end

    test "an entry with no tags at all is still searchable by name", %{opts: opts} do
      # Exactly one entry in 8,222 has an empty tag list — an empty path gives
      # the path fallback nothing to derive from.
      assert {[entry], 1} = Catalog.search([query: "tremolo"] ++ opts)

      assert entry.name == "Auto Pan-Tremolo"
      assert entry.tags == []
      assert entry.paths == [""]
    end

    test "tag_source survives the JSON round-trip", %{opts: opts} do
      {all, 25} = Catalog.search([max_results: 100] ++ opts)

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
        assert {_, ^count} = Catalog.search([category: category, max_results: 100] ++ opts)
      end
    end

    test "punctuation in a name neither breaks the query nor the match", %{opts: opts} do
      assert {[%{name: "Jimi's Feedback Guitar.adg"}], 1} =
               Catalog.search([query: "jimi's"] ++ opts)

      assert {[%{name: "Plug In & Wail.adg"}], 1} = Catalog.search([query: "wail"] ++ opts)

      # Ampersands are everywhere in Live's factory naming ("Piano & Keys",
      # "Ambient & Evolving") and must survive as a literal search term.
      assert {_, 7} = Catalog.search([query: "&", max_results: 100] ++ opts)
    end

    test "stored paths are decoded, not the uri's percent-escaped form", %{opts: opts} do
      # Most of these uris carry %20 in a segment. `paths` arrives as its own
      # field on the browser export and is what search reads — the uri is not
      # in the haystack at all. So "20" finds nothing here, where it would
      # match nearly everything if the escaped form became the searchable text.
      assert {_, 0} = Catalog.search([query: "20"] ++ opts)

      {all, _} = Catalog.search([max_results: 100] ++ opts)
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
