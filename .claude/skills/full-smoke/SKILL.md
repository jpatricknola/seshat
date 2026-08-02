---
name: full-smoke
description: Run every section of the smoke-test checklist in one zero-touch sweep — no Live restart, no server restart, no human action. Checks that need any of those are skipped and named, never silently dropped.
disable-model-invocation: true
---

**Read [docs/live-invariants.md](docs/live-invariants.md) in full, and
[.claude/skills/smoke-test/SKILL.md](.claude/skills/smoke-test/SKILL.md) for how
to run and judge a check.** Those two are the source of truth; this file never
restates a check, only decides *whether* it runs in a zero-touch sweep and *what
stands in* for the parts that normally need a human. If they ever disagree about
how to verify something, they win; fix the divergence there, not here.

Scope is **every section of `live-invariants.md`, regardless of branch** — those
checks are standing properties, so the current diff has no bearing on which
apply. Feature-specific checks in `docs/PLAN_*.md` are **out of scope**: they are
acceptance tests for one change, and `/smoke-test` on that change's branch is
where they run.

A sweep updates each swept section's `Last verified` line — that line is the
only record anywhere that the live layer was exercised, and keeping it current
is half the value of running this. Leave it alone for any section you
substituted rather than ran.

## Ground rules

Out of bounds, without exception: restarting or quitting Ableton Live, toggling
AbletonOSC in Live's preferences, stopping or restarting the Seshat server,
changing audio/hardware routing, any click or keystroke in Live's UI, any
judgment by ear, and any check that needs another client or a fresh
conversation (Claude Desktop). A check gated on one of those is **skipped and
named in the report's Uncovered list with its reason** — the list is a
deliverable, not an apology. A sweep that reports only successes reads as full
coverage and quietly retires the checks nobody ran.

One consequence to internalise: with no reinstall-and-restart, this sweep
verifies **the code Live has loaded**, whatever that is. Preflight establishes
whether that matches the repo; it never tries to change it.

## Preflight (replaces the smoke-test bridge reinstall step)

