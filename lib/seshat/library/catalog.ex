defmodule Seshat.Library.Catalog do
  @moduledoc """
  Persistent, tag-aware index of everything loadable in Live's browser.

  `list_browser_items` answers "what is called 'bass'?" — 267 flat names the
  model has to pick from nearly blind. This answers "what *sounds* like a warm
  analog bass?", by merging two sources we already have on disk:

    * the browser walk (`/live/browser/export`), the only source of loadable
      uris, and
    * Ableton's own database (`Seshat.Library.AbletonDB`), the only source of
      the tags its sound designers wrote.

  The join is exact: preset uris embed the database primary key
  (`query:Sounds#Bass:FileId_5200` → `files.file_id = 5200`). Both halves are
  captured in a single `reindex/1` pass, because a FileId is only meaningful
  against the same database build the uri came from.

  Follows the `Seshat.Session.State` pattern — a GenServer owning in-memory
  state — with one addition: the merged catalog is written to
  `~/.seshat/catalog.json` so search keeps working with Ableton closed, and
  reindexing is something a user does after installing Packs rather than on
  every boot. Rows live in ETS, read directly by callers; the GenServer owns
  writes only. No Ecto, no database of our own.

  The location is overridable via `config :seshat, :catalog_path` — dev points
  it at the (gitignored) project root so the file can be inspected by eye.
  """

  use GenServer

  require Logger

  alias Seshat.Library.AbletonDB
  alias Seshat.OSC.Transport

  @table __MODULE__
  @default_path "~/.seshat/catalog.json"
  @format_version 1

  # A full browser walk of every category runs on Live's UI thread and takes
  # tens of seconds on a large library.
  @export_timeout 120_000

  # Loads are frequent and the file is only a usage counter — batch the writes.
  @persist_debounce 5_000

  @default_max_results 15

  @type entry :: %{
          uri: String.t(),
          name: String.t(),
          category: String.t(),
          path: String.t(),
          tags: [String.t()],
          tag_source: :ableton | :path,
          description: String.t() | nil,
          use_count: non_neg_integer(),
          last_loaded_at: String.t() | nil
        }

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Search the catalog.

  Options:

    * `:query` — case-insensitive AND-of-terms over name, path, tags and
      description
    * `:tags` — every tag listed must be on the entry
    * `:category` — restrict to one browser category
    * `:max_results` — defaults to #{@default_max_results}
    * `:table` — ETS table to read (tests only)

  Returns `{entries, total_matches}` so the caller can tell "that's all of
  them" from "there are more". A full scan at catalog scale (10–20k rows) is
  single-digit milliseconds, so there is no index to keep in sync.
  """
  @spec search(keyword()) :: {[entry()], non_neg_integer()}
  def search(opts \\ []) do
    table = Keyword.get(opts, :table, @table)
    max_results = Keyword.get(opts, :max_results, @default_max_results)

    entries =
      case :ets.info(table) do
        :undefined -> []
        _ -> :ets.select(table, [{{:_, :"$1"}, [], [:"$1"]}])
      end

    matches = Enum.filter(entries, &matches?(&1, opts))

    ranked =
      matches
      |> Enum.sort_by(&{-score(&1, opts), &1.name})
      |> Enum.take(max_results)

    {ranked, length(matches)}
  end

  @doc "How many entries the catalog currently holds."
  @spec count(atom()) :: non_neg_integer()
  def count(table \\ @table) do
    case :ets.info(table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  @doc """
  Rebuild the catalog: export Live's browser, read Ableton's tags, merge, save.

  Both halves are captured in this one pass — see the module doc on why they
  must not be mixed across passes. Existing usage counters survive.
  """
  @spec reindex(atom()) ::
          {:ok, %{items: non_neg_integer(), tagged: non_neg_integer()}} | {:error, term()}
  def reindex(server \\ __MODULE__) do
    export_path =
      Path.join(
        System.tmp_dir!(),
        "seshat-browser-export-#{System.unique_integer([:positive])}.json"
      )

    try do
      with {:ok, export} <- export_browser(export_path),
           {:ok, entries} <- build_entries(export) do
        GenServer.call(server, {:replace, entries}, 30_000)
      end
    after
      File.rm(export_path)
    end
  end

  @doc """
  Note that a uri was successfully loaded, so search can favour it later.

  Fire-and-forget: a catalog that isn't running (or a uri it has never heard
  of) must never turn a successful device load into an error.
  """
  @spec record_load(String.t(), atom()) :: :ok
  def record_load(uri, server \\ __MODULE__) when is_binary(uri) do
    GenServer.cast(server, {:record_load, uri})
  end

  # --- Merge (pure) ---

  @doc """
  Merge a browser export with Ableton's tag database into catalog entries.

  Three tiers, in order:

    1. the uri carries `FileId_<n>` — an exact join on `files.file_id`, which
       covers presets, drum hits and samples (~95% of preset rows are tagged);
    2. no FileId — a bare core device such as `query:Synths#Analog`. Those are
       a set of ~50 and their `files` rows carry tags too, so match by name;
    3. neither — fall back to the folder path as tags, which is roughly what a
       human reading the browser would infer anyway.
  """
  @spec merge(map(), %{integer() => AbletonDB.entry()}) :: [entry()]
  def merge(export, db_index) do
    by_name = index_devices_by_name(db_index)

    for {category, items} <- export,
        item <- items,
        uri = value(item, "uri"),
        is_binary(uri) and uri != "" do
      build_entry(category, item, db_index, by_name)
    end
  end

  @doc """
  Carry `use_count`/`last_loaded_at` from an older set of entries onto newly
  merged ones, so a reindex doesn't forget what the user actually reaches for.
  """
  @spec carry_over_usage([entry()], [entry()]) :: [entry()]
  def carry_over_usage(entries, previous) do
    previous_by_uri = Map.new(previous, &{&1.uri, &1})

    Enum.map(entries, fn entry ->
      case Map.fetch(previous_by_uri, entry.uri) do
        {:ok, old} ->
          %{entry | use_count: old.use_count, last_loaded_at: old.last_loaded_at}

        :error ->
          entry
      end
    end)
  end

  defp build_entry(category, item, db_index, by_name) do
    name = value(item, "name") || ""
    path = value(item, "path") || ""
    uri = value(item, "uri")

    base = %{
      uri: uri,
      name: name,
      category: to_string(category),
      path: path,
      use_count: 0,
      last_loaded_at: nil
    }

    case lookup(uri, name, db_index, by_name) do
      %{tags: tags, description: description} when tags != [] ->
        Map.merge(base, %{tags: tags, tag_source: :ableton, description: description})

      %{description: description} ->
        Map.merge(base, %{tags: path_tags(path), tag_source: :path, description: description})

      nil ->
        Map.merge(base, %{tags: path_tags(path), tag_source: :path, description: nil})
    end
  end

  defp lookup(uri, name, db_index, by_name) do
    case file_id(uri) do
      nil -> Map.get(by_name, String.downcase(name))
      id -> Map.get(db_index, id) || Map.get(by_name, String.downcase(name))
    end
  end

  @doc """
  Extract the `files.file_id` a browser uri embeds, if it has one.

  `query:Sounds#Bass:FileId_5200` → `5200`. Core devices carry no FileId.
  """
  @spec file_id(String.t() | nil) :: integer() | nil
  def file_id(uri) when is_binary(uri) do
    case Regex.run(~r/FileId_(\d+)/, uri) do
      [_, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  def file_id(_), do: nil

  # Core devices have no FileId in their uri, so name is the only join left.
  # Restricting to rows that carry a device_id keeps that name match from
  # colliding with the thousands of presets that share a device's name.
  defp index_devices_by_name(db_index) do
    db_index
    |> Enum.filter(fn {_id, entry} -> is_binary(entry.device_id) and entry.device_id != "" end)
    |> Map.new(fn {_id, entry} -> {String.downcase(entry.name || ""), entry} end)
  end

  defp path_tags(""), do: []

  defp path_tags(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Export rows arrive string-keyed from Jason; atom keys are tolerated so the
  # merge is pleasant to call from tests and iex.
  defp value(item, "name"), do: Map.get(item, "name") || Map.get(item, :name)
  defp value(item, "path"), do: Map.get(item, "path") || Map.get(item, :path)
  defp value(item, "uri"), do: Map.get(item, "uri") || Map.get(item, :uri)

  # --- Search (pure) ---

  defp matches?(entry, opts) do
    matches_query?(entry, Keyword.get(opts, :query)) and
      matches_tags?(entry, Keyword.get(opts, :tags)) and
      matches_category?(entry, Keyword.get(opts, :category))
  end

  defp matches_query?(_entry, nil), do: true
  defp matches_query?(_entry, ""), do: true

  defp matches_query?(entry, query) do
    haystack = haystack(entry)
    Enum.all?(terms(query), &String.contains?(haystack, &1))
  end

  defp matches_tags?(_entry, nil), do: true
  defp matches_tags?(_entry, []), do: true

  defp matches_tags?(entry, tags) do
    entry_tags = Enum.map(entry.tags, &String.downcase/1)

    Enum.all?(tags, fn tag ->
      wanted = String.downcase(tag)
      Enum.any?(entry_tags, &String.contains?(&1, wanted))
    end)
  end

  defp matches_category?(_entry, nil), do: true
  defp matches_category?(_entry, ""), do: true
  defp matches_category?(entry, category), do: entry.category == to_string(category)

  defp haystack(entry) do
    [entry.name, entry.path, entry.category, entry.description || "" | entry.tags]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end

  # A name hit beats a hit buried in the folder path or description, and
  # something the user has actually loaded before beats something they haven't.
  defp score(entry, opts) do
    name = String.downcase(entry.name)
    query_terms = terms(Keyword.get(opts, :query) || "")

    name_score =
      cond do
        query_terms == [] -> 0
        Enum.all?(query_terms, &String.contains?(name, &1)) -> 4
        Enum.any?(query_terms, &String.contains?(name, &1)) -> 2
        true -> 0
      end

    tag_score = if entry.tag_source == :ableton, do: 1, else: 0

    name_score + tag_score + min(entry.use_count, 3)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    path = Keyword.get(opts, :path, catalog_path())

    :ets.new(table, [:set, :protected, :named_table, read_concurrency: true])

    # Trap exits so terminate/2 runs on shutdown and can flush a pending
    # debounced write — otherwise the last few use_count bumps are lost.
    Process.flag(:trap_exit, true)

    state = %{table: table, path: path, persist_timer: nil}
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    case load_file(state.path) do
      {:ok, entries} ->
        insert_all(state.table, entries)
        Logger.info("Catalog: loaded #{length(entries)} entries from #{state.path}")

      {:error, :enoent} ->
        Logger.info("Catalog: no catalog at #{state.path} — run reindex_library to build one")

      {:error, reason} ->
        Logger.warning("Catalog: could not load #{state.path}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:replace, entries}, _from, state) do
    entries = carry_over_usage(entries, all_entries(state.table))

    :ets.delete_all_objects(state.table)
    insert_all(state.table, entries)

    tagged = Enum.count(entries, &(&1.tag_source == :ableton))

    case write_file(state.path, entries) do
      :ok ->
        {:reply, {:ok, %{items: length(entries), tagged: tagged}}, state}

      {:error, reason} ->
        Logger.warning("Catalog: could not write #{state.path}: #{inspect(reason)}")
        {:reply, {:ok, %{items: length(entries), tagged: tagged}}, state}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, write_file(state.path, all_entries(state.table)), cancel_timer(state)}
  end

  @impl true
  def handle_cast({:record_load, uri}, state) do
    case :ets.lookup(state.table, uri) do
      [{^uri, entry}] ->
        updated = %{
          entry
          | use_count: entry.use_count + 1,
            last_loaded_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :ets.insert(state.table, {uri, updated})
        {:noreply, schedule_persist(state)}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:persist, state) do
    write_file(state.path, all_entries(state.table))
    {:noreply, %{state | persist_timer: nil}}
  end

  # A pending timer means unwritten usage bumps — flush them before dying.
  @impl true
  def terminate(_reason, %{persist_timer: nil}), do: :ok

  def terminate(_reason, state) do
    write_file(state.path, all_entries(state.table))
  end

  # --- Private ---

  defp export_browser(export_path) do
    case Transport.query("/live/browser/export", [export_path], @export_timeout) do
      {:ok, {_address, [_path, "ok", _total]}} ->
        read_export(export_path)

      {:ok, {_address, [_path, "error", message]}} ->
        {:error, message}

      {:ok, {_address, args}} ->
        {:error, "Unexpected reply from Live's browser: #{inspect(args)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_export(export_path) do
    with {:ok, body} <- File.read(export_path),
         {:ok, export} <- Jason.decode(body) do
      {:ok, export}
    else
      {:error, reason} -> {:error, "Could not read the browser export: #{inspect(reason)}"}
    end
  end

  # Tags are a bonus, never a precondition: if Live's database has moved or its
  # schema has drifted, we still index every uri with path-derived tags.
  defp build_entries(export) do
    db_index =
      with {:ok, db_path} <- AbletonDB.locate_db(),
           {:ok, index} <- AbletonDB.read_tags(db_path) do
        index
      else
        {:error, reason} ->
          Logger.warning("Catalog: no tags from Ableton's database (#{inspect(reason)})")
          %{}
      end

    {:ok, merge(export, db_index)}
  end

  defp all_entries(table) do
    :ets.select(table, [{{:_, :"$1"}, [], [:"$1"]}])
  end

  defp insert_all(table, entries) do
    :ets.insert(table, Enum.map(entries, &{&1.uri, &1}))
  end

  defp schedule_persist(%{persist_timer: nil} = state) do
    %{state | persist_timer: Process.send_after(self(), :persist, @persist_debounce)}
  end

  defp schedule_persist(state), do: state

  defp cancel_timer(%{persist_timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.persist_timer)
    %{state | persist_timer: nil}
  end

  defp catalog_path do
    Application.get_env(:seshat, :catalog_path, @default_path) |> Path.expand()
  end

  defp load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"entries" => entries}} <- Jason.decode(body) do
      {:ok, Enum.map(entries, &from_json/1)}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, error}
      {:ok, _other} -> {:error, :unrecognised_format}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_file(path, entries) do
    payload = %{
      "version" => @format_version,
      "indexed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "entries" => Enum.map(entries, &to_json/1)
    }

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, body} <- Jason.encode(payload) do
      File.write(path, body)
    end
  end

  defp to_json(entry) do
    %{
      "uri" => entry.uri,
      "name" => entry.name,
      "category" => entry.category,
      "path" => entry.path,
      "tags" => entry.tags,
      "tag_source" => to_string(entry.tag_source),
      "description" => entry.description,
      "use_count" => entry.use_count,
      "last_loaded_at" => entry.last_loaded_at
    }
  end

  defp from_json(row) do
    %{
      uri: row["uri"],
      name: row["name"] || "",
      category: row["category"] || "",
      path: row["path"] || "",
      tags: row["tags"] || [],
      tag_source: if(row["tag_source"] == "ableton", do: :ableton, else: :path),
      description: row["description"],
      use_count: row["use_count"] || 0,
      last_loaded_at: row["last_loaded_at"]
    }
  end
end
