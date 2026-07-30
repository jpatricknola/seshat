# Plan — `show_view`: show the work before it happens

Roadmap item "`show_view` — the follow cam can't be asked to look anywhere".
One new tool — `show_view` — that brings one of Live's six named panes into
view through the fork's existing `/live/view/show_view` address.

**No Python half.** The address already ships in
[priv/AbletonOSC/abletonosc/view.py](../priv/AbletonOSC/abletonosc/view.py),
is documented in
[abletonosc-api-docs.md](abletonosc-api-docs.md), and is already exercised by
`Seshat.Tools.FollowCam`. No submodule commit, pin bump,
`mix abletonosc.install`, or Live restart is introduced by this feature.

## Context

The follow cam makes a successful create, write, or delete visible *after* the
mutation: it selects what changed and opens the pane it lives in. That closes
the "did anything happen?" gap, but it leaves two ordinary session flows
uncovered:

1. The user explicitly asks to look somewhere — "show me the arrangement",
   "take me back to the clip grid", "show me the notes again".
2. The user asks for an action whose visible result lives in another pane. If
   Live is showing Arrangement and the user asks to launch a Session clip,
   Seshat can launch it without changing panes, but the user cannot see the
   action happen. The intended sequence is **show first, act second**:
   `show_view(Session)` and only then `fire_clip`.

The second flow is the primary one. `show_view` is a pre-action visibility
primitive, not merely a navigation convenience. The model should use it
immediately before an action with a natural visual home:

| What the user is about to see happen | What to show first |
|---|---|
| Session clip/scene launch, stop, or rename | `Session` |
| Song loop-brace or future Arrangement-specific work | `Arranger` |
| Device parameter changes (`set_device_parameter`) | `select_track` on the target track, then `Detail/DeviceChain` |
| Explicit requests to re-see notes or clip detail ("show me the notes again") | `Detail/Clip` |
| Browsing Live's own browser on request | `Browser` |

Two families deliberately need no pre-show. Mutations the follow cam already
steers — note writes and removals, clip property changes, clip/scene/track
creates, duplicates and deletes, device load/delete/bypass — select their
target and show its pane immediately after they land; a pre-show before them
would display whatever the pane held last, and the tool description says to
skip it. And track mixer controls, playback, tempo, metronome, undo/redo, and
reads are visible in any pane or in none, gaining nothing from a forced pane
change.

Two of the panes show a *selected* target rather than a global context, which
is why the table's rows differ in shape. `Detail/DeviceChain` shows the
selected track's device chain, so a parameter change needs `select_track`
first whenever the target track may not already be selected —
`set_device_parameter` is the one mutation the follow cam deliberately does
not steer, so nothing repairs a wrong chain afterwards. `Detail/Clip` shows
`song.view.detail_clip` — whichever clip was last opened there — and no
user-facing tool sets that outside the follow cam, so `Detail/Clip` re-shows
recent work; it cannot aim the editor at an arbitrary clip (see Out of scope,
and the rejected-approach section at the end). The model chooses the pane from
the requested action; the handler does not infer a second action from a view
name.

Seshat cannot observe the currently visible pane. AbletonOSC has no
`get_visible_view` address, `Session.State` mirrors no UI-view state, and this
plan adds neither. The deterministic rule is therefore to call `show_view`
before a view-specific action even when that pane may already be open.
⚠️ `Application.View.show_view/1` is assumed to be idempotent for an
already-visible pane, so the harmless duplicate send is preferable to guessing;
the fork's source cannot prove the visible UI behavior (Open question 1).

Three boundaries keep the feature proportionate:

- **Model-driven sequencing, not edits to every action handler.** A direct
  user request for a pane and a pre-action pane change are both ordinary tool
  calls. Baking pre-steering into `fire_clip`, `set_clip_properties`,
  `set_device_parameter`, and every future action would duplicate policy
  across handlers, force view changes even when the conversational context
  says not to, and still would not serve "show me the arrangement" on its own.
- **Existing follow cam stays.** It remains deterministic post-action
  confirmation and recovery for the mutations it already covers. This plan
  does not move or remove any `FollowCam.steer/2` call.
- **Pointing is not seeing.** The OSC address is silent and Seshat receives no
  pixels or visible-view acknowledgement. `show_view` can put the relevant
  pane in front of the user; the separate roadmap item `screenshot_live`
  remains the feature that would let the model inspect it.

## OSC contract

| Address | Request args | Reply | Provenance |
|---|---|---|---|
| `/live/view/show_view` | `[view_name]` where `view_name` is one of `"Browser"`, `"Arranger"`, `"Session"`, `"Detail"`, `"Detail/Clip"`, `"Detail/DeviceChain"` | **none, ever** | Seshat extension already registered in the fork's `abletonosc/view.py` |