1. `get_session_state` — must answer *and* show return/master state (the
   "Return/master state unavailable" line means the fork's `return_track.py`
   isn't loaded). An error or timeout: report and stop, exactly as smoke-test's
   preflight says.
2. **Drift check, instead of reinstalling**: `git submodule status` (checked
   out, on the pinned commit), then `diff -rq` between
   `priv/AbletonOSC/abletonosc` and the installed copy under
   `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC/abletonosc`
   (`__pycache__` is the only acceptable difference; probe the other candidate
   paths in `lib/mix/tasks/abletonosc.install.ex` if that one doesn't exist).
   If they differ, **continue the sweep** — but every fork-specific result
   carries a "tested the loaded copy, not the repo" caveat, and the report
   leads with "run `mix abletonosc.install` and restart Live before trusting
   anything below." Do **not** run the install task: writing new files that
   Live won't reload makes disk and loaded code disagree, which is worse than
   honest drift.
3. **Log.txt baseline**: find the newest
   `~/Library/Preferences/Ableton/Live <version>/Log.txt`, record its current
   byte size. Every later "watch Log.txt" check reads only the tail past this
   offset, so pre-existing noise never masquerades as a finding.
4. `lsof -nP -iUDP:11000` — the bind check from the network-boundary section,
   free to do here: the only AbletonOSC line must read `127.0.0.1:11000`.
5. Session inventory and the scratch-track policy, per smoke-test. Also record
   tempo and time signature — this sweep changes both and must restore them.

## Substitutions — automated stand-ins for the hands-and-ears steps

Each of these **must be recorded in the report as a substitution**, not
reported as the original check having run.

- **Listener fix "by hand in Live's UI"** → tool-driven: create two scratch
  tracks with distinct names, `delete_track` one, `set_track_name` the other,
  `get_session_state` → every name under the right index. The listeners fire
  on the LOM mutation regardless of who caused it; what this loses is only
  proof that UI-originated edits behave the same, so say so.
- **`/live/test` direct reply-route check** (needs the server stopped to bind
  11001) → the smoke-test's own sanctioned fallback: a tool-driven listener
  push travels the same `osc_server.send` default route. `set_tempo` is
  fire-and-forget and the mirror learns the new value *only* from Live's
  listener push to `127.0.0.1:11001`, so a plain `get_session_state` (no
  refresh) showing the new tempo proves the route. Same substitute covers the
  "change tempo or a volume by hand in Live" push checks.
- **Quantize "by eye"** → numeric: `write_midi_notes` with starts deliberately
  off-grid by known offsets, then `quantize_clip` with grid `"1/16"` and amount
  1.0, then `get_clip_notes` → every start on a **0.25-beat** multiple (a
  0.125 spacing means a 1/32 grid was sent — that is the enum regression the
  measured table exists to catch). `undo`, re-run with amount 0.5 → starts
  exactly halfway to the grid. This is *stronger* than the by-eye original;
  timing feel by ear stays uncovered.
- **`Device On` audibility** (tripwire 4) → `get_device_parameters` read-back of
  parameter 0 before and after `bypass_device`. The audible drop and the dimmed
  power button stay uncovered.
- **Groove dial and `hide_view` flip** (tripwires 2 and 3) → `hide_view` reads
  its own pane back through `get_view_state`, so tripwire 3 runs fully
  unattended. The groove dial cannot: reading 130% off the Groove Pool needs
  eyes on Live's UI, and assigning a groove needs hands. Report tripwire 2 as
  uncovered, not substituted — there is no stand-in for reading a dial.
- **Instructions delivery and the 2,048-character truncation** → mechanical
  proxy: `mix run --no-start -e 'IO.puts(String.length(Seshat.Instructions.text()))'`
  — over 2,048 means the tail is being written for nobody, flag it loudly.
  Whether a real client actually delivers the text stays uncovered.

## Excluded outright — the standing Uncovered list

These have no automated stand-in worth the name. Every run's report lists
them, each with its one-line reason:

- **"The mirror never fabricates", entire** — requires Ableton to stop
  answering, which requires quitting Live or toggling AbletonOSC. Its only
  coverage remains the pure formatter tests and whatever run last exercised it.
  Since this is where the 120 BPM / 4/4 / C Major fabrications would return, a
  long-stale `Last verified` on that section is a real risk, not a formality —
  say so in the report rather than listing it and moving on.
- **"Model behaviour", entire, plus the MCP surface's Claude Desktop item** —
  what the model *says* can only be judged from a fresh conversation that
  received the instructions, in a client this sweep cannot drive. That includes
  the undo-orchestration probe, which is the one that failed on 2026-08-01.
- **Bridge integrity item 4 in its real form** — the listener rebind performed
  by hand in Live's UI. The substitution covers the LOM path only.
- **Measurement tripwires 2 and 5** — reading the Groove Pool's Amount dial
  needs eyes on Live's UI and assigning a groove needs hands; `can_undo` at an
  empty history needs File → New Live Set, which discards the open set.
- **Everything else by ear** — sound choice, levels, bypass audibility,
  quantize feel, glitches on mid-playback deletes.
- **Everything in
  [docs/PLAN_backfill_live_verification.md](docs/PLAN_backfill_live_verification.md)**
  — checks whose feature shipped before they ever ran. Most need the ears,
  hands or hardware routing this sweep excludes by definition, so it does not
  attempt them. **Name the file and the count of outstanding checks in the
  report**, per feature. This is the one exclusion that is not merely "we
  couldn't": these are unverified rather than merely unswept, and a sweep that
  reads as complete while `record_clip` has never run is exactly what the
  Uncovered list exists to prevent.

## Run order

Ordering exists to keep state changes from invalidating later checks:

1. Preflight, as above.
2. **Bridge integrity** — items 1 and 2 (the extension answering, the bad-index
   envelope at every depth). Item 4, the listener rebind, is deferred: it
   deletes a track, so it runs near the end, and only in its substituted form.
3. **The advertised MCP surface** — items 1–4 via `scripts/mcp_call.py`. Item 5
   (Claude Desktop) is excluded outright.
4. A generic tool sweep across the surface on scratch tracks — normal /
   boundary / invalid, every effect read back. Not an invariants section; it is
   the cheap breadth pass that catches a tool that stopped answering at all.
5. **Catalog ranking** — all four, judged as conversations.
6. **Measurement tripwires** — item 4 (`Device On`) on a stock device and a
   rack; item 6 (stray-track guard); item 1 (quantize spacing) numerically per
   the substitution above; item 3 (`hide_view`), which self-checks. Item 2
   (groove dial) and item 5 (`can_undo` at an empty history, which needs File →
   New Live Set) are excluded outright.
7. **OSC network boundary** — item 1 (`lsof`, already done in preflight), item 3
   (obsolete export form, Log.txt tail as the observable), item 4 (the
   listener/decoder traffic pass). Item 2 needs Seshat stopped: substituted.
   Also run the export-fixture cleanup check here — plant stale + fresh in
   `~/.seshat/browser-exports/`, backdate the stale one, `reindex_library`,
   verify, then delete the surviving fresh fixture yourself.
8. **Bridge integrity item 4**, substituted (see below).
9. Cleanup: delete every scratch track/scene/clip, restore tempo and time
   signature, `undo` any in-place edits, remove planted fixtures. Leave the
   session as preflight found it.
10. Update the `Last verified` line on every section actually run.

## Report

Smoke-test's reporting rules apply (including the PR-body rule if a PR is
open — a full sweep usually runs on main, in which case the report lives in
the conversation). On top of them, a full-sweep report must contain, in this
order:

1. The drift verdict from preflight — one line if clean, the lead paragraph
   if not.
2. What was exercised and what the read-back showed, per section.
3. **Substitutions used** — each one named as such.
4. **Uncovered** — the standing exclusions above plus anything skipped on the
   day, each with its reason. This section is the reason the sweep can be
   trusted; it is never empty.

Findings that are real but out of scope go to [docs/ROADMAP.md](docs/ROADMAP.md)
as issues, per smoke-test.
