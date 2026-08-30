defmodule Seshat.Test.FakeSessionState do
  @moduledoc """
  A stand-in registered under `Seshat.Session.State`'s own name.

  `Seshat.Generation.AudioClip` reads the session through
  `Seshat.Session.State.snapshot/0`, which is a `GenServer.call` to that module
  name. The real mirror cannot be started in the suite — its setup issues a full
  refresh against an Ableton that is not there — so this answers the one call
  the workflow makes, with a session the test chose.

  Registering under the real module's name rather than adding an indirection to
  production code is deliberate: the workflow keeps calling exactly what it
  calls in production, and there is no injectable-session-module seam for a
  future caller to reach for.

  It also absorbs the `:refresh` cast `Seshat.Commands.Registry` sends after
  creating a track, which would otherwise be a silent no-op only because the
  name happens to be unregistered.
  """

  use GenServer

  @default_song %{
    tempo: 124.0,
    time_sig_numerator: 4,
    time_sig_denominator: 4,
    is_playing: false,
    root_note: 5,
    scale_name: "Minor",
    groove_amount: 0.0,
    swing_amount: 0.0,
    groove_pool: []
  }

  @doc """
  Start the fake under `Seshat.Session.State`'s name.

  `song` overrides any of the mirrored song fields; passing `tempo: nil` or
  `time_sig_denominator: 3` is how the refusal paths are reached.
  """
  def start_link(opts \\ []) do
    song = Map.merge(@default_song, Map.new(Keyword.get(opts, :song, [])))

    GenServer.start_link(__MODULE__, song, name: Seshat.Session.State)
  end

  @doc "The song map the fake reports unless a test overrides it."
  def default_song, do: @default_song

  @impl true
  def init(song), do: {:ok, song}

  # `Seshat.Tools.Handlers` reads the mirrored Groove Pool through `song/0`
  # before assigning a groove, so the fake answers that call too — otherwise the
  # guard's refusal paths would be unreachable in the suite.
  @impl true
  def handle_call(:song, _from, song), do: {:reply, song, song}

  def handle_call(:snapshot, _from, song) do
    snapshot = %{
      song: song,
      tracks: nil,
      return_tracks: [],
      master: nil,
      refresh_pending?: false
    }

    {:reply, snapshot, song}
  end

  @impl true
  def handle_cast(_message, song), do: {:noreply, song}
end
