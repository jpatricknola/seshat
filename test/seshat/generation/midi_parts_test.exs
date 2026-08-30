defmodule Seshat.Generation.MidiPartsTest do
  @moduledoc """
  The `generate_midi` workflow, against a scripted Ableton.

  `Seshat.Test.LiveDouble` answers every query off a mutable session model and
  hands back the datagram trace in arrival order, which is what makes the
  ordering claims assertable: that a refused target costs no mutation, that the
  notes are chunked rather than dropped, and that nothing is reported as
  confirmed before it has been read back out of the model it was written into.
  """

  use ExUnit.Case, async: false

  alias Seshat.Generation.MidiParts
  alias Seshat.OSC.Message
  alias Seshat.OSC.Transport
  alias Seshat.Test.FakeSessionState
  alias Seshat.Test.LiveDouble
  alias Seshat.Test.OSCSink

  setup do
    sink = start_supervised!({OSCSink, forward_to: self()})
    start_supervised!({Transport, send_port: OSCSink.port(sink), reply_port: 0})
    start_supervised!(FakeSessionState)

    %{sink: sink}
  end

  # A session with one audio track (0), one MIDI track (1), one group track (2)
  # and eight scenes — LiveDouble's own, which the audio workflow shares.
  defp live(overrides \\ %{}), do: Map.merge(LiveDouble.session(), overrides)

  defp run(context, params, live \\ nil) do
    LiveDouble.run(context.sink, live || live(), fn -> MidiParts.generate(params) end)
  end

  defp addresses(trace), do: LiveDouble.addresses(trace)

  defp datagrams(trace, address) do
    for {addr, args} <- trace, addr == address, do: args
  end

  defp kick_part(overrides \\ %{}) do
    Map.merge(
      %{"role" => "Kick", "type" => "drum", "pitch" => 36, "pattern" => "x---x---x---x---"},
      overrides
    )
  end

  defp request(overrides \\ %{}) do
    Map.merge(%{"style" => "rock", "bars" => 1, "parts" => [kick_part()]}, overrides)
  end

  describe "the happy path" do
    test "creates a track per part, writes a clip each, and names them", context do
      params =
        request(%{
          "parts" => [
            kick_part(),
            %{
              "role" => "Bass",
              "type" => "bass",
              "relationship" => "lock",
              "roots" => [36]
            }
          ]
        })

      {result, trace} = run(context, params)

      assert {:ok, reply} = result
      assert reply =~ "Composed 2 parts into scene 0"
      assert reply =~ "1 bar of rock"
      assert reply =~ "Kick:"
      assert reply =~ "Bass:"
      assert reply =~ "These are MIDI clips, not audio."
      assert reply =~ "One undo removes the whole request"

      # Two tracks created, two clips created, two note writes, two names.
      assert Enum.count(addresses(trace), &(&1 == "/live/song/create_midi_track")) == 2
      assert Enum.count(addresses(trace), &(&1 == "/live/clip_slot/create_clip")) == 2
      assert Enum.count(addresses(trace), &(&1 == "/live/clip/add/notes_extended")) == 2

      assert [[3, 0, "Kick"], [4, 0, "Bass"]] = datagrams(trace, "/live/clip/set/name")
    end

    # The schema promises the brief is "echoed in the reply" — it steers
    # nothing, but a caller who passed one should see it come back.
    test "the description is echoed in the reply", context do
      {result, _trace} = run(context, request(%{"description" => "lazy boom-bap loop"}))

      assert {:ok, reply} = result
      assert reply =~ "Brief: \"lazy boom-bap loop\""
    end

    test "an omitted description echoes nothing", context do
      {result, _trace} = run(context, request())

      assert {:ok, reply} = result
      refute reply =~ "Brief:"
    end

    # Guards → creates → clip → notes → name → read-back. Every claim this
    # workflow makes rests on that order, and `assert_receive` cannot prove it.
    test "orders guards, creates, writes and the read-back", context do
      {result, trace} = run(context, request())
      assert {:ok, _reply} = result

      order = addresses(trace)

      assert index(order, "/live/song/get/num_scenes") <
               index(order, "/live/song/create_midi_track")

      assert index(order, "/live/song/create_midi_track") <
               index(order, "/live/clip_slot/create_clip")

      assert index(order, "/live/clip_slot/create_clip") <
               index(order, "/live/clip/add/notes_extended")

      assert index(order, "/live/clip/add/notes_extended") <
               index(order, "/live/clip/set/name")

      assert index(order, "/live/clip/set/name") <
               index(order, "/live/clip/get/notes_extended")
    end

    test "an existing MIDI track is written to rather than a new one created", context do
      {result, trace} = run(context, request(%{"parts" => [kick_part(%{"track" => 1})]}))

      assert {:ok, reply} = result
      assert reply =~ "on track 1"
      refute reply =~ "new track"
      refute "/live/song/create_midi_track" in addresses(trace)
    end

    test "the same seed writes byte-identical notes", context do
      params = request(%{"seed" => 4242})

      {_first, first_trace} = run(context, params)
      {_second, second_trace} = run(context, params)

      assert datagrams(first_trace, "/live/clip/add/notes_extended") ==
               datagrams(second_trace, "/live/clip/add/notes_extended")
    end

    test "an omitted seed is drawn and reported so the take can be repeated", context do
      {result, _trace} = run(context, request())
      assert {:ok, reply} = result
      assert reply =~ ~r/seed \d+/
      assert reply =~ "pass that seed back"
    end

    test "a given seed is named as fixed rather than as a draw", context do
      {result, _trace} = run(context, request(%{"seed" => 11}))
      assert {:ok, reply} = result
      assert reply =~ "seed 11"
      assert reply =~ "Same seed, same take."
    end

    test "the reply says whether the style's numbers were measured or derived", context do
      {measured, _trace} = run(context, request(%{"style" => "rock"}))
      assert {:ok, reply} = measured
      assert reply =~ "measured from real drummers"

      {derived, _trace} = run(context, request(%{"style" => "lofi"}))
      assert {:ok, reply} = derived
      assert reply =~ "derived from hiphop"
    end

    # `dance` carries only 7 GMD files, under the harvest's 8-file floor, so
    # every one of its lanes falls back to the cross-style pool — "measured
    # from real drummers" would be true of the pooled numbers but not of
    # dance specifically, so it gets its own honest wording instead.
    test "a fully-pooled style says so rather than claiming to be measured", context do
      {result, _trace} = run(context, request(%{"style" => "dance"}))

      assert {:ok, reply} = result
      assert reply =~ "too few dance recordings to measure on their own"
      refute reply =~ "measured from real drummers"
    end
  end

  describe "note writes" do
    test "every note carries the eight fields in Live's canonical order", context do
      {_result, trace} = run(context, request(%{"humanize" => 0.0}))

      assert [[track, slot | fields]] = datagrams(trace, "/live/clip/add/notes_extended")
      assert track == 3
      assert slot == 0
      assert rem(length(fields), 8) == 0

      [pitch, start, duration, velocity, mute, probability, deviation, release] =
        Enum.take(fields, 8)

      assert pitch == 36
      assert start == 0.0
      assert duration > 0.0
      assert velocity > 1.0
      assert mute == 0
      assert probability == 1.0
      assert deviation == 0.0
      assert release == 64.0
    end

    # 44 bytes of header plus 40 per note against this Mac's `maxdgram` of
    # 9,216 caps a datagram at 229 notes. The chunker's job is that no datagram
    # it emits can be dropped by the OS, which is arithmetic rather than a wire
    # measurement — so the arithmetic is what the test asserts.
    test "a dense lane chunks, and no datagram exceeds the ceiling", context do
      dense =
        kick_part(%{
          "role" => "Hats",
          "pitch" => 42,
          "pattern" => String.duplicate("x", 32),
          "resolution" => "1/32"
        })

      {result, trace} = run(context, request(%{"bars" => 16, "parts" => [dense]}))

      assert {:ok, reply} = result
      assert reply =~ "512 notes"
      # The whole point of the dense case: three read-back windows, and every
      # one of them has to confirm — a float32-truncation false alarm on any
      # single window would report "could not confirm" here.
      assert reply =~ "Read-back: every note confirmed in Live."

      chunks = datagrams(trace, "/live/clip/add/notes_extended")
      assert length(chunks) == 3

      for args <- chunks do
        notes = div(length(args) - 2, 8)
        assert notes <= 200
        assert byte_size(Message.encode("/live/clip/add/notes_extended", args)) <= 9_216
      end

      assert Enum.sum(Enum.map(chunks, &div(length(&1) - 2, 8))) == 512
    end

    # The boundary itself. One bar of 1/32 is 32 steps, so a 32-step pattern
    # over 8 bars puts the note count under the writer's direct control: 25
    # hits per bar is exactly the chunk size, and 26 is one chunk past it.
    test "the chunk boundary falls between 200 notes and 208", context do
      at_limit = String.duplicate("x", 25) <> String.duplicate("-", 7)
      over = String.duplicate("x", 26) <> String.duplicate("-", 6)

      {_result, trace} =
        run(
          context,
          request(%{
            "bars" => 8,
            "parts" => [kick_part(%{"pattern" => at_limit, "resolution" => "1/32"})]
          })
        )

      assert [args] = datagrams(trace, "/live/clip/add/notes_extended")
      assert div(length(args) - 2, 8) == 200

      {_result, trace} =
        run(
          context,
          request(%{
            "bars" => 8,
            "parts" => [kick_part(%{"pattern" => over, "resolution" => "1/32"})]
          })
        )

      assert [first, second] = datagrams(trace, "/live/clip/add/notes_extended")
      assert div(length(first) - 2, 8) == 200
      assert div(length(second) - 2, 8) == 8
    end
  end

  describe "guards" do
    test "an occupied slot is refused before anything is created", context do
      {result, trace} =
        run(
          context,
          request(%{"parts" => [kick_part(%{"track" => 1})]}),
          live(%{
            clips: %{{1, 0} => %{name: "Taken", notes: []}}
          })
        )

      assert {:error, message} = result
      assert message =~ "already holds a clip"
      assert message =~ "Nothing was written and no track was created."

      refute "/live/song/create_midi_track" in addresses(trace)
      refute "/live/clip_slot/create_clip" in addresses(trace)
      refute "/live/clip/add/notes_extended" in addresses(trace)
    end

    test "an audio track is refused before anything is created", context do
      {result, trace} = run(context, request(%{"parts" => [kick_part(%{"track" => 0})]}))

      assert {:error, message} = result
      assert message =~ "not a MIDI track"
      refute "/live/clip_slot/create_clip" in addresses(trace)
    end

    test "a group track is refused by name", context do
      {result, _trace} = run(context, request(%{"parts" => [kick_part(%{"track" => 2})]}))

      assert {:error, message} = result
      assert message =~ "group track"
    end

    # The `generate_audio` review lesson: the scene guard has to run on the
    # branch that creates its own track too, or the most ordinary call renders,
    # creates, and only then has Live refuse.
    test "a scene-less set is refused on the new-track branch as well", context do
      {result, trace} = run(context, request(), live(%{scenes: 0}))

      assert {:error, message} = result
      assert message =~ "no scenes"
      assert message =~ "create_scene"
      refute "/live/song/create_midi_track" in addresses(trace)
    end

    test "a slot past the last scene names the highest one", context do
      {result, _trace} = run(context, request(%{"clip_slot" => 12}))

      assert {:error, message} = result
      assert message =~ "past the last scene"
      assert message =~ "highest slot is 7"
    end

    # Compilation is pure and runs first, so a bad pattern in the second part
    # refuses while Live is still untouched.
    test "two parts sharing an explicit track cost no datagram at all", context do
      params =
        request(%{
          "parts" => [
            kick_part(%{"track" => 1}),
            kick_part(%{"role" => "Snare", "track" => 1})
          ]
        })

      {result, trace} = run(context, params)

      assert {:error, message} = result
      assert message =~ "Two parts both target track 1"
      assert trace == []
    end

    test "a pattern that cannot compile costs no datagram at all", context do
      params =
        request(%{"parts" => [kick_part(), kick_part(%{"role" => "Snare", "pattern" => "x-o-"})]})

      {result, trace} = run(context, params)

      assert {:error, message} = result
      assert message =~ "Part \"Snare\""
      assert message =~ "not a step character"
      refute "/live/song/get/num_scenes" in addresses(trace)
      assert trace == []
    end
  end

  describe "instruments" do
    test "a loaded instrument is named in the reply", context do
      params = request(%{"parts" => [kick_part(%{"instrument_uri" => "query:Drums#Kit"})]})
      {result, trace} = run(context, params)

      assert {:ok, reply} = result
      assert reply =~ "playing Loaded Device"
      refute reply =~ "Silent until a device"
      assert "/live/browser/load_item" in addresses(trace)
    end

    # The notes are the material. A failed load leaves a recoverable silent
    # track; refusing would throw the composition away with it.
    test "a failed load still writes the notes and names the silent track", context do
      params = request(%{"parts" => [kick_part(%{"instrument_uri" => "query:Nope"})]})
      {result, trace} = run(context, params, live(%{load: {:error, "No such item"}}))

      assert {:ok, reply} = result
      assert reply =~ "with no instrument (the load failed)"
      assert reply =~ "Silent until a device is on track 3"
      assert "/live/clip/add/notes_extended" in addresses(trace)
    end

    test "a part with no instrument_uri says the track is silent", context do
      {result, _trace} = run(context, request())

      assert {:ok, reply} = result
      assert reply =~ "with no instrument yet"
      assert reply =~ "search_library"
    end

    # An existing track may already carry a device — this call just didn't
    # load one. Claiming silence here would be a guess, not an observation.
    test "a part with no instrument_uri on an existing track claims nothing about silence",
         context do
      {result, _trace} = run(context, request(%{"parts" => [kick_part(%{"track" => 1})]}))

      assert {:ok, reply} = result
      refute reply =~ "with no instrument yet"
      refute reply =~ "Silent until a device"
    end
  end

  describe "the read-back" do
    test "confirms the notes and reports the expression fields as sent", context do
      {result, trace} = run(context, request(%{"parts" => [kick_part(%{"pattern" => "Xg-x"})]}))

      assert {:ok, reply} = result
      assert reply =~ "Read-back: every note confirmed in Live."
      assert reply =~ "Per-note chance and velocity spread came back as sent"
      assert "/live/clip/get/notes_extended" in addresses(trace)
    end

    # The ⚠️ `priv/AbletonOSC/API.md` carries: the fields were measured to be
    # *accepted*, never read back. If Live turns out to discard them, the reply
    # says so rather than claiming a per-note chance that is not there.
    test "says plainly when Live returns defaults for the expression fields", context do
      {result, _trace} =
        run(
          context,
          request(%{"parts" => [kick_part(%{"pattern" => "Xg-x"})]}),
          live(%{drops_expression: true})
        )

      assert {:ok, reply} = result
      assert reply =~ "Live returned default values for per-note chance and velocity spread"
      assert reply =~ "timing and velocity shape did"
    end

    test "a clip that never answers is reported as unconfirmed, not as done", context do
      {result, _trace} = run(context, request(), live(%{swallow_notes: true}))

      assert {:ok, reply} = result
      assert reply =~ "Read-back: could not confirm \"Kick\""
      assert reply =~ "The notes were sent and most likely landed"
      assert reply =~ "get_clip_notes"
    end

    # A window whose reply does not match what it asked for is treated as a
    # straggler and reissued exactly once — the same defence the rest of the
    # codebase applies to an echoed index, which range arguments cannot carry.
    test "a mismatched window is reissued once before being given up on", context do
      {_result, trace} = run(context, request(), live(%{swallow_notes: true}))

      assert Enum.count(addresses(trace), &(&1 == "/live/clip/get/notes_extended")) == 2
    end

    # The straggler recovers this time: the first reply is about a different
    # (empty) query, but the reissue lands on the real one and the whole
    # request still reports confirmed — the reissue-once defence exists for
    # exactly this case, not only for the "stale twice" one above.
    test "a mismatched window that answers correctly on reissue still confirms", context do
      {result, trace} =
        run(context, request(), live(%{stale_reads_left: 1}))

      assert {:ok, reply} = result
      assert reply =~ "Read-back: every note confirmed in Live."
      assert Enum.count(addresses(trace), &(&1 == "/live/clip/get/notes_extended")) == 2
    end
  end

  describe "readback_windows/3" do
    test "a small clip reads whole, in one window" do
      starts = [0.0, 1.0, 2.0, 3.0]
      assert [{low, span, expected}] = MidiParts.readback_windows(starts, 4.0)

      assert low < 0.0
      assert low + span > 4.0
      assert expected == starts
    end

    test "a dense clip splits into windows of at most the limit" do
      starts = Enum.map(0..511, &(&1 * 0.125))
      windows = MidiParts.readback_windows(starts, 64.0)

      assert length(windows) == 3
      assert Enum.all?(windows, fn {_low, _span, expected} -> length(expected) <= 200 end)
      assert windows |> Enum.flat_map(fn {_l, _s, expected} -> expected end) == starts
    end

    # The getter matches notes by their *start*, so an edge landing on one would
    # either drop it or return it in both windows.
    test "window edges never coincide with a written start" do
      starts = Enum.map(0..511, &(&1 * 0.125))
      windows = MidiParts.readback_windows(starts, 64.0)

      for {low, span, _expected} <- windows do
        refute Enum.any?(starts, &(&1 == low))
        refute Enum.any?(starts, &(&1 == low + span))
      end
    end

    test "windows tile the clip without a gap between them" do
      starts = Enum.map(0..511, &(&1 * 0.125))
      windows = MidiParts.readback_windows(starts, 64.0)

      windows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{low, span, _e}, {next_low, _s, _n}] ->
        assert_in_delta low + span, next_low, 1.0e-9
      end)
    end

    # Notes sharing a start must share a window: splitting them would make both
    # windows disagree with what they asked for.
    test "identical starts are never split across windows" do
      starts = List.duplicate(0.0, 250) ++ List.duplicate(1.0, 10)
      windows = MidiParts.readback_windows(starts, 4.0)

      assert [{_low, _span, first} | _rest] = windows
      assert length(first) == 250
    end
  end

  describe "cross-field validation" do
    test "two parts may not share a role" do
      assert {:error, message} =
               MidiParts.validate(request(%{"parts" => [kick_part(), kick_part()]}))

      assert message =~ "Two parts are both called \"Kick\""
    end

    # Two parts targeting the same explicit track would both write into the
    # same clip_slot — Live rejects the second create_clip, but the notes
    # still get appended onto the first part's clip, merging and misnaming it
    # while the reply would have claimed two clips landed.
    test "two parts may not share an explicit track" do
      params =
        request(%{
          "parts" => [
            kick_part(%{"track" => 1}),
            kick_part(%{"role" => "Snare", "track" => 1})
          ]
        })

      assert {:error, message} = MidiParts.validate(params)
      assert message =~ "Two parts both target track 1"
    end

    test "a drum part needs a pitch and a pattern" do
      assert {:error, no_pitch} =
               MidiParts.validate(request(%{"parts" => [Map.delete(kick_part(), "pitch")]}))

      assert no_pitch =~ "needs a pitch"

      assert {:error, no_pattern} =
               MidiParts.validate(request(%{"parts" => [Map.delete(kick_part(), "pattern")]}))

      assert no_pattern =~ "needs a pattern"
    end

    test "a bass part takes a pattern or a relationship, never both and never neither" do
      both = %{
        "role" => "Bass",
        "type" => "bass",
        "pattern" => "x-x-",
        "relationship" => "lock",
        "roots" => [36]
      }

      assert {:error, message} = MidiParts.validate(request(%{"parts" => [both]}))
      assert message =~ "has both a pattern and a relationship"

      neither = %{"role" => "Bass", "type" => "bass", "roots" => [36]}
      assert {:error, message} = MidiParts.validate(request(%{"parts" => [neither]}))
      assert message =~ "needs either a pattern or a relationship"
    end

    test "a relationship needs a drum part to follow" do
      bass = %{"role" => "Bass", "type" => "bass", "relationship" => "lock", "roots" => [36]}

      assert {:error, message} = MidiParts.validate(request(%{"parts" => [bass]}))
      assert message =~ "has no drum part"
    end

    test "follows must name a drum part in the same request" do
      parts = [
        kick_part(),
        %{
          "role" => "Bass",
          "type" => "bass",
          "relationship" => "lock",
          "roots" => [36],
          "follows" => "Congas"
        }
      ]

      assert {:error, message} = MidiParts.validate(request(%{"parts" => parts}))
      assert message =~ "follows \"Congas\""
      assert message =~ "\"Kick\""
    end

    test "follows defaults to the lowest-pitched drum part" do
      parts = [
        kick_part(%{"role" => "Hats", "pitch" => 42}),
        kick_part(%{"role" => "Kick", "pitch" => 36}),
        %{"role" => "Bass", "type" => "bass", "relationship" => "lock", "roots" => [36]}
      ]

      assert {:ok, request} = MidiParts.validate(request(%{"parts" => parts}))
      bass = Enum.find(request.parts, &(&1.type == "bass"))
      assert bass.follows == "Kick"
    end

    test "more parts than one call carries is refused" do
      parts = for index <- 1..9, do: kick_part(%{"role" => "Part #{index}"})

      assert {:error, message} = MidiParts.validate(request(%{"parts" => parts}))
      assert message =~ "9 parts were asked for"
      assert message =~ "limit is 8"
    end

    test "a style with no profile names the ones that exist" do
      assert {:error, message} = MidiParts.validate(request(%{"style" => "polka"}))
      assert message =~ "has no profile"
      assert message =~ "boom_bap"
    end
  end

  describe "the session" do
    test "an unknown tempo refuses before any OSC", context do
      stop_supervised!(FakeSessionState)
      start_supervised!({FakeSessionState, song: [tempo: nil]})

      {result, trace} = run(context, request())

      assert {:error, message} = result
      assert message =~ "does not know the session tempo"
      assert message =~ "Nothing was written."
      assert trace == []
    end

    test "an unusable time signature refuses before any OSC", context do
      stop_supervised!(FakeSessionState)
      start_supervised!({FakeSessionState, song: [time_sig_denominator: 3]})

      {result, trace} = run(context, request())

      assert {:error, message} = result
      assert message =~ "usable time signature"
      assert trace == []
    end
  end

  defp index(list, value), do: Enum.find_index(list, &(&1 == value))
end
