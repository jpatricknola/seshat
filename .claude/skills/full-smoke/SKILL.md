---
name: full-smoke
description: Run every test in docs/smoke-tests/ in one zero-touch sweep — no Live restart, no server restart, no human action. Tests that need any of those are skipped and named, never silently dropped.
disable-model-invocation: true
---

**Read [docs/smoke-tests/README.md](docs/smoke-tests/README.md), then each file
you sweep, and [.claude/skills/smoke-test/SKILL.md](.claude/skills/smoke-test/SKILL.md)
for how to run and judge a test.** Those are the source of truth; this file never
restates a test, only decides *whether* it runs in a zero-touch sweep and *what
stands in* for the parts that normally need a human. If they ever disagree about
how to verify something, they win; fix the divergence there, not here.

Scope is **every file in `docs/smoke-tests/`, regardless of branch** — the current
diff has no bearing on which apply. A sweep updates the `Last run` line of every
test it actually ran; that line is the only record anywhere that the live layer
was exercised, and keeping it current is half the value of running this. Leave it
alone for anything you substituted.

## Ground rules

Out of bounds, without exception: restarting or quitting Ableton Live, toggling
AbletonOSC in Live's preferences, stopping or restarting the Seshat server,
changing audio/hardware routing, any click or keystroke in Live's UI, any judgment
by ear, and any test that needs another client or a fresh conversation (Claude
Desktop). A test gated on one of those is **skipped and named in the report's
Uncovered list with its reason** — the list is a deliverable, not an apology. A
sweep that reports only successes reads as full coverage and quietly retires the
checks nobody ran.

One consequence to internalise: with no reinstall-and-restart, this sweep verifies
**the code Live has loaded**, whatever that is. Preflight establishes whether that
matches the repo; it never tries to change it.

## Preflight (replaces the smoke-test bridge reinstall step)

1. `get_session_state` — must answer *and* show return/master state (the
   "Return/master state unavailable" line means the fork's `return_track.py` isn't
   loaded). An error or timeout: report and stop, exactly as smoke-test's preflight
   says.
2. **Drift check, instead of reinstalling**: `git submodule status` (checked out,
   on the pinned commit), then `diff -rq` between `priv/AbletonOSC/abletonosc` and
   the installed copy under
   `~/Music/Ableton/User Library/Remote Scripts/AbletonOSC/abletonosc`
   (`__pycache__` is the only acceptable difference; probe the other candidate
   paths in `lib/mix/tasks/abletonosc.install.ex` if that one doesn't exist). If
   they differ, **continue the sweep** — but every fork-specific result carries a
   "tested the loaded copy, not the repo" caveat, and the report leads with "run
   `mix abletonosc.install` and restart Live before trusting anything below." Do
   **not** run the install task: writing new files that Live won't reload makes
   disk and loaded code disagree, which is worse than honest drift.
3. **Log.txt baseline**: find the newest
   `~/Library/Preferences/Ableton/Live <version>/Log.txt`, record its current byte
   size. Every later "watch Log.txt" test reads only the tail past this offset.
4. `lsof -nP -iUDP:11000` — the bind test from `network-boundary.md`, free to do
   here: the only AbletonOSC line must read `127.0.0.1:11000`.
5. Session inventory and the scratch-track policy, per smoke-test. Also record
   tempo and time signature — this sweep changes both and must restore them.

## Substitutions — automated stand-ins for the hands-and-ears steps

Each of these **must be recorded in the report as a substitution**, not reported as
the original test having run, and does **not** update a `Last run` line.

- **`bridge.md § The listener rebind, by hand in Live's UI`** → tool-driven:
  create two scratch tracks with distinct names, `delete_track` one,
  `set_track_name` the other, `get_session_state` → every name under the right
  index. The listeners fire on the LOM mutation regardless of who caused it; what
  this loses is only proof that UI-originated edits behave the same.
- **`network-boundary.md § The default reply route is fixed, not last-sender`**
  (needs the server stopped to bind 11001) → that test's own sanctioned fallback:
  a tool-driven listener push travels the same `osc_server.send` default route.
  `set_tempo` is fire-and-forget and the mirror learns the new value *only* from
  Live's listener push to `127.0.0.1:11001`, so a plain `get_session_state` (no
  refresh) showing the new tempo proves the route. The same substitute covers the
  "change tempo or a volume by hand in Live" push test.
- **`clips.md § Quantize lands on 1/16ths, not 1/32nds`** → numeric instead of by
  eye: `write_midi_notes` with starts deliberately off-grid by known offsets, then
  `quantize_clip` with grid `"1/16"` and amount 1.0, then `get_clip_notes` → every
  start on a **0.25-beat** multiple. `undo`, re-run with amount 0.5 → starts
  exactly halfway to the grid. This is *stronger* than the by-eye original; timing
  feel by ear stays uncovered.
- **`devices.md § Parameter 0 is the Device On switch`** → `get_device_parameters`
  read-back of parameter 0 before and after `bypass_device`. The audible drop and
  the dimmed power button stay uncovered.
