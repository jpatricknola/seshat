defmodule Seshat.OSC.VendoredAddressesTest do
  @moduledoc """
  Tripwire for the addresses upstream AbletonOSC doesn't serve.

  `/live/browser/*`, `/live/return_track/*` and `/live/master/*` are ours, as are
  two addresses under upstream's own `/live/song/` prefix: they exist only
  because `priv/abletonosc/browser.py`, `priv/abletonosc/return_track.py` and
  `priv/abletonosc/song_structure.py` register them. A typo on either side of
  that seam fails the way every OSC mistake fails — silently, over UDP, with no
  reply — and the guard timeouts that catch it look exactly like "Ableton isn't
  running". These tests close the loop without needing Ableton at all:

    * every vendored address the Elixir code sends must be registered in Python
    * every address Python registers must be in the canonical address docs

  Upstream `/live/` addresses are out of scope here — verifying those against
  the installed AbletonOSC source is what the `audit-osc` workflow is for.
  """

  use ExUnit.Case, async: true

  @vendored_prefixes ["/live/browser/", "/live/return_track/", "/live/master/"]

  # song_structure.py registers under `/live/song/`, which upstream mostly owns —
  # a prefix would sweep in every upstream song address and fail. Listed exactly
  # instead, so a typo in either one is still caught.
  @vendored_song_addresses [
    "/live/song/start_listen/tracks",
    "/live/song/start_listen/return_tracks"
  ]

  # The addresses song_structure.py *pushes on*. They are deliberately absent
  # from the list above: nothing registers them (they are sent by a listener
  # callback, never queried), so requiring a handler for them would fail.
  # `Session.State` still matches on them, so they are documented like any other.
  @push_only_addresses ["/live/song/get/tracks", "/live/song/get/return_tracks"]

  @handler_files [
    "priv/abletonosc/browser.py",
    "priv/abletonosc/return_track.py",
    "priv/abletonosc/song_structure.py",
    "priv/abletonosc/track_listeners.py"
  ]

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

    test "every push-only address is documented even though nothing registers it" do
      docs = File.read!(@docs)

      for address <- @push_only_addresses do
        assert String.contains?(docs, address),
               "#{address} is pushed by priv/abletonosc/song_structure.py but missing from #{@docs}."

        refute address in registered_addresses(),
               """
               #{address} is registered by a vendored handler, but this test lists it as
               push-only. Either the registration is a mistake, or @push_only_addresses
               is now out of date.
               """
      end
    end

    test "the return/master handler registers exactly the thirteen documented addresses" do
      assert Enum.sort(registered_addresses("priv/abletonosc/return_track.py")) == [
               "/live/master/get/volume",
               "/live/master/set/volume",
               "/live/master/start_listen/volume",
               "/live/master/stop_listen/volume",
               "/live/return_track/get/count",
               "/live/return_track/get/name",
               "/live/return_track/get/volume",
               "/live/return_track/set/name",
               "/live/return_track/set/volume",
               "/live/return_track/start_listen/name",
               "/live/return_track/start_listen/volume",
               "/live/return_track/stop_listen/name",
               "/live/return_track/stop_listen/volume"
             ]
    end

    test "the song structure handler registers exactly the four documented addresses" do
      assert Enum.sort(registered_addresses("priv/abletonosc/song_structure.py")) == [
               "/live/song/start_listen/return_tracks",
               "/live/song/start_listen/tracks",
               "/live/song/stop_listen/return_tracks",
               "/live/song/stop_listen/tracks"
             ]
    end
  end

  # track_listeners.py is the one file here that registers no new addresses: it
  # re-registers upstream's, to replace listeners that unbind from the wrong
  # object once a track index has been reused. That makes it invisible to the
  # tripwires above — a `/live/track/*` address resolves whether or not the
  # override loaded — so it gets its own.
  describe "the track listener override" do
    @override_file "priv/abletonosc/track_listeners.py"

    test "overrides both verbs for every property it touches" do
      expected =
        for prop <- overridden_properties(), verb <- ["start_listen", "stop_listen"] do
          "/live/track/#{verb}/#{prop}"
        end

      assert Enum.sort(registered_addresses(@override_file)) == Enum.sort(expected),
             """
             The override registers start_listen without stop_listen (or the reverse)
             for some property. Both verbs have to be overridden together: a
             stop_listen left with upstream unbinds from the wrong object and drops
             the bookkeeping entry, which is the bug this file exists to fix.
             """
    end

    # The override deliberately covers only what Session.State subscribes to.
    # Adding a property to @listened_properties without adding it here would put
    # that listener back on upstream's path — silently, since the address answers
    # either way.
    test "covers every property Session.State subscribes to" do
      covered = overridden_properties()

      for prop <- listened_properties() do
        assert prop in covered,
               """
               Seshat.Session.State listens to /live/track/start_listen/#{prop}, but
               #{@override_file} doesn't override it — so it uses upstream's listener,
               which unbinds from the wrong track once an index has been reused.

               Add start_listen and stop_listen handlers for #{inspect(prop)} there,
               using _start_listen_plain (a Track property) or _start_listen_mixer
               (a mixer_device DeviceParameter).

               Covered: #{Enum.join(covered, ", ")}
               """
      end
    end

    test "registers nothing but addresses upstream already owns" do
      for address <- registered_addresses(@override_file) do
        assert String.starts_with?(address, "/live/track/"),
               "#{address} is not an upstream track address — a genuinely new address " <>
                 "belongs in its own handler file, not in the override."
      end
    end

    defp overridden_properties do
      @override_file
      |> registered_addresses()
      |> Enum.flat_map(fn address ->
        case String.split(address, "/live/track/start_listen/") do
          ["", prop] -> [prop]
          _ -> []
        end
      end)
    end
  end

  # `@listened_properties ~w(panning volume mute solo name)` in Session.State.
  defp listened_properties do
    [_match, body] =
      Regex.run(
        ~r/@listened_properties\s+~w\(([^)]*)\)/,
        File.read!("lib/seshat/session/state.ex")
      )

    String.split(body, ~r/\s+/, trim: true)
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
    |> Enum.filter(fn {address, _file} -> vendored?(address) end)
    |> Enum.uniq()
  end

  defp vendored?(address) do
    Enum.any?(@vendored_prefixes, &String.starts_with?(address, &1)) or
      address in @vendored_song_addresses
  end
end
