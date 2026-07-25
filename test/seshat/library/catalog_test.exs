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
      fresh = Catalog.merge(@export, @db_index)

      previous = [
        %{
          uri: "query:Sounds#Bass:FileId_5200",
          use_count: 7,
          last_loaded_at: "2026-07-26T00:00:00Z"
        },
        %{uri: "query:Gone#Away", use_count: 3, last_loaded_at: "2026-07-26T00:00:00Z"}
      ]

      carried = Map.new(Catalog.carry_over_usage(fresh, previous), &{&1.uri, &1})

      assert carried["query:Sounds#Bass:FileId_5200"].use_count == 7
      assert carried["query:Sounds#Bass:FileId_5200"].last_loaded_at == "2026-07-26T00:00:00Z"
      assert carried["query:Synths#Analog"].use_count == 0
    end

    test "entries the previous catalog never had are left untouched" do
      fresh = Catalog.merge(@export, @db_index)

      assert Catalog.carry_over_usage(fresh, []) == fresh
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

      {:ok, _} = GenServer.call(server, {:replace, Catalog.merge(@export, @db_index)})

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
      {:ok, _} = GenServer.call(server, {:replace, Catalog.merge(@export, @db_index)})
    end

    %{opts: [table: table], path: path, server: server}
  end

  defp tmp_path do
    Path.join([
      System.tmp_dir!(),
      "seshat-catalog-test-#{System.unique_integer([:positive])}",
      "catalog.json"
    ])
  end
end