The fork implementation converts the first OSC argument to a string and calls
`Live.Application.get_application().view.show_view(view_name)`. An unknown
name or Live API rejection is caught and logged to Live's `Log.txt`; success
and failure are both silent on the wire. This is the same address and behavior
the follow cam already depends on.

The tool schema closes the only caller-controlled failure case by making the
six accepted names an enum. `Seshat.Tools.Validation` enforces that enum before
dispatch in both entry modes, and the generated MCP schema advertises the same
closed set. The handler therefore stays a single fire-and-forget
`Transport.send_message/2` call; it does not query or claim a wire-level
acknowledgement.

Live's spelling is intentionally the schema contract:

| Tool value | User-language concepts the description maps to it |
|---|---|
| `Arranger` | Arrangement, arrangement view, timeline |
| `Session` | Session, Session view, clip grid, scene grid |
| `Detail/Clip` | clip editor, note editor, notes, clip detail |
| `Detail/DeviceChain` | device chain, devices, device panel |
| `Browser` | browser, sounds/presets browser |
| `Detail` | detail panel, bottom panel |

`Arranger` is not renamed to `Arrangement` in the enum: the value goes straight
to Live, which uses the former even though users say the latter. Friendly
language belongs in the description and reply, not in a translation layer
before validation.

## Numbered parts

### 1. Define the tool — `lib/seshat/tools/definitions.ex`

Insert `show_view` in the existing **View selection** group before
`select_track`:

```elixir
%{
  name: "show_view",
  description:
    "Show a pane in Ableton Live. Use this for explicit navigation requests " <>
      "and BEFORE an action whose result lives in a particular pane, so the " <>
      "user sees the action happen: Session = Session view / clip or scene " <>
      "grid; Arranger = Arrangement view / timeline; Detail/Clip = clip or " <>
      "note editor; Detail/DeviceChain = device chain; Browser = Live's " <>
      "browser; Detail = the bottom detail panel. Seshat cannot read the " <>
      "currently visible pane, so call this even if the requested pane may " <>
      "already be open; showing it again is harmless. Typical sequences: " <>
      "show Session then launch/stop a clip or scene; show Arranger then " <>
      "change the song loop brace; select the target track (select_track) " <>
      "then show Detail/DeviceChain then change a device parameter — the " <>
      "pane shows the SELECTED track's chain. Skip the pre-show before " <>
      "creates, writes and deletes: those already move the view to their " <>
      "result. Detail/Clip shows whichever clip was last opened there, so " <>
      "use it to re-show recent work, not to aim at a different clip. This " <>
      "only points Live at a pane — it does not select a clip or device and " <>
      "cannot see or verify the screen.",
  parameters: %{
    type: "object",
    properties: %{
      "view" => %{
        type: "string",
        enum: [
          "Browser",
          "Arranger",
          "Session",
          "Detail",
          "Detail/Clip",
          "Detail/DeviceChain"
        ],
        description: "Live's exact pane name"
      }
    },
    required: ["view"]
  }
}
```

Decisions made here rather than deferred:

- **One `view` enum, using Live's values.** Friendly surrogate values would
  require a mapping in the handler and create two vocabularies for six fixed
  strings. The description already teaches the natural-language mapping.
- **All six names are exposed.** `Detail` is less specific than its two child
  panes but is a real Live destination and supports the direct request "show
  the detail panel"; withholding an already-supported value gains nothing.
- **The pre-action rule lives prominently in this description.** It matters
  when deciding to use this particular tool and descriptions have no
  instructions-budget cost. The examples teach intent, not an exhaustive
  allowlist future tools would have to amend.
- **No target coordinates.** `show_view` changes a pane only. Selecting a
  track/scene remains `select_track`/`select_scene`; clip and device selection
  continue to belong to follow cam until a separate user-facing selection
  feature is justified.

### 2. Handle it — `lib/seshat/tools/handlers.ex`

Add one Transport-direct clause at the top of the existing **View selection**
section:

```elixir
defp do_call("show_view", %{"view" => view}) do
  case Transport.send_message("/live/view/show_view", [view]) do
    :ok -> {:ok, "Showing #{view_label(view)}"}
    {:error, reason} -> {:error, inspect(reason)}
  end
end
```

Add a private `view_label/1` mapping for all six enum values so the result
uses the user's vocabulary:

- `Browser` → `"Live's browser"`
- `Arranger` → `"Arrangement view"`
- `Session` → `"Session view"`
- `Detail` → `"the detail panel"`
- `Detail/Clip` → `"the clip editor"`
- `Detail/DeviceChain` → `"the device chain"`

