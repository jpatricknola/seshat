> **Archived 2026-07-31 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. `hide_view` and
> `get_view_state` live in `Seshat.Tools.Definitions` / `Handlers`, alongside
> the fork's `/live/view/hide_view` and `/live/view/get/is_view_visible`
> addresses in `priv/AbletonOSC`'s `abletonosc/view.py`. No follow-up from
> this plan is open on [ROADMAP.md](../ROADMAP.md).

# Plan — Read and hide Live's panes: close the view loop

Roadmap item "Read and hide Live's panes — close the view loop". Two new fork
addresses beside the existing `show_view` — a *replying* visibility getter and
a silent `hide_view` setter — and two new tools, `hide_view` and
`get_view_state`, so Seshat can tell which panes are open and can put one away.

**This plan has a Python half.** Both Live Object Model methods
(`Application.View.is_view_visible(name)`, `Application.View.hide_view(name)`)
are confirmed present in Live 12's own shipped Python (see the roadmap entry
and [evaluating/lom-to-fork-gap-audit.md](../evaluating/lom-to-fork-gap-audit.md))
but have no OSC address in the fork. That means the two-commit fork workflow —
a commit in `priv/AbletonOSC`, then a pin bump here — plus
`mix abletonosc.install` and a Live restart, and **no test in this repo
executes the new Python**: its verification is a `/smoke-test` matter by
construction. The parts below are ordered so the one measurement the roadmap
demands ("establish the real hide set against live Ableton before writing the
enum") happens *before* the Elixir enum is written, not after.

## Context

`show_view` shipped 2026-07-31 able to show a pane and nothing else. Its own
description admits the blind spot — "Seshat cannot read the currently visible
pane, so call this even if the requested pane may already be open" — and
there is no way to hide anything, so "hide the browser, I need the room"
still means reaching for the mouse.

The blindness is worse than an inefficiency:

- `/live/view/show_view` never replies, and — measured during the 2026-07-31
  smoke test — Live does **not** raise on a pane name it doesn't recognise:
  pushing `"NoSuchPane"` past the schema produced no exception, so the fork's
  `try/except` never fired and nothing reached `Log.txt`. The schema enum is
  the only guard, with no diagnostic if a name is ever wrong. A visibility
  read is the only thing that could confirm a pane actually showed.
- The `show_view` smoke section cannot run without a human looking at the
  screen: the 2026-07-31 run confirmed five of six names by eye, and bare
  `Detail` went unconfirmed because hiding the detail panel needed a
  keystroke. The getter turns that section into something Seshat checks
  itself — including, at last, bare `Detail`.
- The model has no honest answer to "what am I looking at?" today: it can
  only guess from where it last pointed the view.

Key constraints research surfaced:

- **`hide_view`'s accepted set is smaller than `show_view`'s six names, and
  the exact set is not knowable from the repository.** Live's own
  `ViewToggleComponent` toggles exactly four names (`Session`, `Detail`,
  `Detail/Clip`, `Browser`); `DetailViewController` hides `Detail`.
  `Arranger` and `Detail/DeviceChain` appear nowhere as hide targets. And
  "hide `Session`" needs defining at all — Session and Arranger are a pair
  occupying the main-view slot, so hiding one presumably just shows the
  other, which `show_view` already does more legibly. `hide_view` will be
  silent like every setter, so a name that does nothing must not be offered:
  the enum ships only names *measured* to hide something (Part 2).
- **`is_view_visible` does accept the sub-view names** —
  `DetailViewController` reads it for bare `Detail` and both
  `Detail/{Clip,DeviceChain}` — so the getter's surface is the full six even
  though `hide_view`'s is smaller.
- **Visibility may be observable but is treated as pollable.** Live's
  `ViewToggleComponent` keeps its buttons in sync via a listener slot, so
  *something* changes observably, but the event name is not recoverable from
  the compiled bytecode and no `add_*_view_*_listener` appears in Live's
  shipped scripts. This plan chooses **query-on-demand** (the clip-grid
  precedent: promote to the push mirror only once usage demands it) and adds
  no `Session.State` field, no listener, and no new push address. That is a
  decision, not an open question — if a listener name is ever established,
  promotion is a separate, later item.
- The existing follow cam and the `show_view` tool keep their fire-and-forget
  contract unchanged. Steering must never fail or delay the tool it follows,
  and `show_view`'s six names are known-good (five confirmed 2026-07-31, the
  sixth confirmed by this item's smoke run); the *new, empirically uncertain*
  surface is `hide_view`, and that is the one that verifies itself by
  read-after — the same house pattern as `delete_device`'s re-count and
  `set_clip_properties`' re-read. Its post-mutation read has its own error
  wording: the existing `query_echoed/4` helper is for pre-mutation guards and
  says "nothing further was sent" on every failure, which would be false once
  `hide_view` is already on the wire.

## OSC contract

Both new addresses are Seshat extensions added to the fork's
[abletonosc/view.py](../../priv/AbletonOSC/abletonosc/view.py), beside
`/live/view/show_view` — upstream has no view-visibility surface at all.

| Address | Request args | Reply | Provenance |
|---|---|---|---|
| `/live/view/get/is_view_visible` | `[view_name]` — one of `"Browser"`, `"Arranger"`, `"Session"`, `"Detail"`, `"Detail/Clip"`, `"Detail/DeviceChain"` | `[view_name, "ok", visible]` with `visible` ∈ {1, 0}, or `[view_name, "error", message]` | **new** Seshat extension, fork `view.py` |
| `/live/view/hide_view` | `[view_name]` — measured hide set: `"Browser"`, `"Detail"` (measured 2026-07-31; Part 2 records the full matrix) | **none, ever** | **new** Seshat extension, fork `view.py` |
| `/live/view/show_view` | `[view_name]` — all six | none, ever | existing, unchanged |

Naming, decided rather than guessed (AbletonOSC's naming is not regular):

- `hide_view` sits at `/live/view/hide_view`, mirroring the precedent in the
  same file — `show_view` is at `/live/view/show_view`, *not* under `set/`,
  because neither is a property write.
- The getter goes under `/live/view/get/` with the LOM method name as its
  leaf: `/live/view/get/is_view_visible`. The selection getters
  (`/live/view/get/selected_track` …) establish the `get/` prefix; using the
  LOM name verbatim keeps the address greppable against Live's API docs.
- The getter follows `return_track.py`'s always-reply-even-on-bad-input
  envelope, echoing the view name the way every other getter echoes its
  index — so an unknown name or a Live API rejection errors immediately
  instead of costing a guard timeout, and silence means exactly one thing:
  the installed AbletonOSC predates these addresses. The boolean is sent as
  an int (`1`/`0`), matching the wire convention (`/live/track/get/mute`
  documents "1=on, 0=off").
- `hide_view` is a setter and stays silent, exactly like `show_view`:
  nothing on the Python side waits on it, and the *Elixir* handler is what
  closes the loop by reading `is_view_visible` afterwards.

Reply shape on an unknown name — **measured 2026-07-31, resolved**: unlike
`show_view`, `is_view_visible("NoSuchPane")` *does* raise inside Live
("The specified View Identifier does not exist"), so the `"error"` arm of the
envelope fires and an unknown name costs a fast error reply, never a guard
timeout. The tool-side enums make this unreachable from the model anyway.

## Numbered parts

### 1. Fork: the two addresses — `priv/AbletonOSC/abletonosc/view.py`, `priv/AbletonOSC/SESHAT.md`

In `ViewHandler.init_api`, beside `show_view`:

```python
def get_is_view_visible(params: Optional[Tuple] = ()):
    view_name = str(params[0]) if len(params) > 0 else ""
    try:
        visible = Live.Application.get_application().view.is_view_visible(view_name)
        return (view_name, "ok", 1 if visible else 0)
    except Exception as e:
        return (view_name, "error",
                "could not read visibility of '%s': %s" % (view_name, e))

def hide_view(params: Optional[Tuple] = ()):
    view_name = str(params[0]) if len(params) > 0 else ""
    try:
        Live.Application.get_application().view.hide_view(view_name)
    except Exception as e:
        self.logger.error("View: could not hide view '%s' (%s). Valid names: %s"
                          % (view_name, e, ", ".join(VIEW_NAMES)))
```

registered as:

```python
self.osc_server.add_handler("/live/view/get/is_view_visible", get_is_view_visible)
self.osc_server.add_handler("/live/view/hide_view", hide_view)
```

Like `show_view`, `hide_view` passes the name through verbatim — the accepted
set is Live's to define and the Elixir schema's to guard, so a name Live
gains later works without a Python change.

**Status (2026-07-31):** exactly this code already sits in the submodule
working tree, uncommitted, and is running in Live — installed with
`mix abletonosc.install` and picked up via `/live/api/reload` (which does
reload an *edited, already-imported* module; the api-docs warning about new
modules and the `clear_api` KeyError hazard stands, and the reload survived
here). What remains of this part is the header-comment rewrite, the
`SESHAT.md` entry, and the two commits.

Consequence of that working-tree state: **`mix test` is currently red by
exactly two `vendored_addresses_test` failures** — the Python now registers
two addresses the canonical docs don't list yet, and the view-handler
exact-list test still pins fourteen addresses. Both are the Part 5 updates
doing their tripwire job, not regressions; they go green when Part 5 lands.
Don't "fix" them by reverting the Python — the installed copy in Live's
Remote Scripts already runs it, and reverting the submodule would silently
diverge the tree from what Live is executing.

Also in this commit:

- **Rewrite `view.py`'s header comment.** It currently documents "two
  addresses in this file are Seshat extensions" and "Both are silent". It
  becomes four addresses, with the distinction spelled out: the two steering
  setters and `hide_view` are silent (a bad name is logged and nothing goes
  on the wire), while `get/is_view_visible` always replies in the ok/error
  envelope, because a caller *does* wait on it and silence must mean only
  "extension not installed".
- **Update `SESHAT.md`'s `view.py` divergence entry** the same way (it
  currently reads "`view.py` — `/live/view/show_view` and
  `/live/view/set/detail_clip`" and "Both are **silent**"). This is the
  fork's canonical divergence list; `vendored_addresses_test` already checks
  `SESHAT.md` records other deviations, and an upstream merge is the
  realistic way these additions get dropped.

Commit and push **inside** `priv/AbletonOSC` (on `master`, not the detached
HEAD `git submodule update --init` leaves — see
[.claude/rules/osc.md](../../.claude/rules/osc.md)). The pin bump in this repo
rides the Part 3–6 commit so the pin and the code depending on it move
together.

### 2. Install and measure — **measured 2026-07-31**, results at the end of this part

`mix abletonosc.install`, restart Live. Then, from `iex -S mix` (the running
server must be stopped first — only one Seshat can read Ableton), run the
measurement matrix through `Seshat.OSC.Transport`:

For each of the six names: `query("/live/view/get/is_view_visible", [name])`,
then `send_message("/live/view/hide_view", [name])`, read again, then
`send_message("/live/view/show_view", [name])`, read again. Record, in this
plan and in `abletonosc-api-docs.md`'s View-extensions prose:

1. **The real hide set** — which names actually flip their own visibility to
   0. Expected from Live's own scripts: `Browser`, `Detail`, `Detail/Clip`;
   expected no-ops or main-view swaps: `Arranger`, `Detail/DeviceChain`,
   `Session`.
2. **What hiding `Session` does** — if it merely swaps the main view to
   Arranger, it is excluded from the tool enum (rule below), because
   `show_view("Arranger")` already does that legibly.
3. **Session/Arranger complementarity** — whether
   `is_view_visible("Session")` and `("Arranger")` are always opposite. If
   so, `get_view_state` can render "Main view: Session" from them and
   `focused_document_view` stays unneeded.
4. **`Detail` vs `Detail/Clip`/`Detail/DeviceChain` semantics** — whether the
   sub-names report "detail pane open *and* that tab active" (expected from
   `DetailViewController`'s usage).
5. **Unknown-name behaviour of the getter** — `is_view_visible("NoSuchPane")`:
   error envelope, or `0`? (⚠️ Open question 2.)
6. **Read-after-write ordering** — a `hide_view` immediately followed by the
   getter must reflect the hide. Expected to hold: AbletonOSC processes
   datagrams sequentially on Live's timer thread, so the read cannot
   overtake the hide. If it measurably doesn't hold, drop the read-after
   verify from Part 4's `hide_view` handler (return the send-only reply)
   rather than adding sleeps. (⚠️ Open question 3.)

**The enum rule, decided now:** a name ships in `hide_view`'s enum only if
the measurement shows `hide_view(name)` turns `is_view_visible(name)` false
*without* merely switching to a sibling main view. A name that does nothing
is not offered — `hide_view` is silent, so a bad value would be an
undetectable no-op forever.

**Measured results (2026-07-31, Live 12 Suite, full six-name snapshot after
every hide/show):**

1. **The real hide set is `Browser` and `Detail`** — the only two names whose
   hide turns their own visibility off without showing a sibling. Every other
   name's hide "works" but is really a swap: hide `Session` shows Arranger,
   hide `Arranger` shows Session (main-view pair), hide `Detail/Clip` flips
   the detail panel to `Detail/DeviceChain` (panel stays open), hide
   `Detail/DeviceChain` flips it back to `Detail/Clip`. By the enum rule the
   enum is `["Browser", "Detail"]` — the expected `Detail/Clip` drops out.
2. **Hiding `Session` is exactly a main-view swap to Arranger** (and
   vice-versa) — excluded, `show_view` does it legibly.
3. **Session/Arranger are complementary in every snapshot taken** — never
   both 1 or both 0 — so `get_view_state` derives "Main view" from the pair
   and `focused_document_view` stays unneeded.
4. **`Detail/Clip` and `Detail/DeviceChain` mean "panel open *and* that tab
   active"**: exactly one reads 1 while `Detail` is 1, both read 0 when the
   panel is hidden, and hiding `Detail` zeroes the active tab with it.
5. **Unknown getter name → error envelope**, "The specified View Identifier
   does not exist" — Live raises, unlike `show_view`'s silent ignore.
6. **Read-after-write ordering holds.** Roughly thirty hide/show sends each
   immediately followed by six getter reads produced zero stale reads —
   Part 4's read-after verify stands as designed, no sleeps.

### 3. Define the tools — `lib/seshat/tools/definitions.ex`

Both join the **View selection** group beside `show_view`. Tool count 58 → 60.

`hide_view` (enum as measured 2026-07-31 — Part 2's matrix is the authority):

```elixir
%{
  name: "hide_view",
  description:
    "Hide a pane in Ableton Live — 'hide the browser, I need the room', " <>
      "'close the detail panel'. Only panes Live can truly put away are " <>
      "accepted: Browser = Live's browser; Detail = the bottom detail panel, " <>
      "whichever editor it is showing. Session and Arranger are the main " <>
      "view and cannot be hidden — switching between them is show_view's " <>
      "job — and hiding Detail/Clip or Detail/DeviceChain would only flip " <>
      "the detail panel to its other tab, so to close the panel hide " <>
      "Detail. After hiding, Seshat reads the pane's visibility back from " <>
      "Live and reports honestly if it is still showing. Bring a pane back " <>
      "with show_view.",
  parameters: %{
    type: "object",
    properties: %{
      "view" => %{
        type: "string",
        enum: ["Browser", "Detail"],
        description: "Live's exact pane name"
      }
    },
    required: ["view"]
  }
}
```

`get_view_state`:

```elixir
%{
  name: "get_view_state",
  description:
    "Report which of Live's panes are visible right now, read directly from " <>
      "Live: the main view (Session or Arrangement), whether Live's browser " <>
      "is open, and whether the bottom detail panel is open and which " <>
      "editor it shows (clip editor or device chain). Use it to answer " <>
      "'what am I looking at?', to decide whether a pane needs showing or " <>
      "hiding, and to confirm a view change actually happened. Reads live " <>
      "state on every call; nothing is cached.",
  parameters: %{type: "object", properties: %{}, required: []}
}
```

`show_view`'s description loses its blind-spot admission. Replace the
sentence "Seshat cannot read the currently visible pane, so call this even
if the requested pane may already be open; showing it again is harmless."
with: "For an explicit navigation request, use get_view_state first when the
pane may already be visible and do not re-show it if it is; for time-sensitive
pre-action steering, show the pane directly — showing an already-open pane is
harmless. get_view_state reads what is visible from Live, and hide_view puts a
pane away." The rest of the description is unchanged.

Decisions made here rather than deferred:

- **A separate `hide_view` tool, not `visible: false` on `show_view`.** The
  two accept different name sets, and `Seshat.Tools.Validation` is
  schema-driven — one tool would need "which names are legal depends on
  another parameter", which JSON Schema can't state and the validator can't
  enforce. Separate tools also mirror the LOM pair and leave the shipped
  `show_view` schema untouched.
- **`get_view_state` is a standalone read, not a line in
  `get_session_state`.** The session-state reply renders the *mirror*, which
  is push-fresh; visibility is query-on-demand wire I/O and would put six
  serialized OSC queries inside every session read, taxing the query queue
  for information most session reads don't want. A model that wants both
  calls both.
- **No `Seshat.Session.State` field, no listener** — see Context; the
  clip-grid precedent applies.
- **No `Seshat.Instructions` change.** Routing "hide the browser" is the
  tool description's job, and it does it without spending the hard-capped
  2,048-character budget. The existing "view follows you" bullet already
  covers show-first sequencing and is untouched.
- **The re-show policy distinguishes direct navigation from action
  steering.** For an explicit "show me the browser"-style request, the model
  reads `get_view_state` when the pane may already be open and avoids a
  redundant show, delivering the roadmap's third user story. For a
  view-specific action, it still sends `show_view` directly before the action:
  six serialized reads merely to avoid one harmless idempotent send would add
  latency to the action and buy no visible change. Part 6 pins both halves.

### 4. Handle them — `lib/seshat/tools/handlers.ex`

Both are single-message/query tools — Transport direct, no `%Command{}`, no
`FollowCam` involvement (`FollowCam` is untouched by this plan).

Add a module attribute beside the other hints:

```elixir
@view_extension_hint "These addresses come from Seshat's AbletonOSC extension — " <>
                       "if this times out, the installed copy may predate them: run " <>
                       "`mix abletonosc.install` and restart Ableton Live."
```

`hide_view` — send, then verify by read-after (the `delete_device` /
`set_clip_properties` precedent: the mutation is silent and a no-op is
plausible, so success is claimed only after Live confirms it):

```elixir
defp do_call("hide_view", %{"view" => view}) do
  with :ok <- Transport.send_message("/live/view/hide_view", [view]),
       :ok <- confirm_view_hidden(view) do
    {:ok, "Hidden #{view_label(view)}. show_view brings it back."}
  else
    {:error, reason} when not is_binary(reason) -> {:error, inspect(reason)}
    {:error, message} -> {:error, message}
  end
end
```

`query_view_visible/1` is `query_echoed("/live/view/get/is_view_visible",
[view], "the visibility of #{view}", @view_extension_hint)` followed by
`truthy?/1`, so it returns `{:ok, boolean}`. The existing helper's echo check
compares with `==`, which works for the string echo exactly as it does for
integer indices, and its reissue-once defence and timeout hint come free. This
helper is used by the read-only `get_view_state` path only.

`confirm_view_hidden/1` uses `Transport.query/3` directly against the same
getter and parses the exact `[view, "ok", flag]` / `[view, "error", message]`
envelope, including the echoed-view check and one-reissue stale-reply defence.
It returns `:ok` only for a false flag. A true flag reports that Live still
shows the pane; a remote error, malformed/mismatched reply, or timeout says the
hide **was already sent** and may have landed but could not be confirmed, and
the timeout includes `@view_extension_hint`. It must not call
`query_echoed/4`: that helper's `remote_error/1`, `guard_timeout_error/2`, and
`stale_reply_error/1` all say "nothing further was sent", which is deliberately
true for guards and false here. This is the same explicit post-mutation split
already documented above `confirm_device_count/2` and
`confirm_device_enabled/3` in the current handler.

`get_view_state` — six `query_view_visible/1` reads (`Browser`, `Arranger`,
`Session`, `Detail`, `Detail/Clip`, `Detail/DeviceChain`), then a **pure,
public** formatter `view_state_summary/1` that takes the name→boolean map
and renders, e.g.:

> Main view: Session. Live's browser: open. Detail panel: open, showing the
> clip editor.

Rendering rules in the formatter: main view from the Session/Arranger pair;
browser open/closed; detail panel closed, or open with its tab named from
the `Detail/Clip` / `Detail/DeviceChain` flags (neither flag true → just
"open"). If Session and Arranger ever read the same value, say so plainly
("Live reports both Session and Arrangement visible") rather than picking
one — the formatter never invents a coherent answer from an incoherent read
(the stop-fabricating rule). Any failed query fails the tool with that
query's error — no partial summaries that look complete.

The first read that times out ends the tool call after one `@guard_timeout`
(2s), so the six sequential queries cost ~milliseconds on loopback in the
installed case and one timeout in the not-installed case.

### 5. Docs and tripwires

- **`docs/abletonosc-api-docs.md`** — two new rows in the View API table
  (marked ⚠️ Seshat extension), and rewrite the "View extensions" prose: it
  currently says "Both are silent" of the two existing addresses; it becomes
  four addresses with the setter/getter split stated, the getter's envelope
  and int-boolean documented, and Part 2's measured hide-set findings
  recorded. `vendored_addresses_test` fails in both directions if the rows
  are missing.
- **`test/seshat/osc/vendored_addresses_test.exs`** —
  - add `"/live/view/get/is_view_visible"` and `"/live/view/hide_view"` to
    `@vendored_view_addresses` (the exact-match list; both literals appear
    in `handlers.ex`, so the "still the ones lib/ sends" direction holds);
  - update the view-handler pin test (currently "registers upstream's twelve
    addresses plus Seshat's two") to the new sixteen-address list and rename
    it accordingly;
  - assert the fork's `SESHAT.md` view divergence entry names both new address
    literals. Existing `SESHAT.md` assertions cover other fork deviations but
    do not cover `view.py`, so updating the prose without this assertion would
    leave the canonical merge record unguarded.
- **`test/seshat/tools/definitions_test.exs`** — count 58 → 60; add
  `hide_view` and `get_view_state` wherever the file inventories names.
- **`.claude/rules/osc.md`** — the bullet "Two view addresses of ours live
  inside upstream's own `view.py`" becomes four, and its "Both are silent"
  sentence gets the same setter/getter split as the API docs (the
  "a vendored getter always replies" rule already covers the new getter —
  point the bullet at it).
- **`CLAUDE.md`** — two factual references say "two view addresses in
  `view.py`" (the module map's submodule row and the "Before using any OSC
  address" list). Update the count and add the two addresses to the
  bulleted address list. (The Current-focus narrative sync happens at
  `/ship` as usual.)

### 6. Rewrite the smoke section — `.claude/skills/smoke-test/SKILL.md`

Replace "If the change touches `show_view`" with a section covering the
whole view surface ("If the change touches the view tools"), rewritten
around the getter so it is **self-checking** — the point of the feature:

1. **Visibility matrix, no human eyes needed.** For each of the six names:
   `show_view(name)` then `get_view_state` confirms it visible;
   for each enum name of `hide_view`: hide, then `get_view_state` confirms
   it gone. This finally confirms bare `Detail` (unconfirmed 2026-07-31)
   without the keystroke that blocked it — hide it with the tool, read it
   back.
2. **Hide-set tripwire.** `is_view_visible` read → `hide_view` → read again
   for every enum name; a name whose visibility doesn't flip means Live's
   hide set moved in this version and the enum needs revisiting (the
   `set_groove_amount` dial-check precedent).
3. **Honest failure, when the old installed copy is available.** Before
   reinstalling during implementation, call `hide_view` and `get_view_state`
   against the still-old AbletonOSC copy and confirm both return the reinstall
   hint after the guard timeout. If the new copy is already installed, name
   this check as not reproduced; do not downgrade and restart Live solely to
   manufacture it. A raw Transport send/query is not a substitute because it
   bypasses the handler wording this item is meant to verify.
4. **Model behaviour** (today's items 2–7 otherwise carry over): "hide the
   browser, I need the room" routes to `hide_view`; "what am I looking at?"
   routes to `get_view_state` and the answer names panes, not tool calls. With
   Browser already open, a repeated explicit "show me the browser" reads the
   state and does not send a redundant `show_view`; show-first sequencing
   before a launch still sends `show_view(Session)` directly, without paying
   for a six-query pre-check before the action.

Also update the cross-reference at the skill's line ~538 (full-sweep list)
if its wording states the old blind-spot rationale.

### 7. `mix precommit`

Compile with warnings-as-errors, format, full suite. The suite greps the
submodule, so it must be at the new pin locally (worktrees:
`git submodule update --init` first).

## Testing

Covered pure, without Ableton:

- Definition presence, count (60), enum shapes, and generated MCP parity
  (`Seshat.MCP.ToolsTest` covers new components automatically; `hide_view`'s
  enum and `get_view_state`'s empty-properties schema both flow through
  `MCP.Schema` — the enum path is proven by `show_view`, and an existing
  no-required-params tool proves the other, but eyeball the generated
  schema once).
- `test/seshat/tools/validation_test.exs` — `hide_view` rejects a name
  outside its enum (e.g. `"Detail/Clip"` — accepted by `show_view` and the
  likeliest wrong guess now that it is measured out of the hide set — and
  `"Session"`) with a message naming the allowed set; missing `view`
  rejected before dispatch.
- `vendored_addresses_test` — both new addresses registered in the Python,
  present in the docs, and still sent by `lib/`; the view-handler exact
  list; `SESHAT.md` mention.
- Pure formatter tests for `view_state_summary/1` in `handlers_test.exs`:
  Session main view, Arranger main view, browser open/closed, detail tab
  naming, the incoherent Session+Arranger read rendered as stated
  uncertainty.
- The `hide_view` clause performs a post-send `Transport.query` confirmation,
  and `get_view_state` performs live queries, so — like `delete_device` and
  `bypass_device`, per the existing comment in `handlers_test.exs` — neither
  is driven through `Handlers.call/2` in tests. Nothing tests through
  `Transport.query/3`.

Needs `/smoke-test` with Ableton open, because no repository test executes
the new Python or can see Live's UI:

- Part 2's measurement matrix (this is *in the implementation path*, not
  just verification — the enum depends on it).
- The rewritten smoke section of Part 6: visibility matrix, hide-set tripwire,
  and model-behaviour items run end-to-end; the honest-failure item runs only
  if the old installed copy is still available before reinstall, otherwise it
  is reported explicitly as not reproduced.
- The reply-shape caveat (unknown-name behaviour of the getter) and
  read-after-write ordering, recorded in the API docs prose.

## Out of scope

- **Promoting visibility into `Session.State` / a push listener.** No
  documented listener; query-on-demand is the decision (see Context).
  Reopen only with an established event name *and* measured read frequency.
- **`focused_document_view`.** Expected redundant with the
  Session/Arranger pair; Part 2 confirms. If complementarity fails, that is
  the moment to add it — as its own small fork addition, not smuggled in
  here.
- **Verify-by-read inside `show_view` or the follow cam.** Both stay
  fire-and-forget: known-good names, and steering must never delay or fail
  the tool it follows. `get_view_state` gives the model an explicit check
  when it wants one.
- **Hiding via keystrokes or AX.** The LOM covers this, which per
  [evaluating/ui-scripting-options.md](../evaluating/ui-scripting-options.md)
  settles the mechanism ("when the LOM exposes an operation, add it to the
  fork instead"). That doc's browser-toggle spike idea can *use* this
  getter later; nothing here depends on it.
- **`screenshot_live`** stays its own roadmap item — this is the cheap exact
  boolean for panes Seshat drives, not open-ended seeing.
- **Other `Application.View` members** (`browse_mode`, `focus_view`,
  `scroll_view`, `zoom_view`) — no user story; stay unbridged per the gap
  audit.

## Open questions

None remain — all three were measured against Live 12 Suite on 2026-07-31,
via the Part 1 Python running in Live (results recorded in Part 2):

1. **The real hide set — resolved.** `Browser` and `Detail` are the only
   true hides; `Session`/`Arranger` hides are main-view swaps and
   `Detail/Clip`/`Detail/DeviceChain` hides are detail-tab swaps, so the
   enum is `["Browser", "Detail"]` — the expected `Detail/Clip` dropped out
   under the enum rule.
2. **Getter behaviour on an unknown name — resolved.** Live raises ("The
   specified View Identifier does not exist"), so the error envelope fires;
   an unknown name is a fast error reply, never a guard timeout.
3. **Read-after-write ordering — resolved, it holds.** Zero stale reads
   across the whole matrix; `hide_view`'s read-after verify ships as
   designed, and its description keeps the "reads the pane's visibility
   back" sentence.
