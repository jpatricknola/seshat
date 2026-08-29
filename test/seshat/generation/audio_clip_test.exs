defmodule Seshat.Generation.AudioClipTest do
  @moduledoc """
  The `generate_audio` workflow, with a scripted Ableton and a scripted backend.

  The test process plays Live: it answers every query the workflow sends, in
  arrival order, off a small mutable model of a session. That is what makes the
  ordering claims assertable — that no generation begins for a refused target,
  that no Live mutation precedes a successful file, and that nothing is reported
  as imported before it has been read back.
  """

  use ExUnit.Case, async: false

  alias Seshat.Generation.AudioClip
  alias Seshat.OSC.Transport
  alias Seshat.Test.FakeGenerationBackend
  alias Seshat.Test.FakeSessionState
  alias Seshat.Test.LiveDouble
  alias Seshat.Test.OSCSink

  setup do
    sink = start_supervised!({OSCSink, forward_to: self()})
    start_supervised!({Transport, send_port: OSCSink.port(sink), reply_port: 0})
    start_supervised!(FakeSessionState)

    root = Path.join(System.tmp_dir!(), "seshat-generated-#{System.unique_integer([:positive])}")
    Application.put_env(:seshat, :generated_root, root)

    on_exit(fn ->
      Application.delete_env(:seshat, :generated_root)
      File.rm_rf(root)
    end)

    FakeGenerationBackend.install()

    %{sink: sink, root: root}
  end

  # --- Playing Live ---
  #
  # `Seshat.Test.LiveDouble` answers the workflow's queries off a small mutable
  # session model and hands back the datagram trace in arrival order. It is
  # shared with the handler-level tests so both drive the same Ableton.

  defp run(context, params, live \\ nil) do
    LiveDouble.run(context.sink, live || LiveDouble.session(), fn ->
      AudioClip.generate(params)
    end)
  end

  defp addresses(trace), do: LiveDouble.addresses(trace)

  # --- Pure arithmetic ---

  describe "duration/2" do
    test "four bars of 4/4 at 124 BPM" do
      assert {:ok, duration} =
               AudioClip.duration(4, %{tempo: 124.0, numerator: 4, denominator: 4})

      assert duration.beats == 16.0
      assert_in_delta duration.seconds, 7.741935, 0.000001
      assert duration.target_frames == AudioClip.target_frames(duration.seconds)
    end

    # A beat is a quarter note whatever the denominator says, so 6/8 is three
    # beats to the bar and 3/4 is also three — the same duration at one tempo.
    test "the denominator changes beats per bar, not the definition of a beat" do
      assert {:ok, six_eight} =
               AudioClip.duration(1, %{tempo: 120.0, numerator: 6, denominator: 8})

      assert {:ok, three_four} =
               AudioClip.duration(1, %{tempo: 120.0, numerator: 3, denominator: 4})

      assert six_eight.beats == 3.0
      assert three_four.beats == 3.0
      assert six_eight.seconds == three_four.seconds
    end

    test "the schema's boundaries" do
      assert {:ok, one} = AudioClip.duration(1, %{tempo: 174.0, numerator: 4, denominator: 4})
      assert {:ok, sixteen} = AudioClip.duration(16, %{tempo: 60.0, numerator: 4, denominator: 4})

      assert sixteen.beats == 64.0
      assert sixteen.seconds == 64.0
      assert sixteen.target_frames == 64 * 44_100
      assert one.seconds < sixteen.seconds
    end

    # The runtime trims to int(round(seconds * 44100)) with Python's round,
    # which is half-to-even. Elixir's round/1 is half-away-from-zero, so a tie
    # would put the reported frame count one frame away from the file.
    test "target_frames/1 rounds ties the way Python does" do
      assert AudioClip.target_frames(0.5 / 44_100) == 0
      assert AudioClip.target_frames(1.5 / 44_100) == 2
      assert AudioClip.target_frames(2.5 / 44_100) == 2
      assert AudioClip.target_frames(3.5 / 44_100) == 4

      assert AudioClip.target_frames(1.0) == 44_100
      assert AudioClip.target_frames(0.0) == 0
    end
  end

  describe "prompt/2" do
    test "carries the session facts the model cannot see" do
      prompt =
        AudioClip.prompt("dusty lo-fi drum break", %{
          tempo: 124.0,
          numerator: 4,
          denominator: 4,
          key: "F Minor"
        })

      assert prompt == "dusty lo-fi drum break. 124 BPM, 4/4 time. In F Minor."
    end

    test "omits the key when the session has none" do
      prompt =
        AudioClip.prompt("warm pad bed", %{tempo: 92.5, numerator: 3, denominator: 4, key: nil})

      assert prompt == "warm pad bed. 92.5 BPM, 3/4 time."
    end
  end

  describe "slug/1" do
    test "keeps only characters that can never steer a path" do
      assert AudioClip.slug("Dusty Lo-Fi Drum Break") == "dusty-lo-fi-drum-break"
      assert AudioClip.slug("../../etc/passwd") == "etc-passwd"
      assert AudioClip.slug("  ") == "take"
      assert AudioClip.slug("🥁🥁") == "take"
      assert String.length(AudioClip.slug(String.duplicate("drums ", 40))) <= 40
    end
  end

  # --- Cross-field validation, before anything happens ---

  describe "validate/1" do
    test "a blank description is refused" do
      assert {:error, message} = AudioClip.validate(%{"description" => "   "})
      assert message =~ "blank"
      assert message =~ "nothing was generated"
    end

    test "an over-long description is refused with its length" do
      assert {:error, message} =
               AudioClip.validate(%{"description" => String.duplicate("a", 1_001)})

      assert message =~ "1001 characters"
      assert message =~ "limit is 1000"
    end

    test "an over-long negative prompt is refused" do
      assert {:error, message} =
               AudioClip.validate(%{
                 "description" => "drums",
                 "negative_prompt" => String.duplicate("a", 1_001)
               })

      assert message =~ "negative_prompt"
    end

    test "strength without variation_of is refused by name" do
      assert {:error, message} =
               AudioClip.validate(%{"description" => "drums", "strength" => 0.4})

      assert message =~ "strength only means something with variation_of"
    end

    test "strength with variation_of is accepted" do
      assert {:ok, request} =
               AudioClip.validate(%{
                 "description" => "drums",
                 "strength" => 0.4,
                 "variation_of" => %{"track" => 0, "clip_slot" => 0}
               })

      assert request.strength == 0.4
      assert request.variation == %{track: 0, clip_slot: 0}
    end

    test "strength defaults to 0.55" do
      assert {:ok, request} =
               AudioClip.validate(%{
                 "description" => "drums",
                 "variation_of" => %{"track" => 0, "clip_slot" => 0}
               })

      assert request.strength == 0.55
    end

    test "a variation cannot name a different destination track" do
      assert {:error, message} =
               AudioClip.validate(%{
                 "description" => "same but darker",
                 "track" => 1,
                 "variation_of" => %{"track" => 0, "clip_slot" => 0}
               })

      assert message =~ "track 1 conflicts with variation_of's source track 0"
      assert message =~ "Nothing was generated"
    end

    test "a redundant destination matching the variation source is accepted" do
      assert {:ok, request} =
               AudioClip.validate(%{
                 "description" => "same but darker",
                 "track" => 0,
                 "variation_of" => %{"track" => 0, "clip_slot" => 0}
               })

      assert request.track == request.variation.track
    end

    test "track_name alongside an existing track is refused" do
      assert {:error, message} =
               AudioClip.validate(%{
                 "description" => "drums",
                 "track" => 2,
                 "track_name" => "Gen Drums"
               })

      assert message =~ "track_name names a track this call would create"
      assert message =~ "track 2"
    end

    test "track_name alongside variation_of is refused" do
      assert {:error, message} =
               AudioClip.validate(%{
                 "description" => "drums",
                 "track_name" => "Gen Drums",
                 "variation_of" => %{"track" => 1, "clip_slot" => 0}
               })

      assert message =~ "variation_of already points at track 1"
    end

    test "bars outside 1..16 is refused even on a direct call" do
      assert {:error, message} = AudioClip.validate(%{"description" => "drums", "bars" => 0})
      assert message =~ "1 to 16"

      assert {:error, _} = AudioClip.validate(%{"description" => "drums", "bars" => 17})
    end

    test "bars defaults to 4" do
      assert {:ok, request} = AudioClip.validate(%{"description" => "drums"})
      assert request.bars == 4
    end
  end

  # --- Guards run before generation ---

  describe "target guards" do
    test "an occupied explicit slot is refused and names an empty one", context do
      {result, trace} =
        run(context, %{"description" => "drums", "track" => 0, "clip_slot" => 0})

      assert {:error, message} = result
      assert message =~ "Slot 0 on track 0 already holds a clip"
      assert message =~ "Slot 1 on that track is empty"
      assert message =~ "Nothing was generated"

      refute_received {:generate, _spec}
      refute "/live/clip_slot/create_audio_clip" in addresses(trace)
    end

    test "a MIDI track is refused before anything is generated", context do
      {result, trace} = run(context, %{"description" => "drums", "track" => 1})

      assert {:error, message} = result
      assert message =~ "is a MIDI track"

      refute_received {:generate, _spec}
      refute "/live/song/get/num_scenes" in addresses(trace)
    end

    test "a group track is refused before anything is generated", context do
      {result, _trace} = run(context, %{"description" => "drums", "track" => 2})

      assert {:error, message} = result
      assert message =~ "is a group track"

      refute_received {:generate, _spec}
    end

    test "a full track refuses rather than overwriting or creating a scene", context do
      full =
        LiveDouble.session()
        |> Map.put(:scenes, 2)
        |> Map.put(:clips, %{
          {0, 0} => %{audio?: true},
          {0, 1} => %{audio?: true}
        })

      {result, trace} = run(context, %{"description" => "drums", "track" => 0}, full)

      assert {:error, message} = result
      assert message =~ "already holds a clip"
      assert message =~ "Create a scene"

      refute_received {:generate, _spec}
      refute "/live/song/create_audio_track" in addresses(trace)
    end

    test "a clip_slot past the last scene is refused for a new track", context do
      {result, _trace} = run(context, %{"description" => "drums", "clip_slot" => 99})

      assert {:error, message} = result
      assert message =~ "past the last scene"
      assert message =~ "highest slot is 7"

      refute_received {:generate, _spec}
    end

    test "the first empty slot is found when clip_slot is omitted", context do
      {result, _trace} = run(context, %{"description" => "drums", "track" => 0})

      assert {:ok, generated} = result
      assert generated.clip_slot == 1
      assert generated.track == 0
    end
  end

  describe "the session mirror" do
    test "an unknown tempo refuses rather than guessing a duration", context do
      stop_supervised!(FakeSessionState)
      start_supervised!({FakeSessionState, song: [tempo: nil]})

      {result, _trace} = run(context, %{"description" => "drums"})

      assert {:error, message} = result
      assert message =~ "does not know the session tempo"

      refute_received {:generate, _spec}
    end

    test "an unsupported time signature denominator refuses", context do
      stop_supervised!(FakeSessionState)
      start_supervised!({FakeSessionState, song: [time_sig_denominator: 3]})

      {result, _trace} = run(context, %{"description" => "drums"})

      assert {:error, message} = result
      assert message =~ "usable time signature"

      refute_received {:generate, _spec}
    end
  end

  # --- The happy path ---

  describe "generating onto an existing track" do
    test "renders, imports, reads back and reports what Live said", context do
      {result, trace} = run(context, %{"description" => "dusty breakbeat", "track" => 0})

      assert {:ok, generated} = result

      assert_received {:generate, spec}
      assert spec.prompt == "dusty breakbeat. 124 BPM, 4/4 time. In F Minor."
      assert_in_delta spec.seconds, 7.741935, 0.000001
      assert spec.init_audio == nil
      assert spec.out_path == Path.join(context.root, generated.file)

      assert generated.track == 0
      assert generated.clip_slot == 1
      assert generated.bars == 4
      assert generated.beats == 16.0
      assert generated.key == "F Minor"
      assert generated.observed.length == 16.0
      assert generated.observed.looping == true
      assert generated.observed.warping == true
      refute generated.created_track?

      # The import carries a *basename*, never a path: the fork resolves it
      # under its own fixed root and refuses anything absolute.
      assert {"/live/clip_slot/create_audio_clip", [0, 1, name]} =
               Enum.find(trace, &(elem(&1, 0) == "/live/clip_slot/create_audio_clip"))

      assert name == generated.file
      refute String.contains?(name, "/")
    end

    test "the take is kept on disk with an owner-only root", context do
      {result, _trace} = run(context, %{"description" => "dusty breakbeat", "track" => 0})

      assert {:ok, generated} = result
      assert File.regular?(generated.path)

      assert {:ok, %File.Stat{mode: mode}} = File.stat(context.root)
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "the view follows only after the read-back confirms the clip", context do
      {result, trace} = run(context, %{"description" => "dusty breakbeat", "track" => 0})

      assert {:ok, _generated} = result

      names = addresses(trace)
      import_at = Enum.find_index(names, &(&1 == "/live/clip_slot/create_audio_clip"))
      readback_at = Enum.find_index(names, &(&1 == "/live/clip/get/file_path"))
      steer_at = Enum.find_index(names, &(&1 == "/live/view/set/selected_clip"))

      assert import_at < readback_at
      assert readback_at < steer_at
    end

    test "the clip is named after the material, not after the file", context do
      {result, trace} = run(context, %{"description" => "dusty breakbeat", "track" => 0})

      assert {:ok, generated} = result
      assert generated.clip_name == "dusty breakbeat"

      assert {"/live/clip/set/name", [0, 1, "dusty breakbeat"]} =
               Enum.find(trace, &(elem(&1, 0) == "/live/clip/set/name"))
    end

    test "an explicit seed is used and reported", context do
      {result, _trace} =
        run(context, %{"description" => "drums", "track" => 0, "seed" => 4242})

      assert {:ok, generated} = result
      assert generated.seed == 4242
      assert String.contains?(generated.file, "4242")

      assert_received {:generate, spec}
      assert spec.seed == 4242
    end

    test "a negative prompt reaches the backend", context do
      {result, _trace} =
        run(context, %{
          "description" => "drums",
          "track" => 0,
          "negative_prompt" => "vocals"
        })

      assert {:ok, _generated} = result
      assert_received {:generate, spec}
      assert spec.negative_prompt == "vocals"
    end
  end

  describe "generating onto a new track" do
    test "the track is created after the file exists, never before", context do
      {result, trace} =
        run(context, %{"description" => "dusty breakbeat", "track_name" => "Gen Drums"})

      assert {:ok, generated} = result
      assert generated.created_track?
      assert generated.track == 3
      assert generated.clip_slot == 0
      assert generated.track_name == "Gen Drums"

      assert {"/live/track/set/name", [3, "Gen Drums"]} =
               Enum.find(trace, &(elem(&1, 0) == "/live/track/set/name"))
    end

    test "a failed generation leaves no track and no file behind", context do
      FakeGenerationBackend.install({:error, "The Stable Audio runtime is not installed."})

      {result, trace} = run(context, %{"description" => "drums", "track_name" => "Gen Drums"})

      assert {:error, message} = result
      assert message =~ "not installed"

      refute "/live/song/create_audio_track" in addresses(trace)
      assert File.ls!(context.root) == []
    end

    # Slot 0 is only a slot if a scene exists. The explicit-clip_slot branch has
    # always checked; without the same check here the tool's most ordinary call
    # would render, create a track, and only then have Live refuse the import.
    test "a set with no scenes refuses before generating and before creating", context do
      live = Map.put(LiveDouble.session(), :scenes, 0)

      {result, trace} = run(context, %{"description" => "drums", "track_name" => "Gen"}, live)

      assert {:error, message} = result
      assert message =~ "This set has no scenes"
      assert message =~ "Nothing was generated and no track was created."

      refute_received {:generate, _spec}
      refute "/live/song/create_audio_track" in addresses(trace)

      # The refusal lands before `reserve_take/2`, so the managed root has not
      # even been created — which is stricter than "empty", not weaker.
      assert File.ls(context.root) in [{:ok, []}, {:error, :enoent}]
    end
  end

  describe "variation" do
    test "lands on the source's own track and passes the source through", context do
      live = put_in(LiveDouble.session().clips[{0, 0}][:path], nil)

      # The source has to be a real managed file, so write one and point the
      # session's clip at it.
      source = Path.join(context.root, "earlier-take.wav")
      File.mkdir_p!(context.root)
      File.write!(source, "RIFF")

      live = put_in(live.clips[{0, 0}][:path], source)

      {result, _trace} =
        run(
          context,
          %{
            "description" => "same but darker",
            "variation_of" => %{"track" => 0, "clip_slot" => 0},
            "strength" => 0.4
          },
          live
        )

      assert {:ok, generated} = result
      assert generated.track == 0
      assert generated.clip_slot == 1
      assert generated.variation == %{track: 0, clip_slot: 0, strength: 0.4}

      assert_received {:generate, spec}
      assert spec.init_audio == source
      assert spec.init_noise_level == 0.4
    end

    test "a source outside the managed root is refused", context do
      outside = Path.join(System.tmp_dir!(), "not-ours-#{System.unique_integer([:positive])}.wav")
      File.write!(outside, "RIFF")
      on_exit(fn -> File.rm(outside) end)

      live = put_in(LiveDouble.session().clips[{0, 0}][:path], outside)

      {result, _trace} =
        run(
          context,
          %{"description" => "darker", "variation_of" => %{"track" => 0, "clip_slot" => 0}},
          live
        )

      assert {:error, message} = result
      assert message =~ "outside Seshat's generated-audio folder"

      refute_received {:generate, _spec}
    end

    test "a managed source survives a symlinked generated root", context do
      real_root = context.root <> "-real"
      File.mkdir_p!(real_root)
      File.ln_s!(real_root, context.root)
      on_exit(fn -> File.rm_rf(real_root) end)

      source = Path.join(real_root, "earlier-take.wav")
      File.write!(source, "RIFF")

      # The fork realpaths the import name before handing it to Live, so its
      # file_path getter reports the target spelling, not the configured link.
      live = put_in(LiveDouble.session().clips[{0, 0}][:path], source)

      {result, _trace} =
        run(
          context,
          %{"description" => "darker", "variation_of" => %{"track" => 0, "clip_slot" => 0}},
          live
        )

      assert {:ok, generated} = result
      assert generated.variation.track == 0
      assert_received {:generate, spec}
      assert spec.init_audio == source
    end

    test "a MIDI clip is refused as a variation source", context do
      live = put_in(LiveDouble.session().clips[{0, 0}][:audio?], false)

      {result, _trace} =
        run(
          context,
          %{"description" => "darker", "variation_of" => %{"track" => 0, "clip_slot" => 0}},
          live
        )

      assert {:error, message} = result
      assert message =~ "not an audio clip"

      refute_received {:generate, _spec}
    end

    test "a clip naming no file is refused", context do
      live = put_in(LiveDouble.session().clips[{0, 0}][:path], "")

      {result, _trace} =
        run(
          context,
          %{"description" => "darker", "variation_of" => %{"track" => 0, "clip_slot" => 0}},
          live
        )

      assert {:error, message} = result
      assert message =~ "does not name a file"
    end
  end

  describe "failures after the file exists" do
    test "an import refusal keeps the take and says it was not imported", context do
      live = Map.put(LiveDouble.session(), :import, {:error, "clip slot already contains a clip"})

      {result, _trace} = run(context, %{"description" => "drums", "track" => 0}, live)

      assert {:error, message} = result
      assert message =~ "Ableton refused to import"
      assert message =~ "clip slot already contains a clip"
      assert message =~ "The generated take was kept at"

      assert [file] = File.ls!(context.root)
      assert String.ends_with?(file, ".wav")
    end

    # The read-back is the evidence, so a read-back that disagrees is a failure
    # even though the import said "ok" — and the view must not have moved.
    test "a clip that reads back as another file is not reported as success", context do
      live = Map.put(LiveDouble.session(), :import_path, "/Users/someone/Music/other.wav")

      {result, trace} = run(context, %{"description" => "drums", "track" => 0}, live)

      assert {:error, message} = result
      assert message =~ "reads back as"
      assert message =~ "other.wav"
      assert message =~ "The generated take was kept at"

      refute "/live/view/set/selected_clip" in addresses(trace)
    end

    test "a slot that reads back as not-audio is not reported as success", context do
      live = Map.put(LiveDouble.session(), :import_audio?, false)

      {result, trace} = run(context, %{"description" => "drums", "track" => 0}, live)

      assert {:error, message} = result
      assert message =~ "does not read back as an audio clip"

      refute "/live/view/set/selected_clip" in addresses(trace)
    end

    test "an import refusal on a track this call created reports the empty track", context do
      live = Map.put(LiveDouble.session(), :import, {:error, "Live said no"})

      {result, _trace} =
        run(context, %{"description" => "drums", "track_name" => "Gen Drums"}, live)

      assert {:error, message} = result
      assert message =~ "was created and is still there, empty"
    end

    # The other side of the line: once the import has replied "ok", Live has
    # returned a Clip and the created track is almost certainly holding it. A
    # message that still called the track empty would contradict the sentence
    # in front of it, which says the import succeeded.
    test "a read-back disagreement never calls the created track empty", context do
      live =
        LiveDouble.session()
        |> Map.put(:import_path, "/Users/someone/Music/other.wav")

      {result, _trace} =
        run(context, %{"description" => "drums", "track_name" => "Gen Drums"}, live)

      assert {:error, message} = result
      assert message =~ "reads back as"
      assert message =~ "was created and is still there."
      refute message =~ "still there, empty"
      assert message =~ "could not be confirmed"
      assert message =~ "get_clip_slots"
    end
  end

  # `Seshat.Generation.Backend`'s result type documents `path` as the reserved
  # path restated rather than assumed. This is the assertion that makes it a
  # contract instead of a comment.
  describe "a backend that wrote somewhere else" do
    test "is refused, and nothing is imported", context do
      elsewhere = Path.join(System.tmp_dir!(), "stray-#{System.unique_integer([:positive])}.wav")
      on_exit(fn -> File.rm(elsewhere) end)

      FakeGenerationBackend.install(fn spec ->
        File.write!(elsewhere, "RIFF stray")

        {:ok, %{path: elsewhere, seed: spec.seed, wall_ms: 10}}
      end)

      {result, trace} = run(context, %{"description" => "drums", "track" => 0})

      assert {:error, message} = result
      assert message =~ "reported writing"
      assert message =~ "but this take was reserved at"
      assert message =~ "Nothing was imported."

      refute "/live/clip_slot/create_audio_clip" in addresses(trace)

      # The empty reservation goes with it — importing it would have handed
      # Live a zero-byte file under a name that looks like a real take.
      assert File.ls!(context.root) == []
    end
  end

  describe "reserved names" do
    test "two takes with the same description, second and seed cannot collide", context do
      params = %{"description" => "drums", "track" => 0, "seed" => 7}

      {first, second} = same_second_pair(context, params)

      assert {:ok, one} = first
      assert {:ok, two} = second

      refute one.file == two.file
      assert Enum.sort(File.ls!(context.root)) == Enum.sort([one.file, two.file])
    end
  end

  # The exclusive-create collision this test exercises only happens when both
  # calls land inside the same whole UTC second, since that is the stem's
  # timestamp resolution — otherwise the two takes get different timestamps,
  # the `-1` suffix branch never runs, and `refute one.file == two.file` would
  # still pass without having tested anything. Retry until both calls are
  # observed inside one second rather than asserting on luck.
  defp same_second_pair(context, params, attempts \\ 20)

  defp same_second_pair(_context, _params, 0) do
    flunk("could not land two takes in the same UTC second after 20 attempts")
  end

  defp same_second_pair(context, params, attempts) do
    before = System.os_time(:second)
    {first, _} = run(context, params)
    {second, _} = run(context, params)

    if System.os_time(:second) == before do
      {first, second}
    else
      # Straddled a second boundary — both takes landed with different
      # timestamps and neither collided, so the pair proves nothing. Clear
      # them before retrying so a later success isn't sharing the directory
      # with this attempt's leftovers.
      File.rm_rf(context.root)
      same_second_pair(context, params, attempts - 1)
    end
  end
end
