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
  trap — but only once the detached commit is confirmed to be on
  `origin/master` already. A detached HEAD carrying commits of its own is the
  *other* half of that trap (`git submodule update --init` detaches, and a
  commit made there belongs to no branch), and checking out `master` from it
  would abandon that work while the task reported a plausible commit; that is
  refused, with the branch-it-first recipe.

  If git refuses the fast-forward for any reason — the branch has diverged, the
  tree has uncommitted changes, the network is unreachable — its own message is
  printed verbatim and the task stops rather than installing something that
  isn't what you asked for. Use `--no-pull` to install the checkout exactly as
  it stands, which is what you want offline, or when deliberately installing an
  older commit to bisect against Live.

  Bringing the checkout forward does **not** record the new pin — that stays a
  deliberate commit. When the installed commit and the recorded pin disagree the
  task says so and names `git add priv/AbletonOSC`.

  ### Except on an old revision of this repository

  Advancing past the recorded pin installs Python newer than the pin this
  Seshat revision was tested against. On a current tree that is fine and
  deliberate — the pin is usually seconds behind the tip, and the next commit
  records it. On an **old** revision it is not: a clean checkout of an earlier
  release, run after a later incompatible bridge change, would silently deploy
  that newer Python against Elixir written long before it.

  So when this working tree is behind its own upstream *and* `origin/master` has
  moved past the recorded pin, the install stops and points at
  `git submodule update --init` plus `--no-pull`, which is how you install the
  bridge the checkout actually records.

  Note what the signal is: being behind **this** repository's upstream, not
  anything about the submodule's own history. A descendant check on
  `origin/master` cannot see this case — history moved forward normally there,
  so the old pin genuinely *is* an ancestor of the new tip and the check passes.
  Best-effort by construction: with no upstream ref fetched there is nothing to
  compare against, and the install proceeds rather than blocking on a question
  it cannot answer.

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
  # directory) and the fork's test suites — `tests/` needs a running Live and
  # `tests_unit/` needs pytest, so neither belongs in Remote Scripts. Everything
  # else AbletonOSC ships with goes across — `client/` and `run-console.py` are
  # part of its normal distribution and cost nothing sitting unused next to it.
  #
  # Any future `tests*` directory in the fork has to be added here by hand; the
  # test suite refuses an install that ships one, so the omission fails loudly
  # rather than quietly deploying test fixtures into Live.
  @excluded ~w(.git .github .gitignore tests tests_unit)

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

    # Locate before reporting: a mistyped path should fail without first
    # printing a commit line for an install that never happens.
    install_dir = locate!(rest)

    report_installed_commit(source, dirty)

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
  #
  # Only trailing whitespace is stripped. Porcelain's leading two columns are
  # the staged and unstaged status codes, so ` M file` and `M  file` are
  # different states and trimming the left would render them identically.
  defp dirty_entries(source) do
    case cmd(source, ["status", "--porcelain"]) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim_trailing/1)
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

    Mix.shell().info("Fetching origin...")
    git!(source, ["fetch", "origin"], "fetch origin")

    if detached?(source) do
      refuse_if_checkout_would_orphan!(source)
      Mix.shell().info("#{@source_dir} was on a detached HEAD - checking out #{@branch}.")
      git!(source, ["checkout", @branch], "check out #{@branch}")
    end

    refuse_advance_on_old_release!(source)
    git!(source, ["merge", "--ff-only", "origin/#{@branch}"], "fast-forward to origin/#{@branch}")
  end

  # The detached-HEAD checkout above is safe only while the detached commit is
  # already on origin/#{@branch}. It usually is - that is the stale-pin state
  # this task exists for. But .claude/rules/osc.md's step 1 exists because
  # `git submodule update --init` leaves a detached HEAD and a commit made there
  # "belongs to no branch": someone who edits and commits bridge Python without
  # checking out master first is sitting on exactly such a commit, with a
  # *clean* tree, so refuse_if_dirty!/1 sees nothing wrong.
  #
  # Checking out #{@branch} from there abandons that work. Git says so on
  # stderr, but git!/3 discards output on success, so the user sees only "was on
  # a detached HEAD" and a real-looking commit line while the install ships
  # something else entirely - the same invisible misreport as a stale pin,
  # arriving from a third direction.
  #
  # Run after the fetch, so the ancestry question is asked against a current
  # origin/#{@branch}. When that ref cannot be resolved there is nothing to
  # compare against and nothing is refused; the `merge --ff-only` below fails
  # with git's own message in that case anyway.
  defp refuse_if_checkout_would_orphan!(source) do
    with {_tip, 0} <- cmd(source, ["rev-parse", "--verify", "origin/#{@branch}"]),
         {_out, code} when code != 0 <-
           cmd(source, ["merge-base", "--is-ancestor", "HEAD", "origin/#{@branch}"]),
         {head, 0} <- cmd(source, ["log", "-1", "--format=%h %s"]) do
      Mix.raise("""
      #{@source_dir} is on a detached HEAD carrying work that is not on
      origin/#{@branch}:

      #{indent(head)}

      Checking out #{@branch} to install would leave that commit on no branch at
      all, and the install would deploy #{@branch} while reporting a commit that
      no longer describes anything reachable.

      Put it on a branch first (see .claude/rules/osc.md - editing bridge Python
      is two commits):

          git -C #{@source_dir} branch <name> HEAD
          git -C #{@source_dir} checkout <name>

      Or install this detached commit exactly as it stands:

          mix abletonosc.install --no-pull
      """)
    else
      _ -> :ok
    end
  end

  # The one case where advancing to the fork's tip is the wrong default.
  #
  # Advancing past the recorded pin normally installs Python newer than the pin
  # this Seshat revision was tested against, which is accepted here: on a tree
  # that is current, the pin is usually seconds behind the tip and the next
  # commit records it. On an **old** Seshat revision it is not accepted, and the
  # PR review named the shape: a clean checkout of an older release, run after
  # a later incompatible bridge change, would silently deploy that newer Python
  # against Elixir written years before it.
  #
  # What identifies "old" is the *parent* repo, not the submodule. A descendant
  # check on origin/master cannot see this - in that scenario history moved
  # forward normally, so the old pin **is** an ancestor of the new tip and the
  # check passes. Being behind this repository's own upstream is the signal
  # that the recorded pin belongs to a revision someone has moved past.
  #
  # Best-effort by construction: with no upstream ref fetched there is nothing
  # to compare against, and the install proceeds rather than blocking on a
  # question it cannot answer.
  defp refuse_advance_on_old_release!(source) do
    with true <- old_seshat_revision?(),
         {tip, 0} <- cmd(source, ["rev-parse", "origin/#{@branch}"]),
         pin when is_binary(pin) <- recorded_pin(),
         true <- String.trim(tip) != pin do
      Mix.raise("""
      Refusing to advance #{@source_dir} past the commit this checkout records.

      This working tree is behind its own upstream, so the pin it carries
      (#{String.slice(pin, 0, 7)}) belongs to an older Seshat revision - and
      origin/#{@branch} has moved on to #{String.slice(String.trim(tip), 0, 7)}.
      Installing the fork's tip here would run bridge Python this revision has
      never been tested against.

      Install the bridge this checkout actually records:

          git submodule update --init
          mix abletonosc.install --no-pull

      Or, if advancing is what you meant, bring this repository up to date
      first so the pin moves with it.
      """)
    else
      _ -> :ok
    end
  end

  defp old_seshat_revision? do
    with {ref, 0} <- cmd(File.cwd!(), ["rev-parse", "--abbrev-ref", "@{upstream}"]),
         {behind, 0} <- cmd(File.cwd!(), ["rev-list", "--count", "HEAD..#{String.trim(ref)}"]) do
      String.trim(behind) != "0"
    else
      _ -> false
    end
  end

  defp recorded_pin do
    with {entry, 0} <- cmd(File.cwd!(), ["ls-tree", "HEAD", @source_dir]),
         [_mode, "commit", pin | _] <- String.split(entry, [" ", "\t"], trim: true) do
      pin
    else
      _ -> nil
    end
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
         pin when is_binary(pin) <- recorded_pin(),
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
