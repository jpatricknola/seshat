defmodule Seshat.Eval.Surface do
  @moduledoc """
  A frozen copy of the model-facing MCP contract: the server `instructions` and
  the exact tool list `tools/list` would publish.

  This is what makes a base/head routing comparison possible at all. Only one
  Seshat can bind AbletonOSC's reply port, so the two surfaces can never both be
  *running*; instead each is captured as data and replayed by
  `Seshat.Eval.Recorder`, which never sends a datagram. The base snapshot
  (`priv/routing_eval/surfaces/base-c3096d6.json`, 67 tools) was captured once
  from a worktree at `c3096d6` — the last commit before the #76/#77
  consolidation — and is committed. The head surface is generated from the
  checkout at run time and is never committed.

  ## Why the tools go through Anubis's own encoder

  `current/1` asks `Anubis.Server.Handlers.Tools.handle_list/3` for the list and
  encodes the returned components with the `JSON.Encoder` implementation Anubis
  defines for them, then decodes back to string-keyed maps. Reimplementing the
  published shape by hand from `Seshat.Tools.Definitions` would silently omit
  whatever Anubis adds — `title` today, an optional protocol field tomorrow — and
  the whole point of the snapshot is that the model sees what a real client sees.

  No application start and no subprocess is involved: `handle_list/3` reads
  `__components__(:tool)` off the server module and a bare `%Frame{}`.
  """

  alias Anubis.Server.Frame
  alias Anubis.Server.Handlers.Tools, as: ToolsHandler
  alias Seshat.Instructions
  alias Seshat.MCP.Server

  @enforce_keys [:id, :revision, :instructions, :tools]
  defstruct [:id, :revision, :captured_at, :instructions, :tools]

  @type tool :: %{String.t() => term()}

  @type t :: %__MODULE__{
          id: String.t(),
          revision: String.t(),
          captured_at: String.t() | nil,
          instructions: String.t() | nil,
          tools: [tool()]
        }

  # Reads that cost nothing and change nothing. `get_*` covers most of them; the
  # three exceptions are named because their verbs aren't "get" but their effect
  # on the Set is the same as one. `reindex_library` writes a file of Seshat's
  # own, never the Live Set, and is a read as far as routing is concerned.
  @extra_reads ~w(search_library list_browser_items reindex_library)

  # View calls change what Live *shows*, never the Set. `Seshat.Instructions`
  # actively teaches the model to send one before a view-specific action, so
  # counting one as a mutation would fail a trial for obeying the instructions
  # under test.
  @view_tools ~w(show_view hide_view select_track select_scene)

  @doc """
  The current checkout's surface, tagged with `revision`.

  The revision is supplied by the caller rather than resolved here: shelling out
  to `git` belongs at the Mix-task boundary, and this module stays pure.
  """
  @spec current(String.t()) :: t()
  def current(revision) when is_binary(revision) do
    %__MODULE__{
      id: "head",
      revision: revision,
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      instructions: Instructions.text(),
      tools: published_tools()
    }
  end

  defp published_tools do
    {:reply, %{"tools" => tools}, _frame} =
      ToolsHandler.handle_list(%{}, %Frame{}, Server)

    Enum.map(tools, fn tool -> tool |> JSON.encode!() |> JSON.decode!() end)
  end

  @doc "Every tool name on this surface, in publication order."
  @spec tool_names(t()) :: [String.t()]
  def tool_names(%__MODULE__{tools: tools}), do: Enum.map(tools, & &1["name"])

  @doc "The published tool map for `name`, or `nil`."
  @spec tool(t(), String.t()) :: tool() | nil
  def tool(%__MODULE__{tools: tools}, name), do: Enum.find(tools, &(&1["name"] == name))

  @doc """
  What a call to `name` does to the session: `:read`, `:view` or `:mutation`.

  A name rule rather than a per-tool flag, because the base snapshot predates any
  such flag and the split has to hold identically for both surfaces or the
  mutation counts aren't comparable. The surface argument is accepted (and
  ignored) so a future rule can consult the published tool without every caller
  changing.
  """
  @spec kind(t(), String.t()) :: :read | :view | :mutation
  def kind(%__MODULE__{}, name) when is_binary(name) do
    cond do
      String.starts_with?(name, "get_") -> :read
      name in @extra_reads -> :read
      name in @view_tools -> :view
      true -> :mutation
    end
  end

  @doc "Reads a surface snapshot written by `dump/1`."
  @spec load!(Path.t()) :: t()
  def load!(path) do
    path |> File.read!() |> Jason.decode!() |> from_map!()
  end

  @doc "Builds a surface from a decoded snapshot map."
  @spec from_map!(map()) :: t()
  def from_map!(%{"id" => id, "revision" => revision, "tools" => tools} = map) do
    %__MODULE__{
      id: id,
      revision: revision,
      captured_at: map["captured_at"],
      instructions: map["instructions"],
      tools: tools
    }
  end

  @doc """
  The snapshot as JSON, every object's keys sorted.

  Sorted so a committed snapshot diffs line by line when a description changes.
  Jason emits a map's keys in Erlang term order only while the map stays a flat
  map (32 keys or fewer); past that it is hash order, which would reshuffle a
  committed file for no reason. `Jason.OrderedObject` removes the size cliff.
  """
  @spec dump(t()) :: String.t()
  def dump(%__MODULE__{} = surface) do
    surface
    |> to_map()
    |> sorted()
    |> Jason.encode!(pretty: true)
  end

  @doc "The snapshot as a plain string-keyed map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = surface) do
    %{
      "id" => surface.id,
      "revision" => surface.revision,
      "captured_at" => surface.captured_at,
      "instructions" => surface.instructions,
      "tools" => surface.tools
    }
  end

  @doc """
  The sha256 of the contract payload — instructions plus published tools.

  Identity for a report header: two runs quoting the same digest were reading
  the same words, whatever the surface was called or when it was captured.
  """
  @spec contract_digest(t()) :: String.t()
  def contract_digest(%__MODULE__{} = surface) do
    payload = sorted(%{"instructions" => surface.instructions, "tools" => surface.tools})

    :sha256
    |> :crypto.hash(Jason.encode!(payload))
    |> Base.encode16(case: :lower)
  end

  defp sorted(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, sorted(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp sorted(list) when is_list(list), do: Enum.map(list, &sorted/1)
  defp sorted(other), do: other
end
