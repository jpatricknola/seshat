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
  it at the (gitignored) project root so the file can be inspected by eye, and
  `config :seshat, :catalog_pretty` indents it there for the same reason. Both
  default to the installed-build behaviour: `~/.seshat/catalog.json`, minified.
  """

  use GenServer

  require Logger

  alias Seshat.Library.AbletonDB
  alias Seshat.OSC.Transport

  @table __MODULE__
  @default_path "~/.seshat/catalog.json"
  # 2: one row per preset rather than per browser location — `category`/`path`
  # became `categories`/`paths`, and `uris` records every location. Bumping
  # this makes an older catalog a rebuild prompt instead of a silent misread.
  @format_version 2

  # A full browser walk of every category runs on Live's UI thread and takes
  # tens of seconds on a large library.
  @export_timeout 120_000

  # The browser export is written by Python, which picks the filename: the OSC
  # request carries no path, so nothing a caller sends can steer what Live opens
  # with its own privileges. These three constants are the other half of that
  # contract — the reply is untrusted until it proves to name a regular file
  # directly inside this directory with this name shape. `Path.expand/1` matches
  # Python's `expanduser` + `abspath` (neither resolves symlinks); see
  # `abletonosc/browser.py`'s `EXPORT_ROOT`.
  @export_root "~/.seshat/browser-exports"
  @export_prefix "seshat-browser-export-"
  @export_suffix ".json"

  # An install predating the no-argument export contract answers a no-argument
  # request with its own "requires [dest_path]" error. That is a version skew,
  # not a browser failure, and the fix is never "try again".
  @stale_install_hint "Live is running an AbletonOSC older than this Seshat: " <>
                        "its browser export still expects a destination path. " <>
                        "Run `mix abletonosc.install` and restart Live."

  # Loads are frequent and the file is only a usage counter — batch the writes.
  @persist_debounce 5_000

  @default_max_results 15

  # A truncated result reports the tags that would narrow it, and a reindex
  # reports the library's most common ones — both so the model learns the local
  # vocabulary instead of guessing from a hardcoded list that can't be right on
  # every machine.
  @facet_limit 6
  @vocabulary_sample 6

  # A tag carried by most of the match set can't narrow it, so it is no use as a
  # narrowing suggestion however frequent it is.
  @facet_ubiquity 0.6

  # For a requested tag the library doesn't have: how close a real tag has to be
  # to be worth suggesting, and how many to suggest.
  @nearest_tag_distance 0.75
  @nearest_tag_limit 3

  # A `row` is one browser location: exactly what the export walked, one per
  # place a preset appears. `merge/2` produces rows. An `entry` is one preset —
  # what search and the model deal in — produced by folding a preset's rows
  # together in `normalize/1`. Keeping the two apart is what lets later
  # enrichment stages compose: each is a pure [row] -> [row] or [entry] ->
  # [entry] pass over the same list.
  @type row :: %{
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

  @type entry :: %{
          uri: String.t(),
          uris: [String.t()],
          name: String.t(),
          categories: [String.t()],
          paths: [String.t()],
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
    * `:tags` — at least one must match; the more that match, the higher the
      entry ranks (see `score/2`)
    * `:category` — restrict to one browser category
    * `:max_results` — defaults to #{@default_max_results}
    * `:table` — ETS table to read (tests only)
    * `:now` — reference time for the recency bonus (tests only)

  Returns `{entries, total_matches, facets}`. `total_matches` lets the caller
  tell "that's all of them" from "there are more"; `facets` is the tag frequency
  across *all* matches, which is what a truncated reply offers as the way to
  narrow — empty unless the result was actually truncated. A full scan at
  catalog scale (10–20k rows) is single-digit milliseconds, so there is no index
  to keep in sync.
  """
  @spec search(keyword()) :: {[entry()], non_neg_integer(), [{String.t(), pos_integer()}]}
  def search(opts \\ []) do
    max_results = Keyword.get(opts, :max_results, @default_max_results)
    opts = Keyword.put_new_lazy(opts, :now, &DateTime.utc_now/0)

    matches =
      opts
      |> Keyword.get(:table, @table)
      |> scan()
      |> Enum.filter(&matches?(&1, opts))

    ranked =
      matches
      |> Enum.map(&{score(&1, opts), &1})
      # uri, not name: deterministic across reindexes, where the alphabetical
      # tie-break used to decide almost every slot by itself.
      |> Enum.sort_by(fn {score, entry} -> {-score, entry.uri} end)
      |> take_diverse(max_results)

    total = length(matches)
    facets = if total > length(ranked), do: facets(matches, opts), else: []

    {ranked, total, facets}
  end

  @doc """
  Explain a search that matched nothing, so the model's next attempt is informed
  rather than another guess.

  Reports what each constraint matches *on its own* — the combination failed, so
  the useful question is which part of it — and, for a requested tag the library
  simply doesn't have, the nearest tags it does have with their counts. The tag
  vocabulary is per-machine (it depends on installed Packs), so this is the only
  honest way to advertise it.

  `nearest` is string similarity, which only rescues a typo or a longer form of a
  real tag. It cannot rescue a word the library has no spelling of at all —
  nothing in a stock library is within jaro 0.75 of "Warm", and the semantically
  right answer (`Soft`) is not textually near it. `narrowing_tags` is what makes
  that case recoverable: the real tags carried by what the *query* alone matches,
  which is a concrete set to retry with rather than an instruction to guess
  again.

  Pure, and only worth its extra scan when `search/1` returned nothing.
  """
  @spec diagnose(keyword()) :: %{
          query: String.t() | nil,
          query_matches: non_neg_integer() | nil,
          category: String.t() | nil,
          category_matches: non_neg_integer() | nil,
          narrowing_tags: [{String.t(), pos_integer()}],
          tags: [
            %{
              tag: String.t(),
              matches: non_neg_integer(),
              nearest: [{String.t(), pos_integer()}]
            }
          ]
        }
  def diagnose(opts \\ []) do
    entries = opts |> Keyword.get(:table, @table) |> scan()
    query = Keyword.get(opts, :query)
    category = Keyword.get(opts, :category)
    vocabulary = tag_counts(entries)

    # What the query alone reaches — the set the model should be retrying
    # against. With no query at all, the whole catalog is that set.
    scope = if blank?(query), do: entries, else: Enum.filter(entries, &matches_query?(&1, query))

    %{
      query: query,
      query_matches: if(blank?(query), do: nil, else: length(scope)),
      category: category,
      category_matches: count_unless_blank(entries, category, &matches_category?/2),
      narrowing_tags: facets(scope, opts),
      tags:
        opts
        |> Keyword.get(:tags)
        |> List.wrap()
        |> Enum.map(&diagnose_tag(&1, entries, vocabulary))
    }
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

  The success shape carries the library's tag vocabulary as well as its size, so
  the reply can teach the model the tags this machine actually has.
  """
  @spec reindex(atom()) ::
          {:ok,
           %{
             items: non_neg_integer(),
             tagged: non_neg_integer(),
             distinct_tags: non_neg_integer(),
             top_tags: [{String.t(), pos_integer()}]
           }}
          | {:error, term()}
  def reindex(server \\ __MODULE__) do
    # The export path is only known once Python has replied with it, and only
    # deleted once it has been validated — so the cleanup can't be hoisted above
    # the query the way a path we chose ourselves could be. Python sweeps up
    # anything this never gets to see (a timeout, a lost reply, a refused path).
    with {:ok, path} <- export_browser() do
      consume_export(path, Path.expand(@export_root), server)
    end
  end

  @doc false
  # Validation and deletion live in one function on purpose: every way of
  # splitting them leaves a path where Elixir has validated a file and then
  # abandons it. Reading and decoding are inside the cleanup block for exactly
  # that reason — a truncated or corrupt export is the case where we know the
  # name, so leaving it for Python's stale sweep would be a choice, not a
  # necessity. A path that fails validation is never deleted: it is not ours.
  # `expected_root` is a parameter so tests can drive the whole consume-and-
  # clean-up lifecycle against a tmp dir instead of the developer's home.
  @spec consume_export(String.t(), String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def consume_export(path, expected_root, server \\ __MODULE__) do
    with {:ok, validated} <- validated_export_path(path, expected_root) do
      try do
        with {:ok, body} <- read_export_file(validated),
             {:ok, export} <- decode_export(body),
             {:ok, entries} <- build_entries(export) do
          GenServer.call(server, {:replace, entries}, 30_000)
        end
      after
        File.rm(validated)
      end
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
  @spec merge(map(), %{integer() => AbletonDB.entry()}) :: [row()]
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
  Fold a merged export's rows so that one preset is one entry.

  Live files a preset under every device that can open it and bakes the browser
  path into the uri, so a single `.adg` arrives as two to four rows differing
  only in where they sit. Left alone they crowd the result slate: measured
  across ten realistic "describe a sound" searches, 46% of the returned rows
  were aliases of a preset already in the list.

  The key is the FileId the uri embeds. Across a real 8,222-entry catalog,
  `name`, `tags`, `description` and `tag_source` are identical in every one of
  the 1,798 multi-row clusters, and no two different names ever share a FileId
  — so the fold is lossless as long as the two fields that *do* vary become
  plural. Hence `paths` and `categories`; everything else comes from the
  canonical row.

  Rows carrying no FileId are left alone rather than merged by name — core
  devices (the only aliased pair among them is Drum Rack, under both `drums`
  and `instruments`) and plugins, where a plugin installed in two formats is
  two rows under one name (AUv2 and VST3, and the format trees are not
  mirrors). One surplus row is a better trade than guessing at identity —
  evidence in docs/archive/catalog-aliasing-options.md.
  """
  @spec normalize([row()]) :: [entry()]
  def normalize(rows) do
    rows
    |> Enum.group_by(&fold_key/1)
    |> Enum.map(fn {_key, group} -> fold(group) end)
    # Sorted so a rebuilt catalog.json diffs cleanly against the last one
    # rather than reshuffling with ETS/map iteration order.
    |> Enum.sort_by(& &1.uri)
  end

  defp fold_key(row) do
    case file_id(row.uri) do
      nil -> {:uri, row.uri}
      id -> {:file_id, id}
    end
  end

  defp fold(rows) do
    # The alias uris are interchangeable — `_find_item` in browser.py scans
    # every category, so all of them resolve — but the choice must be stable,
    # or `use_count` detaches from its preset on the next reindex.
    [canonical | _] = sorted = Enum.sort_by(rows, & &1.uri)

    %{
      uri: canonical.uri,
      uris: Enum.map(sorted, & &1.uri),
      name: canonical.name,
      categories: sorted |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort(),
      paths: sorted |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort(),
      tags: canonical.tags,
      tag_source: canonical.tag_source,
      description: canonical.description,
      use_count: canonical.use_count,
      last_loaded_at: canonical.last_loaded_at
    }
  end

  @doc """
  Carry `use_count`/`last_loaded_at` from an older set of entries onto newly
  merged ones, so a reindex doesn't forget what the user actually reaches for.

  Indexed by *every* alias uri, not just the canonical one: installing a Pack
  can add a browser location that sorts ahead of the old canonical pick, and
  the counter should follow the preset rather than the uri that happened to
  win last time.
  """
  @spec carry_over_usage([entry()], [entry()]) :: [entry()]
  def carry_over_usage(entries, previous) do
    previous_by_uri = for old <- previous, uri <- old.uris, into: %{}, do: {uri, old}

    Enum.map(entries, fn entry ->
      case Enum.find_value(entry.uris, &Map.get(previous_by_uri, &1)) do
        nil -> entry
        old -> %{entry | use_count: old.use_count, last_loaded_at: old.last_loaded_at}
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

  # At least one requested tag, not all of them: a strict AND meant one tag the
  # library doesn't have zeroed the whole search, and the advertised vocabulary
  # is a guess by construction. How *many* matched moves into `score/2`, so tags
  # still order the slate — they just no longer empty it. Keeping the
  # one-tag-minimum rather than scoring alone is what keeps `tags` meaningful:
  # with no filter, `tags: ["Analog"]` would "match" the entire catalog and the
  # total the reply reports would stop meaning anything.
  defp matches_tags?(_entry, nil), do: true
  defp matches_tags?(_entry, []), do: true

  defp matches_tags?(entry, tags) do
    entry_tags = normalize_tags(entry)

    Enum.any?(tags, &(tag_match(entry_tags, &1) != :none))
  end

  defp matches_category?(_entry, nil), do: true
  defp matches_category?(_entry, ""), do: true
  defp matches_category?(entry, category), do: to_string(category) in entry.categories

  defp haystack(entry) do
    # Every browser location a preset has is searchable, so folding aliases
    # away costs no recall: "operator" still finds a preset filed under
    # Operator even though only one of its uris survived the fold.
    [entry.name, entry.description || "" | entry.paths ++ entry.categories ++ entry.tags]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end

  # Tags fold to bare alphanumerics on both sides, so 'hi-hat' reaches
  # 'Closed Hihat' and 'pads' reaches 'Pad' — mechanical string folding, not
  # semantics. Mapping "warm" onto Soft/Acoustic is the model's job.
  defp normalize_tag(tag) do
    tag |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
  end

  defp normalize_tags(entry) do
    Enum.map(entry.tags, fn tag ->
      {normalize_tag(tag), tokens(String.downcase(tag))}
    end)
  end

  # `:exact` | `:substring` | `:none`, strongest first — a requested tag scores
  # one or the other, never both. Substring semantics are kept from the strict-AND
  # days (`bass` still reaches `808 Bass`) but no longer look the same as a
  # deliberate hit, which is most of the ranking signal tags now carry.
  # Each entry tag arrives as `{normalized, words}` — 'Closed Hihat' as
  # `{"closedhihat", ["closed", "hihat"]}` — because the two forms answer
  # different questions and normalizing destroys the word boundaries the plural
  # rule needs.
  defp tag_match(entry_tags, requested) do
    wanted = normalize_tag(requested)
    # A plural the library spells singular. The stripped form may match a tag
    # whole, or match one whole *word* of a multi-word tag — never a bare
    # substring of one. That distinction is the whole rule: as a substring
    # 'bass' becomes 'bas' and drags in all 598 'Basic' presets, while as a word
    # 'hihats' correctly reaches the 395 'Closed/Open/Pedal Hihat' ones.
    singular = depluralize(wanted)

    cond do
      wanted == "" ->
        :none

      Enum.any?(entry_tags, fn {tag, _words} -> tag == wanted end) ->
        :exact

      singular != "" and Enum.any?(entry_tags, fn {tag, _words} -> tag == singular end) ->
        :exact

      Enum.any?(entry_tags, fn {tag, _words} -> String.contains?(tag, wanted) end) ->
        :substring

      singular != "" and Enum.any?(entry_tags, fn {_tag, words} -> singular in words end) ->
        :substring

      true ->
        :none
    end
  end

  defp depluralize(tag) do
    case String.replace_suffix(tag, "s", "") do
      ^tag -> ""
      singular -> singular
    end
  end

  @doc """
  Rank one entry against the search options. Higher sorts first.

  | component | value |
  |---|---|
  | requested tag matched exactly (normalized) | +4 each |
  | requested tag matched as a substring only | +2 each |
  | every query term a whole token in the name | +6 |
  | every query term a substring of the name | +4 |
  | at least one query term in the name | +2 |
  | every query term found in name or tags | +2 |
  | tagged by Ableton rather than by folder path | +1 |
  | usage | `min(use_count, 3)`, +2 loaded within 14 days, +1 within 90 |

  The three name components are one tiered `cond` — only the highest applicable
  one counts, so `Pad` the whole word beats `pad` inside "Padlock" rather than
  scoring on top of it. Everything else stacks. The point of the spread is that
  ties should be *rare*: before this, five of six realistic searches had every
  returned slot decided by the alphabetical tie-break rather than by score.
  """
  @spec score(entry(), keyword()) :: integer()
  def score(entry, opts) do
    query_terms = terms(Keyword.get(opts, :query) || "")
    name = String.downcase(entry.name)
    name_tokens = tokens(name)

    name_score =
      cond do
        query_terms == [] -> 0
        Enum.all?(query_terms, &(&1 in name_tokens)) -> 6
        Enum.all?(query_terms, &String.contains?(name, &1)) -> 4
        Enum.any?(query_terms, &String.contains?(name, &1)) -> 2
        true -> 0
      end

    name_score + kind_score(entry, name, query_terms) + tag_score(entry, opts) +
      source_score(entry) + usage_score(entry, Keyword.get(opts, :now))
  end

  # The words for what a sound *is* live in its name and its tags; a term found
  # only in the folder path or in the "Created by:" credit line is a weaker hit.
  defp kind_score(_entry, _name, []), do: 0

  defp kind_score(entry, name, query_terms) do
    haystack = Enum.join([name | Enum.map(entry.tags, &String.downcase/1)], " ")

    if Enum.all?(query_terms, &String.contains?(haystack, &1)), do: 2, else: 0
  end

  defp tag_score(entry, opts) do
    case List.wrap(Keyword.get(opts, :tags)) do
      [] ->
        0

      requested ->
        entry_tags = normalize_tags(entry)

        Enum.reduce(requested, 0, fn tag, total ->
          case tag_match(entry_tags, tag) do
            :exact -> total + 4
            :substring -> total + 2
            :none -> total
          end
        end)
    end
  end

  defp source_score(%{tag_source: :ableton}), do: 1
  defp source_score(_entry), do: 0

  # Recency-decayed rather than flat: something loaded last week is a better bet
  # than something loaded once a year ago.
  defp usage_score(entry, now) do
    min(entry.use_count, 3) + recency_score(entry.last_loaded_at, now)
  end

  defp recency_score(nil, _now), do: 0
  defp recency_score(_timestamp, nil), do: 0

  defp recency_score(timestamp, now) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, loaded, _offset} ->
        case DateTime.diff(now, loaded, :day) do
          days when days <= 14 -> 2
          days when days <= 90 -> 1
          _older -> 0
        end

      {:error, _reason} ->
        0
    end
  end

  defp tokens(text), do: String.split(text, ~r/[^\p{L}\p{N}]+/u, trim: true)

  # --- Truncation (pure) ---

  # Even a good scorer leaves tied bands on a broad query, and taking a tie in
  # sort order hands every remaining slot to one corner of the library — the 26
  # Apple utility AUs flooding a "reverb" slate is the same effect the old
  # alphabetical sort had, one letter at a time. Bands that fit are taken whole;
  # only the band straddling the cut is rotated, across device roots, so the
  # slate spans devices instead of neighbours.
  defp take_diverse(_scored, max_results) when max_results <= 0, do: []

  defp take_diverse(scored, max_results) do
    scored
    |> Enum.chunk_by(fn {score, _entry} -> score end)
    |> Enum.reduce_while({[], max_results}, fn band, {taken, remaining} ->
      entries = Enum.map(band, fn {_score, entry} -> entry end)

      cond do
        remaining <= 0 -> {:halt, {taken, 0}}
        length(entries) <= remaining -> {:cont, {taken ++ entries, remaining - length(entries)}}
        true -> {:halt, {taken ++ round_robin(entries, remaining), 0}}
      end
    end)
    |> elem(0)
  end

  defp round_robin(entries, count) do
    groups = Enum.group_by(entries, &device_root/1)

    entries
    |> Enum.map(&device_root/1)
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(groups, &1))
    |> interleave()
    |> Enum.take(count)
  end

  # Order within a group stays uri-sorted, and groups keep the order they first
  # appear in, so the rotation is deterministic.
  defp interleave([]), do: []

  defp interleave(lists) do
    {heads, rests} =
      Enum.reduce(lists, {[], []}, fn [head | rest], {heads, rests} ->
        {[head | heads], if(rest == [], do: rests, else: [rest | rests])}
      end)

    Enum.reverse(heads) ++ interleave(Enum.reverse(rests))
  end

  # The device a preset is filed under — `Operator`, `Analog`, `AUv2`. Taking the
  # first path unconditionally would not rotate across devices at all: a preset's
  # `sounds` path carries no device prefix, so an Operator bass (`["Bass",
  # "Operator/Bass"]`) would group under `Bass` while an Analog one
  # (`["Analog/Bass", "Bass"]`) groups under `Analog`, purely by accident of the
  # device's initial. Hence the first *device-prefixed* path, with the bare
  # character folder as the fallback for presets that only have those.
  defp device_root(entry) do
    paths = List.wrap(entry.paths)
    path = Enum.find(paths, &String.contains?(&1, "/")) || List.first(paths) || ""

    path |> String.split("/") |> List.first() || ""
  end

  # --- Facets and diagnosis (pure) ---

  # What the model could add to narrow a truncated result. A tag it already asked
  # for narrows nothing, and neither does one carried by most of the match set.
  defp facets(matches, opts) do
    requested =
      opts
      |> Keyword.get(:tags)
      |> List.wrap()
      |> Enum.flat_map(fn tag ->
        normalized = normalize_tag(tag)
        [normalized, depluralize(normalized)]
      end)
      |> MapSet.new()

    ceiling = length(matches) * @facet_ubiquity

    matches
    |> tag_counts()
    |> Enum.reject(fn {tag, count} ->
      MapSet.member?(requested, normalize_tag(tag)) or count > ceiling
    end)
    |> Enum.sort_by(fn {tag, count} -> {-count, tag} end)
    |> Enum.take(@facet_limit)
  end

  defp diagnose_tag(tag, entries, vocabulary) do
    matches = Enum.count(entries, &matches_tags?(&1, [tag]))

    %{
      tag: tag,
      matches: matches,
      nearest: if(matches == 0, do: nearest_tags(tag, vocabulary), else: [])
    }
  end

  # A tag the library doesn't have is a dead end unless the reply says what it
  # *does* have. Jaro catches a misspelling or a near-miss ('Warm' → 'Warmth');
  # containment catches the requested tag being a longer form of a real one,
  # which the substring matcher can't see because it only looks the other way.
  defp nearest_tags(tag, vocabulary) do
    wanted = normalize_tag(tag)

    vocabulary
    |> Enum.filter(fn {real, _count} ->
      normalized = normalize_tag(real)

      normalized != "" and wanted != "" and
        (String.jaro_distance(wanted, normalized) >= @nearest_tag_distance or
           String.contains?(normalized, wanted) or String.contains?(wanted, normalized))
    end)
    |> Enum.sort_by(fn {real, count} -> {-count, real} end)
    |> Enum.take(@nearest_tag_limit)
  end

  defp tag_counts(entries) do
    entries |> Enum.flat_map(& &1.tags) |> Enum.frequencies()
  end

  # A constraint that wasn't set has no count to report — nil, not zero, so the
  # reply can tell "matches nothing" from "wasn't asked for".
  defp count_unless_blank(_entries, constraint, _matcher) when constraint in [nil, ""], do: nil

  defp count_unless_blank(entries, constraint, matcher),
    do: Enum.count(entries, &matcher.(&1, constraint))

  defp blank?(value), do: value in [nil, ""]

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

      {:error, :stale_format} ->
        Logger.info(
          "Catalog: #{state.path} was written in an older format — " <>
            "run reindex_library to rebuild it"
        )

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

    summary = summarise(entries)

    case write_file(state.path, entries) do
      :ok ->
        {:reply, {:ok, summary}, state}

      {:error, reason} ->
        Logger.warning("Catalog: could not write #{state.path}: #{inspect(reason)}")
        {:reply, {:ok, summary}, state}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, write_file(state.path, all_entries(state.table)), cancel_timer(state)}
  end

  @impl true
  def handle_cast({:record_load, uri}, state) do
    case find_entry(state.table, uri) do
      nil ->
        {:noreply, state}

      entry ->
        updated = %{
          entry
          | use_count: entry.use_count + 1,
            last_loaded_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :ets.insert(state.table, {entry.uri, updated})
        {:noreply, schedule_persist(state)}
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

  defp export_browser do
    case Transport.query("/live/browser/export", [], @export_timeout) do
      {:ok, {_address, [path, "ok", _total]}} when is_binary(path) ->
        {:ok, path}

      # Matched before the generic error below: this exact message is the old
      # handler's, and it means the install is stale rather than the walk failed.
      {:ok, {_address, [_path, "error", "export requires [dest_path]" <> _]}} ->
        {:error, @stale_install_hint}

      {:ok, {_address, [_path, "error", message]}} ->
        {:error, message}

      {:ok, {_address, args}} ->
        {:error,
         "Unexpected reply from Live's browser: #{inspect(args)}. " <>
           "If Live's AbletonOSC predates this Seshat, run " <>
           "`mix abletonosc.install` and restart Live."}

      # A timeout is not an {:error, :timeout} here — Transport.query/3 is a
      # GenServer.call, so exceeding @export_timeout exits the caller. The
      # `reindex_library` handler catches that exit and already answers with the
      # "is Ableton running, has mix abletonosc.install been run" advice, which is
      # the same instruction the stale-install hint above gives.
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # The reply path is data from another process, so it is checked before any
  # filesystem call touches it — and the lstat lives here rather than in the
  # caller, because a path check that stops at string arithmetic is the half that
  # never gets tested. `expected_root` is a parameter for exactly that reason:
  # tests point it at a tmp dir instead of the developer's home.
  @spec validated_export_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validated_export_path(path, expected_root)
      when is_binary(path) and is_binary(expected_root) do
    expanded = Path.expand(path)
    basename = Path.basename(expanded)
    root = Path.expand(expected_root)

    cond do
      Path.dirname(expanded) != root ->
        {:error,
         "Live's browser export replied with #{inspect(path)}, which is not directly " <>
           "inside #{root}. Nothing was read or deleted."}

      not (String.starts_with?(basename, @export_prefix) and
               String.ends_with?(basename, @export_suffix)) ->
        {:error,
         "Live's browser export replied with #{inspect(path)}, which is not named " <>
           "#{@export_prefix}*#{@export_suffix}. Nothing was read or deleted."}

      true ->
        case File.lstat(expanded) do
          {:ok, %File.Stat{type: :regular}} ->
            {:ok, expanded}

          {:ok, %File.Stat{type: type}} ->
            {:error,
             "Live's browser export replied with #{inspect(path)}, which is a #{type}, " <>
               "not a regular file. Nothing was read or deleted."}

          {:error, reason} ->
            {:error,
             "Live's browser export replied with #{inspect(path)}, which could not be " <>
               "read: #{inspect(reason)}"}
        end
    end
  end

  defp read_export_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp decode_export(body) do
    case Jason.decode(body) do
      {:ok, export} when is_map(export) ->
        {:ok, export}

      {:ok, other} ->
        {:error, "The browser export was not a JSON object: #{inspect(other)}"}

      {:error, error} ->
        {:error, "Could not decode the browser export: #{Exception.message(error)}"}
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

    # The indexing pipeline: faithful rows out of the export, then one pure
    # pass per transform. Further enrichment belongs here as another stage.
    {:ok, export |> merge(db_index) |> normalize()}
  end

  defp all_entries(table) do
    :ets.select(table, [{{:_, :"$1"}, [], [:"$1"]}])
  end

  # Search and diagnose read the table directly and must answer before the first
  # reindex has created it — an unbuilt catalog is empty, not an error.
  defp scan(table) do
    case :ets.info(table) do
      :undefined -> []
      _info -> all_entries(table)
    end
  end

  # The table is keyed by canonical uri only, but a load can arrive via any
  # of a preset's alias uris — from list_browser_items, or remembered from
  # before a reindex shifted the canonical pick. The counter belongs to the
  # preset, so a key miss falls back to scanning the alias lists. Loads are
  # rare and the table is a few thousand rows; the scan is not worth an index.
  defp find_entry(table, uri) do
    case :ets.lookup(table, uri) do
      [{^uri, entry}] -> entry
      [] -> Enum.find(all_entries(table), &(uri in &1.uris))
    end
  end

  # The reindex reply is the one place the model learns this library's real tag
  # vocabulary, exactly when it changes — and this callback is the only place the
  # fresh entry list is already in hand. A hardcoded list in the tool description
  # can't be right on every machine; installed Packs decide the vocabulary.
  defp summarise(entries) do
    counts = tag_counts(entries)

    %{
      items: length(entries),
      tagged: Enum.count(entries, &(&1.tag_source == :ableton)),
      distinct_tags: map_size(counts),
      top_tags:
        counts
        |> Enum.sort_by(fn {tag, count} -> {-count, tag} end)
        |> Enum.take(@vocabulary_sample)
    }
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

  # The version is matched, not just written. Without that a catalog from an
  # older format loads silently through the current `from_json/1` — no error,
  # no crash, just entries with empty `categories`/`paths`, which reads as "the
  # library has nothing like that" rather than "this file is stale".
  defp load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"version" => @format_version, "entries" => entries}} <- Jason.decode(body) do
      {:ok, Enum.map(entries, &from_json/1)}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, error}
      {:ok, %{"entries" => _}} -> {:error, :stale_format}
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
         {:ok, body} <- Jason.encode(payload, pretty: pretty?()) do
      File.write(path, body)
    end
  end

  # Indented output is ~1.45x the bytes and ~300ms slower to encode, which only
  # buys something where a human reads the file — dev. `Jason.decode` takes
  # either form, so this is free to flip and old catalogs still load.
  defp pretty?, do: Application.get_env(:seshat, :catalog_pretty, false)

  defp to_json(entry) do
    %{
      "uri" => entry.uri,
      "uris" => entry.uris,
      "name" => entry.name,
      "categories" => entry.categories,
      "paths" => entry.paths,
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
      uris: row["uris"] || [row["uri"]],
      name: row["name"] || "",
      categories: row["categories"] || [],
      paths: row["paths"] || [],
      tags: row["tags"] || [],
      tag_source: if(row["tag_source"] == "ableton", do: :ableton, else: :path),
      description: row["description"],
      use_count: row["use_count"] || 0,
      last_loaded_at: row["last_loaded_at"]
    }
  end
end
