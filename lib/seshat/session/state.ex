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
  @listened_song_properties ~w(tempo signature_numerator signature_denominator is_playing)

  # --- Client API ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def tracks, do: GenServer.call(__MODULE__, :tracks)
  def song, do: GenServer.call(__MODULE__, :song)

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
      is_playing: false
    }

    {:ok, %{song: initial_song, tracks: []}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}
  def handle_call(:tracks, _from, state), do: {:reply, state.tracks, state}
  def handle_call(:song, _from, state), do: {:reply, state.song, state}

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
      is_playing: query_song_int(Transport, "/live/song/get/is_playing", 0) |> to_bool()
    }

    Logger.info("Song: #{song.tempo} BPM, #{song.time_sig_numerator}/#{song.time_sig_denominator}")

    case Transport.query("/live/song/get/num_tracks", []) do
      {:ok, {_addr, [count]}} ->
        tracks =
          Enum.map(0..(count - 1), fn i ->
            %{
              index: i,
              name: query_string(Transport, "/live/track/get/name", i, "Track #{i + 1}"),
              volume: query_float(Transport, "/live/track/get/volume", i, 0.85),
              pan: query_float(Transport, "/live/track/get/panning", i, 0.0),
              mute: query_int(Transport, "/live/track/get/mute", i, 0) |> to_bool(),
              solo: query_int(Transport, "/live/track/get/solo", i, 0) |> to_bool()
            }
          end)

        subscribe_song_listeners()
        subscribe_listeners(tracks)
        Logger.info("Loaded #{length(tracks)} tracks: #{Enum.map_join(tracks, ", ", & &1.name)}")
        %{state | song: song, tracks: tracks}

      {:error, reason} ->
        Logger.warning("Could not load tracks from Ableton: #{inspect(reason)}")
        %{state | song: song}
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

  defp query_string(transport, address, track_index, default) do
    case transport.query(address, [track_index]) do
      {:ok, {_addr, [s]}} when is_binary(s) -> s
      {:ok, {_addr, [_idx, s]}} when is_binary(s) -> s
      _ -> default
    end
  end

  defp query_float(transport, address, track_index, default) do
    case transport.query(address, [track_index]) do
      {:ok, {_addr, [v]}} when is_float(v) -> v
      {:ok, {_addr, [_idx, v]}} when is_float(v) -> v
      _ -> default
    end
  end

  defp query_int(transport, address, track_index, default) do
    case transport.query(address, [track_index]) do
      {:ok, {_addr, [v]}} when is_integer(v) -> v
      {:ok, {_addr, [_idx, v]}} when is_integer(v) -> v
      {:ok, {_addr, [true]}} -> 1
      {:ok, {_addr, [false]}} -> 0
      {:ok, {_addr, [_idx, true]}} -> 1
      {:ok, {_addr, [_idx, false]}} -> 0
      _ -> default
    end
  end

  defp query_song_float(transport, address, default) do
    case transport.query(address, []) do
      {:ok, {_addr, [v]}} when is_float(v) -> v
      _ -> default
    end
  end

  defp query_song_int(transport, address, default) do
    case transport.query(address, []) do
      {:ok, {_addr, [v]}} when is_integer(v) -> v
      {:ok, {_addr, [true]}} -> 1
      {:ok, {_addr, [false]}} -> 0
      _ -> default
    end
  end

  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool(1), do: true
  defp to_bool(0), do: false
  defp to_bool(v) when is_integer(v), do: v != 0
end
