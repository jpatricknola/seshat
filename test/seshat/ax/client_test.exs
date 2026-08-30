defmodule Seshat.AX.ClientTest do
  @moduledoc """
  The native process protocol, exercised against fixture executables.

  Nothing here calls macOS Accessibility, and nothing here runs the *installed*
  helper: every test points `:ax_helper_path` at a small shell script it wrote
  itself. That is the whole layer this suite can reach — whether Live's
  identifiers, popup actions, focus restoration and Settings cleanup work is a
  live check (`docs/smoke_tests/auto/audio-output.md`), because no test rig can
  stand in for Live's own UI.
  """

  use ExUnit.Case, async: false

  alias Seshat.AX.Client

  setup do
    # A short outer deadline so the timeout path costs milliseconds instead of
    # the real five seconds. The default itself is asserted below.
    Application.put_env(:seshat, :ax_call_timeout, 300)
    on_exit(fn -> Application.delete_env(:seshat, :ax_call_timeout) end)

    :ok
  end

  # A fixture executable standing in for `seshat-ax`. `body` is shell, so a test
  # can control stdout, stderr, exit status and duration independently — which
  # is exactly the surface `Client` has to defend against.
  defp helper(context, body) do
    path = Path.join(context.tmp_dir, "seshat-ax")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)

    Application.put_env(:seshat, :ax_helper_path, path)
    on_exit(fn -> Application.delete_env(:seshat, :ax_helper_path) end)

    path
  end

  defp emits(json, status \\ 0) do
    "printf '%s\\n' '#{json}'\nexit #{status}"
  end

  # Takes the AX lock in another process and returns once it is actually held,
  # so a test's queue precondition is observed rather than timed. The returned
  # function releases it and waits for the holder to exit.
  defp hold_ax_lock do
    parent = self()

    holder =
      spawn(fn ->
        :global.trans(
          Client.lock_id(),
          fn ->
            send(parent, :ax_lock_held)

            receive do
              :release -> :ok
            end
          end,
          [node()]
        )
      end)

    assert_receive :ax_lock_held, 1_000

    reference = Process.monitor(holder)

    {holder,
     fn ->
       send(holder, :release)
       assert_receive {:DOWN, ^reference, :process, ^holder, _}, 1_000
     end}
  end

  describe "helper_path/0" do
    test "defaults to the stable installed location" do
      Application.delete_env(:seshat, :ax_helper_path)

      assert Client.helper_path() == Path.expand("~/.seshat/bin/seshat-ax")
    end

    @tag :tmp_dir
    test "is overridable, which is how the suite avoids the real helper", context do
      path = helper(context, emits(~s({"ok":true,"protocol_version":2})))

      assert Client.helper_path() == path
    end
  end

  describe "call_timeout/0" do
    # The number matters: a failure has to land inside the same 5-second budget
    # the tool call is judged against, not merely "eventually".
    test "defaults to the 5 seconds the tool budget allows" do
      Application.delete_env(:seshat, :ax_call_timeout)

      assert Client.call_timeout() == 5_000
    end
  end

  describe "list_outputs/0" do
    @tag :tmp_dir
    test "decodes the current selection and every choice", context do
      helper(
        context,
        emits(
          ~s({"ok":true,"current":"Use System: 25 AirPods","devices":["No Device","Use System Device","MacBook Pro Speakers"],"elapsed_ms":412,"protocol_version":2})
        )
      )

      assert {:ok, result} = Client.list_outputs()
      assert result.current == "Use System: 25 AirPods"
      assert result.devices == ["No Device", "Use System Device", "MacBook Pro Speakers"]
      assert result.elapsed_ms == 412
    end

    @tag :tmp_dir
    test "asks the helper for list-outputs and nothing else", context do
      helper(
        context,
        ~s(printf '{"ok":true,"current":"%s","devices":[],"protocol_version":2}' "$*")
      )

      assert {:ok, %{current: "list-outputs"}} = Client.list_outputs()
    end

    # A success whose payload is the wrong shape is a helper that has stopped
    # speaking this protocol, not a device list of zero.
    @tag :tmp_dir
    test "rejects a success carrying no current value", context do
      helper(context, emits(~s({"ok":true,"devices":[],"protocol_version":2})))

      assert {:error, %{code: :ax_failure}} = Client.list_outputs()
    end

    @tag :tmp_dir
    test "rejects a device list that is not all strings", context do
      helper(context, emits(~s({"ok":true,"current":"X","devices":[1,2],"protocol_version":2})))

      assert {:error, %{code: :ax_failure}} = Client.list_outputs()
    end
  end

  describe "set_output/1" do
    @tag :tmp_dir
    test "decodes the observed previous and current values", context do
      helper(
        context,
        emits(
          ~s({"ok":true,"previous":"MacBook Pro Speakers","current":"Use System: 25 AirPods","elapsed_ms":980,"protocol_version":2})
        )
      )

      assert {:ok, result} = Client.set_output("Use System Device")
      assert result.previous == "MacBook Pro Speakers"
      assert result.current == "Use System: 25 AirPods"
    end

    # The device name is user-influenced text. It travels as one argv entry, so
    # no shell ever sees it: a name full of quotes and semicolons arrives at the
    # helper intact and means nothing else on the way.
    @tag :tmp_dir
    test "passes the device name through as one argv entry, unshelled", context do
      helper(
        context,
        ~s(printf '{"ok":true,"previous":"old","current":"%s","protocol_version":2}' "$3")
      )

      hostile = ~s[Device $(touch /tmp/seshat-pwned); echo x]

      assert {:ok, %{current: ^hostile}} = Client.set_output(hostile)
      refute File.exists?("/tmp/seshat-pwned")
    end

    @tag :tmp_dir
    test "rejects a success missing the read-back value", context do
      helper(context, emits(~s({"ok":true,"previous":"old","protocol_version":2})))

      assert {:error, %{code: :ax_failure}} = Client.set_output("Anything")
    end
  end

  describe "convert/1" do
    @tag :tmp_dir
    test "decodes the window counts either side of the pick", context do
      helper(
        context,
        emits(
          ~s({"ok":true,"command":"Convert Melody to New MIDI Track","windows_before":1,"windows_after":1,"elapsed_ms":870,"protocol_version":2})
        )
      )

      assert {:ok, result} = Client.convert("Convert Melody to New MIDI Track")
      assert result.windows_before == 1
      assert result.windows_after == 1
      assert result.elapsed_ms == 870
    end

    @tag :tmp_dir
    test "asks the helper for convert with the title as one argv entry", context do
      helper(
        context,
        ~s(printf '{"ok":true,"windows_before":1,"windows_after":1,"command":"%s","protocol_version":2}' "$*")
      )

      assert {:ok, _result} = Client.convert("Convert Drums to New MIDI Track")
    end

    # The window counts are the only evidence the caller has that Live converted
    # rather than raising a dialog, so a reply without them is malformed rather
    # than an optimistic success.
    @tag :tmp_dir
    test "rejects a success carrying no window counts", context do
      helper(context, emits(~s({"ok":true,"command":"Convert Melody","protocol_version":2})))

      assert {:error, %{code: :ax_failure}} = Client.convert("Convert Melody to New MIDI Track")
    end

    # `command_unavailable` is the *ordinary* answer for a selection Live will
    # not convert — Live's own menu validation said no — so it has to reach the
    # caller as its own code rather than collapsing into the generic failure.
    @tag :tmp_dir
    test "command_unavailable survives as its own code", context do
      helper(
        context,
        emits(
          ~s({"ok":false,"code":"command_unavailable","message":"Live has it disabled.","protocol_version":2}),
          9
        )
      )

      assert {:error, %{code: :command_unavailable, message: message}} =
               Client.convert("Convert Melody to New MIDI Track")

      assert message == "Live has it disabled."
    end

    # The protocol stays closed at the helper, not here: a title outside its
    # three compiled-in strings is refused without Accessibility being touched,
    # and that refusal has to reach the caller intact.
    @tag :tmp_dir
    test "unknown_command survives as its own code", context do
      helper(
        context,
        emits(
          ~s({"ok":false,"code":"unknown_command","message":"Only three commands.","protocol_version":2}),
          10
        )
      )

      assert {:error, %{code: :unknown_command}} = Client.convert("Open Preferences")
    end
  end

  describe "structured errors" do
    for {code, atom, status} <- [
          {"permission_required", :permission_required, 2},
          {"live_not_running", :live_not_running, 3},
          {"settings_unavailable", :settings_unavailable, 4},
          {"device_not_found", :device_not_found, 5},
          {"ax_failure", :ax_failure, 6},
          {"timeout", :timeout, 7}
        ] do
      @tag :tmp_dir
      test "#{code} becomes a #{atom} failure", context do
        helper(
          context,
          emits(
            ~s({"ok":false,"code":"#{unquote(code)}","message":"Native said so.","protocol_version":2}),
            unquote(status)
          )
        )

        assert {:error, %{code: unquote(atom), message: message}} = Client.list_outputs()
        assert is_binary(message) and message != ""
      end
    end

    # A code this Seshat has never heard of must not mint an atom from helper
    # output; it collapses to the generic failure instead.
    @tag :tmp_dir
    test "an unrecognised code collapses to ax_failure", context do
      helper(
        context,
        emits(~s({"ok":false,"code":"invented_here","message":"Odd.","protocol_version":2}), 6)
      )

      assert {:error, %{code: :ax_failure, message: "Odd."}} = Client.list_outputs()
    end

    @tag :tmp_dir
    test "permission failures name the install task rather than the native wording", context do
      helper(
        context,
        emits(
          ~s({"ok":false,"code":"permission_required","message":"Not trusted.","protocol_version":2}),
          2
        )
      )

      assert {:error, %{code: :permission_required, message: message}} = Client.list_outputs()
      assert message =~ "mix ax.install"
      assert message =~ "Accessibility"
    end

    @tag :tmp_dir
    test "a rejected device carries the names that do exist", context do
      helper(
        context,
        emits(
          ~s({"ok":false,"code":"device_not_found","message":"No such output.","current":"Speakers","devices":["Speakers","Use System Device"],"protocol_version":2}),
          5
        )
      )

      assert {:error, failure} = Client.set_output("Nope")
      assert failure.devices == ["Speakers", "Use System Device"]
      assert failure.current == "Speakers"
    end
  end

  describe "a helper that stops speaking the protocol" do
    @tag :tmp_dir
    test "non-JSON output is malformed, not relayed", context do
      helper(context, "echo 'something went wrong'\nexit 1")

      assert {:error, %{code: :ax_failure, message: message}} = Client.list_outputs()
      refute message =~ "something went wrong"
      assert message =~ "mix ax.install"
    end

    @tag :tmp_dir
    test "no output at all is malformed", context do
      helper(context, "exit 0")

      assert {:error, %{code: :ax_failure}} = Client.list_outputs()
    end

    # The exit status is half the protocol. A payload claiming success while the
    # process failed (or the reverse) is a helper in an unknown state, and
    # believing either half would be a fabricated result.
    @tag :tmp_dir
    test "a success payload with a non-zero exit status is malformed", context do
      helper(context, emits(~s({"ok":true,"current":"X","devices":[],"protocol_version":2}), 3))

      assert {:error, %{code: :ax_failure}} = Client.list_outputs()
    end

    @tag :tmp_dir
    test "a failure payload with a zero exit status is malformed", context do
      helper(
        context,
        emits(~s({"ok":false,"code":"ax_failure","message":"Hmm.","protocol_version":2}), 0)
      )

      assert {:error, %{code: :ax_failure, message: message}} = Client.list_outputs()
      assert message =~ "unreadable"
    end

    @tag :tmp_dir
    test "an oversized response is refused rather than buffered", context do
      helper(context, "dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' 'x' 2>/dev/null")

      assert {:error, %{code: :ax_failure, message: message}} = Client.list_outputs()
      assert message =~ "more data than its protocol allows"
    end

    @tag :tmp_dir
    test "a different protocol version is named, not guessed at", context do
      helper(context, emits(~s({"ok":true,"current":"X","devices":[],"protocol_version":99})))

      assert {:error, %{code: :version_mismatch, message: message}} = Client.list_outputs()
      assert message =~ "99"
      assert message =~ "mix ax.install"
    end

    @tag :tmp_dir
    test "a helper that never answers is bounded by the outer deadline", context do
      helper(context, "sleep 30")

      started = System.monotonic_time(:millisecond)
      assert {:error, %{code: :timeout, message: message}} = Client.list_outputs()
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 2_000
      assert message =~ "nothing is known to have changed"
    end
  end

  describe "a missing installation" do
    test "names the path and the task that would create it" do
      Application.put_env(:seshat, :ax_helper_path, "/nonexistent/seshat-ax")
      on_exit(fn -> Application.delete_env(:seshat, :ax_helper_path) end)

      assert {:error, %{code: :helper_missing, message: message}} = Client.list_outputs()
      assert message =~ "/nonexistent/seshat-ax"
      assert message =~ "mix ax.install"
    end

    @tag :tmp_dir
    test "a path that exists but cannot be executed fails honestly", context do
      path = Path.join(context.tmp_dir, "seshat-ax")
      File.write!(path, "not an executable")
      File.chmod!(path, 0o644)

      Application.put_env(:seshat, :ax_helper_path, path)
      on_exit(fn -> Application.delete_env(:seshat, :ax_helper_path) end)

      assert {:error, %{code: :ax_failure, message: message}} = Client.list_outputs()
      assert message =~ "mix ax.install"
    end
  end

  describe "serialization" do
    # Two clients must not drive the same Settings popup at once — the second
    # would press a chooser the first opened, or read a value mid-transition.
    @tag :tmp_dir
    test "two concurrent calls cannot overlap", context do
      helper(
        context,
        "sleep 0.3\n" <> emits(~s({"ok":true,"current":"X","devices":[],"protocol_version":2}))
      )

      Application.put_env(:seshat, :ax_call_timeout, 5_000)

      started = System.monotonic_time(:millisecond)

      [first, second] =
        [1, 2]
        |> Enum.map(fn _ -> Task.async(&Client.list_outputs/0) end)
        |> Task.await_many(5_000)

      elapsed = System.monotonic_time(:millisecond) - started

      assert {:ok, _} = first
      assert {:ok, _} = second
      # Serialized: two 300ms calls take 600ms. Overlapped, they would take 300.
      assert elapsed >= 600
    end

    # The floor above proves calls do not overlap. On its own it also permits
    # the defect the 2026-08-27 PR review found: a queued caller used to wait
    # out the call ahead of it *outside* any deadline and then start a fresh
    # full budget, so two callers could take nearly two budgets between them.
    # This pins the ceiling that makes the floor safe.
    #
    # The queue precondition is established by holding the lock and waiting for
    # the holder to say so, never by sleeping long enough to assume it: the
    # repository's testing rules rule out `Process.sleep/1` as a synchroniser
    # (2026-08-27 PR review).
    @tag :tmp_dir
    test "a queued call is bounded by its own budget, not the one ahead of it", context do
      helper(context, emits(~s({"ok":true,"current":"X","devices":[],"protocol_version":2})))

      Application.put_env(:seshat, :ax_call_timeout, 400)
      on_exit(fn -> Application.delete_env(:seshat, :ax_call_timeout) end)

      {_holder, release} = hold_ax_lock()

      started = System.monotonic_time(:millisecond)
      queued = Client.list_outputs()
      elapsed = System.monotonic_time(:millisecond) - started

      assert {:error, %{code: :timeout}} = queued

      # One budget plus scheduling slack. Before the fix this waited for the
      # holder instead — which, with a holder that never releases, means the
      # call never returns at all.
      assert elapsed < 700, "queued caller took #{elapsed}ms, expected under one 400ms budget"

      release.()
    end

    # The other half of deadline-aware admission: a caller with nothing useful
    # left does not start a helper at all. Starting one would pull Live to the
    # front for a call already destined to time out.
    @tag :tmp_dir
    test "a caller that waits out its budget never starts the helper", context do
      helper(context, "touch #{context.tmp_dir}/ran\n" <> emits(~s({"ok":true})))

      Application.put_env(:seshat, :ax_call_timeout, 200)
      on_exit(fn -> Application.delete_env(:seshat, :ax_call_timeout) end)

      {_holder, release} = hold_ax_lock()

      assert {:error, %{code: :timeout}} = Client.list_outputs()

      refute File.exists?(Path.join(context.tmp_dir, "ran")),
             "the helper was started despite the call having no budget left"

      release.()
    end

    # The boundary the first version of the admission loop got wrong: it checked
    # the budget only when the lock attempt *failed*, so a lock released during
    # the final polling sleep was taken by a caller whose budget was already
    # gone — and the helper ran, taking Live's foreground for a call that could
    # not finish.
    #
    # Placing that window needs two things. The caller must have attempted the
    # lock before the release, or it is simply admitted early with a full budget
    # — `:ax_lock_poll_observer` makes that otherwise invisible state observable.
    # And the polling window must be wide enough that waking from it spends the
    # budget, which is what `:ax_lock_poll_ms` is for: at 300ms the caller wakes
    # with ~40ms left, where the shipped 25ms interval would be a race.
    @tag :tmp_dir
    test "a lock released inside the polling window still refuses a spent caller", context do
      helper(
        context,
        "touch #{context.tmp_dir}/ran\n" <>
          emits(~s({"ok":true,"current":"X","devices":[],"protocol_version":2}))
      )

      Application.put_env(:seshat, :ax_call_timeout, 340)
      Application.put_env(:seshat, :ax_lock_poll_ms, 300)
      Application.put_env(:seshat, :ax_lock_poll_observer, self())

      on_exit(fn ->
        Application.delete_env(:seshat, :ax_call_timeout)
        Application.delete_env(:seshat, :ax_lock_poll_ms)
        Application.delete_env(:seshat, :ax_lock_poll_observer)
      end)

      {_holder, release} = hold_ax_lock()

      caller = Task.async(&Client.list_outputs/0)

      # The failed attempt has happened and the caller is about to sleep for
      # 300ms. Releasing now means it wakes to a free lock and ~40ms left —
      # under the 50ms floor, so it must refuse rather than spawn.
      assert_receive :ax_lock_polling, 1_000
      release.()

      assert {:error, %{code: :timeout, message: message}} = Task.await(caller, 5_000)
      assert message =~ "Another audio-settings request"

      refute File.exists?(Path.join(context.tmp_dir, "ran")),
             "the helper was started after the lock freed with the budget already spent"

      # Prove the release above is part of the stimulus, not incidental cleanup:
      # a fresh-budget call must take the now-free lock and run immediately.
      # Without `release.()`, this call times out behind the holder and the test
      # fails even though the spent caller's timeout and absent marker still pass.
      assert {:ok, %{current: "X", devices: []}} = Client.list_outputs()
      assert File.exists?(Path.join(context.tmp_dir, "ran"))
    end

    # ...but the AX lock is its own, not the OSC undo lock. An audio-output
    # change is outside Live's undo history and has no reason to hold ordinary
    # OSC work behind it. Held deliberately rather than raced into, so this
    # asserts the two locks are distinct rather than that one happened to be
    # free.
    test "holding the AX lock leaves the OSC undo lock free" do
      parent = self()

      holder =
        spawn(fn ->
          :global.trans(
            Client.lock_id(),
            fn ->
              send(parent, :ax_lock_held)

              receive do
                :release -> :ok
              end
            end,
            [node()]
          )
        end)

      assert_receive :ax_lock_held, 1_000

      assert :taken =
               :global.trans({{Seshat.Tools.Handlers, :undo_step}, self()}, fn -> :taken end, [
                 node()
               ])

      send(holder, :release)
    end
  end

  describe "the execution boundary" do
    # The LOM-first rule is only durable if it is mechanical. `Seshat.AX.Client`
    # is the one module allowed to start a process, so a future tool cannot grow
    # a second UI-automation path without this failing — the same job
    # `vendored_addresses_test` does for the fork's address surface.
    #
    # `lib/mix/tasks/` is deliberately outside the scope: mix tasks run at a
    # human's request from a shell, not inside a model's tool call.
    #
    # The pattern is widened past `Port.open`/`:spawn_executable`/`System.cmd`
    # (PR review, 2026-08-27): `System.shell/2`, `:os.cmd/1` and
    # `:erlang.open_port/2` all start a process too and were invisible to the
    # narrower regex. The wildcard now covers all of `lib/` (so
    # `lib/seshat_web/**` is scanned too) rather than stopping at
    # `lib/seshat/**`, which exempted the web tree from a boundary nothing
    # about it is meant to be exempt from.
    #
    # There are **two** doors now, not one. `Seshat.Generation.StableAudio`
    # joined the list when audio generation shipped: rendering audio needs a
    # local model runtime, the BEAM cannot host one, and no OSC address or LOM
    # member can produce a WAV. It was added here deliberately rather than
    # worked around, which is the whole point of the list being exact — a third
    # entry has to be argued the same way, and the assertion below fails on any
    # file that is not one of these two.
    @process_doors ["lib/seshat/ax/client.ex", "lib/seshat/generation/stable_audio.ex"]

    test "only Seshat.AX.Client and Seshat.Generation.StableAudio may start a native process" do
      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&String.starts_with?(&1, "lib/mix/tasks/"))
        |> Enum.filter(fn path ->
          path not in @process_doors and
            File.read!(path) =~
              ~r/Port\.open|:spawn_executable|System\.cmd|System\.shell|:os\.cmd|:erlang\.open_port/
        end)

      assert offenders == [],
             """
             These modules execute a subprocess:

             #{Enum.join(offenders, "\n")}

             Only #{Enum.join(@process_doors, " and ")} are allowed to, so that
             the paths out of the BEAM stay auditable doors rather than a habit.
             If a new capability genuinely needs a native process, it belongs
             behind one of those modules' protocols — or, if it is genuinely a
             third kind of thing, it joins @process_doors in a commit that
             argues the case.
             """
    end

    # The converse: both named files must still *be* doors. A rename or a
    # rewrite that stopped spawning would leave a permanent exemption sitting in
    # the list, quietly licensing a future subprocess in a file nobody expects
    # to have one.
    test "every allowed door actually starts a process" do
      for path <- @process_doors do
        assert File.regular?(path), "#{path} is on the allow-list but does not exist"

        assert File.read!(path) =~
                 ~r/Port\.open|:spawn_executable|System\.cmd|System\.shell|:os\.cmd|:erlang\.open_port/,
               "#{path} is on the native-process allow-list but starts no process — remove it."
      end
    end
  end
end
