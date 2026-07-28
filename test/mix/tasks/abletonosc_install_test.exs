defmodule Mix.Tasks.Abletonosc.InstallTest do
  @moduledoc """
  Exercises `mix abletonosc.install` against fixtures in a tmp dir, so the whole
  install is covered without writing to the user's real Remote Scripts directory.

  The task is the whole delivery mechanism for Seshat's fork of AbletonOSC —
  every `/live/browser/*`, `/live/return_track/*`, `/live/master/*` and
  song-structure address, plus the base-class listener fix. If it drops a file
  or leaves a stale one behind, those addresses go quietly unanswered (or worse,
  answer from old code) and the tools blame a missing install forever.
  Re-running it is also the documented fix for "my addresses stopped
  answering", so idempotence is a promise, not an implementation detail.

  The install is a wholesale directory replacement, which is what makes the
  stale-file case testable at all: plant a file the fork doesn't have, and it
  must be gone afterwards.
  """

  use ExUnit.Case, async: false

  @source "priv/AbletonOSC"

  setup_all do
    unless File.regular?(Path.join(@source, "manager.py")) do
      raise """
      #{@source} is empty — the AbletonOSC submodule isn't checked out.

          git submodule update --init

      Git worktrees don't populate submodules on creation, so you need this
      once per worktree.
      """
    end

    :ok
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "abletonosc_fixture_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)
    on_exit(fn -> Mix.shell(shell) end)

    {:ok, tmp: tmp}
  end

  describe "run/1" do
    test "installs fresh into a path that doesn't exist yet", %{tmp: tmp} do
      dir = Path.join(tmp, "AbletonOSC")

      Mix.Tasks.Abletonosc.Install.run([dir])

      assert File.regular?(Path.join(dir, "manager.py"))
      assert File.regular?(Path.join([dir, "abletonosc", "handler.py"]))

      # Seshat's own three handlers are the reason this task exists.
      for file <- ~w(browser.py return_track.py song_structure.py) do
        assert File.read!(Path.join([dir, "abletonosc", file])) ==
                 File.read!(Path.join([@source, "abletonosc", file])),
               "#{file} was not copied verbatim"
      end

      # pythonosc is vendored inside AbletonOSC and imported by osc_server —
      # a copy that flattened or skipped it would leave Live with a dead script.
      assert File.dir?(Path.join(dir, "pythonosc"))
    end

    test "leaves git bookkeeping and the fork's test suite behind", %{tmp: tmp} do
      dir = Path.join(tmp, "AbletonOSC")

      Mix.Tasks.Abletonosc.Install.run([dir])

      refute File.exists?(Path.join(dir, ".git"))
      refute File.exists?(Path.join(dir, ".github"))
      refute File.exists?(Path.join(dir, "tests"))
    end

    test "replaces an existing install wholesale", %{tmp: tmp} do
      dir = Path.join(tmp, "AbletonOSC")
      File.mkdir_p!(Path.join(dir, "abletonosc"))
      File.write!(Path.join(dir, "manager.py"), "# an old, patched manager\n")
      File.write!(Path.join([dir, "abletonosc", "handler.py"]), "# old handler\n")

      # An install carried forward from the patch-in-place era: a file the fork
      # no longer has, and a registration line for it in __init__.py.
      File.write!(Path.join([dir, "abletonosc", "track_listeners.py"]), "# stale override\n")

      File.write!(
        Path.join([dir, "abletonosc", "__init__.py"]),
        "from .track_listeners import TrackListenerHandler\n"
      )

      Mix.Tasks.Abletonosc.Install.run([dir])

      refute File.exists?(Path.join([dir, "abletonosc", "track_listeners.py"])),
             "a file the fork doesn't have survived the install"

      init = File.read!(Path.join([dir, "abletonosc", "__init__.py"]))
      refute init =~ "track_listeners", "the old __init__.py survived the install"
      assert init =~ "from .browser import BrowserHandler"

      assert File.read!(Path.join(dir, "manager.py")) ==
               File.read!(Path.join(@source, "manager.py"))
    end

    test "refuses an existing directory that isn't an AbletonOSC install", %{tmp: tmp} do
      not_an_install = Path.join(tmp, "my_documents")
      File.mkdir_p!(not_an_install)
      File.write!(Path.join(not_an_install, "important.txt"), "please don't")

      assert_raise Mix.Error, ~r/doesn't look like an AbletonOSC installation/, fn ->
        Mix.Tasks.Abletonosc.Install.run([not_an_install])
      end

      assert File.regular?(Path.join(not_an_install, "important.txt"))
    end

    test "is idempotent", %{tmp: tmp} do
      dir = Path.join(tmp, "AbletonOSC")

      Mix.Tasks.Abletonosc.Install.run([dir])
      after_first = tree(dir)

      Mix.Tasks.Abletonosc.Install.run([dir])

      assert tree(dir) == after_first
    end

    test "errors helpfully when the submodule is uninitialised", %{tmp: tmp} do
      # The task reads its source relative to the cwd, so an empty project root
      # is how "submodule not checked out" is reproduced.
      empty_project = Path.join(tmp, "seshat")
      File.mkdir_p!(Path.join(empty_project, "priv/AbletonOSC"))

      File.cd!(empty_project, fn ->
        assert_raise Mix.Error, ~r/git submodule update --init/, fn ->
          Mix.Tasks.Abletonosc.Install.run([Path.join(tmp, "AbletonOSC")])
        end
      end)
    end
  end

  # Path -> contents for every file under `dir`, so idempotence is asserted on
  # the whole tree rather than on a handful of files that happen to be checked.
  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, dir), File.read!(&1)})
  end
end
