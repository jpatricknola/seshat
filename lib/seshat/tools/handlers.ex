defmodule Seshat.Tools.Handlers do
  @moduledoc """
  Dispatches tool calls to their implementations.

  Takes an MCP tool name and input map and returns a result suitable for sending
  back to the model. Single-message tools talk to `Seshat.OSC.Transport`
  directly; multi-step sequences build a `%Command{}` and execute it via
  `Seshat.Commands.Registry`.
  """

  require Logger

  alias Seshat.Commands.{Command, Registry}
  alias Seshat.Library.Catalog
  alias Seshat.Music.Pitch
  alias Seshat.OSC.Transport
  alias Seshat.Session.State
  alias Seshat.Tools.Definitions
  alias Seshat.Tools.FollowCam
  alias Seshat.Tools.NoteEdit
  alias Seshat.Tools.Validation

  # Which names get an undo step wrapped around them. Validation deliberately
  # lets an unknown name through to `do_call/2`'s catch-all, so membership here
  # is what separates a real tool from a typo — without a second tool list to
  # keep in sync by hand. Same compile-time derivation as `Seshat.MCP.Server`.
  @tool_names MapSet.new(Definitions.all(), & &1.name)

  # ...minus the ones whose definition opts out. `Definitions.unstepped_names/0`
  # is the single source: a tool declares `undo_step: false` beside its own
  # description, and nothing here has to be kept in sync by hand.
  @unstepped_names MapSet.new(Definitions.unstepped_names())

  # Browsing and loading are both far slower than a property read: the first
  # walk of a big browser category takes seconds, and a heavy plugin can take
  # tens of seconds to instantiate.
  @browse_timeout 15_000
  @load_timeout 30_000

  # Guards that run before a mutation read a single track/slot property —
  # roughly 100ms per round trip through the serialized query queue (the
  # 2026-08-03 mirror-rebuild run, docs/smoke_tests/auto/mirror.md: 4.6s over
  # ~46 serialized queries), not the sub-millisecond loopback suggests. That
  # 100ms is AbletonOSC's scheduling tick, not the wire: a query costs a tick
  # because it waits for the next one, and a tick answers everything already
  # queued on the socket. So a *group* of reads costs one tick between them when
  # it goes out as a `Transport.query_batch/2` burst, which is what the clip,
  # sends and device reads do — a lone guard like these still costs its own.
  # Measured 2026-08-04; priv/AbletonOSC/API.md, "Round trips cost ticks,
  # not datagrams".
  # A bad index sends no reply on the queried address
  # (AbletonOSC raises inside the callback), but since the structured
  # /live/error correlation shipped (2026-08-03) Transport fails that query
  # almost at once (212ms measured end-to-end through the MCP harness, Python
  # startup included — docs/smoke_tests/auto/bridge.md; the Transport-level
  # wait is a fraction of that) — so this timeout is the backstop for a lost
  # datagram or a missing install, no longer the usual bad-index path. The
  # house 5s default would turn that backstop into a five-second stall.
  @guard_timeout 2_000

  @default_max_results 25
  @default_catalog_results 15

  # Marks search steering text as model-internal, at the point of use. The
  # 2026-07-28 validation run had "No 'Warm' tag exists in your library" relayed
  # verbatim to a musician who never asked about tags: the diagnose/facet text
  # did its real job (steering the model's retry) but was never meant to be
  # quoted. It travels with the text it governs rather than sitting in the tool
  # description, so it reaches the model exactly when it matters.
  # Wording matches the session instructions' "speak music, not plumbing" rule.
  @diagnostics_internal "(Diagnostics are for refining your search — present results musically; " <>
                          "don't mention tags to the user.)"

  # Advice appended to a guard timeout, per address family.
  #
  # These used to say a bad index gets no reply at all, and a timeout therefore
  # nearly always meant a bad index. The fork's structured `/live/error` inverted
  # that: Live raises, AbletonOSC now sends the request back with the error, and
  # `Seshat.OSC.Transport` fails the query in milliseconds with the rejection
  # wording. A bad index is the one thing a guard timeout no longer means. What
  # is left is Ableton unreachable, AbletonOSC not enabled, a dropped datagram,
  # or a Remote Scripts copy predating the fork — and since that last one is
  # indistinguishable from here and re-reading indices is cheap, the index advice
  # stays, as the second thing to check rather than the first.
  @clip_index_hint "A bad index is normally rejected outright rather than met with silence, so " <>
                     "silence points at Ableton — check it is running with AbletonOSC enabled. " <>
                     "If it is, re-check the track and slot indices with get_clip_slots: a " <>
                     "Remote Scripts copy older than `mix abletonosc.install` still answers a " <>
                     "bad index with nothing."

  @send_index_hint "A bad index is normally rejected outright rather than met with silence, so " <>
                     "silence points at Ableton — check it is running with AbletonOSC enabled. " <>
                     "If it is, re-check the track index (get_session_state) and send index " <>
                     "(get_track_sends; sends are 0-based, send A = 0)."

  @track_index_hint "A bad index is normally rejected outright rather than met with silence, so " <>
                      "silence points at Ableton — check it is running with AbletonOSC enabled. " <>
                      "If it is, re-check the track index with get_session_state."

  @device_index_hint "A bad index is normally rejected outright rather than met with silence, " <>
                       "so silence points at Ableton — check it is running with AbletonOSC " <>
                       "enabled. If it is, re-check the track and device indices with " <>
                       "get_track_devices."

  # The return/master addresses are Seshat's own, and they always reply — a bad
  # index comes back as an error envelope, not silence. So unlike the upstream
  # families above, a timeout here isn't a bad index at all: it means nothing is
  # serving the address.
  @return_extension_hint "These addresses come from Seshat's AbletonOSC extension rather than " <>
                           "upstream, and it answers every query it receives — even for an index " <>
                           "that doesn't exist. Silence therefore means it isn't installed: run " <>
                           "`mix abletonosc.install` and restart Ableton Live, and check Live is " <>
                           "running with AbletonOSC enabled."

  # `/live/view/get/is_view_visible` is Seshat's too, and it answers every query
  # — including one naming a pane Live doesn't recognise, which comes back as an
  # error envelope rather than the silence `show_view` produces. So silence here
  # can only be a missing install, and the enum makes a bad name unreachable
  # anyway.
  @view_extension_hint "These addresses come from Seshat's AbletonOSC extension — " <>
                         "if this times out, the installed copy may predate them: run " <>
                         "`mix abletonosc.install` and restart Ableton Live."

  # Live's six pane names, in the order `get_view_state` reads them. The full set
  # is readable even though only two of them can be hidden — `show_view`'s enum
  # in `Definitions` is the same six, `hide_view`'s is deliberately narrower.
  @view_names ["Browser", "Arranger", "Session", "Detail", "Detail/Clip", "Detail/DeviceChain"]

  @doc false
  # Test-only window onto @view_names: it's a third hand-maintained copy of
  # show_view's six names (alongside Definitions' enum and the literal keys
  # main_view_line/2 and detail_panel_line/1 pattern-match on), with no
  # compiler tripwire if it drifts from them. A dropped or renamed entry here
  # leaves get_view_state's visibility map missing a key, and
  # main_view_line(nil, false) has no clause — a FunctionClauseError instead
  # of a graceful failure. Exposed so the test suite can assert set equality
  # against Definitions without going through Transport.query.
  def view_names, do: @view_names

  # --- Clip properties (get_clip_properties / set_clip_properties) ---
  #
  # Property names are the OSC address suffixes, so one list drives the schema,
  # the reads, the writes and the echo. The addresses themselves stay as
  # literals in `clip_get_address/1` / `clip_set_address/1` rather than being
  # interpolated from these names — the `"/live/` greppability rule.

  # Written to Live as 1/0.
  @clip_boolean_properties ["looping", "legato", "warping"]

  # Enums — written as integers, decoded to names in the replies.
  @clip_integer_properties ["launch_mode", "launch_quantization", "warp_mode"]

  # The two ordered pairs. Live requires start < end at all times, so each pair
  # is written in whichever order keeps that true after every single message
  # (see `clip_property_writes/2`).
  @clip_pair_properties [{"loop_start", "loop_end"}, {"start_marker", "end_marker"}]

  # Anything that changes the clip's audible extent — writing one of these makes
  # `length` worth reading back.
  @clip_range_properties ["looping", "loop_start", "loop_end", "start_marker", "end_marker"]

  # Unpaired properties, written last in this order. Order is fixed rather than
  # map-iteration order so the write list is deterministic and testable.
  # `name` rides this list rather than getting its own tool: it pairs with
  # nothing, so its position is arbitrary — last, after the numeric scalars.
  # It is also the one non-numeric value in the write list, which is why
  # `clip_property_writes/2`'s return type is `String.t() | number()`.
  @clip_scalar_properties [
    "launch_mode",
    "launch_quantization",
    "legato",
    "velocity_amount",
    "gain",
    "warp_mode",
    "warping",
    "name"
  ]

  # `Clip` only carries these on an audio clip. Reading one on a MIDI clip does
  # **not** raise: Live raises `RuntimeError` and
  # `AbletonOSCHandler._get_property` converts exactly that to `None`, so the
  # reply arrives normally carrying nil (`/live/clip/get/gain [0, 0, nil]` —
  # measured 2026-08-05, Live 12.4.3; priv/AbletonOSC/API.md). So the guard
  # buys a round trip and keeps meaningless nils out of the reply, not an
  # avoided error. Writing one is a different case, and the reason the setter
  # refuses rather than sending: an accepted-looking silent setter would report
  # a change Live never made.
  @clip_audio_only_properties ["gain", "warp_mode", "warping"]

  @clip_writable_properties @clip_range_properties ++ @clip_scalar_properties

  @clip_common_reads [
    "name",
    "length",
    "looping",
    "loop_start",
    "loop_end",
    "start_marker",
    "end_marker",
    "launch_mode",
    "launch_quantization",
    "legato",
    "velocity_amount"
  ]

  @clip_audio_reads ["gain", "gain_display_string", "warp_mode", "warping"]

  # --- The mixer (set_mixer) ---
  #
  # Fixed order rather than map-iteration order, so a multi-property call's
  # write list is deterministic and testable — the `@clip_scalar_properties`
  # precedent.
  @mixer_properties ~w(volume pan mute solo arm name)

  # What each strip actually has. Returns have no `arm` (return_track.py
  # registers none); the master has no mute, solo, arm or name setter at all
  # (`Session.State` mirrors none of them either, for the same reason — reading
  # one raises inside Live); cue is a single fader on the master. A property the
  # target lacks is refused before anything goes out, so a call is
  # all-or-nothing rather than partially applied.
  @mixer_supported %{
    "track" => ~w(volume pan mute solo arm name),
    "return" => ~w(volume pan mute solo name),
    "master" => ~w(volume pan),
    "cue" => ~w(volume)
  }

  # The two targets whose index means something. The schema cannot express
  # "required when target is one of these", so the handler reports the omission
  # by name.
  @mixer_indexed_targets ~w(track return)

  @launch_mode_names %{0 => "Trigger", 1 => "Gate", 2 => "Toggle", 3 => "Repeat"}

  @launch_quantization_names %{
    0 => "Global",
    1 => "None",
    2 => "8 bars",
    3 => "4 bars",
    4 => "2 bars",
    5 => "1 bar",
    6 => "1/2",
    7 => "1/2T",
    8 => "1/4",
    9 => "1/4T",
    10 => "1/8",
    11 => "1/8T",
    12 => "1/16",
    13 => "1/16T",
    14 => "1/32"
  }

  @warp_mode_names %{
    0 => "Beats",
    1 => "Tones",
    2 => "Texture",
    3 => "Re-Pitch",
    4 => "Complex",
    6 => "Complex Pro"
  }

  # Properties for the /live/song/get/track_data bulk query, in reply order.
  # Each track.* property contributes one value per track; each clip.* /
  # clip_slot.* property contributes num_scenes values — so a track's chunk is
  # 3 + 5 * num_scenes values. parse_track_data/3 depends on this exact order.
  @track_data_properties [
    "track.name",
    "track.has_midi_input",
    "track.is_foldable",
    "clip_slot.has_clip",
    "clip.name",
    "clip.length",
    "clip.is_playing",
    "clip.is_recording"
  ]

  # Batch size for track_data queries: keeps any single reply datagram far
  # below the Transport's 64KB socket buffer (a truncated datagram surfaces as
  # a mystery timeout). One batch covers any normal set.
  @track_data_target_values 4000

  # How long `capture_midi` waits before its single re-read, for the case where
  # Live defers inserting the captured clip past the LOM call's return. Short
  # enough to be invisible next to the round trips either side of it.
  @capture_retry_delay 250

  # A delete steers to whatever now occupies the index it emptied, which needs
  # the post-delete count. Best-effort by design: this read exists only to aim
  # the view, so it gets the guard timeout rather than the 5s default and a
  # miss simply skips the steering — never the tool's own success reply.
  @follow_cam_count_timeout 2_000

  @spec call(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def call(name, params) when is_binary(name) and is_map(params) do
    params = stringify_keys(params)

    # The one dispatch point, so the one place the declared schemas are
    # authoritatively enforced. Peri does not re-check every base type (see
    # `Seshat.Tools.Validation`). Nothing reaches Transport until the
    # parameters are known good.
    case Validation.validate(name, params) do
      :ok -> dispatch(name, params)
      {:error, message} -> {:error, message}
    end
  end

  # --- One tool call, one Ableton undo step ---
  #
  # Left to itself, Live decides where undo steps begin and end for a
  # control-surface script, and its rules are activity-sensitive: measured on
  # Live 12.4.3 (2026-08-01), `create_track` then `write_midi_notes` collapsed
  # into a single step — one undo deleted the whole track, notes and all — while
  # the same pair with an intervening timed-out call landed as two. Unpredictable
  # is worse than coarse: neither the user nor the model can learn what one undo
  # will do.
  #
  # `Song.begin_undo_step()` / `Song.end_undo_step()` (fork additions to
  # `song.py`, the same mechanism Ableton's own Push script uses) demarcate a
  # step explicitly. Wrapping here rather than around each datagram is the whole
  # point: a multi-message tool like `write_midi_notes` — create clip, add notes,
  # name it — reverts as one unit because the wrap encloses the entire dispatch.
  #
  # "One action" therefore means one *tool call*, not one user message. Seshat
  # never sees the original prompt, only the individual MCP calls, so "undo that
  # request" is one `undo` per mutating call — which is what the `undo` tool
  # description teaches the model.
  #
  # A tool can opt out, and exactly two do (`get_audio_outputs`,
  # `set_audio_output`). They reach Live through macOS Accessibility rather than
  # the LOM, changing an application preference rather than the Set — there is no
  # undo entry for a `begin`/`end` pair to demarcate, and sending the pair anyway
  # would put OSC datagrams on the wire for a tool that has no business touching
  # it (and would queue an audio-device change behind the OSC undo lock for no
  # reason). The opt-out lives in `Definitions` as `undo_step: false`, so the
  # claim is checkable from the tool list itself.
  defp dispatch(name, params) do
    cond do
      MapSet.member?(@unstepped_names, name) ->
        do_call(name, params)

      MapSet.member?(@tool_names, name) ->
        # Anubis serializes calls within one MCP session, but two clients can
        # still overlap — and `begin_undo_step` is measured *not* to refcount, so
        # without a global lock one caller's `end` closes another caller's step.
        # The resource id is shared; `self()` is the lock owner, which OTP
        # releases if the caller dies.
        stepped = fn -> undo_stepped(name, params) end
        :global.trans({{__MODULE__, :undo_step}, self()}, stepped, [node()])

      true ->
        # An unknown tool name must not touch the wire at all: it goes straight
        # to `do_call/2`'s catch-all, which also keeps pure tests calling
        # `call/2` without a running `Transport` alive.
        do_call(name, params)
    end
  end

  # Never wrapped — an undo inside an open step is a state this design never
  # creates. The lone `end` first is defensive: a `begin` leaked by a BEAM death
  # mid-call would otherwise fold the user's next undo into stale grouping.
  # An unmatched `end` is measured harmless (Live logs it as an ordinary method
  # call and the history is untouched).
  defp undo_stepped(name, params) when name in ["undo", "redo"] do
    _ = Transport.send_message("/live/song/end_undo_step", [])
    do_call(name, params)
  end

  # Read-only tools are wrapped too, deliberately: an empty begin/end pair is
  # measured to leave the undo history untouched, whereas a hand-maintained
  # list of mutating tools would fail silently the first time a new tool forgot
  # to join it.
  #
  # The lone `end` before the `begin` is the same defence `undo`/`redo` make,
  # and it is load-bearing for a sharper reason than closing a leak. `begin` does
  # not refcount, so a step left open by a BEAM death or by the failed `end` send
  # below is *still open* when this call's `begin` arrives — that `begin` is a
  # no-op, and the `end` in the `after` then closes a single step holding both
  # the leaked partial work and this call's mutation, which one `undo` would
  # revert together. Closing first gives the leak its own step and this call a
  # clean boundary, which is the whole guarantee. An unmatched `end` is measured
  # harmless, and the global lock means no other Seshat caller can hold a step
  # open for this to close out from under.
  defp undo_stepped(name, params) do
    _ = Transport.send_message("/live/song/end_undo_step", [])

    case Transport.send_message("/live/song/begin_undo_step", []) do
      :ok ->
        try do
          do_call(name, params)
        after
          # An `after` block cannot change the return value, so a failed `end`
          # is logged rather than swallowed: it means a step was left open, and
          # the only other trace would be the user's next undo behaving
          # strangely. No error is manufactured for a tool whose own work
          # succeeded — the next call closes the leak before opening its own
          # step, so the damage is bounded to this call's own boundary.
          case Transport.send_message("/live/song/end_undo_step", []) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "Could not close the Ableton undo step after #{name}: #{inspect(reason)}. " <>
                  "Live may group the next change with this one until another tool call closes it."
              )
          end
        end

      {:error, reason} ->
        {:error,
         "Could not open an Ableton undo step (#{inspect(reason)}), so #{name} was not run — " <>
           "running it now could fold into whatever step Live has open. Check that Ableton " <>
           "Live is running with AbletonOSC enabled, then try again."}
    end
  end

  @doc """
  Recursively converts map keys to strings.

  MCP component params arrive atom-keyed after Peri validates against an
  atom-keyed schema. Normalising here means the clauses below only ever deal
  with one shape, and direct callers can safely supply either key form.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  @doc """
  Reads browser.py's ok/error envelope out of a `/live/browser/get/items` reply,
  once `correlate_reply/2` has stripped the echoed category and filter.

  `returned` is dropped: it counts the triples this reply carries, which the
  triples themselves say. `total` is the pre-truncation match count, and it is
  what the formatter needs.
  """
  @spec browser_items_payload(list()) ::
          {:ok, {non_neg_integer(), list()}} | {:error, String.t()} | :unexpected_shape
  def browser_items_payload(["ok", _returned, total | triples]), do: {:ok, {total, triples}}

  def browser_items_payload(["error", message]) when is_binary(message), do: {:error, message}

  def browser_items_payload(_other), do: :unexpected_shape

  @doc """
  Formats the flat `[name, path, uri, name, path, uri, ...]` tail of a
  `/live/browser/get/items` reply into one line per item.

  `total` is how many items matched before truncation, so the model can tell
  "that's all of them" from "there are more, narrow the filter".
  """
  @spec format_browser_items(list(), non_neg_integer()) :: String.t()
  def format_browser_items([], _total) do
    "No matching browser items. Try a shorter filter, a different spelling, or another category."
  end

  def format_browser_items(triples, total) do
    items = Enum.chunk_every(triples, 3, 3, :discard)

    listing =
      Enum.map_join(items, "\n", fn [name, path, uri] ->
        "#{name}#{format_path(path)} — uri: #{uri}"
      end)

    header =
      if length(items) < total do
        "Showing #{length(items)} of #{total} matches — refine the filter to see the rest."
      else
        "#{length(items)} match(es):"
      end

    "#{header}\n\n#{listing}"
  end

  @doc """
  Formats catalog entries as `name — tags [paths] (uri)`, one per line.

  The tags are the whole reason to prefer this over a raw browser listing, so
  they lead; the uri trails because it is for the next tool call, not the user.

  One entry is one preset, so a preset Live files in several places lists all
  of them — "Analog/Synth Lead · Operator/Synth Lead" says which devices can
  play it, which is real information for choosing. It is still shorter than the
  repeated rows it replaces.

  The third argument is what makes a partial answer actionable rather than a dead
  end: `Catalog.diagnose/1`'s map when nothing matched, so the reply can name the
  tag that killed the search and the real ones near it, and otherwise
  `Catalog.search/1`'s facets, so a truncated reply offers the tags that would
  narrow it. Both carry this library's own vocabulary, which no fixed list can.
  """
  @spec format_catalog_entries([map()], non_neg_integer(), [{String.t(), pos_integer()}] | map()) ::
          String.t()
  def format_catalog_entries([], _total, diagnosis) do
    "No catalog matches.#{format_diagnosis(diagnosis)} If the catalog has never been built, " <>
      "run reindex_library."
  end

  def format_catalog_entries(entries, total, facets) do
    listing =
      Enum.map_join(entries, "\n", fn entry ->
        "#{entry.name} — #{format_tags(entry.tags)}#{format_paths(entry.paths)} (#{entry.uri})"
      end)

    header =
      cond do
        length(entries) >= total ->
          "#{length(entries)} match(es):"

        facets == [] ->
          "Showing #{length(entries)} of #{total} matches — narrow the query or add a tag to " <>
            "see the most relevant ones."

        true ->
          "Showing #{length(entries)} of #{total} matches — top tags among them: " <>
            "#{format_tag_counts(facets)}. Add one as a tag to narrow. " <>
            @diagnostics_internal
      end

    "#{header}\n\n#{listing}"
  end

  # Nothing matched and nothing to say about why — an empty catalog, which the
  # search_library clause reports before it ever gets here.
  defp format_diagnosis(diagnosis) when not is_map(diagnosis), do: ""

  defp format_diagnosis(diagnosis) do
    notes =
      Enum.map(diagnosis.tags, &tag_note/1) ++
        [
          constraint_note("Query", diagnosis.query, diagnosis.query_matches),
          constraint_note("Category", diagnosis.category, diagnosis.category_matches)
        ]

    case Enum.reject(notes, &(&1 == "")) do
      [] ->
        ""

      notes ->
        " " <>
          Enum.join(notes, " ") <> " " <> retry_advice(diagnosis) <> " " <> @diagnostics_internal
    end
  end

  defp tag_note(%{tag: tag, matches: 0, nearest: []}) do
    "Tag '#{tag}' matches nothing in this library."
  end

  defp tag_note(%{tag: tag, matches: 0, nearest: nearest}) do
    "Tag '#{tag}' matches nothing in this library — nearest real tags: " <>
      "#{format_tag_counts(nearest)}."
  end

  defp tag_note(%{tag: tag, matches: matches}), do: "'#{tag}' alone matches #{matches}."

  # nil means the constraint was never set, which is not worth a sentence.
  defp constraint_note(_label, _value, nil), do: ""

  defp constraint_note(label, value, 0), do: "#{label} '#{value}' alone matches nothing."
  defp constraint_note(label, value, matches), do: "#{label} '#{value}' alone matches #{matches}."

  # Two independent things the model needs: *why* it got nothing, and *what to
  # send next*. Folding them into one branch loses whichever it didn't pick —
  # a combination failure with narrowing tags available needs both sentences.
  defp retry_advice(diagnosis) do
    [cause_note(diagnosis), narrowing_note(diagnosis)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # A tag that matched nothing has already been named, with its count, above.
  defp cause_note(diagnosis) do
    if Enum.any?(diagnosis.tags, &(&1.matches == 0)) do
      ""
    else
      "Every constraint matches something on its own, so it is the combination that fails."
    end
  end

  # Naming tags that would actually work is the difference between a dead end and
  # a one-step retry — and string similarity can't supply them when the model
  # guessed a word this library has no spelling of ("Warm", against a vocabulary
  # whose nearest neighbour is "Marimba"). The tags on what the query alone
  # reaches can.
  defp narrowing_note(%{narrowing_tags: [_ | _] = narrowing}) do
    "Real tags on those: #{format_tag_counts(narrowing)} — retry with one of them rather " <>
      "than abandoning the search."
  end

  defp narrowing_note(_diagnosis) do
    "Drop the query down to just the kind of sound, or search with fewer tags."
  end

  defp format_tag_counts(counts) do
    Enum.map_join(counts, ", ", fn {tag, count} -> "#{tag} (#{count})" end)
  end

  @doc """
  Formats a `Catalog.reindex/1` summary.

  A reindex is when the tag vocabulary changes, so it is when the model should be
  told what it now is — the tool description can't, since the vocabulary depends
  on which Packs this user has installed. The distinct count says how much of it
  the sample leaves out.
  """
  @spec format_reindex_summary(map()) :: String.t()
  def format_reindex_summary(%{items: items, tagged: tagged} = summary) do
    "Reindexed the sound catalog: #{items} item(s), #{tagged} of them tagged by Ableton. " <>
      "#{format_vocabulary(summary)}search_library is ready." <> format_persistence(summary)
  end

  # A reindex that couldn't be saved still indexed everything — search answers
  # from memory until Seshat stops. Say both halves, because the half that goes
  # wrong later is the one nothing else would ever mention.
  defp format_persistence(%{persisted: {:error, reason}}) do
    " Note: the catalog could not be saved to disk (#{inspect(reason)}), so these newly " <>
      "indexed results will be lost when Seshat restarts; an older saved catalog may be " <>
      "restored instead. Check that the folder is writable and has free space, then run " <>
      "reindex_library again."
  end

  defp format_persistence(_summary), do: ""

  defp catalog_freshness_notice(:stale) do
    "\n\nCatalog freshness notice: Ableton's library has changed since this catalog was " <>
      "built. These results are still usable, but warn the user and offer to run " <>
      "reindex_library. It can take up to a minute and Live's UI may be temporarily " <>
      "unresponsive, so get confirmation before starting it."
  end

  defp catalog_freshness_notice(:missing) do
    "\n\nCatalog freshness notice: the saved catalog is missing; these results exist only in " <>
      "the current Seshat process. Warn the user and offer to run reindex_library. It can " <>
      "take up to a minute and Live's UI may be temporarily unresponsive, so get " <>
      "confirmation before starting it."
  end

  defp catalog_freshness_notice(_status), do: ""

  defp format_vocabulary(%{distinct_tags: 0}), do: ""

  defp format_vocabulary(%{distinct_tags: distinct, top_tags: top}) do
    ending = if distinct > length(top), do: ", …", else: "."

    "#{distinct} distinct tags — most common: #{format_tag_counts(top)}#{ending} "
  end

  defp format_tags([]), do: "no tags"
  defp format_tags(tags), do: Enum.join(tags, ", ")

  # One location, for a raw browser listing.
  defp format_path(path) when path in [nil, ""], do: ""
  defp format_path(path), do: " [#{path}]"

  # Every location a catalog entry has, since one entry is one preset.
  defp format_paths(paths) do
    case Enum.reject(List.wrap(paths), &(&1 in [nil, ""])) do
      [] -> ""
      list -> " [#{Enum.join(list, " · ")}]"
    end
  end

  @typedoc """
  Which device chain a device tool is aimed at.

  Three index spaces, three sets of OSC addresses, and — the reason this exists
  as a value rather than a bare integer — three different ways to name the
  target in a reply. `{:return, 0}` rendered with the regular-track wording
  would say "track 0", which is a *different, existing* track: the reply would
  be wrong rather than merely vague.
  """
  @type chain :: {:track, integer()} | {:return, integer()} | :master

  @doc """
  How a reply names the chain a device tool acted on.

  "master (shown as Main in Live 12)" is spelled out because Live 12's mixer
  prints `Main` while every tool here says master — a user told to look at "the
  master" has to be able to find it on screen.
  """
  @spec chain_label(chain()) :: String.t()
  def chain_label({:track, index}), do: "track #{index}"
  def chain_label({:return, index}), do: "return track #{index}"
  def chain_label(:master), do: "the master track (shown as Main in Live 12)"

  @doc """
  Formats the parallel name/type/class_name lists of a device-chain read into
  one line per device, in chain order.

  The `chain` says which of the three index spaces the numbers belong to; see
  `t:chain/0`.
  """
  @spec format_device_chain(chain(), list(), list(), list()) :: String.t()
  def format_device_chain({:track, track}, [], _types, _classes) do
    "No devices on track #{track}. If this is a MIDI track it will be silent — " <>
      "load an instrument with list_browser_items + load_device."
  end

  def format_device_chain({:return, index}, [], _types, _classes) do
    "No devices on return track #{index}, so every send into it is silent — load an audio " <>
      "effect with list_browser_items + load_device (target: 'return')."
  end

  def format_device_chain(:master, [], _types, _classes) do
    "No devices on #{chain_label(:master)} — the mix passes through untouched."
  end

  def format_device_chain(chain, names, types, classes) do
    lines =
      [names, types, classes]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{name, type, class}, index} ->
        "Device #{index} \"#{name}\" — #{device_type_label(type)} (#{class})"
      end)

    "#{length(names)} device(s) on #{chain_label(chain)}:\n\n#{lines}"
  end

  @doc """
  Splits the flat tail of a combined device-chain reply into parallel lists.

  The vendored `/live/return_track/get/devices` and `/live/master/get/devices`
  answer with `count` followed by `count` × `(name, type, class_name)` — one
  reply where upstream needs three. Both halves of that promise are checked: a
  tail that isn't a whole number of triples, or whose triple count disagrees
  with the declared `count`, is a reply this code can't read rather than one to
  truncate quietly into a chain that is missing a device.
  """
  @spec parse_device_chain(list()) :: {:ok, {list(), list(), list()}} | {:error, String.t()}
  def parse_device_chain([count | tail]) when is_integer(count) and count >= 0 do
    if rem(length(tail), 3) == 0 and div(length(tail), 3) == count do
      triples = Enum.chunk_every(tail, 3)

      {:ok,
       {Enum.map(triples, &Enum.at(&1, 0)), Enum.map(triples, &Enum.at(&1, 1)),
        Enum.map(triples, &Enum.at(&1, 2))}}
    else
      {:error,
       "Unexpected device list from Live: it declared #{count} device(s) but sent " <>
         "#{length(tail)} value(s), which is not #{count} × (name, type, class). The chain was " <>
         "not read — run `mix abletonosc.install` and restart Ableton Live."}
    end
  end

  def parse_device_chain(other) do
    {:error,
     "Unexpected device list from Live: #{inspect(other)} does not start with a device count. " <>
       "The chain was not read — run `mix abletonosc.install` and restart Ableton Live."}
  end

  @doc """
  Splits the flat tail of a combined device-parameter reply into parallel lists.

  Same contract as `parse_device_chain/1` one level down: `device_name`, then
  `count`, then `count` × `(name, value, min, max)`.
  """
  @spec parse_device_parameters(list()) ::
          {:ok, {String.t(), list(), list(), list(), list()}} | {:error, String.t()}
  def parse_device_parameters([device_name, count | tail])
      when is_binary(device_name) and is_integer(count) and count >= 0 do
    if rem(length(tail), 4) == 0 and div(length(tail), 4) == count do
      quads = Enum.chunk_every(tail, 4)

      {:ok,
       {device_name, Enum.map(quads, &Enum.at(&1, 0)), Enum.map(quads, &Enum.at(&1, 1)),
        Enum.map(quads, &Enum.at(&1, 2)), Enum.map(quads, &Enum.at(&1, 3))}}
    else
      {:error,
       "Unexpected parameter list from Live: '#{device_name}' declared #{count} parameter(s) " <>
         "but sent #{length(tail)} value(s), which is not #{count} × (name, value, min, max). " <>
         "Nothing was read — run `mix abletonosc.install` and restart Ableton Live."}
    end
  end

  def parse_device_parameters(other) do
    {:error,
     "Unexpected parameter list from Live: #{inspect(other)} does not start with a device name " <>
       "and a parameter count. Nothing was read — run `mix abletonosc.install` and restart " <>
       "Ableton Live."}
  end

  @doc """
  The out-of-range error for `delete_device`, raised in Elixir before anything
  reaches the wire.

  `/live/track/delete_device` has no reply on success, and a bad device index
  raises inside AbletonOSC's callback. That rejection does reach the wire as
  `/live/error ["request", "/live/track/delete_device", …]`, but it reaches
  nobody here: the delete goes out through `send_message/2`, which has returned
  before the error lands, so the tool would report a success it never observed.
  Checking against the chain we just read says it immediately, and prints the
  chain so the retry is one step.
  """
  @spec device_out_of_range_error(chain(), integer(), list()) :: String.t()
  def device_out_of_range_error(chain, device, []) do
    "There are no devices on #{chain_label(chain)}, so there is nothing to delete (asked for " <>
      "device #{device}). Check the chain with get_track_devices."
  end

  def device_out_of_range_error(chain, device, names) do
    "There are #{length(names)} device(s) on #{chain_label(chain)} (indices " <>
      "0–#{length(names) - 1}) — there is no device #{device}. Chain: " <>
      "#{format_chain_inline(names)}."
  end

  @doc """
  The success reply for `delete_device`, listing the chain that is left.

  Every device after the deleted one has just moved down an index, so any index
  the model noted earlier is now wrong. Re-listing the chain from the names read
  before the delete costs nothing and saves a `get_track_devices` round trip
  that the model would otherwise have to know to make.
  """
  @spec deleted_device_reply(chain(), integer(), list()) :: String.t()
  def deleted_device_reply(chain, device, names) do
    deleted = Enum.at(names, device)

    case List.delete_at(names, device) do
      [] ->
        "Deleted '#{deleted}' (device #{device}) from #{chain_label(chain)}. Its device chain " <>
          "is now empty."

      remaining ->
        "Deleted '#{deleted}' (device #{device}) from #{chain_label(chain)}. Remaining chain: " <>
          "#{format_chain_inline(remaining)} — later device indices have shifted down by one."
    end
  end

  defp format_chain_inline(names) do
    names
    |> Enum.with_index()
    |> Enum.map_join(", ", fn {name, index} -> "#{index}: #{name}" end)
  end

  @doc """
  Refuses the bypass unless parameter 0's display value reads On/Off.

  Turns "parameter 0 is the Device On switch" from a load-bearing assumption
  into a refusal that prints what it actually found — the whole tool hangs on
  this guard until the assumption is smoke-tested against a live Ableton.
  """
  @spec ensure_on_off_switch(String.t(), term()) :: :ok | {:error, String.t()}
  def ensure_on_off_switch(name, display) do
    if String.downcase(to_string(display)) in ["on", "off"] do
      :ok
    else
      {:error,
       "Parameter 0 of '#{name}' reads '#{display}', not On/Off — this device doesn't expose " <>
         "the standard Device On switch at parameter 0, so nothing was changed. Inspect it " <>
         "with get_device_parameters instead."}
    end
  end

  @doc """
  The success reply for `bypass_device`, once the toggle is confirmed.
  """
  @spec bypass_reply(String.t(), chain(), integer(), boolean()) :: String.t()
  def bypass_reply(name, chain, device, true) do
    "'#{name}' (device #{device} on #{chain_label(chain)}) is now On."
  end

  def bypass_reply(name, chain, device, false) do
    "'#{name}' (device #{device} on #{chain_label(chain)}) is now Off — bypassed, settings kept."
  end

  @doc """
  The no-op reply for `bypass_device` — parameter 0 already read the requested
  state, so nothing was written and the reply must not claim otherwise.
  """
  @spec bypass_noop_reply(String.t(), chain(), integer(), boolean()) :: String.t()
  def bypass_noop_reply(name, chain, device, enabled) do
    "'#{name}' (device #{device} on #{chain_label(chain)}) was already " <>
      "#{on_off_label(enabled)} — nothing to do."
  end

  defp on_off_label(true), do: "On"
  defp on_off_label(false), do: "Off"

  @doc """
  Formats the parallel parameter name/value/min/max lists of the
  `/live/device/get/parameters/*` replies into one line per parameter.
  """
  @spec format_device_parameters(chain(), integer(), String.t(), list(), list(), list(), list()) ::
          String.t()
  def format_device_parameters(chain, device, device_name, names, values, mins, maxes) do
    lines =
      [names, values, mins, maxes]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{name, value, min, max}, index} ->
        "#{index}. #{name} = #{format_number(value)} (range #{format_number(min)}–#{format_number(max)})"
      end)

    "Device #{device} \"#{device_name}\" on #{chain_label(chain)} — #{length(names)} " <>
      "parameter(s):\n\n#{lines}"
  end

  @doc """
  Chunks the flat tail of a `/live/clip/get/notes` reply into one map per note.

  AbletonOSC contributes exactly five fields per note — pitch, start_time,
  duration, velocity, mute — so a tail that isn't a multiple of five means the
  reply shape changed upstream. Fail loudly there rather than silently dropping
  a partial note and reporting a clip that isn't what Live holds.
  """
  @spec parse_clip_notes(list()) :: {:ok, [map()]} | {:error, String.t()}
  def parse_clip_notes(fields) when is_list(fields) do
    if rem(length(fields), 5) == 0 do
      notes =
        fields
        |> Enum.chunk_every(5)
        |> Enum.map(fn [pitch, start_time, duration, velocity, mute] ->
          %{
            pitch: pitch,
            start_time: start_time,
            duration: duration,
            velocity: velocity,
            mute: truthy?(mute)
          }
        end)

      {:ok, notes}
    else
      {:error,
       "Unexpected note data from Live: #{length(fields)} value(s) is not a whole number of " <>
         "notes (5 fields each). AbletonOSC may have changed its reply format — the clip was " <>
         "not read."}
    end
  end

  @doc """
  Formats the notes of a clip, one per line, with note names beside the raw
  MIDI pitches.

  Sorted by start time, then pitch, so chords read as blocks and the model sees
  the clip in playing order rather than Live's internal order.
  """
  @spec format_clip_notes(integer(), integer(), String.t(), number(), [map()]) :: String.t()
  def format_clip_notes(track, slot, clip_name, clip_length, []) do
    ~s{Clip "#{clip_name}" on track #{track}, slot #{slot} — } <>
      "#{format_number(clip_length)} beats, no notes (the clip exists but is empty)."
  end

  def format_clip_notes(track, slot, clip_name, clip_length, notes) do
    lines =
      notes
      |> Enum.sort_by(&{&1.start_time, &1.pitch})
      |> Enum.map_join("\n", fn note ->
        muted = if note.mute, do: "  [muted]", else: ""

        "  " <>
          String.pad_trailing("#{Pitch.note_name(note.pitch)} (#{note.pitch})", 11) <>
          String.pad_trailing("start=#{format_number(note.start_time)}", 14) <>
          String.pad_trailing("dur=#{format_number(note.duration)}", 12) <>
          "vel=#{format_number(note.velocity)}#{muted}"
      end)

    header =
      ~s{Clip "#{clip_name}" on track #{track}, slot #{slot} — } <>
        "#{format_number(clip_length)} beats, #{length(notes)} note(s):"

    "#{header}\n\n#{lines}"
  end

  @doc """
  The `GridQuantization` integer for one of `quantize_clip`'s grid strings.

  **These integers were measured against a running Live on 2026-07-31**, one
  clip per enum value, with probe notes chosen so every candidate grid lands
  somewhere distinguishable. `priv/AbletonOSC/API.md` and the comment in
  the fork's `abletonosc/clip.py` both used to claim `5=1/2, 6=1/4, 7=1/8,
  8=1/16, 9=1/32`, and **every row of that was wrong** — both have since been
  corrected to the table below. If you are here because the code and some
  other document disagree, the instrument won: do not "fix" this back.

  The full measured mapping, including what this function deliberately never
  sends: `0` no grid, `1` 1/4, `2` 1/8, `3` and `4` 1/8 triplet, `5` 1/16,
  `6` and `7` 1/16 triplet, `8` 1/32, `≥9` invalid (Live's callback raises;
  since the fork's dispatch-boundary rework AbletonOSC reports that as
  `/live/error ["request", "/live/clip/quantize", …]`, but nothing moves).
  There is no 1/2 grid and there are no bar-length grids, which is why the
  tool's enum stops at 1/4. Duplicated pairs send the lower value.

  A wrong integer is still silent *to Seshat*: quantize goes out through
  `send_message/2`, which has returned by the time any rejection lands, and the
  address never replies on success either. An out-of-range grid is reported on
  the wire and answers nobody; a valid-but-wrong one isn't reported at all, and
  the only symptom is notes landing on the wrong grid in Live.
  """
  @spec grid_quantization(String.t()) :: 1 | 2 | 3 | 5 | 6 | 8
  def grid_quantization("1/4"), do: 1
  def grid_quantization("1/8"), do: 2
  def grid_quantization("1/8T"), do: 3
  def grid_quantization("1/16"), do: 5
  def grid_quantization("1/16T"), do: 6
  def grid_quantization("1/32"), do: 8

  @doc """
  Sends the quantize itself. Fire-and-forget: the address never replies.

  `amount / 1.0` forces float encoding. AbletonOSC passes OSC-decoded values
  straight through to `clip.quantize(grid, amount)`, so an int32 `1` arriving
  where Live expects a float is a risk taken for nothing.
  """
  @spec send_quantize(integer(), integer(), String.t(), number()) :: :ok | {:error, String.t()}
  def send_quantize(track, slot, grid, amount) do
    case Transport.send_message("/live/clip/quantize", [
           track,
           slot,
           grid_quantization(grid),
           amount / 1.0
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  @doc """
  Describes what a quantize did, from the notes read either side of it.

  The diffs are deliberately multiset-style (`before -- after`) rather than
  paired note tracking. Live's collision handling was measured on 2026-07-31
  and has two shapes: two same-pitch notes landing on the *same* grid point
  **merge** into one (the later note's velocity survives, so the count
  shrinks), while two landing on *different* points that now overlap keep the
  count but **trim** the earlier note's duration to end where the later one
  starts. Paired tracking would have to model both and would still be
  guessing; a multiset diff reports both correctly as "changed".

  Two separate diffs, because "changed" and "moved" aren't the same claim: a
  trim changes a note's full record (its duration) without moving its start,
  so counting "moved" from the full-record diff would credit a trimmed-but-
  stationary note with having moved toward the grid. The full-record diff
  still gates "did anything happen at all" (a duration-only trim is a real
  change); the position-only diff — `{pitch, start_time}` pairs — is what the
  "N of M note(s) moved" count is drawn from, and the duration/count checks
  below say what else happened.

  There is deliberately no Elixir-side "was this note off-grid?" arithmetic —
  modelling target positions is exactly the beat math this tool exists to
  retire, and after the enum finding it is the last thing that should be
  duplicating Live's own.

  `clip_name` may be `nil`: the name read is garnish and never fails the tool.
  """
  @spec format_quantize_result(
          integer(),
          integer(),
          String.t() | nil,
          String.t(),
          number(),
          [map()],
          [map()]
        ) :: String.t()
  def format_quantize_result(track, slot, clip_name, grid, amount, before_notes, after_notes) do
    subject = quantize_subject(track, slot, clip_name)
    strength = "#{round(amount * 100)}% strength"
    changed = before_notes -- after_notes

    if changed == [] do
      # Silence is what success looks like on this address, so an unchanged
      # clip and a Remote Scripts copy predating the fork are indistinguishable
      # from here. Same reasoning as @return_extension_hint, but attached to the
      # no-change case rather than a timeout — here silence is normal.
      "Quantize sent, but no note changed — #{subject} may already sit on the #{grid} grid at " <>
        "#{strength}. If the timing audibly didn't change, the installed AbletonOSC may " <>
        "predate /live/clip/quantize: run mix abletonosc.install and restart Live."
    else
      moved = note_positions(before_notes) -- note_positions(after_notes)

      "Quantized #{subject}: #{length(moved)} of #{length(before_notes)} note(s) moved toward " <>
        "the #{grid} grid at #{strength}." <>
        quantize_collision_note(before_notes, after_notes) <>
        " Listen back — undo reverses it in one step if the feel went stiff."
    end
  end

  defp note_positions(notes), do: Enum.map(notes, &Map.take(&1, [:pitch, :start_time]))

  defp quantize_subject(track, slot, nil), do: "the clip in slot #{slot} on track #{track}"

  defp quantize_subject(track, slot, clip_name),
    do: ~s{"#{clip_name}" (track #{track}, slot #{slot})}

  defp quantize_collision_note(before_notes, after_notes) do
    lost = length(before_notes) - length(after_notes)

    cond do
      lost > 0 ->
        " The clip now has #{length(after_notes)} note(s) rather than #{length(before_notes)}: " <>
          "#{lost} same-pitch note(s) landed on a spot already taken and merged into the note " <>
          "there, keeping the later velocity. Undo restores them."

      lost < 0 ->
        " The clip now has #{length(after_notes)} note(s) rather than #{length(before_notes)} — " <>
          "quantize is not expected to add notes, so re-read the clip with get_clip_notes " <>
          "before building on it."

      durations_changed?(before_notes, after_notes) ->
        " Some note lengths changed too: where a move put two same-pitch notes on top of each " <>
          "other, Live trimmed the earlier one to end where the later one starts."

      true ->
        ""
    end
  end

  # Multiset comparison, for the same reason the diff above is one: it answers
  # "did any length change?" without pretending to know which note became which.
  defp durations_changed?(before_notes, after_notes) do
    Enum.sort(Enum.map(before_notes, & &1.duration)) !=
      Enum.sort(Enum.map(after_notes, & &1.duration))
  end

  @doc """
  Chunks the flat `/live/song/get/track_data` reply into one map per track.

  The reply carries, per track, the values of `@track_data_properties` in
  order: 3 single track-level values, then 5 runs of `num_scenes` slot-level
  values. Empty slots contribute OSC nil for every `clip.*` property; a slot
  is empty iff `clip_slot.has_clip` is falsy, and the nils are discarded.

  A reply that isn't exactly `num_tracks * (3 + 5 * num_scenes)` values means
  the shape changed upstream — fail loudly rather than misattribute values to
  the wrong tracks (same guard as `parse_clip_notes/1`).
  """
  @spec parse_track_data(list(), pos_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, String.t()}
  def parse_track_data(values, num_scenes, num_tracks)
      when is_list(values) and num_scenes >= 1 and num_tracks >= 1 do
    per_track = 3 + 5 * num_scenes
    expected = num_tracks * per_track

    if length(values) == expected do
      tracks =
        values
        |> Enum.chunk_every(per_track)
        |> Enum.map(fn [name, has_midi_input, is_foldable | slot_values] ->
          [has_clips, clip_names, clip_lengths, playings, recordings] =
            Enum.chunk_every(slot_values, num_scenes)

          slots =
            [has_clips, clip_names, clip_lengths, playings, recordings]
            |> Enum.zip()
            |> Enum.map(fn {has_clip, clip_name, clip_length, playing, recording} ->
              if truthy?(has_clip) do
                %{
                  name: clip_name,
                  length: clip_length,
                  playing?: truthy?(playing),
                  recording?: truthy?(recording)
                }
              end
            end)

          %{
            name: name,
            midi?: truthy?(has_midi_input),
            group?: truthy?(is_foldable),
            slots: slots
          }
        end)

      {:ok, tracks}
    else
      {:error,
       "Unexpected clip-grid data from Live: got #{length(values)} value(s) for " <>
         "#{num_tracks} track(s) × #{num_scenes} scene(s), expected #{expected}. " <>
         "AbletonOSC may have changed its track_data reply format — the grid was not read."}
    end
  end

  @doc """
  Formats the parsed clip grid: the scene list, then one block per track.

  Occupied slots get a line each; consecutive empty slots collapse into ranges
  (with 30 scenes the output would otherwise be mostly the word "empty").
  Track label from the flags: `is_foldable` → group, else `has_midi_input` →
  MIDI, else audio. A recording clip shows only `[recording]` — Live reports
  it as playing too, and two flags would just be noise.
  """
  @spec format_clip_slots([String.t()], [map()]) :: String.t()
  def format_clip_slots(scenes, tracks) do
    scene_line =
      "#{length(scenes)} scene(s): " <>
        (scenes
         |> Enum.with_index()
         |> Enum.map_join(", ", fn {name, index} -> ~s(#{index} "#{name}") end))

    track_blocks =
      tracks
      |> Enum.with_index()
      |> Enum.map_join("\n", &format_track_slots/1)

    "#{scene_line}\n\n#{track_blocks}"
  end

  defp format_track_slots({track, index}) do
    label =
      cond do
        track.group? -> "group"
        track.midi? -> "MIDI"
        true -> "audio"
      end

    header = ~s{Track #{index} "#{track.name}" (#{label}):}

    empty_indices =
      for {slot, slot_index} <- Enum.with_index(track.slots), is_nil(slot), do: slot_index

    cond do
      length(empty_indices) == length(track.slots) ->
        "#{header} all #{length(track.slots)} slot(s) empty"

      empty_indices == [] ->
        "#{header}\n#{occupied_slot_lines(track.slots)}"

      true ->
        "#{header}\n#{occupied_slot_lines(track.slots)}\n" <>
          "  #{slot_label(empty_indices)}: empty"
    end
  end

  defp occupied_slot_lines(slots) do
    for {slot, index} <- Enum.with_index(slots), not is_nil(slot) do
      clip_name = if slot.name in [nil, ""], do: "(unnamed)", else: ~s("#{slot.name}")

      flag =
        cond do
          slot.recording? -> " [recording]"
          slot.playing? -> " [playing]"
          true -> ""
        end

      "  slot #{index}: #{clip_name} — #{format_number(slot.length)} beats#{flag}"
    end
    |> Enum.join("\n")
  end

  # [0, 1, 3] -> ~s(slots 0-1, 3); [3] -> ~s(slot 3)
  defp slot_label([index]), do: "slot #{index}"

  defp slot_label(indices) do
    ranges =
      indices
      |> Enum.reduce([], fn index, acc ->
        case acc do
          [{first, last} | rest] when index == last + 1 -> [{first, index} | rest]
          _ -> [{index, index} | acc]
        end
      end)
      |> Enum.reverse()
      |> Enum.map_join(", ", fn
        {first, first} -> "#{first}"
        {first, last} -> "#{first}-#{last}"
      end)

    "slots #{ranges}"
  end

  @doc """
  Diffs two `snapshot_grid/0` results: what `capture_midi` made appear.

  Returns `{new_clips, scenes_added}` — one map per slot that is occupied in
  `after_grid` and empty in `before_grid`, in track then slot order, plus how
  many scenes the grid grew by (capture adds one when it needs somewhere to put
  the clip).

  Tracks are matched by index, which is safe because capture never creates or
  reorders tracks. A slot beyond `before_grid`'s scene count — or on a track
  `before_grid` didn't have — counts as newly occupied: there was nothing there
  to be occupied before.
  """
  @spec capture_diff(map(), map()) :: {[map()], non_neg_integer()}
  def capture_diff(before_grid, after_grid) do
    new_clips =
      after_grid.tracks
      |> Enum.with_index()
      |> Enum.flat_map(fn {track, track_index} ->
        new_clips_on_track(before_grid, track, track_index)
      end)

    {new_clips, max(after_grid.num_scenes - before_grid.num_scenes, 0)}
  end

  defp new_clips_on_track(before_grid, track, track_index) do
    before_slots =
      case Enum.at(before_grid.tracks, track_index) do
        nil -> []
        before_track -> before_track.slots
      end

    for {slot, slot_index} <- Enum.with_index(track.slots),
        not is_nil(slot),
        is_nil(Enum.at(before_slots, slot_index)) do
      %{
        track_index: track_index,
        track_name: track.name,
        slot_index: slot_index,
        clip: slot
      }
    end
  end

  @doc """
  The success reply for `capture_midi`: what appeared, and what Live changed.

  Every fact here comes from the after-snapshot rather than from assumption —
  including whether Live started the clip playing, which depends on the
  transport state at capture time. The tempo line only appears when the two
  readings actually differ, which is Live's tempo inference showing up (it
  happens when the transport was stopped and Live guessed a tempo from the
  playing).
  """
  @spec captured_reply([map()], non_neg_integer(), number(), number()) :: String.t()
  def captured_reply(new_clips, scenes_added, tempo_before, tempo_after) do
    header = "Captured #{length(new_clips)} new clip(s):"
    lines = Enum.map_join(new_clips, "\n", &captured_clip_line/1)

    extras =
      [scene_added_line(scenes_added), tempo_change_line(tempo_before, tempo_after)]
      |> Enum.reject(&is_nil/1)

    Enum.join([header <> "\n" <> lines | extras], "\n\n")
  end

  defp captured_clip_line(%{track_index: track, track_name: name, slot_index: slot, clip: clip}) do
    clip_name = if clip.name in [nil, ""], do: "(unnamed)", else: ~s("#{clip.name}")
    playing = if clip.playing?, do: " [playing]", else: ""

    ~s{Track #{track} "#{name}", slot #{slot}: #{clip_name} — } <>
      "#{format_number(clip.length)} beats#{playing}"
  end

  defp scene_added_line(0), do: nil

  defp scene_added_line(count) do
    "Live added #{count} scene(s) to hold it."
  end

  defp tempo_change_line(tempo_before, tempo_after) when tempo_before == tempo_after, do: nil

  defp tempo_change_line(tempo_before, tempo_after) do
    "Live set the tempo to #{format_tempo(tempo_after)} BPM to match the playing " <>
      "(was #{format_tempo(tempo_before)})."
  end

  defp format_tempo(tempo), do: Float.round(tempo / 1, 1)

  @doc """
  The reply for a `capture_midi` that produced no new Session clip.

  An error rather than a soft success: the user asked to keep what they played
  and nothing was kept, so the model needs to say so and can act on the causes.
  A tempo change with *no* new clip is positive evidence that the capture landed
  somewhere the Session grid can't see, which upgrades the Arrangement caveat
  from a guess to the likely cause.
  """
  @spec nothing_captured_reply(number(), number()) :: String.t()
  def nothing_captured_reply(tempo_before, tempo_after) do
    base =
      "Capture ran but no new clip appeared in the Session grid. Live only buffers MIDI that " <>
        "was played *into* a track — the track has to be armed or monitoring its input — and " <>
        "the buffer is cleared by the previous capture, so there may be nothing left to keep. " <>
        "Audio can't be captured at all."

    if tempo_before == tempo_after do
      base <>
        " If Arrangement view was focused, Live may have captured there instead, where this " <>
        "tool can't see it."
    else
      base <>
        " Live did change the tempo (#{format_tempo(tempo_before)} → " <>
        "#{format_tempo(tempo_after)} BPM), so something *was* captured — most likely into " <>
        "Arrangement view, which Live captures into when that view is focused and which this " <>
        "tool can't see."
    end
  end

  @doc """
  How many beats `record_clip` should ask Live to record for a number of bars.

  `ClipSlot.fire`'s `record_length` is measured in Live's song-time beat, which
  is a quarter note regardless of the time signature — so a bar is
  `numerator × 4 / denominator` of them: four in 4/4, three in 3/4, but three
  (not six) in 6/8. Returns a float, which is what the OSC argument wants.

  Verified 2026-07-31 in Live: with the song in 6/8, a song loop of 6.0 beats
  reads 2.0.0 — two bars — in the transport bar, so a bar of 6/8 is 3.0
  song-time beats and this formula is right. Neither the LOM Song page nor the
  Clip page defines the beat unit, so this is measurement, not documentation.
  """
  @spec record_length_beats(number(), number(), number()) :: float()
  def record_length_beats(bars, numerator, denominator) do
    bars * numerator * 4 / denominator
  end

  @doc """
  `record_clip`'s `bars` against a song map, as `{:ok, beats}` or an error.

  `{:ok, nil}` for no `bars` — an open-ended take needs no signature and must
  keep working when the mirror is degraded. But converting bars to beats *does*
  need one, and a `nil` numerator or denominator would otherwise reach
  `record_length_beats/3` and raise `ArithmeticError` mid-tool-call. Refusing is
  better than recording a take of the wrong length off a guessed 4/4: the guard
  sits ahead of every OSC send in `record_clip`, so "nothing was recorded" is
  true when this errors.
  """
  @spec record_length_from(number() | nil, map()) :: {:ok, float() | nil} | {:error, String.t()}
  def record_length_from(nil, _song), do: {:ok, nil}

  def record_length_from(bars, %{time_sig_numerator: num, time_sig_denominator: den})
      when is_nil(num) or is_nil(den) do
    {:error,
     "The time signature isn't known (Ableton did not answer when the session was last " <>
       "read), so a #{bars}-bar length can't be converted to beats and nothing was recorded. " <>
       "Call get_session_state with refresh: true first, or omit bars to record open-ended " <>
       "and stop_recording when done."}
  end

  def record_length_from(bars, song) do
    {:ok, record_length_beats(bars, song.time_sig_numerator, song.time_sig_denominator)}
  end

  @range_params ~w(start_pitch pitch_span start_time time_span)

  @doc """
  Builds the optional range arguments for `/live/clip/get/notes`.

  AbletonOSC's handler is all-or-nothing: it raises unless it gets exactly zero
  or four range arguments. So one range param from the model means filling in
  the other three (the same defaults `edit_notes` uses), and no range params
  means sending none at all and letting AbletonOSC apply its own catch-all.
  """
  @spec note_range_args(map()) :: list()
  def note_range_args(params) do
    if Enum.any?(@range_params, &Map.has_key?(params, &1)) do
      [
        Map.get(params, "start_pitch", 0),
        Map.get(params, "pitch_span", 128),
        Map.get(params, "start_time", 0.0) / 1.0,
        Map.get(params, "time_span", 9999.0) / 1.0
      ]
    else
      []
    end
  end

  @doc """
  Formats one track's send levels, one per line, with the send letter and the
  return track each one feeds.

  The letter and the return name are both there because neither alone is enough:
  Live's UI labels the send "B", the user calls it "the delay", and the tools
  want the index.
  """
  @spec format_track_sends(integer(), [map()]) :: String.t()
  def format_track_sends(_track, []) do
    "This set has no return tracks, so no track has any sends. Create one with " <>
      "create_track (track_type: 'return'), then load an effect onto it with load_device " <>
      "(target: 'return')."
  end

  def format_track_sends(track, sends) do
    lines =
      Enum.map_join(sends, "\n", fn s ->
        ~s{  send #{s.index} (#{send_letter(s.index)}) → "#{s.return}": } <>
          "#{format_number(s.value)}"
      end)

    "#{length(sends)} send(s) on track #{track}:\n\n#{lines}"
  end

  # Appended once to a whole `get_session_state` reply that contains any unknown
  # at all. One sentence for the reply, not one per field: the per-field strings
  # stay short so a half-degraded session doesn't drown the readable half, and
  # the *explanation* — why a value is missing and what to do — is worth saying
  # exactly once.
  @unknown_explanation "Unknown values mean Ableton did not answer when the mirror was last " <>
                         "read. Do not call get_session_state again automatically; tell the " <>
                         "user what could not be verified, and check Ableton is running with " <>
                         "AbletonOSC enabled."

  # Appended when a coalesced rebuild is scheduled but hasn't run: the mirror is
  # then *known* to be behind on structure, and an unqualified reply would state
  # a layout it has reason to doubt. Deliberately a second sentence rather than a
  # variant of @unknown_explanation — they answer different questions ("Ableton
  # didn't answer" versus "Ableton answered, we haven't asked yet") and a reply
  # can honestly carry both. The closing instruction is the same one 785db9f
  # shipped: an uncertain read must not become a retry loop.
  @settling_explanation "A structural change is still settling, so this may still show the " <>
                          "previous track or return layout: new entries can be absent and " <>
                          "deleted entries can still appear. It converges on its own. Do not " <>
                          "re-read automatically; tell the user the layout is still settling " <>
                          "rather than reporting it as final."

  @doc """
  The whole `get_session_state` reply, from the four mirrored values and the
  mirror's own `refresh_pending?` flag.

  Composition lives here rather than in the caller because the "exactly one
  trailing explanation for the whole reply" rule is a property of the
  composition, not of any one formatter. It `or`s the formatters' `unknown?`
  flags rather than sniffing the composed text for the word "unknown", which
  would work right up until a track is legitimately named that.

  The settling sentence is appended on the same once-per-reply rule, and
  independently: a reply can be both degraded and pending, and each fact gets
  said exactly once.
  """
  @spec format_session_state(map(), [map()] | nil, [map()], map() | nil, boolean()) :: String.t()
  def format_session_state(song, tracks, return_tracks, master, refresh_pending?) do
    {song_line, song_unknown?} = format_song_line(song)
    {track_summary, tracks_unknown?} = format_track_summary(tracks)
    return_summary = format_return_tracks(return_tracks, master)

    body = "#{song_line}\n\n#{track_summary}\n\n#{return_summary}"

    body =
      if song_unknown? or tracks_unknown? or returns_unknown?(return_tracks, master) do
        "#{body}\n\n#{@unknown_explanation}"
      else
        body
      end

    if refresh_pending?, do: "#{body}\n\n#{@settling_explanation}", else: body
  end

  # `master: nil` is both "the extension never answered" (so returns are
  # unavailable too) and "that one query was lost" — either way the reply says
  # something is missing, and the explanation belongs with it.
  defp returns_unknown?(_return_tracks, nil), do: true

  defp returns_unknown?(return_tracks, master) do
    is_nil(master.pan) or is_nil(master.cue_volume) or is_nil(master.volume) or
      Enum.any?(return_tracks, fn r ->
        is_nil(r.name) or is_nil(r.volume) or is_nil(r.pan) or is_nil(r.mute) or is_nil(r.solo)
      end)
  end

  @doc """
  The song line of `get_session_state`'s reply, plus whether any of it was
  unknown.

  Renders per field, so a lost tempo reply doesn't cost the time signature: only
  the phrase whose source is `nil` says "unknown". The caller owns the trailing
  explanation — see `format_session_state/5`.
  """
  @spec format_song_line(map()) :: {String.t(), boolean()}
  def format_song_line(song) do
    tempo = if is_nil(song.tempo), do: "tempo unknown", else: "#{song.tempo} BPM"

    signature_unknown? =
      is_nil(song.time_sig_numerator) or is_nil(song.time_sig_denominator)

    signature =
      if signature_unknown?,
        do: "time signature unknown",
        else: "#{song.time_sig_numerator}/#{song.time_sig_denominator}"

    playing =
      case song.is_playing do
        nil -> "playing state unknown"
        true -> "playing"
        false -> "stopped"
      end

    # Never `Pitch.pitch_class_name(nil)` — it quietly returns "", which would
    # print "key:  Major" and read as a key we simply forgot to name.
    key_unknown? = is_nil(song.root_note) or is_nil(song.scale_name)

    key =
      if key_unknown?,
        do: "key unknown",
        else: "key: #{Pitch.pitch_class_name(song.root_note)} #{song.scale_name}"

    # Raw floats, not percentages: the house rendering for volume/pan/sends, and
    # it keeps the number the model reads equal to the number set_groove_amount
    # and set_swing_amount accept.
    groove =
      if is_nil(song.groove_amount), do: "groove unknown", else: "groove #{song.groove_amount}"

    swing = if is_nil(song.swing_amount), do: "swing unknown", else: "swing #{song.swing_amount}"

    unknown? =
      is_nil(song.tempo) or signature_unknown? or is_nil(song.is_playing) or key_unknown? or
        is_nil(song.groove_amount) or is_nil(song.swing_amount)

    {Enum.join([tempo, signature, playing, key, groove, swing], ", "), unknown?}
  end

  @doc """
  The per-track block of `get_session_state`'s reply, plus whether any of it was
  unknown.

  `nil` (the track list couldn't be read) and `[]` (a verified empty set) are
  deliberately different sentences: presenting an unreachable Ableton as a set
  with no tracks is the fabrication this whole path exists to stop.
  """
  @spec format_track_summary([map()] | nil) :: {String.t(), boolean()}
  def format_track_summary(nil) do
    {"The track list could not be read from Ableton — it is unknown, not empty.", true}
  end

  def format_track_summary([]) do
    {"No tracks in current session (Ableton may not be connected)", false}
  end

  def format_track_summary(tracks) do
    formatted = Enum.map(tracks, &format_track_line/1)

    {Enum.map_join(formatted, "\n", &elem(&1, 0)), Enum.any?(formatted, &elem(&1, 1))}
  end

  defp format_track_line(t) do
    label =
      if is_nil(t.name),
        do: "Track #{t.index} (name unknown)",
        else: ~s{Track #{t.index} "#{t.name}"}

    pan = if is_nil(t.pan), do: "pan unknown", else: "pan=#{Float.round(t.pan / 1.0, 2)}"

    volume =
      if is_nil(t.volume), do: "volume unknown", else: "volume=#{Float.round(t.volume / 1.0, 2)}"

    mute = if t.mute == true, do: " [muted]", else: ""
    solo = if t.solo == true, do: " [solo]", else: ""

    # One marker for the pair: two unanswered flag queries are one lost refresh,
    # and "[mute unknown] [solo unknown]" is twice the noise for the same fact.
    flags_unknown? = is_nil(t.mute) or is_nil(t.solo)
    flags = if flags_unknown?, do: " [mute/solo unknown]", else: ""

    unknown? = is_nil(t.name) or is_nil(t.pan) or is_nil(t.volume) or flags_unknown?

    {"#{label}: #{pan}, #{volume}#{mute}#{solo}#{flags}", unknown?}
  end

  @doc """
  Formats the return tracks and the master mixer state for `get_session_state`.

  `master` is `nil` when `/live/master/get/volume` never answered, which means
  Seshat's AbletonOSC extension isn't installed — say so rather than reporting a
  set with no returns, which looks identical but isn't. Any individual field is
  `nil` on the same principle: one lost reply, and that field is unknown rather
  than "Return 1" or 0.85.

  Return lines carry pan and mute/solo in the same style as regular track lines,
  so the model reads one mixer, not two.
  """
  @spec format_return_tracks([map()], map() | nil) :: String.t()
  def format_return_tracks(_return_tracks, nil) do
    "Return/master state unavailable — run mix abletonosc.install and restart Live."
  end

  def format_return_tracks([], master) do
    "No return tracks in this set — nothing to send to yet; create one with " <>
      "create_track (track_type: 'return').\n#{master_line(master)}"
  end

  def format_return_tracks(return_tracks, master) do
    lines = Enum.map_join(return_tracks, "\n", &return_line/1)

    "#{lines}\n#{master_line(master)}"
  end

  defp return_line(r) do
    mute = if r.mute == true, do: " [muted]", else: ""
    solo = if r.solo == true, do: " [solo]", else: ""
    flags = if is_nil(r.mute) or is_nil(r.solo), do: " [mute/solo unknown]", else: ""

    "#{return_label(r)} (send #{send_letter(r.index)}): #{volume_field(r.volume)}, " <>
      "#{pan_field(r.pan)}#{mute}#{solo}#{flags}"
  end

  # "master (shown as Main in Live 12)" once per discovery path: the tool
  # vocabulary says master everywhere, and Live 12's mixer prints Main — a user
  # told to check "the master" has to be able to find it on screen.
  defp master_line(master) do
    "Master (shown as Main in Live 12): #{volume_field(master.volume)}, " <>
      "#{pan_field(master.pan)}, cue #{cue_field(master.cue_volume)}"
  end

  defp return_label(%{name: nil, index: index}), do: "Return #{index} (name unknown)"
  defp return_label(r), do: ~s{Return #{r.index} "#{r.name}"}

  # A guessed fader position reads as real and the model does relative moves off
  # it ("turn the delay down a bit" from a fictional 0.85 is an increase), so an
  # unanswered volume query says so instead.
  defp volume_field(nil), do: "volume unknown"
  defp volume_field(value), do: "volume=#{round_volume(value)}"

  defp pan_field(nil), do: "pan unknown"
  defp pan_field(value), do: "pan=#{Float.round(value / 1.0, 2)}"

  defp cue_field(nil), do: "unknown"
  defp cue_field(value), do: "volume=#{round_volume(value)}"

  @doc """
  Send index → the letter Live's mixer prints on it: send 0 = A, send 1 = B.

  Live caps a set at 12 return tracks, so the alphabet never runs out in
  practice; past Z it falls back to the 1-based number rather than emitting
  punctuation.
  """
  @spec send_letter(non_neg_integer()) :: String.t()
  def send_letter(index) when index >= 0 and index < 26, do: <<?A + index>>
  def send_letter(index), do: "##{index + 1}"

  defp round_volume(value), do: Float.round(value / 1.0, 2)

  @doc """
  Approximate dB label for Live's 0.0–1.0 mixer scale.

  The fader is not linear and 1.0 is not the ceiling: ~0.85 is unity (0 dB) and
  1.0 is +6 dB. Across the useful top of the range the scale is close to linear
  in dB (`dB ≈ 40 × value − 34`), then dives toward silence below roughly 0.4 /
  −18 dB — so anything under that gets a bound rather than a misleading number.

  There is no OSC `value_string` for the mixer the way there is for device
  parameters, so this is computed rather than read back, and is labelled
  approximate wherever it is shown.
  """
  @spec volume_display(number()) :: String.t()
  def volume_display(value) when value <= 0.0, do: "silence"
  def volume_display(value) when value < 0.4, do: "≈ below -18 dB"
  def volume_display(value), do: "≈ #{format_db(40 * value - 34)}"

  defp format_db(db) do
    rounded = Float.round(db / 1.0, 1)
    magnitude = if rounded == trunc(rounded), do: trunc(rounded), else: rounded
    sign = if rounded > 0, do: "+", else: ""

    "#{sign}#{magnitude} dB"
  end

  @doc """
  Pan label in Live's own notation: `50L` (hard left), `C`, `50R` (hard right).

  Mirrors what the user reads off the mixer, so an echoed result can be checked
  against intent rather than against the raw -1.0…1.0 value.
  """
  @spec pan_display(number()) :: String.t()
  def pan_display(value) do
    amount = round(abs(value) * 50)

    cond do
      amount == 0 -> "C"
      value < 0 -> "#{amount}L"
      true -> "#{amount}R"
    end
  end

  # Live's DeviceType enum, measured against Live 12.4.3 on 2026-07-31 by loading
  # a known instrument and a known audio effect and reading the type back: an
  # Operator reports 1, a Reverb and an EQ Eight report 2. These two were the
  # wrong way round until then — every device chain named its instruments audio
  # effects and its audio effects instruments — and the docs said so too. Both
  # were guessed from upstream's naming, never checked against Live.
  defp device_type_label(1), do: "instrument"
  defp device_type_label(2), do: "audio effect"
  defp device_type_label(4), do: "MIDI effect"
  defp device_type_label(other), do: "type #{other}"

  defp format_number(value) when is_float(value), do: Float.round(value, 4)
  defp format_number(value), do: value

  # --- The mixer ---
  #
  # One tool over four strips, replacing thirteen names the model had to choose
  # between. The wire is unchanged: each property still goes out on the address
  # its old tool used, and the two halves keep their old shapes too.
  #
  #   * A **regular track** stays fire-and-forget. Every value it writes has a
  #     listener behind it (`Session.State`), so Live pushes back whatever it
  #     accepted and a lost or refused set is corrected within a beat.
  #   * **Return, master and cue** keep the guard-read-then-set they have always
  #     had: their addresses come from Seshat's `return_track.py`, so silence
  #     means "extension not installed" rather than "bad index", and the guard
  #     is what tells those apart — while supplying the "was" value the reply
  #     quotes.
  #
  # Neither half refreshes the mirror (listeners do that) and neither steers the
  # view: mixer tweaks and renames are settled non-steering in `FollowCam`.
  defp do_call("set_mixer", params) do
    target = Map.get(params, "target", "track")
    changes = Map.take(params, @mixer_properties)

    with :ok <- ensure_mixer_changes(changes),
         :ok <- ensure_mixer_supported(target, changes),
         {:ok, index} <- mixer_index(target, params) do
      apply_mixer(target, index, ordered_mixer_writes(changes))
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    # The guard reads own their own exits (`query_echoed/4`, `master_volume/0`),
    # so what reaches here is a fire-and-forget write losing the transport —
    # after which the earlier properties in the same call may already be applied.
    :exit, _ ->
      {:error,
       "Lost contact with the OSC transport while setting " <>
         "#{mixer_property_list(params)} on #{mixer_subject_from(params)}. Some of those may " <>
         "already have been applied — check with get_session_state once Ableton is running " <>
         "with AbletonOSC enabled again."}
  end

  # The only multi-step create: `/live/song/create_return_track` appends, so the
  # index is only knowable afterwards and the rename has to follow it. Registry
  # owns that sequencing and hands back the index.
  defp do_call("create_track", %{"track_type" => "return", "name" => name}) do
    case Registry.execute(%Command{command: :create_return_track, name: name}) do
      {:ok, index} ->
        FollowCam.steer("create_track", %{return: index})

        {:ok,
         ~s{Created return track "#{name}" (return #{index} — send #{send_letter(index)} on } <>
           "every track). It has no effect on it yet, so every send into it is silent: load " <>
           "one now with load_device (target: 'return', track: #{index})."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("create_track", %{"track_type" => type, "name" => name})
       when type in ["midi", "audio"] do
    command = %Command{command: :create_track, track_type: to_track_type(type), name: name}

    case Registry.execute(command) do
      {:ok, index} ->
        FollowCam.steer("create_track", %{track: index})
        {:ok, "Created #{type} track '#{name}' at index #{index}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  # The track-type guard up front is the difference between an error and a lie:
  # AbletonOSC accepts a create_clip/add_notes sequence aimed at an audio track
  # and drops it on the floor, so without this the reply reports notes that were
  # never written.
  defp do_call("write_midi_notes", %{"track" => track, "notes" => notes} = params)
       when is_list(notes) and notes != [] do
    slot = Map.get(params, "clip_slot", 0)
    clip_length = Map.get(params, "clip_length", 4.0)

    parsed_notes =
      Enum.map(notes, fn n ->
        %{
          pitch: n["pitch"],
          start_beat: n["start_beat"] / 1.0,
          duration: n["duration"] / 1.0,
          velocity: n["velocity"]
        }
      end)

    command = %Command{
      command: :write_notes,
      track: track,
      clip_slot: slot,
      clip_length: clip_length,
      notes: parsed_notes
    }

    with :ok <- ensure_midi_track(track),
         :ok <- Registry.execute(command) do
      name = Map.get(params, "name")
      maybe_name_clip(track, slot, name)
      FollowCam.steer("write_midi_notes", %{track: track, slot: slot})

      note_count = length(parsed_notes)

      {:ok,
       "Wrote #{note_count} note(s) to track #{track}, clip slot #{slot}#{clip_name_note(name)}"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    # `ensure_midi_track/1` and Registry's own clip lookup each report their
    # timeout, so an exit reaching here came from one of the fire-and-forget
    # sends — the transport itself has stopped answering. Don't blame the indices
    # for that; and say what may be left behind, since the clip is created before
    # the notes are added. (`slot` is bound in the body, which the implicit try
    # can't see; only the head's params are in scope, so it is read back off
    # `params`.)
    :exit, _ ->
      {:error,
       "Lost contact with the OSC transport while writing to clip slot " <>
         "#{Map.get(params, "clip_slot", 0)} on track #{track}, so the notes were not written " <>
         "and an empty clip may have been left in the slot. Check that Ableton is running with " <>
         "AbletonOSC enabled, then try again."}
  end

  # Two index spaces behind one tool: `target` picks which. The return branch is
  # guarded with `get/name` rather than `get/count` — one query catches a bad
  # index and a missing extension both, and the name is worth having in the
  # reply.
  defp do_call("delete_track", %{"track" => index, "target" => "return"}) do
    with {:ok, name} <-
           query_echoed(
             "/live/return_track/get/name",
             [index],
             "return track #{index}",
             @return_extension_hint
           ),
         :ok <- Transport.send_message("/live/song/delete_return_track", [index]) do
      steer_after_delete(
        "delete_track",
        %{return: index},
        "/live/return_track/get/count"
      )

      State.refresh()

      {:ok,
       ~s{Deleted return track #{index} "#{name}". The returns after it have shifted down a } <>
         "place, taking their send letters with them — re-check get_session_state before " <>
         "touching another send."}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("delete_track", %{"track" => track}) do
    case Transport.send_message("/live/song/delete_track", [track]) do
      :ok ->
        steer_after_delete("delete_track", %{track: track}, "/live/song/get/num_tracks")
        State.refresh()
        {:ok, "Deleted track #{track}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  # ⚠️ Live placing the duplicate at source + 1 is the UI's behaviour and is
  # assumed here; it is a smoke-test item.
  defp do_call("duplicate_track", %{"track" => track}) do
    case Transport.send_message("/live/song/duplicate_track", [track]) do
      :ok ->
        FollowCam.steer("duplicate_track", %{track: track + 1})
        State.refresh()
        {:ok, "Duplicated track #{track} — the copy is track #{track + 1}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("set_tempo", %{"bpm" => bpm}) do
    case Transport.send_message("/live/song/set/tempo", [bpm / 1.0]) do
      :ok -> {:ok, "Set tempo to #{bpm} BPM"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # `/live/song/set/swing_amount` is fork-only and, like every setter, silent —
  # a Remote Scripts copy that predates the fork pin drops it on the floor
  # indistinguishably from success. There is no no-change branch to hang the
  # hint on, so it rides the success reply; `get_session_state` showing "swing
  # unknown" is the corroborating symptom, since the getter is equally absent.
  defp do_call("set_swing_amount", %{"amount" => amount}) do
    case Transport.send_message("/live/song/set/swing_amount", [amount / 1.0]) do
      :ok ->
        {:ok,
         "Set the global swing amount to #{amount}. Swing is applied when notes " <>
           "are quantized — quantize the clip to hear it. If nothing changes even " <>
           "after quantizing, the installed AbletonOSC may predate swing support: " <>
           "run mix abletonosc.install and restart Live."}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("set_groove_amount", %{"amount" => amount}) do
    case Transport.send_message("/live/song/set/groove_amount", [amount / 1.0]) do
      :ok ->
        {:ok,
         "Set the global groove amount to #{amount}. This scales grooves already " <>
           "assigned to clips from the Groove Pool — clips without a groove are " <>
           "unaffected."}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("set_time_signature", %{
         "numerator" => numerator,
         "denominator" => denominator
       }) do
    with :ok <- Transport.send_message("/live/song/set/signature_numerator", [numerator]),
         :ok <- Transport.send_message("/live/song/set/signature_denominator", [denominator]) do
      beats = numerator * 4 / denominator

      {:ok,
       "Set the time signature to #{numerator}/#{denominator}. " <>
         "Clip lengths and note times still count quarter-note beats: one bar is now #{beats} beats."}
    else
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("start_playing", _params) do
    case Transport.send_message("/live/song/start_playing", []) do
      :ok -> {:ok, "Started playback"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("stop_playing", _params) do
    case Transport.send_message("/live/song/stop_playing", []) do
      :ok -> {:ok, "Stopped playback"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("set_metronome", %{"enabled" => enabled}) do
    value = if enabled, do: 1, else: 0

    case Transport.send_message("/live/song/set/metronome", [value]) do
      :ok -> {:ok, "Metronome #{if enabled, do: "on", else: "off"}"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # `/live/song/capture_midi` never replies: AbletonOSC's `_call_method` calls
  # `song.capture_midi()` and returns nothing, and it *catches* whatever the
  # call raises — so a capture with nothing buffered is exactly as silent as one
  # that worked. The only evidence available is the session itself, hence the
  # sandwich: snapshot the clip grid and the tempo before, fire, snapshot again,
  # and report the difference. Deliberately behaviour-agnostic — Live's
  # placement rules (which track, which slot, whether a scene gets added) are
  # observed rather than modelled.
  defp do_call("capture_midi", params) do
    with {:ok, tempo_before} <- query_tempo(),
         {:ok, before_grid} <- snapshot_grid() do
      fire_capture(tempo_before, before_grid, Map.get(params, "name"))
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the session before capturing, so nothing was sent. Check that " <>
         "Ableton is running with AbletonOSC enabled."}
  end

  # --- Session recording ---
  #
  # The deliberate take, and the only route audio has into a set. It rides on
  # `/live/clip_slot/fire`'s optional `record_length` (in beats): given one, Live
  # ends the take itself and leaves the clip looping; without one the take runs
  # until `stop_recording` re-fires the slot.
  #
  # Everything before the fire is a guard, because a fire is silent and every way
  # this goes wrong looks identical on the wire — an occupied slot *launches* that
  # clip, a disarmed track records nothing, a group track has no slots of its own.
  # Arming is done for the user rather than asked about: "record me a take on the
  # keys" is consent to arm, and the reply discloses it.
  #
  # `record_length/1` is placed before every OSC-issuing guard on purpose: it reads
  # `State.song()` directly, so it is the one step whose timeout is *not* already
  # turned into an `{:error, _}` by a query helper's own `catch`. Keeping it ahead
  # of `ensure_armed/1` keeps the realistic timeout — a session mirror that isn't
  # answering — from landing in the outer `catch` below with the track already
  # armed, since that catch's text says nothing was sent. It is not an absolute
  # guarantee: `Transport.send_message/2` is itself a `GenServer.call`, so a
  # transport that dies between the arm and the fire still reaches that clause.
  # Nothing cheaper distinguishes the two, and a dead transport has already made
  # the reply moot.
  #
  # Once the fire itself is sent, `report_record_started/5` is responsible for
  # never repeating that "nothing was sent" framing: `record_echo/2`'s own guard
  # errors still say it (they're shared with the pre-fire guards), so it rewraps
  # them instead of returning them verbatim.
  defp do_call("record_clip", %{"track" => track, "clip_slot" => slot} = params) do
    bars = Map.get(params, "bars")

    with :ok <- ensure_bars(bars),
         {:ok, beats} <- record_length(bars),
         :ok <- ensure_slot_empty(track, slot),
         {:ok, just_armed?} <- ensure_armed(track),
         {:ok, input_doubt} <- check_will_record(track, slot),
         :ok <- fire_for_record(track, slot, beats) do
      report_record_started(track, slot, bars, beats, just_armed?, input_doubt)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out checking the track and slot before recording, so nothing was sent. Check " <>
         "that Ableton is running with AbletonOSC enabled."}
  end

  # Finishing a take is a second fire at the *same* slot: Live ends the recording
  # at the next launch-quantization boundary and drops the clip into looped
  # playback. Both guards exist to stop that fire ever reaching an empty slot,
  # where the identical message would *start* a recording instead.
  defp do_call("stop_recording", %{"track" => track, "clip_slot" => slot}) do
    hint = " Nothing is recording there, and nothing was fired."

    with :ok <- ensure_clip(track, slot, hint),
         :ok <- ensure_recording(track, slot),
         :ok <- Transport.send_message("/live/clip_slot/fire", [track, slot]) do
      FollowCam.steer("stop_recording", %{track: track, slot: slot})

      {:ok,
       "Finishing the take in track #{track}, slot #{slot} — it ends at the next quantization " <>
         "boundary and keeps looping. get_clip_properties to inspect it (get_clip_notes too, " <>
         "if it's MIDI — an audio take has no notes to read); delete_clip to scrap it."}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # --- Sends and the mixer ---
  #
  # Sends belong to the *regular* track that feeds the return, so they use
  # upstream's /live/track/get|set/send. Everything about the returns themselves
  # and the master comes from the fork's return_track.py — a Seshat extension, so
  # an un-run `mix abletonosc.install` means no reply at all rather than an
  # error. Each mutation therefore reads its own value first. That guard proves
  # the target exists and supplies the old value; it does not verify that Live
  # subsequently accepted the fire-and-forget setter.

  # The one mixer setter that reads its own value back. Volume, pan, mute and
  # solo can stay fire-and-forget because each has a listener pushing Live's
  # accepted value into the mirror, so a lost or refused set is corrected there
  # within a beat. A send has neither — `track.py` registers no send listener
  # and sends are outside `Session.State` entirely — so nothing anywhere ever
  # corrects this one, and a reply that merely asserted "Set send A … to X"
  # would be the model's only, unchecked account of a silent setter. Hence the
  # read-back: the guard proves the indices and supplies the "was" value, the
  # read-back is what makes the outcome observed rather than assumed.
  defp do_call("set_track_send", %{"track" => track, "send" => send_index, "value" => value}) do
    subject = "send #{send_letter(send_index)}#{return_track_label(send_index)} on track #{track}"

    with {:ok, old} <-
           query_echoed(
             "/live/track/get/send",
             [track, send_index],
             "send #{send_index} on track #{track}",
             @send_index_hint
           ),
         :ok <-
           Transport.send_message("/live/track/set/send", [track, send_index, value / 1.0]) do
      confirm_send(track, send_index, value, old, subject)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    # The guard and the read-back each catch their own exit, so what is left
    # here is the send itself losing the transport — after which the level may
    # or may not have moved.
    :exit, _ ->
      {:error,
       "The set was sent but reading the level back timed out — verify with get_track_sends."}
  end

  defp do_call("get_track_sends", %{"track" => track}) do
    with {:ok, count} <- return_track_count(),
         {:ok, sends} <- read_sends(track, count) do
      {:ok, format_track_sends(track, sends)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # --- Undo / redo ---
  #
  # Both addresses are send-only: Live never acknowledges either, so
  # `Transport.send_message/2` returning `:ok` means the bytes left the socket
  # and nothing more. The old replies ("Undone" / "Redone") asserted an outcome
  # nothing had observed — measured 2026-08-02, a `redo` against an exhausted
  # redo stack reported success while a refreshed `get_session_state` showed
  # Live had not moved. Two things change that: the reply now reports the
  # *request*, never the outcome, and `can_undo` / `can_redo` are read first so
  # the one case the model is actively steered into — walking off the end of the
  # history, one call per mutating tool call — is refused with a reason instead
  # of confirmed with a fiction.
  #
  # The guard runs on every call rather than once per batch. `Handlers` has no
  # batch (each MCP `tools/call` is independent), and an up-front check is wrong
  # for the goal anyway: three `undo` calls against a two-deep history pass it
  # and the third still lies. The guard has to sit where the wall is hit.
  #
  # It also sits inside `do_call/2` deliberately, i.e. *after* `undo_stepped/2`'s
  # defensive `/live/song/end_undo_step`. Closing a leaked step can legitimately
  # add an entry to the history, flipping `can_undo` from false to true, so a
  # read taken before that send would answer about a history state that no
  # longer exists by the time we send.
  defp do_call("undo", _params) do
    history_move(%{
      verb: "undo",
      guard_address: "/live/song/get/can_undo",
      guard_name: "can_undo",
      send_address: "/live/song/undo",
      refusal:
        "Live reported no undo step available, so no undo was sent. Do not retry unless " <>
          "history has changed."
    })
  end

  defp do_call("redo", _params) do
    history_move(%{
      verb: "redo",
      guard_address: "/live/song/get/can_redo",
      guard_name: "can_redo",
      send_address: "/live/song/redo",
      refusal:
        "Live reported no redo step available, so no redo was sent. Do not retry unless " <>
          "history has changed; any new edit can clear Live's redo history."
    })
  end

  # --- Clip control ---

  # Guarded because firing an empty slot is not a no-op: Live reads it as a stop
  # button and silences the track, so an unguarded typo looks like "fired" while
  # doing the opposite of what was asked.
  defp do_call("fire_clip", %{"track" => track, "clip_slot" => slot}) do
    hint =
      " Firing an empty slot would have stopped the track instead — if that was the intent, " <>
        "use stop_clip."

    with :ok <- ensure_clip(track, slot, hint),
         :ok <- Transport.send_message("/live/clip/fire", [track, slot]) do
      {:ok, "Fired clip on track #{track}, slot #{slot}"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("stop_clip", %{"track" => track, "clip_slot" => slot}) do
    case Transport.send_message("/live/clip/stop", [track, slot]) do
      :ok -> {:ok, "Stopped clip on track #{track}, slot #{slot}"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("delete_clip", %{"track" => track, "clip_slot" => slot}) do
    case Transport.send_message("/live/clip_slot/delete_clip", [track, slot]) do
      :ok ->
        FollowCam.steer("delete_clip", %{track: track, slot: slot})
        {:ok, "Deleted clip on track #{track}, slot #{slot}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("duplicate_clip", %{
         "track" => t,
         "clip_slot" => s,
         "target_track" => tt,
         "target_clip_slot" => ts
       }) do
    case Transport.send_message("/live/clip_slot/duplicate_clip_to", [t, s, tt, ts]) do
      :ok ->
        FollowCam.steer("duplicate_clip", %{track: tt, slot: ts})
        {:ok, "Duplicated clip from track #{t}/slot #{s} to track #{tt}/slot #{ts}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  # --- Clip properties ---
  #
  # Sixteen single-value getters — 12 common (`is_midi_clip` plus the 11 in
  # `@clip_common_reads`) and four audio-only — rather than one bulk read: the
  # bulk `/live/song/get/track_data` reply is a bare value list with no index echo,
  # so it can't be checked against the clip we asked about (same reasoning as
  # `ensure_midi_track/1`). What made that expensive was sending them one at a
  # time. A round trip costs one AbletonOSC tick (~100ms) because it waits for
  # the next tick, and a tick answers everything already queued on the socket —
  # so the twelve reads below ride *one* tick together through
  # `Transport.query_batch/2`, which echo-checks each reply against the entry
  # that asked for it. Measured 2026-08-04; see priv/AbletonOSC/API.md,
  # "Round trips cost ticks, not datagrams".
  #
  # `ensure_clip/3` first so an empty slot costs one timeout-free error rather
  # than a batch of twelve rejections. `is_midi_clip` rides the common batch
  # rather than being asked first, so the type check is free: only an audio clip
  # pays a second tick, for the four audio-only reads.
  defp do_call("get_clip_properties", %{"track" => track, "clip_slot" => slot}) do
    with :ok <- ensure_clip(track, slot),
         {:ok, common} <-
           read_clip_properties(track, slot, ["is_midi_clip" | @clip_common_reads]),
         midi? = truthy?(common["is_midi_clip"]),
         {:ok, audio} <- read_audio_clip_properties(track, slot, midi?) do
      properties = common |> Map.delete("is_midi_clip") |> Map.merge(audio)
      {:ok, format_clip_properties(track, slot, midi?, properties)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the properties of the clip in slot #{slot} on track #{track}, so " <>
         "nothing is known about it. Check the indices with get_clip_slots, and that Ableton " <>
         "is running with AbletonOSC enabled."}
  end

  # Every clip setter is fire-and-forget — Live's own rejection of an invalid
  # state would be silent — so the honesty of this tool rests on three things:
  # transport-free validation up front, an ordered write list that never passes
  # through an invalid intermediate state (`clip_property_writes/2`), and a
  # read-back of every property written.
  defp do_call("set_clip_properties", %{"track" => track, "clip_slot" => slot} = params) do
    changes = Map.take(params, @clip_writable_properties)

    with :ok <- ensure_clip_changes(changes),
         :ok <- validate_clip_pairs(changes),
         :ok <- ensure_clip(track, slot),
         :ok <- ensure_audio_clip(track, slot, changes),
         {:ok, current} <- read_clip_pair_context(track, slot, changes),
         {:ok, writes} <- clip_property_writes(current, changes),
         :ok <- send_clip_writes(track, slot, writes),
         {:ok, readback} <- read_clip_writeback(track, slot, writes) do
      FollowCam.steer("set_clip_properties", %{track: track, slot: slot})
      {:ok, format_clip_writes(track, slot, current, writes, readback)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    # Everything before the sends reports its own timeout, so an exit reaching
    # here came from a fire-and-forget write or its read-back: the transport
    # itself has stopped answering, and some of the properties asked for may
    # already be applied. The write list isn't in scope in the implicit try —
    # only the head's params are — so the properties are named off `params`.
    :exit, _ ->
      {:error,
       "Lost contact with the OSC transport while setting " <>
         "#{clip_property_list(params)} on the clip in slot #{slot} on track #{track}. Some of " <>
         "those may already have been applied — check with get_clip_properties once Ableton is " <>
         "running with AbletonOSC enabled again."}
  end

  # --- Scene control ---

  defp do_call("fire_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/scene/fire", [scene]) do
      :ok -> {:ok, "Fired scene #{scene}"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # `-1` means "append", so the new scene's index is only knowable afterwards —
  # hence the count read, which also lets the reply name the index the model will
  # need next. Best-effort like every follow-cam read: a miss falls back to the
  # unresolved wording rather than failing a create that succeeded.
  defp do_call("create_scene", %{"index" => index}) do
    case Transport.send_message("/live/song/create_scene", [index]) do
      :ok ->
        case created_scene_index(index) do
          {:ok, scene} ->
            FollowCam.steer("create_scene", %{scene: scene})
            {:ok, "Created scene at index #{scene}"}

          :error ->
            {:ok,
             "Created a scene at the end of the session — reading the scene count back to " <>
               "confirm its index timed out, so check get_clip_slots if you need it."}
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("delete_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/song/delete_scene", [scene]) do
      :ok ->
        steer_after_delete("delete_scene", %{scene: scene}, "/live/song/get/num_scenes")
        {:ok, "Deleted scene #{scene}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  # ⚠️ Live placing the copy at source + 1 is assumed, as in duplicate_track.
  defp do_call("duplicate_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/song/duplicate_scene", [scene]) do
      :ok ->
        FollowCam.steer("duplicate_scene", %{scene: scene + 1})
        {:ok, "Duplicated scene #{scene} — the copy is scene #{scene + 1}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("set_scene_name", %{"scene" => scene, "name" => name}) do
    case Transport.send_message("/live/scene/set/name", [scene, name]) do
      :ok -> {:ok, "Renamed scene #{scene} to '#{name}'"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # --- Loop control ---

  defp do_call("set_loop", %{"enabled" => enabled} = params) do
    value = if enabled, do: 1, else: 0

    with :ok <- Transport.send_message("/live/song/set/loop", [value]),
         :ok <- maybe_set_loop_start(params),
         :ok <- maybe_set_loop_length(params) do
      {:ok, "Loop #{if enabled, do: "on", else: "off"}#{loop_range_summary(params)}"}
    else
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # --- View selection ---

  # One message, no %Command{} and no FollowCam: this *is* the primitive the
  # follow cam sends. Like every other silent setter, `:ok` means the local
  # transport accepted the datagram — the address never replies, and Seshat
  # cannot see what is on screen. Nothing waits between this and the next tool
  # call either: loopback datagrams reach AbletonOSC in send order.
  defp do_call("show_view", %{"view" => view}) do
    case Transport.send_message("/live/view/show_view", [view]) do
      :ok -> {:ok, "Showing #{view_label(view)}"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # Unlike `show_view` this one verifies itself. The hide address is silent, and
  # its accepted set is Live's rather than ours: a name that quietly does nothing
  # (or that a future Live stops hiding) would be an undetectable no-op forever.
  # The enum only carries names measured to hide, and the read-after is what
  # keeps that measurement honest — the `delete_device` / `set_clip_properties`
  # precedent. Nothing here touches `FollowCam`: hiding a pane is the user's
  # navigation, not a mutation to steer to.
  defp do_call("hide_view", %{"view" => view}) do
    with :ok <- Transport.send_message("/live/view/hide_view", [view]),
         :ok <- confirm_view_hidden(view) do
      {:ok, "Hidden #{view_label(view)}. show_view brings it back."}
    else
      {:error, reason} when not is_binary(reason) -> {:error, Transport.describe_error(reason)}
      {:error, message} -> {:error, message}
    end
  end

  # Six sequential reads at ~100ms each measured — over half a second for
  # the full sweep, not the near-free loopback read this comment once implied.
  # The first failure ends the call: a summary assembled from a partial read
  # looks exactly as confident as a complete one, which is the thing this tool
  # exists not to do.
  defp do_call("get_view_state", _params) do
    Enum.reduce_while(@view_names, {:ok, %{}}, fn view, {:ok, acc} ->
      case query_view_visible(view) do
        {:ok, visible} -> {:cont, {:ok, Map.put(acc, view, visible)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, visibility} -> {:ok, view_state_summary(visibility)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("select_track", %{"track" => track}) do
    case Transport.send_message("/live/view/set/selected_track", [track]) do
      :ok -> {:ok, "Selected track #{track}"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp do_call("select_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/view/set/selected_scene", [scene]) do
      :ok -> {:ok, "Selected scene #{scene}"}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # --- Notes ---

  # In-place note editing, composed rather than atomic. Live's own
  # `apply_note_modifications` is keyed on `note_id`, which the fork's
  # `/live/clip/get/notes` reply does not carry (FORK_GAPS.md, "Notes flatten to
  # five fields"), so the only way to change a note through this bridge is to
  # read it, remove the window it sits in, and add it back changed. `call/2`
  # already brackets every dispatch in one `begin_undo_step`/`end_undo_step`
  # pair, so the three datagrams are one undo step in Live — measured
  # 2026-08-27, one `undo` restored the pre-edit notes exactly.
  #
  # Two conversions are load-bearing, not tidiness: `get/notes` answers with
  # `mute` as an OSC boolean and velocity as a float, while `add/notes` wants
  # `0|1` and an integer — and `Seshat.OSC.Message` has no type tag for a
  # boolean at all, so re-sending a reply verbatim takes the Transport
  # GenServer down (reproduced 2026-08-27; priv/AbletonOSC/API.md).
  defp do_call("edit_notes", %{"track" => track} = params) do
    slot = Map.get(params, "clip_slot", 0)
    window = edit_window(params)
    changes = NoteEdit.changes(params)

    with :ok <- NoteEdit.validate(changes),
         :ok <- ensure_clip(track, slot),
         :ok <- ensure_midi_clip(track, slot),
         {:ok, matched} <- read_note_window(track, slot, window) do
      rewrite_notes(track, slot, window, changes, matched)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    # Every read on this path catches its own exit and words the consequence
    # itself, so an exit reaching here came from one of the two fire-and-forget
    # writes — after which claiming nothing changed would be the lie
    # `quantize_clip`'s own exit clause is written to avoid.
    :exit, _ ->
      {:error,
       "Lost contact with the OSC transport while editing the notes in slot " <>
         "#{Map.get(params, "clip_slot", 0)} on track #{track}. The edit may or may not have " <>
         "been applied — read the clip back with get_clip_notes once Ableton is running with " <>
         "AbletonOSC enabled again."}
  end

  # Reads only, so no %Command{}/Registry — Registry is for mutation sequences.
  # The two guards up front are not politeness: querying notes on an empty slot
  # raises inside AbletonOSC, so the read never answers on its own address. The
  # structured `/live/error` turns that into a fast rejection rather than a 5s
  # timeout, but a rejection carrying no distinguishing value is still a worse
  # answer than "the slot is empty" — which is what these two produce.
  # Three replies, all correlated: without the echo check a straggler abandoned
  # by an earlier timeout could pair one clip's name with another clip's length
  # or notes. The notes read is the one place in the file where the echo is a
  # strict *prefix* of the request — `/live/clip/get/notes` echoes only the track
  # and slot, never the pitch/time range it was given (verified in the fork's
  # clip.py: `create_clip_callback` returns `(track_index, clip_index, *rv)`) —
  # hence the explicit `echo:`.
  defp do_call("get_clip_notes", %{"track" => track} = params) do
    slot = Map.get(params, "clip_slot", 0)

    with :ok <- ensure_clip(track, slot),
         :ok <- ensure_midi_clip(track, slot),
         {:ok, clip_name} <-
           query_correlated("/live/clip/get/name", [track, slot], decode: &unwrap_payload/1),
         {:ok, clip_length} <-
           query_correlated("/live/clip/get/length", [track, slot], decode: &unwrap_payload/1),
         {:ok, fields} <-
           query_correlated(
             "/live/clip/get/notes",
             [track, slot | note_range_args(params)],
             echo: [track, slot]
           ),
         {:ok, notes} <- parse_clip_notes(fields) do
      {:ok, format_clip_notes(track, slot, clip_name, clip_length, notes)}
    else
      {:error, {:stale, _values}} ->
        {:error, stale_reply_error("the clip in slot #{slot} on track #{track}")}

      {:error, {:remote, message}} ->
        {:error, remote_error(message)}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    # `slot` is bound in the body, which the implicit try can't see — only the
    # head's params are in scope here.
    :exit, _ ->
      {:error,
       "Timed out reading the notes in slot #{Map.get(params, "clip_slot", 0)} on track " <>
         "#{track}. Check the track index against get_session_state, and that Ableton is " <>
         "running with AbletonOSC enabled."}
  end

  # Live's own quantize, not an Elixir-side snap: the grid arithmetic stays
  # where it is already correct (and where, unlike every published description
  # of Live's grid enum, it is correct at all — see `grid_quantization/1`).
  #
  # Transport-direct rather than a %Command{}: one logical operation, and
  # Registry is for the three multi-step mutation sequences it owns.
  #
  # The address never replies on success, and the two failure modes are
  # indistinguishable *from here*: a bad grid integer is reported on the wire
  # as `/live/error ["request", "/live/clip/quantize", …]` and a Remote
  # Scripts copy predating the fork answers nothing at all, but this is a
  # `send_message/2` that has returned before either could land. So the tool's
  # honesty comes from reading the notes back either side of the send and
  # diffing them — the same shape as capture_midi's grid snapshot and
  # delete_device's count re-read. AbletonOSC processes datagrams in arrival
  # order and `clip.quantize()` runs synchronously inside its callback, so the
  # second read sees the post-quantize clip.
  defp do_call("quantize_clip", %{
         "track" => track,
         "clip_slot" => slot,
         "grid" => grid,
         "amount" => amount
       }) do
    with :ok <- reject_zero_amount(amount),
         :ok <- ensure_clip(track, slot),
         :ok <- ensure_midi_clip(track, slot),
         clip_name = read_clip_name(track, slot),
         {:ok, before_notes} <- read_all_notes(track, slot, :before_quantize),
         :ok <- ensure_notes_to_quantize(before_notes, track, slot),
         :ok <- send_quantize(track, slot, grid, amount),
         {:ok, after_notes} <- read_all_notes(track, slot, :after_quantize) do
      FollowCam.steer("quantize_clip", %{track: track, slot: slot})

      {:ok,
       format_quantize_result(track, slot, clip_name, grid, amount, before_notes, after_notes)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    # Deliberately not "nothing was sent": the exit can happen either side of
    # the quantize message, and once it is on the wire claiming nothing changed
    # would be a lie (the set_clip_properties precedent).
    :exit, _ ->
      {:error,
       "Lost contact with the OSC transport while quantizing the clip in slot #{slot} on " <>
         "track #{track}. The quantize may or may not have been applied — read the clip back " <>
         "with get_clip_notes, and check Ableton is running with AbletonOSC enabled."}
  end

  # --- Sound catalog ---
  #
  # Results come from ETS, so no Ableton or Catalog-process round trip is
  # required. The advisory freshness check fails soft to `:unknown` if that
  # process is busy or absent rather than delaying or taking down the search.

  defp do_call("search_library", params) do
    opts =
      [
        query: Map.get(params, "query"),
        tags: Map.get(params, "tags", []),
        category: Map.get(params, "category"),
        max_results: Map.get(params, "max_results", @default_catalog_results)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if Catalog.count() == 0 do
      {:error,
       "The sound catalog is empty — it has never been built, or the build failed. Run " <>
         "reindex_library (Ableton must be running; it takes up to a minute), or fall back to " <>
         "list_browser_items for this search."}
    else
      freshness = Catalog.freshness()
      {entries, total, facets} = Catalog.search(opts)

      # A zero-result search is the one case worth a second scan: without it the
      # reply can only say "loosen something", which is where the model gives up.
      context = if total == 0, do: Catalog.diagnose(opts), else: facets

      {:ok,
       format_catalog_entries(entries, total, context) <> catalog_freshness_notice(freshness)}
    end
  end

  defp do_call("reindex_library", _params) do
    case Catalog.reindex() do
      {:ok, summary} ->
        {:ok, format_reindex_summary(summary)}

      {:error, reason} ->
        {:error, "Could not reindex the library: #{inspect(reason)}"}
    end
  catch
    :exit, _ ->
      {:error,
       "The browser export timed out. Is Ableton Live running with AbletonOSC enabled, and has " <>
         "`mix abletonosc.install` been run to add the browser handler? A very large library " <>
         "can also simply exceed the timeout — try again once Live has finished loading."}
  end

  # --- Browser / device loading ---
  #
  # Both addresses are Seshat extensions to AbletonOSC, served by the fork's
  # browser.py — see `mix abletonosc.install`.

  # The reply echoes the category and the filter — as `str()` round-trips of the
  # strings sent, so identity for the schema-validated ones Seshat sends — but
  # never `max_results`, hence the explicit `echo:`. This runs on the 15s
  # @browse_timeout, the widest straggler window in the file, so presenting an
  # earlier search's results as this one's is the realistic failure here.
  #
  # The error arm is echo-checked too, because `query_correlated/4` verifies
  # before the decode fun ever runs: a stale error envelope would report a
  # failure that never happened to this search, the same reason `load_outcome/2`
  # rejects a mismatched error rather than relaying it.
  #
  # The reissue can cost a second browse (up to 15s more, worst case). Accepted:
  # it only happens on a stale reply, browser.py caches its per-category index so
  # a second walk of an already-indexed category is fast, and the alternative is
  # showing another search's results.
  defp do_call("list_browser_items", %{"category" => category} = params) do
    filter = Map.get(params, "filter", "")
    max_results = Map.get(params, "max_results", @default_max_results)

    query =
      query_correlated(
        "/live/browser/get/items",
        [category, filter, max_results],
        echo: [category, filter],
        timeout: @browse_timeout,
        decode: &browser_items_payload/1
      )

    case query do
      {:ok, {total, pairs}} ->
        {:ok, format_browser_items(pairs, total)}

      {:error, {:remote, message}} ->
        {:error, message}

      {:error, {:stale, _values}} ->
        {:error,
         stale_reply_error(
           "the browser search for #{category}",
           "Nothing in Live was changed — run the search again."
         )}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out searching Live's browser. The first search of a large category " <>
         "(samples, sounds, plugins) is slow — try again, or narrow it with a filter. " <>
         "If it keeps timing out, check that Ableton is running with AbletonOSC enabled and " <>
         "that `mix abletonosc.install` has been run to add the browser handler."}
  end

  # --- load_device on a return / the master ---
  #
  # Their own addresses rather than a widened /live/browser/load_item, so the
  # reply arity itself says which index space was targeted — and because the two
  # vendored endpoints verify that the load *landed*, which the regular-track one
  # has no need to. Loading a non-effect onto a return or the master doesn't
  # fail in Live: it silently creates a stray MIDI track and loads it there
  # (measured 2026-07-31), so the error path below is the normal outcome of
  # asking for an instrument, not an edge case.
  defp do_call("load_device", %{"track" => track, "uri" => uri, "target" => "return"}) do
    query = Transport.query("/live/browser/load_item_on_return", [track, uri], @load_timeout)

    case query do
      {:ok, {_address, args}} ->
        case load_outcome(args, [track, uri]) do
          {:loaded, [return_name, device_name, device]} ->
            Catalog.record_load(uri)
            FollowCam.steer("load_device", %{return: track, device: device})

            {:ok,
             ~s{Loaded '#{device_name}' onto return track #{track} "#{return_name}"} <>
               "#{loaded_device_note(device)}. Every track's send #{send_letter(track)} now " <>
               "feeds it."}

          {:remote_error, message} ->
            {:error, message}

          :stale ->
            {:error, stale_load_error("return track #{track}", uri)}

          _other ->
            {:error, unexpected_chain_reply("return track #{track}", args)}
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       extension_missing_error(
         "load a device onto return track #{track}",
         "it is unknown whether anything was loaded — check Ableton before retrying"
       )}
  end

  defp do_call("load_device", %{"uri" => uri, "target" => "master"}) do
    case Transport.query("/live/browser/load_item_on_master", [uri], @load_timeout) do
      {:ok, {_address, args}} ->
        case load_outcome(args, [uri]) do
          {:loaded, [device_name, device]} ->
            Catalog.record_load(uri)
            FollowCam.steer("load_device", %{master: true, device: device})

            {:ok,
             "Loaded '#{device_name}' onto #{chain_label(:master)}" <>
               "#{loaded_device_note(device)} — it now processes the whole mix."}

          {:remote_error, message} ->
            {:error, message}

          :stale ->
            {:error, stale_load_error(chain_label(:master), uri)}

          _other ->
            {:error, unexpected_chain_reply(chain_label(:master), args)}
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       extension_missing_error(
         "load a device onto #{chain_label(:master)}",
         "it is unknown whether anything was loaded — check Ableton before retrying"
       )}
  end

  defp do_call("load_device", %{"track" => track, "uri" => uri}) do
    case Transport.query("/live/browser/load_item", [track, uri], @load_timeout) do
      {:ok, {_address, args}} ->
        case load_outcome(args, [track, uri]) do
          {:loaded, [name, device]} ->
            Catalog.record_load(uri)
            FollowCam.steer("load_device", %{track: track, device: device})
            {:ok, "Loaded '#{name}' onto track #{track}#{loaded_device_note(device)}"}

          # The 4-element ok reply is the *previous* shape of this address, which
          # is our own — so seeing it means Live is running an older copy of the
          # fork. Not a compat path: a self-diagnosing refusal, since the device
          # did load and a silent degrade would hide why the view never followed.
          {:loaded, [name]} ->
            {:error,
             "Loaded '#{name}' onto track #{track}, but Ableton is running an older copy of " <>
               "Seshat's AbletonOSC extension: its reply carries no device index, so the view " <>
               "can't follow the load. Run `mix abletonosc.install` and restart Ableton Live."}

          {:remote_error, message} ->
            {:error, message}

          :stale ->
            {:error, stale_load_error("track #{track}", uri)}

          _other ->
            {:error, "Unexpected reply from Live's browser: #{inspect(args)}"}
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out loading the device onto track #{track}. A heavy plugin may still be " <>
         "loading — check Ableton, and use get_session_state before retrying so you don't " <>
         "load it twice."}
  end

  # --- Device chain / parameters ---

  defp do_call("get_track_devices", %{"track" => track, "target" => "return"}) do
    read_vendored_chain("/live/return_track/get/devices", [track], {:return, track})
  end

  defp do_call("get_track_devices", %{"target" => "master"}) do
    read_vendored_chain("/live/master/get/devices", [], :master)
  end

  # Three replies rather than the vendored chains' one, so the three lists could
  # otherwise describe two different chains. One batch: Transport hands each
  # reply to the entry whose track index it echoes, which is the check the three
  # `query_correlated/4` calls used to do caller-side — at the price of one
  # ~100ms AbletonOSC tick each, where the batch spends one between them.
  # Collapsing them onto a combined /live/track/get/devices endpoint in the fork
  # was weighed and dropped for exactly that reason: it would buy no latency over
  # this (docs/archive/PLAN_batched_queries.md, benchmarked 2026-08-04). What stays
  # residual: three verified replies are still three snapshots, so a chain edited
  # mid-read is reported as it was at each moment — the window is now one tick
  # wide instead of three.
  defp do_call("get_track_devices", %{"track" => track}) do
    subject = "the devices on track #{track}"

    entries = [
      {"/live/track/get/devices/name", [track]},
      {"/live/track/get/devices/type", [track]},
      {"/live/track/get/devices/class_name", [track]}
    ]

    with {:ok, [name_reply, type_reply, class_reply]} <- Transport.query_batch(entries),
         {:ok, names} <- decode_entry(name_reply, subject, &{:ok, &1}),
         {:ok, types} <- decode_entry(type_reply, subject, &{:ok, &1}),
         {:ok, classes} <- decode_entry(class_reply, subject, &{:ok, &1}) do
      {:ok, format_device_chain({:track, track}, names, types, classes)}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading devices on track #{track}. Check the track index against " <>
         "get_session_state, and that Ableton is running with AbletonOSC enabled."}
  end

  defp do_call("get_device_parameters", %{
         "track" => track,
         "device" => device,
         "target" => "return"
       }) do
    read_vendored_parameters(
      "/live/return_track/device/get/parameters",
      [track, device],
      {:return, track},
      device
    )
  end

  defp do_call("get_device_parameters", %{"device" => device, "target" => "master"}) do
    read_vendored_parameters(
      "/live/master/device/get/parameters",
      [device],
      :master,
      device
    )
  end

  # `get_track_devices`' hazard at worse odds — five replies rather than three,
  # each of which has to echo a track *and* a device index — so one batch here
  # too, resolved per entry on both indices. The name read decodes a single
  # value; the four parameter reads keep their whole list, which is why they pass
  # the identity decode rather than `unwrap_payload/1`.
  defp do_call("get_device_parameters", %{"track" => track, "device" => device}) do
    subject = "device #{device} on track #{track}"
    indices = [track, device]

    entries = [
      {"/live/device/get/name", indices},
      {"/live/device/get/parameters/name", indices},
      {"/live/device/get/parameters/value", indices},
      {"/live/device/get/parameters/min", indices},
      {"/live/device/get/parameters/max", indices}
    ]

    with {:ok, [device_reply, name_reply, value_reply, min_reply, max_reply]} <-
           Transport.query_batch(entries),
         {:ok, device_name} <- decode_entry(device_reply, subject),
         {:ok, names} <- decode_entry(name_reply, subject, &{:ok, &1}),
         {:ok, values} <- decode_entry(value_reply, subject, &{:ok, &1}),
         {:ok, mins} <- decode_entry(min_reply, subject, &{:ok, &1}),
         {:ok, maxes} <- decode_entry(max_reply, subject, &{:ok, &1}) do
      {:ok,
       format_device_parameters(
         {:track, track},
         device,
         device_name,
         names,
         values,
         mins,
         maxes
       )}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading device #{device} on track #{track}. Check both indices with " <>
         "get_track_devices first."}
  end

  # The pre-read is not decoration on the vendored paths: the setter is silent,
  # so without it a bad device or parameter index would be discovered only
  # *after* something was sent — and the vendored getter answers a bad index with
  # an error envelope immediately, which is the whole reason it exists.
  defp do_call("set_device_parameter", %{
         "track" => track,
         "device" => device,
         "parameter" => parameter,
         "value" => value,
         "target" => "return"
       }) do
    set_vendored_parameter(
      {:return, track},
      "/live/return_track/device/get/parameter/value_string",
      "/live/return_track/device/set/parameter/value",
      [track, device, parameter],
      device,
      parameter,
      value
    )
  end

  defp do_call("set_device_parameter", %{
         "device" => device,
         "parameter" => parameter,
         "value" => value,
         "target" => "master"
       }) do
    set_vendored_parameter(
      :master,
      "/live/master/device/get/parameter/value_string",
      "/live/master/device/set/parameter/value",
      [device, parameter],
      device,
      parameter,
      value
    )
  end

  # The confirming read goes through `read_back_value/2`, the same helper the
  # vendored paths use for exactly this job. Without its echo check a straggler
  # on this address could present another parameter's display string as proof
  # this write landed — a fabricated confirmation, the one thing a read-back
  # exists to prevent — so an unverified read must reach the reply as
  # uncertainty and never as "it now reads '…'".
  defp do_call("set_device_parameter", %{
         "track" => track,
         "device" => device,
         "parameter" => parameter,
         "value" => value
       }) do
    subject = "parameter #{parameter} of device #{device} on track #{track}"

    with :ok <-
           Transport.send_message(
             "/live/device/set/parameter/value",
             [track, device, parameter, value / 1.0]
           ),
         {:ok, display} <-
           read_back_value("/live/device/get/parameter/value_string", [
             track,
             device,
             parameter
           ]) do
      {:ok, "Set #{subject} to #{value} — it now reads '#{display}'"}
    else
      :unconfirmed ->
        {:error,
         "The set was sent but reading #{subject} back did not confirm it — verify with " <>
           "get_device_parameters."}

      # Live named the rejection. Unlike the return and master clauses this one
      # has no pre-mutation guard, so the read-back is where a bad device or
      # parameter index surfaces — and it is the same pair of indices the set
      # used, so a rejection here means the set was refused too. Say that
      # rather than routing the model to get_device_parameters, which would be
      # rejected for the same reason.
      {:error, {:live_error, _} = reason} ->
        {:error,
         "#{Transport.describe_error(reason)} That read used the same indices as the set, " <>
           "so the set was refused too and nothing changed — list the chain with " <>
           "get_track_devices and its controls with get_device_parameters to find the " <>
           "indices that exist."}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    # A residual guard now rather than the read-back's timeout path:
    # `read_back_value/2` catches its own exit and answers `:unconfirmed`, so
    # what is left here is the send itself losing the transport.
    :exit, _ ->
      {:error,
       "The set was sent but reading the value back timed out — verify the result with " <>
         "get_device_parameters."}
  end

  # `/live/track/delete_device` has no reply on success — AbletonOSC's
  # `_call_method` returns nothing — and a bad device index raises inside the
  # callback. The raise is correlated on the wire now, but this is a
  # `send_message/2`: it has returned before that datagram arrives, so from
  # here success and failure still look identical. Hence the sandwich:
  # read the chain first (which validates the track index, bounds-checks the
  # device index in Elixir, and captures the names for the reply), then re-read
  # the count afterwards as the only confirmation available.
  # No count sandwich on the vendored paths: the vendored delete *replies*, with
  # the chain length re-read from Live afterwards. That is both the confirmation
  # and the check — `remaining` disagreeing with what the pre-read implies means
  # something else changed the chain, and saying so is better than reporting a
  # delete that may not be the one asked for.
  defp do_call("delete_device", %{"track" => track, "device" => device, "target" => "return"}) do
    delete_vendored_device(
      {:return, track},
      "/live/return_track/get/devices",
      [track],
      "/live/return_track/delete_device",
      device,
      &[track, &1]
    )
  end

  defp do_call("delete_device", %{"device" => device, "target" => "master"}) do
    delete_vendored_device(
      :master,
      "/live/master/get/devices",
      [],
      "/live/master/delete_device",
      device,
      &[&1]
    )
  end

  defp do_call("delete_device", %{"track" => track, "device" => device}) do
    with {:ok, names} <- read_device_names(track),
         {:ok, device} <- ensure_device_index({:track, track}, device, names),
         :ok <- Transport.send_message("/live/track/delete_device", [track, device]),
         :ok <- confirm_device_count(track, length(names) - 1) do
      FollowCam.steer("delete_device", %{
        track: track,
        device: device,
        remaining: length(names) - 1
      })

      {:ok, deleted_device_reply({:track, track}, device, names)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # Parameter 0 of every Live device is its "Device On" switch, so bypass is a
  # parameter write — but only if that really is what parameter 0 holds on this
  # device. The display value is read *before* the write and the write refused
  # unless it reads On/Off, so a device that breaks the assumption gets a clean,
  # self-diagnosing error instead of a wrong parameter silently changed.
  defp do_call("bypass_device", %{
         "track" => track,
         "device" => device,
         "enabled" => enabled,
         "target" => "return"
       }) do
    bypass_vendored_device(
      {:return, track},
      %{
        name: "/live/return_track/device/get/name",
        value_string: "/live/return_track/device/get/parameter/value_string",
        value: "/live/return_track/device/get/parameter/value",
        set: "/live/return_track/device/set/parameter/value"
      },
      [track, device],
      device,
      enabled
    )
  end

  defp do_call("bypass_device", %{
         "device" => device,
         "enabled" => enabled,
         "target" => "master"
       }) do
    bypass_vendored_device(
      :master,
      %{
        name: "/live/master/device/get/name",
        value_string: "/live/master/device/get/parameter/value_string",
        value: "/live/master/device/get/parameter/value",
        set: "/live/master/device/set/parameter/value"
      },
      [device],
      device,
      enabled
    )
  end

  defp do_call("bypass_device", %{"track" => track, "device" => device, "enabled" => enabled}) do
    subject = "device #{device} on track #{track}"

    with {:ok, name} <-
           query_echoed("/live/device/get/name", [track, device], subject, @device_index_hint),
         {:ok, prior} <-
           query_echoed(
             "/live/device/get/parameter/value_string",
             [track, device, 0],
             "the on/off switch of #{subject}",
             @device_index_hint
           ),
         :ok <- ensure_on_off_switch(name, prior) do
      set_device_enabled({:track, track}, device, name, enabled, prior, fn value ->
        with :ok <-
               Transport.send_message(
                 "/live/device/set/parameter/value",
                 [track, device, 0, value]
               ) do
          confirm_device_enabled_at(
            "/live/device/get/parameter/value",
            [track, device, 0],
            {:track, track},
            device,
            enabled
          )
        end
      end)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # Reads only, so direct Transport.query — no %Command{}/Registry (Registry
  # is for mutation sequences). One bulk track_data query per batch of tracks
  # plus one bulk query for every scene name; parsing and formatting are pure.
  defp do_call("get_clip_slots", _params) do
    case snapshot_grid() do
      {:ok, %{tracks: []}} ->
        {:ok, "No tracks in the session — the clip grid is empty."}

      {:ok, %{num_scenes: num_scenes, tracks: tracks}} ->
        case query_scene_names(num_scenes) do
          {:ok, scenes} -> {:ok, format_clip_slots(scenes, tracks)}
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, reason} -> {:error, Transport.describe_error(reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the clip grid. Check that Ableton is running with AbletonOSC enabled."}
  end

  # State mirrors Ableton by push, so it is current without asking. `refresh` is
  # the backstop for what the listeners can't see (a lost UDP push, or two
  # identically named tracks swapping places) and blocks until the re-read is
  # done — hence sync rather than the fire-and-forget `State.refresh/0`, which
  # is now debounced as well as asynchronous and would serve the stale mirror it
  # just asked to replace.
  #
  # That debounce is also why an unrefreshed read can be behind on *structure*
  # specifically: a track just created is in the mirror only once the coalesced
  # rebuild runs, and the debounce is trailing-edge — a sustained burst restarts
  # the timer on every request, so a long burst can leave structure stale for
  # the whole burst plus the debounce window plus the rebuild itself, not just
  # one second. Scalars are unaffected — they arrive by push.
  defp do_call("get_session_state", params) do
    with :ok <- maybe_refresh(params) do
      serve_session_state()
    end
  end

  # --- Audio output (macOS Accessibility, not OSC) ---
  #
  # The only two clauses in this file that never touch `Transport`. Live's
  # application-wide audio device preference is absent from the Live Object
  # Model, so it is reached through `Seshat.AX.Client` and the native helper
  # instead. Nothing else changes: no `%Command{}`, no `Registry`, no
  # `FollowCam` (there is no Live Set object to select), and nothing enters
  # `Session.State` — an audio device is application-wide, external to the Set,
  # and changed rarely enough that reading it on demand is right.
  #
  # The client module is configurable so the pure suite can dispatch these
  # clauses against a fake instead of driving a real UI.
  defp do_call("get_audio_outputs", _params) do
    case ax_client().list_outputs() do
      {:ok, %{current: current, devices: devices}} ->
        {:ok, format_audio_outputs(current, devices)}

      {:error, failure} ->
        {:error, audio_error(failure)}
    end
  end

  # An empty or whitespace-only string is a shape `required` cannot catch
  # (there is no `minLength` in `Validation`/`MCP.Schema` today) but the
  # helper's own CLI parsing does — as `set-output requires --device <name>.`,
  # its bare usage text, if this clause let it through. That would put an
  # Objective-C command-line detail on the tool surface, exactly what the rest
  # of this protocol works to keep off it, so it is rejected here instead with
  # wording the model can act on, before the helper is ever started.
  defp do_call("set_audio_output", %{"device" => device}) do
    case String.trim(device) do
      "" ->
        {:error,
         "\"device\" cannot be blank. Call get_audio_outputs first and pass one of the exact " <>
           "names it returns."}

      _ ->
        do_set_audio_output(device)
    end
  end

  defp do_call(name, _params), do: {:error, "Unknown tool: #{name}"}

  defp ax_client, do: Application.get_env(:seshat, :ax_client, Seshat.AX.Client)

  defp do_set_audio_output(device) do
    case ax_client().set_output(device) do
      # `previous` and `current` are both values the helper *observed* on Live's
      # own control — the reply never echoes the requested name as though it were
      # the result.
      {:ok, %{previous: previous, current: current}} when previous == current ->
        {:ok,
         "Ableton Live's audio output was already \"#{current}\" — nothing changed." <>
           use_system_hint(current)}

      {:ok, %{previous: previous, current: current}} ->
        # Never both: the hint's own wording doesn't say which value it is
        # about, so appending it twice (previous and current both starting
        # "Use System:", e.g. macOS's resolved default changing between reads)
        # read as though Live had returned the same note about two different
        # things (round-2 PR review, 2026-08-27). `current` wins when both
        # qualify, since it's what the caller now has to act on.
        hint =
          if String.starts_with?(current, "Use System:") do
            use_system_hint(current)
          else
            use_system_hint(previous)
          end

        {:ok,
         "Ableton Live's audio output is now \"#{current}\" (it was \"#{previous}\"). " <>
           "Live confirmed the new value itself." <> hint}

      {:error, failure} ->
        {:error, audio_error(failure)}
    end
  end

  defp format_audio_outputs(current, []) do
    "Ableton Live's audio output is \"#{current}\", and it lists no other choices." <>
      use_system_hint(current)
  end

  defp format_audio_outputs(current, devices) do
    "Ableton Live's audio output is \"#{current}\". Available choices, exactly as Live " <>
      "spells them: " <>
      Enum.map_join(devices, ", ", &"\"#{&1}\"") <>
      "." <>
      use_system_hint(current)
  end

  # `current`/`previous` are read straight off Live's own popup
  # (`ValueReflects` in native/seshat_ax/main.m), and for every choice but one
  # that is also the exact name `set_audio_output` matches against. "Use
  # System Device" is the exception: Live resolves it and displays it as
  # "Use System: <the macOS device>", a string that appears in no chooser
  # title. Reported plainly, a caller that remembers this value — to restore
  # it later, say — and sends it straight back gets `device_not_found` after a
  # wasted round trip; this note closes that the first time the value is seen,
  # rather than relying on the recovery path to explain it after the fact.
  defp use_system_hint(value) do
    if String.starts_with?(value, "Use System:") do
      " (That is Live's own resolved description of \"Use System Device\" — send " <>
        "\"Use System Device\" itself, not this string, to select or restore it.)"
    else
      ""
    end
  end

  # Native codes are already rendered as prose by `Seshat.AX.Client`; what is
  # added here is the recovery path, which is a tool-surface question rather than
  # a helper one. A rejected device name is the case worth spending words on: the
  # names are machine-specific, so the model cannot guess a second time, and the
  # helper already collected the real ones on its way to failing.
  defp audio_error(%{code: :device_not_found, message: message, devices: devices})
       when is_list(devices) and devices != [] do
    message <>
      " Choose one of these exact names instead: " <>
      Enum.map_join(devices, ", ", &"\"#{&1}\"") <> "."
  end

  defp audio_error(%{message: message}), do: message

  # An explicit refresh that never completes is caught here rather than left to
  # `serve_session_state/0`'s own catch, which reports a mirror that didn't
  # answer. Both are honest errors now, but they are different errors: this one
  # knows the caller asked Ableton for fresh values and never got them, so it
  # names Ableton and AbletonOSC. The caller passed refresh: true because the
  # mirror looked wrong; that is the fault worth reporting.
  defp maybe_refresh(params) do
    if Map.get(params, "refresh", false), do: State.refresh_sync(), else: :ok
  catch
    :exit, _ ->
      {:error,
       "Refreshing from Ableton timed out. Check that Ableton is running with " <>
         "AbletonOSC enabled."}
  end

  # Reads the four mirrored values and hands them to the pure formatter. The exit
  # catch is a *mirror* that didn't answer — realistically it is mid-refresh
  # against an unresponsive Ableton, since `do_refresh/1` blocks the GenServer
  # for the length of every guard timeout it hits. Reporting that as an empty
  # session (which this used to do) is the same fabrication as a guessed tempo,
  # just wearing a different coat: the caller has no way to tell "I couldn't ask"
  # from "there is nothing there".
  #
  # One `snapshot/0` call rather than four narrower ones: refreshes are coalesced
  # now, so a refresh can land *between* two reads of the same reply and produce
  # a session line combining song-before with tracks-after. One GenServer turn
  # can't straddle a refresh, and it faces one five-second timeout instead of
  # four. It still waits behind a refresh that has already started — against a
  # genuinely unresponsive Ableton the error below is more honest than quietly
  # serving a stale copy, and `refresh: true` is there for a caller that needs an
  # authoritative rebuild.
  # The snapshot's `refresh_pending?` rides through to the formatter rather than
  # being acted on here: a scheduled rebuild is a fact about the reply, not a
  # reason to block one. `refresh: true` above cancels the timer before rebuilding,
  # so an explicitly refreshed read never carries the settling sentence — it is a
  # marker for the ordinary read, which is the one that had no way to know.
  defp serve_session_state do
    %{
      song: song,
      tracks: tracks,
      return_tracks: return_tracks,
      master: master,
      refresh_pending?: refresh_pending?
    } = State.snapshot()

    {:ok, format_session_state(song, tracks, return_tracks, master, refresh_pending?)}
  catch
    :exit, _ ->
      {:error,
       "The session mirror did not answer — it may be mid-refresh against an unresponsive " <>
         "Ableton. Do not retry automatically; tell the user that session verification was " <>
         "unavailable and check Ableton is running with AbletonOSC enabled."}
  end

  defp to_track_type("midi"), do: :midi
  defp to_track_type("audio"), do: :audio

  # The clip grid as structured data — shared by `get_clip_slots` (which then
  # reads scene names and formats) and `capture_midi` (which takes two of these
  # and diffs them). Scene *names* deliberately stay out: the capture diff needs
  # occupancy only, so folding them in here would spend a round trip per snapshot
  # — and `capture_midi` takes two — for strings nobody reads. (They used to cost
  # one query *per scene*, which is what this comment was originally weighing;
  # `query_scene_names/2` is one bulk reply now, so the argument is smaller but
  # still holds.)
  #
  # An empty session answers `{:ok, %{num_scenes: 0, tracks: []}}` rather than
  # an error — capture on an empty set is a legitimate nothing-appeared, not a
  # failure to read.
  #
  # Raw `Transport.query/3`, not `query_correlated/4`: both counts are index-free
  # song properties, so there is nothing in either reply to echo and nothing to
  # verify. A straggler on one of these addresses is a count from moments earlier,
  # which `parse_track_data/3` then length-checks against the data it read.
  defp snapshot_grid do
    with {:ok, {_addr, [num_tracks]}} <- Transport.query("/live/song/get/num_tracks", []),
         {:ok, {_addr, [num_scenes]}} <- Transport.query("/live/song/get/num_scenes", []) do
      snapshot_tracks(num_tracks, num_scenes)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp snapshot_tracks(num_tracks, num_scenes) when num_tracks < 1 or num_scenes < 1 do
    {:ok, %{num_scenes: 0, tracks: []}}
  end

  defp snapshot_tracks(num_tracks, num_scenes) do
    with {:ok, values} <- query_track_data(num_tracks, num_scenes),
         {:ok, tracks} <- parse_track_data(values, num_scenes, num_tracks) do
      {:ok, %{num_scenes: num_scenes, tracks: tracks}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # --- Follow cam helpers ---
  #
  # The decision of *where* to steer is pure and lives in `Seshat.Tools.FollowCam`.
  # What's left here is gathering the one fact a delete needs — how many of that
  # kind of object are left — and the optional clip name.

  # This query still races the delete's own side effects, even though the
  # clause's `State.refresh()` cast is now a debounced timer at least a second
  # out rather than an inline query: the delete itself makes `song_structure.py`
  # push `/live/song/get/tracks`, which `Session.State` records as a pending
  # reconciliation and schedules for its own coalesced rebuild — a rebuild that
  # can still land before this query's reply and race it on the same address
  # (Transport serializes queries but still correlates replies by address
  # alone, so a straggler from an abandoned query can answer the next one on
  # that address). If that race is lost, this call reports `:error` (see
  # `remaining_count/1`) and steering is simply skipped for that delete — never
  # a crash or a wrong index. The steering sends themselves are fire-and-forget
  # and race nothing.
  defp steer_after_delete(tool, facts, count_address) do
    case remaining_count(count_address) do
      {:ok, remaining} -> FollowCam.steer(tool, Map.put(facts, :remaining, remaining))
      :error -> :ok
    end
  end

  # Deliberately total: every failure — timeout, missing extension, a reply shape
  # we don't recognise — means "don't steer", never "fail the tool".
  #
  # Raw `Transport.query/3`: these are index-free count addresses, so the reply
  # echoes nothing and `query_correlated/4` would have nothing to verify. The
  # race this loses is documented above `steer_after_delete/3`, and losing it
  # costs a skipped steer, not a wrong index.
  defp remaining_count(address) do
    case Transport.query(address, [], @follow_cam_count_timeout) do
      {:ok, {_addr, [count]}} when is_integer(count) -> {:ok, count}
      _other -> :error
    end
  catch
    :exit, _ -> :error
  end

  # `-1` appends, so the new scene is the last one; any other index is where it
  # was inserted.
  defp created_scene_index(-1) do
    with {:ok, count} when count > 0 <- remaining_count("/live/song/get/num_scenes") do
      {:ok, count - 1}
    else
      _other -> :error
    end
  end

  defp created_scene_index(index), do: {:ok, index}

  defp maybe_name_clip(_track, _slot, nil), do: :ok

  # Fire-and-forget, like `set_clip_properties`' own name send — but this runs *after* a
  # mutation (write_midi_notes, capture_midi) that already succeeded, inside a
  # function whose own `catch :exit` assumes nothing past that point can still
  # exit. Left uncaught, a dead/restarting Transport here would surface as the
  # enclosing tool's timeout message, denying a write or capture that actually
  # landed. Catch and log instead: worst case the clip keeps its default name.
  defp maybe_name_clip(track, slot, name) do
    case Transport.send_message("/live/clip/set/name", [track, slot, name]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "maybe_name_clip: /live/clip/set/name failed for track #{track}, slot #{slot}: " <>
            inspect(reason)
        )

        :ok
    end
  catch
    :exit, _ ->
      Logger.debug(
        "maybe_name_clip: transport unavailable, skipped naming clip at track #{track}, slot #{slot}"
      )

      :ok
  end

  defp clip_name_note(nil), do: ""
  defp clip_name_note(name), do: ~s{, named "#{name}"}

  defp loaded_device_note(-1), do: " (still instantiating, so it has no device index yet)"
  defp loaded_device_note(device), do: " (device #{device})"

  # --- capture_midi ---

  # Raw `Transport.query/3`: tempo is an index-free song property, so its reply
  # echoes nothing for `query_correlated/4` to check. It is also one of the
  # addresses `Session.State` listens on, so a listener push can satisfy this
  # query — Transport's residual class 2, which no correlation on this wire can
  # remove. A tempo from moments earlier is what `capture_midi` is comparing
  # against anyway.
  defp query_tempo do
    case Transport.query("/live/song/get/tempo", []) do
      {:ok, {_addr, [tempo]}} when is_number(tempo) ->
        {:ok, tempo}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from /live/song/get/tempo: #{inspect(args)}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  # Everything from here on runs *after* the capture message is on the wire, so
  # no failure text may imply nothing happened — the `set_device_parameter`
  # precedent. AbletonOSC processes datagrams in arrival order and
  # `song.capture_midi()` runs synchronously inside its callback, so the tempo
  # query sent afterwards reads the post-capture value.
  defp fire_capture(tempo_before, before_grid, name) do
    with :ok <- Transport.send_message("/live/song/capture_midi", []),
         {:ok, tempo_after} <- query_tempo(),
         {:ok, after_grid} <- snapshot_grid() do
      report_capture(before_grid, after_grid, tempo_before, tempo_after, name)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Capture was sent but reading the session back timed out — check the result with " <>
         "get_clip_slots."}
  end

  defp report_capture(before_grid, after_grid, tempo_before, tempo_after, name) do
    case capture_diff(before_grid, after_grid) do
      {[], _scenes_added} ->
        retry_capture_diff(before_grid, tempo_before, tempo_after, name)

      {clips, scenes_added} ->
        captured_success(clips, scenes_added, tempo_before, tempo_after, name)
    end
  end

  # ⚠️ Unconfirmed whether Live has inserted the clip by the time the LOM call
  # returns — it may defer the insertion to a later UI tick. One bounded re-read
  # covers that case without turning a genuine nothing-captured into a stall.
  defp retry_capture_diff(before_grid, tempo_before, tempo_after, name) do
    Process.sleep(@capture_retry_delay)

    with {:ok, after_grid} <- snapshot_grid() do
      case capture_diff(before_grid, after_grid) do
        {[], _scenes_added} ->
          {:error, nothing_captured_reply(tempo_before, tempo_after)}

        {clips, scenes_added} ->
          captured_success(clips, scenes_added, tempo_before, tempo_after, name)
      end
    end
  end

  # One capture is one take, so a multi-track capture gets the same name on every
  # clip it produced. The name is substituted into the clip maps rather than
  # re-read: the after-snapshot predates the rename, so re-reading would cost a
  # round trip for a string we just wrote — the same trust `set_clip_properties`
  # extends to its own fire-and-forget send.
  defp captured_success(clips, scenes_added, tempo_before, tempo_after, name) do
    clips = Enum.map(clips, &name_captured_clip(&1, name))
    steer_to_captured(clips)

    {:ok, captured_reply(clips, scenes_added, tempo_before, tempo_after)}
  end

  @doc """
  Applies `capture_midi`'s optional model-supplied `name` to one captured clip.

  Fires the rename (`maybe_name_clip/3`, itself exit-safe) and, independently
  of whether that send lands, substitutes the name into the returned map so
  `captured_reply/4` prints what was asked for rather than the `""` Live gave
  the clip by default.
  """
  @spec name_captured_clip(map(), String.t() | nil) :: map()
  def name_captured_clip(clip, nil), do: clip

  def name_captured_clip(%{track_index: track, slot_index: slot} = new_clip, name) do
    maybe_name_clip(track, slot, name)
    %{new_clip | clip: %{new_clip.clip | name: name}}
  end

  @doc """
  Which of `capture_midi`'s new clips gets the follow cam.

  Several new clips means one take spread across tracks; `clips` is already in
  track-then-slot order (`capture_diff/2`'s own ordering), so the first entry
  is the one to show. `nil` when nothing was captured.
  """
  @spec captured_steer_target([map()]) ::
          %{track: non_neg_integer(), slot: non_neg_integer()} | nil
  def captured_steer_target([%{track_index: track, slot_index: slot} | _rest]),
    do: %{track: track, slot: slot}

  def captured_steer_target([]), do: nil

  defp steer_to_captured(clips) do
    case captured_steer_target(clips) do
      nil -> :ok
      facts -> FollowCam.steer("capture_midi", facts)
    end
  end

  # Every scene name in one reply, sent with no arguments — the fork's
  # `song_get_scene_names` reads that as the full range `0..len(song.scenes)`,
  # in index order, so the docs' `-1` trap (an empty reply that looks like a set
  # with no scenes) is unreachable from here.
  #
  # This reply carries **names only — the range is not echoed back**
  # (priv/AbletonOSC/API.md), so it cannot ride `query_correlated/4`: there
  # is no prefix to verify. The length check against the `num_scenes` the caller
  # just read stands in for it, with the same reissue-once defence. That is
  # weaker than an echo but not weaker than the per-scene loop this replaces: an
  # echoed index cannot see a rename either, so a same-length straggler would
  # have passed N echo checks too — at N serialized round trips instead of one.
  #
  # A second disagreement is reported rather than retried further. If the scene
  # count genuinely changed mid-read, the `track_data` half of the grid snapshot
  # is stale as well, and re-reading the whole grid is the only correct advice.
  #
  # `num_scenes >= 1` is guaranteed by the caller: `snapshot_tracks/2` answers
  # the empty grid without ever reaching here.
  defp query_scene_names(num_scenes, reissued? \\ false) do
    case Transport.query("/live/song/get/scenes/name", []) do
      {:ok, {_addr, names}} when length(names) == num_scenes ->
        {:ok, names}

      {:ok, {_addr, _mismatched}} ->
        if reissued? do
          {:error,
           "Ableton's reply with the scene names did not carry #{num_scenes} names, twice in a " <>
             "row — either the scene list changed while the grid was being read, or the reply " <>
             "belongs to an earlier query that timed out. Nothing was changed; read the grid " <>
             "again with get_clip_slots."}
        else
          query_scene_names(num_scenes, true)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # end_track is exclusive; explicit bounds per batch (never -1) because
  # parsing needs the count anyway.
  #
  # Raw `Transport.query/3`: `/live/song/get/track_data` replies with values
  # only — it echoes neither the range nor the property list — so there is no
  # prefix for `query_correlated/4` to verify. `parse_track_data/3` length-checks
  # what came back against the batch it asked for, and `ensure_midi_track/1`
  # refuses to use this address at all for exactly the missing-echo reason.
  defp query_track_data(num_tracks, num_scenes) do
    per_track = 3 + 5 * num_scenes
    batch_size = max(1, div(@track_data_target_values, per_track))

    result =
      0..(num_tracks - 1)
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
        start_track = List.first(batch)
        end_track = List.last(batch) + 1
        args = [start_track, end_track | @track_data_properties]

        case Transport.query("/live/song/get/track_data", args) do
          {:ok, {_addr, values}} -> {:cont, {:ok, [values | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, batches} <- result do
      {:ok, batches |> Enum.reverse() |> Enum.concat()}
    end
  end

  # --- Session recording helpers ---

  defp ensure_bars(nil), do: :ok
  defp ensure_bars(bars) when is_number(bars) and bars > 0, do: :ok

  defp ensure_bars(bars) do
    {:error,
     "bars must be a positive number of bars (got #{inspect(bars)}), so nothing was " <>
       "recorded. Omit it for a take that runs until stop_recording."}
  end

  # The `nil` short-circuit stays here as well as inside `record_length_from/2`:
  # an open-ended take has no reason to need the mirror at all, and routing it
  # through `State.song()` would make a GenServer that is mid-refresh able to
  # fail a `record_clip` call that asks nothing of it.
  defp record_length(nil), do: {:ok, nil}
  defp record_length(bars), do: record_length_from(bars, State.song())

  # A third OSC argument is `ClipSlot.fire()`'s first optional positional one,
  # `record_length` — AbletonOSC's clip_slot handler forwards everything past the
  # two indices verbatim. Omitting it is what makes the take open-ended.
  defp fire_for_record(track, slot, nil) do
    Transport.send_message("/live/clip_slot/fire", [track, slot])
  end

  defp fire_for_record(track, slot, beats) do
    Transport.send_message("/live/clip_slot/fire", [track, slot, beats])
  end

  # The inverse of `ensure_clip/3`, and the reason `record_clip` is not just
  # `fire_clip` with a length: firing an *occupied* slot launches that clip
  # rather than recording anything, and says nothing about it.
  defp ensure_slot_empty(track, slot) do
    case query_flag(
           "/live/clip_slot/get/has_clip",
           [track, slot],
           "whether slot #{slot} on track #{track} holds a clip"
         ) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        {:error,
         "Slot #{slot} on track #{track} already holds a clip, so nothing was recorded — " <>
           "firing it would have launched that clip instead. Record into an empty slot " <>
           "(get_clip_slots shows which are free), or delete_clip this one first if the " <>
           "take is meant to replace it."}

      {:error, message} ->
        {:error, message}
    end
  end

  # Returns whether *this call* armed the track — `false` for one that was armed
  # already — so the reply can disclose an arm the user didn't ask for. A track
  # that is already armed skips the `can_be_armed` read: it self-evidently could.
  defp ensure_armed(track) do
    case query_flag("/live/track/get/arm", [track], "whether track #{track} is armed") do
      {:ok, true} -> {:ok, false}
      {:ok, false} -> arm_track(track)
      {:error, message} -> {:error, message}
    end
  end

  # `/live/track/set/arm` is silent, so the re-read is the whole guard: without
  # it a track Live refused to arm would go on to a fire that records nothing and
  # a reply claiming a take is running.
  defp arm_track(track) do
    case query_flag(
           "/live/track/get/can_be_armed",
           [track],
           "whether track #{track} can be armed"
         ) do
      {:ok, false} ->
        {:error,
         "Track #{track} can't be armed for recording, so nothing was recorded. Group tracks " <>
           "have no clip slots of their own — record into one of the tracks inside the " <>
           "group; get_clip_slots labels group tracks 'group'."}

      {:ok, true} ->
        with :ok <- Transport.send_message("/live/track/set/arm", [track, 1]),
             {:ok, armed?} <-
               query_flag("/live/track/get/arm", [track], "whether track #{track} is armed") do
          if armed? do
            {:ok, true}
          else
            {:error,
             "Asked Ableton to arm track #{track} but it still reads as disarmed, so nothing " <>
               "was recorded. Arm it by hand in Live — the round button in the track's mixer " <>
               "row — and try again."}
          end
        end

      {:error, message} ->
        {:error, message}
    end
  end

  # Advisory, not a precondition — and it used to be the latter, which made
  # `record_clip` refuse every call it was ever asked to make.
  #
  # `will_record_on_start` reads as the answer to "would firing this slot
  # record?" and is not. Measured 2026-08-03 on Live 12.4.3: on an armed MIDI
  # track with an empty slot it returns `False` while `/live/clip_slot/fire` on
  # that exact track and slot starts recording immediately. It stayed `False`
  # across every state worth trying — transport stopped and playing,
  # `session_record` off and on, MIDI track with an instrument, bare MIDI track
  # and audio track — with `arm`, `can_be_armed` and `has_midi_input` all true
  # and monitoring on Auto. Whatever it answers, it is not this question, and no
  # substitute precondition turned up, so nothing is gated on it any more.
  #
  # The reading is still worth surfacing, because the case it was meant to catch
  # is real: an audio track with no input routed records silence. That is a
  # recoverable, self-evident outcome, so it belongs in the reply rather than in
  # a refusal. The fire's own confirmation (`record_echo/2`) remains the thing
  # that decides whether the take actually started.
  defp check_will_record(track, slot) do
    case query_flag(
           "/live/clip_slot/get/will_record_on_start",
           [track, slot],
           "whether firing slot #{slot} on track #{track} would record"
         ) do
      {:ok, true} ->
        {:ok, nil}

      {:ok, false} ->
        {:ok,
         "Live reported this slot might not capture input. That reading is unreliable, so the " <>
           "take was fired anyway — if it comes back silent, check the track's input routing " <>
           "and monitoring in Live."}

      # A failed *read* still blocks, unchanged: it means Ableton isn't
      # answering, which the fire is about to discover more expensively.
      {:error, message} ->
        {:error, message}
    end
  end

  defp ensure_recording(track, slot) do
    case query_flag(
           "/live/clip/get/is_recording",
           [track, slot],
           "whether the clip in slot #{slot} on track #{track} is recording"
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         "Nothing is recording in slot #{slot} on track #{track}, so nothing was fired — " <>
           "get_clip_slots marks the slot that is. Use stop_clip to stop a clip that is " <>
           "merely playing."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp report_record_started(track, slot, bars, beats, just_armed?, input_doubt) do
    case record_echo(track, slot) do
      {:ok, status} ->
        FollowCam.steer("record_clip", %{track: track, slot: slot})
        {:ok, record_reply(track, slot, bars, beats, just_armed?, status, input_doubt)}

      {:error, message} ->
        # `record_echo/2` shares its guard helpers with the pre-fire checks, so
        # its errors still carry their "nothing was sent" framing — false here,
        # since the fire already went out. Rewrap rather than return verbatim.
        {:error,
         "The take was fired on track #{track}, slot #{slot}, but confirming it failed: " <>
           "#{message} That doesn't mean nothing is recording — check with get_clip_slots, " <>
           "and stop_recording track #{track} slot #{slot} if it turns out to be running."}
    end
  end

  # The fire is silent, so the session itself is the only honest signal that the
  # take started. `has_clip` first: once Live has made the clip, `is_recording`
  # is definitive. Before that — a fire with the transport already playing waits
  # for the launch-quantization boundary — the evidence is slot-level
  # `is_triggered`. Deliberately no `playing_status`: its enum is documented
  # nowhere. Live handles datagrams in arrival order, so all three reads see a
  # session in which the fire has already been processed.
  defp record_echo(track, slot, reread? \\ false) do
    case query_flag(
           "/live/clip_slot/get/has_clip",
           [track, slot],
           "whether slot #{slot} on track #{track} holds a clip"
         ) do
      {:ok, true} ->
        recording_or_queued(track, slot)

      # Measured 2026-08-03, Live 12.4.3: the clip does not exist the instant the
      # fire is processed. Polling straight after `/live/clip_slot/fire` with
      # launch quantization set to None, `has_clip` read `False` on the first
      # query and `True` 99ms later, with `is_recording` already true by then.
      # Datagram ordering (which the comment above relies on) is preserved; what
      # it does not buy is the engine state the fire *triggers*, which lands
      # asynchronously. Without this re-read, a take that started immediately
      # reports "Queued" — the whole point of the echo, inverted.
      #
      # One re-read is enough because the round trip is itself ~100ms. A take
      # genuinely waiting for a boundary has no clip for up to a bar, so it still
      # reads `false` twice and is still correctly reported as queued.
      {:ok, false} when not reread? ->
        record_echo(track, slot, true)

      {:ok, false} ->
        queued_or_nothing(track, slot)

      {:error, message} ->
        {:error, message}
    end
  end

  defp recording_or_queued(track, slot) do
    case query_flag(
           "/live/clip/get/is_recording",
           [track, slot],
           "whether the clip in slot #{slot} on track #{track} is recording"
         ) do
      {:ok, true} -> {:ok, :recording}
      {:ok, false} -> queued_or_nothing(track, slot)
      {:error, message} -> {:error, message}
    end
  end

  defp queued_or_nothing(track, slot) do
    case query_flag(
           "/live/clip_slot/get/is_triggered",
           [track, slot],
           "whether slot #{slot} on track #{track} is waiting to start"
         ) do
      {:ok, true} ->
        {:ok, :queued}

      {:ok, false} ->
        {:error,
         "Fired slot #{slot} on track #{track} but Live reports nothing recording or waiting " <>
           "to start there, so the take did not begin. Live had just answered that firing " <>
           "this slot would record, so something changed underneath — most likely the slot " <>
           "or the track's arm was touched by hand in Live between the two. Check with " <>
           "get_clip_slots and call record_clip again."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp record_reply(track, slot, bars, beats, just_armed?, status, input_doubt) do
    [
      record_headline(track, slot, bars, beats),
      record_status_line(status),
      if(just_armed?, do: "Armed the track first."),
      input_doubt
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp record_headline(track, slot, nil, _beats) do
    "Recording into track #{track}, slot #{slot} until stop_recording."
  end

  defp record_headline(track, slot, bars, beats) do
    "Recording #{format_number(bars)} bars (#{format_number(beats)} beats) into track " <>
      "#{track}, slot #{slot} — Live stops the take itself and leaves the clip looping."
  end

  defp record_status_line(:recording), do: "Recording now."

  defp record_status_line(:queued) do
    "Queued: it starts at the next launch-quantization boundary, usually the next bar."
  end

  # --- Return tracks & master reads ---

  # Doubles as the "is return_track.py installed?" probe — the whole extension
  # either answers or it doesn't, so one timeout is enough to say which.
  #
  # Raw `Transport.query/3`, like the two index-less master getters below: with
  # no index to look up there is nothing to echo, and no envelope either (the
  # vendored-getter rule's stated exception), so `query_correlated/4` would have
  # no prefix to verify.
  defp return_track_count do
    case Transport.query("/live/return_track/get/count", [], @guard_timeout) do
      {:ok, {_addr, [count]}} when is_integer(count) ->
        {:ok, count}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from /live/return_track/get/count: #{inspect(args)}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ -> {:error, extension_missing_error("read the return tracks", "no sends were read")}
  end

  defp master_volume do
    case Transport.query("/live/master/get/volume", [], @guard_timeout) do
      {:ok, {_addr, [volume]}} when is_number(volume) ->
        {:ok, volume}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from /live/master/get/volume: #{inspect(args)}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error, extension_missing_error("read the master volume", "that property was not changed")}
  end

  # The index-less master getters reply with a bare value and no envelope, so
  # neither `query_echoed/4` nor `query_correlated/4` fits them — there is no
  # echoed prefix to strip or verify. This is `master_volume/0`'s shape
  # generalized over the address. A timeout is a missing install, exactly as
  # there.
  defp master_bare_float(address, subject) do
    case Transport.query(address, [], @guard_timeout) do
      {:ok, {_addr, [value]}} when is_number(value) ->
        {:ok, value}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from #{address}: #{inspect(args)}"}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error, extension_missing_error("read #{subject}", "that property was not changed")}
  end

  defp extension_missing_error(attempted, consequence) do
    "Timed out trying to #{attempted}, so #{consequence}. Those addresses come from Seshat's " <>
      "AbletonOSC extension rather than upstream, so run `mix abletonosc.install` and restart " <>
      "Ableton Live — and check Live is running with AbletonOSC enabled."
  end

  # A reply in a shape this code can't read, on one of Seshat's own addresses.
  # An older installed copy of the fork is the realistic cause, so the hint says
  # so rather than blaming the index.
  defp unexpected_chain_reply(target, args) do
    "Unexpected reply from Live when loading onto #{target}: #{inspect(args)}. The installed " <>
      "copy of Seshat's AbletonOSC extension may predate this address — run " <>
      "`mix abletonosc.install` and restart Ableton Live."
  end

  @doc """
  Decides what a device-load reply means, before anything acts on it.

  `asked` is what this call sent — `[track_or_return_index, uri]` or `[uri]` —
  and the reply echoes it back in front of the payload. `Seshat.OSC.Transport`
  correlates replies by address alone, so a load abandoned by an earlier timeout
  can still answer the next load on the same address: the echo is the only thing
  that distinguishes this call's reply from that straggler's.

  Getting that wrong is worse here than on a getter. A stale *success* would make
  the tool record the wrong URI as loaded, steer the view using a device index
  from a different chain, and tell the user a device landed somewhere it did not
  — all while the load actually asked for may still be in flight.

  Hence `:stale` rather than the reissue `query_correlated/4` performs on a
  mismatched getter: a load is a mutation, and reissuing one could load a second
  device. There is nothing safe to do but report the outcome as unknown — which
  is also why this verifies by hand rather than riding the shared decode, along
  with the uri echo and the envelope arms it has to keep apart.
  """
  @spec load_outcome(list(), list()) ::
          {:loaded, list()} | {:remote_error, String.t()} | :stale | :unexpected
  def load_outcome(reply_args, asked) do
    {echoed, payload} = Enum.split(reply_args, length(asked))

    cond do
      length(echoed) < length(asked) -> :unexpected
      not indices_match?(echoed, asked) -> :stale
      true -> load_payload(payload)
    end
  end

  defp load_payload(["ok" | rest]), do: {:loaded, rest}
  defp load_payload(["error", message]) when is_binary(message), do: {:remote_error, message}
  defp load_payload(_other), do: :unexpected

  # Deliberately does not tell the user to just try again: the load this reply
  # belongs to may have landed, and a blind retry is how one device becomes two.
  defp stale_load_error(target, uri) do
    "Ableton's reply when loading '#{uri}' onto #{target} was about a different load — it " <>
      "belongs to an earlier request that timed out. Nothing further was sent, and whether " <>
      "anything was loaded is unknown: check with get_track_devices before retrying, since " <>
      "retrying blind could load a second copy."
  end

  # With no returns there are no sends to read, but the track index still gets
  # checked: otherwise a typo'd track comes back as "this set has no return
  # tracks" — true, and not the question that was asked.
  defp read_sends(track, count) when count < 1 do
    with {:ok, _name} <-
           query_echoed("/live/track/get/name", [track], "track #{track}", @track_index_hint) do
      {:ok, []}
    end
  end

  # One tick, not 1 + 2N of them. Each return contributes two entries — its own
  # name and this track's send into it — and `Transport.query_batch/2` tells the
  # replies apart by the index each echoes, which is exactly what lets two reads
  # per return share one burst. At Live's 12-return cap that is 25 entries and
  # one ~100ms tick, against the ~2.5s the serialized loop cost.
  #
  # It also supersedes the freshness-gated mirror read this comment used to
  # sketch (PR #62 review, 2026-08-03). Reusing `Session.State`'s return names
  # would now save nothing — the names arrive in the same tick as the levels —
  # while still owing the staleness ceremony that review demanded, since the
  # debounced mirror can lag a return delete or reorder by ~1s and would label a
  # send with the return that *used to* hold that index.
  #
  # The track-name entry is the index guard, riding the same tick rather than
  # being implied by whichever send read happened to fail first.
  defp read_sends(track, count) do
    entries =
      [{"/live/track/get/name", [track]}] ++
        Enum.flat_map(0..(count - 1), fn index ->
          [
            {"/live/return_track/get/name", [index]},
            {"/live/track/get/send", [track, index]}
          ]
        end)

    case Transport.query_batch(entries, @guard_timeout) do
      {:ok, [track_name | pairs]} ->
        with {:ok, _name} <- decode_entry(track_name, "track #{track}") do
          collect_sends(track, pairs)
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  rescue
    # `entries` is `2 * count + 1`, and `Transport.query_batch/2` raises
    # `ArgumentError` — synchronously, before anything reaches the wire — past
    # its entry cap. Live 12 caps return tracks at 12 (25 entries), so this
    # should never trigger through the UI; it exists so a count this code
    # doesn't otherwise bound turns into a sentence rather than an uncaught
    # crash out of a tool handler.
    e in ArgumentError ->
      {:error,
       "Track #{track} has #{count} return tracks, too many to read sends for in a single " <>
         "batch (#{Exception.message(e)}). That's far beyond Live's own return-track limit, so " <>
         "this shouldn't happen — treat it as a bug if it does."}
  catch
    # One deadline over the whole burst. The hint names both indices because the
    # burst reads both, and the extension hint isn't the right diagnosis here:
    # `return_track_count/0` has already proved the extension answers.
    :exit, _ ->
      {:error, guard_timeout_error("the sends on track #{track}", @send_index_hint)}
  end

  # The batch's tail comes back as name/level pairs in return order — the order
  # they were queued in — so re-pairing them is a chunk rather than a lookup.
  # Stops at the first entry Live refused, as the per-return loop did.
  defp collect_sends(track, pairs) do
    collected =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {[name_result, value_result], index}, {:ok, acc} ->
        with {:ok, name} <- decode_entry(name_result, "the name of return track #{index}"),
             {:ok, value} <- decode_entry(value_result, "send #{index} on track #{track}") do
          {:cont, {:ok, [%{index: index, return: name, value: value} | acc]}}
        else
          {:error, message} -> {:halt, {:error, message}}
        end
      end)

    with {:ok, sends} <- collected, do: {:ok, Enum.reverse(sends)}
  end

  # The post-set read of a send level, and the three things it can say. The
  # comparison rounds to 4 decimals because OSC's `f` is 32-bit and Elixir's
  # floats are not: `0.37` goes out and comes back as `0.3700000047683716`, so
  # `==` would report every non-representable value as a mismatch. Same
  # precision, same reason as `clip_value_matches?/3`, and the same as
  # `format_number/1` prints at — so the numbers in the reply are the numbers
  # that were compared.
  defp confirm_send(track, send_index, value, old, subject) do
    case read_back_value("/live/track/get/send", [track, send_index]) do
      {:ok, got} when is_number(got) ->
        if Float.round(value / 1.0, 4) == Float.round(got / 1.0, 4) do
          {:ok,
           "Set #{subject} to #{value} (was #{format_number(old)}), confirmed by reading it back."}
        else
          {:error,
           "Sent #{subject} the value #{value}, but Live reports #{format_number(got)} " <>
             "(was #{format_number(old)}) — the set did not land. Try once more, and if it " <>
             "still does not land, tell the user."}
        end

      # `:unconfirmed` (stale twice, a timeout, an error), or a reply shaped
      # like nothing this code can compare. Either way the set is already on
      # the wire, so the report is that it wasn't verified — never that nothing
      # was sent.
      _other ->
        {:error,
         "The set was sent but reading #{subject} back did not confirm it — verify with " <>
           "get_track_sends."}
    end
  end

  # --- set_mixer ---

  defp ensure_mixer_changes(changes) when map_size(changes) == 0 do
    {:error,
     "Nothing to set — pass at least one of #{Enum.join(@mixer_properties, ", ")}. Keys the " <>
       "schema does not name are dropped before this point, so if you did send a value, " <>
       "check its spelling against that list. Nothing was sent."}
  end

  defp ensure_mixer_changes(_changes), do: :ok

  defp ensure_mixer_supported(target, changes) do
    case Map.fetch(@mixer_supported, target) do
      {:ok, supported} ->
        unsupported =
          Enum.filter(@mixer_properties, &(Map.has_key?(changes, &1) and &1 not in supported))

        if unsupported == [] do
          :ok
        else
          {:error,
           "#{mixer_subject(target, nil)} has no " <>
             "#{Enum.join(unsupported, " or ")} — it has #{Enum.join(supported, ", ")}. " <>
             "Nothing in this call was sent. Drop #{Enum.join(unsupported, " and ")} and try " <>
             "again."}
        end

      :error ->
        {:error,
         "Unknown target '#{target}' — use 'track', 'return', 'master' or 'cue'. Nothing " <>
           "was sent."}
    end
  end

  defp mixer_index(target, params) when target in @mixer_indexed_targets do
    case Map.get(params, "track") do
      index when is_integer(index) and index >= 0 ->
        {:ok, index}

      index when is_float(index) and index >= 0.0 ->
        {:ok, trunc(index)}

      _missing ->
        {:error,
         "target '#{target}' needs track — the 0-based index of the " <>
           "#{if target == "return", do: "return track (return 0 = send A)", else: "track"}. " <>
           "See get_session_state. Nothing was sent."}
    end
  end

  defp mixer_index(_target, _params), do: {:ok, nil}

  defp ordered_mixer_writes(changes) do
    @mixer_properties
    |> Enum.filter(&Map.has_key?(changes, &1))
    |> Enum.map(&{&1, Map.fetch!(changes, &1)})
  end

  # Applied in order, one result line each, stopping at the first failure — and
  # a stop names what already went out, because on the return/master path the
  # failure is a guard read and the properties before it are already on the
  # wire (`send_clip_writes/3` reports the same way for the same reason).
  defp apply_mixer(target, index, writes) do
    outcome =
      Enum.reduce_while(writes, {:ok, []}, fn {property, value}, {:ok, done} ->
        case mixer_write(target, index, property, value) do
          {:ok, line} ->
            {:cont, {:ok, [{property, line} | done]}}

          {:error, message} ->
            {:halt, {:error, mixer_partial_error(target, index, property, message, done)}}
        end
      end)

    case outcome do
      {:ok, done} ->
        lines = done |> Enum.reverse() |> Enum.map(&elem(&1, 1))
        {:ok, mixer_reply(target, index, Map.new(writes), lines)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp mixer_partial_error(target, index, property, message, []) do
    "Could not set #{property} on #{mixer_subject(target, index)}: #{message} Nothing else " <>
      "in the call was sent."
  end

  defp mixer_partial_error(target, index, property, message, done) do
    already = done |> Enum.reverse() |> Enum.map_join(", ", &elem(&1, 0))

    "Could not set #{property} on #{mixer_subject(target, index)}: #{message} " <>
      "#{already} #{if(length(done) == 1, do: "was", else: "were")} already sent in the same " <>
      "call and may have landed — check with get_session_state."
  end

  defp mixer_reply(target, index, changes, lines) do
    "#{mixer_header(target, index, changes)} #{Enum.join(lines, "; ")}." <> mixer_footer(target)
  end

  defp mixer_footer("cue"),
    do: " This is the browser-preview/headphone level, not the master output."

  defp mixer_footer(_target), do: ""

  # The label is cosmetic, so an unavailable or stale mirror costs nothing — but
  # a rename in this same call wins over the mirrored name, which is by
  # definition the old one.
  defp mixer_header("track", index, changes),
    do: "Track #{index}#{mixer_label(mirrored_track_name(index), changes)}:"

  defp mixer_header("return", index, changes),
    do: "Return #{index}#{mixer_label(mirrored_return_name(index), changes)}:"

  defp mixer_header("master", _index, _changes), do: "Master (shown as Main in Live 12):"
  defp mixer_header("cue", _index, _changes), do: "Cue:"

  defp mixer_label(mirrored, changes) do
    case Map.get(changes, "name", mirrored) do
      name when is_binary(name) and name != "" -> ~s{ ("#{name}")}
      _unknown -> ""
    end
  end

  defp mirrored_track_name(index) do
    case Enum.find(State.tracks() || [], &(&1.index == index)) do
      %{name: name} -> name
      _missing -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp mirrored_return_name(index) do
    case Enum.find(State.return_tracks(), &(&1.index == index)) do
      %{name: name} -> name
      _missing -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp mixer_subject("track", index) when is_integer(index), do: "Track #{index}"
  defp mixer_subject("track", _index), do: "A regular track"
  defp mixer_subject("return", index) when is_integer(index), do: "Return track #{index}"
  defp mixer_subject("return", _index), do: "A return track"
  defp mixer_subject("master", _index), do: "The master"
  defp mixer_subject("cue", _index), do: "The cue output"
  defp mixer_subject(target, _index), do: "Target '#{target}'"

  # Regular tracks: fire-and-forget, exactly as the six tools this replaces
  # were. Every value here has a listener pushing Live's accepted value back
  # into `Session.State`, so a refused or lost set is corrected within a beat
  # and `get_session_state` is the read.
  defp mixer_write("track", index, "volume", value) do
    send_mixer(
      "/live/track/set/volume",
      [index, value / 1.0],
      "volume #{format_number(value)} (#{volume_display(value)})"
    )
  end

  defp mixer_write("track", index, "pan", value) do
    send_mixer(
      "/live/track/set/panning",
      [index, value / 1.0],
      "pan #{format_number(value)} (#{pan_display(value)})"
    )
  end

  defp mixer_write("track", index, "mute", value) do
    send_mixer(
      "/live/track/set/mute",
      [index, if(truthy?(value), do: 1, else: 0)],
      if(truthy?(value), do: "muted", else: "unmuted")
    )
  end

  defp mixer_write("track", index, "solo", value) do
    send_mixer(
      "/live/track/set/solo",
      [index, if(truthy?(value), do: 1, else: 0)],
      if(truthy?(value), do: "soloed", else: "unsoloed")
    )
  end

  defp mixer_write("track", index, "arm", value) do
    send_mixer(
      "/live/track/set/arm",
      [index, if(truthy?(value), do: 1, else: 0)],
      if(truthy?(value), do: "armed", else: "disarmed")
    )
  end

  defp mixer_write("track", index, "name", value) do
    send_mixer("/live/track/set/name", [index, value], "renamed to '#{value}'")
  end

  # Returns: guard-read then set, as before. The guard proves the index exists
  # and tells a bad index (an error reply) from an uninstalled extension
  # (silence) apart, and it is where the "was" value comes from.
  defp mixer_write("return", index, "volume", value) do
    with {:ok, old} <-
           query_echoed(
             "/live/return_track/get/volume",
             [index],
             "the volume of return track #{index}",
             @return_extension_hint
           ) do
      send_mixer(
        "/live/return_track/set/volume",
        [index, value / 1.0],
        "volume #{format_number(value)} (#{volume_display(value)}) — was " <>
          "#{format_number(old)} (#{volume_display(old)})"
      )
    end
  end

  defp mixer_write("return", index, "pan", value) do
    with {:ok, old} <-
           query_echoed(
             "/live/return_track/get/panning",
             [index],
             "the pan of return track #{index}",
             @return_extension_hint
           ) do
      send_mixer(
        "/live/return_track/set/panning",
        [index, value / 1.0],
        "pan #{format_number(value)} (#{pan_display(value)}) — was #{format_number(old)} " <>
          "(#{pan_display(old)})"
      )
    end
  end

  defp mixer_write("return", index, "mute", value) do
    with {:ok, old} <-
           query_echoed(
             "/live/return_track/get/mute",
             [index],
             "the mute state of return track #{index}",
             @return_extension_hint
           ) do
      send_mixer(
        "/live/return_track/set/mute",
        [index, if(truthy?(value), do: 1, else: 0)],
        "#{if truthy?(value), do: "muted", else: "unmuted"} — was " <>
          "#{if truthy?(old), do: "muted", else: "unmuted"} (every track's send into it is " <>
          "unchanged)"
      )
    end
  end

  defp mixer_write("return", index, "solo", value) do
    with {:ok, old} <-
           query_echoed(
             "/live/return_track/get/solo",
             [index],
             "the solo state of return track #{index}",
             @return_extension_hint
           ) do
      send_mixer(
        "/live/return_track/set/solo",
        [index, if(truthy?(value), do: 1, else: 0)],
        "#{if truthy?(value), do: "soloed", else: "unsoloed"} — was " <>
          "#{if truthy?(old), do: "soloed", else: "not soloed"}"
      )
    end
  end

  defp mixer_write("return", index, "name", value) do
    with {:ok, old} <-
           query_echoed(
             "/live/return_track/get/name",
             [index],
             "the name of return track #{index}",
             @return_extension_hint
           ) do
      send_mixer(
        "/live/return_track/set/name",
        [index, value],
        "renamed to '#{value}' — was '#{old}'"
      )
    end
  end

  # The master and cue getters take no index, so they carry no envelope to
  # unwrap and no echo to check: `master_volume/0` and `master_bare_float/2`
  # are their shape, and a timeout on either means the extension is missing.
  defp mixer_write("master", _index, "volume", value) do
    with {:ok, old} <- master_volume() do
      send_mixer(
        "/live/master/set/volume",
        [value / 1.0],
        "volume #{format_number(value)} (#{volume_display(value)}) — was " <>
          "#{format_number(old)} (#{volume_display(old)})"
      )
    end
  end

  defp mixer_write("master", _index, "pan", value) do
    with {:ok, old} <- master_bare_float("/live/master/get/panning", "the master pan") do
      send_mixer(
        "/live/master/set/panning",
        [value / 1.0],
        "pan #{format_number(value)} (#{pan_display(value)}) — was #{format_number(old)} " <>
          "(#{pan_display(old)})"
      )
    end
  end

  defp mixer_write("cue", _index, "volume", value) do
    with {:ok, old} <- master_bare_float("/live/master/get/cue_volume", "the cue volume") do
      send_mixer(
        "/live/master/set/cue_volume",
        [value / 1.0],
        "volume #{format_number(value)} (#{volume_display(value)}) — was " <>
          "#{format_number(old)} (#{volume_display(old)})"
      )
    end
  end

  defp send_mixer(address, args, line) do
    case Transport.send_message(address, args) do
      :ok -> {:ok, line}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  defp mixer_property_list(params) do
    case Enum.filter(@mixer_properties, &Map.has_key?(params, &1)) do
      [] -> "the mixer"
      properties -> Enum.join(properties, ", ")
    end
  end

  defp mixer_subject_from(params) do
    Map.get(params, "target", "track")
    |> mixer_subject(Map.get(params, "track"))
    |> String.downcase()
  end

  # Best-effort label from the mirrored state, for a reply that reads better with
  # the return's name in it. Purely cosmetic, so a stale or unavailable mirror
  # costs nothing — and an *unknown* name (`nil`, its read unanswered) drops the
  # label entirely rather than rendering `("")`, which would present the return
  # as being named the empty string.
  defp return_track_label(index) do
    case Enum.find(State.return_tracks(), &(&1.index == index)) do
      %{name: nil} -> ""
      %{name: name} -> ~s{ ("#{name}")}
      _ -> ""
    end
  catch
    :exit, _ -> ""
  end

  # --- Device chain guards ---

  # The pre-delete read: it validates the track index and captures the chain in
  # one query. `query_correlated/4` with the default decode, because the payload
  # behind the echoed track index is a whole list rather than the single value
  # `query_echoed/4`'s `unwrap_payload/1` reads.
  defp read_device_names(track) do
    case query_correlated("/live/track/get/devices/name", [track], timeout: @guard_timeout) do
      {:ok, names} ->
        {:ok, names}

      {:error, {:stale, _values}} ->
        {:error, stale_reply_error("the devices on track #{track}")}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    # Only the head's params are in scope in an implicit try's `catch`, so the
    # subject is rebuilt here rather than bound in the body.
    :exit, _ ->
      {:error, guard_timeout_error("the devices on track #{track}", @device_index_hint)}
  end

  # Floats are tolerated the way `correlate_reply/2` documents for indices — 1.0
  # reaches Ableton as device 1 — so the bounds check normalises rather than
  # rejects, and hands back the index the rest of the sequence should use.
  defp ensure_device_index(chain, device, names) do
    index = if is_number(device), do: trunc(device), else: device

    if is_integer(index) and index >= 0 and index < length(names) do
      {:ok, index}
    else
      {:error, device_out_of_range_error(chain, device, names)}
    end
  end

  # --- Return / master device chains ---
  #
  # These addresses are Seshat's own and always reply, so silence can only mean
  # the extension isn't installed — which is why every error path below carries
  # @return_extension_hint (or extension_missing_error) and names the chain it
  # was aimed at. None of them may fall through to the regular-track wording:
  # "check the track index with get_session_state" is actively misleading when
  # the real answer is `mix abletonosc.install`.

  defp read_vendored_chain(address, indices, chain) do
    subject = "the devices on #{chain_label(chain)}"

    with {:ok, flat} <- query_vendored_list(address, indices, subject),
         {:ok, {names, types, classes}} <- parse_device_chain(flat) do
      {:ok, format_device_chain(chain, names, types, classes)}
    end
  end

  defp read_vendored_parameters(address, indices, chain, device) do
    subject = "the parameters of device #{device} on #{chain_label(chain)}"

    with {:ok, flat} <- query_vendored_list(address, indices, subject),
         {:ok, {device_name, names, values, mins, maxes}} <- parse_device_parameters(flat) do
      {:ok, format_device_parameters(chain, device, device_name, names, values, mins, maxes)}
    end
  end

  # `query_echoed/4`'s shape, but for a reply whose payload is a whole list rather
  # than one value — the same reason `read_device_names/1` takes the shared core's
  # default decode. The envelope unwrapping is what makes this its own wrapper:
  # an index-less master getter carries no envelope at all.
  defp query_vendored_list(address, indices, subject) do
    query =
      query_correlated(address, indices,
        timeout: @guard_timeout,
        decode: &unwrap_list_payload(&1, indices)
      )

    case query do
      {:ok, list} -> {:ok, list}
      {:error, {:remote, message}} -> {:error, remote_error(message)}
      {:error, {:stale, _values}} -> {:error, stale_reply_error(subject)}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ -> {:error, guard_timeout_error(subject, @return_extension_hint)}
  end

  # An index-less master getter has nothing to look up and so carries no
  # envelope — the payload *is* the list. Everything else is browser.py's
  # ok/error envelope with the list spliced in behind the "ok".
  defp unwrap_list_payload(payload, []), do: {:ok, payload}
  defp unwrap_list_payload(["ok" | rest], _indices), do: {:ok, rest}

  defp unwrap_list_payload(["error", message], _indices) when is_binary(message),
    do: {:error, message}

  defp unwrap_list_payload(_payload, _indices), do: :unexpected_shape

  defp set_vendored_parameter(chain, get_address, set_address, indices, device, parameter, value) do
    subject = "parameter #{parameter} of device #{device} on #{chain_label(chain)}"

    with {:ok, _prior} <- query_echoed(get_address, indices, subject, @return_extension_hint),
         :ok <- Transport.send_message(set_address, indices ++ [value / 1.0]),
         {:ok, display} <- read_back_value(get_address, indices) do
      {:ok, "Set #{subject} to #{value} — it now reads '#{display}'"}
    else
      :unconfirmed ->
        {:error,
         "The set was sent but reading #{subject} back did not confirm it — verify with " <>
           "get_device_parameters."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  # The post-mutation read. A non-answer collapses to `:unconfirmed`, because
  # after the setter is on the wire the only honest report is that the write was
  # not verified — never that nothing was sent, which is what `query_echoed/4`'s
  # wording would claim. That is the one reason this isn't `query_echoed/4`; the
  # echo check and the reissue-once defence both come from the shared core, so a
  # straggler can no longer supply another parameter's display value as proof
  # this write landed.
  #
  # A rejection Live *named* is not a non-answer and is passed through intact.
  # It used to collapse with the rest, which cost the regular-track
  # `set_device_parameter` clause its only index diagnosis: it has no
  # pre-mutation guard, so a bad device or parameter index arrived as "did not
  # confirm it — verify with get_device_parameters", sending the model to a call
  # that fails the same way. `:unconfirmed` now means what it says — a mismatch,
  # a stale reply, or a timeout — and every caller either renders the
  # `{:error, _}` or falls through to its own unconfirmed wording.
  #
  # The timeout is caught here rather than left to the caller: a read-back that
  # never answers is exactly as unconfirmed as one that answers wrongly, and the
  # caller's own message says so.
  defp read_back_value(address, indices) do
    case query_correlated(address, indices, timeout: @guard_timeout, decode: &unwrap_payload/1) do
      {:ok, value} -> {:ok, value}
      {:error, {:live_error, _} = reason} -> {:error, reason}
      _other -> :unconfirmed
    end
  catch
    :exit, _ -> :unconfirmed
  end

  defp delete_vendored_device(
         chain,
         list_address,
         list_indices,
         delete_address,
         device,
         build_args
       ) do
    subject = "the devices on #{chain_label(chain)}"

    with {:ok, flat} <- query_vendored_list(list_address, list_indices, subject),
         {:ok, {names, _types, _classes}} <- parse_device_chain(flat),
         {:ok, device} <- ensure_device_index(chain, device, names),
         {:ok, remaining} <-
           query_vendored_delete(delete_address, build_args.(device), chain, device),
         :ok <- ensure_remaining(chain, device, remaining, length(names) - 1) do
      FollowCam.steer(
        "delete_device",
        Map.merge(chain_facts(chain), %{
          device: device,
          remaining: remaining
        })
      )

      {:ok, deleted_device_reply(chain, device, names)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # Verifies more than an echo, which is why it doesn't ride `query_correlated/4`:
  # the payload is the chain length re-read after the delete, so the mismatch and
  # the not-a-count branches each need their own post-mutation wording ("it is
  # unknown whether the device was removed"), and a reissue would be a second
  # confirmation query rather than a second attempt at one answer.
  defp query_vendored_delete(address, args, chain, device) do
    case Transport.query(address, args, @guard_timeout) do
      {:ok, {_addr, values}} ->
        {echoed, payload} = Enum.split(values, length(args))

        if indices_match?(echoed, args) do
          case unwrap_payload(payload) do
            {:ok, remaining} when is_integer(remaining) ->
              {:ok, remaining}

            {:error, message} ->
              {:error, remote_error(message)}

            _other ->
              {:error,
               "Live's reply to deleting device #{device} on #{chain_label(chain)} was not a " <>
                 "device count (#{inspect(payload)}), so it is unknown whether it was removed. " <>
                 "Verify with get_track_devices."}
          end
        else
          {:error,
           "The reply confirming the delete was not about device #{device} on " <>
             "#{chain_label(chain)} (got #{inspect(values)}) — likely left over from an " <>
             "earlier timed-out query, so it is unknown whether the device was removed. " <>
             "Verify with get_track_devices."}
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "The delete of device #{device} on #{chain_label(chain)} got no reply, so it is unknown " <>
         "whether it was removed. #{@return_extension_hint}"}
  end

  defp ensure_remaining(_chain, _device, remaining, expected) when remaining == expected, do: :ok

  defp ensure_remaining(chain, device, remaining, expected) do
    {:error,
     "The delete of device #{device} on #{chain_label(chain)} reported #{remaining} device(s) " <>
       "left, not #{expected} — the chain changed underneath this call. Re-read it with " <>
       "get_track_devices before acting on any index."}
  end

  defp bypass_vendored_device(chain, addresses, indices, device, enabled) do
    subject = "device #{device} on #{chain_label(chain)}"

    with {:ok, name} <-
           query_echoed(addresses.name, indices, subject, @return_extension_hint),
         {:ok, prior} <-
           query_echoed(
             addresses.value_string,
             indices ++ [0],
             "the on/off switch of #{subject}",
             @return_extension_hint
           ),
         :ok <- ensure_on_off_switch(name, prior) do
      set_device_enabled(chain, device, name, enabled, prior, fn value ->
        with :ok <- Transport.send_message(addresses.set, indices ++ [0, value]) do
          confirm_device_enabled_at(addresses.value, indices ++ [0], chain, device, enabled)
        end
      end)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, Transport.describe_error(reason)}
    end
  end

  # The facts a follow-cam clause keys on, per chain — the one place the three
  # index spaces are turned into steering vocabulary.
  defp chain_facts({:track, track}), do: %{track: track}
  defp chain_facts({:return, index}), do: %{return: index}
  defp chain_facts(:master), do: %{master: true}

  # The only defence the no-reply delete address allows. Raw `Transport.query`
  # deliberately, not `query_echoed/4` or `query_correlated/4`: it verifies more
  # than an echo — the *expected count* is pattern-matched in the head, so a
  # correct echo carrying the wrong number is a distinct, reportable outcome —
  # and every timeout wording here has to say the delete is already on the wire
  # (`set_device_parameter`'s read-back sets that precedent).
  defp confirm_device_count(track, expected) do
    case Transport.query("/live/track/get/num_devices", [track]) do
      {:ok, {_addr, [echoed, ^expected]}} when echoed == track ->
        :ok

      {:ok, {_addr, [echoed, actual]}} when echoed == track ->
        {:error,
         "The delete did not go through — track #{track} still reports #{actual} device(s), " <>
           "not #{expected}. Check Ableton and re-read the chain with get_track_devices."}

      {:ok, {_addr, args}} ->
        {:error,
         "The reply confirming the delete was not about track #{track} " <>
           "(got #{inspect(args)}) — likely left over from an earlier timed-out query, so it " <>
           "is unknown whether the device was removed. Verify with get_track_devices."}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "The delete was sent but confirming it timed out, so it is unknown whether the device " <>
         "was removed — verify with get_track_devices."}
  end

  # Steering happens on the no-op path too: showing the device is the
  # confirmation either way, and "it was already off" is exactly the answer a
  # user is most likely to want to see for themselves.
  #
  # `mutate` is the whole difference between the three chains — send the toggle
  # on that chain's address, read it back on that chain's address — so the
  # decision (already in the requested state? steer where?) lives here once
  # rather than three times.
  defp set_device_enabled(chain, device, name, enabled, prior, mutate) do
    if String.downcase(to_string(prior)) == String.downcase(on_off_label(enabled)) do
      FollowCam.steer("bypass_device", Map.put(chain_facts(chain), :device, device))
      {:ok, bypass_noop_reply(name, chain, device, enabled)}
    else
      case mutate.(if(enabled, do: 1.0, else: 0.0)) do
        :ok ->
          FollowCam.steer("bypass_device", Map.put(chain_facts(chain), :device, device))
          {:ok, bypass_reply(name, chain, device, enabled)}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, Transport.describe_error(reason)}
      end
    end
  end

  # Numeric readback rather than the display string: "Device On" is quantized to
  # exactly 0.0/1.0, so the comparison is safe, and it can't be confused by
  # however a given device chooses to spell its display value. Raw
  # `Transport.query` for the same reason as `confirm_device_count/2` — it
  # verifies more than an echo (the value must equal what was written) and runs
  # after the mutation, so a timeout is uncertainty rather than a refusal.
  defp confirm_device_enabled_at(address, indices, chain, device, enabled) do
    expected = if enabled, do: 1.0, else: 0.0
    subject = "the on/off switch of device #{device} on #{chain_label(chain)}"

    case Transport.query(address, indices, @guard_timeout) do
      {:ok, {_addr, values}} ->
        {echoed, payload} = Enum.split(values, length(indices))

        with true <- indices_match?(echoed, indices),
             {:ok, value} when is_number(value) <- unwrap_payload(payload) do
          if value / 1.0 == expected do
            :ok
          else
            {:error,
             "The toggle was sent but #{subject} still reads #{format_number(value)}, not " <>
               "#{expected} — check it with get_device_parameters."}
          end
        else
          _other ->
            {:error,
             "The reply confirming the toggle was not about #{subject} (got " <>
               "#{inspect(values)}) — likely left over from an earlier timed-out query. " <>
               "Verify with get_device_parameters."}
        end

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "The toggle was sent but reading the on/off switch of device #{device} on " <>
         "#{chain_label(chain)} back timed out — verify with get_device_parameters."}
  end

  # --- Clip property helpers ---

  @doc """
  The ordered OSC writes for a `set_clip_properties` call.

  Pure, and the whole of the write-ordering decision — the handler around it
  only reads, sends and echoes. Takes the clip's current values (needed for the
  paired properties only) and the requested changes, both keyed by property
  name, and returns `[{property, wire_value}]` in the order they must go out.

  Ordering exists because clip setters are silent: Live requires `start < end`
  at all times, and a rejected write would produce no error, just a clip that
  didn't change. So the invariant has to hold after *every individual message*,
  not merely at the end:

    * `looping` goes first. While looping is off, Live's object model aliases
      `loop_start`/`loop_end` onto the play markers, so writing a brace before
      the toggle would move the wrong thing.
    * A pair with both sides changing is written end-first when the new start
      lies at or beyond the old end (`s1 >= e0`), start-first otherwise. Either
      way both intermediate states are valid.
    * A pair with one side changing must be valid against the *current* other
      side, or it is an error naming that current value — there is no ordering
      that can rescue it.
    * Unpaired scalars go last, in `@clip_scalar_properties` order.

  Values are coerced to the house wire conventions here too: booleans to 1/0,
  enums to integers, every other number to a float. `name` is the one string
  value in the list and passes through untouched.
  """
  @spec clip_property_writes(map(), map()) ::
          {:ok, [{String.t(), String.t() | number()}]} | {:error, String.t()}
  def clip_property_writes(current, changes) do
    with :ok <- validate_clip_pairs(changes),
         {:ok, loop_writes} <- clip_pair_writes(current, changes, "loop_start", "loop_end"),
         {:ok, marker_writes} <-
           clip_pair_writes(current, changes, "start_marker", "end_marker") do
      {:ok,
       clip_looping_write(changes) ++ loop_writes ++ marker_writes ++ clip_scalar_writes(changes)}
    end
  end

  # Runs twice: once in the handler before anything touches the transport (so an
  # inverted range costs no round trips at all), and once inside
  # `clip_property_writes/2` so the pure function is correct on its own terms.
  defp validate_clip_pairs(changes) do
    Enum.reduce_while(@clip_pair_properties, :ok, fn {start_key, end_key}, :ok ->
      case {Map.get(changes, start_key), Map.get(changes, end_key)} do
        {start, finish} when is_number(start) and is_number(finish) and start >= finish ->
          {:halt,
           {:error,
            "#{start_key} #{format_number(start / 1.0)} is not before #{end_key} " <>
              "#{format_number(finish / 1.0)} — a clip's range must start before it ends, so " <>
              "nothing was set."}}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp clip_pair_writes(current, changes, start_key, end_key) do
    case {Map.fetch(changes, start_key), Map.fetch(changes, end_key)} do
      {:error, :error} ->
        {:ok, []}

      {{:ok, start}, {:ok, finish}} ->
        {:ok, ordered_pair_writes(current, start_key, start, end_key, finish)}

      {{:ok, start}, :error} ->
        case Map.get(current, end_key) do
          finish when is_number(finish) and is_number(start) and start / 1.0 >= finish / 1.0 ->
            {:error,
             "#{start_key} #{format_number(start / 1.0)} is not before the current #{end_key} " <>
               "#{format_number(finish / 1.0)} — pass #{end_key} too to move the whole range. " <>
               "Nothing was set."}

          _ ->
            {:ok, [clip_write(start_key, start)]}
        end

      {:error, {:ok, finish}} ->
        case Map.get(current, start_key) do
          start when is_number(start) and is_number(finish) and finish / 1.0 <= start / 1.0 ->
            {:error,
             "#{end_key} #{format_number(finish / 1.0)} is not after the current #{start_key} " <>
               "#{format_number(start / 1.0)} — pass #{start_key} too to move the whole range. " <>
               "Nothing was set."}

          _ ->
            {:ok, [clip_write(end_key, finish)]}
        end
    end
  end

  # End-first when the new range sits at or beyond the old end, so the
  # intermediate state is (old start, new end) rather than the inverted
  # (new start, old end). With no current value known, start-first is the
  # harmless default.
  defp ordered_pair_writes(current, start_key, start, end_key, finish) do
    current_end = Map.get(current, end_key)

    if is_number(current_end) and is_number(start) and start / 1.0 >= current_end / 1.0 do
      [clip_write(end_key, finish), clip_write(start_key, start)]
    else
      [clip_write(start_key, start), clip_write(end_key, finish)]
    end
  end

  defp clip_looping_write(%{"looping" => value}), do: [clip_write("looping", value)]
  defp clip_looping_write(_changes), do: []

  defp clip_scalar_writes(changes) do
    @clip_scalar_properties
    |> Enum.filter(&Map.has_key?(changes, &1))
    |> Enum.map(&clip_write(&1, Map.fetch!(changes, &1)))
  end

  defp clip_write(property, value), do: {property, coerce_clip_value(property, value)}

  # `truthy?/1`, not a bare `if`: every non-nil term is truthy in Elixir, so a
  # boolean spelled as `0` would otherwise turn the property *on*. Since
  # `Seshat.Tools.Validation` runs in `call/2`, a `0` no longer arrives by that
  # route in either mode — it is rejected as "must be a boolean". This stays
  # because `clip_property_writes/2` is public and called directly, so `call/2`
  # is not the only way in.
  defp coerce_clip_value(property, value) when property in @clip_boolean_properties,
    do: if(truthy?(value), do: 1, else: 0)

  defp coerce_clip_value(property, value)
       when property in @clip_integer_properties and is_number(value),
       do: trunc(value)

  defp coerce_clip_value(_property, value) when is_number(value), do: value / 1.0
  defp coerce_clip_value(_property, value), do: value

  defp ensure_clip_changes(changes) when map_size(changes) == 0 do
    {:error,
     "Nothing to set — pass at least one property: " <>
       Enum.join(@clip_writable_properties, ", ") <> "."}
  end

  defp ensure_clip_changes(_changes), do: :ok

  # Only pays for the type check when an audio-only property is actually being
  # written. An explicit error, never a silent drop — the `write_midi_notes`
  # guard precedent.
  defp ensure_audio_clip(track, slot, changes) do
    case Enum.filter(@clip_audio_only_properties, &Map.has_key?(changes, &1)) do
      [] ->
        :ok

      properties ->
        case clip_is_midi(track, slot) do
          {:ok, true} ->
            {:error,
             "#{Enum.join(properties, ", ")} apply to audio clips only, and slot #{slot} on " <>
               "track #{track} holds a MIDI clip — nothing was set. Drop those properties and " <>
               "try again."}

          {:ok, false} ->
            :ok

          {:error, message} ->
            {:error, message}
        end
    end
  end

  defp clip_is_midi(track, slot) do
    query_flag(
      "/live/clip/get/is_midi_clip",
      [track, slot],
      "whether the clip in slot #{slot} on track #{track} is MIDI"
    )
  end

  # Both sides of a pair, whenever either side is changing: the ordering
  # decision needs the current end, the single-sided validation needs the
  # current other side, and the echo reports "was".
  defp read_clip_pair_context(track, slot, changes) do
    @clip_pair_properties
    |> Enum.flat_map(fn {start_key, end_key} ->
      if Map.has_key?(changes, start_key) or Map.has_key?(changes, end_key),
        do: [start_key, end_key],
        else: []
    end)
    |> then(&read_clip_properties(track, slot, &1))
  end

  # Everything written, plus the two derived values worth seeing: the dB string
  # after a gain change (the 0–1 float's curve is undocumented, so the display
  # string is the only honest report), and the length after anything that moves
  # the clip's audible extent.
  #
  # A failure here is reported in this function's own words rather than passed
  # up: every `query_echoed/4` error ends in "nothing further was sent", which is
  # true of a guard that runs *before* the writes and false of a read-back that
  # runs after them. The writes are already on the wire at this point, and
  # telling the model otherwise is the one lie this tool can't afford — its whole
  # contract is that what it reports is what Live holds (`confirm_device_enabled`
  # draws the same distinction on the same kind of path).
  defp read_clip_writeback(track, slot, writes) do
    written = Enum.map(writes, fn {property, _value} -> property end)

    extras =
      if("gain" in written, do: ["gain_display_string"], else: []) ++
        if(Enum.any?(written, &(&1 in @clip_range_properties)), do: ["length"], else: [])

    case read_clip_properties(track, slot, written ++ extras) do
      {:ok, values} ->
        {:ok, values}

      {:error, _message} ->
        {:error,
         "#{Enum.join(written, ", ")} #{if(length(written) == 1, do: "was", else: "were")} sent " <>
           "to the clip in slot #{slot} on track #{track} and most likely applied, but reading " <>
           "the values back failed — what Live actually holds is unconfirmed. Check with " <>
           "get_clip_properties, and that Ableton is still running with AbletonOSC enabled."}
    end
  end

  defp read_audio_clip_properties(_track, _slot, true), do: {:ok, %{}}

  defp read_audio_clip_properties(track, slot, false),
    do: read_clip_properties(track, slot, @clip_audio_reads)

  # One batch, not one query per property. Each entry echoes the same track and
  # slot behind a different address, and `Transport.query_batch/2` verifies that
  # echo per entry — the check `query_echoed/4` used to perform caller-side, one
  # reply at a time, at the price of a 100ms AbletonOSC tick each. Twelve
  # properties therefore cost one tick between them rather than twelve.
  #
  # The per-property wording stays here, where the property is known: the
  # transport reports only which entry failed and why.
  defp read_clip_properties(_track, _slot, []), do: {:ok, %{}}

  defp read_clip_properties(track, slot, properties) do
    properties = Enum.uniq(properties)
    entries = Enum.map(properties, &{clip_get_address(&1), [track, slot]})

    case Transport.query_batch(entries, @guard_timeout) do
      {:ok, results} ->
        properties
        |> Enum.zip(results)
        |> Enum.reduce_while({:ok, %{}}, fn {property, result}, {:ok, acc} ->
          subject = "the #{property} of the clip in slot #{slot} on track #{track}"

          case decode_entry(result, subject) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, property, value)}}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    # One deadline covers the whole batch, so a timeout is no longer about one
    # property — and every caller of this helper still reads before it mutates,
    # bar `read_clip_writeback/3`, which overrides this wording with its own.
    :exit, _ ->
      {:error,
       guard_timeout_error(
         "the properties of the clip in slot #{slot} on track #{track}",
         @clip_index_hint
       )}
  end

  defp send_clip_writes(track, slot, writes) do
    Enum.reduce_while(writes, :ok, fn {property, value}, :ok ->
      case Transport.send_message(clip_set_address(property), [track, slot, value]) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            "Failed to set #{property} on the clip in slot #{slot} on track #{track}: " <>
              "#{inspect(reason)}. Properties earlier in the same call may already have been " <>
              "applied — check with get_clip_properties."}}
      end
    end)
  end

  # Addresses as literals, one clause per property, rather than interpolating
  # the property name into the address: `vendored_addresses_test` greps `lib/`
  # for `"/live/…"` literals, and an interpolated address is invisible to it.
  defp clip_get_address("is_midi_clip"), do: "/live/clip/get/is_midi_clip"
  defp clip_get_address("name"), do: "/live/clip/get/name"
  defp clip_get_address("length"), do: "/live/clip/get/length"
  defp clip_get_address("looping"), do: "/live/clip/get/looping"
  defp clip_get_address("loop_start"), do: "/live/clip/get/loop_start"
  defp clip_get_address("loop_end"), do: "/live/clip/get/loop_end"
  defp clip_get_address("start_marker"), do: "/live/clip/get/start_marker"
  defp clip_get_address("end_marker"), do: "/live/clip/get/end_marker"
  defp clip_get_address("launch_mode"), do: "/live/clip/get/launch_mode"
  defp clip_get_address("launch_quantization"), do: "/live/clip/get/launch_quantization"
  defp clip_get_address("legato"), do: "/live/clip/get/legato"
  defp clip_get_address("velocity_amount"), do: "/live/clip/get/velocity_amount"
  defp clip_get_address("gain"), do: "/live/clip/get/gain"
  defp clip_get_address("gain_display_string"), do: "/live/clip/get/gain_display_string"
  defp clip_get_address("warp_mode"), do: "/live/clip/get/warp_mode"
  defp clip_get_address("warping"), do: "/live/clip/get/warping"

  defp clip_set_address("looping"), do: "/live/clip/set/looping"
  defp clip_set_address("loop_start"), do: "/live/clip/set/loop_start"
  defp clip_set_address("loop_end"), do: "/live/clip/set/loop_end"
  defp clip_set_address("start_marker"), do: "/live/clip/set/start_marker"
  defp clip_set_address("end_marker"), do: "/live/clip/set/end_marker"
  defp clip_set_address("launch_mode"), do: "/live/clip/set/launch_mode"
  defp clip_set_address("launch_quantization"), do: "/live/clip/set/launch_quantization"
  defp clip_set_address("legato"), do: "/live/clip/set/legato"
  defp clip_set_address("velocity_amount"), do: "/live/clip/set/velocity_amount"
  defp clip_set_address("gain"), do: "/live/clip/set/gain"
  defp clip_set_address("warp_mode"), do: "/live/clip/set/warp_mode"
  defp clip_set_address("warping"), do: "/live/clip/set/warping"
  defp clip_set_address("name"), do: "/live/clip/set/name"

  # An *unwarped* audio clip counts its length, loop points and markers in
  # seconds, not beats (Live's object model switches the unit on `warping`), so
  # the reply names the unit it is actually reporting rather than always saying
  # "beats" and being wrong on exactly the clips a producer drags in.
  defp format_clip_properties(track, slot, midi?, properties) do
    type = if midi?, do: "MIDI", else: "audio"
    beats? = midi? or truthy?(properties["warping"])
    unit = if beats?, do: "beats", else: "seconds"
    position = if beats?, do: "beat", else: "second"

    header =
      "Clip '#{properties["name"]}' — track #{track}, slot #{slot} — #{type}, " <>
        "#{format_number(properties["length"])} #{unit}"

    loop =
      "Loop: #{on_off_word(truthy?(properties["looping"]))}, from #{position} " <>
        "#{format_number(properties["loop_start"])} to " <>
        "#{format_number(properties["loop_end"])}" <>
        beat_span(properties["loop_start"], properties["loop_end"], unit)

    markers =
      "Play markers: start #{format_number(properties["start_marker"])}, " <>
        "end #{format_number(properties["end_marker"])}"

    launch =
      "Launch: #{enum_name(@launch_mode_names, properties["launch_mode"])}, quantization " <>
        "#{enum_name(@launch_quantization_names, properties["launch_quantization"])}, legato " <>
        "#{on_off_word(truthy?(properties["legato"]))}, velocity amount " <>
        "#{format_number(properties["velocity_amount"])}"

    audio =
      if midi? do
        []
      else
        [
          "Audio: gain #{properties["gain_display_string"]} " <>
            "(#{format_number(properties["gain"])}), warp " <>
            "#{on_off_word(truthy?(properties["warping"]))}, mode " <>
            "#{enum_name(@warp_mode_names, properties["warp_mode"])}"
        ]
      end

    Enum.join([header, loop, markers, launch] ++ audio, "\n")
  end

  defp format_clip_writes(track, slot, current, writes, readback) do
    lines =
      Enum.map(writes, fn {property, sent} ->
        "  " <>
          clip_write_line(property, sent, Map.get(readback, property), Map.get(current, property))
      end)

    extras =
      [
        if(Map.has_key?(readback, "gain_display_string"),
          do: "  gain now reads #{readback["gain_display_string"]} in Live"
        ),
        if(Map.has_key?(readback, "length"),
          do: "  clip length is now #{format_number(readback["length"])} beats"
        )
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(
      ["Set clip properties on track #{track}, slot #{slot}:" | lines] ++ extras,
      "\n"
    )
  end

  # The read-back is the only place a silent in-Live rejection can surface, so a
  # value that came back different from what was sent is reported as such rather
  # than smoothed over.
  defp clip_write_line(property, sent, got, was) do
    previously = if is_nil(was), do: "", else: " (was #{format_clip_value(property, was)})"

    cond do
      is_nil(got) ->
        "#{property}: #{format_clip_value(property, sent)} was sent, but reading it back gave " <>
          "nothing#{previously}"

      clip_value_matches?(property, sent, got) ->
        "#{property}: #{format_clip_value(property, got)}#{previously}"

      true ->
        "#{property}: Live reports #{format_clip_value(property, got)}, not the " <>
          "#{format_clip_value(property, sent)} that was sent#{previously}"
    end
  end

  defp clip_value_matches?(property, sent, got) when property in @clip_boolean_properties,
    do: truthy?(got) == (sent == 1)

  defp clip_value_matches?(_property, sent, got) when is_number(sent) and is_number(got),
    do: Float.round(sent / 1.0, 4) == Float.round(got / 1.0, 4)

  defp clip_value_matches?(_property, sent, got), do: sent == got

  defp format_clip_value(property, value) when property in @clip_boolean_properties,
    do: on_off_word(truthy?(value))

  defp format_clip_value("launch_mode", value), do: enum_name(@launch_mode_names, value)

  defp format_clip_value("launch_quantization", value),
    do: enum_name(@launch_quantization_names, value)

  defp format_clip_value("warp_mode", value), do: enum_name(@warp_mode_names, value)
  defp format_clip_value("name", value), do: ~s{'#{value}'}
  defp format_clip_value(_property, value), do: format_number(value)

  defp clip_property_list(params) do
    case Enum.filter(@clip_writable_properties, &Map.has_key?(params, &1)) do
      [] -> "no properties"
      properties -> Enum.join(properties, ", ")
    end
  end

  defp beat_span(start, finish, unit) when is_number(start) and is_number(finish),
    do: " (#{format_number(finish / 1.0 - start / 1.0)} #{unit})"

  defp beat_span(_start, _finish, _unit), do: ""

  defp enum_name(names, value) do
    key = if is_number(value), do: trunc(value), else: value
    Map.get(names, key, "unknown (#{inspect(value)})")
  end

  defp on_off_word(true), do: "on"
  defp on_off_word(false), do: "off"

  # --- Guards ---
  #
  # Each guard catches its own timeout rather than leaving it to the caller: a
  # `catch` on the calling clause also covers the work that runs *after* the
  # guard, so a later timeout would come back wearing the guard's error message.
  # All four read a single flag through `query_flag/3`, which is where the
  # reply-correlation hazard is handled.

  # Message stays action-neutral: shared by the readers (get_clip_notes) and by
  # fire_clip. `hint` carries the caller's own advice about what an empty slot
  # means for *that* operation, and is appended only on the empty-slot branch —
  # a transport failure gets the bare reason, not misleading advice.
  defp ensure_clip(track, slot, hint \\ "") do
    case query_flag(
           "/live/clip_slot/get/has_clip",
           [track, slot],
           "whether slot #{slot} on track #{track} holds a clip"
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         "Slot #{slot} on track #{track} is empty. Clip slots are 0-based, so scene 1 is " <>
           "slot 0; check the slot and track index with get_clip_slots." <> hint}

      {:error, message} ->
        {:error, message}
    end
  end

  # Two properties, not one: `has_midi_input` is true for a group track built
  # from MIDI tracks as well, and a group track has no clip slots of its own —
  # so without the second check the write is dropped and we report success,
  # which is the failure mode this guard exists to kill. Ordered so an audio
  # track still costs a single round trip.
  #
  # Two queries rather than one `/live/song/get/track_data` carrying both
  # properties: that reply is a bare value list with no index echo, so it cannot
  # be checked against the track we asked about. The second round trip costs one
  # AbletonOSC tick (~100ms measured 2026-08-04, not the sub-millisecond this
  # comment once claimed) and is still the right spend — the echo check is what
  # it buys. Not a `Transport.query_batch/2` case, either: the second read is
  # conditional on the first, so batching them would pay for a read an audio
  # track never needs.
  defp ensure_midi_track(track) do
    case query_flag("/live/track/get/has_midi_input", [track], "the type of track #{track}") do
      {:ok, true} ->
        ensure_not_group_track(track)

      {:ok, false} ->
        {:error,
         "Track #{track} is an audio track — MIDI notes can only be written to MIDI tracks, " <>
           "so nothing was written. Check track types with get_clip_slots, and remember " <>
           "track indices are 0-based."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp ensure_not_group_track(track) do
    case query_flag(
           "/live/track/get/is_foldable",
           [track],
           "whether track #{track} is a group track"
         ) do
      {:ok, true} ->
        {:error,
         "Track #{track} is a group track — it has no clip slots of its own, so nothing was " <>
           "written. Write to one of the tracks inside the group instead; get_clip_slots " <>
           "labels group tracks 'group'."}

      {:ok, false} ->
        :ok

      {:error, message} ->
        {:error, message}
    end
  end

  defp ensure_midi_clip(track, slot) do
    case query_flag(
           "/live/clip/get/is_midi_clip",
           [track, slot],
           "whether the clip in slot #{slot} on track #{track} is MIDI"
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         "The clip in slot #{slot} on track #{track} is an audio clip, not a MIDI clip, so " <>
           "it has no notes to read."}

      {:error, message} ->
        {:error, message}
    end
  end

  # --- edit_notes ---
  #
  # One window value, used four times: the read that decides what matched, the
  # remove that clears it, the quote in every refusal, and (after a delete) the
  # emptiness check. So it is resolved once, here, always to four arguments —
  # never AbletonOSC's zero-argument catch-all, whose defaults (`0, 127, -8192,
  # 16384`) span 127 pitches from 0 and so leave note 127 out.
  defp edit_window(params) do
    if Enum.any?(@range_params, &Map.has_key?(params, &1)) do
      [
        Map.get(params, "start_pitch", 0),
        Map.get(params, "pitch_span", 128),
        Map.get(params, "start_time", 0.0) / 1.0,
        Map.get(params, "time_span", 9999.0) / 1.0
      ]
    else
      [0, 128, -8192.0, 16384.0]
    end
  end

  # The same correlated read `get_clip_notes` makes — `/live/clip/get/notes`
  # echoes only the track and slot, never the range it was handed, hence the
  # explicit `echo:`. Every failure here is before any write, so every failure
  # may say so.
  defp read_note_window(track, slot, window) do
    case query_correlated("/live/clip/get/notes", [track, slot | window], echo: [track, slot]) do
      {:ok, fields} ->
        parse_clip_notes(fields)

      {:error, {:stale, _values}} ->
        {:error, stale_reply_error("the notes in slot #{slot} on track #{track}")}

      {:error, {:remote, message}} ->
        {:error, remote_error(message)}

      {:error, {:live_error, message}} ->
        {:error, "#{message}. Nothing was changed — check the indices with get_clip_slots."}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the notes in slot #{slot} on track #{track}, so nothing was " <>
         "changed. Check the indices with get_clip_slots, and that Ableton is running with " <>
         "AbletonOSC enabled."}
  end

  # An empty window is a question about an empty range, not a failure: the model
  # asked what is there and the answer is "nothing". Saying so — and saying why,
  # since match-by-start is the surprising half — beats an error it would retry.
  defp rewrite_notes(track, slot, window, _changes, []) do
    {:ok,
     "No notes start inside #{window_phrase(window)} in the clip in slot #{slot} on track " <>
       "#{track}, so nothing was changed. A note that begins before the window and sounds " <>
       "into it does not match — call get_clip_notes to see what is actually there."}
  end

  defp rewrite_notes(track, slot, window, changes, matched) do
    if NoteEdit.delete?(changes) do
      delete_note_window(track, slot, window, matched)
    else
      edit_note_window(track, slot, window, changes, matched)
    end
  end

  defp delete_note_window(track, slot, window, matched) do
    subject =
      "#{note_count(length(matched))} in #{window_phrase(window)} of the clip in slot " <>
        "#{slot} on track #{track}"

    case Transport.send_message("/live/clip/remove/notes", [track, slot | window]) do
      :ok ->
        FollowCam.steer("edit_notes", %{track: track, slot: slot})
        confirm_window_empty(track, slot, window, subject)

      {:error, reason} ->
        {:error, "Nothing was changed: #{Transport.describe_error(reason)}"}
    end
  end

  # Remove then add, in that order, both silent. The add is where a partial
  # failure would be unrecoverable, so it gets its own wording: the notes are
  # gone and the replacements never went out, which is an `undo` away from being
  # fixed and must not be dressed up as a success.
  defp edit_note_window(track, slot, window, changes, matched) do
    with {:ok, edited, clamped} <- NoteEdit.apply(matched, changes),
         :ok <- remove_before_add(track, slot, window),
         :ok <- add_edited_notes(track, slot, edited) do
      FollowCam.steer("edit_notes", %{track: track, slot: slot})
      confirm_edited_notes(track, slot, window, changes, edited, clamped)
    end
  end

  defp remove_before_add(track, slot, window) do
    case Transport.send_message("/live/clip/remove/notes", [track, slot | window]) do
      :ok -> :ok
      {:error, reason} -> {:error, "Nothing was changed: #{Transport.describe_error(reason)}"}
    end
  end

  # `mute` as `0|1` and velocity as an integer: the two conversions without
  # which a read reply cannot be re-sent at all (see the clause's comment).
  defp add_edited_notes(track, slot, edited) do
    flat =
      Enum.flat_map(edited, fn note ->
        [
          note.pitch,
          note.start_time / 1.0,
          note.duration / 1.0,
          round(note.velocity),
          if(note.mute, do: 1, else: 0)
        ]
      end)

    case Transport.send_message("/live/clip/add/notes", [track, slot | flat]) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         "The matched notes were removed but the edited replacements could not be sent " <>
           "(#{Transport.describe_error(reason)}), so slot #{slot} on track #{track} is now " <>
           "missing them. Call undo immediately to put them back."}
    end
  end

  defp confirm_window_empty(track, slot, window, subject) do
    case read_note_window(track, slot, window) do
      {:ok, []} ->
        {:ok, "Deleted #{subject}. The window reads back empty."}

      {:ok, left} ->
        {:error,
         "Deleted #{subject}, but the window still reads back #{note_count(length(left))} — " <>
           "the delete did not fully land. Check with get_clip_notes."}

      {:error, _message} ->
        {:error,
         "The delete was sent for #{subject}, but reading the window back failed, so what " <>
           "Live now holds is unconfirmed. Check with get_clip_notes."}
    end
  end

  # The read-back window is the *bounding rectangle* of the old window and the
  # edited notes, because a transpose or a shift can move a note out of the
  # window it was matched in. That rectangle can legitimately contain notes this
  # call never touched, so the check is "every expected note is present", never
  # "the count matches" — comparing counts here would invent a mismatch out of an
  # innocent neighbour.
  defp confirm_edited_notes(track, slot, window, changes, edited, clamped) do
    summary =
      "Edited #{note_count(length(edited))} in #{window_phrase(window)} of the clip in slot " <>
        "#{slot} on track #{track} — #{describe_note_changes(changes)}." <>
        clamped_note(clamped)

    case read_note_window(track, slot, readback_window(window, edited)) do
      {:ok, found} ->
        case missing_note_keys(edited, found) do
          [] ->
            {:ok, "#{summary} Read back and confirmed."}

          missing ->
            {:error,
             "#{summary} But #{note_count(length(missing))} did not read back as expected, " <>
               "so what Live holds is not what was asked for. Check with get_clip_notes, and " <>
               "undo if the clip is wrong."}
        end

      {:error, _message} ->
        {:error,
         "#{summary} Reading the notes back failed, so what Live now holds is unconfirmed. " <>
           "Check with get_clip_notes."}
    end
  end

  # Padded by a beat either side so a start sitting exactly on an edge is inside
  # the rectangle whichever way Live rounds the comparison, and widened to every
  # pitch the edit produced.
  defp readback_window([start_pitch, pitch_span, start_time, time_span], edited) do
    pitches = Enum.map(edited, & &1.pitch)
    starts = Enum.map(edited, &(&1.start_time / 1.0))

    low_pitch = Enum.min([start_pitch | pitches]) |> max(0)
    high_pitch = Enum.max([start_pitch + pitch_span - 1 | pitches]) |> min(127)

    low_time = Enum.min([start_time / 1.0 | starts]) - 1.0
    high_time = Enum.max([start_time / 1.0 + time_span / 1.0 | starts]) + 1.0

    [low_pitch, max(high_pitch - low_pitch + 1, 1), low_time, high_time - low_time]
  end

  # Rounded to 4 decimals for the same reason `confirm_send/5` rounds: OSC's `f`
  # is 32-bit and Elixir's floats are not, so a computed start goes out as
  # `1.6667` and comes back as `1.666700005531311`.
  defp note_key(note) do
    {trunc(note.pitch), Float.round(note.start_time / 1.0, 4),
     Float.round(note.duration / 1.0, 4), round(note.velocity), note.mute == true}
  end

  defp missing_note_keys(expected, found) do
    found_counts = found |> Enum.map(&note_key/1) |> Enum.frequencies()

    expected
    |> Enum.map(&note_key/1)
    |> Enum.reduce({[], found_counts}, fn key, {missing, counts} ->
      case Map.get(counts, key, 0) do
        0 -> {[key | missing], counts}
        n -> {missing, Map.put(counts, key, n - 1)}
      end
    end)
    |> elem(0)
  end

  defp note_count(1), do: "1 note"
  defp note_count(count), do: "#{count} notes"

  defp clamped_note(0), do: ""

  defp clamped_note(count),
    do: " #{note_count(count)} hit the 1-127 velocity limit and stopped there."

  defp window_phrase([0, 128, _start_time, _time_span]), do: "the whole clip"

  defp window_phrase([start_pitch, pitch_span, start_time, time_span]) do
    "pitches #{start_pitch}-#{start_pitch + pitch_span - 1}, beats " <>
      "#{format_number(start_time / 1.0)}-#{format_number((start_time + time_span) / 1.0)}"
  end

  defp describe_note_changes(changes) do
    ~w(transpose velocity velocity_delta duration shift)
    |> Enum.filter(&Map.has_key?(changes, &1))
    |> Enum.map_join(", ", &describe_note_change(&1, Map.fetch!(changes, &1)))
  end

  defp describe_note_change("transpose", value),
    do: "transposed #{signed_number(value)} semitone(s)"

  defp describe_note_change("velocity", value), do: "velocity set to #{format_number(value)}"

  defp describe_note_change("velocity_delta", value),
    do: "velocity #{signed_number(value)}"

  defp describe_note_change("duration", value),
    do: "duration set to #{format_number(value / 1.0)} beat(s)"

  defp describe_note_change("shift", value),
    do: "shifted #{signed_number(value)} beat(s)"

  defp signed_number(value) when is_number(value) and value >= 0,
    do: "+#{format_number(value)}"

  defp signed_number(value), do: "#{format_number(value)}"

  # --- Quantize guards and reads ---

  # 0% strength provably cannot move a note, so it is a trap rather than an
  # option — the same argument that keeps `no_grid` (enum 0) out of the tool's
  # grid list. It has to live here: `Seshat.Tools.Validation` reads only
  # `:minimum`, with no `exclusiveMinimum` branch to reject 0.0 at the schema.
  # Without this the zero case would reach the nothing-moved reply and tell the
  # user their AbletonOSC install might be stale, which at 0% is a fabrication.
  defp reject_zero_amount(amount) when amount == 0 do
    {:error,
     "amount 0 is 0% strength, which cannot move any note — try 0.5 to tighten the timing " <>
       "while keeping the feel."}
  end

  defp reject_zero_amount(_amount), do: :ok

  # The name is garnish: it only decides whether the reply says "Keys" or "the
  # clip in slot 0 on track 1", so a failed read falls back rather than failing
  # a quantize that would otherwise have succeeded.
  defp read_clip_name(track, slot) do
    case query_echoed(
           "/live/clip/get/name",
           [track, slot],
           "the name of the clip in slot #{slot} on track #{track}",
           @clip_index_hint
         ) do
      {:ok, name} when is_binary(name) -> name
      _other -> nil
    end
  end

  defp ensure_notes_to_quantize([], track, slot) do
    {:error, "The clip in slot #{slot} on track #{track} has no notes to quantize."}
  end

  defp ensure_notes_to_quantize(_notes, _track, _slot), do: :ok

  # No range args: AbletonOSC defaults to the whole clip.
  #
  # It verifies more than `query_correlated/4` can, which is why it spells the
  # echo check and the reissue-once defence out rather than riding the shared
  # decode: `phase` changes the *consequence* sentence on every failure path (see
  # below), and a stale reply after the quantize is already on the wire may not
  # claim nothing was sent.
  #
  # Be clear about what the check buys: it catches a *cross-clip* straggler — a
  # notes query abandoned by an earlier timeout, plausible here because an
  # oversized reply truncates and surfaces as one. It does nothing about this
  # tool's own hazard, two identical back-to-back queries: a late or duplicate
  # answer to the *before* read satisfying the *after* read carries the same
  # indices, passes this check, and reads as "nothing moved". Only the hedged
  # nothing-moved wording stands against that.
  #
  # `phase` decides the *consequence* sentence, never the diagnosis. This helper
  # reads either side of `send_quantize/4`, and the two sides can afford
  # different claims: before the datagram goes out "nothing further was sent" is
  # true and actionable, while after it the mutation is already on the wire and
  # Live may well have applied it. Saying nothing was sent there would be the
  # same lie the `catch :exit` clause in `quantize_clip` is written to avoid —
  # and this became reachable when a rejection started arriving in milliseconds
  # instead of never, so the failure the exit clause guards against by hand now
  # has a fast sibling that has to make the same distinction.
  defp read_all_notes(track, slot, phase, reissued? \\ false) do
    case Transport.query("/live/clip/get/notes", [track, slot]) do
      {:ok, {_addr, [echoed_track, echoed_slot | fields]}}
      when echoed_track == track and echoed_slot == slot ->
        parse_clip_notes(fields)

      {:ok, {_addr, _mismatched}} ->
        if reissued? do
          {:error,
           stale_reply_error(
             "the notes in slot #{slot} on track #{track}",
             notes_read_consequence(phase, track, slot)
           )}
        else
          read_all_notes(track, slot, phase, true)
        end

      # As in `query_echoed/4`: a rejected read of this clip means the track or
      # slot isn't there. Before the quantize that carries the same consequence
      # as the vendored envelope's error arm; after it, only the diagnosis
      # survives.
      {:error, {:live_error, message}} ->
        {:error, "#{message}. " <> notes_read_consequence(phase, track, slot)}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  end

  defp notes_read_consequence(:before_quantize, _track, _slot),
    do: "Nothing further was sent — check get_session_state for the indices that actually exist."

  defp notes_read_consequence(:after_quantize, track, slot),
    do:
      "The quantize was already sent, so it may or may not have been applied — read the clip " <>
        "back with get_clip_notes on track #{track}, slot #{slot}."

  # `query_echoed/4` for the boolean properties, normalising AbletonOSC's mix of
  # `true`/`false` and 1/0.
  defp query_flag(address, indices, subject) do
    with {:ok, flag} <- query_echoed(address, indices, subject, @clip_index_hint) do
      {:ok, truthy?(flag)}
    end
  end

  # --- Correlated reply decoding ---
  #
  # Transport serializes queries, but it correlates replies by address alone, so
  # a reply abandoned by an earlier timeout can still answer the next query on
  # that same address — answering a read of track 3 with track 0's data is
  # exactly the silent wrong answer these checks exist to prevent. Every
  # AbletonOSC getter that takes an index echoes it back in front of the payload,
  # and that echo is the only thing on the wire distinguishing this call's reply
  # from a straggler's.
  #
  # `correlate_reply/2` is that whole decision, and `query_correlated/4` wraps it
  # in the send and the reissue-once policy. Nothing in this module may read an
  # echoed reply without going through one of them or spelling the same check out
  # — the handful that do spell it out say why in a comment of their own, and
  # every raw `Transport.query/3` site left over says why it has no echo to
  # check.

  @doc """
  Splits a reply into the prefix it echoes back and the payload behind it,
  verifying that prefix against what was asked.

  `echo` is what the reply must repeat, which is usually the request's own
  arguments but not always: `/live/clip/get/notes` echoes only the track and slot
  even when sent a pitch/time range, and `/live/browser/get/items` echoes the
  category and filter but never `max_results`.

  `:stale` covers both failure modes, because to a caller they mean the same
  thing — this reply is not an answer to this request. A reply *shorter* than the
  echo counts as one: `Enum.zip/2` truncates to the shorter list, so a
  one-element reply would otherwise sail past a two-index comparison having
  compared nothing. `load_outcome/2` guards that trap by hand for the same
  reason.

  Values are compared with `==` rather than pinned: a float index still reaches
  Ableton fine (it casts to int) and comes back as an integer, so pinning would
  reject a reply that is in fact ours. String echoes — the browser's category and
  filter, `is_view_visible`'s pane name — compare just as happily.
  """
  @spec correlate_reply(list(), list()) :: {:ok, list()} | :stale
  def correlate_reply(values, echo) do
    {echoed, payload} = Enum.split(values, length(echo))

    cond do
      length(echoed) < length(echo) -> :stale
      not indices_match?(echoed, echo) -> :stale
      true -> {:ok, payload}
    end
  end

  # One correlated query: send it, verify the echoed prefix, decode what is left,
  # and reissue once when the reply is stale or in a shape this code can't read.
  #
  # The reissue asks the identical question, so the straggler's genuine successor
  # usually answers it. That is mitigation, not a guarantee — the genuine reply
  # can land in the gap after the mismatch is rejected and before the reissue is
  # in flight, in which case it is broadcast and the reissue times out. These
  # checks earn their keep by refusing wrong data, not by reliably obtaining
  # right data. Only a second failure is reported.
  #
  # Options:
  #   echo:    the prefix the reply must echo (default: `args`)
  #   timeout: passed to Transport.query/3 (default: Transport's own)
  #   decode:  applied to the payload behind the echo, returning
  #            {:ok, term} | {:error, remote_message} | :unexpected_shape
  #            (default: the payload list as-is)
  #
  # Returns `{:ok, decoded}`; `{:error, {:stale, values}}` once a second reply
  # has failed; `{:error, {:remote, message}}` for a decoded error envelope; or
  # Transport's own `{:error, reason}` — including `{:live_error, message}` —
  # untouched. Wording stays at the call site, where the subject and the
  # consequence of failing are known.
  #
  # **Timeouts are deliberately not caught here.** `Transport.query/3` exits the
  # caller, and each call site already has a `catch :exit` whose wording knows
  # whether anything was sent. Swallowing it here would flatten "nothing further
  # was sent" and "the mutation is already on the wire" into one message.
  defp query_correlated(address, args, opts, reissued? \\ false) do
    reply =
      case Keyword.get(opts, :timeout) do
        nil -> Transport.query(address, args)
        timeout -> Transport.query(address, args, timeout)
      end

    case reply do
      {:ok, {_addr, values}} ->
        decode = Keyword.get(opts, :decode, &{:ok, &1})

        case correlate_reply(values, Keyword.get(opts, :echo, args)) do
          {:ok, payload} ->
            case decode.(payload) do
              {:ok, decoded} -> {:ok, decoded}
              {:error, message} -> {:error, {:remote, message}}
              :unexpected_shape -> reissue_correlated(address, args, opts, reissued?, values)
            end

          :stale ->
            reissue_correlated(address, args, opts, reissued?, values)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reissue_correlated(address, args, opts, false, _values),
    do: query_correlated(address, args, opts, true)

  defp reissue_correlated(_address, _args, _opts, true, values),
    do: {:error, {:stale, values}}

  # Reads one value, and returns it only if the reply echoed back the indices we
  # asked about — `query_correlated/4` with `unwrap_payload/1` as the decode, on
  # the guard timeout.
  #
  # It keeps a `catch :exit` of its own, which the shared core deliberately does
  # not have: every caller is a guard that reads *before* a mutation, so a
  # timeout here really does mean nothing further was sent. `hint` is that
  # caller's advice for one — which index to re-check, and whether the address is
  # one of Seshat's extensions.
  defp query_echoed(address, indices, subject, hint) do
    query =
      query_correlated(address, indices,
        timeout: @guard_timeout,
        decode: &unwrap_payload/1
      )

    case query do
      {:ok, value} ->
        {:ok, value}

      {:error, {:remote, message}} ->
        {:error, remote_error(message)}

      {:error, {:stale, _values}} ->
        {:error, stale_reply_error(subject)}

      # Live rejected this exact request — for a guard query that means the
      # index doesn't exist, which is precisely what `remote_error/1` says for
      # the vendored envelope's error arm. Rendering both the same way is the
      # point: an upstream address and one of ours now fail a guard identically.
      {:error, {:live_error, message}} ->
        {:error, remote_error(message)}

      {:error, reason} ->
        {:error, Transport.describe_error(reason)}
    end
  catch
    :exit, _ -> {:error, guard_timeout_error(subject, hint)}
  end

  @doc """
  Reads the value out of a getter reply, once the echoed indices have been
  stripped off the front.

  Upstream getters reply with the value alone. Seshat's own return/master getters
  wrap it in browser.py's ok/error envelope, so an index that doesn't exist comes
  back as a message instead of the silence upstream produces — immediately, and
  distinguishably from an extension that was never installed.

  `:unexpected_shape` means the reply is not one this code knows how to read,
  which the caller treats as a crossed wire rather than an answer.
  """
  @spec unwrap_payload(list()) :: {:ok, term()} | {:error, String.t()} | :unexpected_shape
  def unwrap_payload([value]), do: {:ok, value}
  def unwrap_payload(["ok", value]), do: {:ok, value}
  def unwrap_payload(["error", message]) when is_binary(message), do: {:error, message}
  def unwrap_payload(_other), do: :unexpected_shape

  defp remote_error(message) do
    "#{message}. Nothing further was sent — check get_session_state for the indices that " <>
      "actually exist."
  end

  # One `Transport.query_batch/2` result, rendered the way the serialized path
  # renders a single reply: `unwrap_payload/1` behind the echoed indices by
  # default, `remote_error/1` for a rejection Live named — whether that came back
  # as the vendored envelope's error arm or as the structured `/live/error`
  # Transport correlated to this very entry — and a sentence of its own for a
  # payload no clause here can read.
  #
  # `decode` is the escape hatch for a reply whose payload is a whole list rather
  # than one value (the device chain and parameter reads), exactly as
  # `query_correlated/4`'s `:decode` option is.
  #
  # There is no reissue to make here and no `:stale` arm to write: the echo check
  # `query_correlated/4` reissues in order to obtain has already happened inside
  # Transport, per entry, before this reply was assigned to this entry at all.
  defp decode_entry(result, subject, decode \\ &unwrap_payload/1)

  defp decode_entry({:ok, payload}, subject, decode) do
    case decode.(payload) do
      {:ok, value} -> {:ok, value}
      {:error, message} -> {:error, remote_error(message)}
      :unexpected_shape -> {:error, unreadable_reply_error(subject)}
    end
  end

  defp decode_entry({:error, {:live_error, message}}, _subject, _decode),
    do: {:error, remote_error(message)}

  # Not `stale_reply_error/2`: that one's "not about what was asked for, twice in
  # a row" describes the serialized path's reissue, which a batch has no
  # equivalent of. A reply that reaches this point *is* about what was asked for
  # — Transport matched its echo — and is simply shaped in a way nothing here
  # knows how to read.
  defp unreadable_reply_error(subject) do
    "Ableton's reply about #{subject} was not a shape this can read, so its value is " <>
      "unknown. Nothing further was sent; try again."
  end

  # Only ever reached with two equal-length lists — `correlate_reply/2` rejects a
  # short reply before this runs, because `Enum.zip/2` would truncate to the
  # shorter one and report a match on nothing.
  defp indices_match?(echoed, indices) do
    echoed |> Enum.zip(indices) |> Enum.all?(fn {reply, asked} -> reply == asked end)
  end

  # What a timeout means depends on who serves the address, so the caller's hint
  # supplies the diagnosis: for upstream addresses silence is usually a bad index,
  # for Seshat's own extension it can only be a missing install.
  defp guard_timeout_error(subject, hint) do
    "Timed out checking #{subject}, so nothing further was sent. #{hint}"
  end

  # Reissued once already, so this is not one crossed wire: something is steadily
  # answering with another index's data.
  # The consequence is a parameter because a caller reading *after* a mutation
  # cannot claim nothing was sent — see `read_all_notes/4`. Every other caller
  # reads before mutating and takes the default.
  # "what was asked for" rather than "the track or slot asked for": the shared
  # decode now reports stale replies for browser searches (echoing a category and
  # a filter) and device reads (a track and a device) as well as clip reads, and
  # naming the wrong pair of indices in the diagnosis is its own small lie.
  # `subject` has already said what was being read.
  defp stale_reply_error(subject, consequence \\ "Nothing further was sent; try again.") do
    "Ableton's replies when checking #{subject} were not about what was asked for, twice in " <>
      "a row — they belong to an earlier query that timed out. " <> consequence
  end

  # AbletonOSC sends booleans for some properties and 0/1 for others.
  defp truthy?(true), do: true
  defp truthy?(value) when is_number(value), do: value != 0
  defp truthy?(_value), do: false

  defp maybe_set_loop_start(%{"start" => start}),
    do: Transport.send_message("/live/song/set/loop_start", [start / 1.0])

  defp maybe_set_loop_start(_), do: :ok

  defp maybe_set_loop_length(%{"length" => length}),
    do: Transport.send_message("/live/song/set/loop_length", [length / 1.0])

  defp maybe_set_loop_length(_), do: :ok

  defp loop_range_summary(%{"start" => start, "length" => length}),
    do: " — start: #{start}, length: #{length} beats"

  defp loop_range_summary(%{"start" => start}), do: " — start: #{start}"
  defp loop_range_summary(%{"length" => length}), do: " — length: #{length} beats"
  defp loop_range_summary(_), do: ""

  # --- View state ---

  # The read-only path. `query_echoed/4` fits it exactly: the reply echoes the
  # view name where every other getter echoes an index, and `==` compares strings
  # as happily as integers, so the reissue-once stale defence and the timeout hint
  # come free. The post-*mutation* read in `confirm_view_hidden/1` deliberately
  # cannot use it — see there.
  defp query_view_visible(view) do
    with {:ok, flag} <-
           query_echoed(
             "/live/view/get/is_view_visible",
             [view],
             "the visibility of #{view}",
             @view_extension_hint
           ) do
      {:ok, truthy?(flag)}
    end
  end

  # Raw `Transport.query` rather than `query_echoed/4` or `query_correlated/4`,
  # for the same reason as `confirm_device_count/2` and
  # `confirm_device_enabled_at/5`: it verifies more than an echo — the ok/error
  # envelope's two arms get different post-mutation wording, and the flag itself
  # decides whether the hide landed — and every failure path here must say the
  # hide is already on the wire, where the shared helpers say "nothing further
  # was sent". The echo check and the reissue-once stale defence are spelled out
  # for the same reason `correlate_reply/2` exists: Transport correlates replies
  # by address alone.
  defp confirm_view_hidden(view, reissued? \\ false) do
    case Transport.query("/live/view/get/is_view_visible", [view], @guard_timeout) do
      {:ok, {_addr, [echoed, "ok", flag]}} when echoed == view ->
        if truthy?(flag) do
          {:error,
           "The hide was sent, but Live still reports #{view_label(view)} as visible. " <>
             "Check Ableton, and re-read the panes with get_view_state."}
        else
          :ok
        end

      {:ok, {_addr, [echoed, "error", message]}} when echoed == view ->
        {:error,
         "The hide was sent, but Ableton could not read #{view_label(view)} back: " <>
           "#{message}. It is unknown whether the pane closed — check get_view_state."}

      {:ok, {_addr, args}} ->
        if reissued? do
          {:error,
           "The replies confirming the hide were not about #{view} (got #{inspect(args)}), " <>
             "twice in a row — they belong to an earlier query that timed out. The hide was " <>
             "sent and may well have landed; verify with get_view_state."}
        else
          confirm_view_hidden(view, true)
        end

      # A deaf transport is the case that makes this branch matter: `send_message/2`
      # is handled outside the query queue and does not check `deaf`, so the hide
      # is on the wire even though no reply can ever come back. Pointing at
      # get_view_state here would be advice that cannot work — it reads through
      # the same dead socket.
      {:error, reason} ->
        {:error,
         "The hide was sent, but confirming it failed (#{Transport.describe_error(reason)}), so it is " <>
           "unknown whether #{view_label(view)} closed. Check Ableton directly: while " <>
           "this error stands, get_view_state cannot read the panes back either."}
    end
  catch
    :exit, _ ->
      {:error,
       "The hide was sent but confirming it timed out, so it is unknown whether " <>
         "#{view_label(view)} closed — verify with get_view_state. #{@view_extension_hint}"}
  end

  # The shared body of `undo` and `redo`, which differ only in their two
  # addresses and in what a refusal has to warn about (redo's history can also
  # be cleared by any new edit; undo's cannot). Three-way, never two: only a
  # confirmed `false` stops the send. An unanswered or unreadable guard proceeds
  # and says so — refusing there would turn a dropped datagram into a failed
  # undo, a worse regression than the dishonest reply this replaces.
  defp history_move(%{verb: verb, send_address: send_address} = move) do
    case history_guard(move.guard_address) do
      :unavailable ->
        {:error, move.refusal}

      availability ->
        uncertainty =
          if availability == :unknown do
            " Ableton did not answer the #{move.guard_name} check, so whether there was " <>
              "anything to #{verb} is unknown."
          else
            ""
          end

        # Nothing to check on the way back: the address never replies. The
        # reply's job is to say exactly that, so the model verifies once after
        # the batch instead of trusting a per-call confirmation that cannot
        # exist.
        case Transport.send_message(send_address, []) do
          :ok ->
            {:ok,
             "#{String.capitalize(verb)} requested. Ableton does not acknowledge #{verb}, so " <>
               "this confirms the request was sent, not that history moved. Verify once after " <>
               "the batch with get_session_state." <> uncertainty}

          {:error, reason} ->
            {:error, Transport.describe_error(reason)}
        end
    end
  end

  # Reads `can_undo` / `can_redo` — upstream `song.py` `properties_r`, so a plain
  # song property with no index and no envelope.
  #
  # That missing index is why `query_correlated/4` cannot be used here: there is nothing
  # for a reply to echo, so the caller-side correlation defence Transport's
  # "Query serialization" section insists is not redundant is unavailable, and
  # its two residual collision classes have to be argued instead. Class 2 (a
  # listener push satisfying a query on the same address) cannot occur — nothing
  # in `lib/` starts a listener on either property. Class 1 (a straggler from a
  # timed-out query answering the next query on that address) can, and it is not
  # benign in both directions: a history-changing call between the two queries
  # can make an old `false` wrong, while a stale `true` only sends a request
  # whose reply asserts nothing. So a `false` is queried once more and refused
  # only if the second recognized answer agrees — the same reissue-once
  # mitigation the echoed guards use, not correlation, which is why the refusal
  # wording reports what Live said rather than asserting the history state as an
  # independently known fact.
  #
  # The accepted reply shape is deliberately loose. `_get_property` hands Live's
  # raw Python value to the encoder, so a bool reaches the wire as OSC `T`/`F`
  # while anything integral arrives as an int; both are read here exactly as
  # `Seshat.Session.State.query_song_int/2` reads them, which makes measuring the
  # exact encoding unnecessary rather than merely deferred.
  #
  # `Transport.query/3` **exits** the caller on timeout and never returns
  # `{:error, :timeout}`, so the unanswered path is a `catch :exit` — without it a
  # dropped datagram would kill the tool call and surface as an opaque MCP crash,
  # strictly worse than today, where undo at least always sends.
  @spec history_guard(String.t(), boolean()) :: :available | :unavailable | :unknown
  defp history_guard(address, reissued? \\ false) do
    case Transport.query(address, [], @guard_timeout) do
      {:ok, {_addr, [value]}} when is_boolean(value) or is_number(value) ->
        cond do
          truthy?(value) -> :available
          reissued? -> :unavailable
          true -> history_guard(address, true)
        end

      # A shape this code cannot read is a crossed wire, not an answer — and an
      # answer is the only thing that may stop the send.
      {:ok, {_addr, _args}} ->
        :unknown

      {:error, _reason} ->
        :unknown
    end
  catch
    :exit, _ -> :unknown
  end

  @doc """
  Renders `get_view_state`'s reply from the six pane-visibility flags.

  Pure, and the whole of the reporting decision — the handler around it only
  queries. Takes Live's pane names mapped to booleans and returns one line
  naming the main view, the browser, and the detail panel with its active tab.

  Live's panes overlap rather than partition, which is what the rules encode:
  `Session` and `Arranger` share the main-view slot and measured complementary
  in every reading (2026-07-31, Live 12 Suite), and `Detail/Clip` /
  `Detail/DeviceChain` mean "the detail panel is open *and* that tab is active",
  so both read false whenever `Detail` does.

  Where a reading contradicts that, the summary says so rather than picking the
  likelier half. A guess rendered in the same confident sentence as a real
  reading is the fabrication the house rule forbids — and this tool exists
  precisely so the model can stop guessing about the view.
  """
  @spec view_state_summary(%{optional(String.t()) => boolean()}) :: String.t()
  def view_state_summary(visibility) do
    Enum.join(
      [
        main_view_line(visibility["Session"], visibility["Arranger"]),
        "Live's browser: #{if visibility["Browser"], do: "open", else: "closed"}.",
        detail_panel_line(visibility)
      ],
      " "
    )
  end

  defp main_view_line(true, false), do: "Main view: Session."
  defp main_view_line(false, true), do: "Main view: Arrangement."
  defp main_view_line(true, true), do: "Live reports both Session and Arrangement visible."
  defp main_view_line(false, false), do: "Live reports neither Session nor Arrangement visible."

  defp detail_panel_line(%{"Detail" => false}), do: "Detail panel: closed."

  defp detail_panel_line(%{"Detail/Clip" => true, "Detail/DeviceChain" => true}),
    do: "Detail panel: open, but Live reports both the clip editor and the device chain active."

  defp detail_panel_line(%{"Detail/Clip" => true}),
    do: "Detail panel: open, showing the clip editor."

  defp detail_panel_line(%{"Detail/DeviceChain" => true}),
    do: "Detail panel: open, showing the device chain."

  defp detail_panel_line(_visibility), do: "Detail panel: open."

  # The reply says what the user is now looking at, in their vocabulary. Live's
  # own `Arranger` spelling is the schema contract because the value goes
  # straight onto the wire, but nobody calls it that out loud.
  defp view_label("Browser"), do: "Live's browser"
  defp view_label("Arranger"), do: "Arrangement view"
  defp view_label("Session"), do: "Session view"
  defp view_label("Detail"), do: "the detail panel"
  defp view_label("Detail/Clip"), do: "the clip editor"
  defp view_label("Detail/DeviceChain"), do: "the device chain"
end
