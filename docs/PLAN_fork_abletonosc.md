# Fork AbletonOSC: own the bridge source, retire the patch-in-place installer

## Context

Seshat currently extends AbletonOSC by patching the user's install:
`mix abletonosc.install` copies four vendored handlers from
[priv/abletonosc/](../priv/abletonosc/) and inserts anchor-based registration
lines into upstream's `__init__.py` and `manager.py`. One of the four,
`track_listeners.py`, is an *override* that only works because `add_handler`
is a dict assignment and the installer anchors our handlers below
`TrackHandler` — an invariant whose failure is invisible.

[fork-options.md](fork-options.md) documented the triggers that would flip
this to a fork. Two have now fired:

- **Trigger #1 (a second override):** upstream PR #213's fix — a one-line
  logger bug in `clip_slot.py` that floods Live's Log.txt with a
  `RemoteScriptError` traceback on *every* clip operation Seshat performs
  (`write_midi_notes`, `delete_clip`, `duplicate_clip`, the `get_clip_slots`
  fallback) — can only be vendored as a second dict-assignment override.
- **Trigger #2 (editing upstream files):** upstream PR #208's resilience fix
  wraps `_call_method`/`_set_property` in the handler base class and adds
  per-message error handling to the OSC server's `process()` tick — code with
  no `add_handler` seam at all. Today one throwing message aborts the rest of
  that tick's queue, which is exactly the shape of `Registry`'s ordered
  multi-message sequences.

Meanwhile upstream is dormant (last merge 2025-11-16, 33 PRs open, some since
2023 — see fork-options.md "State of upstream"), so the fork's ongoing cost —
merging upstream releases — is approximately zero, and waiting for these
fixes to arrive by upgrade is not a strategy.

**The move:** fork `ideoforms/AbletonOSC` to `jpatricknola/AbletonOSC`, fold
our fixes and the valuable community-PR content into the fork's own files,
move our three extension handlers in as normal committed modules, and reduce
`mix abletonosc.install` to locate-and-copy. The override mechanism, the
anchor patching, and `track_listeners.py` all cease to exist.

**Invariant that makes this safe:** the Elixir side does not change, except
for the installer task and test paths. Every existing OSC address, request
shape, and reply shape stays byte-identical — `Handlers`, `Registry`,
`Session.State`, and `Transport` are untouched. The PR review (2026-07-28,
recorded in the conversation that produced this plan) already judged the
community implementations of browser/return-track support inferior to ours;
nothing of theirs replaces ours.

## OSC contract

Existing surface: **unchanged**. Every address currently documented in
[abletonosc-api-docs.md](abletonosc-api-docs.md) — upstream and vendored —
keeps its exact request and reply shapes.

New addresses (all served by the fork; Elixir tools for them are **out of
scope** here — they are roadmap items whose Python half this plan lands):