- **`model-behaviour.md § The instructions arrive, and arrive whole`** →
  mechanical proxy for the length half only:
  `mix run --no-start -e 'IO.puts(String.length(Seshat.Instructions.text()))'` —
  over 2,048 means the tail is being written for nobody, flag it loudly. Whether a
  real client delivers the text stays uncovered.

`views.md` needs no substitution worth the name: `hide_view` and `get_view_state`
read their own panes back, so the visibility matrix and the hide-set test run
fully unattended. The follow-cam sequencing tests in that file are model
behaviour — excluded.

## Excluded outright — the standing Uncovered list

These have no automated stand-in worth the name. Every run's report lists them,
each with its one-line reason:

- **`mirror.md § Nothing is fabricated when Ableton stops answering`** — requires
  Ableton to stop answering, which requires quitting Live or toggling AbletonOSC.
  Its only coverage is the pure formatter tests and whatever run last exercised it.
  Since this is where the 120 BPM / 4/4 / C Major fabrications would return, a
  long-stale `Last run` there is a real risk, not a formality — say so in the report
  rather than listing it and moving on.
- **`model-behaviour.md`, entire, plus `mcp-surface.md § Claude Desktop lists the
  tools at all`** — what the model *says* can only be judged from a fresh
  conversation that received the instructions, in a client this sweep cannot drive.
  That includes the undo-orchestration test, which is the one that failed on
  2026-08-01.
- **`views.md`'s sequencing tests** (show-first, no redundant pre-show, the
  selected-track pane, pure navigation) — model behaviour by another name.
- **`transport.md § The groove dial reads 130% at 1.3`** — reading the Groove
  Pool's Amount dial needs eyes on Live's UI, and assigning a groove needs hands.
- **`undo.md § can_undo=False is reachable at an empty history`** — needs File →
  New Live Set, which discards the open set.
- **`recording.md`, most of it** — the audio take needs an input routed, the
  `will_record_on_start` guard needs a routing no tool can create, and whether a
  take *sounds* right needs ears. Run the fixed-length take, the auto-arm and the
  6/8 length check if a scratch MIDI track is available; name the rest. **This file
  has never had a passing run at all** — say so with the count, per the note below.
- **Everything else by ear** — sound choice, levels, bypass audibility, quantize
  feel, glitches on mid-playback deletes.

**Count the never-run tests.** Any test still reading `*Last run: —*` after the
sweep is unverified rather than merely unswept, and the report states how many
there are and in which files. A sweep that reads as complete while `record_clip`
has never run is exactly what the Uncovered list exists to prevent.

## Run order

Ordering exists to keep state changes from invalidating later tests:

1. Preflight, as above.
2. **`bridge.md`** — the extension answering, the bad-index envelope at every
   depth, the Log.txt tail. The listener rebind is deferred: it deletes a track, so
   it runs near the end, and only substituted.
3. **`mcp-surface.md`** — everything but the Claude Desktop item, via
   `scripts/mcp_call.py`.
4. A generic tool sweep across the surface on scratch tracks, per
   `/write-smoke-tests`'s "Writing a new test" pattern — normal, boundary, invalid,
   every effect read back. Not a file in the folder; it is the cheap breadth pass
   that catches a tool that stopped answering at all.
5. **`catalog.md`** — the ranking tests, judged as conversations. Preview is
   excluded (ears).
6. **`devices.md`** — `Device On` on a stock device and a rack, the stray-track
   guard, the read/write surface on both chains, the mixer setters. Audibility
   items excluded.
7. **`clips.md`** — quantize numerically per the substitution, the loop-pair and
   ordering tests. Audio-clip properties only if an audio clip exists already.
8. **`transport.md`** — swing push and the time signature; restore both. The groove
   dial is excluded.
9. **`views.md`** — the visibility matrix and the hide-set test, both self-checking.
10. **`undo.md`** — granularity and the ordinary-undo report. The empty-history
    boundary is excluded.
11. **`mirror.md`** — the coalescing and degraded-rebuild tests (Live running). The
    dead-Ableton test is excluded outright.
12. **`network-boundary.md`** — the export fixtures, the obsolete path-taking form,
    the listener/decoder traffic pass. The reply-route test is substituted.
13. **`bridge.md`'s listener rebind**, substituted.
14. Cleanup: delete every scratch track/scene/clip, restore tempo and time
    signature, `undo` any in-place edits, remove planted fixtures. Leave the session
    as preflight found it.
15. Update the `Last run` line on every test actually run.

## Report

Smoke-test's reporting rules apply (including the PR-body rule if a PR is open — a
full sweep usually runs on main, in which case the report lives in the
conversation). On top of them, a full-sweep report must contain, in this order:

1. The drift verdict from preflight — one line if clean, the lead paragraph if not.
2. What was exercised and what the read-back showed, per file.
3. **Substitutions used** — each one named as such.
4. **Uncovered** — the standing exclusions above plus anything skipped on the day,
   each with its reason, and the count of tests still reading `*Last run: —*`. This
   section is the reason the sweep can be trusted; it is never empty.

Findings that are real but out of scope go to [docs/ROADMAP.md](docs/ROADMAP.md) as
issues, per smoke-test.
