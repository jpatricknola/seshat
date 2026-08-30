defmodule Seshat.Test.LiveDouble do
  @moduledoc """
  A scripted Ableton for the generated-audio tests.

  `run/3` starts the work in a task and, from the calling process, answers every
  datagram the work sends against a small mutable model of a session: tracks
  with their audio/group flags, a scene count, occupied slots, and whether the
  import address says `"ok"` or `"error"`. It returns the work's result together
  with the datagram trace, in arrival order.

  Arrival order is the point. `assert_receive` proves a datagram arrived but
  never that it arrived *second*, and the claims this feature makes are almost
  all ordering claims: that no generation begins for a refused target, that no
  Live mutation precedes a successful file, that nothing steers the view before
  the clip has been read back.

  The model mutates as the work runs — the import fills the slot it was given,
  the track create appends a track — so a workflow that reads its own effects
  back sees what it just did rather than a fixed script.
  """

  import ExUnit.Assertions

  alias Seshat.OSC.Message
  alias Seshat.OSC.Transport
  alias Seshat.Test.OSCSink

  @doc """
  A session with one audio track (0), one MIDI track (1), one group track (2),
  eight scenes, and one clip already in slot 0 of track 0.
  """
  @spec session() :: map()
  def session do
    %{
      tracks: %{
        0 => %{audio?: true, group?: false},
        1 => %{audio?: false, group?: false},
        2 => %{audio?: true, group?: true}
      },
      num_tracks: 3,
      scenes: 8,
      clips: %{
        {0, 0} => %{
          name: "Kept take",
          length: 16.0,
          looping: 1,
          warping: 1,
          path: nil,
          audio?: true
        }
      },
      import: :ok
    }
  end

  @doc """
  Run `work` against `live`, answering its queries, and return
  `{result, trace}`.
  """
  @spec run(pid(), map(), (-> term())) :: {term(), [{String.t(), list()}]}
  def run(sink, live, work) do
    task = Task.async(work)

    serve(sink, task, live, [], nil, System.monotonic_time(:millisecond) + 15_000)
  end

  # Keeps answering while the work runs, then drains briefly: the follow cam's
  # steering is fire-and-forget and can still be in flight after the work has
  # returned, and it is exactly what the ordering assertions need to see.
  #
  # The result is taken with `Task.yield/2` rather than `Task.await/2` because
  # this process is also the one answering the task's queries — awaiting would
  # stop answering, and the work would time out against its own test.
  defp serve(sink, task, live, trace, result, deadline) do
    receive do
      {:osc_out, address, args} ->
        {reply, live} = respond(address, args, live)

        case reply do
          :silent -> :ok
          values -> reply_datagram(sink, Message.encode(address, values))
        end

        serve(sink, task, live, [{address, args} | trace], result, deadline)
    after
      if(result, do: 60, else: 20) ->
        cond do
          result != nil ->
            {result, Enum.reverse(trace)}

          System.monotonic_time(:millisecond) > deadline ->
            Task.shutdown(task, :brutal_kill)
            flunk("the work did not finish within 15s")

          true ->
            case Task.yield(task, 0) do
              {:ok, value} -> serve(sink, task, live, trace, value, deadline)
              {:exit, reason} -> flunk("the work crashed: #{inspect(reason)}")
              nil -> serve(sink, task, live, trace, result, deadline)
            end
        end
    end
  end

  defp reply_datagram(sink, binary) do
    reply_port = :sys.get_state(Transport).reply_port
    :ok = OSCSink.send_datagram(sink, reply_port, binary)
  end

  @doc "Just the addresses out of a trace, in arrival order."
  @spec addresses([{String.t(), list()}]) :: [String.t()]
  def addresses(trace), do: Enum.map(trace, &elem(&1, 0))

  defp respond("/live/track/get/is_foldable", [track], live),
    do: {[track, flag(track(live, track)[:group?])], live}

  defp respond("/live/track/get/has_audio_input", [track], live),
    do: {[track, flag(track(live, track)[:audio?])], live}

  defp respond("/live/track/get/has_midi_input", [track], live),
    do: {[track, flag(not track(live, track)[:audio?])], live}

  defp respond("/live/song/get/num_scenes", [], live), do: {[live.scenes], live}

  defp respond("/live/song/get/num_tracks", [], live), do: {[live.num_tracks], live}

  defp respond("/live/clip_slot/get/has_clip", [track, slot], live),
    do: {[track, slot, flag(Map.has_key?(live.clips, {track, slot}))], live}

  defp respond("/live/clip/get/is_audio_clip", [track, slot], live),
    do: {[track, slot, flag(clip(live, track, slot)[:audio?])], live}

  defp respond("/live/clip/get/file_path", [track, slot], live),
    do: {[track, slot, clip(live, track, slot)[:path] || ""], live}

  defp respond("/live/clip/get/name", [track, slot], live),
    do: {[track, slot, clip(live, track, slot)[:name] || ""], live}

  defp respond("/live/clip/get/length", [track, slot], live),
    do: {[track, slot, clip(live, track, slot)[:length] || 0.0], live}

  defp respond("/live/clip/get/looping", [track, slot], live),
    do: {[track, slot, clip(live, track, slot)[:looping] || 0], live}

  defp respond("/live/clip/get/warping", [track, slot], live),
    do: {[track, slot, clip(live, track, slot)[:warping] || 0], live}

  # The fork resolves the wire-supplied *name* under its own fixed root and
  # hands Live the absolute path, so the double does the same — which is what
  # makes the workflow's read-back path check meaningful rather than trivially
  # true.
  # `:import_path` overrides the path the created clip reads back as, which is
  # how a "Live imported *something else*" read-back is reachable at all.
  defp respond("/live/clip_slot/create_audio_clip", [track, slot, name], live) do
    case live.import do
      :ok ->
        clip = %{
          name: "",
          length: 16.0,
          looping: 1,
          warping: 1,
          path:
            Map.get(live, :import_path) ||
              Path.join(Seshat.Generation.AudioClip.generated_root(), name),
          audio?: Map.get(live, :import_audio?, true)
        }

        {[track, slot, "ok", 16.0], put_in(live.clips[{track, slot}], clip)}

      {:error, message} ->
        {[track, slot, "error", message], live}
    end
  end

  # --- The composed-MIDI workflow ---
  #
  # `generate_midi` writes through the extended-notes family, which the audio
  # workflow never touches. The model keeps the notes it was sent so the
  # read-back is a real read of what landed, windows included.

  defp respond("/live/clip_slot/create_clip", [track, slot, length], live) do
    clip = %{name: "", length: length, looping: 1, warping: 0, audio?: false, notes: []}
    {:silent, put_in(live.clips[{track, slot}], clip)}
  end

  defp respond(
         "/live/clip/add/notes_extended",
         [_track, _slot | _fields],
         %{swallow_notes: true} = live
       ),
       do: {:silent, live}

  defp respond("/live/clip/add/notes_extended", [track, slot | fields], live) do
    existing = clip(live, track, slot)[:notes] || []

    added =
      fields
      |> Enum.chunk_every(8)
      |> Enum.filter(&(length(&1) == 8))
      |> Enum.with_index(length(existing))
      |> Enum.map(fn {[pitch, start, duration, velocity, mute, probability, deviation, release],
                      id} ->
        # `:drops_expression` is how "Live kept the note but not the three
        # expression fields" is reachable at all — the exact uncertainty
        # `priv/AbletonOSC/API.md` carries a ⚠️ on.
        {probability, deviation} =
          if Map.get(live, :drops_expression, false),
            do: {1.0, 0.0},
            else: {probability, deviation}

        %{
          pitch: pitch,
          start: start,
          duration: duration,
          velocity: velocity,
          mute: mute,
          probability: probability,
          deviation: deviation,
          release: release,
          id: id
        }
      end)

    {:silent, put_in(live.clips[{track, slot}][:notes], existing ++ added)}
  end

  defp respond(
         "/live/clip/get/notes_extended",
         [track, slot, low_pitch, pitch_span, start, span],
         live
       ) do
    notes =
      (clip(live, track, slot)[:notes] || [])
      |> Enum.filter(fn note ->
        note.pitch >= low_pitch and note.pitch < low_pitch + pitch_span and
          note.start >= start and note.start < start + span
      end)
      |> Enum.flat_map(fn note ->
        [
          note.pitch,
          note.start,
          note.duration,
          note.velocity,
          note.mute,
          note.probability,
          note.deviation,
          note.release,
          note.id
        ]
      end)

    {[track, slot] ++ notes, live}
  end

  # The fork's widened reply: `track, uri, "ok", name, device_index`.
  defp respond("/live/browser/load_item", [track, uri], live) do
    case Map.get(live, :load, :ok) do
      :ok -> {[track, uri, "ok", "Loaded Device", 0], live}
      {:error, message} -> {[track, uri, "error", message], live}
      :silent -> {:silent, live}
    end
  end

  defp respond("/live/song/create_midi_track", [-1], live) do
    index = live.num_tracks

    live =
      live
      |> Map.put(:num_tracks, index + 1)
      |> put_in([:tracks, index], %{audio?: false, group?: false})

    {:silent, live}
  end

  defp respond("/live/song/create_audio_track", [-1], live) do
    index = live.num_tracks

    live =
      live
      |> Map.put(:num_tracks, index + 1)
      |> put_in([:tracks, index], %{audio?: true, group?: false})

    {:silent, live}
  end

  # `:ignore_renames` drops the setter on the floor, which is the only way a
  # lost fire-and-forget datagram is reachable in a test: nothing on the wire
  # distinguishes a rename that landed from one that did not, which is exactly
  # why the read-back compares the name it asked for against the name Live
  # reports.
  defp respond("/live/clip/set/name", [track, slot, name], live) do
    if Map.get(live, :ignore_renames, false) do
      {:silent, live}
    else
      {:silent, put_in(live.clips[{track, slot}][:name], name)}
    end
  end

  # Everything else — the undo-step pair, track renames, the follow cam's view
  # calls — is fire-and-forget and answers nothing, exactly as AbletonOSC does.
  defp respond(_address, _args, live), do: {:silent, live}

  defp track(live, index), do: Map.get(live.tracks, index, %{audio?: false, group?: false})
  defp clip(live, track, slot), do: Map.get(live.clips, {track, slot}, %{})

  defp flag(true), do: 1
  defp flag(_other), do: 0
end
