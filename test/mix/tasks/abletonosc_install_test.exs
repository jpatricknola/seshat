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

      Mix.Tasks.Abletonosc.Install.run(["--no-pull", dir])

      assert File.regular?(Path.join(dir, "manager.py"))
      assert File.regular?(Path.join([dir, "abletonosc", "handler.py"]))

      # Seshat's own three handlers are the reason this task exists.
      #
      # osc_server.py joins them because the fork changes upstream's *behaviour*
      # there, not just its addresses: the socket binds loopback only and the
      # default reply address is never retargeted to the last sender. An install
      # that shipped an older copy of that file would silently put Live's OSC API
      # back on every network interface, and every address would still answer.
      for file <- ~w(browser.py osc_server.py return_track.py song_structure.py) do
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

      Mix.Tasks.Abletonosc.Install.run(["--no-pull", dir])

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

      Mix.Tasks.Abletonosc.Install.run(["--no-pull", dir])

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
        Mix.Tasks.Abletonosc.Install.run(["--no-pull", not_an_install])
      end

      assert File.regular?(Path.join(not_an_install, "important.txt"))
    end

    test "is idempotent", %{tmp: tmp} do
      dir = Path.join(tmp, "AbletonOSC")

      Mix.Tasks.Abletonosc.Install.run(["--no-pull", dir])
      after_first = tree(dir)

      Mix.Tasks.Abletonosc.Install.run(["--no-pull", dir])

      assert tree(dir) == after_first
    end

    test "errors helpfully when the submodule is uninitialised", %{tmp: tmp} do
      # The task reads its source relative to the cwd, so an empty project root
      # is how "submodule not checked out" is reproduced.
      empty_project = Path.join(tmp, "seshat")
      File.mkdir_p!(Path.join(empty_project, "priv/AbletonOSC"))

      File.cd!(empty_project, fn ->
        assert_raise Mix.Error, ~r/git submodule update --init/, fn ->
          Mix.Tasks.Abletonosc.Install.run(["--no-pull", Path.join(tmp, "AbletonOSC")])
        end
      end)
    end
  end

  # The install is only as current as the checkout it copies, and on 2026-08-05
  # that was the whole bug: a fork PR was merged, the task was run, and it
  # faithfully deployed the two-day-old commit the checkout was detached at,
  # reporting success either way. These exercise the fetch-and-fast-forward
  # against local fixture repositories — no network, and the real
  # priv/AbletonOSC is never touched, which is what lets them run in `mix test`
  # at all.
  describe "bringing the submodule up to date" do
    test "fast-forwards a detached checkout onto the merged commit", %{tmp: tmp} do
      %{project: project, install: install} = fixture_repo(tmp)

      File.cd!(project, fn -> Mix.Tasks.Abletonosc.Install.run([install]) end)

      assert File.read!(Path.join(install, "manager.py")) =~ "merged",
             "installed the commit the checkout was detached at, not origin/master"
    end

    test "--no-pull installs the detached checkout as it stands", %{tmp: tmp} do
      %{project: project, install: install} = fixture_repo(tmp)

      File.cd!(project, fn -> Mix.Tasks.Abletonosc.Install.run(["--no-pull", install]) end)

      assert File.read!(Path.join(install, "manager.py")) =~ "original",
             "--no-pull still brought the checkout forward"
    end

    test "refuses to install when the branch has diverged", %{tmp: tmp} do
      %{project: project, install: install, source: source, first: first} = fixture_repo(tmp)

      # A real fork, not merely being ahead: local master carries a commit
      # origin doesn't *and* lacks the one origin has. Exactly the state that
      # turned the 2026-08-05 recovery into a rebase, and the one case where
      # --ff-only genuinely cannot proceed.
      git(source, ["checkout", "master"])
      git(source, ["reset", "--hard", first])
      File.write!(Path.join(source, "manager.py"), "# diverged\n")
      commit(source, "local work")

      File.cd!(project, fn ->
        assert_raise Mix.Error, ~r/fast-forward/, fn ->
          Mix.Tasks.Abletonosc.Install.run([install])
        end
      end)

      refute File.exists?(Path.join(install, "manager.py")),
             "installed anyway after refusing the fast-forward"
    end

    test "refuses a source that isn't a git checkout at all", %{tmp: tmp} do
      project = Path.join(tmp, "seshat")
      source = Path.join(project, "priv/AbletonOSC")
      File.mkdir_p!(Path.join(source, "abletonosc"))
      File.write!(Path.join(source, "manager.py"), "# vendored by hand\n")
      File.write!(Path.join([source, "abletonosc", "handler.py"]), "# handler\n")

      File.cd!(project, fn ->
        assert_raise Mix.Error, ~r/not a git checkout/, fn ->
          Mix.Tasks.Abletonosc.Install.run([Path.join(tmp, "AbletonOSC")])
        end
      end)
    end
  end

  # A bare "origin" two commits deep, and a clone of it detached at the first —
  # the shape a submodule checkout is left in by `git submodule update`, and the
  # one where a merged PR is invisible until something fetches.
  defp fixture_repo(tmp) do
    origin = Path.join(tmp, "origin.git")
    work = Path.join(tmp, "work")
    project = Path.join(tmp, "seshat")
    source = Path.join(project, "priv/AbletonOSC")

    File.mkdir_p!(origin)
    git(origin, ["init", "--bare", "--initial-branch=master"])

    File.mkdir_p!(Path.join(work, "abletonosc"))
    File.write!(Path.join(work, "manager.py"), "# original\n")
    File.write!(Path.join([work, "abletonosc", "handler.py"]), "# handler\n")
    git(work, ["init", "--initial-branch=master"])
    git(work, ["remote", "add", "origin", origin])
    commit(work, "first")
    first = sha(work)
    git(work, ["push", "-u", "origin", "master"])

    # The merge that lands on the remote while the checkout is looking elsewhere.
    File.write!(Path.join(work, "manager.py"), "# merged\n")
    commit(work, "the merged PR")
    git(work, ["push", "origin", "master"])

    File.mkdir_p!(Path.dirname(source))
    git(tmp, ["clone", origin, source])
    git(source, ["checkout", first])

    %{project: project, source: source, first: first, install: Path.join(tmp, "AbletonOSC")}
  end

  defp commit(dir, message) do
    git(dir, ["add", "-A"])
    git(dir, ["-c", "user.email=t@example.com", "-c", "user.name=Test", "commit", "-m", message])
  end

  defp sha(dir) do
    {out, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp git(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed in #{dir}:\n#{out}"
    out
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
