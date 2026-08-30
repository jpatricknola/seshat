defmodule Seshat.Session.StateTest do
  use ExUnit.Case, async: true

  alias Seshat.Session.State

  # The GenServer isn't started here — its init queries Ableton over OSC, which
  # needs a live Live. The listener-push handling is pure given a state map, so
  # it is exercised by calling handle_info/2 directly.
  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        song: %{
          tempo: 120.0,
          time_sig_numerator: 4,
          time_sig_denominator: 4,
          is_playing: false,
          root_note: 0,
          scale_name: "Major",
          groove_amount: nil,
          swing_amount: nil
        },
        tracks: [],
        return_tracks: [],
        master: nil,
        returns_readable?: true,
        unreconciled: %{},
        refresh_timer: nil,
        refresh_token: nil,
        refresh_requested?: false,
        pending_reconciliations: %{}
      },
      overrides
    )
  end

  defp track(index, name) do
    %{index: index, name: name, volume: 0.85, pan: 0.0, mute: false, solo: false}
  end

  defp return(index, name) do
    %{index: index, name: name, volume: 0.85, pan: 0.0, mute: false, solo: false}
  end

  defp master(overrides \\ %{}) do
    Map.merge(%{volume: 0.85, pan: 0.0, cue_volume: 0.85}, overrides)
  end

  defp push(state, address, args) do
    {:noreply, state} = State.handle_info({:osc_message, address, args}, state)
    state
  end

  defp cast_refresh(state) do
    {:noreply, state} = State.handle_cast(:refresh, state)
    state
  end

  # The timer message as the GenServer would receive it. Nothing here ever fires
  # a *current* token: that branch runs do_refresh/1, which queries Ableton.
  defp fire(state, token) do
    {:noreply, state} = State.handle_info({:refresh, token}, state)
    state
  end

  describe "song property pushes" do
    test "records a new root note" do
      state = push(state(), "/live/song/get/root_note", [7])

      assert state.song.root_note == 7
    end

    test "records a new scale name" do
      state = push(state(), "/live/song/get/scale_name", ["Minor"])

      assert state.song.scale_name == "Minor"
    end

    test "key changes leave the rest of the song state alone" do
      state =
        state()
        |> push("/live/song/get/root_note", [2])
        |> push("/live/song/get/scale_name", ["Dorian"])

      assert state.song.root_note == 2
      assert state.song.scale_name == "Dorian"
      assert state.song.tempo == 120.0
      assert state.song.time_sig_numerator == 4
    end

    # The listener echo is the only verification channel these two setters have:
    # /live/song/set/* never replies, so a push landing here is what proves the
    # value took. `swing_amount` additionally comes from the fork's song.py.
    test "records a new swing amount" do
      state = push(state(), "/live/song/get/swing_amount", [0.25])

      assert state.song.swing_amount == 0.25
    end

    test "records a new groove amount" do
      state = push(state(), "/live/song/get/groove_amount", [1.3])

      assert state.song.groove_amount == 1.3
    end

    test "swing and groove changes leave the rest of the song state alone" do
      state =
        state()
        |> push("/live/song/get/swing_amount", [0.16])
        |> push("/live/song/get/groove_amount", [+0.0])

      assert state.song.swing_amount == 0.16
      assert state.song.groove_amount == +0.0
      assert state.song.tempo == 120.0
      assert state.song.scale_name == "Major"
    end

    test "still handles the properties that were already listened to" do
      state =
        state()
        |> push("/live/song/get/tempo", [128.0])
        |> push("/live/song/get/is_playing", [1])

      assert state.song.tempo == 128.0
      assert state.song.is_playing == true
    end

    test "an unhandled address is ignored rather than crashing" do
      assert push(state(), "/live/song/get/something_new", [1]) == state()
    end
  end

  describe "stale?/2" do
    test "the same names in the same order are not stale" do
      refute State.stale?([track(0, "Drums"), track(1, "Bass")], ["Drums", "Bass"])
    end

    test "a deleted track is stale" do
      assert State.stale?([track(0, "Drums"), track(1, "Bass")], ["Drums"])
    end

    test "an added track is stale" do
      assert State.stale?([track(0, "Drums")], ["Drums", "Bass"])
    end

    test "a rename is stale" do
      assert State.stale?([track(0, "Drums")], ["Beats"])
    end

    test "a reorder is stale even though the same names are present" do
      assert State.stale?([track(0, "Drums"), track(1, "Bass")], ["Bass", "Drums"])
    end

    test "an empty mirror against a live session is stale" do
      assert State.stale?([], ["Drums"])
    end

    test "an empty mirror against an empty session is not stale" do
      refute State.stale?([], [])
    end

    # `nil` is "we could not read the list", which is a different fact from "the
    # list is empty" and must not reconcile against anything. Being stale against
    # every pushed list is what heals a failed refresh: the next structure push
    # disagrees by definition and triggers the authoritative re-read.
    test "an unknown mirror is stale against an empty session" do
      assert State.stale?(nil, [])
    end

    test "an unknown mirror is stale against a live session" do
      assert State.stale?(nil, ["Drums"])
    end
  end

  describe "song structure pushes" do
    test "a track list matching the mirror leaves the state untouched" do
      mirrored = state(%{tracks: [track(0, "Drums"), track(1, "Bass")]})

      assert push(mirrored, "/live/song/get/tracks", ["Drums", "Bass"]) == mirrored
    end

    test "a return list matching the mirror leaves the state untouched" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      assert push(mirrored, "/live/song/get/return_tracks", ["Reverb"]) == mirrored
    end

    # A return list that disagrees with the mirror normally triggers do_refresh,
    # which needs Ableton. When returns aren't readable it must not — otherwise
    # each push refreshes, each refresh re-subscribes, and each re-subscribe
    # pushes again, forever. That branch is pure, so it is the one testable half
    # of the disagreement case.
    test "a disagreeing return list is ignored while returns are unreadable" do
      mirrored = state(%{return_tracks: [], returns_readable?: false})

      state = push(mirrored, "/live/song/get/return_tracks", ["Reverb"])

      assert state == mirrored
      # Explicitly, not just as a consequence of the equality above: the brake
      # has to stop the *scheduling* now, not only the rebuild. A version that
      # recorded the push and armed a timer would still refresh on every push a
      # second later, which is the spin this test exists to prevent.
      assert state.refresh_timer == nil
      assert state.refresh_token == nil
      assert state.pending_reconciliations == %{}
    end

    # The brake against an unbounded refresh spin: a refresh that comes back
    # still disagreeing records the list it failed on, and a repeat of that exact
    # list must not refresh again. Pre-setting the record is what makes the
    # branch reachable without Ableton — taking it means do_refresh is never
    # called, which is the whole assertion.
    test "a name list that already failed to reconcile is not refreshed on again" do
      mirrored =
        state(%{
          tracks: [track(0, "Drums")],
          unreconciled: %{tracks: ["Drums", "Bass"]}
        })

      state = push(mirrored, "/live/song/get/tracks", ["Drums", "Bass"])

      assert state == mirrored
      assert state.refresh_timer == nil
      assert state.pending_reconciliations == %{}
    end

    # A refresh that couldn't read the track count leaves `tracks: nil`, and
    # `stale?(nil, _)` is true, so without the brake every subsequent push would
    # refresh again — the unbounded spin, reached by the failure path this whole
    # change adds. Pre-setting the record proves the brake still holds when the
    # mirror side is unknown rather than a list.
    test "the brake still holds when the mirror side is unknown" do
      mirrored =
        state(%{
          tracks: nil,
          unreconciled: %{tracks: ["Drums", "Bass"]}
        })

      assert push(mirrored, "/live/song/get/tracks", ["Drums", "Bass"]) == mirrored
    end

    test "the return list gets the same brake" do
      mirrored =
        state(%{
          return_tracks: [return(0, "Reverb")],
          unreconciled: %{return_tracks: ["Reverb", "Delay"]}
        })

      assert push(mirrored, "/live/song/get/return_tracks", ["Reverb", "Delay"]) == mirrored
    end

    # A *different* list has to get a fresh attempt, or one unreconcilable push
    # would deafen the mirror to every real change after it.
    test "a list that matches the mirror lifts the brake" do
      mirrored =
        state(%{
          tracks: [track(0, "Drums")],
          unreconciled: %{tracks: ["Drums", "Bass"]}
        })

      state = push(mirrored, "/live/song/get/tracks", ["Drums"])

      assert state.unreconciled == %{}
    end

    # The echo-loop guard. A degraded rebuild leaves `tracks: nil`, which is
    # stale against every list including the one the re-subscription echo pushes
    # straight back — so without this branch each echo would replace the pending
    # record, throwing away the `retried?` marker that bounds the retry and
    # pushing the trailing edge out again. Unbounded, and reachable only in the
    # state a degraded read creates.
    test "an identical re-push leaves a pending record, its marker and the timer alone" do
      timer = make_ref()

      pending =
        state(%{
          tracks: nil,
          pending_reconciliations: %{
            tracks: %{
              names: ["Drums", "Bass"],
              message: "Track list changed in Live",
              retried?: true
            }
          },
          refresh_timer: timer,
          refresh_token: make_ref()
        })

      assert push(pending, "/live/song/get/tracks", ["Drums", "Bass"]) == pending
    end

    # The other half of the guarantee: a list that genuinely differs is a real
    # change, so it gets a fresh record and a fresh attempt — the retry marker
    # belongs to the list that failed, not to the key.
    test "a different name list replaces the record and drops the retry marker" do
      pending =
        state(%{
          tracks: nil,
          pending_reconciliations: %{
            tracks: %{
              names: ["Drums", "Bass"],
              message: "Track list changed in Live",
              retried?: true
            }
          }
        })

      state = push(pending, "/live/song/get/tracks", ["Drums", "Bass", "Keys"])

      assert state.pending_reconciliations == %{
               tracks: %{names: ["Drums", "Bass", "Keys"], message: "Track list changed in Live"}
             }

      assert is_reference(state.refresh_timer)
    end
  end

  # The post-rebuild decision, reachable from here because the finalizer is a
  # public state transition that touches no OSC: it takes the rebuilt state, the
  # pending records the rebuild cleared, and the pre-refresh context. Everything
  # it decides — one retry for a rebuild that read nothing, an immediate brake for
  # one that disagreed, and whether the other key's brake survives — is invisible
  # to `mix test` if it lives behind `do_refresh/1`.
  describe "finalize_reconciliations/3" do
    defp record(names, extra \\ %{}) do
      Map.merge(%{names: names, message: "Track list changed in Live"}, extra)
    end

    defp finalize(state, pending, context) do
      State.finalize_reconciliations(state, pending, context)
    end

    # "The rebuild established nothing" is not "Live and the mirror disagree":
    # nothing has been contradicted, so the brake — which exists to stop a spin
    # between two answers — has nothing to brake yet.
    test "a rebuild that read nothing keeps the record and schedules exactly one retry" do
      final =
        finalize(
          state(%{tracks: nil}),
          %{tracks: record(["Drums", "Bass"])},
          %{unreconciled: %{return_tracks: ["Reverb", "Delay"]}, explicit?: false}
        )

      assert final.pending_reconciliations == %{
               tracks: record(["Drums", "Bass"], %{retried?: true})
             }

      assert is_reference(final.refresh_timer)
      # Untouched: this rebuild is only about :tracks, so the other key's brake
      # rides through unchanged rather than being cleared as a side effect.
      assert final.unreconciled == %{return_tracks: ["Reverb", "Delay"]}
      # Structure-only, so the retry keeps protecting the other key's brake
      # rather than lifting every one of them.
      assert final.refresh_requested? == false
    end

    test "a second failure records the brake and schedules nothing further" do
      final =
        finalize(
          state(%{tracks: nil}),
          %{tracks: record(["Drums", "Bass"], %{retried?: true})},
          %{unreconciled: %{}, explicit?: false}
        )

      assert final.unreconciled == %{tracks: ["Drums", "Bass"]}
      assert final.refresh_timer == nil
      assert final.pending_reconciliations == %{}
    end

    # A rebuild that read the session successfully and got a different answer is
    # information, not a failure. Retrying it is the flood the brake exists to
    # stop, so this one never gets the retry the failure case does.
    test "a rebuild that disagrees brakes immediately with no retry" do
      final =
        finalize(
          state(%{tracks: [track(0, "Drums")]}),
          %{tracks: record(["Drums", "Bass"])},
          %{unreconciled: %{}, explicit?: false}
        )

      assert final.unreconciled == %{tracks: ["Drums", "Bass"]}
      assert final.refresh_timer == nil
      assert final.pending_reconciliations == %{}
    end

    test "a rebuild that reproduced the pushed list clears that key's brake" do
      final =
        finalize(
          state(%{tracks: [track(0, "Drums"), track(1, "Bass")]}),
          %{tracks: record(["Drums", "Bass"])},
          %{unreconciled: %{tracks: ["Drums", "Bass"]}, explicit?: false}
        )

      assert final.unreconciled == %{}
      assert final.refresh_timer == nil
    end

    # The cross-key loop brake. Dropping the *other* key's record on a
    # structure-only rebuild lets the two lift each other's brake forever: tracks
    # refresh, clearing returns, whose echo refreshes, clearing tracks, and every
    # refresh re-subscribes and every re-subscribe pushes again.
    test "a structure-only rebuild carries an unrelated key's brake over" do
      final =
        finalize(
          state(%{tracks: [track(0, "Drums"), track(1, "Bass")]}),
          %{tracks: record(["Drums", "Bass"])},
          %{unreconciled: %{return_tracks: ["Reverb", "Delay"]}, explicit?: false}
        )

      assert final.unreconciled == %{return_tracks: ["Reverb", "Delay"]}
    end

    # An explicit refresh is a forced retry of every brake, so it keeps none of
    # them and re-records only what this rebuild still can't reproduce.
    test "an explicit rebuild drops every brake it isn't about" do
      final =
        finalize(
          state(%{tracks: [track(0, "Drums"), track(1, "Bass")]}),
          %{tracks: record(["Drums", "Bass"])},
          %{unreconciled: %{return_tracks: ["Reverb", "Delay"]}, explicit?: true}
        )

      assert final.unreconciled == %{}
    end
  end

  # The trailing-edge scheduler. Everything here stops at the timer boundary: the
  # branch where a *current* token fires calls do_refresh/1, which queries
  # Ableton, so it stays a /smoke-test concern (testing.md: never reach
  # Transport.query/3). Driving a configurable delay to zero would reach the same
  # calls sooner rather than avoid them, which is why the delay is a constant.
  #
  # Timer messages land in the bare ExUnit test process here, never in a running
  # GenServer, so an unhandled due message is inert and dies with the test.
  describe "coalescing refresh requests" do
    test "a refresh cast schedules one rather than rebuilding" do
      state = cast_refresh(state())

      assert is_reference(state.refresh_timer)
      assert is_reference(state.refresh_token)
      assert state.refresh_requested? == true
    end

    # The whole point of a trailing edge: a second request during the window
    # doesn't queue a second rebuild, it moves the one that's already scheduled.
    test "a second refresh cast replaces the timer rather than adding one" do
      first = cast_refresh(state())
      second = cast_refresh(first)

      assert second.refresh_token != first.refresh_token
      assert second.refresh_timer != first.refresh_timer
      assert second.refresh_requested? == true
    end

    # Process.cancel_timer/1 can't unsend a message already in the mailbox, so
    # the token — not the cancellation — is what makes a replaced timer harmless.
    test "the replaced timer's message is ignored when it arrives late" do
      first = cast_refresh(state())
      second = cast_refresh(first)

      assert fire(second, first.refresh_token) == second
    end

    test "a stale timer message cannot erase pending work or touch the mirror" do
      scheduled =
        %{tracks: [track(0, "Drums")]}
        |> state()
        |> push("/live/song/get/tracks", ["Drums", "Bass"])

      assert fire(scheduled, make_ref()) == scheduled
    end

    # `nil` is the marker for "nothing scheduled". A message carrying it must not
    # be read as matching the idle state.
    test "a timer message carrying no token is ignored" do
      idle = state()

      assert fire(idle, nil) == idle
    end

    test "a stale track list schedules a refresh instead of rebuilding inline" do
      state =
        %{tracks: [track(0, "Drums")]}
        |> state()
        |> push("/live/song/get/tracks", ["Drums", "Bass"])

      assert is_reference(state.refresh_timer)
      # Not an explicit request: this timer exists only to reconcile structure,
      # which decides whether the rebuild lifts every brake or only this key's.
      assert state.refresh_requested? == false

      assert state.pending_reconciliations == %{
               tracks: %{names: ["Drums", "Bass"], message: "Track list changed in Live"}
             }
    end

    test "successive track lists keep only the latest names under one timer" do
      first =
        %{tracks: [track(0, "Drums")]}
        |> state()
        |> push("/live/song/get/tracks", ["Drums", "Bass"])

      second = push(first, "/live/song/get/tracks", ["Drums", "Bass", "Keys"])

      assert second.pending_reconciliations[:tracks].names == ["Drums", "Bass", "Keys"]
      assert map_size(second.pending_reconciliations) == 1
      assert second.refresh_token != first.refresh_token
    end

    test "a track and a return change ride one timer with a record each" do
      state =
        %{tracks: [track(0, "Drums")], return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/song/get/tracks", ["Drums", "Bass"])
        |> push("/live/song/get/return_tracks", ["Reverb", "Delay"])

      assert state.pending_reconciliations |> Map.keys() |> Enum.sort() ==
               [:return_tracks, :tracks]

      assert state.pending_reconciliations[:tracks].names == ["Drums", "Bass"]
      assert state.pending_reconciliations[:return_tracks].names == ["Reverb", "Delay"]
      assert is_reference(state.refresh_timer)
    end

    # The mirror caught up on its own — pushes filled it in, or the change was
    # undone — so the question the timer was scheduled to answer is already
    # answered, and there is nothing left to rebuild for.
    test "a list matching the mirror drops its record and cancels the timer" do
      state =
        %{tracks: [track(0, "Drums")]}
        |> state()
        |> push("/live/song/get/tracks", ["Drums", "Bass"])
        |> push("/live/song/get/tracks", ["Drums"])

      assert state.pending_reconciliations == %{}
      assert state.refresh_timer == nil
      assert state.refresh_token == nil
    end

    test "the timer survives a settled track list while a return list is still pending" do
      state =
        %{tracks: [track(0, "Drums")], return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/song/get/tracks", ["Drums", "Bass"])
        |> push("/live/song/get/return_tracks", ["Reverb", "Delay"])
        |> push("/live/song/get/tracks", ["Drums"])

      assert Map.keys(state.pending_reconciliations) == [:return_tracks]
      assert is_reference(state.refresh_timer)
    end

    # An explicit refresh/0 asked for a rebuild, not for a structure comparison,
    # so settling the structure question must not cancel it out from under them.
    test "the timer survives a settled list while an explicit refresh is riding it" do
      state =
        %{tracks: [track(0, "Drums")]}
        |> state()
        |> push("/live/song/get/tracks", ["Drums", "Bass"])
        |> cast_refresh()
        |> push("/live/song/get/tracks", ["Drums"])

      assert state.pending_reconciliations == %{}
      assert state.refresh_requested? == true
      assert is_reference(state.refresh_timer)
    end

    test "a matching return list settles the same way" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/song/get/return_tracks", ["Reverb", "Delay"])
        |> push("/live/song/get/return_tracks", ["Reverb"])

      assert state.pending_reconciliations == %{}
      assert state.refresh_timer == nil
    end
  end

  describe "reads while a refresh is scheduled" do
    test "a snapshot returns all four mirror sections from one state" do
      mirrored =
        state(%{
          tracks: [track(0, "Drums")],
          return_tracks: [return(0, "Reverb")],
          master: master()
        })

      {:reply, snapshot, unchanged} = State.handle_call(:snapshot, self(), mirrored)

      assert snapshot == %{
               song: mirrored.song,
               tracks: mirrored.tracks,
               return_tracks: mirrored.return_tracks,
               master: mirrored.master,
               refresh_pending?: false
             }

      assert unchanged == mirrored
    end

    # The flag `get_session_state` uses to say the layout is still settling. It
    # is a fact about this reply, so it rides the snapshot and not the four
    # narrower reads, which have no reply to qualify.
    test "a snapshot taken with a rebuild scheduled says so" do
      scheduled = cast_refresh(state(%{tracks: [track(0, "Drums")]}))

      {:reply, snapshot, _unchanged} = State.handle_call(:snapshot, self(), scheduled)

      assert snapshot.refresh_pending? == true
    end

    # Reads answer from the push-updated mirror and neither force nor cancel the
    # pending rebuild. The trade is structural staleness lasting the burst that
    # keeps restarting the timer, plus the window past its last request, plus
    # the rebuild; blocking every read on a scheduled refresh would reintroduce
    # the queuing this change removes.
    test "a snapshot leaves a pending timer alone" do
      scheduled = cast_refresh(state(%{tracks: [track(0, "Drums")]}))

      {:reply, snapshot, unchanged} = State.handle_call(:snapshot, self(), scheduled)

      assert snapshot.tracks == [track(0, "Drums")]
      assert unchanged == scheduled
    end

    test "the narrower reads leave a pending timer alone too" do
      scheduled =
        state(%{
          tracks: [track(0, "Drums")],
          return_tracks: [return(0, "Reverb")],
          master: master()
        })
        |> cast_refresh()

      for {request, expected} <- [
            tracks: scheduled.tracks,
            song: scheduled.song,
            return_tracks: scheduled.return_tracks,
            master: scheduled.master
          ] do
        assert {:reply, ^expected, ^scheduled} = State.handle_call(request, self(), scheduled)
      end
    end
  end

  describe "track scalar pushes onto an unknown track list" do
    # A failed refresh leaves `tracks: nil` — unknown, not empty. A scalar push
    # for a list we don't hold has nothing to land on, and building a one-track
    # mirror out of a volume push would invent every other field. Dropped, and
    # the next structure push re-reads the lot.
    test "a volume push is a no-op" do
      mirrored = state(%{tracks: nil})

      assert push(mirrored, "/live/track/get/volume", [0, 0.5]) == mirrored
    end

    test "a name push is a no-op" do
      mirrored = state(%{tracks: nil})

      assert push(mirrored, "/live/track/get/name", [0, "Drums"]) == mirrored
    end

    test "a mute push is a no-op" do
      mirrored = state(%{tracks: nil})

      assert push(mirrored, "/live/track/get/mute", [0, 1]) == mirrored
    end
  end

  describe "return track and master pushes" do
    test "a name push updates that return and no other" do
      state =
        %{return_tracks: [return(0, "Reverb"), return(1, "Delay")]}
        |> state()
        |> push("/live/return_track/get/name", [1, "Tape Delay"])

      assert Enum.map(state.return_tracks, & &1.name) == ["Reverb", "Tape Delay"]
    end

    test "a name query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/name", [0, "ok", "Hall"])

      assert Enum.map(state.return_tracks, & &1.name) == ["Hall"]
    end

    test "a volume push updates that return and no other" do
      state =
        %{return_tracks: [return(0, "Reverb"), return(1, "Delay")]}
        |> state()
        |> push("/live/return_track/get/volume", [0, 0.5])

      assert Enum.map(state.return_tracks, & &1.volume) == [0.5, 0.85]
    end

    test "a volume query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/volume", [0, "ok", 0.25])

      assert Enum.map(state.return_tracks, & &1.volume) == [0.25]
    end

    test "a push for an index the mirror doesn't have is a no-op" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      assert push(mirrored, "/live/return_track/get/volume", [3, 0.5]) == mirrored
    end

    test "a pan push updates that return and no other" do
      state =
        %{return_tracks: [return(0, "Reverb"), return(1, "Delay")]}
        |> state()
        |> push("/live/return_track/get/panning", [1, -0.4])

      assert Enum.map(state.return_tracks, & &1.pan) == [0.0, -0.4]
    end

    test "a pan query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/panning", [0, "ok", 0.25])

      assert Enum.map(state.return_tracks, & &1.pan) == [0.25]
    end

    # The getter replies 0/1 and Live's own listener pushes a bool, so both
    # spellings have to normalize — otherwise the mirror holds two ways of
    # saying "muted" and every reader has to know both.
    test "a mute push normalizes an int to a boolean" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/mute", [0, 1])

      assert Enum.map(state.return_tracks, & &1.mute) == [true]
    end

    test "a mute push normalizes a bool the same way" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/mute", [0, true])

      assert Enum.map(state.return_tracks, & &1.mute) == [true]
    end

    test "a mute query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/mute", [0, "ok", 1])

      assert Enum.map(state.return_tracks, & &1.mute) == [true]
    end

    test "a solo push normalizes and touches only that return" do
      state =
        %{return_tracks: [return(0, "Reverb"), return(1, "Delay")]}
        |> state()
        |> push("/live/return_track/get/solo", [1, 1])

      assert Enum.map(state.return_tracks, & &1.solo) == [false, true]
    end

    test "a solo query reply carries its ok envelope and still lands" do
      state =
        %{return_tracks: [return(0, "Reverb")]}
        |> state()
        |> push("/live/return_track/get/solo", [0, "ok", 0])

      assert Enum.map(state.return_tracks, & &1.solo) == [false]
    end

    test "a master volume push leaves pan and cue volume alone" do
      state =
        %{master: master()}
        |> state()
        |> push("/live/master/get/volume", [0.7])

      assert state.master == %{volume: 0.7, pan: 0.0, cue_volume: 0.85}
    end

    test "a master pan push leaves volume and cue volume alone" do
      state =
        %{master: master()}
        |> state()
        |> push("/live/master/get/panning", [-0.25])

      assert state.master == %{volume: 0.85, pan: -0.25, cue_volume: 0.85}
    end

    test "a cue volume push leaves volume and pan alone" do
      state =
        %{master: master()}
        |> state()
        |> push("/live/master/get/cue_volume", [0.4])

      assert state.master == %{volume: 0.85, pan: 0.0, cue_volume: 0.4}
    end

    # There is exactly one master, so there is no index to be wrong about — a
    # push arriving before any refresh has read one builds the map rather than
    # being dropped. The fields it doesn't carry stay unknown, never 0.0.
    test "a master push into an empty mirror builds it with the rest unknown" do
      state = push(state(), "/live/master/get/panning", [0.5])

      assert state.master == %{volume: nil, pan: 0.5, cue_volume: nil}
    end

    # The error envelope shares its address and arity with the ok envelope, so
    # only the literal "ok" and the float guard keep the message text out of the
    # mirror. Relax either and a return gets named "error".
    test "a name error envelope is ignored rather than mirrored" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      assert push(mirrored, "/live/return_track/get/name", [0, "error", "no such return"]) ==
               mirrored
    end

    test "a volume error envelope is ignored rather than mirrored" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      assert push(mirrored, "/live/return_track/get/volume", [0, "error", "no such return"]) ==
               mirrored
    end

    test "pan, mute and solo error envelopes are ignored rather than mirrored" do
      mirrored = state(%{return_tracks: [return(0, "Reverb")]})

      for address <- [
            "/live/return_track/get/panning",
            "/live/return_track/get/mute",
            "/live/return_track/get/solo"
          ] do
        assert push(mirrored, address, [0, "error", "no such return"]) == mirrored
      end
    end
  end

  # `/live/startup`, `refresh_sync/0` and a *current* timer token all call
  # do_refresh/1, which queries Ableton — untestable here by design
  # (testing.md: never reach Transport.query/3), and covered by /smoke-test.
  # That includes subscribe_return_listeners/1's five start_listen sends: the
  # plan asked for a unit test of "subscription sends for all new listeners",
  # but the function is private and reachable only through do_refresh/1, so
  # there is no pure entry point to call it through. New mixer smoke item 3
  # ("Push, not poll") is the actual coverage.
  #
  # Coalescing moved the *stale* branch of the two structure pushes out of that
  # set: it now records the pushed names and arms a timer, both pure, so
  # scheduling, latest-list replacement, cross-key accumulation and the settling
  # rules are all tested above. The post-refresh decision came out of that set
  # too: finalize_reconciliations/3 is public and OSC-free, so the retry, the
  # brake and the cross-key carry-over are ordinary state-transition tests above.
  #
  # What stays live-only is `do_refresh/1` itself, which names
  # `Seshat.OSC.Transport` directly. `read_tracks/2` does not: it takes the
  # transport module as an argument, so the degrade decision — the part of a
  # rebuild worth pinning — is testable against a stub that answers the way
  # Ableton does. That a *real* rebuild wires this to Live is still a
  # /smoke-test check; see the Session.State refresh section there.
  describe "read_tracks/2" do
    defmodule StubTransport do
      @moduledoc false
      # Answers from a map of {address, index} => reply, defaulting to silence
      # (an exit, which is what Transport.query/3 does on timeout).
      def query(address, [index], _timeout) do
        case Process.get({__MODULE__, address, index}, :timeout) do
          :timeout -> exit({:timeout, {GenServer, :call, [Transport, :stub, 0]}})
          reply -> reply
        end
      end

      # The per-track input block goes out as one batch. Answering it from the
      # same map keeps the stub one thing: `{:ok, tail}` per entry, where the
      # tail is what `Transport.query_batch/2` hands back — the reply's values
      # with the echoed index already stripped.
      def query_batch(entries, _timeout) do
        results =
          Enum.map(entries, fn {address, [index]} ->
            case Process.get({__MODULE__, address, index}, :timeout) do
              :timeout -> {:error, {:live_error, "stub has no answer"}}
              {:ok, {_addr, [^index | tail]}} -> {:ok, tail}
              {:ok, {_addr, values}} -> {:ok, values}
            end
          end)

        {:ok, results}
      end

      def put(address, index, reply), do: Process.put({__MODULE__, address, index}, reply)
    end

    defp stub_track(index, name) do
      StubTransport.put(
        "/live/track/get/name",
        index,
        {:ok, {"/live/track/get/name", [index, name]}}
      )

      StubTransport.put("/live/track/get/volume", index, {:ok, {"", [index, 0.85]}})
      StubTransport.put("/live/track/get/panning", index, {:ok, {"", [index, 0.0]}})
      StubTransport.put("/live/track/get/mute", index, {:ok, {"", [index, 0]}})
      StubTransport.put("/live/track/get/solo", index, {:ok, {"", [index, 0]}})
    end

    test "a count of zero is a verified-empty set, not degradation" do
      assert State.read_tracks(StubTransport, 0) == {:ok, []}
    end

    test "every name answered gives the whole list" do
      stub_track(0, "Drums")
      stub_track(1, "Bass")

      assert {:ok, [%{index: 0, name: "Drums"}, %{index: 1, name: "Bass"}]} =
               State.read_tracks(StubTransport, 2)
    end

    # The point of the whole /live/error correlation: an index that vanished
    # mid-walk now *answers* — with a rejection — where it used to leave the
    # query to time out. The degrade decision must be identical either way,
    # since a rejected name is exactly as unknown as an unanswered one.
    test "a rejected name degrades at that index, like an unanswered one" do
      stub_track(0, "Drums")

      StubTransport.put(
        "/live/track/get/name",
        1,
        {:error, {:live_error, "Index out of range"}}
      )

      assert State.read_tracks(StubTransport, 3) == {:degraded, 1}
    end

    test "an unanswered name degrades at that index" do
      stub_track(0, "Drums")

      assert State.read_tracks(StubTransport, 3) == {:degraded, 1}
    end

    # The input block rides in each track's existing step as one batch — four
    # reads for one AbletonOSC tick — rather than four more serialized queries.
    test "each track carries the input block its batch answered" do
      stub_track(0, "Vocals")
      StubTransport.put("/live/track/get/has_audio_input", 0, {:ok, {"", [0, 1]}})
      StubTransport.put("/live/track/get/input_routing_type", 0, {:ok, {"", [0, "Ext. In"]}})
      StubTransport.put("/live/track/get/input_routing_channel", 0, {:ok, {"", [0, "3/4"]}})
      StubTransport.put("/live/track/get/current_monitoring_state", 0, {:ok, {"", [0, 2]}})

      assert {:ok, [track]} = State.read_tracks(StubTransport, 1)

      assert track.audio_input? == true
      assert track.input_type == "Ext. In"
      assert track.input_channel == "3/4"
      assert track.monitoring == 2
    end

    # Unknown, never a guess — the rule the whole module runs on. An unanswered
    # input read leaves the field `nil` and costs nothing else: unlike a name,
    # it is not the identity field, so the row survives.
    test "an unanswered input block leaves the fields nil without degrading" do
      stub_track(0, "Drums")

      assert {:ok, [track]} = State.read_tracks(StubTransport, 1)

      assert track.name == "Drums"
      assert track.audio_input? == nil
      assert track.input_type == nil
      assert track.input_channel == nil
      assert track.monitoring == nil
    end
  end
end
