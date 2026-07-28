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

  With no argument the task probes the usual Remote Scripts locations. If it
  finds an existing AbletonOSC install, that directory is replaced. If it finds
  none, it installs fresh to
  `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`.

  A directory that already exists but doesn't look like an AbletonOSC install
  (no `manager.py`, no `abletonosc/handler.py`) is refused rather than replaced,
  so a mistyped path can't delete something else.

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

  @impl true
  def run(args) do
    source = source!()
    install_dir = locate!(args)

    Mix.shell().info("Installing #{@source_dir} -> #{install_dir}")

    replace!(source, install_dir)

    Mix.shell().info("""

    Done. Restart Ableton Live (or toggle AbletonOSC off and back on under
    Preferences > Link/MIDI > Control Surface) to pick up the new handlers.
    """)
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
      to replace it — pass a path that is either an AbletonOSC install or
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
        Mix.shell().info("No existing AbletonOSC found — installing fresh.")
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
