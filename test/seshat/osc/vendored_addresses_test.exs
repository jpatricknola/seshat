defmodule Seshat.OSC.VendoredAddressesTest do
  @moduledoc """
  Tripwire for the addresses upstream AbletonOSC doesn't serve.

  `/live/browser/*`, `/live/return_track/*` and `/live/master/*` are ours: they
  exist only because `priv/abletonosc/browser.py` and
  `priv/abletonosc/return_track.py` register them. A typo on either side of that
  seam fails the way every OSC mistake fails — silently, over UDP, with no reply
  — and the guard timeouts that catch it look exactly like "Ableton isn't
  running". These tests close the loop without needing Ableton at all:

    * every vendored address the Elixir code sends must be registered in Python
    * every address Python registers must be in the canonical address docs

  Upstream `/live/` addresses are out of scope here — verifying those against
  the installed AbletonOSC source is what the `audit-osc` workflow is for.
  """

  use ExUnit.Case, async: true

  @vendored_prefixes ["/live/browser/", "/live/return_track/", "/live/master/"]

  @handler_files ["priv/abletonosc/browser.py", "priv/abletonosc/return_track.py"]

  @docs "docs/abletonosc-api-docs.md"

  describe "vendored OSC addresses" do
    test "every one the Elixir code uses is registered by a vendored handler" do
      registered = registered_addresses()
      used = used_addresses()

      # Without this the loop below passes by finding nothing to check — the one
      # way a tripwire fails silently.
      assert length(used) >= 10, "expected the vendored addresses to be in use in lib/"

      for {address, file} <- used do
        assert address in registered,
               """
               #{file} sends #{address}, but no vendored handler registers it.

               Registered: #{Enum.join(Enum.sort(registered), ", ")}

               An unregistered address is silently dropped by AbletonOSC — add it
               to a handler in priv/abletonosc/, or fix the typo.
               """
      end
    end

    test "every one a vendored handler registers is in the canonical address docs" do
      docs = File.read!(@docs)

      for address <- registered_addresses() do
        assert String.contains?(docs, address),
               """
               #{address} is registered in priv/abletonosc/ but missing from #{@docs}.

               That file is the canonical list every tool is written against, and
               .claude/rules/osc.md says an address that isn't in it doesn't exist.
               """
      end
    end

    test "the return/master handler registers exactly the seven documented addresses" do
      assert Enum.sort(registered_addresses("priv/abletonosc/return_track.py")) == [
               "/live/master/get/volume",
               "/live/master/set/volume",
               "/live/return_track/get/count",
               "/live/return_track/get/name",
               "/live/return_track/get/volume",
               "/live/return_track/set/name",
               "/live/return_track/set/volume"
             ]
    end
  end

  # `add_handler("/live/...", ...)` — the one way a handler registers an address.
  defp registered_addresses(file) do
    ~r/add_handler\(\s*"(\/live\/[^"]+)"/
    |> Regex.scan(File.read!(file))
    |> Enum.map(fn [_match, address] -> address end)
  end

  defp registered_addresses, do: Enum.flat_map(@handler_files, &registered_addresses/1)

  # Address strings live inline in Handlers/Registry/Session.State by design
  # (osc.md: greppable via `"/live/`), which is exactly what makes this checkable.
  defp used_addresses do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      ~r/"(\/live\/[^"]+)"/
      |> Regex.scan(File.read!(file))
      |> Enum.map(fn [_match, address] -> {address, file} end)
    end)
    |> Enum.filter(fn {address, _file} ->
      Enum.any?(@vendored_prefixes, &String.starts_with?(address, &1))
    end)
    |> Enum.uniq()
  end
end
