defmodule Seshat.Eval.Fixture do
  @moduledoc """
  The synthetic Live set a routing trial explores, and the replies it answers
  reads with.

  A fixture stands in for Ableton entirely — nothing in the eval tree opens a
  socket. What matters for routing is that the *discovery* replies read exactly
  as production's do, so the model's picture of the set is the real one: the
  reads render through `Seshat.Tools.Handlers`' own public formatters
  (`format_session_state/5`, `format_clip_notes/5`, `format_clip_slots/2`)
  rather than through prose invented here.

  ## Mutations are recorded, not applied

  A mutation gets a short templated success line and the fixture is unchanged.
  Neither seed case reads state back after writing, and a general state
  simulator built before a case needs one would be this slice's largest
  untested component. When a later case has a concrete read-after-write
  assertion, that is the moment to add simulation — not before.

  A read the fixture has no data for is an **error**, never an empty success:
  a model that can proceed on invented state produces a trace that scores well
  and means nothing.
  """

  alias Seshat.Tools.Handlers

  @enforce_keys [:name, :song, :tracks, :return_tracks, :master, :clips]
  defstruct [:name, :song, :tracks, :return_tracks, :master, :clips]

  @type t :: %__MODULE__{
          name: String.t(),
          song: map(),
          tracks: [map()],
          return_tracks: [map()],
          master: map(),
          clips: %{String.t() => map()}
        }

  @doc "Loads `priv/routing_eval/fixtures/<name>.json`."
  @spec load!(String.t()) :: t()
  def load!(name) when is_binary(name) do
    "routing_eval/fixtures/#{name}.json"
    |> path()
    |> File.read!()
    |> Jason.decode!()
    |> from_map!(name)
  end

  @doc "A path inside `priv/`, resolved from the repository root."
  @spec path(String.t()) :: Path.t()
  def path(relative), do: Path.expand(Path.join("priv", relative), File.cwd!())

  @doc "Builds a fixture from a decoded JSON map."
  @spec from_map!(map(), String.t()) :: t()
  def from_map!(map, name) do
    %__MODULE__{
      name: name,
      song: atomize(map["song"], ~w(tempo time_sig_numerator time_sig_denominator is_playing
        root_note scale_name groove_amount swing_amount groove_pool)a),
      tracks: Enum.map(map["tracks"] || [], &track/1),
      return_tracks: Enum.map(map["return_tracks"] || [], &return_track/1),
      master: atomize(map["master"], ~w(volume pan cue_volume)a),
      clips: map["clips"] || %{}
    }
  end

  defp track(map) do
    map
    |> atomize(~w(index name volume pan mute solo arm midi? group?)a)
    |> Map.put_new(:midi?, false)
    |> Map.put_new(:group?, false)
  end

  defp return_track(map), do: atomize(map, ~w(index name volume pan mute solo)a)

  defp atomize(nil, _keys), do: nil

  defp atomize(map, keys) do
    Map.new(keys, fn key -> {key, map[Atom.to_string(key)]} end)
  end

  @doc """
  Answers a `tools/call` against the fixture.

  Returns `{:ok, text}` for a read the fixture can serve or any mutation, and
  `{:error, text}` for a read it cannot.
  """
  @spec call(t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def call(%__MODULE__{} = fixture, "get_session_state", _arguments) do
    {:ok,
     Handlers.format_session_state(
       fixture.song,
       fixture.tracks,
       fixture.return_tracks,
       fixture.master,
       false
     )}
  end

  def call(%__MODULE__{} = fixture, "get_clip_notes", arguments) do
    track = arguments["track"]
    slot = arguments["clip_slot"] || 0

    case clip(fixture, track, slot) do
      nil ->
        {:error, missing_clip(track, slot)}

      clip ->
        notes =
          clip
          |> Map.get("notes", [])
          |> Enum.map(&note/1)
          |> Enum.filter(&in_window?(&1, arguments))

        {:ok, Handlers.format_clip_notes(track, slot, clip["name"], clip["length"] * 1.0, notes)}
    end
  end

  def call(%__MODULE__{} = fixture, "get_clip_slots", _arguments) do
    {:ok, Handlers.format_clip_slots(scene_names(fixture), grid(fixture))}
  end

  # Every other read is a discovery path this fixture was not built for. Saying
  # so is the point: the model must not proceed on state nobody supplied.
  def call(%__MODULE__{}, "get_" <> _ = name, _arguments) do
    {:error,
     "#{name} is not available in this evaluation fixture — no data was supplied for it. " <>
       "Work from what get_session_state and get_clip_notes report."}
  end

  def call(%__MODULE__{}, name, arguments), do: {:ok, mutation_reply(name, arguments)}

  # Deliberately generic. A specific, plausible success line per tool would be a
  # second implementation of `Handlers`' replies that nothing keeps in sync, and
  # it lands after the routing choice has already been made.
  defp mutation_reply(name, arguments) when map_size(arguments) == 0 do
    "Done. (#{name} was recorded by the evaluation harness; nothing was sent to Ableton.)"
  end

  defp mutation_reply(name, arguments) do
    rendered =
      arguments
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{render(value)}" end)

    "Done: #{name} #{rendered}. " <>
      "(Recorded by the evaluation harness; nothing was sent to Ableton.)"
  end

  defp render(value) when is_binary(value), do: value
  defp render(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp render(value), do: Jason.encode!(value)

  defp missing_clip(track, slot) do
    "No clip in slot #{slot} on track #{track} in this evaluation fixture. " <>
      "get_clip_slots shows which slots hold clips."
  end

  defp clip(%__MODULE__{clips: clips}, track, slot), do: Map.get(clips, "#{track}:#{slot}")

  defp note(map) do
    %{
      pitch: map["pitch"],
      start_time: map["start_time"] * 1.0,
      duration: map["duration"] * 1.0,
      velocity: map["velocity"] * 1.0,
      mute: Map.get(map, "mute", false)
    }
  end

  # The same window `get_clip_notes` documents: pitch range and time range, each
  # with the schema's default when the call omits it.
  defp in_window?(note, arguments) do
    start_pitch = arguments["start_pitch"] || 0
    pitch_span = arguments["pitch_span"] || 128
    start_time = (arguments["start_time"] || 0) * 1.0
    time_span = arguments["time_span"]

    note.pitch >= start_pitch and note.pitch < start_pitch + pitch_span and
      note.start_time >= start_time and
      (is_nil(time_span) or note.start_time < start_time + time_span * 1.0)
  end

  @doc """
  The clip grid in the shape `Handlers.format_clip_slots/2` consumes.
  """
  @spec grid(t()) :: [map()]
  def grid(%__MODULE__{} = fixture) do
    scenes = scene_count(fixture)

    Enum.map(fixture.tracks, fn track ->
      slots =
        Enum.map(0..(scenes - 1)//1, fn slot ->
          case clip(fixture, track.index, slot) do
            nil ->
              nil

            clip ->
              %{
                name: clip["name"],
                length: clip["length"] * 1.0,
                playing?: false,
                recording?: false
              }
          end
        end)

      %{name: track.name, midi?: track.midi?, group?: track.group?, slots: slots}
    end)
  end

  @doc "Scene names, one per row of the grid."
  @spec scene_names(t()) :: [String.t()]
  def scene_names(%__MODULE__{} = fixture) do
    Enum.map(1..scene_count(fixture)//1, &"Scene #{&1}")
  end

  # Enough rows to hold every clip the fixture declares, and never fewer than
  # two so the grid reads as a grid.
  defp scene_count(%__MODULE__{clips: clips}) do
    clips
    |> Map.keys()
    |> Enum.map(fn key -> key |> String.split(":") |> List.last() |> String.to_integer() end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
    |> max(2)
  end
end
