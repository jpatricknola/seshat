defmodule Seshat.Session.State do
  @moduledoc """
  GenServer that mirrors Ableton session state.

  On startup: queries Ableton for initial track state, then subscribes to
  AbletonOSC listeners so any change — whether from this app, the Ableton UI,
  or a MIDI controller — is pushed here automatically via OSC on port 11001.

  That covers the *structure* of the session as well as its scalars. Adding,
  deleting, duplicating or reordering tracks and returns in Live's UI pushes the
  new name list (Seshat's `song_structure.py` extension), which is compared
  against the mirror and triggers a full re-read only when it differs; return and
  master faders push their own values. `/live/startup` — sent whenever AbletonOSC
  initialises, so on a Live restart, a set load, or the control surface being
  toggled — triggers a refresh too, which matters twice over: the old song's
  listeners are all dead by then, so without it the mirror would be stale
  *permanently*.

  The one thing this can't see is two identically named tracks swapping places.
  `refresh_sync/0` is the backstop for that and for a lost datagram; it is what
  `get_session_state`'s `refresh` parameter calls.
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

  # A full refresh against an Ableton that has stopped answering is a stack of
  # per-property guard timeouts, and no constant can bound it: the six song
  # properties alone reach @query_timeout each before the first track is read,
  # and the per-track cost grows with the session. So this is a ceiling on how
  # long the *caller* waits, not on the refresh — the GenServer finishes in its
  # own time. Reaching it means Ableton is unreachable rather than slow, which is
  # what `get_session_state` reports when `maybe_refresh` catches the exit.
  @refresh_sync_timeout 30_000

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

  @doc """
  Like `refresh/0`, but returns only once the mirror has been rebuilt.

  The backstop for the cases the listeners can't cover — a lost UDP push, or two
  identically named tracks swapping places. Callers that only want the refresh to
  happen eventually should use `refresh/0`; this one exists so
  `get_session_state` can serve state it knows is current.
  """
  def refresh_sync, do: GenServer.call(__MODULE__, :refresh_sync, @refresh_sync_timeout)

  @doc """
  True when the mirrored entries no longer match the names Live just pushed.

  Order-sensitive on purpose: a reorder in Live's UI changes what every index
  means, so it has to count as stale even though the same names are present. The
  one change it cannot see is two *identically named* tracks swapping places —
  accepted, since nothing downstream can tell those apart either.
  """
  def stale?(mirrored, live_names), do: Enum.map(mirrored, & &1.name) != live_names

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

    state = %{
      song: initial_song,
      tracks: [],
      return_tracks: [],
      master: nil,
      returns_readable?: false,
      unreconciled: %{}
    }

    {:ok, state, {:continue, :setup}}
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
  def handle_call(:refresh_sync, _from, state), do: {:reply, :ok, do_refresh(state)}

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  # AbletonOSC sends this every time the control surface initialises: Live
  # launching, a different set being loaded, or AbletonOSC toggled off and on.
  # Every listener registered against the previous song object is gone by then,
  # so this is the only thing standing between a set load and a mirror that is
  # both wrong and permanently deaf.
  @impl true
  def handle_info({:osc_message, "/live/startup", _args}, state) do
    Logger.info("AbletonOSC started — refreshing session state and re-subscribing")
    {:noreply, do_refresh(state)}
  end

  # Pushed by song_structure.py whenever tracks are added, deleted, duplicated or
  # reordered — including by Live's UI and by our own undo/redo, neither of which
  # any other listener sees. Carries names only: it is a change signal, and the
  # authoritative re-read is `do_refresh/1`. Re-subscribing inside that refresh
  # makes the extension push again immediately, which is why the comparison in
  # `reconcile/4` matters — the echo compares equal against the state it just
  # produced and stops there instead of looping.
  def handle_info({:osc_message, "/live/song/get/tracks", names}, state) do
    {:noreply, reconcile(state, :tracks, names, "Track list changed in Live")}
  end

  # Guarded by `returns_readable?`, unlike its track counterpart, because these
  # two addresses come from *different* vendored handlers: song_structure.py
  # pushes this list, and return_track.py is what `do_refresh/1` reads it back
  # with. If the second is broken while the first works — a half-applied manual
  # install is the realistic way there — every push disagrees with a mirror that
  # can never be reconciled, and refreshing on each one is an unbounded loop
  # flooding Live, since re-subscribing inside the refresh pushes again. Refusing
  # to act on a list we can't read back costs only staleness, and any later
  # refresh that does read returns clears the latch.
  def handle_info({:osc_message, "/live/song/get/return_tracks", names}, state) do
    cond do
      not stale?(state.return_tracks, names) ->
        {:noreply, reconciled(state, :return_tracks)}

      state.returns_readable? ->
        {:noreply, reconcile(state, :return_tracks, names, "Return track list changed in Live")}

      true ->
        Logger.warning(
          "Live reports #{length(names)} return track(s) but /live/return_track/get/count is " <>
            "not answering — leaving the mirror as it is. Run `mix abletonosc.install` and " <>
            "restart Ableton Live."
        )

        {:noreply, state}
    end
  end

  # Two shapes reach these: the listener's bare push, and the ok-envelope of a
  # query reply, which Transport broadcasts as well as returning to its caller.
  # Both carry a current value, so both are worth taking.
  def handle_info({:osc_message, "/live/return_track/get/name", [idx, "ok", name]}, state)
      when is_binary(name) do
    {:noreply, update_return(state, idx, :name, name)}
  end

  def handle_info({:osc_message, "/live/return_track/get/name", [idx, name]}, state)
      when is_binary(name) do
    {:noreply, update_return(state, idx, :name, name)}
  end

  def handle_info({:osc_message, "/live/return_track/get/volume", [idx, "ok", value]}, state)
      when is_float(value) do
    {:noreply, update_return(state, idx, :volume, value)}
  end

  def handle_info({:osc_message, "/live/return_track/get/volume", [idx, value]}, state)
      when is_float(value) do
    {:noreply, update_return(state, idx, :volume, value)}
  end

  # The master getter takes no index, so it has no envelope — push and query
  # reply are the same single-value shape.
  def handle_info({:osc_message, "/live/master/get/volume", [value]}, state)
      when is_float(value) do
    {:noreply, %{state | master: %{volume: value}}}
  end

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

  # A pushed name list that disagrees with the mirror triggers one authoritative
  # re-read. Normally that reconciles it and the echo from re-subscribing
  # compares equal, so the exchange ends there.
  #
  # It ends there even when it *doesn't* reconcile, which is the point of the
  # bookkeeping. A refresh can come back still disagreeing — replies running one
  # index behind after an abandoned timeout make `read_tracks/2`'s echo check
  # reject every name and fall back to "Track N" for all of them — and without a
  # brake that is an unbounded spin: refresh, re-subscribe, push, disagree,
  # refresh. Recording the exact list that failed stops the second attempt at it
  # while leaving any *different* list a fresh try, so a real change is never
  # ignored. `/live/startup` and `refresh_sync/0` lift the brake, because
  # `do_refresh/1` clears every record — but a refresh triggered from *here*
  # must keep the records it isn't about; see below.
  defp reconcile(state, key, names, change_message) do
    cond do
      not stale?(Map.fetch!(state, key), names) ->
        reconciled(state, key)

      Map.get(state.unreconciled, key) == names ->
        state

      true ->
        Logger.info("#{change_message} — refreshing session state")

        # Every record but this one survives the refresh. `do_refresh/1` clears
        # them all, which is what makes an explicitly requested refresh lift the
        # brake — but this refresh is about `key` alone, and dropping the other
        # key's record hands the two of them a way to lift each other's brake
        # forever: tracks refresh, which clears returns, whose echo then
        # refreshes, which clears tracks, whose echo then refreshes. Since every
        # refresh re-subscribes and every re-subscribe pushes again, that is the
        # unbounded spin this bookkeeping exists to stop, reached whenever both
        # lists are unreconcilable at once — one degraded refresh does exactly
        # that, since the same abandoned replies defeat both echo checks.
        others = Map.delete(state.unreconciled, key)

        refreshed =
          state
          |> do_refresh()
          |> Map.update!(:unreconciled, &Map.merge(&1, others))

        if stale?(Map.fetch!(refreshed, key), names) do
          Logger.warning(
            "#{change_message}, but re-reading Ableton did not reproduce it: Live reports " <>
              "#{inspect(names)} and the mirror holds " <>
              "#{inspect(Enum.map(Map.fetch!(refreshed, key), & &1.name))}. Leaving it as it " <>
              "is rather than refreshing on every push; pass refresh: true to force a retry."
          )

          %{refreshed | unreconciled: Map.put(refreshed.unreconciled, key, names)}
        else
          reconciled(refreshed, key)
        end
    end
  end

  defp reconciled(state, key) do
    %{state | unreconciled: Map.delete(state.unreconciled, key)}
  end

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

    returns = refresh_returns(Transport)

    # Outside the case above on purpose: neither of these depends on the track
    # count, and the song listeners are what make a *later* structure change
    # reach us at all. Subscribing them only on the branch where
    # /live/song/get/num_tracks answered would mean one dropped datagram at
    # startup leaves the mirror permanently deaf to the adds, deletes and
    # reorders these listeners exist to catch — the failure they were added to
    # end, reintroduced through the back door. `subscribe_listeners/1` stays
    # inside, since it genuinely needs the track list.
    subscribe_song_listeners()
    subscribe_return_listeners(returns.return_tracks)

    state
    |> Map.merge(returns)
    |> Map.put(:unreconciled, %{})
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

  defp refresh_returns(transport) do
    case probe(transport, "/live/return_track/get/count", [], @return_probe_timeout) do
      {:ok, [count]} when is_integer(count) ->
        return_tracks = read_return_tracks(transport, count)

        Logger.info(
          "Loaded #{length(return_tracks)} return track(s): " <>
            "#{Enum.map_join(return_tracks, ", ", & &1.name)}"
        )

        %{
          return_tracks: return_tracks,
          master: read_master(transport),
          returns_readable?: true
        }

      _no_answer ->
        Logger.warning(
          "Return tracks and master volume are unavailable: /live/return_track/get/count did " <>
            "not answer. Run `mix abletonosc.install` and restart Ableton Live."
        )

        %{return_tracks: [], master: nil, returns_readable?: false}
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

    # Seshat extensions (the fork's song_structure.py), kept out of
    # @listened_song_properties because their push carries a list of names rather
    # than a scalar — and because upstream serves neither address.
    Transport.send_message("/live/song/start_listen/tracks", [])
    Transport.send_message("/live/song/start_listen/return_tracks", [])
  end

  # Also Seshat extensions, so a Live where `mix abletonosc.install` was never run
  # drops these on the floor — the same silent no-op as the return queries above,
  # and the same fix. Written out rather than interpolated over a property list on
  # purpose: `vendored_addresses_test` greps `lib/` for `/live/return_track/` and
  # `/live/master/` literals and checks each one against what the Python actually
  # registers, and an interpolated address is invisible to that tripwire.
  defp subscribe_return_listeners(return_tracks) do
    alias Seshat.OSC.Transport

    for %{index: index} <- return_tracks do
      Transport.send_message("/live/return_track/start_listen/name", [index])
      Transport.send_message("/live/return_track/start_listen/volume", [index])
    end

    Transport.send_message("/live/master/start_listen/volume", [])
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

  # An index absent from the mirror matches nothing here, the same way
  # `update_track/4` handles a deleted track. Nothing on this side clears a
  # listener — `Session.State` never sends `stop_listen`, and a refresh only
  # re-subscribes the indices that currently exist — so the guarantee that a
  # push arriving under index N really describes return N is enforced in the
  # fork's `AbletonOSCHandler._stop_listen`, which unbinds the object a callback
  # was registered on rather than whatever the index now resolves to, before an
  # index is re-bound. Without that a deleted return leaves its neighbour
  # listening under two indices at once, and this function would faithfully
  # write one return's name onto another.
  defp update_return(state, index, key, value) do
    Logger.debug("Return #{index} #{key} → #{inspect(value)}")

    return_tracks =
      Enum.map(state.return_tracks, fn return ->
        if return.index == index, do: Map.put(return, key, value), else: return
      end)

    %{state | return_tracks: return_tracks}
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
