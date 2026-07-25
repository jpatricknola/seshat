defmodule Seshat.Library.AbletonDBTest do
  @moduledoc """
  Exercises the reader against a miniature copy of Ableton's schema.

  The fixture is built here rather than checked in as a binary so that the
  handful of columns we depend on are documented as executable code — if Live
  ever changes them, this setup is the spec to compare against.
  """

  use ExUnit.Case, async: true

  alias Seshat.Library.AbletonDB

  @description_key 1_097_756_271

  setup do
    dir = Path.join(System.tmp_dir!(), "seshat-db-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "Live-files-12300.db")
    build_fixture(path)

    {:ok, dir: dir, path: path}
  end

  describe "read_tags/1" do
    test "returns tags, description and device_id keyed by file_id", %{path: path} do
      assert {:ok, index} = AbletonDB.read_tags(path)

      assert %{
               name: "808 Drifter.adg",
               tags: tags,
               description: "Created by: Comakid",
               device_id: nil
             } = index[5200]

      assert Enum.sort(tags) == ["808 Bass", "Punchy", "Sub"]
    end

    test "keeps untagged files, with an empty tag list", %{path: path} do
      assert {:ok, index} = AbletonDB.read_tags(path)

      assert index[7000].name == "Untagged Thing.adv"
      assert index[7000].tags == []
      assert index[7000].description == nil
    end

    test "carries device_id so core devices can be matched by it", %{path: path} do
      assert {:ok, index} = AbletonDB.read_tags(path)

      assert index[49].name == "Analog"
      assert index[49].device_id == "device:ableton:instr:Analog"
      assert "Analog" in index[49].tags
    end

    test "tag rows are themselves files, and are not mistaken for items", %{path: path} do
      assert {:ok, index} = AbletonDB.read_tags(path)

      # The tag "Punchy" is a row in `files` too — it is present, and untagged.
      assert index[101].name == "Punchy"
      assert index[101].tags == []
    end

    test "a missing database fails soft rather than raising", %{dir: dir} do
      assert {:error, _reason} = AbletonDB.read_tags(Path.join(dir, "nope.db"))
    end

    test "a file that is not SQLite fails soft", %{dir: dir} do
      path = Path.join(dir, "garbage.db")
      File.write!(path, "definitely not a database")

      assert {:error, _reason} = AbletonDB.read_tags(path)
    end
  end

  describe "locate_db/1" do
    test "finds the newest Live-files-*.db in a directory", %{dir: dir, path: path} do
      older = Path.join(dir, "Live-files-12100.db")
      File.write!(older, "")
      File.touch!(older, {{2020, 1, 1}, {0, 0, 0}})

      assert {:ok, ^path} = AbletonDB.locate_db(dir)
    end

    test "reports not_found rather than guessing" do
      empty = Path.join(System.tmp_dir!(), "seshat-empty-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf(empty) end)

      assert {:error, :not_found} = AbletonDB.locate_db(empty)
    end
  end

  # The columns and joins below are exactly what Seshat depends on in Live's
  # own database — nothing more.
  defp build_fixture(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    execute(conn, """
    CREATE TABLE files (
      file_id   INTEGER PRIMARY KEY,
      parent_id INTEGER,
      name      TEXT,
      device_id TEXT
    )
    """)

    execute(conn, "CREATE TABLE keywords (file_id INTEGER, keyw_id INTEGER, is_auto BOOL)")
    execute(conn, "CREATE TABLE metadata (file_id INTEGER, key INTEGER, value_id INTEGER)")
    execute(conn, "CREATE TABLE metadata_values (id INTEGER PRIMARY KEY, value TEXT)")

    # Tags are rows in `files`, like everything else.
    execute(conn, "INSERT INTO files VALUES (100, NULL, '808 Bass', NULL)")
    execute(conn, "INSERT INTO files VALUES (101, NULL, 'Punchy', NULL)")
    execute(conn, "INSERT INTO files VALUES (102, NULL, 'Sub', NULL)")

    execute(conn, "INSERT INTO files VALUES (5200, 1, '808 Drifter.adg', NULL)")
    execute(conn, "INSERT INTO files VALUES (7000, 1, 'Untagged Thing.adv', NULL)")
    execute(conn, "INSERT INTO files VALUES (49, 1, 'Analog', 'device:ableton:instr:Analog')")

    execute(conn, "INSERT INTO keywords VALUES (5200, 100, 0)")
    execute(conn, "INSERT INTO keywords VALUES (5200, 101, 1)")
    execute(conn, "INSERT INTO keywords VALUES (5200, 102, 0)")
    # A device row carries tags too — one of them happens to be its own name.
    execute(conn, "INSERT INTO files VALUES (103, NULL, 'Analog', NULL)")
    execute(conn, "INSERT INTO keywords VALUES (49, 103, 0)")

    execute(conn, "INSERT INTO metadata_values VALUES (35, 'Created by: Comakid')")
    execute(conn, "INSERT INTO metadata VALUES (5200, #{@description_key}, 35)")
    # An unrelated metadata key must not leak into the description.
    execute(conn, "INSERT INTO metadata_values VALUES (36, 'device:ableton:instr:Drift')")
    execute(conn, "INSERT INTO metadata VALUES (5200, 1148601161, 36)")

    Exqlite.Sqlite3.close(conn)
  end

  defp execute(conn, sql), do: :ok = Exqlite.Sqlite3.execute(conn, sql)
end
