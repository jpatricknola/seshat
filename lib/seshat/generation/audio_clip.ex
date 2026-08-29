defmodule Seshat.Generation.AudioClip do
  @moduledoc """
  The `generate_audio` workflow: render short audio locally, then import it into
  a Session slot.

  `Seshat.Tools.Handlers` dispatches here and formats what comes back. Nothing
  in this module renders prose for the model, and nothing in `Handlers` decides
  what happens to Live.

  ## Generate first, touch Live second

  Every guard that can refuse the request runs *before* the backend is called:
  the target track must be a regular audio track rather than a group or a MIDI
  track, an explicitly named slot must be empty, and a variation source must be
  a real managed file. A generation that fails therefore leaves the Live set
  exactly as it found it, and the expensive step is never spent on a target that
  was going to be refused anyway.

  The one Live mutation that can precede a successful render is the *creation*
  of a new destination track — and it deliberately does not: when `track` is
  omitted, the track is created in step 7, after the file exists. A failed
  generation leaves no orphan track behind.

  ## The wire never carries a path

  The fork's `/live/clip_slot/create_audio_clip` takes a *name relative to*
  `~/.seshat/generated` and builds the absolute path itself
  (`abletonosc/path_safety.py`). So this module writes takes into exactly that
  directory and sends basenames. The root is not a Seshat preference any more —
  it is one constant in the fork, pinned from the Elixir side by
  `test/seshat/osc/vendored_addresses_test.exs` — and `:generated_root` exists
  to let the suite point at a tmp directory, not to let an installation move it.

  ## Every take is kept

  Files here are append-only. Live may still be referencing one from a saved
  set, and a variation of a take the user liked must not overwrite the take the
  user liked. Names are reserved with an exclusive create, so two concurrent
  requests cannot collide even when their descriptions, second and seed all
  agree. The only file this module ever deletes is the one *this* request
  reserved, and only when the render that was going to fill it failed.

  ## What it does not do

  The raw duration-exact render is imported unchanged. Nothing here analyses
  rhythmic phase, repairs a loop seam, or sets looping, warping, markers or
  gain. Those properties are *read back* and reported. That division is the
  point of the MVP, and the follow-up work is planned separately.
  """

  alias Seshat.Commands.Command
  alias Seshat.Commands.Registry
  alias Seshat.Generation.Backend
  alias Seshat.Generation.Result
  alias Seshat.Generation.Spec
  alias Seshat.OSC.Transport
  alias Seshat.Session.State
  alias Seshat.Tools.FollowCam

  require Logger

  @sample_rate 44_100

  # Must equal `path_safety.IMPORT_ROOT` in the fork. `Path.expand/1` resolves
  # `~` without resolving symlinks, matching `browser.py`'s EXPORT_ROOT handling
  # rather than `path_safety`'s internal realpath — what matters here is that
  # the *basename* we send resolves under the same directory we wrote into.
  @default_generated_root "~/.seshat/generated"

  # A single property read, like every other pre-mutation guard in the codebase.
  @guard_timeout 2_000

  # The import is a Live *method* that opens and decodes a file, not a property
  # read, so it gets its own budget rather than the guard's. Nothing measured
  # says how long Live takes over a 60-second WAV.
  @import_timeout 15_000

  # The read-back is six ordinary property reads in one batch — one tick — so
  # Transport's default is plenty.
  @readback_timeout 5_000

  # `Transport.query_batch/2`'s own cap, restated so the slot scan chunks to it
  # rather than raising on a set with more scenes than one batch can carry.
  @batch_limit 64

  @max_prompt_length 1_000
  @max_bars 16

  # Live's own denominators. A signature outside this set is refused rather than
  # guessed at, because the beats-per-bar arithmetic below is the whole duration
  # contract.
  @supported_denominators [1, 2, 4, 8, 16]

  @doc """
  Run the whole workflow for one already-schema-validated parameter map.

  Returns `{:ok, %Seshat.Generation.Result{}}` or `{:error, message}`, where
  the message is a finished sentence naming the stage that failed and any side
  effect that survived it.
  """
  @spec generate(map()) :: {:ok, Result.t()} | {:error, String.t()}
  def generate(params) when is_map(params) do
    with {:ok, request} <- validate(params),
         {:ok, music} <- read_session(),
         {:ok, duration} <- duration(request.bars, music),
         {:ok, plan} <- resolve_destination(request),
         {:ok, source} <- resolve_variation_source(request),
         {:ok, reservation} <- reserve_take(request, duration) do
      render_and_import(request, music, duration, plan, source, reservation)
    end
  end

  # --- Cross-field validation ---

  @doc """
  The pure cross-field rules the JSON Schema cannot express.

  `Seshat.Tools.Validation` has already checked types, numeric bounds and
  unknown keys straight out of the declared schema. What is left is the
  relationships between parameters, plus the two string-length rules the
  schema/validator pair has no `minLength`/`maxLength` support for — so they
  live here rather than being implied by a schema that would not enforce them.

  Runs before any OSC or backend call, so every refusal it produces carries the
  same guarantee: nothing was generated and nothing in Live was touched.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, String.t()}
  def validate(params) when is_map(params) do
    description = Map.get(params, "description")
    negative = Map.get(params, "negative_prompt")
    track = Map.get(params, "track")
    track_name = Map.get(params, "track_name")
    variation = normalise_variation(Map.get(params, "variation_of"))
    strength = Map.get(params, "strength")
    bars = Map.get(params, "bars", 4)

    with :ok <- check_prompt(description, "description"),
         :ok <- check_optional_prompt(negative, "negative_prompt"),
         :ok <- check_bars(bars),
         :ok <- check_strength(strength, variation),
         :ok <- check_destination_track(track, variation),
         :ok <- check_track_name(track_name, track, variation) do
      {:ok,
       %{
         description: String.trim(description),
         negative_prompt: trimmed_or_nil(negative),
         bars: bars,
         track: track,
         clip_slot: Map.get(params, "clip_slot"),
         track_name: trimmed_or_nil(track_name),
         variation: variation,
         strength: strength || 0.55,
         seed: Map.get(params, "seed")
       }}
    end
  end

  defp normalise_variation(nil), do: nil

  defp normalise_variation(%{"track" => track, "clip_slot" => slot}),
    do: %{track: track, clip_slot: slot}

  defp normalise_variation(_other), do: nil

  defp check_prompt(value, name) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error,
         "#{name} is blank. Describe the material you want — for example " <>
           "\"dusty lo-fi drum break\" — and nothing was generated."}

      String.length(trimmed) > @max_prompt_length ->
        {:error,
         "#{name} is #{String.length(trimmed)} characters; the limit is #{@max_prompt_length}. " <>
           "Nothing was generated."}

      true ->
        :ok
    end
  end

  defp check_prompt(_value, name),
    do: {:error, "#{name} is required and must be a string. Nothing was generated."}

  defp check_optional_prompt(nil, _name), do: :ok
  defp check_optional_prompt(value, name), do: check_prompt(value, name)

  defp check_bars(bars) when is_integer(bars) and bars >= 1 and bars <= @max_bars, do: :ok

  defp check_bars(bars) do
    {:error,
     "bars must be a whole number from 1 to #{@max_bars} (got #{inspect(bars)}). " <>
       "Nothing was generated."}
  end

  defp check_strength(nil, _variation), do: :ok
  defp check_strength(_strength, variation) when is_map(variation), do: :ok

  defp check_strength(_strength, _variation) do
    {:error,
     "strength only means something with variation_of — it sets how far a variation departs " <>
       "from the clip it is based on. Pass variation_of, or drop strength. Nothing was " <>
       "generated."}
  end

  defp check_destination_track(nil, _variation), do: :ok
  defp check_destination_track(_track, nil), do: :ok

  defp check_destination_track(track, %{track: track}), do: :ok

  defp check_destination_track(track, %{track: source_track}) do
    {:error,
     "track #{track} conflicts with variation_of's source track #{source_track}. A variation " <>
       "lands on the source clip's own track; omit track, or pass track #{source_track}. " <>
       "Nothing was generated."}
  end

  defp check_track_name(nil, _track, _variation), do: :ok

  defp check_track_name(_name, track, _variation) when is_integer(track) do
    {:error,
     "track_name names a track this call would create, but track #{track} was also given, so " <>
       "no track is being created. Drop track_name to write to track #{track}, or drop track " <>
       "to create a new one. Nothing was generated."}
  end

  defp check_track_name(_name, _track, variation) when is_map(variation) do
    {:error,
     "track_name names a track this call would create, but variation_of already points at " <>
       "track #{variation.track}, which is where the variation lands. Drop track_name, or pass " <>
       "an explicit track. Nothing was generated."}
  end

  defp check_track_name(_name, _track, _variation), do: :ok

  defp trimmed_or_nil(nil), do: nil

  defp trimmed_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # --- Session and duration ---

  defp read_session do
    snapshot = State.snapshot()
    song = snapshot.song

    cond do
      not positive_number?(song.tempo) ->
        {:error,
         "Seshat does not know the session tempo, so it cannot work out how long the " <>
           "requested bars are. Run get_session_state (refresh: true) and try again. " <>
           "Nothing was generated."}

      not supported_signature?(song.time_sig_numerator, song.time_sig_denominator) ->
        {:error,
         "Seshat does not know a usable time signature for this session " <>
           "(#{inspect(song.time_sig_numerator)}/#{inspect(song.time_sig_denominator)}), so it " <>
           "cannot work out how long the requested bars are. Run get_session_state " <>
           "(refresh: true) and try again. Nothing was generated."}

      true ->
        {:ok,
         %{
           tempo: song.tempo * 1.0,
           numerator: song.time_sig_numerator,
           denominator: song.time_sig_denominator,
           key: key_hint(song)
         }}
    end
  catch
    :exit, _ ->
      {:error,
       "Seshat's session mirror is not available, so the session tempo and time signature " <>
         "could not be read and nothing was generated. Check that Seshat is running with " <>
         "Ableton Live open."}
  end

  defp positive_number?(value), do: is_number(value) and value > 0

  defp supported_signature?(numerator, denominator) do
    is_integer(numerator) and numerator > 0 and denominator in @supported_denominators
  end

  defp key_hint(%{root_note: root, scale_name: scale})
       when is_integer(root) and is_binary(scale) do
    "#{Seshat.Music.Pitch.pitch_class_name(root)} #{scale}"
  end

  defp key_hint(_song), do: nil

  @doc """
  Bars to beats, seconds and sample frames, at one tempo and time signature.

  Pure, and public because it is the arithmetic the whole duration claim rests
  on. `beats_per_bar` is `numerator * 4 / denominator`, so 4/4 is 4 beats, 6/8
  is 3, and 3/4 is 3 — Live counts a beat as a quarter note regardless of the
  denominator.
  """
  @spec duration(pos_integer(), map()) :: {:ok, map()} | {:error, String.t()}
  def duration(bars, %{tempo: tempo, numerator: numerator, denominator: denominator}) do
    beats_per_bar = numerator * 4 / denominator
    beats = bars * beats_per_bar
    seconds = beats * 60 / tempo

    {:ok,
     %{
       beats: beats,
       seconds: seconds,
       target_frames: target_frames(seconds)
     }}
  end

  @doc """
  The sample-frame count the runtime will trim its render to.

  The runtime computes `int(round(seconds * 44100))` in Python, whose `round`
  is **half-to-even**; Elixir's `round/1` is half-away-from-zero. They agree on
  every value that is not exactly halfway, and this rounds the way Python does
  so that they agree there too — otherwise a contrived tempo could put the
  reported frame count one frame away from the file's actual length, which is
  precisely the claim this feature makes.
  """
  @spec target_frames(float()) :: integer()
  def target_frames(seconds) when is_float(seconds) do
    exact = seconds * @sample_rate
    floor = Float.floor(exact)

    cond do
      exact - floor > 0.5 -> trunc(floor) + 1
      exact - floor < 0.5 -> trunc(floor)
      # Exactly halfway: to even.
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end

  @doc """
  The prompt handed to the model: the user's description, plus the session facts
  it cannot see.

  Pure and public so the tests can pin it. Tempo and time signature are always
  appended — they are the reason the render is the length it is — while the key
  is appended only when the session has one, as a soft hint. Nothing verifies
  the result is in that key, which is why the reply reports it as requested.
  """
  @spec prompt(String.t(), map()) :: String.t()
  def prompt(description, %{tempo: tempo, numerator: numerator, denominator: denominator} = music) do
    base = "#{description}. #{format_number(tempo)} BPM, #{numerator}/#{denominator} time."

    case Map.get(music, :key) do
      nil -> base
      key -> base <> " In #{key}."
    end
  end

  defp format_number(value) when is_float(value) do
    if value == Float.round(value), do: Integer.to_string(trunc(value)), else: to_string(value)
  end

  defp format_number(value), do: to_string(value)

  # --- Destination ---

  # Returns the plan for where the clip will land. `:track` is `nil` when a new
  # audio track is to be created *after* generation succeeds.
  defp resolve_destination(request) do
    case destination_track(request) do
      nil -> new_track_plan(request)
      track -> existing_track_plan(request, track)
    end
  end

  # Cross-field validation has already required an explicit destination to
  # agree with a variation's source, so either spelling resolves to the same
  # track. Keeping the explicit clause first also handles ordinary renders.
  defp destination_track(%{track: track}) when is_integer(track), do: track
  defp destination_track(%{variation: %{track: track}}), do: track
  defp destination_track(_request), do: nil

  defp existing_track_plan(request, track) do
    with :ok <- check_audio_track(track) do
      case request.clip_slot do
        nil -> first_empty_slot_plan(track)
        slot -> explicit_slot_plan(track, slot)
      end
    end
  end

  defp new_track_plan(request) do
    case request.clip_slot do
      nil ->
        # Slot 0 is only a slot if the set has a scene, so this branch asks the
        # same question the explicit one below does. Without it, the tool's most
        # ordinary call — no track, no clip_slot — would spend the whole render
        # and create a track before Live refused the import on a scene-less set,
        # which is the exact shape every other guard here is ordered to avoid.
        with {:ok, scenes} <- num_scenes() do
          if scenes > 0 do
            {:ok, %{track: nil, slot: 0, track_name: request.track_name}}
          else
            {:error,
             "This set has no scenes, so a new track would have no clip slot to generate " <>
               "into. Create a scene, then try again. Nothing was generated and no track " <>
               "was created."}
          end
        end

      slot ->
        # There is no occupancy to check — the track does not exist yet — but
        # the scene has to, or the import would name a slot Live has no object
        # for.
        with {:ok, scenes} <- num_scenes() do
          if slot < scenes do
            {:ok, %{track: nil, slot: slot, track_name: request.track_name}}
          else
            {:error,
             "clip_slot #{slot} is past the last scene (this set has #{scenes}, so the highest " <>
               "slot is #{scenes - 1}). Create a scene first, or omit clip_slot to use slot 0. " <>
               "Nothing was generated and no track was created."}
          end
        end
    end
  end

  # Group tracks and MIDI tracks both have clip slots, and both would take the
  # import somewhere useless — a group slot controls the clips below it, and a
  # MIDI track cannot hold an audio clip at all. Read as one batch: three
  # properties, one tick.
  defp check_audio_track(track) do
    entries = [
      {"/live/track/get/is_foldable", [track]},
      {"/live/track/get/has_audio_input", [track]},
      {"/live/track/get/has_midi_input", [track]}
    ]

    with {:ok, [foldable, audio_input, midi_input]} <-
           batch(entries, @guard_timeout, "track #{track}") do
      cond do
        truthy?(foldable) ->
          {:error,
           "Track #{track} is a group track, which cannot hold an audio clip. Pick one of the " <>
             "tracks inside it, or omit track to create a new audio track. Nothing was generated."}

        truthy?(midi_input) or not truthy?(audio_input) ->
          {:error,
           "Track #{track} is a MIDI track, so an audio clip cannot be imported onto it. Omit " <>
             "track to create a new audio track, or pick an existing audio track " <>
             "(get_session_state names them). Nothing was generated."}

        true ->
          :ok
      end
    end
  end

  defp explicit_slot_plan(track, slot) do
    case slot_occupied?(track, slot) do
      {:ok, false} ->
        {:ok, %{track: track, slot: slot, track_name: nil}}

      {:ok, true} ->
        {:error, occupied_message(track, slot)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp occupied_message(track, slot) do
    suggestion =
      case first_empty_slot(track) do
        {:ok, empty} -> " Slot #{empty} on that track is empty."
        _ -> " No empty slot was found on that track — create a scene first."
      end

    "Slot #{slot} on track #{track} already holds a clip, and generated audio never overwrites " <>
      "one.#{suggestion} Nothing was generated."
  end

  defp first_empty_slot_plan(track) do
    case first_empty_slot(track) do
      {:ok, slot} ->
        {:ok, %{track: track, slot: slot, track_name: nil}}

      {:error, message} ->
        {:error, message}
    end
  end

  defp slot_occupied?(track, slot) do
    with {:ok, [has_clip]} <-
           batch(
             [{"/live/clip_slot/get/has_clip", [track, slot]}],
             @guard_timeout,
             "slot #{slot} on track #{track}"
           ) do
      {:ok, truthy?(has_clip)}
    end
  end

  # Scans the existing scenes in `Transport.query_batch/2`-sized chunks — one
  # tick each rather than one per slot — and stops at the first empty one.
  # Scenes are never created here: a set's scene count is the user's layout, and
  # silently extending it is a change nobody asked for.
  defp first_empty_slot(track) do
    with {:ok, scenes} <- num_scenes() do
      if scenes == 0 do
        {:error,
         "This set has no scenes yet, so track #{track} has no clip slot to generate into. " <>
           "Create a scene, then try again. Nothing was generated."}
      else
        0..(scenes - 1)//1
        |> Enum.chunk_every(@batch_limit)
        |> Enum.reduce_while({:error, no_empty_slot_message(track, scenes)}, fn chunk, acc ->
          entries = for slot <- chunk, do: {"/live/clip_slot/get/has_clip", [track, slot]}

          case batch(entries, @guard_timeout, "the clip slots on track #{track}") do
            {:ok, values} ->
              case chunk
                   |> Enum.zip(values)
                   |> Enum.find(fn {_slot, value} -> not truthy?(value) end) do
                {slot, _value} -> {:halt, {:ok, slot}}
                nil -> {:cont, acc}
              end

            {:error, message} ->
              {:halt, {:error, message}}
          end
        end)
      end
    end
  end

  defp no_empty_slot_message(track, scenes) do
    "Every one of track #{track}'s #{scenes} clip slots already holds a clip, and generated " <>
      "audio never overwrites one. Create a scene, or free a slot with delete_clip, then try " <>
      "again. Nothing was generated."
  end

  defp num_scenes do
    case query("/live/song/get/num_scenes", [], @guard_timeout) do
      {:ok, [scenes]} when is_integer(scenes) and scenes >= 0 ->
        {:ok, scenes}

      {:ok, other} ->
        {:error,
         "Ableton's reply about the scene count was #{inspect(other)}, which Seshat cannot " <>
           "read, so nothing was generated."}

      {:error, message} ->
        {:error, message}
    end
  end

  # --- Variation source ---

  defp resolve_variation_source(%{variation: nil}), do: {:ok, nil}

  defp resolve_variation_source(%{
         variation: %{track: track, clip_slot: slot},
         strength: strength
       }) do
    entries = [
      {"/live/clip/get/is_audio_clip", [track, slot]},
      {"/live/clip/get/file_path", [track, slot]}
    ]

    with {:ok, [is_audio, file_path]} <-
           batch(entries, @guard_timeout, "the clip in slot #{slot} on track #{track}") do
      cond do
        not truthy?(is_audio) ->
          {:error,
           "The clip in slot #{slot} on track #{track} is not an audio clip, so it cannot be " <>
             "used as a variation source. Point variation_of at a generated audio clip. " <>
             "Nothing was generated."}

        not is_binary(file_path) or file_path == "" ->
          {:error,
           "The clip in slot #{slot} on track #{track} does not name a file on disk, so it " <>
             "cannot be used as a variation source. Nothing was generated."}

        true ->
          check_managed_source(file_path, track, slot, strength)
      end
    end
  end

  # The MVP varies Seshat's own takes and nothing else. Reading an arbitrary
  # file off the user's disk into a model is a different decision from writing
  # one Seshat itself produced, and it is not one this PR makes.
  defp check_managed_source(path, track, slot, strength) do
    expanded = Path.expand(path)

    cond do
      not under_root?(expanded) ->
        {:error,
         "The clip in slot #{slot} on track #{track} refers to #{path}, which is outside " <>
           "Seshat's generated-audio folder (#{generated_root()}). This version can only vary " <>
           "clips it generated itself. Nothing was generated."}

      not regular_file?(expanded) ->
        {:error,
         "The variation source #{path} is not a regular file on disk any more, so it cannot be " <>
           "read. Nothing was generated."}

      true ->
        {:ok, %{path: expanded, track: track, clip_slot: slot, strength: strength * 1.0}}
    end
  end

  defp under_root?(path) do
    with {:ok, root_identity} <- file_identity(generated_root()) do
      ancestor_has_identity?(Path.dirname(path), root_identity)
    else
      _ -> false
    end
  end

  # Live reports the path after the fork has realpath-resolved it, while
  # `generated_root/0` deliberately retains the configured spelling. Comparing
  # directory identities instead of strings makes containment survive a
  # symlinked ~/.seshat without accepting a similarly prefixed sibling or a
  # symlink that escapes the root.
  defp ancestor_has_identity?(directory, root_identity) do
    case file_identity(directory) do
      {:ok, ^root_identity} ->
        true

      _ ->
        parent = Path.dirname(directory)

        if parent == directory,
          do: false,
          else: ancestor_has_identity?(parent, root_identity)
    end
  end

  defp file_identity(path) do
    case File.stat(path) do
      {:ok, %File.Stat{inode: inode, major_device: device}} -> {:ok, {inode, device}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `lstat`, not `stat`: a symlink is refused rather than followed, matching the
  # rule the adapter applies to its own output.
  defp regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  # --- Reserving the take ---

  @doc """
  The managed folder every generated take is written into.

  Equal to the fork's `path_safety.IMPORT_ROOT` by contract, not by
  coincidence: the import address resolves the basename Seshat sends underneath
  that constant, so a divergence would make every import fail with "no such file
  in the import root". `:generated_root` overrides it for the test suite.
  """
  @spec generated_root() :: String.t()
  def generated_root do
    Path.expand(Application.get_env(:seshat, :generated_root) || @default_generated_root)
  end

  defp reserve_take(request, duration) do
    seed = request.seed || :rand.uniform(2_147_483_647)
    root = generated_root()

    with :ok <- ensure_root(root) do
      case reserve_name(root, slug(request.description), timestamp(), seed, 0) do
        {:ok, basename, path} ->
          {:ok, %{basename: basename, path: path, seed: seed, seconds: duration.seconds}}

        {:error, reason} ->
          {:error,
           "Could not reserve a file for this take in #{root} (#{reason}). Nothing was " <>
             "generated."}
      end
    end
  end

  # Created if absent, and chmodded on every call rather than only on creation:
  # the mode is the guarantee, and a root that has drifted to something wider is
  # exactly the case worth correcting. `mkdir_p` alone would leave it to the
  # process umask.
  defp ensure_root(root) do
    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      :ok
    else
      {:error, reason} ->
        {:error,
         "Could not prepare Seshat's generated-audio folder at #{root} " <>
           "(#{:file.format_error(reason)}). Nothing was generated."}
    end
  end

  # An exclusive create is what makes the name safe under concurrency: two
  # requests with the same description, second and seed cannot both win, and the
  # loser tries the next suffix rather than overwriting a take.
  defp reserve_name(_root, _slug, _stamp, _seed, attempt) when attempt > 50,
    do: {:error, "51 candidate names were already taken"}

  defp reserve_name(root, slug, stamp, seed, attempt) do
    suffix = if attempt == 0, do: "", else: "-#{attempt}"
    basename = "#{slug}-#{stamp}-#{seed}#{suffix}.wav"
    path = Path.join(root, basename)

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        File.close(io)
        {:ok, basename, path}

      {:error, :eexist} ->
        reserve_name(root, slug, stamp, seed, attempt + 1)

      {:error, reason} ->
        {:error, :file.format_error(reason)}
    end
  end

  @doc """
  A lowercase, filesystem-safe stem derived from the user's description.

  Public because the naming rule is part of what "every take is kept" means: the
  name has to be recognisable enough to find in Finder and constrained enough
  that no description can steer it. Nothing but `a-z`, `0-9` and `-` survives,
  so the model's text can never contribute a path separator, a leading dash, or
  a name of its own choosing.
  """
  @spec slug(String.t()) :: String.t()
  def slug(description) do
    description
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> String.trim("-")
    |> case do
      "" -> "take"
      stem -> stem
    end
  end

  defp timestamp do
    DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
  end

  # --- Render, then Live ---

  defp render_and_import(request, music, duration, plan, source, reservation) do
    reserved = reservation.path

    spec = %Spec{
      prompt: prompt(request.description, music),
      negative_prompt: request.negative_prompt,
      seconds: duration.seconds,
      seed: reservation.seed,
      init_audio: source && source.path,
      init_noise_level: source && source.strength,
      out_path: reservation.path
    }

    case Backend.impl().generate(spec) do
      {:ok, %{path: ^reserved} = generated} ->
        land(request, music, duration, plan, source, reservation, generated)

      # `Seshat.Generation.Backend`'s result type documents `path` as the
      # reserved path restated rather than assumed, and this is what makes that
      # a check rather than a comment. The wire carries a *basename* resolved
      # under the fork's own root, so a backend that wrote somewhere else would
      # otherwise have this module import whatever happened to be sitting at the
      # reserved name — nothing, usually, but the empty reservation itself.
      {:ok, %{path: path}} ->
        discard(reservation.path)

        {:error,
         "The audio backend reported writing #{path}, but this take was reserved at " <>
           "#{reservation.path}. Nothing was imported."}

      {:error, message} ->
        discard(reservation.path)
        {:error, message}
    end
  end

  # Only this request's reservation, and only after its render failed. Anything
  # else in the folder is somebody's take.
  defp discard(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.debug("Could not remove #{path}: #{inspect(reason)}")
    end
  end

  defp land(request, music, duration, plan, source, reservation, generated) do
    case ensure_track(plan, request) do
      {:ok, target} ->
        import_and_verify(request, music, duration, target, source, reservation, generated)

      {:error, message} ->
        {:error,
         message <>
           " The generated take was kept at #{reservation.path} — nothing was imported, and it " <>
           "can be dragged into Live by hand."}
    end
  end

  # The one Live mutation that happens before the import, and only once the file
  # exists. The Registry's create is count-verified: it names an index only
  # after the regular-track count rose by exactly one.
  defp ensure_track(%{track: track, slot: slot}, _request) when is_integer(track) do
    {:ok, %{track: track, slot: slot, created?: false, name: nil}}
  end

  defp ensure_track(%{track: nil, slot: slot, track_name: name}, request) do
    track_name = name || default_track_name(request)

    case Registry.execute(%Command{command: :create_track, track_type: :audio, name: track_name}) do
      {:ok, index} ->
        # The same guards an explicit track gets. A freshly created audio track
        # passing them is expected; a Live that answers otherwise is a reason to
        # stop before importing, not to assume.
        case check_audio_track(index) do
          :ok ->
            {:ok, %{track: index, slot: slot, created?: true, name: track_name}}

          {:error, message} ->
            {:error,
             "Created audio track #{index} (\"#{track_name}\"), but then could not confirm it " <>
               "can hold an audio clip: #{message} The empty track was left in place."}
        end

      {:error, reason} ->
        {:error, "Could not create an audio track for the generated clip: #{render(reason)}"}
    end
  end

  defp default_track_name(%{variation: %{}}), do: "Generated"

  defp default_track_name(request),
    do: request.description |> String.slice(0, 20) |> String.trim()

  defp import_and_verify(request, music, duration, target, source, reservation, generated) do
    case import_clip(target, reservation.basename) do
      {:ok, _length} ->
        clip_name = clip_name(request)
        _ = Transport.send_message("/live/clip/set/name", [target.track, target.slot, clip_name])

        verify(request, music, duration, target, source, reservation, generated, clip_name)

      {:error, message} ->
        {:error, message <> partial_effects(target, reservation)}
    end
  end

  defp import_clip(target, basename) do
    case query(
           "/live/clip_slot/create_audio_clip",
           [target.track, target.slot, basename],
           @import_timeout,
           [target.track, target.slot]
         ) do
      {:ok, ["ok", length]} ->
        {:ok, length}

      {:ok, ["error", message]} when is_binary(message) ->
        {:error,
         "Ableton refused to import the generated file into slot #{target.slot} on track " <>
           "#{target.track}: #{message}."}

      {:ok, other} ->
        {:error,
         "Ableton's reply to the import was #{inspect(other)}, which Seshat cannot read, so " <>
           "whether the clip landed is unknown."}

      {:error, message} ->
        {:error, message}
    end
  end

  # Named after the material, not after the file: the file name carries a
  # timestamp and a seed, which is the wrong thing to read off a clip in the
  # Session grid.
  defp clip_name(request) do
    request.description |> String.slice(0, 40) |> String.trim()
  end

  # Two shapes, deliberately not one function with a flag: what this code has
  # actually observed differs on either side of the import's reply.
  #
  # Before it, nothing landed, and "the track is empty" is a fact. After a
  # `["ok", _]` reply Live has already returned a `Clip`, so a created track
  # almost certainly *does* hold one and only the read-back disagreed or never
  # arrived. Calling it empty there would contradict the sentence it is appended
  # to — which is the whole failure mode this module's requested/observed split
  # exists to prevent.
  defp partial_effects(target, reservation) do
    created =
      if target.created?,
        do:
          " Audio track #{target.track} (\"#{target.name}\") was created and is still there, empty.",
        else: ""

    " The generated take was kept at #{reservation.path}.#{created}"
  end

  defp unverified_effects(target, reservation) do
    created =
      if target.created?,
        do: " Audio track #{target.track} (\"#{target.name}\") was created and is still there.",
        else: ""

    " The generated take was kept at #{reservation.path}.#{created} Whether the clip is in " <>
      "slot #{target.slot} is exactly what could not be confirmed — read that track with " <>
      "get_clip_slots before generating again, so a second take does not land beside one " <>
      "that is already there."
  end

  # Success is what Live says on a *separate* read, never the import's own
  # reply: the fork documents that whether the returned Clip is synchronously
  # readable is unmeasured, so `length` from the import is treated as a hint and
  # this batch is the evidence.
  defp verify(request, music, duration, target, source, reservation, generated, clip_name) do
    entries = [
      {"/live/clip/get/is_audio_clip", [target.track, target.slot]},
      {"/live/clip/get/name", [target.track, target.slot]},
      {"/live/clip/get/length", [target.track, target.slot]},
      {"/live/clip/get/looping", [target.track, target.slot]},
      {"/live/clip/get/warping", [target.track, target.slot]},
      {"/live/clip/get/file_path", [target.track, target.slot]}
    ]

    case batch(entries, @readback_timeout, "the imported clip") do
      {:ok, [is_audio, name, length, looping, warping, file_path]} ->
        cond do
          not truthy?(is_audio) ->
            {:error,
             "The import reported success, but slot #{target.slot} on track #{target.track} " <>
               "does not read back as an audio clip." <> unverified_effects(target, reservation)}

          not same_file?(file_path, reservation.path) ->
            {:error,
             "The import reported success, but slot #{target.slot} on track #{target.track} " <>
               "reads back as #{inspect(file_path)} rather than the generated take." <>
               unverified_effects(target, reservation)}

          true ->
            FollowCam.steer("generate_audio", %{track: target.track, slot: target.slot})

            {:ok,
             build_result(
               request,
               music,
               duration,
               target,
               source,
               reservation,
               generated,
               %{
                 name: name,
                 length: length,
                 looping: boolean_or_nil(looping),
                 warping: boolean_or_nil(warping),
                 file_path: file_path
               },
               clip_name
             )}
        end

      {:error, message} ->
        {:error,
         "The import reported success, but reading the clip back failed: #{message}" <>
           unverified_effects(target, reservation)}
    end
  end

  # Inode identity rather than string equality: the fork resolves the name it is
  # given with `realpath`, so a symlinked `~/.seshat` would make Live report a
  # different *string* for the very file just written. Falls back to comparing
  # expanded paths when either stat fails.
  defp same_file?(reported, ours) when is_binary(reported) do
    case {File.stat(reported), File.stat(ours)} do
      {{:ok, %File.Stat{inode: a, major_device: da}},
       {:ok, %File.Stat{inode: b, major_device: db}}} ->
        {a, da} == {b, db}

      _ ->
        Path.expand(reported) == Path.expand(ours)
    end
  end

  defp same_file?(_reported, _ours), do: false

  defp build_result(
         request,
         music,
         duration,
         target,
         source,
         reservation,
         generated,
         observed,
         clip_name
       ) do
    %Result{
      track: target.track,
      track_name: target.name,
      created_track?: target.created?,
      clip_slot: target.slot,
      clip_name: clip_name,
      bars: request.bars,
      beats: duration.beats,
      seconds: duration.seconds,
      target_frames: duration.target_frames,
      tempo: music.tempo,
      time_sig_numerator: music.numerator,
      time_sig_denominator: music.denominator,
      key: music.key,
      file: reservation.basename,
      path: reservation.path,
      seed: generated.seed,
      wall_ms: generated.wall_ms,
      variation:
        source && %{track: source.track, clip_slot: source.clip_slot, strength: source.strength},
      observed: observed
    }
  end

  # --- Small OSC helpers ---
  #
  # Deliberately local rather than borrowed from `Seshat.Tools.Handlers`: those
  # are private there, and importing a workflow's OSC vocabulary from the
  # dispatcher it is called by would make the dependency circular. They do the
  # same two jobs — check the echoed prefix, unwrap the payload — on the two
  # shapes this module reads.

  defp query(address, args, timeout, echo \\ nil) do
    echo = echo || args

    case Transport.query(address, args, timeout) do
      {:ok, {_address, values}} ->
        case correlate(values, echo) do
          {:ok, payload} ->
            {:ok, payload}

          :stale ->
            {:error,
             "Ableton's reply on #{address} was about a different request, so nothing further " <>
               "was done."}
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason) <> " — nothing further was done."}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out waiting for Ableton on #{address}, so nothing further was done. Check that " <>
         "Live is running with AbletonOSC enabled, and that `mix abletonosc.install` has been " <>
         "run since the import address was added."}
  end

  # One batch, one value per entry — every address this module batches replies
  # with exactly one value behind its echoed prefix.
  defp batch(entries, timeout, subject) do
    case Transport.query_batch(entries, timeout) do
      {:ok, results} ->
        Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
          case unwrap_entry(result, subject) do
            {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      {:error, reason} ->
        {:error, Transport.describe_error(reason) <> " — nothing further was done."}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading #{subject} from Ableton, so nothing further was done. Check that " <>
         "Live is running with AbletonOSC enabled."}
  end

  defp unwrap_entry({:ok, payload}, subject) do
    case unwrap(payload) do
      {:ok, value} ->
        {:ok, value}

      :unexpected_shape ->
        {:error,
         "Ableton's reply about #{subject} was #{inspect(payload)}, which Seshat cannot read."}
    end
  end

  defp unwrap_entry({:error, {:live_error, message}}, subject) do
    {:error, "Ableton rejected the request about #{subject}: #{message}."}
  end

  defp correlate(values, echo) do
    {echoed, payload} = Enum.split(values, length(echo))

    if length(echoed) == length(echo) and
         Enum.zip(echoed, echo) |> Enum.all?(fn {a, b} -> a == b end) do
      {:ok, payload}
    else
      :stale
    end
  end

  # Every address `unwrap_entry/2` sees replies with a bare single-element
  # list — the `["ok"|"error", _]` discriminator belongs to
  # `/live/clip_slot/create_audio_clip` alone, and that address is matched
  # directly in `import_clip/2`, never routed through here.
  defp unwrap([value]), do: {:ok, value}
  defp unwrap(_other), do: :unexpected_shape

  defp truthy?(value), do: value in [1, true]

  defp boolean_or_nil(1), do: true
  defp boolean_or_nil(true), do: true
  defp boolean_or_nil(0), do: false
  defp boolean_or_nil(false), do: false
  defp boolean_or_nil(_other), do: nil

  defp render(reason) when is_binary(reason), do: reason
  defp render(reason), do: inspect(reason)
end
