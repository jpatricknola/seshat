defmodule Seshat.Library.AbletonDB do
  @moduledoc """
  Read-only reader for Ableton Live's own browser database.

  Live 12 ships every factory and Pack preset pre-tagged by its sound designers
  (`808 Drifter.adg` → `808 Bass | Punchy | Sub | Synth Bass`), but those tags
  are not exposed through the Live Object Model — reading Live's SQLite file is
  the only way to get at them.

  This is **source data, not Seshat's database**. It is opened read-only, at
  reindex time only, and never written to. Live keeps it in WAL mode and holds
  it open while running, which a read-only connection tolerates fine.

  The schema is undocumented and may shift between Live versions, so every read
  is wrapped: any failure returns `{:error, reason}` and the caller simply
  treats tags as unavailable. The dependency surface is deliberately small —
  `files(file_id, name, device_id)`, `keywords`, and one `metadata` key.

  ## Schema, as far as we depend on it

  | Table | What we take from it |
  |---|---|
  | `files` | Every browser item *and* every tag — tags are rows in `files` too. `file_id` is the join key browser uris embed as `FileId_<n>` |
  | `keywords` | The item↔tag join: `file_id` → `keyw_id` (which is a `files.file_id`) |
  | `metadata` / `metadata_values` | Per-file key/value strings; one integer key holds the author credit ("Created by: …") |
  """

  require Logger

  # macOS. Windows lives elsewhere and is a follow-up — locate_db/1 returns
  # {:error, :not_found} there rather than guessing.
  @default_dir "~/Library/Application Support/Ableton/Live Database"

  # Live stores metadata keys as opaque integer hashes. This one holds the
  # preset's free-text annotation — an author credit ("Created by: …"), a
  # description of the sound, or both. Either way it is worth searching.
  @description_key 1_097_756_271

  @type entry :: %{
          name: String.t(),
          tags: [String.t()],
          description: String.t() | nil,
          device_id: String.t() | nil
        }

  @doc """
  Path to the newest `Live-files-*.db` in Live's database directory.

  The filename encodes Live's build number (`Live-files-12300.db`), so a new
  Live version arrives as a new file rather than a silent schema mutation.
  """
  @spec locate_db(String.t() | nil) :: {:ok, String.t()} | {:error, :not_found}
  def locate_db(dir \\ nil) do
    dir = Path.expand(dir || Application.get_env(:seshat, :ableton_db_dir, @default_dir))

    case Path.wildcard(Path.join(dir, "Live-files-*.db")) do
      [] ->
        {:error, :not_found}

      paths ->
        {:ok, Enum.max_by(paths, &file_mtime/1)}
    end
  end

  @doc """
  Read every tagged item out of the database, keyed by `files.file_id`.

  That key is the whole point: browser uris embed it as `FileId_<n>`, so the
  catalog's join against a browser export is exact rather than name-matched.
  """
  @spec read_tags(String.t()) :: {:ok, %{integer() => entry()}} | {:error, term()}
  def read_tags(db_path) do
    with {:ok, conn} <- open(db_path) do
      try do
        do_read(conn)
      rescue
        error -> {:error, error}
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  defp open(db_path) do
    case Exqlite.Sqlite3.open(db_path, mode: :readonly) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp do_read(conn) do
    with {:ok, tags} <- tags_by_file(conn),
         {:ok, descriptions} <- descriptions_by_file(conn),
         {:ok, files} <- files_by_id(conn) do
      entries =
        Map.new(files, fn {file_id, {name, device_id}} ->
          {file_id,
           %{
             name: name,
             tags: Map.get(tags, file_id, []),
             description: Map.get(descriptions, file_id),
             device_id: device_id
           }}
        end)

      {:ok, entries}
    end
  end

  # Tags are themselves rows in `files`, so this is a self-join through the
  # `keywords` table. `is_auto` (Live's automatic tags vs. deliberate ones) is
  # kept — an automatic "Bass" tag is just as useful for search.
  defp tags_by_file(conn) do
    query(conn, """
    SELECT k.file_id, t.name
    FROM keywords k
    JOIN files t ON t.file_id = k.keyw_id
    WHERE t.name IS NOT NULL
    """)
    |> group_strings()
  end

  defp descriptions_by_file(conn) do
    with {:ok, rows} <-
           query(conn, """
           SELECT m.file_id, v.value
           FROM metadata m
           JOIN metadata_values v ON v.id = m.value_id
           WHERE m.key = #{@description_key}
           """) do
      {:ok, Map.new(rows, fn [file_id, value] -> {file_id, value} end)}
    end
  end

  defp files_by_id(conn) do
    with {:ok, rows} <- query(conn, "SELECT file_id, name, device_id FROM files") do
      {:ok, Map.new(rows, fn [file_id, name, device_id] -> {file_id, {name, device_id}} end)}
    end
  end

  defp group_strings({:error, reason}), do: {:error, reason}

  defp group_strings({:ok, rows}) do
    grouped =
      rows
      |> Enum.group_by(fn [file_id, _value] -> file_id end, fn [_file_id, value] -> value end)
      |> Map.new(fn {file_id, values} -> {file_id, Enum.uniq(values)} end)

    {:ok, grouped}
  end

  defp query(conn, sql) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, statement} ->
        try do
          Exqlite.Sqlite3.fetch_all(conn, statement)
        after
          Exqlite.Sqlite3.release(conn, statement)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> {{0, 0, 0}, {0, 0, 0}}
    end
  end
end
