# Roadmap

The single living list of what to do next — **features, defects, and security
work in one ranked queue.** **The top item is the biggest win, work top to
bottom.** Ranking is **impact-per-effort**: mission impact weighed against cost,
so a medium-impact quick win outranks a high-impact slog. Issue numbers are
ranks, not stable identifiers — when something ships, delete all trace of it from the roadmap and let the rest renumber (the `/ship` skill handles this). If a shipped issue had a
detailed plan doc, move that doc to [archive/](archive/) with a status banner.
Nothing else about a ship stays here — this file documents future work only, and ship history
lives in git, CLAUDE.md's Current focus, and [archive/](archive/). A shipped
thing is mentioned below only where an *open* item needs it as context.

**Cite an item by its title, never by its rank**
A rank is correct only until the next ship, and a stale one doesn't look stale —
it silently points at a different item. Any cross-reference written by rank will quickly become wrong.

**Adding to the roadmap**
Each issue must state the goal and why it's worth building. Where the value is user-visible, an issue also carries **user stories** — concrete moments that show the feature earning its place. Internal plumbing items skip them. An issue should also include context for the plan author — a roadmap entry is **not** an implementation plan. Plans get written per issue (the `/plan` skill) when the work is picked up. 

**[Deliberately not planned](#deliberately-not-planned)**
The section at the end of this file records ideas that were weighed and
declined, each with the condition that would reopen it. Check it before
proposing or re-proposing work.

**One sibling doc holds evidence rather than queue:**

- [SECURITY_BACKLOG.md](SECURITY_BACKLOG.md) — security work. Everything it
  still lists is dormant behind a gate and *not* in this queue: HTTP
  authentication, production binding, rate limiting and the multi-user design
  activate only when something binds beyond loopback or a second person is
  invited.

The canonical OSC address reference is
[abletonosc-api-docs.md](abletonosc-api-docs.md). Check it before using any
address — naming is irregular, and a wrong address fails silently.

---

## #1 · `show_view` — the follow cam can't be asked to look anywhere

**Goal:** a tool that shows a named pane in Live — Session, Arrangement, the
clip's note editor, the device chain, the browser. Use it for explicit
navigation ("show me the arrangement"), but primarily **before a
view-specific action**: show Session, then launch the clip; show the device
chain, then change the device; show Arrangement, then move the song loop
brace. The user should see the action happen in its visual context, not be
told where to look afterwards.

**Why:** it closes a hole in a principle we already committed to. The follow
cam's contract is that the view follows the work and the user is told *what to
look at, never how to navigate there*
([lib/seshat/tools/follow_cam.ex](../lib/seshat/tools/follow_cam.ex),
`Seshat.Instructions`). But that steering happens **after** a limited set of
creates, writes and deletes. Many actions already work without changing panes:
from Arrangement, Seshat can launch a Session clip; from Session, it can change
a device or the Arrangement loop brace. The mutation lands, but the user
cannot watch it. There is also no way to move the view on an explicit request,
so "show me the notes again" falls back to keyboard instructions. Both violate
the same principle: if Live exposes the navigation, Seshat should put the work
on screen itself. Hit on 2026-07-31 while checking a plan's open question: the
Arrangement loop brace was needed and the assistant had to talk the user
through switching views by hand.

**User stories:**
- As a producer looking at Arrangement, when I ask Seshat to launch a clip,
  the Session grid comes up first — I watch the clip fire instead of hearing
  a change I can't see.
- As a producer, when I say "show me the notes again," the clip editor just
  opens; nobody talks me through Tab and keyboard shortcuts.
- As a producer, when Seshat changes a device, the device chain is on screen
  — so I can see, and grab, the knob it just moved.

**Planner notes:**
- **The address already ships** — `/live/view/show_view [view_name]`, our own
  extension in the fork's `abletonosc/view.py`, documented at
  [abletonosc-api-docs.md](abletonosc-api-docs.md). **No Python half, no
  install step.** It takes Live's own pane names: `Browser`, `Arranger`,
  `Session`, `Detail`, `Detail/Clip`, `Detail/DeviceChain`. `FollowCam` today
  sends only three of the six; `Arranger` and `Browser` have never been sent
  by anything.
- So this is one definition plus one handler clause — an enum parameter over
  those six names, and the description's real job is mapping how people
  actually say them ("arrangement", "the timeline", "session", "the grid",
  "the note editor", "the browser") onto Live's spelling, `Arranger`
  included, which nobody says out loud.
- **Show first, act second is the primary contract.** Teach the model to call
  `show_view` immediately before an action with a natural visual home. Seshat
  cannot read the currently visible pane, so make the call unconditionally;
  re-showing an open pane is assumed harmless and is a smoke-test item. This
  is model-driven sequencing in the tool description plus shared instructions,
  not pre-steering copied into every action handler.
- **Keep the existing follow cam.** It remains deterministic post-action
  confirmation and recovery for the mutations it already covers; this tool
  fills the pre-action and explicit-navigation gaps rather than replacing it.
- **Silent, like every view address** — an unknown pane name does nothing and
  replies nothing. The enum is what makes that unreachable; same reasoning as
  `set_time_signature`'s denominator.
- The reply should name the pane in the user's language ("Arrangement view",
  "clip editor"), not echo Live's internal spelling; the silent address cannot
  verify the screen, and `screenshot_live` remains the separate seeing feature.
- Sequenced here because it is nearly free and repairs a stated principle,
  where the items behind it add new capability. It is **not** a substitute for
  `screenshot_live` — that one lets Seshat *see*; this one lets Seshat
  *point*.