The reply says what Seshat is presenting rather than echoing Live's internal
`Arranger` spelling. Like `set_tempo`, `select_track`, and the other silent
setters, `:ok` means the datagram was accepted by the local transport, not
that Live acknowledged the UI state; the tool description retains the honest
boundary that it cannot verify the screen.

Do not route this through `%Command{}` or `FollowCam`: it is one message, and
it is itself the primitive FollowCam calls. Do not add a read-back or delay
between `show_view` and the next tool call; the address has no reply, and
loopback datagrams are received by AbletonOSC in send order.

### 3. Update the shared visibility convention — `lib/seshat/instructions.ex`

The existing session instruction says:

> The view follows you. What you create, write to, or delete is already
> selected, pane showing.

That describes only post-action follow cam and can lead the model to assume no
pre-action call is needed. Rewrite this bullet compactly to carry both halves:

> The view follows you. Creates, writes and deletes leave what they touched
> selected, pane showing; before other view-specific actions — launching,
> device tweaks, the loop brace — show the pane first so the change happens
> visibly. Say what to look at, never how to navigate there.

This belongs in `Seshat.Instructions` as well as the tool description because
it is a session-wide interaction rule: the user should watch an action happen,
not merely be navigated on explicit request. Keep the whole instruction text
under the measured 2,048-character cap; the existing
`instructions_test.exs` assertion remains the guard. Do not add a brittle test
for exact prose.

No `@agent_specific` change in `Seshat.Agent`: both MCP and API-key modes need
the same behavior, and `Instructions` is their shared source.

### 4. Tests

