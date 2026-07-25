defmodule Mix.Tasks.Abletonosc.Install do
  @moduledoc """
  Installs Seshat's browser handler into an existing AbletonOSC installation.

  Upstream AbletonOSC has no browser API, so `list_browser_items` and
  `load_device` need an extra handler on the Python side. This task copies
  `priv/abletonosc/browser.py` into AbletonOSC and registers it.

  ## Usage

      mix abletonosc.install                 # probe for AbletonOSC
      mix abletonosc.install /path/to/AbletonOSC

  ## What it changes

  1. Copies `priv/abletonosc/browser.py` -> `<install>/abletonosc/browser.py`
  2. Adds `from .browser import BrowserHandler` to `<install>/abletonosc/__init__.py`
  3. Adds `abletonosc.BrowserHandler(self),` to the handler list in `<install>/manager.py`

  All three steps are idempotent - re-running the task is safe. If AbletonOSC
  has drifted and a patch anchor can't be found, the task prints the exact
  manual edit rather than guessing where the line belongs.

  Restart Ableton Live afterwards — or toggle AbletonOSC off and back on under
  Preferences > Link/Tempo/MIDI > Control Surface. `/live/api/reload` is not a
  shortcut here: `reload_imports` names the modules it reloads and
  `abletonosc.browser` isn't among them, so it never picks up an edit to this
  file, new module or not. It can also leave AbletonOSC with no handlers at all
  — see the warning in docs/abletonosc-api-docs.md.
  """

  use Mix.Task

  @shortdoc "Install Seshat's browser handler into AbletonOSC"

  @source_path "priv/abletonosc/browser.py"

  @init_anchor "from .midimap import MidiMapHandler"
  @init_line "from .browser import BrowserHandler"

  @manager_anchor "abletonosc.MidiMapHandler(self),"
  @manager_line "abletonosc.BrowserHandler(self),"

  @impl true
  def run(args) do
    source = Path.expand(@source_path, File.cwd!())

    unless File.regular?(source) do
      Mix.raise("Can't find #{@source_path} - run this task from the Seshat project root.")
    end

    install_dir = locate!(args)
    Mix.shell().info("AbletonOSC found at #{install_dir}")

    copy_handler(source, install_dir)

    results = [
      patch(Path.join([install_dir, "abletonosc", "__init__.py"]), @init_anchor, @init_line),
      patch(Path.join(install_dir, "manager.py"), @manager_anchor, @manager_line)
    ]

    if Enum.any?(results, &(&1 == :anchor_not_found)) do
      print_manual_instructions(install_dir)
    else
      Mix.shell().info("""

      Done. Restart Ableton Live (or toggle AbletonOSC off and back on under
      Preferences > Link/MIDI > Control Surface) to pick up the new handler.
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

  defp copy_handler(source, install_dir) do
    target = Path.join([install_dir, "abletonosc", "browser.py"])

    case File.cp(source, target) do
      :ok ->
        Mix.shell().info("  copied  abletonosc/browser.py")

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
    Mix.shell().error("""

    AbletonOSC has changed since this task was written, so one or both patches
    were skipped. browser.py has been copied - apply the edits by hand:

    1. In #{Path.join([install_dir, "abletonosc", "__init__.py"])}, alongside the
       other handler imports, add:

           #{@init_line}

    2. In #{Path.join(install_dir, "manager.py")}, inside the `self.handlers = [`
       list in `init_api`, add:

           #{@manager_line}

    Then restart Ableton Live.
    """)
  end
end
