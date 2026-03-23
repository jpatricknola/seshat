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

  # --- Client API ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def get, do: GenServer.call(__MODULE__, :get)
  def tracks, do: GenServer.call(__MODULE__, :tracks)

  @doc "Re-queries Ableton for full state and re-subscribes to all listeners."
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
    {:ok, %{tracks: []}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}
  def handle_call(:tracks, _from, state), do: {:reply, state.tracks, state}

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
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

        subscribe_listeners(tracks)
        Logger.info("Loaded #{length(tracks)} tracks: #{Enum.map_join(tracks, ", ", & &1.name)}")
        %{state | tracks: tracks}

      {:error, reason} ->
        Logger.warning("Could not load tracks from Ableton: #{inspect(reason)}")
        state
    end
  end

  defp subscribe_listeners(tracks) do
    alias Seshat.OSC.Transport

    for track <- tracks, prop <- @listened_properties do
      Transport.send_message("/live/track/start_listen/#{prop}", [track.index])
    end
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

  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool(1), do: true
  defp to_bool(0), do: false
  defp to_bool(v) when is_integer(v), do: v != 0
end