1. **`test/seshat/tools/definitions_test.exs`**
   - Bump the single tool-count assertion from its value at implementation
     time by one (`53 → 54` if this plan lands against today's surface).
   - Add `show_view` beside `select_track`/`select_scene` in the expected-name
     inventory.
   - The existing schema parity and validation sweeps cover the new enum's
     shape automatically.
2. **`test/seshat/tools/validation_test.exs`**
   - An unknown value such as `"Arrangement"` is rejected with a message
     naming the six allowed values, following the file's existing
     message-text idiom. This pins the important irregularity:
     natural-language "Arrangement" maps to Live's `"Arranger"`.
   - A missing `view` is rejected before dispatch.
3. **`test/seshat/tools/handlers_test.exs`**
   - Add an OSCSink-backed `describe "show_view"` using `setup :osc_sink`.
   - Exercise all six enum values (table-driven is appropriate): each call
     returns `{:ok, message}`, emits exactly
     `{:osc_out, "/live/view/show_view", [view]}`, and its message contains
     the friendly label rather than merely echoing the raw value.
   - One rejection test through `Handlers.call/2` with the sink live: an
     unknown view returns `{:error, _}` and `refute_receive {:osc_out, _, _}`
     proves nothing reached the wire. The "nothing is sent" invariant is
     proved here, where a transport exists — the validation tests above
     assert message text only.
   - No test reaches `Transport.query/3`; the address is a setter and the
     test asserts the outgoing datagram only.
4. **`test/seshat/instructions_test.exs`**
   - No new assertion. Its existing cap and delivery tests are the correct
     coverage for prose edited by judgment; model behavior belongs in the
     smoke test.
5. **Generated MCP parity**
   - `Seshat.MCP.ToolsTest` confirms the new definition becomes an MCP
     component with the enum intact. No hand-written MCP component or server
     registration is added.

### 5. Bookkeeping

- **`docs/TOOL_AUDIT.md`** — add `show_view` to the inventory beside
  `select_track` and `select_scene`, category `Selection`, verdict `Keep`,
  noting that it is explicit navigation plus pre-action visibility and uses
  the already-vendored silent view address. Do not rewrite the dated
  follow-cam history; "No new tools" remains true of that 2026-07-28 change.
- **No change to `abletonosc-api-docs.md`** — the exact address, six values,
  silent behavior, and fork provenance are already documented.
- **No change to `Seshat.Tools.FollowCam` or its tests** — its existing
  post-action contract remains intact.
- **No change to `Session.State` or the LiveView UI** — neither needs to know
  which pane is visible.
- Run `mix precommit` after implementation.

## Testing

Covered without Ableton:

- Definition presence, count, required enum parameter, and generated MCP
  schema parity.
- Central validation refuses a missing or unknown view before a datagram.
- All six exact values and friendly replies are asserted through the
  test-local OSC sink.
- Shared instructions remain below the client truncation cap and reach both
  entry modes through existing tests.

Needs `/smoke-test` with Ableton open because no repository test executes
`Application.View.show_view/1` or can inspect Live's UI:

1. Call `show_view` for each of `Browser`, `Arranger`, `Session`, `Detail`,
   `Detail/Clip`, and `Detail/DeviceChain`; visually confirm each destination.
   In particular, confirm that Live still accepts all six spellings documented
   by the fork.
2. Start in Arrangement and ask naturally to launch a named Session clip.
   Observe that the client calls `show_view(Session)` before `fire_clip`, Live
   shows the grid first, and the launch then happens visibly.
3. Start in Session and ask to change a clip's loop brace or notes. Observe
   that the client needs no pre-show: the existing follow cam leaves the
   edited clip selected in the editor immediately after the write, and no
   `show_view(Detail/Clip)` fires beforehand to display a stale clip.
4. With a *different* track selected, ask to change a device parameter on a
   named track. Observe `select_track` and `show_view(Detail/DeviceChain)`
   before the mutation, so the right chain is on screen when the knob moves —
   this is the one mutation with no follow cam behind it.
5. Start in Session and ask to set the song loop brace. Observe
   `show_view(Arranger)` before `set_loop`, so the brace change is visible.
6. Ask only "show me the timeline" and "show me the notes again"; confirm the
   client uses `show_view` without inventing a follow-up mutation or giving
   keyboard instructions.
7. Repeat a request while its destination is already open; confirm the
   idempotent `show_view` call does not toggle away or disturb selection.

Smoke items 2–6 are model-behavior checks. `mix test` can prove the tool exists
and sends the right datagram, but it cannot prove that the tool description and
shared instruction cause an MCP client to choose the show-first sequence.

## Out of scope

- **Reading the current pane.** No OSC getter exists, and saving one redundant
  idempotent send is not worth a new Python address, listener, or
  `Session.State` field.
- **Automatically injecting a view send into every action handler.** The
  model-driven sequence is the feature; existing post-action FollowCam remains
  the deterministic handler-level safety net.
- **Selecting arbitrary clips or devices on request.** `show_view` opens a
  pane but does not accept track/scene/device coordinates. Add direct
  selection tools separately if a real session demonstrates the need.
- **Verifying what is on screen.** `screenshot_live` remains on the roadmap
  for that.
- **Arrangement editing.** This tool can show Arrangement and makes the
  existing song loop brace visible, but it adds no clip placement, locator,
  automation, or Arrangement-recording operations.
- **Changing the follow-cam inclusion rule or adding an off switch.** Neither
  is needed to expose the already-existing steering primitive.

## Open questions

1. **⚠️ Do all six documented pane names work in the installed Live version,
   and is showing the already-visible pane a true no-op?** The fork's
   `view.py` names `Browser`, `Arranger`, `Session`, `Detail`, `Detail/Clip`,
   and `Detail/DeviceChain`, and the existing follow cam has exercised
   `Session` plus the two Detail children. `Arranger`, `Browser`, and generic
   `Detail` have never been sent by Seshat, while no code or OSC reply can
   reveal whether a pane actually appeared. This could not be resolved from
   the repository because it needs a visual check in live Ableton. **Assumed
   meanwhile:** all six names retain the behavior documented by Live and
   re-showing one preserves selection and stays on that pane. Smoke items 1
   and 7 check both assumptions before the feature is considered complete; a
   failing name is removed from the enum and description rather than hidden
   behind a fallback.

## Approach considered and rejected — target coordinates on `show_view`

A 2026-07-31 plan review proposed a rival shape: optional target parameters on
`show_view`, so that clip focus would send `/live/view/set/selected_clip` +
`/live/view/set/detail_clip` before showing `Detail/Clip`, and device focus
would send `/live/view/set/selected_device` before showing
`Detail/DeviceChain`. The finding underneath it was real and is folded into
this plan: the two Detail panes show a *selected* target, not a global
context, so a bare pre-show can display the wrong clip or the wrong track's
chain while the mutation lands off screen.

The coordinate surface itself was rejected because the corrected pane-only
tool covers every named case with tools that already ship:

- Every clip-mutating tool is already steered by the follow cam, which
  selects the clip, puts it in the Detail view, and shows the pane
  milliseconds after the write. A pre-show before those tools is redundant,
  and this plan now says to skip it.
- `set_device_parameter` — the one mutation the follow cam deliberately does
  not steer — is covered by `select_track` before
  `show_view(Detail/DeviceChain)`: the chain pane shows the selected track's
  devices, so the parameter move is visible.
- What remains unique to the rival is "show me the notes of clip X" for a
  clip the session hasn't recently touched. That needs user-facing clip
  selection — a capability the roadmap entry and this plan's Out of scope
  both defer until a real session demonstrates the need, and one that would
  duplicate the follow cam's steering logic in a second, user-facing place.

Reopen this as a separate selection feature if the untouched-clip case shows
up in real sessions; do not widen this tool's schema for it.
