defmodule Seshat.Generation.MidiParts do
  @moduledoc """
  The `generate_midi` workflow: several composed MIDI parts, one call, one undo
  step.

  `Seshat.Tools.Handlers` dispatches here and does nothing else — every decision
  about what happens to Live, and every sentence the model reads back, is made
  in this module. The shape is `Seshat.Generation.AudioClip`'s: guards before
  side effects, honest partial reporting, a read-back before anything is called
  a success.

  ## Compile everything before touching anything

  Step one compiles and performs *every* part — patterns, bass rules, the
  performance layer — with no OSC at all. A pattern with a stray character in
  part four refuses the request while Live is still untouched, rather than after
  three tracks have been created. That ordering is the whole reason the pure
  modules (`Pattern`, `Performance`, `Bass`) are pure.

  ## Writes chunk, reads window — both against the same 9,216-byte ceiling

  `/live/clip/add/notes_extended` encodes as 44 bytes plus 40 per note
  (measured 2026-08-30 through `Seshat.OSC.Message.encode/2`), so this Mac's
  `net.inet.udp.maxdgram` of 9,216 caps one datagram at 229 notes; writes chunk
  at 200 and repeated adds append. The *reply* direction shares that ceiling
  — nine fields per note rather than eight — so a whole-clip read of a dense
  lane is a datagram AbletonOSC could never send, and the read-back windows the
  clip's time axis instead. Window edges are chosen strictly between two
  distinct written starts, never on one, because the getter matches notes by
  their start.

  Range arguments are **not** echoed in the reply, so two windows on one clip
  correlate identically on `(track, clip)`. Each window therefore also checks
  the starts it got back against the starts it expected, and treats a mismatch
  as a stale reply — the same reissue-once defence the rest of the codebase
  applies to an echoed index.

  ## What the read-back is for

  It confirms the notes landed, and it measures something nothing in the suite
  can: whether Live keeps `probability` and `velocity_deviation` as sent.
  `priv/AbletonOSC/API.md` carries a ⚠️ on exactly that, because the 2026-08-29
  probe read the five-field getter. If the fields come back as defaults the
  reply says so plainly instead of claiming a per-note chance that is not there.
  """

  alias Seshat.Commands.Command
  alias Seshat.Commands.Registry
  alias Seshat.Generation.Midi.Bass
  alias Seshat.Generation.Midi.Pattern
  alias Seshat.Generation.Midi.Performance
  alias Seshat.Generation.Midi.Profiles
  alias Seshat.Library.Catalog
  alias Seshat.OSC.Transport
  alias Seshat.Session.State
  alias Seshat.Tools.FollowCam
  alias Seshat.Tools.Handlers

  # 44 bytes of header plus 40 per note against `maxdgram` 9,216 puts the hard
  # ceiling at 229. 200 leaves room for a longer address or a wider header
  # without re-measuring, and costs one extra datagram on a 512-note lane.
  @chunk_notes 200

  # The reply direction is ~41 bytes per note against the same ceiling, so ~220
  # notes. Windows are sized to this.
  @readback_window_notes 200

  @guard_timeout 2_000
  @load_timeout 30_000
  @readback_timeout 5_000

  # `Transport.query_batch/2`'s own cap, restated so a wide request chunks its
  # guard batches rather than raising.
  @batch_limit 64

  @max_parts 8
  @max_bars 16
  @max_pattern_length 1_600
  @max_role_length 32

  @supported_denominators [1, 2, 4, 8, 16]

  @doc """
  Run the whole workflow for one already-schema-validated parameter map.

  `{:ok, reply}` or `{:error, message}`, both finished prose for the model.
  """
  @spec generate(map()) :: {:ok, String.t()} | {:error, String.t()}
  def generate(params) when is_map(params) do
    with {:ok, request} <- validate(params),
         {:ok, music} <- read_session(),
         {:ok, parts} <- compile_parts(request, music),
         :ok <- guard_targets(parts, request, music),
         {:ok, parts} <- ensure_tracks(parts) do
      write_parts(parts, request, music)
    end
  end

  # --- Cross-field validation (pure) ---

  @doc """
  The pure cross-field rules the JSON Schema cannot express.

  `Seshat.Tools.Validation` has already checked types, bounds, enums and unknown
  keys from the declared schema. What is left is the relationships between
  parameters and the two length rules the schema has no `maxLength` for.

  Runs before the session is read and before any OSC, so every refusal carries
  the same guarantee: nothing was written and nothing was created.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, String.t()}
  def validate(params) when is_map(params) do
    bars = Map.get(params, "bars", 4)
    style = Map.get(params, "style")
    parts = Map.get(params, "parts")

    with :ok <- check_bars(bars),
         :ok <- check_style(style),
         {:ok, parts} <- check_parts(parts, bars),
         {:ok, parts} <- resolve_follows(parts) do
      {:ok,
       %{
         description: Map.get(params, "description"),
         bars: bars,
         clip_slot: Map.get(params, "clip_slot", 0),
         style: style,
         humanize: Map.get(params, "humanize", 1.0) * 1.0,
         swing: Map.get(params, "swing"),
         seed: Map.get(params, "seed") || :rand.uniform(2_147_483_647),
         seed_given?: not is_nil(Map.get(params, "seed")),
         parts: parts
       }}
    end
  end

  defp check_bars(bars) when is_integer(bars) and bars >= 1 and bars <= @max_bars, do: :ok

  defp check_bars(bars) do
    {:error,
     "bars must be a whole number from 1 to #{@max_bars} (got #{inspect(bars)}). " <>
       "Nothing was written."}
  end

  defp check_style(style) when is_binary(style) do
    if style in Profiles.names() do
      :ok
    else
      {:error,
       "style #{inspect(style)} has no profile. Pick one of: " <>
         Enum.join(Profiles.names(), ", ") <> ". Nothing was written."}
    end
  end

  defp check_style(_style) do
    {:error,
     "style is required — it decides the feel. One of: " <>
       Enum.join(Profiles.names(), ", ") <> ". Nothing was written."}
  end

  defp check_parts(parts, _bars) when not is_list(parts) or parts == [] do
    {:error,
     "parts is required and must hold at least one part — each with a role, a type " <>
       "(drum or bass) and what it plays. Nothing was written."}
  end

  defp check_parts(parts, _bars) when length(parts) > @max_parts do
    {:error,
     "#{length(parts)} parts were asked for; the limit is #{@max_parts} in one call. Ask for " <>
       "the rest in a second call, targeting the same scene. Nothing was written."}
  end

  defp check_parts(parts, bars) do
    parts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {part, index}, {:ok, acc} ->
      case check_part(part, index, bars) do
        {:ok, checked} -> {:cont, {:ok, acc ++ [checked]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, checked} ->
        with {:ok, checked} <- check_roles_unique(checked) do
          check_tracks_unique(checked)
        end

      {:error, message} ->
        {:error, message}
    end
  end

  defp check_part(part, index, bars) when is_map(part) do
    role = Map.get(part, "role")
    type = Map.get(part, "type", "drum")
    pattern = Map.get(part, "pattern")

    with :ok <- check_role(role, index),
         :ok <- check_pattern_length(pattern, role),
         {:ok, checked} <- check_part_shape(type, part, role, bars) do
      {:ok,
       Map.merge(checked, %{
         role: String.trim(role),
         type: type,
         index: index,
         resolution: Map.get(part, "resolution", "1/16"),
         track: Map.get(part, "track"),
         instrument_uri: Map.get(part, "instrument_uri"),
         follows: Map.get(part, "follows")
       })}
    end
  end

  defp check_part(part, index, _bars) do
    {:error, "Part #{index + 1} is #{inspect(part)}, not an object. Nothing was written."}
  end

  defp check_role(role, index) when is_binary(role) do
    trimmed = String.trim(role)

    cond do
      trimmed == "" ->
        {:error,
         "Part #{index + 1} has a blank role. Name it after what it plays — \"Kick\", " <>
           "\"Bass\" — since the role names the track and the clip. Nothing was written."}

      String.length(trimmed) > @max_role_length ->
        {:error,
         "Part #{index + 1}'s role is #{String.length(trimmed)} characters; the limit is " <>
           "#{@max_role_length}. Nothing was written."}

      true ->
        :ok
    end
  end

  defp check_role(_role, index) do
    {:error, "Part #{index + 1} needs a role — the track and clip name. Nothing was written."}
  end

  defp check_pattern_length(nil, _role), do: :ok

  defp check_pattern_length(pattern, role) when is_binary(pattern) do
    if String.length(pattern) > @max_pattern_length do
      {:error,
       "Part \"#{role}\"'s pattern is #{String.length(pattern)} characters; the limit is " <>
         "#{@max_pattern_length}. Nothing was written."}
    else
      :ok
    end
  end

  defp check_part_shape("drum", part, role, _bars) do
    pitch = Map.get(part, "pitch")
    pattern = Map.get(part, "pattern")

    cond do
      not is_integer(pitch) ->
        {:error,
         "Drum part \"#{role}\" needs a pitch — the pad it plays (General MIDI: kick 36, " <>
           "snare 38, closed hat 42, open hat 46). Nothing was written."}

      not is_binary(pattern) ->
        {:error,
         "Drum part \"#{role}\" needs a pattern — one character per step, X accent, x hit, " <>
           "g ghost, - rest. Nothing was written."}

      Map.has_key?(part, "roots") or Map.has_key?(part, "relationship") ->
        {:error,
         "Drum part \"#{role}\" was given roots or a relationship, which belong to a bass " <>
           "part. Set type to \"bass\", or drop them. Nothing was written."}

      true ->
        {:ok, %{pitch: pitch, pattern: pattern, roots: nil, relationship: nil}}
    end
  end

  defp check_part_shape("bass", part, role, bars) do
    pattern = Map.get(part, "pattern")
    relationship = Map.get(part, "relationship")
    roots = Map.get(part, "roots")

    cond do
      is_binary(pattern) and is_binary(relationship) ->
        {:error,
         "Bass part \"#{role}\" has both a pattern and a relationship. A pattern writes the " <>
           "bass on its own; a relationship derives it from a drum part's onsets — pick one. " <>
           "Nothing was written."}

      not is_binary(pattern) and not is_binary(relationship) ->
        {:error,
         "Bass part \"#{role}\" needs either a pattern or a relationship " <>
           "(#{Enum.join(Bass.relationships(), ", ")}). Nothing was written."}

      Map.has_key?(part, "pitch") ->
        {:error,
         "Bass part \"#{role}\" was given a pitch; a bass part is pitched by its roots, one " <>
           "per bar. Drop pitch. Nothing was written."}

      true ->
        with :ok <- Bass.validate_roots(roots, bars, role) do
          {:ok, %{pitch: nil, pattern: pattern, roots: roots, relationship: relationship}}
        end
    end
  end

  defp check_part_shape(type, _part, role, _bars) do
    {:error,
     "Part \"#{role}\" has type #{inspect(type)}; only drum and bass parts exist so far. " <>
       "Nothing was written."}
  end

  defp check_roles_unique(parts) do
    duplicate =
      parts
      |> Enum.map(& &1.role)
      |> Enum.frequencies()
      |> Enum.find(fn {_role, count} -> count > 1 end)

    case duplicate do
      nil ->
        {:ok, parts}

      {role, _count} ->
        {:error,
         "Two parts are both called \"#{role}\". Each part names its own track and clip, so " <>
           "the roles have to differ. Nothing was written."}
    end
  end

  # Two parts sharing an explicit `track` would both write into the same
  # (track, clip_slot) — Live rejects the second `create_clip`, but the notes
  # still get appended onto the first part's clip and the reply would have
  # claimed two clips landed when only one, merged and misnamed, did.
  defp check_tracks_unique(parts) do
    duplicate =
      parts
      |> Enum.filter(&is_integer(&1.track))
      |> Enum.map(& &1.track)
      |> Enum.frequencies()
      |> Enum.find(fn {_track, count} -> count > 1 end)

    case duplicate do
      nil ->
        {:ok, parts}

      {track, _count} ->
        {:error,
         "Two parts both target track #{track}. Every part writes into the same clip_slot, " <>
           "so two parts sharing a track would collide in one clip slot. Give each its own " <>
           "track, or drop track on one so a new track is created. Nothing was written."}
    end
  end

  # A relationship reads another part's compiled onsets, so the part it names
  # has to be in this same request — and the default is the lowest-pitched drum
  # part, which is the kick in every kit worth the name.
  defp resolve_follows(parts) do
    drums = Enum.filter(parts, &(&1.type == "drum"))

    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case resolve_follow(part, drums) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp resolve_follow(%{type: "bass", relationship: relationship} = part, drums)
       when is_binary(relationship) do
    cond do
      is_binary(part.follows) ->
        case Enum.find(drums, &(&1.role == part.follows)) do
          nil ->
            {:error,
             "Bass part \"#{part.role}\" follows \"#{part.follows}\", which is not a drum part " <>
               "in this request. Name one of: " <>
               Enum.map_join(drums, ", ", &"\"#{&1.role}\"") <> ". Nothing was written."}

          drum ->
            {:ok, %{part | follows: drum.role}}
        end

      drums == [] ->
        {:error,
         "Bass part \"#{part.role}\" derives its notes from a drum part's onsets, and this " <>
           "request has no drum part. Add one, or give the bass a pattern of its own. " <>
           "Nothing was written."}

      true ->
        lowest = Enum.min_by(drums, & &1.pitch)
        {:ok, %{part | follows: lowest.role}}
    end
  end

  defp resolve_follow(part, _drums) do
    if is_binary(part.follows) do
      {:error,
       "Part \"#{part.role}\" names follows, which only means something for a bass part with " <>
         "a relationship. Drop it. Nothing was written."}
    else
      {:ok, part}
    end
  end

  # --- The session ---

  defp read_session do
    song = State.snapshot().song

    cond do
      not (is_number(song.tempo) and song.tempo > 0) ->
        {:error,
         "Seshat does not know the session tempo, so it cannot work out how long the clips " <>
           "should be. Run get_session_state (refresh: true) and try again. Nothing was written."}

      not supported_signature?(song.time_sig_numerator, song.time_sig_denominator) ->
        {:error,
         "Seshat does not know a usable time signature for this session " <>
           "(#{inspect(song.time_sig_numerator)}/#{inspect(song.time_sig_denominator)}), so it " <>
           "cannot lay the bars out. Run get_session_state (refresh: true) and try again. " <>
           "Nothing was written."}

      true ->
        {:ok,
         %{
           tempo: song.tempo * 1.0,
           numerator: song.time_sig_numerator,
           denominator: song.time_sig_denominator,
           beats_per_bar: song.time_sig_numerator * 4 / song.time_sig_denominator
         }}
    end
  catch
    :exit, _ ->
      {:error,
       "Seshat's session mirror is not available, so the tempo and time signature could not " <>
         "be read and nothing was written. Check that Seshat is running with Ableton Live open."}
  end

  defp supported_signature?(numerator, denominator) do
    is_integer(numerator) and numerator > 0 and denominator in @supported_denominators
  end

  # --- Compile and perform (pure) ---

  defp compile_parts(request, music) do
    clip_beats = music.beats_per_bar * request.bars

    with {:ok, compiled} <- compile_onsets(request, music) do
      swing = resolved_swing(request)

      performed =
        Enum.map(compiled, fn part ->
          lane =
            case part.type do
              "bass" -> Profiles.bass_lane(request.style)
              _ -> lane_for(request.style, part.pitch)
            end

          notes =
            Performance.perform(part.onsets, %{
              pitch: part.pitch,
              lane: lane,
              humanize: request.humanize,
              swing: swing,
              seed: request.seed,
              part_index: part.index,
              clip_beats: clip_beats,
              beats_per_bar: music.beats_per_bar
            })

          Map.put(part, :notes, notes)
        end)

      case Enum.find(performed, &(&1.notes == [])) do
        nil ->
          {:ok, performed}

        empty ->
          {:error,
           "Part \"#{empty.role}\" compiled to no notes at all — its pattern is all rests, or " <>
             "the drums it follows never play. Nothing was written."}
      end
    end
  end

  defp lane_for(style, pitch) do
    {:ok, _lane_name, lane} = Profiles.lane_for(style, pitch)
    lane
  end

  # Drums first, so a bass part's `follows` always finds compiled onsets.
  defp compile_onsets(request, music) do
    drums = Enum.filter(request.parts, &(&1.type == "drum"))
    basses = Enum.filter(request.parts, &(&1.type == "bass"))

    with {:ok, compiled_drums} <- compile_drums(drums, request, music) do
      by_role = Map.new(compiled_drums, &{&1.role, &1.onsets})

      Enum.reduce_while(basses, {:ok, compiled_drums}, fn part, {:ok, acc} ->
        spec = %{
          role: part.role,
          pattern: part.pattern,
          relationship: part.relationship,
          resolution: part.resolution,
          roots: part.roots,
          bars: request.bars,
          beats_per_bar: music.beats_per_bar
        }

        case Bass.compile(spec, Map.get(by_role, part.follows, [])) do
          {:ok, onsets} -> {:cont, {:ok, acc ++ [Map.put(part, :onsets, onsets)]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
    end
    |> case do
      {:ok, parts} -> {:ok, Enum.sort_by(parts, & &1.index)}
      {:error, message} -> {:error, message}
    end
  end

  defp compile_drums(drums, request, music) do
    Enum.reduce_while(drums, {:ok, []}, fn part, {:ok, acc} ->
      case Pattern.compile(part.pattern, part.resolution, request.bars, music.beats_per_bar) do
        {:ok, onsets} ->
          {:cont, {:ok, acc ++ [Map.put(part, :onsets, onsets)]}}

        {:error, message} ->
          {:halt, {:error, "Part \"#{part.role}\": " <> message}}
      end
    end)
  end

  # The tool takes swing as 0–1, where 1.0 is a full triplet feel: the off-8th
  # sits a third of an 8th late, which is two thirds of a 16th. The profiles
  # measure it directly in 16ths, so the two meet here rather than in either.
  defp resolved_swing(%{swing: nil, style: style}), do: Profiles.swing(style)
  defp resolved_swing(%{swing: swing}), do: swing * 2.0 / 3.0

  # --- Guards (every read before any mutation) ---

  defp guard_targets(parts, request, music) do
    slot = request.clip_slot

    with {:ok, scenes} <- num_scenes(),
         :ok <- check_scene(slot, scenes),
         :ok <- check_existing_tracks(parts, slot) do
      check_clip_length(request, music)
    end
  end

  defp check_scene(_slot, scenes) when scenes < 1 do
    {:error,
     "This set has no scenes, so there is no clip slot to write into. Create a scene with " <>
       "create_scene, then try again. Nothing was written and no track was created."}
  end

  defp check_scene(slot, scenes) do
    if slot < scenes do
      :ok
    else
      {:error,
       "clip_slot #{slot} is past the last scene (this set has #{scenes}, so the highest slot " <>
         "is #{scenes - 1}). Create a scene with create_scene, or target a lower slot. " <>
         "Nothing was written and no track was created."}
    end
  end

  # Live's clip length is a float in beats and nothing here needs a ceiling of
  # its own; this only refuses the degenerate case a bad time signature could
  # produce, before a `create_clip` with a zero length reaches Live.
  defp check_clip_length(request, music) do
    if music.beats_per_bar * request.bars > 0 do
      :ok
    else
      {:error,
       "This session's time signature works out to a bar of no length, so the clips would be " <>
         "empty. Check it with get_session_state. Nothing was written."}
    end
  end

  defp check_existing_tracks(parts, slot) do
    existing = Enum.filter(parts, &is_integer(&1.track))

    Enum.reduce_while(existing, :ok, fn part, :ok ->
      case check_existing_track(part, slot) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp check_existing_track(part, slot) do
    entries = [
      {"/live/track/get/is_foldable", [part.track]},
      {"/live/track/get/has_midi_input", [part.track]},
      {"/live/clip_slot/get/has_clip", [part.track, slot]}
    ]

    with {:ok, [foldable, midi?, has_clip]} <-
           batch(entries, @guard_timeout, "track #{part.track}") do
      cond do
        truthy?(foldable) ->
          {:error,
           "Part \"#{part.role}\" targets track #{part.track}, which is a group track and " <>
             "cannot hold a clip. Pick a MIDI track inside it, or drop track so one is " <>
             "created. Nothing was written and no track was created."}

        not truthy?(midi?) ->
          {:error,
           "Part \"#{part.role}\" targets track #{part.track}, which is not a MIDI track, so " <>
             "MIDI notes cannot be written to it. Drop track to have one created, or pick a " <>
             "MIDI track (get_session_state names them). Nothing was written and no track was " <>
             "created."}

        truthy?(has_clip) ->
          {:error,
           "Slot #{slot} on track #{part.track} (part \"#{part.role}\") already holds a clip, " <>
             "and generated parts never overwrite one. Target an empty scene, or free the slot " <>
             "with delete_clip. Nothing was written and no track was created."}

        true ->
          :ok
      end
    end
  end

  defp num_scenes do
    case query("/live/song/get/num_scenes", [], @guard_timeout) do
      {:ok, [scenes]} when is_integer(scenes) and scenes >= 0 ->
        {:ok, scenes}

      {:ok, other} ->
        {:error,
         "Ableton's reply about the scene count was #{inspect(other)}, which Seshat cannot " <>
           "read, so nothing was written."}

      {:error, message} ->
        {:error, message}
    end
  end

  # --- Tracks and instruments ---

  defp ensure_tracks(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case ensure_track(part) do
        {:ok, resolved} ->
          {:cont, {:ok, acc ++ [resolved]}}

        {:error, message} ->
          {:halt, {:error, message <> created_so_far(acc)}}
      end
    end)
  end

  defp ensure_track(%{track: track} = part) when is_integer(track),
    do: {:ok, Map.put(part, :created?, false)}

  defp ensure_track(part) do
    case Registry.execute(%Command{command: :create_track, track_type: :midi, name: part.role}) do
      {:ok, index} ->
        {:ok, part |> Map.put(:track, index) |> Map.put(:created?, true)}

      {:error, reason} ->
        {:error, "Could not create a MIDI track for part \"#{part.role}\": #{render(reason)}"}
    end
  end

  defp created_so_far(parts) do
    case Enum.filter(parts, & &1.created?) do
      [] ->
        " Nothing was created."

      created ->
        " Tracks created before this failure are still there and empty: " <>
          Enum.map_join(created, ", ", &"#{&1.track} (\"#{&1.role}\")") <>
          ". One undo removes the whole request."
    end
  end

  # A failed load never aborts the part: the notes are the material, and a
  # silent track the reply names is recoverable with one load_device call,
  # whereas a refusal here would throw away the composition too.
  defp load_instruments(parts) do
    Enum.map(parts, fn part ->
      case part.instrument_uri do
        nil -> Map.put(part, :instrument, :none)
        uri -> Map.put(part, :instrument, load_instrument(part.track, uri))
      end
    end)
  end

  defp load_instrument(track, uri) do
    case Transport.query("/live/browser/load_item", [track, uri], @load_timeout) do
      {:ok, {_address, args}} ->
        case Handlers.load_outcome(args, [track, uri]) do
          {:loaded, [name | _rest]} ->
            Catalog.record_load(uri)
            {:loaded, name}

          {:remote_error, message} ->
            {:failed, message}

          :stale ->
            {:failed,
             "Ableton's reply was about a different load, so whether it landed is unknown"}

          _other ->
            {:failed, "Ableton's reply could not be read: #{inspect(args)}"}
        end

      {:error, reason} ->
        {:failed, Transport.describe_error(reason)}
    end
  catch
    :exit, _ -> {:failed, "the load timed out"}
  end

  # --- Writing ---

  defp write_parts(parts, request, music) do
    parts = load_instruments(parts)
    clip_beats = music.beats_per_bar * request.bars
    slot = request.clip_slot

    written =
      Enum.map(parts, fn part ->
        Map.put(part, :outcome, write_part(part, slot, clip_beats))
      end)

    case Enum.find(written, &match?({:error, _}, &1.outcome)) do
      nil ->
        verified = Enum.map(written, &Map.put(&1, :readback, read_back(&1, slot)))
        steer(verified, slot)
        {:ok, reply(verified, request, music, slot)}

      failed ->
        {:error, write_failure(failed, written, slot)}
    end
  end

  defp write_part(part, slot, clip_beats) do
    with :ok <-
           Transport.send_message("/live/clip_slot/create_clip", [part.track, slot, clip_beats]),
         :ok <- add_notes(part, slot),
         :ok <- Transport.send_message("/live/clip/set/name", [part.track, slot, part.role]) do
      :ok
    else
      {:error, reason} -> {:error, render(reason)}
    end
  end

  defp add_notes(part, slot) do
    part.notes
    |> Enum.chunk_every(@chunk_notes)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      args = [part.track, slot | Enum.flat_map(chunk, &note_args/1)]

      case Transport.send_message("/live/clip/add/notes_extended", args) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  One note as the eight arguments `/live/clip/add/notes_extended` takes, in
  Live's canonical order.

  Public because the order *is* the contract — `pitch, start_time, duration,
  velocity, mute, probability, velocity_deviation, release_velocity`, with
  `mute` sent as `0`/`1` where the reply returns it as an OSC boolean — and a
  silent transposition of two fields is exactly the failure this wire cannot
  report.
  """
  @spec note_args(map()) :: [number()]
  def note_args(note) do
    [
      note.pitch,
      note.start_time * 1.0,
      note.duration * 1.0,
      note.velocity * 1.0,
      note.mute,
      note.probability * 1.0,
      note.velocity_deviation * 1.0,
      note.release_velocity * 1.0
    ]
  end

  defp write_failure(failed, written, slot) do
    {:error, reason} = failed.outcome

    "Writing part \"#{failed.role}\" into slot #{slot} on track #{failed.track} failed: " <>
      reason <>
      ". Every part is attempted regardless, so others may have landed either before or " <>
      "after this one — read the scene with get_clip_slots. " <>
      standing_tracks(written) <> " One undo removes everything this call created."
  end

  defp standing_tracks(parts) do
    case Enum.filter(parts, & &1.created?) do
      [] ->
        "No track was created."

      created ->
        "Tracks created by this call: " <>
          Enum.map_join(created, ", ", &"#{&1.track} (\"#{&1.role}\")") <> "."
    end
  end

  # --- Read-back ---

  @doc """
  The time windows one clip's read-back is split into, given the starts written.

  Pure, and public because it is the whole defence against a reply that can
  never arrive. Each window holds at most `limit` notes; its edges sit strictly
  *between* two distinct written starts, so the getter's match-by-start
  semantics can neither drop a boundary note nor return it twice. A clip whose
  notes all fit one reply gets a single window spanning the clip.

  Returns `[{start_time, time_span, expected_starts}]`.
  """
  @spec readback_windows([float()], float(), pos_integer()) :: [{float(), float(), [float()]}]
  def readback_windows(starts, clip_beats, limit \\ @readback_window_notes) do
    sorted = Enum.sort(starts)
    grouped = sorted |> Enum.chunk_by(& &1)

    {windows, current, _count} =
      Enum.reduce(grouped, {[], [], 0}, fn group, {windows, current, count} ->
        if current != [] and count + length(group) > limit do
          {windows ++ [current], group, length(group)}
        else
          {windows, current ++ group, count + length(group)}
        end
      end)

    windows = if current == [], do: windows, else: windows ++ [current]

    windows
    |> Enum.with_index()
    |> Enum.map(fn {group, index} ->
      low =
        if index == 0 do
          min(0.0, List.first(group)) - 0.5
        else
          midpoint(List.last(Enum.at(windows, index - 1)), List.first(group))
        end

      high =
        case Enum.at(windows, index + 1) do
          nil -> max(clip_beats, List.last(group)) + 0.5
          next -> midpoint(List.last(group), List.first(next))
        end

      {low, high - low, group}
    end)
  end

  defp midpoint(low, high), do: low + (high - low) / 2

  defp read_back(part, slot) do
    starts = Enum.map(part.notes, & &1.start_time)
    pitches = Enum.map(part.notes, & &1.pitch)
    low_pitch = Enum.min(pitches)
    pitch_span = Enum.max(pitches) - low_pitch + 1
    clip_beats = Enum.max(Enum.map(part.notes, &(&1.start_time + &1.duration)))

    starts
    |> readback_windows(clip_beats)
    |> Enum.reduce_while({:ok, []}, fn {start, span, expected}, {:ok, acc} ->
      case read_window(part, slot, low_pitch, pitch_span, start, span, expected) do
        {:ok, notes} -> {:cont, {:ok, acc ++ notes}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, notes} -> compare(part, notes)
      {:error, message} -> {:unconfirmed, message}
    end
  end

  defp read_window(part, slot, low_pitch, pitch_span, start, span, expected, reissued? \\ false) do
    args = [part.track, slot, low_pitch, pitch_span, start, span]

    case Transport.query("/live/clip/get/notes_extended", args, @readback_timeout) do
      {:ok, {_address, [track, clip | fields]}} when track == part.track and clip == slot ->
        notes = decode_notes(fields)

        cond do
          starts_match?(notes, expected) ->
            {:ok, notes}

          reissued? ->
            {:error,
             "the notes Ableton returned for this window were not the ones it was asked for, " <>
               "twice in a row — they belong to an earlier query that timed out"}

          true ->
            read_window(part, slot, low_pitch, pitch_span, start, span, expected, true)
        end

      {:ok, _mismatched} when not reissued? ->
        read_window(part, slot, low_pitch, pitch_span, start, span, expected, true)

      {:ok, _mismatched} ->
        {:error,
         "Ableton's replies were about a different clip, twice in a row — they belong to an " <>
           "earlier query that timed out"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ -> {:error, "reading the notes back timed out"}
  end

  # Nine fields per note, `note_id` last, `mute` as an OSC boolean.
  defp decode_notes(fields) do
    fields
    |> Enum.chunk_every(9)
    |> Enum.filter(&(length(&1) == 9))
    |> Enum.map(fn [pitch, start, duration, velocity, mute, probability, deviation, release, id] ->
      %{
        pitch: pitch,
        start_time: start,
        duration: duration,
        velocity: velocity,
        mute: mute,
        probability: probability,
        velocity_deviation: deviation,
        release_velocity: release,
        note_id: id
      }
    end)
  end

  # Live stores note positions as 32-bit floats, so a start near beat 60 can
  # round-trip up to ~7e-6 off — rounding both sides to 3 decimals and
  # comparing for equality (the previous approach) still fails whenever that
  # error straddles a rounding boundary, which measured out to a false
  # "could not confirm" on tens of seeds out of every hundred on a dense
  # lane. A tolerance well above float32's error and well below `@min_gap`
  # (two notes can legitimately sit 0.002 beats apart) is the fix: each
  # returned start is matched to its nearest expected start, and the match
  # only holds if every expected start found a returned start within
  # tolerance and vice versa.
  @start_tolerance 1.0e-3

  defp starts_match?(notes, expected) do
    returned = notes |> Enum.map(& &1.start_time) |> Enum.filter(&is_number/1) |> Enum.sort()
    wanted = Enum.sort(expected)

    length(returned) == length(notes) and
      length(returned) == length(wanted) and
      Enum.zip(returned, wanted)
      |> Enum.all?(fn {got, want} -> abs(got * 1.0 - want * 1.0) <= @start_tolerance end)
  end

  # The measurement `priv/AbletonOSC/API.md` has a ⚠️ on. Whether the three
  # expression fields *persist* was never read back — the 2026-08-29 probe used
  # the five-field getter — so this compares what came back against what went
  # out and the reply says which it is.
  #
  # Tracked per field, not folded into one flag: a pattern with no ghosts sends
  # `velocity_deviation` but never a `probability` below 1.0, and Live keeping
  # one field while dropping the other is exactly the case a single combined
  # "kept" boolean cannot report — it would call the drop "kept" because the
  # other field happened to survive.
  defp compare(part, notes) do
    probability_sent? = Enum.any?(part.notes, &(&1.probability < 1.0))
    deviation_sent? = Enum.any?(part.notes, &(&1.velocity_deviation > 0.0))

    probability_kept? =
      probability_sent? and Enum.any?(notes, &number_below?(&1.probability, 1.0))

    deviation_kept? =
      deviation_sent? and Enum.any?(notes, &number_above?(&1.velocity_deviation, 0.0))

    # No note-count comparison lives here, deliberately: every window already
    # had to return exactly the starts it was asked for before it was accepted,
    # so a surviving read-back has the right notes by construction and a wrong
    # one is `:unconfirmed`. A count check here would be a branch no reply can
    # reach.
    %{
      notes: Enum.count(notes),
      probability_sent?: probability_sent?,
      deviation_sent?: deviation_sent?,
      probability_kept?: probability_kept?,
      deviation_kept?: deviation_kept?
    }
  end

  defp number_below?(value, ceiling) when is_number(value), do: value < ceiling - 1.0e-6
  defp number_below?(_value, _ceiling), do: false

  defp number_above?(value, floor) when is_number(value), do: value > floor + 1.0e-6
  defp number_above?(_value, _floor), do: false

  # --- The reply ---

  defp steer(parts, slot) do
    case List.last(parts) do
      nil -> :ok
      part -> FollowCam.steer("generate_midi", %{track: part.track, slot: slot})
    end
  end

  defp reply(parts, request, music, slot) do
    headline =
      "Composed #{length(parts)} #{pluralise(length(parts), "part")} into scene #{slot} — " <>
        "#{request.bars} #{pluralise(request.bars, "bar")} of #{request.style} at " <>
        "#{format_number(music.tempo)} BPM, #{music.numerator}/#{music.denominator}. " <>
        "These are MIDI clips, not audio." <> brief(request.description)

    lines = Enum.map(parts, &part_line(&1, slot))

    feel =
      "Feel: #{request.style} " <>
        cond do
          Profiles.fully_pooled?(request.style) ->
            "(too few #{request.style} recordings to measure on their own; using the " <>
              "combined-style average)"

          Profiles.harvested?(request.style) ->
            "(measured from real drummers)"

          true ->
            "(derived from #{Profiles.authored_from(request.style)})"
        end <>
        ", humanize #{format_number(request.humanize)}, seed #{request.seed}" <>
        if(request.seed_given?,
          do: ". Same seed, same take.",
          else: " — pass that seed back for this exact take, or leave it out for another."
        )

    readback = readback_line(parts)

    undo =
      "One undo removes the whole request — every track and clip this call created, in one step."

    Enum.join([headline | lines] ++ [feel, readback, undo] ++ silent_note(parts), "\n")
  end

  # The schema promises the brief is "echoed in the reply"; it steers nothing
  # (the pattern and style are what decide the result), so it rides on the
  # headline rather than a line of its own.
  defp brief(description) when is_binary(description) do
    trimmed = String.trim(description)
    if trimmed == "", do: "", else: " Brief: \"#{trimmed}\"."
  end

  defp brief(_description), do: ""

  defp part_line(part, slot) do
    where =
      if part.created?,
        do: "new track #{part.track}",
        else: "track #{part.track}"

    instrument =
      case part.instrument do
        {:loaded, name} -> ", playing #{name}"
        {:failed, _message} -> ", with no instrument (the load failed)"
        :none -> ", with no instrument yet"
      end

    "  #{part.role}: #{length(part.notes)} notes on #{where}, slot #{slot}#{instrument}"
  end

  defp readback_line(parts) do
    unconfirmed = Enum.filter(parts, &match?({:unconfirmed, _}, &1.readback))
    confirmed = Enum.reject(parts, &match?({:unconfirmed, _}, &1.readback))

    if unconfirmed == [] do
      "Read-back: every note confirmed in Live." <> expression_note(confirmed)
    else
      {:unconfirmed, why} = List.first(unconfirmed).readback

      "Read-back: could not confirm " <>
        Enum.map_join(unconfirmed, ", ", &"\"#{&1.role}\"") <>
        " (#{why}). The notes were sent and most likely landed — check with get_clip_notes."
    end
  end

  # The honest half of the ⚠️: say which way the measurement went, per field,
  # in the words a user would need to act on it. "Per-note chance" and
  # "velocity spread" are reported independently because Live can keep one
  # and drop the other — a combined verdict would misreport that case either
  # way.
  @expression_fields [
    {"per-note chance", :probability_sent?, :probability_kept?},
    {"velocity spread", :deviation_sent?, :deviation_kept?}
  ]

  defp expression_note(parts) do
    sent =
      Enum.filter(@expression_fields, fn {_label, sent_key, _kept_key} ->
        Enum.any?(parts, &Map.fetch!(&1.readback, sent_key))
      end)

    if sent == [] do
      ""
    else
      kept =
        Enum.filter(sent, fn {_label, sent_key, kept_key} ->
          parts
          |> Enum.filter(&Map.fetch!(&1.readback, sent_key))
          |> Enum.all?(&Map.fetch!(&1.readback, kept_key))
        end)

      dropped = sent -- kept

      [kept_sentence(kept), dropped_sentence(dropped)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join(" ", & &1)
      |> case do
        "" -> ""
        sentence -> " " <> sentence
      end
    end
  end

  defp kept_sentence([]), do: ""

  defp kept_sentence(fields) do
    names = Enum.map_join(fields, " and ", &elem(&1, 0))

    suffix =
      if Enum.any?(fields, &(elem(&1, 0) == "per-note chance")) do
        ", so Live re-rolls the ghost notes on every pass."
      else
        "."
      end

    String.capitalize(names) <> " came back as sent" <> suffix
  end

  defp dropped_sentence([]), do: ""

  defp dropped_sentence(fields) do
    names = Enum.map_join(fields, " and ", &elem(&1, 0))
    those_did = if length(fields) > 1, do: "those did", else: "that did"

    "Live returned default values for " <>
      names <>
      ", so #{those_did} not stick — the timing and velocity shape did, which is most of the feel."
  end

  defp silent_note(parts) do
    case Enum.filter(parts, &(&1.instrument == :none or match?({:failed, _}, &1.instrument))) do
      [] ->
        []

      silent ->
        [
          "Silent until a device is on " <>
            Enum.map_join(silent, ", ", &"track #{&1.track} (\"#{&1.role}\")") <>
            " — find one with search_library and load it with load_device."
        ]
    end
  end

  defp pluralise(1, word), do: word
  defp pluralise(_count, word), do: word <> "s"

  defp format_number(value) when is_float(value) do
    if value == Float.round(value), do: Integer.to_string(trunc(value)), else: to_string(value)
  end

  defp format_number(value), do: to_string(value)

  # --- Small OSC helpers ---
  #
  # Local for the same reason `Seshat.Generation.AudioClip`'s are: the ones in
  # `Handlers` are private there, and reaching into the dispatcher this module
  # is called from for its OSC vocabulary would invert the dependency.

  defp query(address, args, timeout) do
    case Transport.query(address, args, timeout) do
      {:ok, {_address, values}} ->
        {echoed, payload} = Enum.split(values, length(args))

        if echoed == args do
          {:ok, payload}
        else
          {:error,
           "Ableton's reply on #{address} was about a different request, so nothing was written."}
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason) <> " — nothing was written."}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out waiting for Ableton on #{address}, so nothing was written. Check that Live " <>
         "is running with AbletonOSC enabled."}
  end

  defp batch(entries, timeout, subject) do
    entries
    |> Enum.chunk_every(@batch_limit)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case Transport.query_batch(chunk, timeout) do
        {:ok, results} ->
          case unwrap_all(results, subject) do
            {:ok, values} -> {:cont, {:ok, acc ++ values}}
            {:error, message} -> {:halt, {:error, message}}
          end

        {:error, reason} ->
          {:halt, {:error, Transport.describe_error(reason) <> " — nothing was written."}}
      end
    end)
  catch
    :exit, _ ->
      {:error,
       "Timed out reading #{subject} from Ableton, so nothing was written. Check that Live is " <>
         "running with AbletonOSC enabled."}
  end

  defp unwrap_all(results, subject) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case result do
        {:ok, [value]} ->
          {:cont, {:ok, acc ++ [value]}}

        {:ok, payload} ->
          {:halt,
           {:error,
            "Ableton's reply about #{subject} was #{inspect(payload)}, which Seshat cannot " <>
              "read, so nothing was written."}}

        {:error, {:live_error, message}} ->
          {:halt,
           {:error,
            "Ableton rejected the request about #{subject}: #{message}. Nothing was written."}}
      end
    end)
  end

  defp truthy?(value), do: value in [1, true]

  defp render(reason) when is_binary(reason), do: reason
  defp render(reason), do: inspect(reason)
end
