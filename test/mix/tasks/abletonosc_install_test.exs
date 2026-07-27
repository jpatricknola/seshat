defmodule Mix.Tasks.Abletonosc.InstallTest do
  @moduledoc """
  Exercises `mix abletonosc.install` against a fixture that mimics an AbletonOSC
  checkout, so the whole multi-handler install is covered without writing to the
  user's real Remote Scripts directory.

  The task is the whole delivery mechanism for `/live/browser/*`,
  `/live/return_track/*`, `/live/master/*` and the song-structure listeners: if
  it copies a file but skips a
  registration line, every one of those addresses goes quietly unanswered and
  the tools blame a missing install forever. Re-running it is also the documented
  fix for "my addresses stopped answering", so idempotence is a promise, not an
  implementation detail.
  """

  use ExUnit.Case, async: false

  @init_py """
  from .handler import AbletonOSCHandler
  from .song import SongHandler
  from .midimap import MidiMapHandler
  from .view import ViewHandler
  """

  # The anchor sits inside a list literal, so its indentation is load-bearing:
  # a line inserted flush-left here is a Python syntax error.
  @manager_py """
  class Manager:
      def init_api(self):
          self.handlers = [
              abletonosc.SongHandler(self),
              abletonosc.MidiMapHandler(self),
              abletonosc.ViewHandler(self),
          ]
  """

  setup do
    install_dir =
      Path.join(System.tmp_dir!(), "abletonosc_fixture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(install_dir, "abletonosc"))

    File.write!(Path.join(install_dir, "manager.py"), @manager_py)

    File.write!(
      Path.join([install_dir, "abletonosc", "handler.py"]),
      "class AbletonOSCHandler:\n    pass\n"
    )

    File.write!(Path.join([install_dir, "abletonosc", "__init__.py"]), @init_py)

    on_exit(fn -> File.rm_rf!(install_dir) end)

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)
    on_exit(fn -> Mix.shell(shell) end)

    {:ok, install_dir: install_dir}
  end

  describe "run/1" do
    test "copies every handler and registers each one exactly once", %{install_dir: dir} do
      Mix.Tasks.Abletonosc.Install.run([dir])

      for file <- ["browser.py", "return_track.py", "song_structure.py"] do
        assert File.read!(Path.join([dir, "abletonosc", file])) ==
                 File.read!("priv/abletonosc/#{file}"),
               "#{file} was not copied verbatim"
      end

      init = File.read!(Path.join([dir, "abletonosc", "__init__.py"]))
      assert occurrences(init, "from .browser import BrowserHandler") == 1
      assert occurrences(init, "from .return_track import ReturnTrackHandler") == 1
      assert occurrences(init, "from .song_structure import SongStructureHandler") == 1

      manager = File.read!(Path.join(dir, "manager.py"))
      assert occurrences(manager, "abletonosc.BrowserHandler(self),") == 1
      assert occurrences(manager, "abletonosc.ReturnTrackHandler(self),") == 1
      assert occurrences(manager, "abletonosc.SongStructureHandler(self),") == 1
    end

    test "matches the anchor's indentation so manager.py still parses", %{install_dir: dir} do
      Mix.Tasks.Abletonosc.Install.run([dir])

      lines = dir |> Path.join("manager.py") |> File.read!() |> String.split("\n")

      for line <- Enum.filter(lines, &String.contains?(&1, "Handler(self),")) do
        assert String.starts_with?(line, "            "),
               "#{inspect(line)} lost the anchor's indentation"
      end
    end

    test "is a no-op on the second run", %{install_dir: dir} do
      Mix.Tasks.Abletonosc.Install.run([dir])

      after_first = %{
        init: File.read!(Path.join([dir, "abletonosc", "__init__.py"])),
        manager: File.read!(Path.join(dir, "manager.py"))
      }

      Mix.Tasks.Abletonosc.Install.run([dir])

      assert File.read!(Path.join([dir, "abletonosc", "__init__.py"])) == after_first.init
      assert File.read!(Path.join(dir, "manager.py")) == after_first.manager
    end

    test "refuses a directory that isn't an AbletonOSC install" do
      not_an_install =
        Path.join(System.tmp_dir!(), "not_abletonosc_#{System.unique_integer([:positive])}")

      File.mkdir_p!(not_an_install)
      on_exit(fn -> File.rm_rf!(not_an_install) end)

      assert_raise Mix.Error, ~r/doesn't look like an AbletonOSC installation/, fn ->
        Mix.Tasks.Abletonosc.Install.run([not_an_install])
      end
    end

    test "reports the manual edit when an anchor is missing rather than guessing", %{
      install_dir: dir
    } do
      File.write!(
        Path.join([dir, "abletonosc", "__init__.py"]),
        "from .song import SongHandler\n"
      )

      # The manual instructions go to Mix.shell().error, which Mix.Shell.Quiet
      # still prints — so swap in the IO shell and capture both streams.
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Mix.shell(Mix.Shell.IO)
            Mix.Tasks.Abletonosc.Install.run([dir])
            Mix.shell(Mix.Shell.Quiet)
          end)
        end)

      assert output =~ "from .browser import BrowserHandler"
      assert output =~ "from .return_track import ReturnTrackHandler"
      assert output =~ "from .song_structure import SongStructureHandler"

      # The handler files are still copied — only the registration is left to the
      # user, so a hand-edit is all that's needed to finish.
      assert File.regular?(Path.join([dir, "abletonosc", "return_track.py"]))
    end
  end

  defp occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
