---
name: full-smoke
description: Run every section of the smoke-test checklist in one zero-touch sweep — no Live restart, no server restart, no human action. Checks that need any of those are skipped and named, never silently dropped.
disable-model-invocation: true
---

**Read [.claude/skills/smoke-test/SKILL.md](.claude/skills/smoke-test/SKILL.md)
in full before doing anything.** That file is the single source of truth for
what each check is and how to judge it — this one never restates a check, only
decides *whether* it runs in a zero-touch sweep and *what stands in* for the
parts that normally need a human. If the two ever disagree about how to verify
something, the smoke-test skill wins; fix the divergence there, not here.

Scope is **everything, regardless of branch**: run every section of the
checklist, not just the ones the current diff touches.

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
- **Non-4/4 recording check** → set the song time signature by raw send-only
  OSC — `/live/song/set/signature_numerator` and
  `/live/song/set/signature_denominator` (both canonical; see
  [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md)) — using the
  send-only Python client pattern from smoke-test so nothing binds 11001.
  Confirm the mirror saw the change (that's a listener-push check for free),
  run the recording checks that need 4/4 in 4/4 and the two-bars-in-6/8 check
  in 6/8, then restore the original signature the same way.
- **Quantize "by eye"** → numeric: `write_midi_notes` with starts deliberately
  off-grid by known offsets, then `quantize_clip` with grid `"1/16"` and amount
  1.0, then `get_clip_notes` → every start on a **0.25-beat** multiple (a
  0.125 spacing means a 1/32 grid was sent — that is the enum regression the
  measured table exists to catch). `undo`, re-run with amount 0.5 → starts
  exactly halfway to the grid. This is *stronger* than the by-eye original;
  timing feel by ear stays uncovered.
- **Preview audibility** → send `preview_item` / `stop_preview` raw and verify
  what is checkable: nothing added to the set (`get_session_state`,
  `get_track_devices`) and a clean Log.txt tail. Whether it *sounds* is
  uncovered — cue routing is a hands-and-ears matter.
- **Bypass/delete device audibility** → `get_device_parameters` read-back of
  parameter 0 before and after, reply-vs-fresh-read agreement for
  `delete_device`. The audible drop, the dimmed power button, and
  click-on-delete-while-playing stay uncovered.
- **Instructions delivery and the 2,048-character truncation** → mechanical
  proxy: `mix run --no-start -e 'IO.puts(String.length(Seshat.Instructions.text()))'`
  — over 2,048 means the tail is being written for nobody, flag it loudly.
  Whether a real client actually delivers the text stays uncovered.
- **Audio recording headline** → run the take on an audio track and verify a
  clip exists with the right length; whether it contains audible material
  depends on input routing Seshat can neither see nor set — uncovered.

## Excluded outright — the standing Uncovered list

These have no automated stand-in worth the name. Every run's report lists
them, each with its one-line reason:

- **The whole Session.State failure-path section** — requires Ableton to stop
  answering, which requires quitting Live or toggling AbletonOSC. Its only
  coverage remains the pure formatter tests and whatever run last exercised it.
- **Claude Desktop** — tool-list acceptance and instruction delivery in the
  one client with a history of failing quietly. Needs a fresh conversation
  there.
- **The session-guidance behaviour probes** — what the model *says* can only
  be judged from a separate conversation that received the instructions.
- **Everything by ear** — sound choice, levels, bypass audibility, preview
  audibility, quantize feel, glitches on mid-playback deletes.
- **Guards needing routing or track types no tool creates** — the
  unrouted-input `will_record_on_start` guard and the group-track arm guard.

## Run order

Ordering exists to keep state changes from invalidating later checks:

1. Preflight, as above.
2. Bridge liveness: the bad-index envelope checks (immediate error naming the
   real count, never a ~2s timeout) on the vendored getters.
3. MCP schema section: the raw `tools/list` handshake against
   `http://localhost:4000/mcp` from smoke-test, count matched to
   `Definitions.all()`. (No schema changed; this is the baseline that the
   advertised surface is intact.)
4. The generic tool sweep — smoke-test's "Exercise the change" pattern
   (normal / boundary / invalid, read every effect back) applied across the
   tool surface, on scratch tracks.
5. Catalog section (the conversation-shaped search checks, judged as
   conversations).
6. Device tools section, on a stock device and a rack loaded via
   `load_device`; plugin coverage only if one is already in the set.
7. Clip-properties section, including the §05 aliasing wart check.
8. Quantize section (numeric, as above), then the one remaining no-tool-yet
   address: preview (as above).
9. Recording section — 4/4 checks, then the 6/8 check via the signature
   substitution, then restore the signature.
10. Network-boundary section: export fixtures (plant stale + fresh in
    `~/.seshat/browser-exports/`, backdate the stale one, `reindex_library`,
    verify, then delete the surviving fresh fixture yourself), the obsolete
    path-taking export form by raw OSC with the Log.txt tail as the observable,
    and the push-route substitution.
11. The tool-driven listener-fix check (it deletes a track, so it lives near
    the end).
12. The Elixir listener/decoder pass — the normal-session traffic list from
    smoke-test's network item 7, then Seshat's own log output: zero occurrences
    of either `Dropped OSC` line.
13. Cleanup: delete every scratch track/scene/clip, restore tempo and time
    signature, `undo` any in-place edits, remove planted fixtures. Leave the
    session as preflight found it.

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