- **Plan:** [PLAN_show_view.md](PLAN_show_view.md) (2026-07-31) — one Elixir
  tool over the address that already ships; use it both for explicit navigation
  and immediately before view-specific actions so the user sees the change
  happen, with the existing follow cam retained as post-action confirmation.

## #2 · `start_new_project` — the setup wizard, and prompt budget back

**Goal:** a tool that catches "let's start a new project" / "start fresh" and
runs the opening of a session: report what's in the open set, name any empty
leftover track, and gather the one-line brief (genre, tempo, mood, reference)
its reply asks for. It **reads and guides; it does not mutate** — the actual
work stays with `create_track` / `delete_track`, with the model in the loop.

**Why:** two wins at once. It fixes finding #1 of the 2026-07-28 validation
run ("start a new project" only appended tracks, leaving the default set's
leftovers behind), and it moves that rule off the *instructions* budget,
which is hard-capped — see below. A tool description routes a user utterance
far more reliably than a bullet in a block that gets truncated from the
bottom, and a reply can name the empty track it actually found instead of
asserting a cleanup unconditionally and hoping the model checks.

**User stories:**
- As a producer saying "let's start something fresh," I get a quick read of
  what's in the open set and one question — genre, tempo, mood, reference —
  so the session starts from my idea, not from leftovers.
- As a producer, the default set's empty leftover track gets noticed and put
  to use, instead of new tracks silently piling up beside it.

**Planner notes:**
- **The 2,048-character ceiling is the point.** Claude Desktop truncates
  server `instructions` mid-sentence at 2,048 characters and says nothing
  (measured 2026-07-29; see the comment above `@text` in
  [lib/seshat/instructions.ex](../lib/seshat/instructions.ex)). Tool schemas
  have no such cap — ~36KB ships every request. So moving a rule from the
  instructions into a tool description or reply costs nothing in total
  context and buys room on the one budget that silently drops content.
- **The "New project" bullet is already gone from `Seshat.Instructions`**
  (removed 2026-07-29, ~230 characters back). Nothing states replace-not-append
  until this ships — the model will append tracks, as it did before that rule
  was written. That gap is deliberate: the rule was bought back as budget on
  the assumption this tool follows.
- **No file operations, ever.** Opening or saving a set is a human step —
  Live's save dialog swallows keystrokes and no code should discard a user's
  work. That is settled; see
  [archive/create-project-removal.md](archive/create-project-removal.md).
- **Read-only is what keeps it from repeating history.** Every failure of the
  removed `create_project` came from fire-and-forget mutation through Live's
  post-load settling window. A tool that only reads `Session.State` and
  returns guidance cannot reproduce any of it.
- The default set is now a single blank MIDI track, so "leftovers" is at most
  one track — the reply should say what it found, not describe a mess.
- Trigger phrasing carries the whole routing job now, so the description has
  to cover the ways the intent is actually spoken. Standard `/add-tool`
  discipline, load-bearing here.
- Sequenced above personas: smaller, fixes a named validation finding, and
  frees budget the persona work will want.

## #3 · Devices on return and master tracks — make the sends system self-serve

**Goal:** load, inspect, tweak, bypass, and delete devices on return and
master tracks, and complete the return/master mixer surface (return
pan/mute/solo, master pan, cue volume) in the same pass.

