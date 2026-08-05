defmodule Mix.Tasks.Abletonosc.Install do
  @moduledoc """
  Installs Seshat's fork of AbletonOSC into Ableton Live's Remote Scripts.

  Seshat runs `jpatricknola/AbletonOSC`, a fork of `ideoforms/AbletonOSC`. The
  fork carries the addresses upstream doesn't have (`/live/browser/*`,
  `/live/return_track/*`, `/live/master/*`, the song-structure listeners) plus
  fixes to upstream's own code that have no handler seam to override — chiefly
  the base class unbinding a listener from the wrong object once an index has
  been reused. `SESHAT.md` at the fork root lists every divergence.

  The fork is a git submodule at `priv/AbletonOSC`, so this task is a
  locate-and-copy: no patching, no anchors, no per-file registration. The
  install directory is **replaced wholesale**, which is what keeps a file
  deleted in the fork from lingering in an old install.

  ## Usage

      mix abletonosc.install                 # probe for an existing install
      mix abletonosc.install /path/to/AbletonOSC
      mix abletonosc.install --no-pull       # install the checkout as it stands
      mix abletonosc.install --allow-dirty   # ...including uncommitted edits

  With no argument the task probes the usual Remote Scripts locations. If it
  finds an existing AbletonOSC install, that directory is replaced. If it finds
  none, it installs fresh to
  `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`.

  A directory that already exists but doesn't look like an AbletonOSC install
  (no `manager.py`, no `abletonosc/handler.py`) is refused rather than replaced,
  so a mistyped path can't delete something else.

  ## It brings the submodule up to date first

  This task **fetches and fast-forwards `priv/AbletonOSC` to `origin/master`
  before copying anything**, and prints the commit it actually installed.

  That is not a convenience. Merging a PR on the fork changes the *remote*; it
  does not touch this clone, and a submodule is a separate repository, so
  nothing you can do in the Seshat repo will move it either — `git pull` here
  updates the recorded *pin*, and `git submodule update` moves the checkout *to*
  that pin, which is itself whatever commit was last recorded. On 2026-08-05
  that cost a full afternoon: a fork PR was merged, Live was quit, this task was
  run, Live was restarted, and the smoke tests were run against pre-merge
  Python — because the checkout had been sitting detached at the old pin for two
  days and this task copied it faithfully and reported success.

  A detached HEAD is checked out onto `master` first, since that was the actual
  trap. If git refuses the fast-forward for any reason — the branch has
  diverged, the tree has uncommitted changes, the network is unreachable — its
  own message is printed verbatim and the task stops rather than installing
  something that isn't what you asked for. Use `--no-pull` to install the
  checkout exactly as it stands, which is what you want offline, or when
  deliberately installing an older commit to bisect against Live.

  Bringing the checkout forward does **not** record the new pin — that stays a
  deliberate commit. When the installed commit and the recorded pin disagree the
  task says so and names `git add priv/AbletonOSC`.

  ## A dirty checkout is refused

  Naming the installed commit is the point, and an uncommitted edit quietly
  breaks it. When the checkout is already current, `fetch` and `merge --ff-only`
  both succeed and say nothing, so every check passes, the reported subject is a
  real commit — and the file copied into Live is not that commit. Same failure
  as installing a stale pin, arriving from the other direction: the displayed
  commit does not identify what was deployed.

  So tracked modifications and untracked source (via `git status --porcelain`,
  which skips `.gitignore`d paths, so `__pycache__` doesn't count) stop the
  install, before the update and on the `--no-pull` path alike — opting out of
  *advancing* the checkout is not opting out of knowing what is being deployed.
  `--allow-dirty` installs anyway, for the inner loop of editing bridge Python,
  and prints the count of uncommitted changes directly under the commit line so
  the report stays honest.

  ## Prerequisite

  The submodule has to be checked out:

      git submodule update --init

  Git worktrees don't populate submodules on creation, so this is once per
  worktree, not once per machine.

  ## Afterwards

  Restart Ableton Live — or toggle AbletonOSC off and back on under
  Preferences > Link/Tempo/MIDI > Control Surface. `/live/api/reload` is not a
  shortcut: it can leave AbletonOSC with no handlers at all — see the warning in
  docs/abletonosc-api-docs.md.
  """

  use Mix.Task

  @shortdoc "Install Seshat's AbletonOSC fork into Ableton Live"

  @source_dir "priv/AbletonOSC"

  # Git's own bookkeeping (`.git` is a *file* in a submodule checkout, not a
  # directory) and the fork's test suite. Everything else AbletonOSC ships with
  # goes across — `client/` and `run-console.py` are part of its normal
  # distribution and cost nothing sitting unused next to it.
  @excluded ~w(.git .github .gitignore tests)

  # The fork's default branch. Hardcoded rather than resolved from origin/HEAD:
  # this task installs one specific repository, and a wrong guess here would
  # fast-forward to somewhere unintended rather than fail.
  @branch "master"

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [no_pull: :boolean, allow_dirty: :boolean])

    source = source!()
    dirty = dirty_entries(source)

    unless opts[:allow_dirty], do: refuse_if_dirty!(dirty)

    if opts[:no_pull] do
      Mix.shell().info("Skipping the update (--no-pull) - installing the checkout as it stands.")
    else
      sync!(source)
    end

    report_installed_commit(source, dirty)

    install_dir = locate!(rest)

    Mix.shell().info("Installing #{@source_dir} -> #{install_dir}")

    replace!(source, install_dir)

    Mix.shell().info("""

    Done. Restart Ableton Live (or toggle AbletonOSC off and back on under
    Preferences > Link/MIDI > Control Surface) to pick up the new handlers.

    Files on disk are not code in memory: Live loads Remote Scripts at startup,
    so until it restarts it keeps running whatever it loaded last.
    """)
  end

  # --- The checkout has to describe what gets copied ---

  # Tracked modifications *and* untracked source, via --porcelain (which omits
  # .gitignore'd paths, so __pycache__ doesn't count). Empty output means
  # clean; a non-zero exit means this isn't a git checkout at all, which
  # sync!/1 reports properly and --no-pull tolerates, so it is not this
  # function's business.
  defp dirty_entries(source) do
    case cmd(source, ["status", "--porcelain"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      {_out, _code} -> []
    end
  end

  # Naming the installed commit is the whole point of this task, and a dirty
  # tree quietly breaks it: fetch and --ff-only both succeed when the checkout
  # is already current, so every check passes, the reported subject is a real
  # commit, and replace!/2 copies something that is not that commit. That is
  # the same class of failure as installing a stale pin - the displayed commit
  # not identifying what was deployed - so it is refused here rather than
  # warned about afterwards. Checked before the update and on the --no-pull
  # path alike: opting out of *advancing* the checkout is not opting out of
  # knowing what is being deployed.
  defp refuse_if_dirty!([]), do: :ok

  defp refuse_if_dirty!(entries) do
    Mix.raise("""
    #{@source_dir} has uncommitted changes, so the commit this task would
    report is not what it would copy into Live:

    #{indent(Enum.join(entries, "\n"))}

    Commit them in the submodule (see .claude/rules/osc.md - editing bridge
    Python is two commits), or install them anyway, knowing the deployed
    Python is not any commit:

        mix abletonosc.install --allow-dirty
    """)
  end

  # --- Bringing the submodule up to date ---

  # Fetch and fast-forward, or explain why not and stop. Every failure here is
  # reported with git's own stderr rather than a paraphrase: the states that
  # land here (diverged branch, uncommitted changes, no network, no remote) are
  # exactly the ones where git's message already names the fix and a paraphrase
  # would lose it. Nothing is forced, rebased or stashed — this task installs
  # files, and quietly rewriting someone's history to do that would be a far
  # worse surprise than refusing.
  defp sync!(source) do
    unless File.exists?(Path.join(source, ".git")) do
      Mix.raise("""
      #{@source_dir} is not a git checkout, so it can't be brought up to date.

      If it was vendored deliberately rather than checked out as a submodule,
      install it as it stands:

          mix abletonosc.install --no-pull
      """)
    end

    if detached?(source) do
      Mix.shell().info("#{@source_dir} was on a detached HEAD - checking out #{@branch}.")
      git!(source, ["checkout", @branch], "check out #{@branch}")
    end

    Mix.shell().info("Fetching origin...")
    git!(source, ["fetch", "origin"], "fetch origin")
    git!(source, ["merge", "--ff-only", "origin/#{@branch}"], "fast-forward to origin/#{@branch}")
  end

  # `symbolic-ref` fails on a detached HEAD, which is precisely the state a
  # submodule checkout is left in by `git submodule update` — and the state that
  # made a merged PR invisible to this task for two days.
  defp detached?(source) do
    match?({_, code} when code != 0, cmd(source, ["symbolic-ref", "--quiet", "HEAD"]))
  end

  defp git!(source, args, what) do
    case cmd(source, args) do
      {_out, 0} ->
        :ok

      {out, _code} ->
        Mix.raise("""
        Couldn't #{what} in #{@source_dir}, so the install stopped rather than
        deploying Python that isn't what you asked for.

        git said:

        #{indent(out)}

        Resolve that, or install the checkout exactly as it stands:

            mix abletonosc.install --no-pull
        """)
    end
  end

  # What is about to be copied, named. The whole failure this guards against is
  # invisible without it: the copy always succeeds and always reports success,
  # so the commit is the only thing that distinguishes a good install from one
  # that silently deployed month-old Python.
  defp report_installed_commit(source, dirty) do
    case cmd(source, ["log", "-1", "--format=%h %s"]) do
      {out, 0} ->
        Mix.shell().info("  at #{String.trim(out)}")
        report_dirty(dirty)
        warn_if_pin_differs(source)

      {_out, _code} ->
        :ok
    end
  end

  # Only reachable under --allow-dirty, since anything else has already
  # stopped. The commit line above is true but incomplete there, and leaving it
  # to stand alone would be the misreport this task exists to prevent - so the
  # deviation is named on the line right under it.
  defp report_dirty([]), do: :ok

  defp report_dirty(entries) do
    Mix.shell().info(
      "  plus #{length(entries)} uncommitted change(s) (--allow-dirty) - " <>
        "the deployed Python is not that commit"
    )
  end

  # The pin is Seshat's record of which bridge its Elixir was written against,
  # and moving the checkout deliberately does not move it. Saying so here is
  # what keeps "I installed the latest" from silently becoming "the tests now
  # grep Python no commit of mine refers to".
  defp warn_if_pin_differs(source) do
    with {head, 0} <- cmd(source, ["rev-parse", "HEAD"]),
         {entry, 0} <- cmd(File.cwd!(), ["ls-tree", "HEAD", @source_dir]),
         [_mode, "commit", pin] <-
           String.split(entry, [" ", "\t"], parts: 4, trim: true) |> Enum.take(3),
         true <- String.trim(head) != pin do
      Mix.shell().info("""

      Note: this is not the commit Seshat records for #{@source_dir}
      (pinned #{String.slice(pin, 0, 7)}). Record it so the Elixir side and the
      bridge move together:

          git add #{@source_dir}
      """)
    else
      _ -> :ok
    end
  end

  defp cmd(dir, args) do
    System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  rescue
    ErlangError -> {"git is not available on PATH", 1}
  end

  defp indent(text) do
    text
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  # --- Source ---

  defp source! do
    source = Path.expand(@source_dir, File.cwd!())

    cond do
      not File.dir?(source) ->
        Mix.raise("""
        Can't find #{@source_dir} - run this task from the Seshat project root.
        """)

      not File.regular?(Path.join(source, "manager.py")) ->
        Mix.raise("""
        #{@source_dir} is empty - the AbletonOSC submodule isn't checked out.

            git submodule update --init

        Git worktrees don't populate submodules on creation, so you need this
        once per worktree.
        """)

      true ->
        source
    end
  end

  # --- Locating the install directory ---

  defp locate!([path | _]) do
    expanded = Path.expand(path)

    if File.exists?(expanded) and not abletonosc_install?(expanded) do
      Mix.raise("""
      #{expanded} already exists and doesn't look like an AbletonOSC installation.

      Expected to find manager.py and abletonosc/handler.py inside it. Refusing
      to replace it - pass a path that is either an AbletonOSC install or
      doesn't exist yet.
      """)
    end

    expanded
  end

  defp locate!([]) do
    case Enum.find(candidate_paths(), &abletonosc_install?/1) do
      nil ->
        # Nothing installed anywhere we know to look, so this is a fresh
        # install. The user library is the right home for it: Live's own app
        # bundle is wiped by a Live upgrade.
        fresh = hd(candidate_paths())
        Mix.shell().info("No existing AbletonOSC found - installing fresh.")
        fresh

      path ->
        path
    end
  end

  defp candidate_paths do
    home = System.user_home!()

    user_library =
      [
        Path.join([home, "Music", "Ableton", "User Library", "Remote Scripts", "AbletonOSC"]),
        Path.join([home, "Documents", "Ableton", "User Library", "Remote Scripts", "AbletonOSC"])
      ]

    # Live's own bundled MIDI Remote Scripts directory — some people install there.
    app_bundles =
      "/Applications/Ableton Live*.app/Contents/App-Resources/MIDI Remote Scripts/AbletonOSC"
      |> Path.wildcard()

    user_library ++ app_bundles
  end

  defp abletonosc_install?(path) do
    File.regular?(Path.join(path, "manager.py")) and
      File.regular?(Path.join([path, "abletonosc", "handler.py"]))
  end

  # --- Copying ---

  # Delete then copy, rather than copying over the top. An install carried
  # forward from the patch-in-place era has files the fork doesn't (most
  # notably `track_listeners.py`, whose whole reason for existing is now fixed
  # in the base class), and a merge would leave them loaded.
  defp replace!(source, install_dir) do
    File.rm_rf!(install_dir)
    File.mkdir_p!(install_dir)

    source
    |> File.ls!()
    |> Enum.reject(&(&1 in @excluded))
    |> Enum.each(fn entry ->
      File.cp_r!(Path.join(source, entry), Path.join(install_dir, entry))
      Mix.shell().info("  copied  #{entry}")
    end)
  end
end
