defmodule Seshat.OSC.VendoredAddressesTest do
  @moduledoc """
  Tripwire for the addresses upstream AbletonOSC doesn't serve.

  `/live/browser/*`, `/live/return_track/*` and `/live/master/*` are ours, as are
  two addresses under upstream's own `/live/song/` prefix: they exist only
  because `browser.py`, `return_track.py` and `song_structure.py` in the
  `priv/AbletonOSC` fork register them. A typo on either side of that seam fails
  the way every OSC mistake fails — silently, over UDP, with no reply — and the
  guard timeouts that catch it look exactly like "Ableton isn't running". These
  tests close the loop without needing Ableton at all:

    * every vendored address the Elixir code sends must be registered in Python
    * every address Python registers must be in the canonical address docs

  Upstream `/live/` addresses are out of scope here — verifying those against
  the fork's source is what the `audit-osc` workflow is for.

  There used to be a fourth file, `track_listeners.py`, which registered no new
  addresses: it overrode five of upstream's, whose listeners unbind from the
  wrong object once a track index has been reused. It had its own describe block
  here, pinning that it covered everything `Session.State` subscribes to. The
  fork fixes that bug in `AbletonOSCHandler._stop_listen` instead, so there is
  nothing left to override and nothing left to keep in sync.
  """

  use ExUnit.Case, async: true

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

  @vendored_prefixes ["/live/browser/", "/live/return_track/", "/live/master/"]

  # song_structure.py registers under `/live/song/`, which upstream mostly owns —
  # a prefix would sweep in every upstream song address and fail. Listed exactly
  # instead. That exactness cuts both ways: unlike a prefix, a typo'd address
  # stops being recognised as vendored and so drops out of the check it should
  # fail — which is what "the exactly-listed song addresses are still in use"
  # below exists to catch.
  @vendored_song_addresses [
    "/live/song/start_listen/tracks",
    "/live/song/start_listen/return_tracks"
  ]

  # The addresses song_structure.py *pushes on*. They are deliberately absent
  # from the list above: nothing registers them (they are sent by a listener
  # callback, never queried), so requiring a handler for them would fail.
  # `Session.State` still matches on them, so they are documented like any other.
  @push_only_addresses ["/live/song/get/tracks", "/live/song/get/return_tracks"]

  @browser_file "priv/AbletonOSC/abletonosc/browser.py"
  @return_track_file "priv/AbletonOSC/abletonosc/return_track.py"
  @song_structure_file "priv/AbletonOSC/abletonosc/song_structure.py"

  @handler_files [@browser_file, @return_track_file, @song_structure_file]

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
               to a handler in #{@source}, or fix the typo.
               """
      end
    end

    # The prefix entries are self-correcting: `/live/return_track/nmae` still
    # starts with `/live/return_track/`, so it is swept into `used` and fails
    # against the registered list. The two song addresses are admitted by exact
    # match, so a typo on the *Elixir* side excludes itself from that check —
    # `vendored?/1` simply stops recognising it, and `used` quietly shrinks by
    # one (15 addresses today, so the >= 10 floor above doesn't notice either).
    # Pinning that both are still sent is what closes that direction.
    test "the exactly-listed song addresses are still the ones Session.State sends" do
      sent = Enum.map(used_addresses(), fn {address, _file} -> address end)

      for address <- @vendored_song_addresses do
        assert address in sent,
               """
               #{address} is listed in @vendored_song_addresses, but nothing under lib/
               sends it.

               If it was typo'd on the Elixir side, that typo is invisible to the
               used→registered test above — these two are recognised by exact match
               only, so a misspelling stops counting as vendored instead of failing.
               Fix the address, or drop it from @vendored_song_addresses if it is
               genuinely no longer used.

               Sent: #{Enum.join(Enum.sort(sent), ", ")}
               """
      end
    end

    test "every one a vendored handler registers is in the canonical address docs" do
      docs = File.read!(@docs)

      for address <- registered_addresses() do
        assert String.contains?(docs, address),
               """
               #{address} is registered in #{@source} but missing from #{@docs}.

               That file is the canonical list every tool is written against, and
               .claude/rules/osc.md says an address that isn't in it doesn't exist.
               """
      end
    end

    test "every push-only address is documented even though nothing registers it" do
      docs = File.read!(@docs)

      for address <- @push_only_addresses do
        assert String.contains?(docs, address),
               "#{address} is pushed by #{@song_structure_file} but missing from #{@docs}."

        refute address in registered_addresses(),
               """
               #{address} is registered by a vendored handler, but this test lists it as
               push-only. Either the registration is a mistake, or @push_only_addresses
               is now out of date.
               """
      end
    end

    test "the browser handler registers exactly the five documented addresses" do
      assert Enum.sort(registered_addresses(@browser_file)) == [
               "/live/browser/export",
               "/live/browser/get/items",
               "/live/browser/load_item",
               "/live/browser/preview_item",
               "/live/browser/stop_preview"
             ]
    end

    test "the return/master handler registers exactly the thirteen documented addresses" do
      assert Enum.sort(registered_addresses(@return_track_file)) == [
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
      assert Enum.sort(registered_addresses(@song_structure_file)) == [
               "/live/song/start_listen/return_tracks",
               "/live/song/start_listen/tracks",
               "/live/song/stop_listen/return_tracks",
               "/live/song/stop_listen/tracks"
             ]
    end
  end

  # The fork's one fix whose loss is completely invisible: every address still
  # answers, and the only symptom is one track's name appearing under another's
  # index some time later. SESHAT.md lists it as a merge hazard for exactly that
  # reason, and an upstream merge is the realistic way it gets dropped. A grep is
  # a crude guard, but the alternative is a live Ableton.
  describe "the base-class listener fix" do
    @handler_base "priv/AbletonOSC/abletonosc/handler.py"

    test "_stop_listen unbinds from the stored object, not the one it was passed" do
      assert File.read!(@handler_base) =~ "self.listener_objects.get(listener_key, target)",
             """
             #{@handler_base}'s _stop_listen no longer resolves its target through
             listener_objects.

             Without it, a listener keyed by an index that has since been renumbered
             is unbound from the wrong object: the removal raises, is swallowed as
             "likely benign", and the bookkeeping entry is dropped anyway — leaving
             the old listener alive and pushing under an index that now means someone
             else. Seshat.Session.State's mirror then reports one track's name under
             another's index.

             This is the fix that let priv/abletonosc/track_listeners.py be deleted.
             If an upstream merge reverted it, reapply it — see SESHAT.md in the fork.
             """
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
    |> Enum.filter(fn {address, _file} -> vendored?(address) end)
    |> Enum.uniq()
  end

  defp vendored?(address) do
    Enum.any?(@vendored_prefixes, &String.starts_with?(address, &1)) or
      address in @vendored_song_addresses
  end
end
