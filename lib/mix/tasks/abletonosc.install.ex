defmodule Mix.Tasks.Abletonosc.Install do
  @moduledoc """
  Installs Seshat's handler extensions into an existing AbletonOSC installation.

  Upstream AbletonOSC has no browser API, so `list_browser_items` and
  `load_device` need an extra handler on the Python side; it also reaches
  regular tracks only, so the return-track and master addresses the send/level
  tools need come from a second one. This task copies both files from
  `priv/abletonosc/` into AbletonOSC and registers them.

  ## Usage

      mix abletonosc.install                 # probe for AbletonOSC
      mix abletonosc.install /path/to/AbletonOSC

  ## What it changes

  For each of `browser.py` and `return_track.py`:

  1. Copies `priv/abletonosc/<file>` -> `<install>/abletonosc/<file>`
  2. Adds its `from .<module> import <Handler>` line to `<install>/abletonosc/__init__.py`
  3. Adds `abletonosc.<Handler>(self),` to the handler list in `<install>/manager.py`

  Every step is idempotent - re-running the task is safe. If AbletonOSC
  has drifted and a patch anchor can't be found, the task prints the exact
  manual edit rather than guessing where the line belongs.

  Restart Ableton Live afterwards — or toggle AbletonOSC off and back on under
  Preferences > Link/Tempo/MIDI > Control Surface. `/live/api/reload` is not a
  shortcut here: `reload_imports` names the modules it reloads and neither
  `abletonosc.browser` nor `abletonosc.return_track` is among them, so it never
  picks up an edit to these files, new module or not. It can also leave
  AbletonOSC with no handlers at all — see the warning in
  docs/abletonosc-api-docs.md.
  """

  use Mix.Task

  @shortdoc "Install Seshat's AbletonOSC handler extensions"

  @handlers [
    %{
      file: "browser.py",
      init_line: "from .browser import BrowserHandler",
      manager_line: "abletonosc.BrowserHandler(self),"
    },
    %{
      file: "return_track.py",
      init_line: "from .return_track import ReturnTrackHandler",
      manager_line: "abletonosc.ReturnTrackHandler(self),"
    }
  ]

  # Both handlers insert after the same anchor. `patch/3` is idempotent per line
  # and each insert lands directly after the anchor, so the order the two end up
  # in is arbitrary and harmless — they are independent imports.
  @init_anchor "from .midimap import MidiMapHandler"
  @manager_anchor "abletonosc.MidiMapHandler(self),"

  @impl true
  def run(args) do
    sources =
      Map.new(@handlers, fn handler ->
        source = Path.expand("priv/abletonosc/#{handler.file}", File.cwd!())

        unless File.regular?(source) do
          Mix.raise(
            "Can't find priv/abletonosc/#{handler.file} - run this task from the Seshat " <>
              "project root."
          )
        end

        {handler.file, source}
      end)

    install_dir = locate!(args)
    Mix.shell().info("AbletonOSC found at #{install_dir}")

    results =
      Enum.flat_map(@handlers, fn handler ->
        copy_handler(Map.fetch!(sources, handler.file), install_dir, handler.file)

        [
          patch(
            Path.join([install_dir, "abletonosc", "__init__.py"]),
            @init_anchor,
            handler.init_line
          ),
          patch(Path.join(install_dir, "manager.py"), @manager_anchor, handler.manager_line)
        ]
      end)

    if Enum.any?(results, &(&1 == :anchor_not_found)) do
      print_manual_instructions(install_dir)
    else
      Mix.shell().info("""

      Done. Restart Ableton Live (or toggle AbletonOSC off and back on under
      Preferences > Link/MIDI > Control Surface) to pick up the new handlers.
      """)
    end
  end

  # --- Locating AbletonOSC ---

  defp locate!([path | _]) do
    expanded = Path.expand(path)

    if abletonosc_install?(expanded) do
      expanded
    else
      Mix.raise("""
      #{expanded} doesn't look like an AbletonOSC installation.

      Expected to find manager.py and abletonosc/handler.py inside it.
      """)
    end
  end

  defp locate!([]) do
    case Enum.find(candidate_paths(), &abletonosc_install?/1) do
      nil ->
        Mix.raise("""
        Couldn't find AbletonOSC. Looked in:

        #{Enum.map_join(candidate_paths(), "\n", &"  #{&1}")}

        Pass the path explicitly:

            mix abletonosc.install /path/to/AbletonOSC
        """)

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

  # --- Steps ---

  defp copy_handler(source, install_dir, file) do
    target = Path.join([install_dir, "abletonosc", file])

    case File.cp(source, target) do
      :ok ->
        Mix.shell().info("  copied  abletonosc/#{file}")

      {:error, reason} ->
        Mix.raise("Couldn't write #{target}: #{:file.format_error(reason)}")
    end
  end

  # Inserts `line` directly after `anchor`, matching the anchor's indentation.
  # Returns :ok, :already_patched, or :anchor_not_found.
  defp patch(file, anchor, line) do
    relative = Path.basename(file)
    contents = read!(file)
    lines = String.split(contents, "\n")

    already_patched? = Enum.any?(lines, &(String.trim(&1) == line))
    anchor_index = Enum.find_index(lines, &(String.trim(&1) == anchor))

    case {already_patched?, anchor_index} do
      {true, _} ->
        Mix.shell().info("  skipped #{relative} (already patched)")
        :already_patched

      {false, nil} ->
        Mix.shell().error(
          "  FAILED  #{relative} - couldn't find the anchor line #{inspect(anchor)}"
        )

        :anchor_not_found

      {false, index} ->
        indent = indentation_of(Enum.at(lines, index))
        patched = List.insert_at(lines, index + 1, indent <> line)
        File.write!(file, Enum.join(patched, "\n"))
        Mix.shell().info("  patched #{relative}")
        :ok
    end
  end

  defp indentation_of(line) do
    case Regex.run(~r/^\s*/, line) do
      [indent] -> indent
      _ -> ""
    end
  end

  defp read!(file) do
    case File.read(file) do
      {:ok, contents} ->
        contents

      {:error, reason} ->
        Mix.raise("Couldn't read #{file}: #{:file.format_error(reason)}")
    end
  end

  defp print_manual_instructions(install_dir) do
    init_lines = Enum.map_join(@handlers, "\n", &"           #{&1.init_line}")
    manager_lines = Enum.map_join(@handlers, "\n", &"           #{&1.manager_line}")

    Mix.shell().error("""

    AbletonOSC has changed since this task was written, so at least one patch
    was skipped. The handler files have been copied - apply the edits by hand
    (skip any line that is already there):

    1. In #{Path.join([install_dir, "abletonosc", "__init__.py"])}, alongside the
       other handler imports, add:

    #{init_lines}

    2. In #{Path.join(install_dir, "manager.py")}, inside the `self.handlers = [`
       list in `init_api`, add:

    #{manager_lines}

    Then restart Ableton Live.
    """)
  end
end