**Why:** `create_return_track` ships an empty return, and every send into it
is silent until the user drops the effect in by hand in Live — the tool's own
description apologizes for it ("Seshat cannot yet load a device onto a return
track"). The 2026-07-31 external tool audit
made this its top recommendation, which is exactly the "real workflow needs
them" condition the Deliberately-not-planned entry for return/master device
loading was waiting on. Absorbs the former "Return/master mixer completeness"
item: same fork file, one package that makes returns first-class tracks.

**User stories:**
- As a producer, "make a reverb return and send the vocal to it" works end to
  end — the return gets a reverb loaded onto it, not an empty track and
  instructions for doing it by hand.
- As a producer, "brighten the reverb" or "mute the delay return" just works,
  the same as it would on any regular track.

**Planner notes:**
- Both halves are ordinary fork commits in files we already own.
  `/live/browser/load_item` (our `browser.py`) resolves its target from
  `song.tracks` only, so loading onto a return/master needs the handler to
  resolve those targets too; device chain read/delete/bypass/parameters on
  returns belong in `return_track.py`, which already owns the return/master
  surface. Two-commit fork workflow, `mix abletonosc.install`, Live restart.
- The mixer half is already scoped: the 2026-07-28 PR review confirmed the LOM
  details — return mute/solo are plain listenable props, master pan is
  `mixer_device.panning`, cue volume is `mixer_device.cue_volume`, and the
  master has no mute/solo/arm.
- Tool-surface decision for the plan: extend the existing device tools with a
  return/master target versus separate return-device tools. The send/return
  tools chose a separate 0-based index space (`return_track` param); follow
  whatever keeps model tool-selection unambiguous.
- When this ships, update the descriptions that state the old limitation:
  `create_return_track` ("cannot yet load"), `delete_device` and
  `bypass_device` ("Regular tracks only").

## #4 · Model-readable rejections for invalid tool parameters in MCP mode

**Goal:** an out-of-range or wrong-typed parameter comes back to the model as
`Seshat.Tools.Validation`'s message — naming the parameter, the bound, the value
it got, and the parameter's own description — in MCP mode as well as API-key
mode.

**Why:** bounds are enforced in both modes now ("Enforce tool ranges and
non-negative indices centrally", shipped 2026-07-30), but in MCP mode Peri
rejects at the wire first, and a Peri rejection is a JSON-RPC error rather than
a tool result. Measured against the running server on 2026-07-30:

- Claude Code surfaced `set_track_pan value: 2.0` to the model as nothing but
  `MCP error -32602: Invalid params` — the explanatory `data.message` never
  reached it.
- That detail is Elixir internals anyway: `expected either {:float, {:range,
  ...}} or {:integer, {:range, ...}}, got: 2.0`, and `should be greater then or
  equal to 0` (Peri's own typo).
- For a nested array it is **empty**: a bad note velocity produces `"notes: "` —
  no note index, no field, no reason.

The designed message reaches the model only in the narrow band where Peri passes
and the central validator catches, such as a non-integer index (`track: 1.5`). A
model that cannot read why its call was refused cannot fix it, and this feature
made refusals far more common than they used to be — previously the bad value
went through to Live.

**User stories:**
- As a producer, when Seshat reaches for an out-of-range value, it reads the
  refusal, corrects the value, and quietly retries — instead of surfacing a
  cryptic "invalid params" failure I'm left to interpret.

**Planner notes:**
- The seam is the generated component in
  [mcp/tools.ex](../lib/seshat/mcp/tools.ex): when Peri's `validate_input`
  fails, run `Seshat.Tools.Validation.validate/2` against the raw params and
  return its message as a tool result instead of letting the protocol error
  through.
- **Keep the bounds in the advertised schema.** That half shipped and is the
  client's only machine-readable contract. This item is about which layer
  *speaks*, not which layer knows.
- Decide the fallback for a violation the central validator does not model (an
  unknown property, a malformed array), where Peri refuses but `validate/2`
  returns `:ok`. Falling back to Peri's text is acceptable; falling through to
  the handler is not.
- Nothing in `mix test` sees this: the suite exercises `Handlers.call/2` and the
  components' `validate_input` separately, never a client's view of a refusal.
  Found by `/smoke-test` on 2026-07-30 and reproducible with a raw MCP
  handshake.

## #5 · Preserve partial agent results at the tool-iteration limit

**Goal:** when `Seshat.Agent` hits `@max_iterations`, return the commands it
already executed and the conversation so far, and surface a warning in the UI.

**Why:** [agent.ex:83-86](../lib/seshat/agent.ex#L83-L86) discards both
`executed` and `messages` and returns a generic error. Nine or ten rounds of
real mutations land, the UI reports an error with no record of them, the
conversation isn't kept, and the obvious user response — retry — repeats
everything. Partial side effects go invisible exactly when recovery information
matters most.

**User stories:**
- As a producer in the browser UI, when a long exchange dies at the iteration
  limit, I can still see which changes already landed in my set — so hitting
  retry doesn't blindly repeat nine rounds of mutations.

**Planner notes:**
- Scoped to API-key mode, which is the dev/fallback path — that is why it ranks
  here and not higher. The fix is small and the failure is silent, which is the
  combination worth clearing.
- The LiveView error branch leaves history unchanged; both halves need doing or
  neither helps.
- From the 2026-07-29 external review, accepted as written.

## #6 · `undo` can revert far more than the last action

**Goal:** either make single scripted actions land as separate Live undo
steps, or make Seshat's `undo` tool honest about what it is actually about to
revert.

**Why:** smoke-testing `quantize_clip` on 2026-07-31 found that a single
`undo` call after `create_track` → `write_midi_notes` reverted the *entire
track*, not just the last write — reproduced three times, including with
5-second pauses inserted between every step to rule out Live batching
rapid-fire calls into one undo group. It reproduces with zero `quantize_clip`
calls in the sequence, so this is not something that feature introduced; it
is how Live's own undo history groups mutations driven by a control-surface
script, or a fork/AbletonOSC behavior in front of it. A user who asks to
"undo the quantize" after a short multi-step exchange could silently lose an
entire track's worth of work instead.

**User stories:**
- As a producer who says "undo the quantize" after a few minutes of
  back-and-forth, only the quantize is reverted — or Seshat warns me it's
  about to take the whole track with it, before anything is lost.

**Planner notes:**
- Open research question, not a confirmed fix: check whether the Live Object
  Model exposes `Song.begin_undo_step()`/`end_undo_step()` (or equivalent) to
  a Remote Script, and whether wrapping each `/live/...` handler call in the
  fork in its own step actually separates them — the 5-second-pause
  reproduction suggests grouping may not be about call timing at all, so this
  may not be fixable from the fork's side.
- If no fix is available at the Python/LOM layer, the fallback is honesty
  rather than silence: `undo`'s tool description and/or `Seshat.Instructions`
  should say plainly that one `undo` may revert more than the most recent
  visible action when several mutations happened in quick succession.
- Reproduction: `create_track` → `write_midi_notes` (any notes) → `undo` →
  the track is gone, not just the clip's notes. No quantize step needed.

## #7 · Make catalog persistence atomic and report write failures

**Goal:** a reindex that cannot be persisted says so, and a crash mid-write
cannot leave a truncated `catalog.json`.

**Why:** [catalog.ex:831-838](../lib/seshat/library/catalog.ex#L831-L838) logs a
write failure and then returns `{:ok, summary}` — the UI reports success while
the next start restores an old or empty catalog. `File.write/2` is not atomic.

**User stories:**
- As a producer, if a reindex couldn't be saved I'm told right then — not
  left to discover at the next launch that search has been answering from an
  old library.

**Planner notes:**
- Write to a temporary file, sync, rename — then report durable success.
- **Skip the ETS generation swap.** The review also flagged that
  `:ets.delete_all_objects/1` before `insert_all` lets a concurrent search see an
  empty table. Real, but reindex is a rare user-initiated operation that freezes
  Live's UI for up to a minute and that the user is waiting on; a few
  milliseconds of empty results inside that window is not observable.
- **Do this in one pass with "Catalog staleness check"** — same writer, and that
  issue needs a built-at timestamp written there anyway.
- From the 2026-07-29 external review; the durability half accepted, the ETS
  generation swap declined above.

## #8 · Catalog staleness check — reindex without being asked

**Goal:** a free freshness check — does `catalog.json` exist, and is its
build timestamp newer than the mtime of Ableton's browser database? Run it
at server startup and/or on `search_library` calls; when the catalog is
missing or stale, tell the user a reindex is needed and will take up to a
minute (Live's UI freezes), then run it.

**Why:** 2026-07-28 validation run: the script literally has the *user*
asking whether an index exists yet — backwards. The user shouldn't need to
know indexing exists. The check costs two file stats; the expensive rebuild
stays announced and cause-driven instead of manual or unprompted.

**User stories:**
- As a producer who just installed a new Pack, Seshat notices its index is
  stale, tells me a one-minute refresh is coming, and runs it — I never have
  to know indexing exists.

**Planner notes:**
- `catalog.json` needs a built-at timestamp if the merge writer doesn't
  already record one — which is why this pairs with "Make catalog persistence
atomic".
- The Ableton DB path comes from `Seshat.Library.AbletonDB` (per-machine;
  the Windows caveat stays with "Deliberately not planned", not this issue).
- Decide the surfacing point: a line in `search_library` replies, a startup
  check, or both.

## #9 · Verify destructive mutations before reporting success

**Goal:** destructive and structural operations check their target before
mutating and confirm the result afterward, instead of returning success as soon
as `:gen_udp.send/4` returns.

**Why:** Python catches Live API exceptions and only logs them, so a rejected
delete or a dropped packet is indistinguishable from a successful one — and the
follow cam then steers to a destination that may not exist. The reachable
trigger is a stale model-held index.

**User stories:**
- As a producer, when a delete never actually happened in Live, Seshat says
  so — instead of confirming success and steering my view toward a track
  that doesn't exist.

**Planner notes:**
- **Keep ordinary parameter setters fire-and-forget.** The review's headline
  recommendation — structured acknowledgements from every mutation endpoint —
  is rejected: it reverses the settled rule in
  [.claude/rules/osc.md](../.claude/rules/osc.md) ("Setters stay silent — each
  is guarded by its getter first, and nothing waits on one"), and adds a
  round-trip to every mutation, adding load to the query queue that now
  serializes every OSC request.
- The pattern already exists: `delete_device` bounds-checks then verifies by
  re-count, `set_clip_properties` verifies each write by re-read. Extend that to
  the remaining destructive operations and stop.
- Ranked here rather than higher because the surface is broad — this is the
  slog of the correctness items.
- From the 2026-07-29 external review; the verify-before-mutate half accepted,
  structured setter acknowledgements rejected above.
- **Fold in the `remove_notes` footgun fix** (2026-07-31 external tool
  audit): with no range given it silently deletes every note in the clip. Require an explicit range or `all: true`
  before a full wipe — the same principle (destructive intent must be
  explicit), a few lines in `Definitions` + `Handlers`, and small enough to
  ride along here (or as a drive-by before this item is picked up) rather
  than rank on its own.

## #10 · Catalog vocabulary — read tag axes, teach the menu proactively

**Goal:** read the tag *axes* (Character, Genres, Type, …) and the
preset→device relation out of Ableton's database, and surface the real
vocabulary proactively in tool replies — so the model sees the menu before
ordering, instead of guessing tags and learning only from failures.

**Why:** this is levers №1+№2 of
[sound-search-options.md](sound-search-options.md) — read that doc before
planning; it grounds every claim in measurements. The top of the search
funnel leaks first-attempt vocabulary misses ("warm" isn't a tag here, `Soft`
is), and the axes fix real traps the flat tag list creates (`Distortion` the
device tag vs. `Distorted` the character tag). Highest certain win left in
the catalog area, at Low/Low-Med effort. №2 also enables future levers, which
is why they ship together.

**User stories:**
- As a producer asking for "a warm pad," the first slate is right because
  Seshat already knows this library's word for it is `Soft` — it sees the
  menu before ordering instead of guessing and learning from misses.
- As a producer asking for "something distorted," I get presets with a
  distorted *character*, not everything touched by the Distortion *device* —
  the axes keep those apart.

**Planner notes:**
- The axis lives in `files.parent_id`, which
  `Seshat.Library.AbletonDB.read_tags/1` currently discards; the
  preset→device map is the `file_devices` table (4,535 rows on the dev
  machine).
- Vocabulary is per-machine (depends on installed Packs) — it must flow
  through replies/catalog data, never be hardcoded in a tool description.
  That rule already governs `search_library`'s design.
- Requires a catalog rebuild (`reindex_library`) — fine, just say so; no
  migration shims (see CLAUDE.md).

## #11 · Producer personas — switchable musical taste

**Goal:** layer a *persona* — musical taste, and only taste — onto the base
session instructions. Personas live one per file in [priv/producers/](../priv/producers/)
(five stubs exist; `mona_dust.md` is the default); the default composes onto
`Seshat.Instructions` at the same seam `Seshat.Agent.system_prompt/0` already
uses, and a `load_producer` tool (plus `list_producers`) switches mid-session:
"load me Volt Kessler" changes the session's whole aesthetic.

**Why:** taste as a feature instead of a wording debate: different producer,
different palette, same tools. The split is strict (Patrick, 2026-07-29):
personas carry *only* aesthetic taste — sonic palette, genre instincts.
Everything behavioral — slate style, opinionatedness, register, the
"my gut for an 86 BPM lo-fi track…" voice from the 2026-07-28 run — lives in
the base text ([lib/seshat/instructions.ex](../lib/seshat/instructions.ex),
shipped 2026-07-29) and stays consistent across personas. Swapping producers
changes what Seshat reaches for, never how it works.

**User stories:**
- As a producer, "load me Volt Kessler" changes what every following pick
  reaches for — a different palette, same tools, no re-explaining a whole
  aesthetic in every prompt.
- As a producer with a direction of my own, my stated taste still leads; the
  persona only fills in where I haven't said anything yet.

**Planner notes:**
- **MCP `instructions` are delivered once, at initialize** — mid-session
  switching cannot go through that channel. It must be a tool whose *reply*
  carries the new persona into context and states that it supersedes the
  previous one; that reaches the model identically in both modes. API-key
  mode can additionally swap for real, since `system_prompt/0` composes per
  call.
- Personas are musically expressed, never machine-specific — "warm and
  dusty," not tag names; the model maps taste onto this machine's library via
  `search_library`'s replies. Same rule that governs tool descriptions.
- **The taste hierarchy (Patrick, 2026-07-29): the user's communicated taste
  always leads; the persona is the *default* — the prior that fills in when
  the user hasn't said yet.** The base text's voice section is already
  written as read-and-execute-the-user's-taste, so a persona slots in
  underneath it; add one line to the base stating the hierarchy when this
  ships.
- Flesh the five stubs out from one sentence to a real (but short) voice each
  — a persona rides on top of the base text in every session's context.
- **Constant iteration is the expected mode** (Patrick, 2026-07-29): personas
  will be dialed in mid-work based on responses, so `load_producer` must read
  the persona file from disk at call time — edit the file, re-invoke the
  tool, and the new text lands in context with no recompile, restart, or
  reconnect. Do not compile personas in. (The base text will be iterated
  even more, but its loop is connect-bound regardless — instructions are
  delivered at initialize. If the recompile step in that loop grates,
  `Seshat.Instructions.text/0` can trivially become a runtime file read;
  decide when the friction is actually felt.)
- Decide persistence: does a chosen producer survive reconnect (a small file
  under `~/.seshat/`, still not a database) or reset to the default each
  session?
- The groundwork is already in place, from the session-instructions work
  (shipped 2026-07-29): the composition seam is
  `Seshat.Agent.system_prompt/0`, the 2,048-character delivery ceiling and its
  proof are recorded in
  [archive/PLAN_mcp_server_instructions.md](archive/PLAN_mcp_server_instructions.md),
  and the base text's voice section already reads as execute-the-user's-taste,
  which is what a persona slots underneath.

## #12 · `screenshot_live` — let Seshat see the screen

**Goal:** capture Live's window (macOS `screencapture` targeted by window
ID) and return the image in the MCP tool result, so the client model —
already vision-capable — can look at the actual UI when the user asks about
it.

**Why:** 2026-07-28 validation run: "why can't I see the notes?" — OSC is
blind to presentation. The mirror knows session *state*, never what's on
screen (focused view, open dialogs, browser panes), so UI questions today
get guesses. Trigger is user UI questions, not routine post-action use —
the follow cam (shipped 2026-07-29) covers that.

**User stories:**
- As a producer asking "why can't I see the notes?", Seshat looks at my
  actual screen and answers — instead of guessing from mirrored state that
  can't see a dialog, a collapsed pane, or where focus went.

**Planner notes:**
- Verify Anubis supports image content in tool results (the MCP spec does).
- Downscale before returning — full-res screenshots are token-expensive.
- One-time macOS Screen Recording permission for the BEAM process; capture
  works occluded but not minimized.
- API-key mode would need image blocks threaded through `Seshat.Agent`'s
  loop — decide whether to support it there or keep this MCP-only.

## #13 · Restart the MCP supervisor after abnormal failure

**Goal:** change the nested MCP supervisor's child spec from
`restart: :temporary` to `:transient`.

**Why:** [application.ex:80](../lib/seshat/application.ex#L80) means an abnormal
exit permanently removes MCP service while the Phoenix endpoint keeps looking
healthy — the tools simply stop existing, with nothing saying why.

**Planner notes:**
- **`:transient`, not `:permanent`.** The review offered `:permanent` first;
  that would take the whole application down when Anubis genuinely cannot
  start, which is very likely why `:temporary` was chosen. `:transient`
  restarts on abnormal exit only, which is exactly the case described.
- One line. Do it in passing while touching `application.ex` rather than
  scheduling it.
- Raised as a speculative risk by the 2026-07-29 external review — the failure
  has not been reproduced, only reasoned from the child spec.

## #14 · Search eval harness — numbers before opinions

**Goal:** a repeatable harness that scores `search_library` relevance against
a fixed set of realistic "describe a sound" queries, so every further catalog
lever gets measured instead of argued.

**Why:** lever №9 of [sound-search-options.md](sound-search-options.md),
estimated at a morning's work. It exists to **gate the catalog levers below it**:
after "Catalog vocabulary" lands, the eval decides whether any of the remaining
catalog levers are still worth buying. Sequenced after "Catalog vocabulary"
because that one is a certain win with or without numbers.

**Planner notes:** the result-quality work already used a six-query/77-slot
benchmark informally (see
[archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md));
formalize that rather than inventing a new one. Runs offline against the
catalog — no Ableton needed.

---

**Gate: the six issues below are catalog levers that wait on "Search eval
harness".** Buy each only if the eval still shows the miss it targets after
"Catalog vocabulary" lands. They're ranked by
[sound-search-options.md](sound-search-options.md)'s impact-per-effort ordering.

## #15 · Widen the search slate at tied score bands

**Goal:** when the score band straddling the result cut is large (the ~46
identical-tag `E-Piano *` presets), show more of the band rather than
pretending rank means something inside it.

**Why:** lever №4 — a presentation fix for ranking headroom that scoring
provably can't close (a graded per-term variant measured +1 slot across six
queries and was rejected). Hours of work, honest fix.

**User stories:**
- As a producer choosing an e-piano, when dozens of presets score
  identically, I see the honest breadth of the tie — not an arbitrary top
  five pretending rank means something inside it.

## #16 · Accepted-search memory

**Goal:** remember what a description resolved to — "this request led to this
accepted preset" — and let it bias future rankings.

**Why:** lever №8. `use_count`/recency already bias rankings, but the
description→preset association is thrown away today. Compounds over time; a
personal tool can afford a personal memory.

**User stories:**
- As a producer who settled on a particular preset for "dusty keys" last
  week, the same request surfaces it first this week — my accepted picks
  teach the search what my words mean.

**Planner notes:** this is the one catalog feature that wants a write-side
store. Keep it out of the read-only catalog file — a separate small file
under `~/.seshat/` — and it is still not a database (see CLAUDE.md).

## #17 · Browser preview audition

**Goal:** play a preset's browser preview instead of loading it, so the agent
can flip through ten candidates in the time one heavy preset takes to
instantiate.

**Why:** lever №6 — the lighter cousin of the shipped audition loop
(`delete_device`/`bypass_device`). Metadata will never distinguish two `Soft`
pads as well as ten seconds of audio. Explicitly sequenced after the eval:
better search may make it unnecessary.

**User stories:**
- As a producer torn between two `Soft` pads the tags can't tell apart, we
  flip through their browser previews and pick by ear — ten candidates
  auditioned in the time one heavy preset takes to load.

**Planner notes:** the fork already ships `/live/browser/preview_item` and
`/live/browser/stop_preview`; what remains here is the Elixir tool. The
preview plays through Live's cue channel — the tool description must
surface that audibility depends on cue routing.

## #18 · Opt-in `samples` index

**Goal:** index the `samples` category (3,567 items) into the catalog,
returned **only** when `category: samples` is explicitly requested.

**Why:** lever №7, the only category still invisible — "a vinyl crackle" is
unfindable while `Crackle Vinyl Pop.wav` sits in the browser. Sample uris
carry FileIds, so tag-awareness comes free.

**User stories:**
- As a producer asking for "a vinyl crackle," the sample that's sitting
  right there in Live's browser is actually findable — today no search can
  reach it.

**Planner notes:** samples is why `EXPORT_CATEGORIES` excludes it and the
20k-node scan cap exists — measure the walk cost first. Keeping samples out
of default results is a hard requirement so the preset slate stays clean.

## #19 · LLM enrichment at reindex

**Goal:** generate tags/descriptions for untagged and third-party items at
reindex time, using an API key or an MCP-client-driven tagging turn.

**Why:** lever №5 — highest ceiling (it attacks the thin-signal problem
directly: ~200 of 5,795 entries say anything real about their sound) and
highest cost. Last resort: buy only if the search eval still shows first-slate
misses on thin-tagged entries after everything above. Concrete evidence from
the 2026-07-28 validation run: for "warm, slightly out-of-tune electric
piano," the character lived only in preset *names* — E-Piano Rusty, Old
School, MKII Old, Cheap were invisible to tag scoring because no warm/aged/
detuned vocabulary exists to carry them.

**User stories:**
- As a producer asking for "a warm, slightly out-of-tune electric piano,"
  the presets whose character lives only in their names — E-Piano Rusty,
  MKII Old — finally rank on their sound instead of their tag luck.

## #20 · User XMP tags

**Goal:** read the user's own tags from
`User Library/Ableton Folder Info/12/`.

**Why:** user-authored tags are the highest-precision signal a personal
library can have; currently ignored. Small, but only matters once the user
actually tags things — hence the low rank.

**User stories:**
- As a producer who has tagged parts of my own library, those tags count in
  search — they're the most precise signal about my sounds that exists.

---

## #21 · Cap large tool-result payloads in API-key mode

**Goal:** bound what accumulates in `Seshat.Agent`'s `messages` and the
LiveView's log for the life of a conversation.

**Why:** full tool inputs and outputs accumulate unbounded, and catalog and
device results are exactly the payloads large enough to matter — a single local
user can exhaust the Anthropic context window on `search_library` output alone,
and LiveView process memory grows with it.

**Planner notes:** capping large tool-result payloads before they enter
`messages` is the cheap majority of the fix; skip summarising old turns until
needed. MCP mode is primary and keeps no history in this process, which is why
this ranks here. Raised as a speculative risk by the 2026-07-29 external review
— reasoned from the code, not reproduced.

## #22 · Read-only audio input display — warn before a silent take

**Goal:** surface a track's audio input routing, read-only, so `record_clip`
can warn when an audio take is about to record nothing.

**Why:** `record_clip`'s description admits Seshat "cannot choose or check
the input," so an audio take is a coin flip on whether anything was routed —
a silent take discovered after the fact. Upstream already has every address
needed (`/live/track/get/input_routing_type` / `_channel` and the
`available_*` lists — no fork change). Raised as a Medium gap by the
2026-07-31 external tool audit; ranked
here rather than higher because audio recording is a side path in a
MIDI-first workflow and the failure it prevents is recoverable and already
documented in `record_clip`'s description.

**User stories:**
- As a producer setting up a guitar take, Seshat tells me "that track is
  listening to Ext. In 3/4" — or that no input is routed — before recording,
  instead of us finding a silent clip after.

**Planner notes:**
- Read side only. The write side (`/live/track/set/input_routing_*`) stays in
  the grab bag — that's where the sharp edges are.
- Smallest version: `record_clip` reads the routing before firing on an audio
  track and names it in the reply. Decide whether it's also worth a line in
  `get_session_state` before building more surface than the warning needs.
- Routing values are strings from Live's own menus; report them verbatim,
  don't interpret.

## #23 · Device list per track in session state

**Goal:** mirror each track's device chain in `Seshat.Session.State`, so the
agent sees loaded devices without a `get_track_devices` round-trip.

**Why:** device-chain reads are frequent (every load/delete/bypass verifies
by re-read), and the session-state mirror is push-fresh for everything else.
Quality-of-life multiplier for the now-complete device workflow — but the
gain is latency and tokens, not user-visible experience, hence the rank.

**Planner notes:** needs device add/remove listeners per track — check what
upstream offers before assuming a new handler is required. The clip-grid
precedent applies (see the "Clip grid in session state" note): query-on-demand
shipped first, promotion to
push state only once usage justified the subscription surface. Usage now
plausibly does; confirm before building. These listeners are index-keyed —
the fork already fixes the wrong-object unbind in the handler base class, so
any listener work here is an ordinary fork commit, no override gymnastics.

## #24 · Modify a note in place

**Goal:** edit one note's velocity/length/pitch directly instead of
read → remove range → rewrite.

**Why:** the current path works but is three calls and a footgun
(`remove_notes` ranges). Cleaner, not urgent.

**User stories:**
- As a producer saying "make the third note a little quieter," that's one
  clean edit — not a read, a range delete, and a rewrite that can clip the
  notes around it.

## #25 · Clip grid in session state — only if usage demands it

**Goal:** promote the clip grid from on-demand (`get_clip_slots`, shipped)
into push-fresh `Session.State`.

**Why (conditional):** clip-slot listeners are a large subscription surface
(tracks × scenes × properties). The standing decision
([archive/PLAN_clip_slot_state.md](archive/PLAN_clip_slot_state.md)) is to
wait for evidence the grid is read constantly. Session record has now shipped
alongside `capture_midi`, so the trigger this item was waiting on has
happened — worth checking whether grid-read frequency actually justifies the
subscription surface before building it. Index-keyed listeners, like the
device-chain mirror's — these are ordinary fork commits on the fixed base class.

## #26 · Small OSC breadth — grab bag

Individually tiny, none blocking a workflow; pick up opportunistically:

- **Track color** — `/live/track/set/color_index [track_id, 0-69]`. Low
  value for AI control.
- **MIDI mapping** — `/live/midimap/map_cc`. Power-user feature.
- **Beat listener** — `/live/song/start_listen/beat` for sync/visualization.
- **Groups · routing/IO · automation** — grouping tracks, input/output
  routing & monitoring, automation envelopes. (The read-only input *display*
  graduated to its own item, "Read-only audio input display"; the write side
  stays here.)
- **Sends on return tracks** (return→return routing, feedback sends) —
  niche, needs Live's "sends only" awareness, no named workflow yet.
- **Groove Pool assignment by index** — `Clip.groove` is unserializable over
  the wire, but a fork handler could assign it Python-side from
  `song.groove_pool.grooves[i]`, which would make `set_groove_amount` live in
  Seshat-only sessions. Niche until a user actually has grooves in their
  pool; recorded so the "groove amount is inert" audit finding doesn't get
  re-litigated.

## #27 · MCP mode in the browser UI

**Goal:** give `AssistantLive` a second backend — headless Claude Code
(`claude -p`) as a subprocess consuming Seshat's own `/mcp` endpoint — so the
browser UI runs off a Claude subscription instead of an API key, with a
per-conversation toggle.

**Why:** removes the API-key requirement from the only mode that needs one.
Designed but never built; ranked low because MCP mode already serves the
project's one user.

**User stories:**
- As a producer using the browser UI, my Claude subscription covers the
  conversation — no API key to provision just to chat with my own set.

**Planner notes:** full design (milestones, streaming UI, tested CLI flags
that may have drifted) in
[archive/PLAN_mcp_browser_ui.md](archive/PLAN_mcp_browser_ui.md) — verify the
CLI flags against current Claude Code before trusting it.

## #28 · Adopt MCP `2026-07-28` when Anubis supports it

**Goal:** serve MCP's stateless `2026-07-28` protocol over both Streamable HTTP
and stdio while retaining legacy compatibility for as long as clients need it.

**Why:** `2026-07-28` removes the `initialize` / `notifications/initialized`
handshake and `Mcp-Session-Id`, moves version and client capabilities into
per-request `_meta`, adds mandatory `server/discover`, requires
`Mcp-Method` / `Mcp-Name` HTTP headers and `resultType` on results, and makes
list responses cacheable. Claude support began rolling out on 2026-07-28.
Seshat is currently pinned to `anubis_mcp` 1.10.0, whose newest supported
protocol is `2025-11-25`; current dual-era clients can fall back to that legacy
flow, so this is not an active break.

**Planner notes:**
- Wait for an Anubis release with native `2026-07-28` support; do not implement
  the wire protocol inside Seshat. The existing `~> 1.10` constraint may admit
  a later 1.x release, leaving only a lock update plus any new transport option.
- Prefer dual-era operation initially. A modern-only client cannot use the
  current server, while a dual-era client probes `server/discover` and falls
  back to legacy initialization.
- Seshat's application state already lives outside MCP transport sessions:
  tools delegate to `Seshat.Tools.Handlers` and do not use the per-client Anubis
  frame. No tool or OSC redesign should be needed.
- Verify that `Seshat.MCP.Server.server_instructions/0` reaches the
  `server/discover` result. The new protocol retains `instructions`, but today
  Anubis emits them from the legacy initialize response and this guidance is
  load-bearing.
- The SDK should own per-request `_meta`, standard HTTP headers, `resultType`,
  cache fields, version errors and discovery dispatch. Seshat's static tool
  list is already deterministic and does not vary by connection.
- Keep the current GET/SSE path while supporting legacy clients; modern
  `2026-07-28` replaces the standalone GET stream with
  `subscriptions/listen`. Revisit the router comments and
  `Seshat.MCP.LogFilter` after the Anubis upgrade.
- Authorization changes do not apply while Seshat remains unauthenticated and
  loopback-only. Tasks, roots, sampling, elicitation and MCP logging are not
  used here.
- Add wire-level tests for `server/discover`, a direct stateless `tools/list`
  and `tools/call`, required response fields, HTTP headers, instructions, and
  legacy fallback. Existing MCP tests cover component parity and the
  instructions callback, not transport negotiation.
- Primary references:
  [release overview](https://blog.modelcontextprotocol.io/posts/2026-07-28/),
  [key changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
  [discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
  and
  [version compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).


---

## Deliberately not planned

- **Deployment-gated security work** — HTTP authentication on `/mcp` and the
  LiveView, production binding, rate limiting, and the multi-user design
  question. Not in this queue by design; see
  [SECURITY_BACKLOG.md](SECURITY_BACKLOG.md) for the two triggers that activate
  them. Note that authentication alone does not make Seshat multi-user — one
  transport, one mirror, one Ableton.
- **The vendored Python test harness reloads AbletonOSC on import.**
  `priv/AbletonOSC/tests/__init__.py` sends `/live/api/reload` at module level,
  outside any fixture, so even `pytest --collect-only` reloads the Remote Script
  in a live session. Declined 2026-07-30: it is upstream's harness and we never
  run it — `mix test` only *greps* the vendored Python
  (`vendored_addresses_test`), and nothing here invokes `pytest`. Fixing it
  means carrying a divergence in a file we do not execute through every upstream
  merge. Instead: don't run `pytest` against a Live session that matters.
  **Reconsider if** we ever adopt the Python suite as part of our own
  verification.
- **`pythonosc`'s dispatcher has an invalid escape sequence.**
  `priv/AbletonOSC/pythonosc/dispatcher.py` uses `'[\w|\+]*'`, which emits a
  `SyntaxWarning` and treats `|` as a literal class member. Declined 2026-07-30:
  this is `pythonosc` vendored inside AbletonOSC vendored inside our fork — two
  levels from code we own — and editing it buys one silenced warning for a
  `SESHAT.md` divergence entry and a merge conflict surface. **Reconsider if**
  an Ableton release bumps the bundled Python to a version where this is an
  error, or if the file needs changing for another reason — then fix it in
  passing. Upstream `pythonosc` is the right owner.
- **A PubSub restart would leave `Session.State` permanently unsubscribed.**
  State subscribes only in `init/1`, and it is a `:one_for_one` sibling of
  `Phoenix.PubSub`, so a PubSub restart leaves it registered in a dead registry
  and deaf to OSC broadcasts. The mechanism is real. Declined 2026-07-30 because
  the offered fix is worse than the disease: `:rest_for_one` at
  [application.ex:39](../lib/seshat/application.ex#L39) would, given the current
  child order, restart Transport, Session.State, Catalog, the MCP supervisor
  **and the Phoenix endpoint** on any PubSub blip — a guaranteed heavy failure
  traded for a hypothetical one. `Phoenix.PubSub` crashing is close to unheard
  of. **Reconsider if it is ever actually observed**, and then take the targeted
  option: monitor PubSub and re-subscribe after replacement.
  `get_session_state`'s `refresh: true` is already a manual backstop for a
  mirror that has gone stale for any reason.
- **The monitored refresh worker for `Session.State`** — an overall deadline
  plus freshness/connection/last-error metadata, the larger half of the
  2026-07-29 review's session-refresh finding. Only the fabricated-defaults half
  shipped (2026-07-30); refresh still runs sequential synchronous OSC calls
  inside the GenServer. Deferred, not declined: the blocking window is short and
  has never been observed, and the OSC query queue changed the contention
  picture anyway. **Reconsider if the blocking window is ever actually seen.**
- **Arrangement view** — everything Seshat does is Session view. Upstream has
  arrangement addresses (`/live/track/get/arrangement_clips/*`, arrangement
  overdub, song position) — revisit if a real workflow needs the timeline.
- Device *reordering* (removal & bypass
  shipped — see `delete_device`/`bypass_device`), rack inner chains, parameter
  listeners (live meters/automation following) — revisit if a real workflow
  needs them. (Return/master-track device loading was listed here until
  2026-07-31, when its revisit condition fired — see "Devices on return and
  master tracks" in the queue.)
- Embeddings or a semantic index for the catalog — the LLM is already the
  semantic layer and has the musical context.
- Replacing AbletonOSC with a Max for Live WebSocket bridge — weighed and
  declined in [bridge-options.md](bridge-options.md); reopen only if a Remote
  Script fundamentally can't do something we need.
- **Machinery around the fork's two known soft spots** (recorded 2026-07-28
  with the fork itself): a pre-push guard for an unpushed `priv/AbletonOSC`
  commit behind a bumped pin (today it surfaces only as a confusing CI
  checkout failure), and a mechanical check that the fork's `SESHAT.md` stays
  current (a missing divergence entry is invisible until the next upstream
  merge). Both are covered by prose in `/implement` and `/pr-review`; neither
  is worth automating while upstream is dormant and there is one committer.
  Reopen if a merge actually goes wrong because of one.
- Anything related to Windows. It would be nice for this to work on a windows machine,
  but currently we are not focused on this.
