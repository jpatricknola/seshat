defmodule Seshat.OSC.VendoredAddressesTest do
  @moduledoc """
  Tripwire for the addresses upstream AbletonOSC doesn't serve.

  `/live/browser/*`, `/live/return_track/*` and `/live/master/*` are ours, as are
  four addresses under upstream's own `/live/song/` prefix and four under its
  `/live/view/` prefix: they exist only because `browser.py`, `return_track.py`,
  `song_structure.py` and our additions to `view.py` and `song.py` in the
  `priv/AbletonOSC` fork register them. A typo on either side of that seam fails
  the way every OSC mistake fails — silently, over UDP, with no reply — and the
  guard timeouts that catch it look exactly like "Ableton isn't running". These
  tests close the loop without needing Ableton at all:

    * every vendored address the Elixir code sends must be registered in Python
    * every address Python registers must be in the canonical address docs

  Two of those four `/live/song/` addresses — `begin_undo_step` and
  `end_undo_step` — plus the `swing_amount` property are entries in a *list*
  rather than literal `add_handler` calls, so neither check above can see them
  at all. They get their own grep-based describes at the bottom of this file.

  Upstream `/live/` addresses get one check of their own: everything upstream's
  handler files register — including the routes their property/method loops
  generate — must appear in the canonical address docs ("upstream address doc
  coverage" below). That direction used to cover only the vendored files, which
  is how 19 upstream addresses stayed out of the docs until 2026-08-03 and a
  false "no bulk scene-name address exists" comment grew in `handlers.ex`.
  Verifying *behaviour* against the fork's source is still the `audit-osc`
  workflow's job.

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

  # Four more of ours under a prefix upstream owns, and for the same reason listed
  # exactly rather than by prefix — `/live/view/` is upstream's. Unlike
  # song_structure.py these live *inside* an upstream file, so view.py joins
  # @handler_files below and its upstream registrations get checked against the
  # docs alongside them (they are all documented already). song.py is the other
  # upstream file we add to, but it stays out of @handler_files: its additions
  # are list entries, not add_handler calls (see the last two describes).
  #
  # view.py registers three more of ours — `get/selected_track_identity` and its
  # start/stop listener pair — which are deliberately absent here: this list is
  # also the "still sent by lib/" pin below, and nothing under lib/ sends them
  # yet. The whole-file registration pin further down is what keeps an upstream
  # merge from dropping them. Move them up here when a tool starts sending them.
  @vendored_view_addresses [
    "/live/view/show_view",
    "/live/view/hide_view",
    "/live/view/get/is_view_visible",
    "/live/view/set/detail_clip"
  ]

  @browser_file "priv/AbletonOSC/abletonosc/browser.py"
  @return_track_file "priv/AbletonOSC/abletonosc/return_track.py"
  @song_structure_file "priv/AbletonOSC/abletonosc/song_structure.py"
  @view_file "priv/AbletonOSC/abletonosc/view.py"

  @handler_files [@browser_file, @return_track_file, @song_structure_file, @view_file]

  # Upstream's handler files, for the doc-coverage check only. view.py is
  # already in @handler_files (its registrations are all literal), and
  # manager.py carries the five /live/test + /live/api literals. The rest
  # register most of their addresses through property/method loops, which
  # upstream_registered_addresses/1 expands.
  @upstream_handler_files [
    "priv/AbletonOSC/abletonosc/application.py",
    "priv/AbletonOSC/abletonosc/song.py",
    "priv/AbletonOSC/abletonosc/track.py",
    "priv/AbletonOSC/abletonosc/clip.py",
    "priv/AbletonOSC/abletonosc/clip_slot.py",
    "priv/AbletonOSC/abletonosc/scene.py",
    "priv/AbletonOSC/abletonosc/device.py",
    "priv/AbletonOSC/abletonosc/midimap.py",
    "priv/AbletonOSC/manager.py"
  ]

  # Listener routes are documented once per family rather than once per
  # property. Keep the exact start/stop templates here so a getter alone cannot
  # make its listeners look documented after that family-level prose is removed.
  @listener_doc_markers %{
    "song" => [
      "/live/song/start_listen/<property>",
      "/live/song/stop_listen/<property>"
    ],
    "track" => [
      "/live/track/start_listen/<property>",
      "/live/track/stop_listen/<property>"
    ],
    "clip_slot" => [
      "/live/clip_slot/start_listen/<property>",
      "/live/clip_slot/stop_listen/<property>"
    ],
    "clip" => [
      "/live/clip/start_listen/<property>",
      "/live/clip/stop_listen/<property>"
    ],
    "scene" => [
      "/live/scene/start_listen/<property>",
      "/live/scene/stop_listen/<property>"
    ],
    "device" => [
      "/live/device/start_listen/<property>",
      "/live/device/stop_listen/<property>"
    ]
  }

  @docs "priv/AbletonOSC/API.md"

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
    # against the registered list. The song and view addresses are admitted by
    # exact match, so a typo on the *Elixir* side excludes itself from that
    # check — `vendored?/1` simply stops recognising it, and `used` quietly
    # shrinks by one (the >= 10 floor above doesn't notice either).
    # Pinning that all six are still sent is what closes that direction.
    test "the exactly-listed song and view addresses are still the ones lib/ sends" do
      sent = Enum.map(used_addresses(), fn {address, _file} -> address end)

      for address <- @vendored_song_addresses ++ @vendored_view_addresses do
        assert address in sent,
               """
               #{address} is listed as an exactly-matched vendored address, but nothing under
               lib/ sends it.

               If it was typo'd on the Elixir side, that typo is invisible to the
               used→registered test above — these are recognised by exact match
               only, so a misspelling stops counting as vendored instead of failing.
               Fix the address, or drop it from @vendored_song_addresses /
               @vendored_view_addresses if it is genuinely no longer used.

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

    # Both file lists are hand-maintained, which is its own loophole: a
    # registering file in neither list is silently outside every doc check —
    # midimap.py was exactly that until the 2026-08-03 PR #62 counter-review
    # caught it. This census makes the lists self-verifying: any Python file
    # in the fork that registers an address must be claimed by one of them.
    # The fork's own Python test suites are excluded: they register addresses
    # against a stub server inside fixtures, which ship nothing to Live and so
    # have nothing to document.
    test "every fork file that registers an address is covered by a doc-coverage list" do
      registering =
        Path.wildcard("#{@source}/**/*.py")
        |> Enum.reject(&(&1 =~ ~r"/tests(_unit)?/"))
        |> Enum.filter(&(File.read!(&1) =~ "osc_server.add_handler("))
        |> Enum.sort()

      assert registering != [], "no fork file matches osc_server.add_handler( — census broken"

      covered = @handler_files ++ @upstream_handler_files

      for file <- registering do
        assert file in covered,
               """
               #{file} registers OSC addresses but is in neither @handler_files
               (vendored) nor @upstream_handler_files (upstream doc coverage), so
               nothing checks its addresses against #{@docs}. Add it to the right
               list.
               """
      end
    end

    # The loophole this closes: the docs-coverage test above reads only the
    # vendored files, so an upstream registration — literal or loop-generated —
    # could stay undocumented forever, and did (19 of them until 2026-08-03).
    # Listener addresses ride the docs' per-family convention: a
    # start_listen/stop_listen pair counts as documented when its family's
    # get/<property> is, which every family section now states generically.
    test "every address an upstream handler registers is in the canonical address docs" do
      docs = File.read!(@docs)

      addresses =
        @upstream_handler_files
        |> Enum.flat_map(&upstream_registered_addresses/1)
        |> Enum.uniq()

      # The extraction reads Python lists with a regex; if the fork
      # restructures registration this floor fails loudly instead of the check
      # quietly covering nothing. 462 at the 2026-08-03 pin (an earlier
      # version of this comment said ~490 — that run had swept in the
      # vendored files' literals). The count grows as the fork gains
      # addresses; the floor, not the census, is what's load-bearing.
      assert length(addresses) >= 400,
             "expected 400+ upstream addresses, got #{length(addresses)} — " <>
               "the list extraction in upstream_registered_addresses/1 no longer " <>
               "matches the fork's registration style."

      for address <- addresses do
        assert documented?(docs, address),
               """
               #{address} is registered by an upstream handler in #{@source} but
               missing from #{@docs}.

               That file is the canonical list every tool is written against, and
               .claude/rules/osc.md says an address that isn't in it doesn't exist.
               Document it (a listener pair is covered by documenting the family's
               get/<property> plus the family's generic listener statement), or —
               if the extraction misread the Python — fix
               upstream_registered_addresses/1.
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

    test "the browser handler registers exactly the seven documented addresses" do
      assert Enum.sort(registered_addresses(@browser_file)) == [
               "/live/browser/export",
               "/live/browser/get/items",
               "/live/browser/load_item",
               "/live/browser/load_item_on_master",
               "/live/browser/load_item_on_return",
               "/live/browser/preview_item",
               "/live/browser/stop_preview"
             ]
    end

    test "the return/master handler registers exactly the fifty-one documented addresses" do
      assert Enum.sort(registered_addresses(@return_track_file)) == [
               "/live/master/delete_device",
               "/live/master/device/get/name",
               "/live/master/device/get/parameter/value",
               "/live/master/device/get/parameter/value_string",
               "/live/master/device/get/parameters",
               "/live/master/device/set/parameter/value",
               "/live/master/get/cue_volume",
               "/live/master/get/devices",
               "/live/master/get/panning",
               "/live/master/get/volume",
               "/live/master/select",
               "/live/master/select_device",
               "/live/master/set/cue_volume",
               "/live/master/set/panning",
               "/live/master/set/volume",
               "/live/master/start_listen/cue_volume",
               "/live/master/start_listen/panning",
               "/live/master/start_listen/volume",
               "/live/master/stop_listen/cue_volume",
               "/live/master/stop_listen/panning",
               "/live/master/stop_listen/volume",
               "/live/return_track/delete_device",
               "/live/return_track/device/get/name",
               "/live/return_track/device/get/parameter/value",
               "/live/return_track/device/get/parameter/value_string",
               "/live/return_track/device/get/parameters",
               "/live/return_track/device/set/parameter/value",
               "/live/return_track/get/count",
               "/live/return_track/get/devices",
               "/live/return_track/get/mute",
               "/live/return_track/get/name",
               "/live/return_track/get/panning",
               "/live/return_track/get/solo",
               "/live/return_track/get/volume",
               "/live/return_track/select",
               "/live/return_track/select_device",
               "/live/return_track/set/mute",
               "/live/return_track/set/name",
               "/live/return_track/set/panning",
               "/live/return_track/set/solo",
               "/live/return_track/set/volume",
               "/live/return_track/start_listen/mute",
               "/live/return_track/start_listen/name",
               "/live/return_track/start_listen/panning",
               "/live/return_track/start_listen/solo",
               "/live/return_track/start_listen/volume",
               "/live/return_track/stop_listen/mute",
               "/live/return_track/stop_listen/name",
               "/live/return_track/stop_listen/panning",
               "/live/return_track/stop_listen/solo",
               "/live/return_track/stop_listen/volume"
             ]
    end

    # The mixer listeners are keyed ("value", (index, prop)) rather than
    # ("value", (index,)): the base class derives remove_value_listener from the
    # *prop* half, which forces every DeviceParameter listener to register under
    # "value", so the discriminator has to live in the params half. Lose it and
    # subscribing a return's pan silently evicts its volume listener — every
    # address still answers, and the mirror just stops following one fader.
    test "the mixer listeners discriminate their keys by property, not by index alone" do
      source = File.read!(@return_track_file)

      for key <- [
            ~s|listener_params=(index, "volume")|,
            ~s|listener_params=(index, "panning")|,
            ~s|listener_params=("master", "volume")|,
            ~s|listener_params=("master", "panning")|,
            ~s|listener_params=("master", "cue_volume")|
          ] do
        assert String.contains?(source, key),
               """
               #{@return_track_file} no longer registers a mixer listener with #{key}.

               All of them register under the prop "value" (the base class derives
               remove_value_listener from it), so two mixer parameters sharing an
               index would share a listener key — and the second subscribe would
               silently unbind the first. Nothing on the wire changes; the mirror
               just stops following one of them.
               """
      end
    end

    test "the song structure handler registers exactly the four documented addresses" do
      assert Enum.sort(registered_addresses(@song_structure_file)) == [
               "/live/song/start_listen/return_tracks",
               "/live/song/start_listen/tracks",
               "/live/song/stop_listen/return_tracks",
               "/live/song/stop_listen/tracks"
             ]
    end

    # view.py is upstream's file with eleven of ours added, so unlike the three
    # handlers above this list is mostly upstream's. Pinning the whole of it is
    # what makes an upstream merge that drops our additions fail here rather
    # than in Live: nothing else notices, because every *other* address still
    # answers and ours fail the way all OSC fails — silently. `hide_view` fails
    # that way too despite the tool reading it back: without the address the
    # read-after reports the pane still visible, which is indistinguishable from
    # Live simply refusing to hide it.
    test "the view handler registers upstream's twelve addresses plus Seshat's eleven" do
      assert Enum.sort(registered_addresses(@view_file)) == [
               "/live/view/get/is_view_visible",
               "/live/view/get/mod_mapping_device",
               "/live/view/get/mod_mapping_parameter",
               "/live/view/get/selected_chain",
               "/live/view/get/selected_clip",
               "/live/view/get/selected_device",
               "/live/view/get/selected_parameter",
               "/live/view/get/selected_scene",
               "/live/view/get/selected_track",
               "/live/view/get/selected_track_identity",
               "/live/view/hide_view",
               "/live/view/set/detail_clip",
               "/live/view/set/selected_clip",
               "/live/view/set/selected_device",
               "/live/view/set/selected_scene",
               "/live/view/set/selected_track",
               "/live/view/show_view",
               "/live/view/start_listen/selected_scene",
               "/live/view/start_listen/selected_track",
               "/live/view/start_listen/selected_track_identity",
               "/live/view/stop_listen/selected_scene",
               "/live/view/stop_listen/selected_track",
               "/live/view/stop_listen/selected_track_identity"
             ]
    end

    # The registration list above proves the addresses exist; this proves the
    # fork still *records* that they are ours. SESHAT.md is what the next
    # upstream merge is read against, and an entry that silently stops naming an
    # address is how a merge drops it without anyone noticing — the same
    # reasoning as the osc_server.py assertions further down, applied to the one
    # divergence that lives inside an upstream file.
    test "SESHAT.md records the view.py additions by address" do
      source = File.read!("priv/AbletonOSC/SESHAT.md")

      for address <- @vendored_view_addresses do
        assert String.contains?(source, address),
               """
               priv/AbletonOSC/SESHAT.md no longer names #{address} in its view.py
               divergence entry.

               That file is the fork's only record of what we changed and why. An
               address missing from it is an address the next upstream merge has no
               reason to keep.
               """
      end
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

    # The stored-object contract has two halves: the base class *reads*
    # listener_objects, and every hand-rolled DeviceParameter listener has to
    # *populate* it. An upstream merge can revert track.py or device.py while
    # leaving handler.py intact — every address still answers, the grep above
    # stays green, and mixer/parameter listeners silently regain both bugs.
    test "every DeviceParameter listener stores the object it registered on" do
      for file <- [
            "priv/AbletonOSC/abletonosc/track.py",
            "priv/AbletonOSC/abletonosc/device.py"
          ] do
        assert File.read!(file) =~ "self.listener_objects[listener_key] = parameter_object",
               """
               #{file} no longer stores the DeviceParameter it registered its
               listener on in listener_objects.

               Without that entry, the base _stop_listen falls back to unbinding
               from the object it was handed — the wrong one once an index has been
               renumbered — and _clear_listeners raises KeyError on script reload.
               Those are the two bugs the fork fixes. See SESHAT.md's merge hazards.
               """
      end
    end
  end

  # The device/parameter lookups on a return or the master track echo every
  # index they were asked about, including on a failure two levels up — a bad
  # return index still has to report the parameter index the caller sent, or
  # the caller's own echo check treats the reply as desynced and retries into
  # a timeout that reads exactly like "Ableton isn't running". `_echo_index`
  # is what makes that work by parsing the deeper index instead of assuming
  # -1; losing it back to a literal -1 passes every other test in this file,
  # since the address still answers and the getters this affects are already
  # exercised by other tests through their happy path.
  describe "the echoed index on a failed outer device/parameter lookup" do
    test "_echo_index parses the position instead of assuming -1" do
      source = File.read!(@return_track_file)

      assert source =~ "def _echo_index(params: Tuple[Any], position: int) -> int:",
             "#{@return_track_file} no longer defines _echo_index."

      assert source =~ "return int(params[position])",
             """
             #{@return_track_file}'s _echo_index no longer parses params[position].

             Without it, a bad return or device index makes the deeper
             device/parameter index in the error reply come back as a hardcoded -1
             instead of the value the caller actually asked about. The caller's
             echo check then sees a reply that doesn't correlate with its query,
             retries, and eventually times out — the false "try again" this
             function exists to prevent.
             """
    end

    # The three call sites that need the deeper echo when an outer lookup
    # already failed. Any one of them reverting to a literal -1 (as they used
    # to be) is invisible to every other check here: the address still
    # answers, and a *good* index at every depth is already covered elsewhere.
    test "every outer-failure echo of a deeper index calls _echo_index" do
      source = File.read!(@return_track_file)

      for call <- [
            ~s|_echo_index(params, 1)|,
            ~s|_echo_index(params, 2)|
          ] do
        assert String.contains?(source, call),
               """
               #{@return_track_file} no longer calls #{call}.

               This is one of the sites that echoes a deeper index (device or
               parameter) back to the caller after an outer lookup (return track or
               device) already failed. A literal -1 there desyncs the reply from
               the query that asked about it — see _echo_index's docstring.
               """
      end

      assert length(String.split(source, "_echo_index(params,")) == 4,
             """
             #{@return_track_file} calls _echo_index(params, ...) a different
             number of times than expected (3 call sites: _return_device,
             _return_device_parameter, _master_device_parameter).

             If this changed on purpose, update the count here; if not, a call
             site regressed back to a literal -1.
             """
    end
  end

  # `/live/clip/quantize` is invisible to both checks above by construction:
  # clip.py registers its addresses in a loop (`"/live/clip/%s" % method`), so
  # the literal-grep `registered_addresses/1` can't see it, and `/live/clip/` is
  # not a vendored prefix, so the Elixir-side literal isn't swept into
  # `used_addresses` either. Losing `"quantize"` from that methods list in an
  # upstream merge would be exactly as silent as every other loss in this file —
  # the address simply stops existing, and a send-only address that no longer
  # exists is indistinguishable from one that worked.
  #
  # clip.py deliberately does *not* join @handler_files: its loop registration
  # would make `registered_addresses/1` under-report and trip the docs test
  # falsely.
  describe "the quantize method on the clip handler" do
    @clip_file "priv/AbletonOSC/abletonosc/clip.py"

    # The double-quoted literal, not the bare word: `quantize` appears twice
    # in clip.py — once in the prose comment above the methods list, once as
    # the list entry — so a grep for the bare word stays green after the entry
    # is deleted, which is precisely the regression this test exists to catch.
    test "clip.py still registers quantize in its generic methods list" do
      assert File.read!(@clip_file) =~ ~s("quantize"),
             """
             #{@clip_file} no longer lists "quantize" among its generic methods.

             That single list entry is the whole of /live/clip/quantize — it is a
             fork addition (upstream PR #198), taken into clip.py rather than a
             handler file of ours, so nothing else in this suite can see it. Without
             it the address is unregistered, and since it never replies even when it
             works, Seshat's quantize_clip tool would report success forever while
             moving nothing.

             Reinstate it and check SESHAT.md's "Additions to upstream's code".
             """
    end
  end

  # `swing_amount` is the same shape of blind spot one file over: song.py builds
  # its addresses in a loop (`"/live/song/set/%s" % prop`), so the literal-grep
  # `registered_addresses/1` can't see them, and `/live/song/` is a prefix
  # upstream owns, so the Elixir-side literals aren't swept into
  # `used_addresses` either. song.py therefore deliberately does *not* join
  # @handler_files, and these addresses deliberately do *not* join
  # @vendored_song_addresses — either would make the checks above under-report
  # and fail falsely.
  describe "the swing_amount property on the song handler" do
    @song_file "priv/AbletonOSC/abletonosc/song.py"

    test "song.py still lists swing_amount among its read/write properties" do
      contents = File.read!(@song_file)

      assert contents =~ ~s("swing_amount"),
             """
             #{@song_file} no longer lists "swing_amount" in properties_rw.

             That single list entry is the whole of /live/song/get/swing_amount,
             /live/song/set/swing_amount and their listeners — a fork addition
             upstream does not have (it exposes groove_amount only), so nothing
             else in this suite can see it. Without it, Seshat's set_swing_amount
             tool reports success forever while nothing swings, and
             get_session_state's swing value goes permanently unknown.

             Reinstate it and check SESHAT.md's "Additions to upstream's code".
             """

      # One entry, not two: the property is registered by a single line in
      # properties_rw, and a duplicate would mean an upstream merge re-added it
      # somewhere else — worth looking at rather than silently tolerating.
      assert length(String.split(contents, ~s("swing_amount"))) == 2,
             ~s(#{@song_file} mentions "swing_amount" more than once; expected the single properties_rw entry.)
    end
  end

  # The two undo-step methods are the same blind spot again, and worse: they are
  # entries in song.py's *generic methods* list, so the loop
  # (`"/live/song/%s" % method`) hides them from `registered_addresses/1`, and
  # `/live/song/` is upstream's prefix so the Elixir literals aren't swept into
  # `used_addresses` either. Unlike swing, losing them has no symptom that any
  # test or any reply could show: both addresses are send-only, so the datagrams
  # go out and nothing answers them whether they are registered or not. Undo just
  # quietly goes back to reverting whole conversations at a time.
  describe "the undo step boundary methods on the song handler" do
    test "song.py still registers begin_undo_step and end_undo_step" do
      contents = File.read!(@song_file)

      for method <- ["begin_undo_step", "end_undo_step"] do
        assert contents =~ ~s("#{method}"),
               """
               #{@song_file} no longer lists "#{method}" in its generic methods list.

               That single list entry is the whole of /live/song/#{method} — a fork
               addition upstream does not have, and one nothing else in this suite can
               see (the address is built in a loop, and it never replies). Without it,
               Seshat.Tools.Handlers.call/2 keeps sending the address forever while Live
               groups tool calls into undo steps by its own rules again: one undo can
               then revert an entire conversation.

               Reinstate it and check SESHAT.md's "Additions to upstream's code".
               """

        assert length(String.split(contents, ~s("#{method}"))) == 2,
               ~s(#{@song_file} mentions "#{method}" more than once; expected the single methods-list entry.)
      end
    end

    # The other direction: the Elixir side sends these as literals, and a typo
    # there is invisible for exactly the same reason (no reply, upstream prefix).
    test "the handlers still send both addresses as literals" do
      contents = File.read!("lib/seshat/tools/handlers.ex")

      for address <- ["/live/song/begin_undo_step", "/live/song/end_undo_step"] do
        assert contents =~ ~s("#{address}"),
               """
               lib/seshat/tools/handlers.ex no longer sends #{address} as a string literal.

               `call/2` wraps every known tool dispatch in a begin/end pair so that one
               tool call is one Ableton undo step. Interpolating or dropping either
               address fails the way all OSC fails — silently — and the only symptom is
               a user's undo reverting more than they asked for.
               """
      end
    end
  end

  # Two deliberate departures from upstream's *behaviour*, neither of which any
  # address-level check can see: upstream's OSC socket binds every interface and
  # retargets its default reply address to whoever spoke last, which handed full,
  # unauthenticated control of Live to anything the machine's network boundary
  # let through. Losing either in an upstream merge is invisible from this
  # machine — loopback traffic behaves identically — so the regression would be
  # silent remote exposure. The behaviour itself only exists inside Live, so a
  # grep is the only guard available here, exactly as for the listener fix above.
  describe "the loopback-only network boundary" do
    @osc_server "priv/AbletonOSC/abletonosc/osc_server.py"
    @seshat_md "priv/AbletonOSC/SESHAT.md"

    test "the OSC socket binds loopback, not the wildcard address" do
      source = File.read!(@osc_server)

      assert source =~ "local_addr: Tuple[str, int] = ('127.0.0.1', OSC_LISTEN_PORT)",
             """
             #{@osc_server}'s OSCServer no longer defaults to binding 127.0.0.1.

             Manager constructs OSCServer() with no arguments, so this default is the
             whole network boundary: upstream's ('0.0.0.0', OSC_LISTEN_PORT) exposes
             every Live-controlling OSC address, unauthenticated, on every interface.
             Restore the loopback default — see SESHAT.md in the fork. A networked
             controller needs an explicit opt-in bind and a security design, never a
             restored wildcard.
             """

      refute source =~ "0.0.0.0",
             "#{@osc_server} mentions the wildcard address again — see SESHAT.md."
    end

    test "the default reply address is never retargeted to the last sender" do
      source = File.read!(@osc_server)

      refute source =~ ~r/self\._remote_addr\s*=\s*\(/,
             """
             #{@osc_server}'s process() assigns a tuple to self._remote_addr again.

             That is upstream's per-datagram retargeting: listener pushes,
             /live/startup, /live/error and /live/test would follow whichever client
             spoke last instead of the fixed 127.0.0.1 response port. The only
             assignment that belongs is __init__'s `self._remote_addr = remote_addr`.
             """

      assert source =~ "self._remote_addr = remote_addr",
             "#{@osc_server} no longer takes its default remote address from __init__."
    end

    test "SESHAT.md records both deviations" do
      source = File.read!(@seshat_md)

      assert source =~ "### Deliberate changes to upstream's behaviour",
             """
             #{@seshat_md} lost the section recording the loopback bind and the removed
             reply retargeting. That file is the only record of what this fork changed
             and why, and it is what the next upstream merge is read against.
             """

      assert source =~ "osc_server.py",
             "#{@seshat_md} no longer mentions osc_server.py."
    end
  end

  # The structured /live/error payload has the same failure mode as the boundary
  # above: lose it in an upstream merge and nothing breaks loudly. Every address
  # still answers, every error still reaches Log.txt and /live/error, and
  # `mix test` stays green — Seshat just quietly goes back to paying a full
  # query timeout for every rejection Live already announced. The payload is
  # built inside Live, so a grep is again the only guard available here.
  describe "the structured /live/error payload" do
    @manager_file "priv/AbletonOSC/manager.py"

    test "osc_server.py catches a raising callback and sends the request with the error" do
      source = File.read!(@osc_server)

      assert source =~ ~s|self.send("/live/error",| and
               source =~ ~s|len(message.params), *message.params))|,
             """
             #{@osc_server} no longer sends the structured
             /live/error ["request", address, message, arg_count, *args] payload.

             The dispatch boundary is the only place the failing request's address
             and arguments are still in scope — upstream lets the exception unwind
             to process()'s per-datagram catch, where they are gone. Without this
             send, Seshat.OSC.Transport cannot correlate a rejection with the query
             it belongs to, and every rejected query waits out its full timeout
             again. See SESHAT.md in the fork.

             The tail half of that payload — `len(message.params), *message.params`
             — is asserted separately and deliberately: correlation is by address
             *and* every argument, so an upstream merge that kept the "request" tag
             but dropped the count and the echoed args would leave this test and
             every pure Transport test green (they synthesize the whole payload
             themselves) while every real rejection from Live silently stopped
             matching and went back to paying a full timeout.
             """

      assert_address_then_detail(source)

      assert source =~ ~s|extra={"osc_request_error": True}|,
             """
             #{@osc_server} no longer marks the error record as already sent.

             manager.py's log relay reads that marker to skip records the structured
             send has already carried. Without it, one failure produces two
             /live/error datagrams.
             """
    end

    test "manager.py's relay tags its payload and skips already-sent records" do
      source = File.read!(@manager_file)

      assert source =~ ~s|self.osc_server.send("/live/error", ("log", message))|,
             """
             #{@manager_file}'s LiveOSCErrorLogHandler no longer tags its relay payload
             with "log".

             Seshat.OSC.Transport distinguishes the two /live/error shapes by that
             first element: a "log" payload is never correlated to a query, while an
             untagged one-string payload is upstream's and equally uncorrelatable.
             Dropping the tag makes an uncorrelatable error indistinguishable from a
             malformed structured one.
             """

      assert source =~ ~s|getattr(record, "osc_request_error", False)|,
             """
             #{@manager_file}'s LiveOSCErrorLogHandler no longer skips records that
             osc_server.py has already sent structured.

             Without the skip, every handler rejection goes out twice: once as
             ["request", ...] and once as ["log", ...].
             """
    end

    test "SESHAT.md records the divergence" do
      source = File.read!(@seshat_md)

      assert source =~ "/live/error` carries the request that",
             """
             #{@seshat_md} lost the entry recording the structured /live/error payload.

             That file is the only record of what this fork changed and why, and it is
             what the next upstream merge is read against.
             """
    end
  end

  # The browser export writes a file with Live's privileges. It used to write
  # wherever the request said; now the request carries no path at all and Python
  # picks a fresh file inside a fixed root. Like the boundary above this is
  # behaviour that only runs inside Live, so these greps are what protects the
  # contract across an upstream merge — the Live smoke test is the behavioural
  # proof, since importing the handler needs Live's embedded Python.
  describe "the browser export's fixed destination" do
    test "no destination is derived from the request parameters" do
      source = File.read!(@browser_file)

      refute source =~ ~r/dest_path\s*=\s*str\(params/,
             """
             #{@browser_file} derives an export destination from the request again.

             A caller-supplied path is opened with Live's privileges. The export takes
             no arguments: it chooses a file inside EXPORT_ROOT and returns the path.
             """

      assert source =~ "export takes no arguments",
             "#{@browser_file} no longer rejects a request that carries arguments."
    end

    test "exports are created with mkstemp inside the fixed export root" do
      source = File.read!(@browser_file)

      assert source =~
               ~s|EXPORT_ROOT = os.path.abspath(os.path.expanduser("~/.seshat/browser-exports"))|,
             """
             #{@browser_file}'s EXPORT_ROOT changed spelling.

             Seshat.Library.Catalog validates the returned path against
             Path.expand("~/.seshat/browser-exports"), which resolves no symlinks —
             so this must stay expanduser + abspath, never realpath, or every reindex
             fails its root check on a machine with a symlinked ~/.seshat.
             """

      assert source =~ "tempfile.mkstemp(" and source =~ "dir=EXPORT_ROOT",
             """
             #{@browser_file} no longer allocates its export with
             tempfile.mkstemp(dir=EXPORT_ROOT).

             mkstemp is what makes the create exclusive, the name unguessable and the
             mode owner-only — an open() on a name this code composed itself brings
             back the collision and pre-existing-file cases it removed.
             """
    end

    test "the stale sweep keeps its age gate and its regular-file guard" do
      source = File.read!(@browser_file)

      assert source =~ "EXPORT_STALE_SECONDS = 10 * 60",
             """
             #{@browser_file}'s stale-export age gate changed.

             It is load-bearing, not hygiene: Transport serializes queries, but the
             file read happens *after* the query resolves — a second export (and the
             sweep that precedes it) can run while the first export's caller is still
             reading its file. Ten minutes is well past the 120s query timeout plus
             any plausible read.
             """

      assert source =~ "info.st_mtime > cutoff",
             "#{@browser_file}'s stale sweep no longer compares mtime against a cutoff."

      assert source =~ "os.lstat(" and source =~ "stat.S_ISREG(",
             """
             #{@browser_file}'s stale sweep no longer gates removal on os.lstat
             reporting a regular file.

             Without it the sweep follows symlinks and can delete something outside
             the export root that merely happens to be named like an export.
             """
    end
  end

  # The `("request", …)` payload's *order* is the wire contract, not just its
  # membership: Seshat.OSC.Transport reads slot 2 as the address it correlates
  # against the in-flight query and slot 3 as the human message it renders. Swap
  # them and every rejected query stops correlating — Transport compares the
  # error text to the pending address, never matches, and pays out the full
  # timeout. That is precisely the regression this whole describe block exists
  # to prevent, so a guard that accepts the swapped tuple is worse than none.
  #
  # But the slots must stay free to be *renamed*. The address has already been
  # spelled `message.address` (when the send lived inline in process_message's
  # exact-match branch) and `error_address` (once both branches were funnelled
  # through OSCServer._dispatch), and a guard that fails on a rename is a guard
  # that gets weakened to shut it up — which is how it came to accept a reorder
  # in the first place.
  #
  # So the slots are identified by where their values *come from*, which no
  # rename changes and a reorder cannot satisfy:
  #
  #   - the address is handed in by the caller, so its root name is a parameter
  #     of _dispatch (`error_address`, or `message` in `message.address`);
  #   - the detail is built locally from the caught exception, so its name is
  #     assigned from `str(...)` inside the function and is *not* a parameter.
  #
  # Swapping the two fails both halves at once. A refactor that inlines either
  # slot as a bare expression rather than a name also fails here, deliberately:
  # this call site is the wire format, and a change to its shape is a thing a
  # human should have to look at rather than a thing a regex should wave through.
  defp assert_address_then_detail(source) do
    slots =
      Regex.run(~r/\(\s*"request"\s*,\s*([\w.]+)\s*,\s*([\w.]+)\s*,/, source,
        capture: :all_but_first
      )

    assert slots,
           """
           #{@osc_server}'s structured /live/error payload no longer has a plain
           name in its address and detail slots, so this guard cannot tell which
           slot is which any more.

           Seshat reads that tuple positionally — slot 2 is the address it
           correlates a pending query against, slot 3 is the message it renders.
           Re-derive this check against the new shape rather than relaxing it;
           see Seshat.OSC.Transport's "Failed-query correlation" section for what
           depends on the order.
           """

    [address_slot, detail_slot] = slots
    params = dispatch_parameters(source)
    address_root = address_slot |> String.split(".") |> hd()
    detail_root = detail_slot |> String.split(".") |> hd()

    assert address_root in params,
           """
           #{@osc_server} sends `#{address_slot}` in the address slot of its
           structured /live/error payload, but that name is not a parameter of
           _dispatch — so it is not the request address the caller handed in.

           The likeliest cause is that the address and detail slots have been
           swapped. Seshat.OSC.Transport reads slot 2 as the address to correlate
           against the in-flight query; given the error text there instead, no
           rejection ever matches and every rejected query waits out its full
           timeout — silently, because the error still arrives and Live's log
           still shows it.

           _dispatch parameters: #{inspect(params)}
           """

    assert detail_root not in params and source =~ ~r/\b#{Regex.escape(detail_root)}\s*=\s*str\(/,
           """
           #{@osc_server} sends `#{detail_slot}` in the detail slot of its
           structured /live/error payload, but that name is a parameter of
           _dispatch rather than a message built locally from the caught
           exception (`#{detail_root} = str(...)`).

           The likeliest cause is that the address and detail slots have been
           swapped — see the address assertion above for what that costs. If the
           message is genuinely constructed somewhere new, re-derive this check
           against that rather than dropping it.

           _dispatch parameters: #{inspect(params)}
           """
  end

  # Parameter *names* of `def _dispatch(...)`, with any default value or type
  # annotation stripped. Used to tell a value the caller handed in from one the
  # function built itself.
  defp dispatch_parameters(source) do
    case Regex.run(~r/def _dispatch\(([^)]*)\)/s, source, capture: :all_but_first) do
      [params] ->
        params
        |> String.split(",")
        |> Enum.map(fn param ->
          param |> String.split(["=", ":"]) |> hd() |> String.trim()
        end)
        |> Enum.reject(&(&1 in ["", "self"]))

      _ ->
        flunk("""
        #{@osc_server} has no `def _dispatch(...)` to read parameters from, so the
        structured /live/error payload's address slot cannot be distinguished from
        its detail slot.

        If the dispatch boundary moved or was renamed, re-derive this guard
        against the new one — Seshat.OSC.Transport still reads that payload
        positionally either way.
        """)
    end
  end

  # `add_handler("/live/...", ...)` — the one way a handler registers an address.
  # Either quote style: our own files use double quotes throughout, but upstream's
  # view.py (which now carries two of ours) mixes in single-quoted registrations,
  # and a regex that missed those would under-report what the file registers —
  # a tripwire that quietly stops tripping.
  defp registered_addresses(file) do
    ~r/add_handler\(\s*['"](\/live\/[^'"]+)['"]/
    |> Regex.scan(File.read!(file))
    |> Enum.map(fn [_match, address] -> address end)
  end

  defp registered_addresses, do: Enum.flat_map(@handler_files, &registered_addresses/1)

  # Upstream files register addresses two ways: literal add_handler calls
  # (caught by registered_addresses/1) and loops over `methods`,
  # `properties_r`, `properties_rw` and track.py's `mixer_properties_rw`
  # lists, expanded here with the pattern every handler shares:
  # methods → /live/<family>/<m>; readable properties → get + a
  # start_listen/stop_listen pair; writable ones → those plus set. The
  # family is the file's basename (song.py → /live/song/...), which holds
  # for every file in @upstream_handler_files; manager.py has no lists.
  defp upstream_registered_addresses(file) do
    source = File.read!(file)
    family = Path.basename(file, ".py")

    expanded =
      ~r/^\s*(methods|properties_r|properties_rw|mixer_properties_rw)\s*=\s*\[(.*?)\]/ms
      |> Regex.scan(source)
      |> Enum.flat_map(fn [_match, list_name, body] ->
        entries =
          body
          |> String.split("\n")
          |> Enum.map(&String.replace(&1, ~r/#.*/, ""))
          |> Enum.flat_map(fn line ->
            Regex.scan(~r/"([^"]+)"/, line) |> Enum.map(fn [_, entry] -> entry end)
          end)

        Enum.flat_map(entries, &expand_registration(family, list_name, &1))
      end)

    # The literal scan also matches the loops' format strings
    # ("/live/song/%s" % method) — those are the templates the expansion
    # above already covers, not addresses.
    literals = Enum.reject(registered_addresses(file), &String.contains?(&1, "%s"))

    literals ++ expanded
  end

  defp expand_registration(family, "methods", entry), do: ["/live/#{family}/#{entry}"]

  defp expand_registration(family, "properties_r", entry) do
    [
      "/live/#{family}/get/#{entry}",
      "/live/#{family}/start_listen/#{entry}",
      "/live/#{family}/stop_listen/#{entry}"
    ]
  end

  defp expand_registration(family, _rw, entry) do
    ["/live/#{family}/set/#{entry}" | expand_registration(family, "properties_r", entry)]
  end

  # An address is documented when it appears literally, or — for a
  # start_listen/stop_listen pair — when its getter and both family-level
  # listener templates do. The docs state listener addresses once per family,
  # generically, rather than as 200-odd rows.
  defp documented?(docs, address) do
    String.contains?(docs, address) or
      case Regex.run(~r{^/live/([a-z_]+)/(?:start|stop)_listen/(.+)$}, address) do
        [_, family, property] ->
          case Map.fetch(@listener_doc_markers, family) do
            {:ok, markers} ->
              String.contains?(docs, "/live/#{family}/get/#{property}") and
                Enum.all?(markers, &String.contains?(docs, &1))

            :error ->
              false
          end

        nil ->
          false
      end
  end

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
      address in @vendored_song_addresses or
      address in @vendored_view_addresses
  end
end
