defmodule Seshat.Session.State do
  @moduledoc """
  GenServer that mirrors Ableton session state.

  On startup: queries Ableton for initial track state, then subscribes to
  AbletonOSC listeners so any change — whether from this app, the Ableton UI,
  or a MIDI controller — is pushed here automatically via OSC on port 11001.
  """

  use GenServer

  require Logger

  @pubsub Seshat.PubSub
  @topic "osc:in"
  @listened_properties ~w(panning volume mute solo name)
  @listened_song_properties ~w(
    tempo signature_numerator signature_denominator is_playing root_note scale_name
  )

  # The default query timeout, matching Transport's own.
  @query_timeout 5_000

  # `/live/return_track/*` and `/live/master/*` come from Seshat's return_track.py
  # extension, not upstream AbletonOSC, so a Live where `mix abletonosc.install`
  # was never run answers them with silence rather than an error. Short timeout:
  # a missing extension must not stall every refresh for five seconds.
  @return_probe_timeout 2_000

  # --- Client API ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def tracks, do: GenServer.call(__MODULE__, :tracks)
  def song, do: GenServer.call(__MODULE__, :song)

  @doc """
  Return tracks, in send order — `%{index, name, volume}`, where return 0 is
  send A on every regular track. Empty when the extension isn't answering, and a
  single entry's `volume` is `nil` when that one query went unanswered — never a
  guessed number.
  """
  def return_tracks, do: GenServer.call(__MODULE__, :return_tracks)

  @doc """
  Master track level as `%{volume: float}`, or `nil` when
  `/live/master/get/volume` never answered — i.e. Seshat's AbletonOSC extension
  isn't installed. `nil` is "unknown", never "zero".
  """
  def master, do: GenServer.call(__MODULE__, :master)

  @doc "Re-queries Ableton for full state and re-subscribes to all listeners."
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @topic)

    initial_song = %{
      tempo: 120.0,
      time_sig_numerator: 4,
      time_sig_denominator: 4,
      is_playing: false,
      root_note: 0,
      scale_name: "Major"
    }

    {:ok, %{song: initial_song, tracks: [], return_tracks: [], master: nil}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_call(:tracks, _from, state), do: {:reply, state.tracks, state}
  def handle_call(:song, _from, state), do: {:reply, state.song, state}
  def handle_call(:return_tracks, _from, state), do: {:reply, state.return_tracks, state}
  def handle_call(:master, _from, state), do: {:reply, state.master, state}

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_info({:osc_message, "/live/song/get/tempo", [value]}, state) do
    {:noreply, update_song(state, :tempo, value)}
  end

  def handle_info({:osc_message, "/live/song/get/signature_numerator", [value]}, state) do
    {:noreply, update_song(state, :time_sig_numerator, value)}
  end

  def handle_info({:osc_message, "/live/song/get/signature_denominator", [value]}, state) do
    {:noreply, update_song(state, :time_sig_denominator, value)}
  end

  def handle_info({:osc_message, "/live/song/get/is_playing", [value]}, state) do
    {:noreply, update_song(state, :is_playing, to_bool(value))}
  end

  def handle_info({:osc_message, "/live/song/get/root_note", [value]}, state) do
    {:noreply, update_song(state, :root_note, value)}
  end

  def handle_info({:osc_message, "/live/song/get/scale_name", [value]}, state) do
    {:noreply, update_song(state, :scale_name, value)}
  end

  def handle_info({:osc_message, "/live/track/get/panning", [idx, value]}, state) do
    {:noreply, update_track(state, idx, :pan, value)}
  end

  def handle_info({:osc_message, "/live/track/get/volume", [idx, value]}, state) do
    {:noreply, update_track(state, idx, :volume, value)}
  end

  def handle_info({:osc_message, "/live/track/get/mute", [idx, value]}, state) do
    {:noreply, update_track(state, idx, :mute, to_bool(value))}
  end

  def handle_info({:osc_message, "/live/track/get/solo", [idx, value]}, state) do
    {:noreply, update_track(state, idx, :solo, to_bool(value))}
  end

  def handle_info({:osc_message, "/live/track/get/name", [idx, name]}, state) do
    {:noreply, update_track(state, idx, :name, name)}
  end

  def handle_info({:osc_message, address, _args}, state) do
    Logger.debug("Unhandled OSC notification: #{address}")
    {:noreply, state}
  end

  # --- Private ---

  defp do_refresh(state) do
    alias Seshat.OSC.Transport

    song = %{
      tempo: query_song_float(Transport, "/live/song/get/tempo", 120.0),
      time_sig_numerator: query_song_int(Transport, "/live/song/get/signature_numerator", 4),
      time_sig_denominator: query_song_int(Transport, "/live/song/get/signature_denominator", 4),
      is_playing: query_song_int(Transport, "/live/song/get/is_playing", 0) |> to_bool(),
      root_note: query_song_int(Transport, "/live/song/get/root_note", 0),
      scale_name: query_song_string(Transport, "/live/song/get/scale_name", "Major")
    }

    Logger.info(
      "Song: #{song.tempo} BPM, #{song.time_sig_numerator}/#{song.time_sig_denominator}, " <>
        "key #{Seshat.Music.Pitch.pitch_class_name(song.root_note)} #{song.scale_name}"
    )

    state =
      case probe(Transport, "/live/song/get/num_tracks", [], @query_timeout) do
        {:ok, [count]} when is_integer(count) ->
          tracks = read_tracks(Transport, count)

          subscribe_song_listeners()
          subscribe_listeners(tracks)

          Logger.info(
            "Loaded #{length(tracks)} tracks: #{Enum.map_join(tracks, ", ", & &1.name)}"
          )

          %{state | song: song, tracks: tracks}

        # Anything else — a timeout, a deaf transport, a reply in a shape we
        # don't recognise — leaves the session unmirrored rather than crashing
        # a GenServer whose supervisor would only restart it into the same wall.
        other ->
          Logger.warning("Could not load tracks from Ableton: #{inspect(other)}")
          %{state | song: song}
      end

    Map.merge(state, refresh_returns(Transport))
  end

  defp read_tracks(_transport, count) when count < 1, do: []

  defp read_tracks(transport, count) do
    Enum.map(0..(count - 1), fn i ->
      %{
        index: i,
        name: query_string(transport, "/live/track/get/name", i, "Track #{i + 1}"),
        volume: query_float(transport, "/live/track/get/volume", i, 0.85),
        pan: query_float(transport, "/live/track/get/panning", i, 0.0),
        mute: query_int(transport, "/live/track/get/mute", i, 0) |> to_bool(),
        solo: query_int(transport, "/live/track/get/solo", i, 0) |> to_bool()
      }
    end)
  end

  # No listeners for these in v1 — they are re-read on every refresh, and the
  # mutating tools call `refresh/0`. A return or master fader moved in Live's UI
  # therefore goes stale until the next refresh, like clip state today.
  defp refresh_returns(transport) do
    case probe(transport, "/live/return_track/get/count", [], @return_probe_timeout) do
      {:ok, [count]} when is_integer(count) ->
        return_tracks = read_return_tracks(transport, count)

        Logger.info(
          "Loaded #{length(return_tracks)} return track(s): " <>
            "#{Enum.map_join(return_tracks, ", ", & &1.name)}"
        )

        %{return_tracks: return_tracks, master: read_master(transport)}

      _no_answer ->
        Logger.warning(
          "Return tracks and master volume are unavailable: /live/return_track/get/count did " <>
            "not answer. Run `mix abletonosc.install` and restart Ableton Live."
        )

        %{return_tracks: [], master: nil}
    end
  end

  defp read_return_tracks(_transport, count) when count < 1, do: []

  defp read_return_tracks(transport, count) do
    Enum.map(0..(count - 1), fn i ->
      %{
        index: i,
        name:
          query_string(
            transport,
            "/live/return_track/get/name",
            i,
            "Return #{i}",
            @return_probe_timeout
          ),
        volume:
          query_float(
            transport,
            "/live/return_track/get/volume",
            i,
            nil,
            @return_probe_timeout
          )
      }
    end)
  end

  # Only reached once `get/count` has answered, so the extension is installed —
  # a lost datagram for this one query specifically is the only way to land here
  # without an answer. `nil` is the same "unavailable" signal `refresh_returns/1`
  # uses when the extension itself doesn't answer at all: `format_return_tracks/2`
  # already reports that honestly rather than printing a fabricated number, at
  # the cost of also hiding the return tracks (already loaded above) behind that
  # one lost datagram — an acceptable trade against reporting a guessed volume as
  # real.
  defp read_master(transport) do
    case probe(transport, "/live/master/get/volume", [], @return_probe_timeout) do
      {:ok, [volume]} when is_float(volume) -> %{volume: volume}
      _no_answer -> nil
    end
  end

  defp subscribe_song_listeners do
    alias Seshat.OSC.Transport

    for prop <- @listened_song_properties do
      Transport.send_message("/live/song/start_listen/#{prop}", [])
    end
  end

  defp subscribe_listeners(tracks) do
    alias Seshat.OSC.Transport

    for track <- tracks, prop <- @listened_properties do
      Transport.send_message("/live/track/start_listen/#{prop}", [track.index])
    end
  end

  defp update_song(state, key, value) do
    Logger.debug("Song #{key} → #{inspect(value)}")
    %{state | song: Map.put(state.song, key, value)}
  end

  defp update_track(state, idx, key, value) do
    Logger.debug("Track #{idx} #{key} → #{inspect(value)}")

    tracks =
      Enum.map(state.tracks, fn track ->
        if track.index == idx, do: Map.put(track, key, value), else: track
      end)

    %{state | tracks: tracks}
  end

  # Each of these accepts the reply both with and without an echoed index, so the
  # same helper serves the bare song getters' shape and the per-index ones. The
  # three-element clause is the return/master extension's ok/error envelope: an
  # `"error"` payload doesn't match it and falls through to the default, which is
  # right — the only way to ask this extension for an index it doesn't have is to
  # race a return being deleted mid-refresh.
  #
  # Every echoed index is checked against the one asked for, the same reason
  # `Handlers.query_echoed/5` does it: Transport correlates replies by address
  # alone and holds one query at a time, so a reply abandoned by an earlier
  # timeout can land while the next index's query is pending. Unchecked, that
  # hangs return 0's name on return 1 — a wrong answer that looks like a right
  # one. Compared with `==` rather than pinned, matching Handlers: these callers
  # always send integers, but a float index would still come back as an integer.
  defp query_string(transport, address, index, default, timeout \\ @query_timeout) do
    case probe(transport, address, [index], timeout) do
      {:ok, [s]} when is_binary(s) -> s
      {:ok, [idx, s]} when idx == index and is_binary(s) -> s
      {:ok, [idx, "ok", s]} when idx == index and is_binary(s) -> s
      _ -> default
    end
  end

  defp query_float(transport, address, index, default, timeout \\ @query_timeout) do
    case probe(transport, address, [index], timeout) do
      {:ok, [v]} when is_float(v) -> v
      {:ok, [idx, v]} when idx == index and is_float(v) -> v
      {:ok, [idx, "ok", v]} when idx == index and is_float(v) -> v
      _ -> default
    end
  end

  defp query_int(transport, address, index, default, timeout \\ @query_timeout) do
    case probe(transport, address, [index], timeout) do
      {:ok, [v]} when is_integer(v) -> v
      {:ok, [idx, v]} when idx == index and is_integer(v) -> v
      {:ok, [true]} -> 1
      {:ok, [false]} -> 0
      {:ok, [idx, true]} when idx == index -> 1
      {:ok, [idx, false]} when idx == index -> 0
      _ -> default
    end
  end

  # `Transport.query/3` exits the caller on timeout, and a missing extension (or a
  # dropped datagram) is exactly that. Catching it here means one unanswered
  # property falls back to its default instead of taking the whole GenServer down
  # mid-refresh.
  defp probe(transport, address, args, timeout) do
    case transport.query(address, args, timeout) do
      {:ok, {_addr, values}} -> {:ok, values}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :timeout}
  end

  # Like the per-index helpers, these go through `probe/4` — an Ableton that
  # isn't running, or isn't reachable, must leave the defaults standing rather
  # than take this GenServer down before it has finished starting.
  defp query_song_float(transport, address, default) do
    case probe(transport, address, [], @query_timeout) do
      {:ok, [v]} when is_float(v) -> v
      _ -> default
    end
  end

  defp query_song_string(transport, address, default) do
    case probe(transport, address, [], @query_timeout) do
      {:ok, [s]} when is_binary(s) -> s
      _ -> default
    end
  end

  defp query_song_int(transport, address, default) do
    case probe(transport, address, [], @query_timeout) do
      {:ok, [v]} when is_integer(v) -> v
      {:ok, [true]} -> 1
      {:ok, [false]} -> 0
      _ -> default
    end
  end

  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool(1), do: true
  defp to_bool(0), do: false
  defp to_bool(v) when is_integer(v), do: v != 0
end