| Address | Request | Reply | Notes |
|---|---|---|---|
| `/live/clip/quantize` | `track_id, clip_id, grid, amount` | none (method call) | Upstream's generic `_call_method` path: `"quantize"` added to the clip methods list at `clip.py:66`, per PR #198. `Clip.quantize(quantization_grid, amount)` verified against the Live 12.3.6 API stubs (PhotonicVelocity/LiveAPI). **Grid is the `GridQuantization` enum, NOT `RecordingQuantization`**: no_grid=0, g_8_bars=1, g_4_bars=2, g_2_bars=3, g_bar=4, g_half=5, g_quarter=6, g_eighth=7, g_sixteenth=8, g_thirtysecond=9 — so "quantize to 16ths" is grid **8**. No triplet grids; swing comes from the song's `swing_amount`, which quantize honours. Amount is a float, 0.0–1.0 assumed (Live's UI amount is 0–100%); confirm by ear at smoke. The eventual #9 tool must carry this enum in its description. |
| `/live/browser/preview_item` | `uri` | `uri, "ok", name` / `uri, "error", message` | Resolves via the existing cached `_find_item(uri)`; calls `browser.preview_item(item)` (Live API calls proven by PR #204/#192). House envelope rules apply. |
| `/live/browser/stop_preview` | none | `"ok"` | `browser.stop_preview()`. No index → minimal reply, but unlike the index-less getters it still replies `"ok"`, because nothing else confirms the action. |

All three go into the fork **and** into `abletonosc-api-docs.md` in the same
change — `vendored_addresses_test`'s registered→documented check enforces the
browser two; document `/live/clip/quantize` by the same rule even though the
test doesn't sweep upstream prefixes.

Explicitly **not** adopted from PR #208: its reply-to-sender-port routing.
Listener pushes still go to fixed port 11001 regardless, so the one-reader
invariant of [osc-port-contention.md](osc-port-contention.md) stands either
way; changing query routing alone buys nothing and touches reply correlation.

## Part A — Create the fork

1. `gh repo fork ideoforms/AbletonOSC --clone` → `jpatricknola/AbletonOSC`
   (public, as GitHub forks of public repos are). Keep `upstream` as a remote
   (the gh fork clone sets this up).
2. Work directly on `master`. No branch ceremony: upstream is dormant, we are
   the only consumer, and fork-options.md records the merge playbook if
   upstream ever revives.
3. First commit: a `SESHAT.md` at the fork root listing every divergence from
   upstream (the commits of Part B, kept current), so the delta stays
   self-describing — the property the patch-in-place model had and the fork
   otherwise loses. Include the merge-time hazard note: upstream PRs #182/#185
   rename `/live/clip_slot/duplicate_clip_to` → `duplicate_to` with no alias;
   Seshat's `duplicate_clip` tool depends on the old name, so any future
   merge of those PRs must be caught here (the `audit-osc` workflow is the
   verifier).

## Part B — Fork commits (Python)

Ordered; each is one commit with the PR credited in the message where it
borrows one.

### B1. Fix the wrong-object listener unbind in the base class

The bug `track_listeners.py` exists to fix, fixed at the root instead:
upstream's `AbletonOSCHandler._stop_listen` unbinds from the target it is
*handed*, which after an index renumber is the wrong object.

Verified against the installed source (2026-07-28) — the fix is smaller than
this plan first assumed:

- `handler.py`'s `_start_listen` **already stores the target**
  (`self.listener_objects[listener_key] = target`, line 81); `_stop_listen`
  simply ignores it and unbinds from the caller-passed object (line 87–105).
  The base fix is one line at the top of `_stop_listen`'s found-branch:
  `target = self.listener_objects.get(listener_key, target)`.
  `_clear_listeners` already resolves through `listener_objects` and needs
  nothing.
- `track.py`'s mixer listeners (`_start_mixer_listen`/`_stop_mixer_listen`,
  lines 244–274) have two confirmed bugs: they never populate
  `listener_objects` (→ `KeyError` in `_clear_listeners` on script reload
  with any mixer listener active, since it iterates *all* of
  `listener_functions`), and `_stop_mixer_listen` re-resolves the
  DeviceParameter from the passed track (→ wrong-object unbind after a
  renumber). Fix both by adopting the key shape our vendored files already
  use: key mixer listeners as `("value", (*params, prop))`, store the
  DeviceParameter in `listener_objects`, and let `_stop_mixer_listen`
  delegate to the fixed base `_stop_listen` — the base derives the removal
  method name from the key's prop, and `"value"` yields
  `remove_value_listener`, which is correct for a DeviceParameter. That also
  makes `_clear_listeners` handle mixer keys for free.
- **`priv/abletonosc/track_listeners.py` is not ported** — it never enters
  the fork. Our `return_track.py`'s hand-rolled `_stop_listen_stored` is
  redundant under the fixed base class (its keys are already
  `("value", …)`-shaped); simplify it to the base path in the same commit.

### B2. Cherry-pick PR #213 — clip_slot logger fix

`git fetch upstream pull/213/head` and cherry-pick (one-line
`logger.info` format-args fix in `abletonosc/clip_slot.py`). Attribution
comes free with the cherry-pick. Verified 2026-07-28: the buggy line sits
verbatim at `clip_slot.py:21` in current source — the cherry-pick is clean.

### B3. Apply PR #208's resilience pieces (b) and (c)

Hand-applied (the PR bundles them with the rejected port routing; do not
cherry-pick wholesale). Hunk boundaries verified against the PR diff and
current source, 2026-07-28:

- **Take** both `handler.py` hunks: try/except around `_call_method`'s
  `getattr(target, method)(*params)` and `_set_property`'s `setattr`,
  logging the failure instead of raising through the dispatcher.
- **Take** the `osc_server.py` `process()` rewrite: recvfrom-loop with
  per-message try/except, so one failing message no longer aborts the rest
  of that tick's queue. Note it deliberately keeps
  `self._remote_addr = (remote_addr[0], OSC_RESPONSE_PORT)`.
- **Skip** the two `process_message` hunks (they reroute query replies to
  the sender's source port — the rejected piece).
- Commit message credits PR #208 and records that the port-routing part
  was deliberately not taken (link the reasoning: osc-port-contention.md).

### B4. Add `quantize` to the clip methods list (PR #198)

The three-line version: `"quantize"` added to `ClipHandler`'s generic
methods list → `/live/clip/quantize track_id, clip_id, grid, amount` via
`_call_method`. Nothing else from #198 (warp markers, extended notes) — that
is roadmap #5 material for its own plan.

### B5. Move Seshat's extension handlers in as first-class modules

- `priv/abletonosc/browser.py`, `return_track.py`, `song_structure.py` →
  `abletonosc/` in the fork, content unchanged except: header comments
  updated ("Seshat extension, lives in the fork" instead of "installed by
  mix abletonosc.install"), and B1's simplification of
  `return_track.py`'s `_stop_listen_stored` to the fixed base path.
- Register directly: import lines in `abletonosc/__init__.py`, instantiation
  in `manager.py`'s handler list. Position no longer matters (no overrides
  exist after B1) — place them at the end of the list with a one-line
  comment saying order is not load-bearing anymore.

### B6. Add browser preview (PR #204's Live API calls, our shape)

In the fork's `browser.py`: `/live/browser/preview_item [uri]` and
`/live/browser/stop_preview` per the OSC contract above — our cached URI
resolution and reply envelope, their two Live API calls. Verified 2026-07-28
against the Live 12.3.6 API stubs: `Browser.preview_item(item: BrowserItem)`
("Previews the provided browser item") and `Browser.stop_preview()` both
exist. ⚠️ Whether a given preset has an *audible* preview, and the
cue-routing dependency, can only be checked with Live open — smoke item 4,
and the eventual roadmap-#16 tool description must surface the cue caveat.

## Part C — Seshat repo: consume the fork

### C1. Submodule

- Add the fork as a git submodule at `priv/AbletonOSC` (full checkout:
  `manager.py` + `abletonosc/` package). Delete `priv/abletonosc/` (all four
  files) in the same commit.
- Why a submodule and not a committed copy or install-time clone: the tests
  grep the Python source, so it must exist locally and offline; a committed
  copy is a second source of truth that *will* drift; a clone-at-install
  needs the network at exactly the wrong moment. The submodule pins a SHA,
  keeps one source of truth, and the one-user cost ("`git submodule update
  --init` once") is a README line.
- Note for future sessions (goes in CLAUDE.md, Part E): editing bridge
  Python now means committing in the submodule repo and bumping the pin in
  Seshat — two commits, on purpose.
- Worktree caveat: git worktrees (used by `/lifecycle` and worktree-isolated
  agents) don't auto-populate submodules — `git submodule update --init`
  once per worktree, or the Python-grepping tests fail. Goes in the same
  CLAUDE.md note.

### C2. Rewrite `mix abletonosc.install` — locate and copy

[lib/mix/tasks/abletonosc.install.ex](../lib/mix/tasks/abletonosc.install.ex)
keeps its name, CLI shape, probing (`candidate_paths/0`, `locate!/1`), and
the restart-Live guidance; loses all anchor/patch machinery. New behavior:

1. Resolve the target: explicit path arg, else probe. If the probe finds an
   existing AbletonOSC install, that directory is replaced; if it finds
   nothing, install fresh to the first user-library candidate path
   (`~/Music/Ableton/User Library/Remote Scripts/AbletonOSC`).
2. Guard: refuse to replace an existing directory that doesn't look like an
   AbletonOSC install (`manager.py` + `abletonosc/handler.py` present) —
   same check as today — so a mistyped path can't delete something else.
3. Copy `priv/AbletonOSC/` → target, excluding `.git*` and `tests/`.
   Delete-then-copy (`File.rm_rf!` + `File.cp_r!`) so removed files don't
   linger — a stale `track_listeners.py` from the old install must not
   survive, or its import line in the *old* `__init__.py`... moot: the whole
   tree is replaced, which is the point. Refuse to run if the submodule is
   not initialised (empty `priv/AbletonOSC`), with the
   `git submodule update --init` hint in the error.
4. Moduledoc rewritten: what the fork is, that installs are wholesale
   replacement, the submodule prerequisite, and the unchanged restart-Live /
   no-hot-reload caveat.

### C3. Comment sweep

`grep -rn "priv/abletonosc\|track_listeners" lib/ test/ docs/ .claude/
README.md AGENTS.md` and update every hit. Known today: `handlers.ex:947`,
`handlers.ex:1297`, `state.ex:479`, plus the docs/rules files in Part E.

## Part D — Tests

### D1. `test/mix/tasks/abletonosc_install_test.exs` — rewrite

The fixture-patching tests die with the mechanism they test (anchor
insertion, ordering, indentation, manual-instructions fallback — all gone).
New coverage, same fixture-in-tmp-dir approach:

- installs fresh into an explicit path that doesn't exist yet (creates the
  tree; `manager.py` and `abletonosc/handler.py` land) — the probe-fallback
  fresh install isn't testable without faking `$HOME`, so it's covered by
  the same code path via the explicit arg
- replaces an existing install wholesale (plant a `track_listeners.py` and a
  patched `__init__.py` in the fixture; assert both are gone after)
- refuses a non-AbletonOSC existing directory
- is idempotent (second run → identical tree)
- errors helpfully when the submodule is uninitialised

### D2. `test/seshat/osc/vendored_addresses_test.exs` — retarget

The test's two directions (used→registered, registered→documented) survive
unchanged in purpose.

- `@handler_files` → the fork's three Seshat handlers:
  `priv/AbletonOSC/abletonosc/{browser,return_track,song_structure}.py`.
- Drop the entire "track listener override" describe block and
  `track_listeners.py` from the file list — the override no longer exists.
  Its *reason* (Session.State's `@listened_properties` must have working
  listeners) is now guaranteed by B1 in the base class; note that in the
  moduledoc.
- The exact-count assertions update: return/master stays thirteen;
  browser gains `preview_item` + `stop_preview` (add an exact-count test for
  browser while touching this — it had none, and the docs check alone
  doesn't pin removals).
- Registered→documented now also covers the two new browser addresses —
  which forces the abletonosc-api-docs.md update (Part E) or the suite
  fails. Working as designed.
- Add a setup guard: if `priv/AbletonOSC` is empty (submodule not
  initialised), fail with the `git submodule update --init` hint instead of
  an opaque `File.read!` enoent.

### D3. `mix precommit` green, no new test layers

Nothing here reaches `Transport.query/3`. The Python itself is still tested
only by the smoke checklist (house rule).

## Part E — Docs

- **[abletonosc-api-docs.md](abletonosc-api-docs.md):** add the three new
  addresses (contract table above); update the vendored-extensions preamble
  (extensions now live in the fork, not in patch-installed files); add the
  #182/#185 `duplicate_clip_to` rename hazard as a note on that address's
  row, pointing at `SESHAT.md` in the fork and `audit-osc`.
- **[fork-options.md](fork-options.md):** prepend a status banner — decision
  flipped 2026-07-28, triggers #1 and #2 fired (name them), fork lives at
  `jpatricknola/AbletonOSC`, playbook below was executed; keep the body as
  the historical record and the upstream-revival merge playbook.
- **[CLAUDE.md](../CLAUDE.md):** module map — replace the four
  `priv/abletonosc/*.py` rows with `priv/AbletonOSC` (submodule, what it is,
  three Seshat handlers inside) and the rewritten install task row; rewrite
  the "Before using any OSC address" vendored-files paragraphs and the
  "Patch AbletonOSC in place, don't fork it — yet" design bullet (now: "We
  maintain the fork; here's what that means"); add the two-commit
  submodule-edit workflow note.
- **[.claude/rules/osc.md](../.claude/rules/osc.md):** same story — vendored
  addresses now live in the fork; the override rule and anchor-ordering
  warning are deleted; the reply-envelope and `_stop_listen`-correctness
  rules survive (they now describe the base class).
- **[.claude/docs/ableton-osc-reference.md](../.claude/docs/ableton-osc-reference.md)
  and the `/smoke-test`, `/add-tool` skills:** sweep for references to the
  four vendored files / anchor mechanism (C3's grep finds them); the
  smoke-test checklist gains: Log.txt stays clean during clip operations
  (verifies B2/#213), and a quantize + preview spot-check.
- **[ROADMAP.md](ROADMAP.md):** all done at planning time — entry #6 links
  this plan, the quantize (#9) and preview (#16) entries already note their
  Python half lands with #6 (leaving only the Elixir tool), and the #20/#23
  planner notes already read "ordinary fork commits on the fixed base class".
  Nothing left for the implementer here; listed so `/ship` knows the roadmap
  needs no further sweep beyond deleting entry #6.

## Testing

Pure (no Ableton): everything in Part D via `mix precommit`.

Needs Ableton (`/smoke-test` additions, first run after `mix
abletonosc.install` + Live restart):

1. Existing surface intact: `get_session_state` (mirror + listeners),
   `load_device`, `write_midi_notes`, sends/returns tools, delete a track by
   hand in Live's UI and confirm the mirror follows (exercises B1's
   base-class listener fix on the renumber path — the old bug's exact
   reproduction: delete a track, rename another, mirror must stay correct).
2. Log.txt does **not** accumulate `RemoteScriptError` tracebacks during
   clip operations (B2).
3. `/live/clip/quantize` audibly tightens a sloppy test clip (grid 8 =
   sixteenths — the `GridQuantization` enum in the OSC contract); confirm
   amount 0.5 audibly half-quantizes.
4. `/live/browser/preview_item` on a preset with a known preview is audible
   with cue routing up; `stop_preview` stops it (B6).

## Out of scope (and where it lives)

- **Elixir tools for quantize and preview** — roadmap #9 and #16; this plan
  only lands their addresses.
- **PR #89-style chunking of oversized replies** (`get_clip_notes` on dense
  clips) — real but separate; the PR's implementation was judged weak. Fork
  makes a clean home for our own scheme later; not a roadmap item yet.
- **Hotswap audition** (PR #204's `hotswap_target`) — candidate roadmap
  entry, not part of the migration.
- **PR #208's reply-port routing** — deliberately rejected, see OSC
  contract.
- **Warp markers / extended notes** (rest of PR #198) — roadmap #5's plan
  decides.
- **Return/master mixer completeness** — roadmap #21, now implemented as
  ordinary fork commits when picked up.
- **Filing the base-class listener fix as an upstream PR** — optional
  courtesy after the fork lands (fork-options.md's "good citizenship" note);
  never a dependency.

## Open questions

All five original questions were resolved on 2026-07-28, before
implementation started; the answers are folded into the parts above.
Record of resolution:

1. **Base-class fix shape (B1)** — resolved by reading the installed
   source. `_start_listen` already stores the target; the base fix is one
   line in `_stop_listen`, and the mixer path adopts the `("value", …)` key
   shape our vendored files already use (which also fixes a confirmed
   `_clear_listeners` `KeyError` on reload). Details in B1.
2. **`Clip.quantize` signature** — resolved against the Live 12.3.6 API
   stubs. Grid is the `GridQuantization` enum (values in the OSC contract
   table), **not** `RecordingQuantization` — a first web result offered the
   wrong enum, which would have made "quantize to 16ths" silently quantize
   to half notes. Amount 0.0–1.0 assumed from Live's UI; smoke item 3
   confirms by ear.
3. **Preview API** — resolved: `Browser.preview_item`/`stop_preview` exist
   in Live 12.3.6 (API stubs). Only *audibility* (cue routing, whether a
   preset carries a preview) remains, by design a smoke item (4).
4. **Patch cleanliness** — resolved: #213's target line sits verbatim at
   `clip_slot.py:21` (clean cherry-pick); #208's take-vs-skip hunk
   boundaries are identified in B3.
5. **Fork visibility** — decided: public. Nothing sensitive lives in the
   fork, and public keeps the fork relationship and PR-ref cherry-picking.
   Reversible only by delete-and-mirror, so flag before Part A runs if you
   disagree.

The only ⚠️ left in the plan body is preview audibility (B6/smoke 4) —
a verification step, not an unknown that blocks implementation.
