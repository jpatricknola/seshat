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

  ## Refreshes are coalesced, not immediate

  A full refresh is expensive — it serially queries the song, every track, every
  return and the master, then re-subscribes every listener, which measured
  1.0–1.8s against a ten-track set — and it runs *inside* this GenServer, so
  reads queue behind it. A model turn can fire twenty tools; twenty rebuilds
  queued back to back put an ordinary five-second read past its own timeout and
  make a healthy Ableton look dead.

  So the asynchronous requests — `refresh/0` and the structure pushes — do not
  rebuild. They move a **trailing-edge** timer to one second after the latest
  request; when it fires, exactly one rebuild runs. Anything arriving
  while that rebuild blocks the GenServer is still sitting in the mailbox and,
  once handled, schedules the *next* trailing rebuild, so the final mutation is
  never the one that gets dropped. The guarantee is a bounded backlog: at most
  one running rebuild plus one scheduled one, at any request rate.

  A leading-edge throttle would not do: one rebuild can outlast the interval, so
  work still accumulates. The token carried on the timer message is the other
  half — `Process.cancel_timer/1` can't recall a message already queued in the
  mailbox, so a `{:refresh, token}` whose token is no longer the current one is
  ignored rather than trusted.

  The three immediate paths stay immediate: initial setup, `/live/startup` (the
  old song's listeners are dead, so this cannot wait), and `refresh_sync/0`,
  which cancels the pending timer and consumes its pending work in the rebuild
  the caller is waiting on. Ordinary reads never force the timer; they answer
  from the push-updated mirror, which costs nothing on scalars and, on
  *structure*, the debounce window past the *last* request — a trailing-edge
  debounce, so a sustained burst restarts the timer on every request and
  stretches that window to cover the whole burst, not just one second.

  ## Unknown is `nil`, never a guess

  One rule holds for every mirrored value here: **a read that Ableton didn't
  answer yields `nil` — unknown, never a plausible default.** A fabricated
  120 BPM or 0.85 fader reads as fact to the model, which then writes bar
  lengths against a made-up time signature and makes relative mixer moves
  against a fictional level. `nil` costs a "we don't know" in the reply and
  nothing else, and it self-heals: every refresh re-subscribes all listeners,
  and the fork's `AbletonOSCHandler._start_listen` pushes the current value on
  subscription, so a field nil'd by one lost reply is repopulated milliseconds
  later whenever Ableton is actually alive.

  That rule reaches the track *list* as well as the fields in it. A rebuild that
  races a structural change gets no *value* back for an index that has just
  gone — `track.py` raises `IndexError` inside the callback, and the fork
  answers with a `/live/error` naming that request rather than with the property,
  which `Transport` correlates into `{:error, {:live_error, _}}` — so
  `read_tracks/2` stops at the first unreadable **name** and reports
  `{:degraded, index}` rather than handing back a list with holes in it. A
  degraded read nils the whole list: a half-read list still *names* tracks, and
  naming a track Live no longer has is the same fabrication as a guessed tempo,
  only harder to spot.

  The recovery route for a nil'd list is deliberately not the scalar pushes.
  `update_track/4`'s `%{tracks: nil}` clause drops them, because a scalar push
  carries an index whose meaning is exactly what the failed read could not
  establish. What heals it is the *structure* push — `song_structure.py` pushes
  the authoritative name list the moment `do_refresh/1` re-subscribes, and
  `stale?(nil, names)` is true against any list — together with the single retry
  `finalize_reconciliations/3` grants a rebuild that established nothing. Those
  two are load-bearing rather than tidy-up.
  """

  use GenServer

  require Logger

  @pubsub Seshat.PubSub
  @topic "osc:in"
  @listened_properties ~w(panning volume mute solo name)
  @listened_song_properties ~w(
    tempo signature_numerator signature_denominator is_playing root_note scale_name
    groove_amount swing_amount
  )

  # The default query timeout, matching Transport's own.
  @query_timeout 5_000

  # A full refresh against an Ableton that has stopped answering is a stack of
  # per-property guard timeouts, and no constant can bound it: the eight song
  # properties alone reach @query_timeout each before the first track is read,
  # and the per-track cost grows with the session. So this is a ceiling on how
  # long the *caller* waits, not on the refresh — the GenServer finishes in its
  # own time. Reaching it means Ableton is unreachable rather than slow, which is
  # what `get_session_state` reports when `maybe_refresh` catches the exit.
  @refresh_sync_timeout 30_000

  # How long the trailing-edge timer waits after the *latest* asynchronous
  # refresh request before rebuilding. A module constant, not application
  # configuration: no product decision hangs on the number, and the one reason
  # anyone would want it configurable — making `do_refresh/1` unit-testable by
  # driving the delay to zero — is a mirage. A zero delay reaches the same live
  # `Transport.query/3` calls, just sooner. The scheduler's state transitions are
  # unit-tested by calling the callbacks directly; the real coalesced rebuild is
  # a /smoke-test check.
  @refresh_debounce_ms 1_000

  # `/live/return_track/*` and `/live/master/*` come from Seshat's return_track.py
  # extension, not upstream AbletonOSC, so a Live where `mix abletonosc.install`
  # was never run answers them with silence rather than an error. Short timeout:
  # a missing extension must not stall every refresh for five seconds.
  @return_probe_timeout 2_000

  # --- Client API ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The mirrored track list — `%{index, name, volume, pan, mute, solo}` per track,
  in Live's order.

  `nil` when the last read couldn't establish how many tracks the set has:
  unknown, never "no tracks". `[]` is the verified-empty set. An individual
  field is `nil` on the same rule — unknown, never a guess.
  """
  def tracks, do: GenServer.call(__MODULE__, :tracks)

  @doc """
  The mirrored song scalars — `%{tempo, time_sig_numerator, time_sig_denominator,
  is_playing, root_note, scale_name, groove_amount, swing_amount}`.

  Every field is `nil` when the last read couldn't get it — unknown, never a
  guess. Callers must handle `nil` rather than assume 120 BPM or 4/4.
  """
  def song, do: GenServer.call(__MODULE__, :song)

  @doc """
  Return tracks, in send order — `%{index, name, volume, pan, mute, solo}`, where
  return 0 is send A on every regular track. Empty when the extension isn't
  answering, and a single field is `nil` when that one query went unanswered —
  never a guessed number.
  """
  def return_tracks, do: GenServer.call(__MODULE__, :return_tracks)

  @doc """
  Master track mixer state as `%{volume, pan, cue_volume}`, or `nil` when
  `/live/master/get/volume` never answered — i.e. Seshat's AbletonOSC extension
  isn't installed. `nil` is "unknown", never "zero", and that holds per field
  too: a lost `panning` reply leaves `pan: nil` rather than a centred guess.

  The master has no mute, solo or arm — reading one raises inside Live rather
  than returning something falsy — so there is nothing here to mirror.
  """
  def master, do: GenServer.call(__MODULE__, :master)

  @doc """
  Requests a full re-query of Ableton and a re-subscribe of every listener,
  *eventually*.

  Not a rebuild on the spot: this schedules one, one second after the last such
  request, so a burst of tool calls collapses into a single rebuild instead of
  queuing one apiece behind reads that then time out. The last request in a burst
  is never the one discarded — see the module doc. Callers that must read state
  they know is current want `refresh_sync/0` instead.
  """
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @doc """
  All four mirrored sections — `%{song:, tracks:, return_tracks:, master:}` — as
  they stood in one GenServer turn, plus `refresh_pending?`.

  What the four narrower reads can't offer: with refreshes coalesced, a rebuild
  can land between two of them and produce a reply that pairs the song from
  before it with the tracks from after. One call, one turn, one coherent answer,
  and one timeout window rather than four.

  `refresh_pending?` is true when a rebuild is scheduled but hasn't run, which is
  to say the structure in this snapshot is *known* to be behind Live: reads
  neither force the timer nor cancel it. It is reported rather than waited on so
  `get_session_state` can label its own uncertainty instead of asserting a layout
  it has reason to doubt. `refresh_sync/0` cancels the timer before rebuilding,
  so a refreshed read never sees it true.
  """
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  Like `refresh/0`, but returns only once the mirror has been rebuilt.

  The backstop for the cases the listeners can't cover — a lost UDP push, or two
  identically named tracks swapping places. Callers that only want the refresh to
  happen eventually should use `refresh/0`; this one exists so
  `get_session_state` can serve state it knows is current.

  Immediate and un-debounced by definition, and it *absorbs* any pending
  trailing refresh rather than racing it: the timer is cancelled, its pending
  structure work is reconciled against this rebuild, and no duplicate refresh
  fires a second later.
  """
  def refresh_sync, do: GenServer.call(__MODULE__, :refresh_sync, @refresh_sync_timeout)

  @doc """
  True when the mirrored entries no longer match the names Live just pushed.

  Order-sensitive on purpose: a reorder in Live's UI changes what every index
  means, so it has to count as stale even though the same names are present. The
  one change it cannot see is two *identically named* tracks swapping places —
  accepted, since nothing downstream can tell those apart either.

  A `nil` mirror — the list couldn't be read at all — is stale against *any*
  pushed list, including the empty one. That is what heals a failed refresh: the
  next `song_structure.py` push disagrees by definition and triggers the
  authoritative re-read.
  """
  def stale?(nil, _live_names), do: true
  def stale?(mirrored, live_names), do: Enum.map(mirrored, & &1.name) != live_names

  @doc """
  The deferred half of `reconcile/4`: the comparison that used to happen inline
  right after `do_refresh/1`, run once the scheduled rebuild has finished.

  Takes the rebuilt state, the `pending_reconciliations` map captured *before*
  the rebuild cleared it, and the pre-refresh context
  `%{unreconciled: previous_unreconciled, explicit?: boolean}`. Returns the state
  with each pending key's brake recorded, cleared, or converted into one retry.

  Public and OSC-free on purpose. Every decision below is a state transition with
  no wire access, and each of them is the difference between a mirror that heals
  and one that holds a knowingly-wrong answer forever — none of which is
  reachable from `mix test` if the only entry point is a private function behind
  `Transport.query/3`. It must stay that way: no query belongs in here.

  ## Carry-over

  For a structure-only rebuild, every record but the ones this refresh is about
  survives it. `do_refresh/1` clears them all, which is what makes an explicitly
  requested refresh lift the brake — but dropping the *other* key's record here
  hands the two of them a way to lift each other's brake forever: tracks refresh,
  which clears returns, whose echo then refreshes, which clears tracks, whose
  echo then refreshes. Since every refresh re-subscribes and every re-subscribe
  pushes again, that is an unbounded spin, reached whenever both lists are
  unreconcilable at once — one degraded refresh does exactly that, since the same
  abandoned replies defeat both echo checks.

  An explicit request is the opposite case and takes precedence even when it
  shares a timer with pending structure records: it is a forced retry of all of
  them, so nothing old is carried over and only what this rebuild still can't
  reproduce gets re-recorded.

  ## Failed is not disagreed

  "Live says X and the mirror says Y" and "the rebuild established nothing" used
  to be treated identically, and only the first is a reason never to try again:

    * **Reconciled** — the rebuild reproduced the pushed list. That key's brake
      clears.
    * **Failed** — the mirror value for that key is `nil`, so this rebuild has
      not disagreed with anything; it read nothing. The pending record survives
      marked `retried?: true` and one more rebuild is scheduled. No brake. Only
      `:tracks` has a `nil` sentinel to fail into — `read_return_tracks/2` always
      returns a list, so a return-side mismatch always takes the "Disagreed"
      branch below instead.
    * **Failed again** — `retried?` was already set. Now the brake goes on, with
      the same warning as a disagreement. Two rebuilds per pushed list is the
      bound, and that is not a spin.
    * **Disagreed** — the mirror holds a real list whose names differ. Brake
      immediately, no retry. A rebuild that read the session successfully and got
      a different answer is information, not a failure, and retrying it is what
      floods Live.

  The retry rides `schedule_refresh/1` rather than recursing into `do_refresh/1`:
  a second immediate rebuild would be racing the same structural change that
  broke the first one, and it lands one debounce window later instead.
  `refresh_requested?` stays false, so the retry is a structure-only rebuild and
  the carry-over above keeps protecting the other key.
  """
  @spec finalize_reconciliations(map(), map(), %{unreconciled: map(), explicit?: boolean()}) ::
          map()
  def finalize_reconciliations(state, pending, %{unreconciled: previous, explicit?: explicit?}) do
    # Preserved only for a structure-only rebuild, and only for the keys it isn't
    # about; an explicit request deliberately keeps nothing.
    carried_over = if explicit?, do: %{}, else: Map.drop(previous, Map.keys(pending))

    state = Map.update!(state, :unreconciled, &Map.merge(&1, carried_over))

    Enum.reduce(pending, state, fn {key, record}, acc ->
      %{names: names, message: change_message} = record
      mirrored = Map.fetch!(acc, key)

      cond do
        not stale?(mirrored, names) ->
          reconciled(acc, key)

        is_nil(mirrored) and not Map.get(record, :retried?, false) ->
          Logger.info(
            "#{change_message}, but the rebuild could not read the #{list_label(key)} — " <>
              "retrying once."
          )

          acc
          |> Map.update!(
            :pending_reconciliations,
            &Map.put(&1, key, Map.put(record, :retried?, true))
          )
          |> schedule_refresh()

        true ->
          Logger.warning(
            "#{change_message}, but re-reading Ableton did not reproduce it: Live reports " <>
              "#{inspect(names)} and the mirror holds " <>
              "#{mirrored_names(mirrored)}. Leaving it as it " <>
              "is rather than refreshing on every push; pass refresh: true to force a retry."
          )

          %{acc | unreconciled: Map.put(acc.unreconciled, key, names)}
      end
    end)
  end

  defp list_label(:tracks), do: "track list"
  defp list_label(:return_tracks), do: "return track list"

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @topic)

    # All-`nil`: nothing has been read yet, so nothing is known. No caller can
    # observe this map (`handle_continue(:setup, ...)` refreshes before the first
    # `handle_call` runs), but a plausible constant sitting here is an invitation
    # to reuse it as a fallback somewhere that *is* observable. `tracks` below is
    # `nil` for the same reason: `[]` asserts a session with no tracks in it,
    # which nothing has checked yet.
    initial_song = %{
      tempo: nil,
      time_sig_numerator: nil,
      time_sig_denominator: nil,
      is_playing: nil,
      root_note: nil,
      scale_name: nil,
      groove_amount: nil,
      swing_amount: nil
    }

    state = %{
      song: initial_song,
      tracks: nil,
      return_tracks: [],
      master: nil,
      returns_readable?: false,
      unreconciled: %{},

      # The trailing-edge scheduler. `refresh_timer` is what gets cancelled;
      # `refresh_token` is what makes a cancellation that arrived too late
      # harmless, since a due message can already be in the mailbox. They are
      # separate fields because cancelling has to clear the token too — a
      # `nil` token matches no message.
      refresh_timer: nil,
      refresh_token: nil,

      # True when an explicit `refresh/0` is riding on the current timer, as
      # opposed to a timer scheduled only to reconcile a structure push. The
      # distinction decides whether the rebuild lifts *every* `unreconciled`
      # brake (explicit: a forced retry of all of them) or only the ones it is
      # about.
      refresh_requested?: false,

      # `%{tracks: %{names: [...], message: "..."}, ...}` — the latest name list
      # Live pushed for each structure key, held until the scheduled rebuild can
      # be compared against it. This is `reconcile/4`'s inline check, deferred:
      # the comparison still happens, just after the refresh the timer runs
      # rather than after an inline one.
      pending_reconciliations: %{}
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    {:noreply, do_refresh(state)}
  end

  # Reads answer from the mirror as it stands, even with a rebuild scheduled:
  # they neither force the timer nor cancel it. The cost is structural
  # staleness — and on a sustained burst that is not one debounce window but
  # the whole burst (every request restarts the timer), plus the window past
  # the last request, plus the rebuild itself. That is the trade the coalescing
  # buys; `refresh_sync/0` is the way out of it.
  @impl true
  def handle_call(:tracks, _from, state), do: {:reply, state.tracks, state}
  def handle_call(:song, _from, state), do: {:reply, state.song, state}
  def handle_call(:return_tracks, _from, state), do: {:reply, state.return_tracks, state}
  def handle_call(:master, _from, state), do: {:reply, state.master, state}

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      song: state.song,
      tracks: state.tracks,
      return_tracks: state.return_tracks,
      master: state.master,

      # Only on the snapshot, never on the four narrower reads: this is a fact
      # about the whole reply `get_session_state` is about to compose, and the
      # narrower reads have no reply to qualify.
      refresh_pending?: state.refresh_timer != nil
    }

    {:reply, snapshot, state}
  end

  # Immediate, and it consumes whatever the pending timer was going to do: an
  # explicit refresh is a forced retry of every brake, so it starts from an empty
  # `unreconciled` (via `do_refresh/1`) and re-records only what this rebuild
  # still can't reproduce.
  def handle_call(:refresh_sync, _from, state) do
    {:reply, :ok, run_refresh(state, explicit?: true)}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, state |> Map.put(:refresh_requested?, true) |> schedule_refresh()}
  end

  # The trailing edge. Only the token minted by the *latest* `schedule_refresh/1`
  # does any work: `Process.cancel_timer/1` cannot recall a message that has
  # already been queued, so a replaced timer's message still arrives and must be
  # inert. Rebuilding on it would be exactly the duplicate refresh the debounce
  # exists to remove.
  @impl true
  def handle_info({:refresh, token}, %{refresh_token: token} = state) when not is_nil(token) do
    {:noreply, run_refresh(state, explicit?: false)}
  end

  def handle_info({:refresh, _stale_token}, state), do: {:noreply, state}

  # AbletonOSC sends this every time the control surface initialises: Live
  # launching, a different set being loaded, or AbletonOSC toggled off and on.
  # Every listener registered against the previous song object is gone by then,
  # so this is the only thing standing between a set load and a mirror that is
  # both wrong and permanently deaf. Never debounced, and it *discards* rather
  # than consumes any pending structure work: those name lists describe the
  # previous song, so reconciling this song's rebuild against them would record a
  # brake against a list that is no longer meaningful.
  def handle_info({:osc_message, "/live/startup", _args}, state) do
    Logger.info("AbletonOSC started — refreshing session state and re-subscribing")
    {:noreply, state |> clear_refresh_schedule() |> do_refresh()}
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
        {:noreply, settled(state, :return_tracks)}

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

  def handle_info({:osc_message, "/live/return_track/get/panning", [idx, "ok", value]}, state)
      when is_float(value) do
    {:noreply, update_return(state, idx, :pan, value)}
  end

  def handle_info({:osc_message, "/live/return_track/get/panning", [idx, value]}, state)
      when is_float(value) do
    {:noreply, update_return(state, idx, :pan, value)}
  end

  # Normalized at the boundary: the getter replies 0/1 and Live's own listener
  # pushes a bool, so the mirror would otherwise hold two spellings of the same
  # fact and every reader would have to know both.
  def handle_info({:osc_message, "/live/return_track/get/mute", [idx, "ok", value]}, state)
      when is_integer(value) or is_boolean(value) do
    {:noreply, update_return(state, idx, :mute, to_bool(value))}
  end

  def handle_info({:osc_message, "/live/return_track/get/mute", [idx, value]}, state)
      when is_integer(value) or is_boolean(value) do
    {:noreply, update_return(state, idx, :mute, to_bool(value))}
  end

  def handle_info({:osc_message, "/live/return_track/get/solo", [idx, "ok", value]}, state)
      when is_integer(value) or is_boolean(value) do
    {:noreply, update_return(state, idx, :solo, to_bool(value))}
  end

  def handle_info({:osc_message, "/live/return_track/get/solo", [idx, value]}, state)
      when is_integer(value) or is_boolean(value) do
    {:noreply, update_return(state, idx, :solo, to_bool(value))}
  end

  # The master getters take no index, so they have no envelope — push and query
  # reply are the same single-value shape. Each writes one field and leaves its
  # siblings alone; replacing the whole map would blank pan and cue volume on
  # every volume push.
  def handle_info({:osc_message, "/live/master/get/volume", [value]}, state)
      when is_float(value) do
    {:noreply, update_master(state, :volume, value)}
  end

  def handle_info({:osc_message, "/live/master/get/panning", [value]}, state)
      when is_float(value) do
    {:noreply, update_master(state, :pan, value)}
  end

  def handle_info({:osc_message, "/live/master/get/cue_volume", [value]}, state)
      when is_float(value) do
    {:noreply, update_master(state, :cue_volume, value)}
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

  def handle_info({:osc_message, "/live/song/get/groove_amount", [value]}, state) do
    {:noreply, update_song(state, :groove_amount, value)}
  end

  def handle_info({:osc_message, "/live/song/get/swing_amount", [value]}, state) do
    {:noreply, update_song(state, :swing_amount, value)}
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

  # A pushed name list that disagrees with the mirror schedules one authoritative
  # re-read. Normally that reconciles it and the echo from re-subscribing
  # compares equal, so the exchange ends there.
  #
  # It ends there even when it *doesn't* reconcile, which is the point of the
  # bookkeeping. A refresh can come back still disagreeing — replies running one
  # index behind after an abandoned timeout make `read_tracks/2`'s echo check
  # reject every name and yield `nil` for all of them, and a `nil` never equals a
  # pushed name. Transport's queue narrows that cascade (it needs a straggler on
  # the address the *next* query happens to use, not mere overlap) without
  # removing it, so the brake stays. Without one it is an unbounded spin: refresh,
  # re-subscribe, push, disagree,
  # refresh. Recording the exact list that failed stops the second attempt at it
  # while leaving any *different* list a fresh try, so a real change is never
  # ignored. `/live/startup`, `refresh_sync/0` and an explicit `refresh/0` lift
  # the brake, because `do_refresh/1` clears every record — but a refresh
  # scheduled from *here* alone must keep the records it isn't about; see
  # `finalize_reconciliations/3`.
  #
  # What changed with coalescing is only *when* the comparison happens. The
  # re-read no longer runs inline: this records the pushed list and moves the
  # trailing timer, and `finalize_reconciliations/3` does the comparing once the
  # rebuild that timer schedules has finished.
  defp reconcile(state, key, names, change_message) do
    cond do
      not stale?(Map.fetch!(state, key), names) ->
        settled(state, key)

      Map.get(state.unreconciled, key) == names ->
        state

      # The echo-loop guard. It is reachable any time a pending record already
      # holds this exact list — not only when the mirror is degraded — but the
      # degraded-rebuild state Part 2 creates is why it matters: a rebuild that
      # came back degraded leaves `tracks: nil`, so `stale?/2` is true against
      # *every* list — including the very list the re-subscription echo pushes
      # straight back. Falling through to the general case would replace the
      # pending record on each echo, discarding the `retried?` marker that
      # bounds the retry and pushing the trailing edge out again, which is an
      # unbounded loop. Outside that state the same guard just declines to
      # extend the trailing edge for a duplicate push, which is harmless. Same
      # names as the record already holds: keep the record exactly as it is,
      # and touch neither the marker nor the timer. A list that genuinely
      # differs still falls through and gets a fresh record, so a real change
      # is never ignored.
      match?(%{names: ^names}, Map.get(state.pending_reconciliations, key)) ->
        state

      true ->
        Logger.info("#{change_message} — scheduling a session refresh")

        # Only the *latest* list for this key is kept: an older one describes a
        # session state Live has already moved past, and comparing the rebuild
        # against it would record a brake against a list nobody is claiming any
        # more. The other key's pending record, if there is one, rides the same
        # timer.
        state
        |> Map.update!(
          :pending_reconciliations,
          &Map.put(&1, key, %{names: names, message: change_message})
        )
        |> schedule_refresh()
    end
  end

  # The one refresh entry point that isn't a raw `do_refresh/1`: it takes over the
  # pending timer's work rather than running alongside it. Used by the trailing
  # timer and by `refresh_sync/0`, which differ only in whether the explicit flag
  # is forced on.
  #
  # Everything the rebuild is about to destroy is captured *first* and handed to
  # `finalize_reconciliations/3` as raw context: `clear_refresh_schedule/1` empties
  # the pending records and `do_refresh/1` empties `unreconciled`. The carry-over
  # decision itself deliberately lives in the public finalizer rather than here —
  # passing an already-computed `carried_over` map would leave the explicit-vs-
  # structure choice unreachable from `mix test`, which is most of what this
  # bookkeeping is.
  defp run_refresh(state, explicit?: forced?) do
    context = %{
      unreconciled: state.unreconciled,
      explicit?: forced? or state.refresh_requested?
    }

    pending = state.pending_reconciliations

    state
    |> clear_refresh_schedule()
    |> do_refresh()
    |> finalize_reconciliations(pending, context)
  end

  # Move the trailing edge: cancel whatever was scheduled and schedule one
  # refresh for `@refresh_debounce_ms` from now, under a fresh token. The token
  # is what makes this safe — `Process.cancel_timer/1` can't unsend a message
  # already sitting in the mailbox, so the old timer's message is discarded on
  # arrival by `handle_info/2` instead.
  defp schedule_refresh(state) do
    state = cancel_refresh_timer(state)
    token = make_ref()

    %{
      state
      | refresh_timer: Process.send_after(self(), {:refresh, token}, @refresh_debounce_ms),
        refresh_token: token
    }
  end

  defp cancel_refresh_timer(%{refresh_timer: nil} = state), do: %{state | refresh_token: nil}

  defp cancel_refresh_timer(state) do
    Process.cancel_timer(state.refresh_timer)
    %{state | refresh_timer: nil, refresh_token: nil}
  end

  # Everything the scheduler was holding, dropped: used by the paths that refresh
  # right now, so no cancelled timer can produce a second rebuild behind them.
  defp clear_refresh_schedule(state) do
    state
    |> cancel_refresh_timer()
    |> Map.put(:refresh_requested?, false)
    |> Map.put(:pending_reconciliations, %{})
  end

  defp mirrored_names(nil), do: "unknown"
  defp mirrored_names(entries), do: inspect(Enum.map(entries, & &1.name))

  defp reconciled(state, key) do
    %{state | unreconciled: Map.delete(state.unreconciled, key)}
  end

  # A pushed list that agrees with the mirror answers the question the pending
  # refresh was scheduled to answer — pushes updated the mirror in the meantime,
  # or the change was undone — so that record goes, and with it the timer if
  # nothing else is riding on it. An explicit `refresh/0` on the same timer keeps
  # it: that caller asked for a rebuild, not for a structure comparison.
  defp settled(state, key) do
    state
    |> reconciled(key)
    |> Map.update!(:pending_reconciliations, &Map.delete(&1, key))
    |> cancel_idle_timer()
  end

  defp cancel_idle_timer(%{refresh_requested?: false, pending_reconciliations: pending} = state)
       when map_size(pending) == 0 do
    cancel_refresh_timer(state)
  end

  defp cancel_idle_timer(state), do: state

  defp do_refresh(state) do
    alias Seshat.OSC.Transport

    song = %{
      tempo: query_song_float(Transport, "/live/song/get/tempo"),
      time_sig_numerator: query_song_int(Transport, "/live/song/get/signature_numerator"),
      time_sig_denominator: query_song_int(Transport, "/live/song/get/signature_denominator"),
      is_playing: query_song_int(Transport, "/live/song/get/is_playing") |> to_bool(),
      root_note: query_song_int(Transport, "/live/song/get/root_note"),
      scale_name: query_song_string(Transport, "/live/song/get/scale_name"),
      groove_amount: query_song_float(Transport, "/live/song/get/groove_amount"),
      # `swing_amount` is fork-only (song.py's properties_rw), so an install
      # predating that pin never answers and this times out to `nil` — rendered
      # as a stated unknown, which is the honest signal to re-run
      # `mix abletonosc.install`. Deliberately the full @query_timeout and *not*
      # @return_probe_timeout: the extra 5s exists only in the
      # not-yet-reinstalled state, whereas a 2s probe risks a false "swing
      # unknown" on a healthy install.
      swing_amount: query_song_float(Transport, "/live/song/get/swing_amount")
    }

    Logger.info(
      "Song: #{unknown_if_nil(song.tempo)} BPM, " <>
        "#{unknown_if_nil(song.time_sig_numerator)}/" <>
        "#{unknown_if_nil(song.time_sig_denominator)}, " <>
        "key #{root_note_label(song.root_note)} #{unknown_if_nil(song.scale_name)}"
    )

    state =
      case probe(Transport, "/live/song/get/num_tracks", [], @query_timeout) do
        {:ok, [count]} when is_integer(count) ->
          read = read_tracks(Transport, count)

          # Subscribed from the *count*, not from the rows that were read, and
          # unconditionally: a degraded read must not also go deaf. Subscribing
          # an index that no longer exists is harmless — the same silent
          # `IndexError` path, and no listener is created — whereas skipping the
          # subscription is how a degraded refresh would stay degraded, since the
          # structure push that heals it is itself a listener.
          subscribe_listeners(if count < 1, do: [], else: 0..(count - 1))

          case read do
            {:ok, tracks} ->
              Logger.info(
                "Loaded #{length(tracks)} tracks: " <>
                  "#{Enum.map_join(tracks, ", ", &unknown_if_nil(&1.name))}"
              )

              %{state | song: song, tracks: tracks}

            # The same rule as the failed-`num_tracks` branch below, applied to
            # the case it never reached: a read that stopped partway established
            # the *existence* of no track after `stopped_index` and the identity
            # of none at it. Keeping what it managed to read would serve tracks
            # that may already be gone — the measured 2026-08-01 failure, where a
            # deleted "Bass" was reported as present beside a track whose every
            # field was unknown, with nothing in the reply distinguishing the two.
            {:degraded, stopped_index} ->
              Logger.warning(
                "Ableton reported #{count} track(s) but the read stopped at index " <>
                  "#{stopped_index}: no name came back for it, so the whole track list is " <>
                  "unknown rather than partly guessed. A structure push or the single retry " <>
                  "in finalize_reconciliations/3 rebuilds it."
              )

              %{state | song: song, tracks: nil}
          end

        # Anything else — a timeout, a deaf transport, a reply in a shape we
        # don't recognise — leaves the session unmirrored rather than crashing
        # a GenServer whose supervisor would only restart it into the same wall.
        #
        # `tracks: nil` rather than the previous list: a refresh runs precisely
        # when the mirror is suspect (`/live/startup` means a *different song*,
        # `refresh: true` means it looked wrong), so keeping the old list serves
        # the previous set's tracks as this set's. Unknown, not stale-but-plausible.
        other ->
          Logger.warning("Could not load tracks from Ableton: #{inspect(other)}")
          %{state | song: song, tracks: nil}
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

  @doc """
  Read `count` tracks out of Ableton, one index at a time.

  `{:ok, tracks}` or `{:degraded, stopped_index}` — never a list with holes in
  it. `count < 1` is `{:ok, []}`: a verified-empty set, not degradation.

  The **name** is the marker, and only the name, for two reasons:

    * It is the identity field. `stale?/2` compares names and nothing else, so
      a row with `name: nil` can never reconcile against a pushed list — it is
      guaranteed to be recorded as a brake, which is exactly the trap the
      measured 2026-08-01 run fell into. A `nil` volume has no such
      consequence, so an unanswered volume still leaves that one field unknown
      and keeps the row.
    * `query_string/4`'s echo check rejects a reply whose echoed index isn't
      the one asked for, so a straggler running one index behind yields `nil`
      here too. The marker therefore catches the abandoned-reply cascade as
      well as the index that no longer exists — the same failure seen from two
      ends.

  Per-index reads over the bulk `/live/song/get/track_names` is a decision,
  not an oversight (docs/evaluating/abletonosc-integration-review.md,
  2026-08-03, flagged the bulk address as unused). One query instead of N is tempting at the measured ~100ms per
  serialized round trip, but the bulk reply is a bare name list — it echoes neither an
  index nor the requested range, so on a transport that correlates replies by
  address alone a straggler from an earlier query is indistinguishable by
  content, and one accepted straggler mislabels every track at once instead of
  yielding a single `nil`. That would defeat the echo check both bullets above
  lean on, during exactly the structural churn a rebuild runs in. If the fork
  ever grows the bulk mirror-snapshot endpoint the review recommends (§3.2,
  indices echoed in the reply), this loop is what it replaces.

  Aborting the whole read rather than skipping the one index is deliberate:
  `do_refresh/1` is about to discard the list anyway, so every query after the
  first unanswered name is spent on a result that gets thrown away. A vanished
  index is refused rather than answered — `track.py`'s `create_track_callback`
  and its neighbours index `song.tracks` with no bounds check, and the fork
  turns the resulting `IndexError` into a `/live/error` naming this exact
  request, which `Transport` correlates and returns as
  `{:error, {:live_error, _}}` — so `query_string/4` yields `nil` in
  milliseconds. Before that correlation existed the same index cost a full
  `@query_timeout` of silence each, which is what made stopping at the first one
  worth this much prose.

  `transport` is the module to query through — `Seshat.OSC.Transport` in
  production. Public, and parameterised, for the same reason
  `finalize_reconciliations/3` is: the degrade decision is the part of a refresh
  worth pinning in a unit test, and everything around it needs a live Ableton.
  """
  @spec read_tracks(module(), integer()) :: {:ok, [map()]} | {:degraded, non_neg_integer()}
  def read_tracks(_transport, count) when count < 1, do: {:ok, []}

  def read_tracks(transport, count) do
    0..(count - 1)
    |> Enum.reduce_while([], fn i, acc ->
      case query_string(transport, "/live/track/get/name", i) do
        nil ->
          {:halt, {:degraded, i}}

        name ->
          track = %{
            index: i,
            name: name,
            volume: query_float(transport, "/live/track/get/volume", i),
            pan: query_float(transport, "/live/track/get/panning", i),
            mute: query_int(transport, "/live/track/get/mute", i) |> to_bool(),
            solo: query_int(transport, "/live/track/get/solo", i) |> to_bool()
          }

          {:cont, [track | acc]}
      end
    end)
    |> case do
      {:degraded, index} -> {:degraded, index}
      tracks -> {:ok, Enum.reverse(tracks)}
    end
  end

  defp refresh_returns(transport) do
    case probe(transport, "/live/return_track/get/count", [], @return_probe_timeout) do
      {:ok, [count]} when is_integer(count) ->
        return_tracks = read_return_tracks(transport, count)

        Logger.info(
          "Loaded #{length(return_tracks)} return track(s): " <>
            "#{Enum.map_join(return_tracks, ", ", &unknown_if_nil(&1.name))}"
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
        name: query_string(transport, "/live/return_track/get/name", i, @return_probe_timeout),
        volume: query_float(transport, "/live/return_track/get/volume", i, @return_probe_timeout),
        pan: query_float(transport, "/live/return_track/get/panning", i, @return_probe_timeout),
        mute:
          query_int(transport, "/live/return_track/get/mute", i, @return_probe_timeout)
          |> to_bool(),
        solo:
          query_int(transport, "/live/return_track/get/solo", i, @return_probe_timeout)
          |> to_bool()
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
      {:ok, [volume]} when is_float(volume) ->
        %{
          volume: volume,
          pan: master_float(transport, "/live/master/get/panning"),
          cue_volume: master_float(transport, "/live/master/get/cue_volume")
        }

      _no_answer ->
        nil
    end
  end

  # Only the volume read decides whether the master is readable at all (above);
  # these two are per-field, so a lost datagram for one costs that field and
  # nothing else. Bare replies, no envelope — these getters take no index.
  defp master_float(transport, address) do
    case probe(transport, address, [], @return_probe_timeout) do
      {:ok, [value]} when is_float(value) -> value
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
      Transport.send_message("/live/return_track/start_listen/panning", [index])
      Transport.send_message("/live/return_track/start_listen/mute", [index])
      Transport.send_message("/live/return_track/start_listen/solo", [index])
    end

    Transport.send_message("/live/master/start_listen/volume", [])
    Transport.send_message("/live/master/start_listen/panning", [])
    Transport.send_message("/live/master/start_listen/cue_volume", [])
  end

  # Takes track *indices* rather than the mirrored rows: the caller subscribes
  # what `num_tracks` said exists, which is still true when the read of those
  # tracks came back degraded and there are no rows to derive an index from.
  defp subscribe_listeners(indices) do
    alias Seshat.OSC.Transport

    for index <- indices, prop <- @listened_properties do
      Transport.send_message("/live/track/start_listen/#{prop}", [index])
    end
  end

  defp update_song(state, key, value) do
    Logger.debug("Song #{key} → #{inspect(value)}")
    %{state | song: Map.put(state.song, key, value)}
  end

  # A scalar push for a track list we don't hold is dropped, the same way a push
  # for an index absent from the list already is: there is nothing to hang it on,
  # and inventing a one-track mirror out of a volume push would be a new guess.
  # The next structure push finds `stale?(nil, _)` true and re-reads everything.
  defp update_track(%{tracks: nil} = state, idx, key, value) do
    Logger.debug("Track #{idx} #{key} → #{inspect(value)} dropped: track list unknown")
    state
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
  # A push for a master the mirror doesn't hold *does* build one, unlike
  # `update_track/4`'s drop — there is exactly one master, so there is no index
  # to be wrong about and no structure to guess at. The two unpushed fields stay
  # `nil`: unknown, and repopulated by their own listeners' first push.
  defp update_master(%{master: nil} = state, key, value) do
    Logger.debug("Master #{key} → #{inspect(value)} (mirror had no master yet)")
    %{state | master: Map.put(%{volume: nil, pan: nil, cue_volume: nil}, key, value)}
  end

  defp update_master(state, key, value) do
    Logger.debug("Master #{key} → #{inspect(value)}")
    %{state | master: Map.put(state.master, key, value)}
  end

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
  # `"error"` payload doesn't match it and falls through to `nil`, which is
  # right — the only way to ask this extension for an index it doesn't have is to
  # race a return being deleted mid-refresh.
  #
  # None of them takes a fallback value: anything they can't read is `nil`, full
  # stop. That is deliberately not a `nil` passed at each call site — a parameter
  # is a seam a future caller reopens with a new plausible constant, and the
  # constants are the defect this module is fixing.
  #
  # Every echoed index is checked against the one asked for, the same reason
  # `Handlers.query_echoed/5` does it: Transport serializes queries — one in
  # flight, the rest queued — but correlates replies by address alone, so a reply
  # abandoned by an earlier timeout can still answer the next query on that same
  # address. Unchecked, that hangs return 0's name on return 1 — a wrong answer
  # that looks like a right one. Compared with `==` rather than pinned, matching
  # Handlers: these callers always send integers, but a float index would still
  # come back as an integer.
  defp query_string(transport, address, index, timeout \\ @query_timeout) do
    case probe(transport, address, [index], timeout) do
      {:ok, [s]} when is_binary(s) -> s
      {:ok, [idx, s]} when idx == index and is_binary(s) -> s
      {:ok, [idx, "ok", s]} when idx == index and is_binary(s) -> s
      _ -> nil
    end
  end

  defp query_float(transport, address, index, timeout \\ @query_timeout) do
    case probe(transport, address, [index], timeout) do
      {:ok, [v]} when is_float(v) -> v
      {:ok, [idx, v]} when idx == index and is_float(v) -> v
      {:ok, [idx, "ok", v]} when idx == index and is_float(v) -> v
      _ -> nil
    end
  end

  defp query_int(transport, address, index, timeout \\ @query_timeout) do
    case probe(transport, address, [index], timeout) do
      {:ok, [v]} when is_integer(v) -> v
      {:ok, [idx, v]} when idx == index and is_integer(v) -> v
      {:ok, [true]} -> 1
      {:ok, [false]} -> 0
      {:ok, [idx, true]} when idx == index -> 1
      {:ok, [idx, false]} when idx == index -> 0
      # The return/master extension's ok-envelope, as in query_string/query_float
      # above: `/live/return_track/get/mute` and `get/solo` reply this shape.
      {:ok, [idx, "ok", v]} when idx == index and is_integer(v) -> v
      {:ok, [idx, "ok", true]} when idx == index -> 1
      {:ok, [idx, "ok", false]} when idx == index -> 0
      _ -> nil
    end
  end

  # `Transport.query/3` exits the caller on timeout, and a missing extension (or a
  # dropped datagram) is exactly that. Catching it here means one unanswered
  # property becomes `nil` instead of taking the whole GenServer down
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
  # isn't running, or isn't reachable, must leave the field unknown rather than
  # take this GenServer down before it has finished starting.
  defp query_song_float(transport, address) do
    case probe(transport, address, [], @query_timeout) do
      {:ok, [v]} when is_float(v) -> v
      _ -> nil
    end
  end

  defp query_song_string(transport, address) do
    case probe(transport, address, [], @query_timeout) do
      {:ok, [s]} when is_binary(s) -> s
      _ -> nil
    end
  end

  defp query_song_int(transport, address) do
    case probe(transport, address, [], @query_timeout) do
      {:ok, [v]} when is_integer(v) -> v
      {:ok, [true]} -> 1
      {:ok, [false]} -> 0
      _ -> nil
    end
  end

  # `nil` in means the query went unanswered, and unknown has to survive the
  # conversion — a `to_bool(nil)` that returned `false` would put the guess back
  # one layer down. Wire pushes never carry `nil`, so no live shape gains a nil
  # path from this clause.
  defp to_bool(nil), do: nil
  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool(1), do: true
  defp to_bool(0), do: false
  defp to_bool(v) when is_integer(v), do: v != 0

  # Log-only renderers. These are not the reply the model reads —
  # `Seshat.Tools.Handlers` owns that — they just keep a refresh log line
  # readable when half the session came back unknown.
  defp unknown_if_nil(nil), do: "unknown"
  defp unknown_if_nil(value), do: to_string(value)

  defp root_note_label(nil), do: "unknown"
  defp root_note_label(note), do: Seshat.Music.Pitch.pitch_class_name(note)
end
