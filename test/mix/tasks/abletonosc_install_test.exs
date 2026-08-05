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

  # Every test that copies the *real* submodule passes both flags, and the
  # second one is not incidental. `--no-pull` keeps `mix test` off the network
  # and stops it fast-forwarding the developer's actual checkout. `--allow-dirty`
  # is what keeps the suite green during the two-commit bridge-editing loop in
  # .claude/rules/osc.md: between editing Python and committing it, the submodule
  # is dirty by design, and the install task refuses a dirty tree on the
  # `--no-pull` path too. Without this, `mix precommit` fails six unrelated tests
  # at exactly the moment the rules file tells you to run it.
  #
  # Neither flag is under test here — the dirty-refusal and fetch behaviour have
  # their own describe block below, against throwaway fixture repositories.
  @local_source ~w(--no-pull --allow-dirty)

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

      Mix.Tasks.Abletonosc.Install.run(@local_source ++ [dir])

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

    test "leaves git bookkeeping and the fork's test suites behind", %{tmp: tmp} do
      dir = Path.join(tmp, "AbletonOSC")

      Mix.Tasks.Abletonosc.Install.run(@local_source ++ [dir])

      refute File.exists?(Path.join(dir, ".git"))
      refute File.exists?(Path.join(dir, ".github"))
      refute File.exists?(Path.join(dir, "tests"))
      refute File.exists?(Path.join(dir, "tests_unit"))

      # Asserted as a pattern, not as two names. The fork grew `tests_unit/`
      # beside `tests/` in the 2026-08-05 dispatch-boundary merge and the
      # exclusion list did not grow with it, so pytest fixtures shipped into
      # Live's Remote Scripts. Naming each directory as it appears means the
      # next one slips through the same way; this fails on it instead.
      shipped_test_dirs =
        dir
        |> File.ls!()
        |> Enum.filter(&(String.starts_with?(&1, "tests") and File.dir?(Path.join(dir, &1))))

      assert shipped_test_dirs == [],
             "the install shipped the fork's test suite(s) into Remote Scripts: " <>
               "#{inspect(shipped_test_dirs)} — add them to @excluded"
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

      Mix.Tasks.Abletonosc.Install.run(@local_source ++ [dir])

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
        Mix.Tasks.Abletonosc.Install.run(@local_source ++ [not_an_install])
      end

      assert File.regular?(Path.join(not_an_install, "important.txt"))
    end

    test "is idempotent", %{tmp: tmp} do
      dir = Path.join(tmp, "AbletonOSC")

      Mix.Tasks.Abletonosc.Install.run(@local_source ++ [dir])
      after_first = tree(dir)

      Mix.Tasks.Abletonosc.Install.run(@local_source ++ [dir])

      assert tree(dir) == after_first
    end

    test "errors helpfully when the submodule is uninitialised", %{tmp: tmp} do
      # The task reads its source relative to the cwd, so an empty project root
      # is how "submodule not checked out" is reproduced.
      empty_project = Path.join(tmp, "seshat")
      File.mkdir_p!(Path.join(empty_project, "priv/AbletonOSC"))

      File.cd!(empty_project, fn ->
        assert_raise Mix.Error, ~r/git submodule update --init/, fn ->
          Mix.Tasks.Abletonosc.Install.run(@local_source ++ [Path.join(tmp, "AbletonOSC")])
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

    test "refuses to abandon commits made on the detached HEAD", %{tmp: tmp} do
      %{project: project, install: install, source: source} = fixture_repo(tmp)

      # .claude/rules/osc.md step 1 exists because `git submodule update --init`
      # detaches and a commit made there belongs to no branch. This is someone
      # who skipped it: edited bridge Python and committed, still detached. The
      # tree is *clean*, so the dirty guard sees nothing - and checking out
      # master to install would drop the commit on the floor while the task
      # printed a real-looking commit line for something else.
      commit_message = "urgent bridge fix nobody branched"
      File.write!(Path.join(source, "manager.py"), "# work only on the detached HEAD\n")
      commit(source, commit_message)

      File.cd!(project, fn ->
        assert_raise Mix.Error, ~r/detached HEAD carrying work that is not on/, fn ->
          Mix.Tasks.Abletonosc.Install.run([install])
        end
      end)

      refute File.exists?(Path.join(install, "manager.py")),
             "installed master anyway, abandoning the detached commit"

      assert git(source, ["log", "-1", "--format=%s"]) =~ commit_message,
             "the detached commit is no longer HEAD - the task moved off it"
    end

    test "a detached HEAD already on origin/master is brought forward, not refused",
         %{tmp: tmp} do
      # The other side of the guard above, and the ordinary case: detached at a
      # commit origin already has. Nothing is at risk, so it must not be refused
      # - a guard that also blocks the stale pin would block the whole point of
      # the task.
      %{project: project, install: install} = fixture_repo(tmp)

      File.cd!(project, fn -> Mix.Tasks.Abletonosc.Install.run([install]) end)

      assert File.read!(Path.join(install, "manager.py")) =~ "merged"
    end

    test "names the pin when the installed commit has moved past it", %{tmp: tmp} do
      # Advancing the checkout deliberately does not record the new pin, so the
      # Elixir side and the bridge are now describing different commits. Saying
      # so is the second half of the two-commit rule in .claude/rules/osc.md;
      # without it, "I installed the latest" quietly becomes "the tests grep
      # Python no commit of mine refers to".
      %{project: project, install: install, source: source, first: first} = fixture_repo(tmp)

      git(project, ["init", "--initial-branch=main"])
      git(source, ["checkout", first])
      git(project, ["add", "priv/AbletonOSC"])
      commit(project, "record the older pin")
      git(source, ["checkout", "--detach", first])

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.Quiet) end)

      File.cd!(project, fn -> Mix.Tasks.Abletonosc.Install.run([install]) end)

      messages = drain_shell()

      assert messages =~ "not the commit Seshat records",
             "advanced past the recorded pin without saying so"

      assert messages =~ "git add priv/AbletonOSC",
             "said the pin was stale without naming how to record it"
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

    test "refuses a dirty checkout rather than reporting a commit it isn't deploying",
         %{tmp: tmp} do
      %{project: project, install: install, source: source} = fixture_repo(tmp)

      # Up to date with origin, so fetch and --ff-only both succeed and say
      # nothing - but the tree has an uncommitted edit. This is the case where
      # the reported commit stops describing what was copied, which is the one
      # failure this whole task exists to prevent.
      git(source, ["checkout", "master"])
      File.write!(Path.join(source, "manager.py"), "# uncommitted work in progress\n")

      File.cd!(project, fn ->
        assert_raise Mix.Error, ~r/uncommitted|dirty/i, fn ->
          Mix.Tasks.Abletonosc.Install.run([install])
        end
      end)

      refute File.exists?(Path.join(install, "manager.py")),
             "copied a dirty checkout after reporting a clean commit"
    end

    test "refuses a checkout with untracked source rather than reporting a clean commit",
         %{tmp: tmp} do
      %{project: project, install: install, source: source} = fixture_repo(tmp)

      git(source, ["checkout", "master"])
      File.write!(Path.join([source, "abletonosc", "experiment.py"]), "# not committed\n")

      File.cd!(project, fn ->
        assert_raise Mix.Error, ~r/uncommitted|untracked|dirty/i, fn ->
          Mix.Tasks.Abletonosc.Install.run([install])
        end
      end)
    end

    test "--no-pull still refuses a dirty checkout", %{tmp: tmp} do
      # --no-pull opts out of *advancing* the checkout, not out of knowing what
      # is being deployed: the reported commit is just as wrong either way.
      %{project: project, install: install, source: source} = fixture_repo(tmp)

      git(source, ["checkout", "master"])
      File.write!(Path.join(source, "manager.py"), "# uncommitted\n")

      File.cd!(project, fn ->
        assert_raise Mix.Error, ~r/uncommitted|dirty/i, fn ->
          Mix.Tasks.Abletonosc.Install.run(["--no-pull", install])
        end
      end)
    end

    test "--allow-dirty installs the dirty tree and says the commit doesn't describe it",
         %{tmp: tmp} do
      %{project: project, install: install, source: source} = fixture_repo(tmp)

      git(source, ["checkout", "master"])
      File.write!(Path.join(source, "manager.py"), "# uncommitted work in progress\n")

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.Quiet) end)

      File.cd!(project, fn ->
        Mix.Tasks.Abletonosc.Install.run(["--allow-dirty", install])
      end)

      assert File.read!(Path.join(install, "manager.py")) =~ "uncommitted work in progress"

      assert drain_shell() =~ "uncommitted change(s)",
             "installed a dirty tree without saying the commit doesn't describe it"
    end

    test "refuses to advance the bridge when the parent tree is an old revision",
         %{tmp: tmp} do
      %{project: project, install: install, source: source, first: first} = fixture_repo(tmp)

      # The parent is a real repo whose HEAD is behind its own upstream, and
      # whose recorded pin is the older bridge commit. That is the shape of a
      # clean checkout of an older Seshat release: a descendant check cannot
      # see it, because the pin genuinely is an ancestor of the fork's tip.
      parent_origin = Path.join(tmp, "seshat-origin.git")
      File.mkdir_p!(parent_origin)
      git(parent_origin, ["init", "--bare", "--initial-branch=main"])
      git(project, ["init", "--initial-branch=main"])
      git(project, ["remote", "add", "origin", parent_origin])
      git(source, ["checkout", first])
      File.write!(Path.join(project, "README.md"), "old release\n")
      git(project, ["add", "README.md"])
      git(project, ["-c", "user.email=t@e.com", "-c", "user.name=T", "add", "priv/AbletonOSC"])
      commit(project, "old release")
      git(project, ["push", "-u", "origin", "main"])
      File.write!(Path.join(project, "README.md"), "newer release\n")
      commit(project, "newer release")
      git(project, ["push", "origin", "main"])
      git(project, ["reset", "--hard", "HEAD~1"])

      File.cd!(project, fn ->
        assert_raise Mix.Error, ~r/older Seshat revision|behind its own upstream/, fn ->
          Mix.Tasks.Abletonosc.Install.run([install])
        end
      end)

      refute File.exists?(Path.join(install, "manager.py")),
             "advanced and installed despite the parent being an old revision"
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

  # Everything Mix.Shell.Process has queued, joined. The task reports across
  # several info/1 calls, and which line carries a given phrase is a formatting
  # detail no test should be pinned to.
  defp drain_shell do
    Stream.repeatedly(fn ->
      receive do: ({:mix_shell, :info, [m]} -> m), after: (0 -> nil)
    end)
    |> Enum.take_while(&is_binary/1)
    |> Enum.join("\n")
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
