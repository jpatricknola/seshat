# Validation script — thoughts and findings

Run date: **2026-07-28**. Fresh run from Part 1, evaluated live with Claude.

First run since two relevant changes shipped after the 2026-07-27 run:

- **Push-based session state** (#21) — Part 1's "What's in the session?" is a
  direct re-test of the stale-mirror failure (7 tracks reported after 4 were
  hand-deleted).
- **`create_project` removed** — Part 1's "start a new project" now resolves to
  `create_track` calls against the open set; Seshat should say it can't open a
  fresh set rather than silently reinterpreting.

Classification per the script: **Broken** (claimed success, Live didn't change),
**Wrong** (something happened, but not what was asked), **Judgement** (worked,
but musically poor).

---

## Part 1 — Open the set

**Prompt 1 — "Let's start a new project. Make me three MIDI tracks."**
Result: three tracks created and named correctly, but the default set's one
leftover "1 MIDI" track stayed and Patrick had to ask separately to remove it.
Classification: **Wrong** (mild) — the mechanical work succeeded, but "start a
new project" carries the intent *replace what's here*, and Seshat only
appended. It has the session state to see that the remaining track is an empty
default; it should have deleted it (after creating the new ones — Live requires
at least one track) or at least offered to.

Context noted during the run: `create_project` was removed deliberately
(closing the open set → save prompts → too fragile), and the Ableton default
set was pared down to one MIDI track + Main to approximate a blank slate. So
the fix here is guidance, not a new tool.

**Prompt 2 — "What's in the session right now?"**
Result: **PASS**, no notes. Significant: this was the 2026-07-27 run's stale
session-state failure (7 tracks reported after hand-deletions), and it's the
direct re-test of the push-based session state work (#21). The fix holds.

**Prompt 3 — "86 BPM + metronome on"**
Result: **PASS**, no notes. (Also passed last run.)

**Open design thought (Patrick):** the starting state leaves a lot to be
desired. A "new project" moment could be richer — let the user give a
free-form description of the song they're imagining, or ask a few kickoff
questions (genre, tempo, key, reference) whose answers then steer everything
downstream (`search_library` choices, tempo, track layout). Worth a roadmap
think — see improvement ideas below.

## Part 2 — Find sounds

**Prompt 2 — "Warm, slightly out-of-tune electric piano for Keys — what have
I got?"**
Result: **PASS**, near-ideal. Four real Core Library presets (E-Piano
Detuned / Moody / Rhodish / Muted Pure), each with a one-line reason tied to
the lo-fi / 86 BPM context, a recommendation, and it asked before loading.
Notably, the #20 catalog work was visibly functioning: two `search_library`
calls, with "No 'Warm' tag exists in your library" showing the
facet/diagnose feedback teaching the model the real tag vocabulary and the
model adjusting instead of returning nothing.

**Slate accuracy audit (Claude, against the full catalog):** pool is ~50
electric-piano candidates (33 named E-Piano + Wurli/FM/Synth Piano tagged
`Electric Piano`). The top two surfaced picks are the two objectively best
matches in the library: E-Piano Detuned (only name encoding "out-of-tune",
Electric physical model) and E-Piano Moody (the *only* EP tagged
`Lofi & Vinyl` — most on-genre choice that exists). Factual claims about
devices checked out. Weak fourth pick: Muted Pure ("Pure" contradicts the
ask) over stronger aged-character candidates — E-Piano MKI Mellow, MKII Old,
Rusty, Old School, Cheap, Wurli Soft. Root cause: no warm/aged/detuned tags
exist; that character lives only in preset *names*, which scoring can't see —
direct evidence for ROADMAP #17 (LLM enrichment at reindex; evidence now
cited there). Verdict ~8/10:
optimal head, soft tail, diversification across engines (Electric/Drift/
Analog) visibly working. Minor: claimed Muted Pure is "tagged Analog" —
Analog is its device, not a tag.

**Prompt 3 — "Load the second one."**
Result: **PASS** — correct instrument loaded onto Keys, no notes.

**Positive signal (Patrick):** the closing recommendation paragraph ("My gut
for an 86 BPM lo-fi track: E-Piano Moody for instant vibe, or E-Piano Detuned
if you want the out-of-tune quality front and center… I can also stack a
touch of chorus/vinyl…") is the target behavior: opinionated with a musical
trade-off, asks before loading, and proactively offers the next production
move. The scored/diversified slate is what makes that opinionatedness
possible — keep this shape as the reference example for search replies.

**Judgement finding (Patrick):** opening the reply with "No 'Warm' tag exists
in your library" leaks catalog plumbing to the user — the musician asked a
musical question and doesn't know or care what a tag is. The diagnose/facet
text did its real job (steering the model's retry) but shouldn't have been
relayed. Fix in the tool layer: have `search_library`'s diagnostic text (or
the tool description) mark itself as internal — "use this to refine your
search; present results musically, don't mention tags to the user."

## Part 3 — The first idea

_(pending)_

## Part 4 — Bass and drums

_(pending)_

## Part 5 — Editing what's already there

_(pending)_

## Part 6 — Building an arrangement

_(pending)_

## Part 7 — Mixing

_(pending)_

## Part 8 — Making a mess and cleaning it up

_(pending)_

## Part 9 — Wrap up

_(pending)_

---

## Summary

### Broken

_(none yet)_

### Wrong

_(none yet)_

### Judgement

- Part 2, EP search: relayed "No 'Warm' tag exists in your library" to the
  user — tag plumbing surfacing in a musical conversation. Fix: mark
  `search_library`'s diagnostic text as model-internal.
- Off-script, "why can't I see the notes?": manual UI instructions assume Live
  fluency — "Tab to Session View" is opaque if you don't know Tab is a
  keyboard toggle or what Session View looks like. When Seshat hits a
  limitation and must talk the user through a manual step, it should spell
  out every keystroke ("press the Tab key") and describe what the screen
  should show afterward so each step is verifiable. Another candidate for
  MCP server instructions.
  On pushback, Seshat swung to the other failure mode: a four-paragraph
  walkthrough explaining what Session and Arrangement views *are*, two
  alternative methods, etc. Patrick: still too verbose — "our goal is to
  create music, not learn about Ableton." The target register is **precise
  brevity**: every keystroke located, every step confirmed by what appears
  on screen, and nothing else — no conceptual education, no alternatives
  up front (keep fallbacks for "that didn't work"). Reference example:
  "Press the Tab key (above Caps Lock). You should now see a grid of
  colored cells. In the Keys column, double-click the top cell — your notes
  appear at the bottom of the screen." Both failure modes — terse jargon
  and patient lecture — miss the same target. For MCP server instructions:
  assume no Live fluency, spell out actions, and default to the shortest
  complete path with detail on demand.

### Improvement ideas

- **"New project" should clean up the default track.** When the user says
  "new project" / "start fresh" and the set contains only empty default
  tracks, Seshat should create the requested tracks and then delete the empty
  defaults (create-then-delete, since Live needs ≥1 track) — or ask. Note:
  `Seshat.MCP.Server` currently declares only `capabilities: [:tools]` — it
  sends no server-level `instructions`, so today the *only* channel for this
  kind of session-level guidance in MCP mode is tool descriptions. Adding MCP
  server instructions would give session-level behaviors like this a proper
  home. Running tally of guidance with nowhere to live: (1) new-project
  default-track cleanup; (2) known limitations, so the model explains where
  a setting lives instead of improvising (audio-output case); (3) manual UI
  instructions must spell out keystrokes and describe what the screen shows
  afterward (Tab/Session View case); plus cross-tool conventions like
  offer-choices and read-before-relative-changes. Strongest single theme of
  this run so far. **Promoted to ROADMAP #1 (MCP server instructions),
  which also absorbs the search-diagnostic-leak fix and the kickoff idea's
  practical core (invite a vision / ask before assuming).**
- **Reindexing shouldn't be something the user asks for.** (Patrick, during
  Part 2 — agreed direction.) Split the concern in two:
  - *Check* (free): does `catalog.json` exist, and is its build timestamp
    newer than the mtime of Ableton's browser database (which
    `Seshat.Library.AbletonDB` already reads)? Run this wherever convenient —
    server startup and/or every `search_library` call.
  - *Rebuild* (expensive, ~1 min Live freeze): only when the check finds the
    catalog missing or stale. Don't rebuild silently — tell the user it needs
    a reindex and that it could take a minute, then run it.
  Net effect: the user never asks to reindex and never sits through an
  unnecessary one; the freeze always comes announced and with a real cause.
  **Promoted to ROADMAP #7.**
- **Audio output switching (roadmap candidate).** During an off-script
  write-and-play test (which otherwise went well), audio came out of the
  laptop speakers, not headphones. Live's audio-device setting is not in the
  Live Object Model, so no OSC route exists — but Live's Settings offer
  **"Use System Device"**, and with that set once by hand, Live follows the
  macOS default output, which *is* controllable from the same machine the
  MCP server runs on. Sketch: a `set_audio_output` tool whose handler shells
  out to `SwitchAudioSource` (brew `switchaudio-osx`; `-a` lists, `-s` sets).
  Caveats: requires the one-time "Use System Device" setting (unverifiable
  from Seshat — if flipped back, the tool silently stops affecting Live);
  moves all system audio; would be the first non-OSC shell-out tool in
  `Handlers`; device switch causes a brief Live audio re-init. **Decision:
  out of scope** — a once-per-session manual setting isn't worth the
  precedent. The sketch above stays here in case it's revisited; the useful
  residue is the general point that Seshat should know its boundaries (a
  "limitations" note in future MCP server instructions) so it explains where
  the setting lives instead of improvising.
- **Writes are invisible — show the work.** (Patrick, during off-script
  write-and-play.) After `write_midi_notes`, Session view shows only an
  anonymous colored slot — no notes, no name — and the detail pane was
  focused on the just-loaded device. "I would have thought the writing failed
  if I didn't press play." Three-tier fix, ascending cost:
  1. Name the clip at write time (`set_clip_name` exists; visible text in
     the slot is a success signal, and grid readouts report clip names).
  2. Select the written clip — upstream `/live/view/set/selected_clip`
     exists but isn't exposed as a tool yet.
  3. Focus the piano roll — no upstream address; needs a small vendored
     view handler calling `Application.View.show_view("Detail/Clip")`,
     same pattern as the other vendored extensions.
  Together 2+3 = "show me what you just wrote" as default post-write
  behavior. **Promoted to ROADMAP #3 during the run, then broadened at
  Patrick's direction into the "follow cam": every mutating tool steers the
  view to what it touched, automatically, implemented in the handlers rather
  than as model guidance. Acting beats instructing; automatic beats
  asked-for.** His reference for the fallback
  register: "Press Tab once. You'll see a grid of cells. Double-click the
  orange cell in the Keys row — the notes open at the bottom." But the best
  response is Seshat doing the equivalent itself: select the clip, focus the
  editor, say "there they are."
  Supporting evidence: asked "why can't I see the notes?", Seshat gave a
  good talk-the-user-through-it answer (Tab to Session, double-click, editor
  at bottom — plus the write-confirming detail "all 16 notes across four
  bars") because explaining was the *only* lever it had. With 2+3 the answer
  becomes "here, look" + the piano roll opening. Minor confabulation in that
  reply worth remembering: claimed clip cells show "a tiny waveform-ish
  preview" — they don't (colored block + optional name only).
- **`screenshot_live` — let Seshat see the screen (roadmap candidate).**
  When the user asks about the UI ("why can't I see the notes?"), Seshat
  should be able to look instead of guessing. Mechanism: MCP server runs on
  the same Mac → shell out to `screencapture` targeting Live's window by
  window ID → return the image in the MCP tool result → the client model
  (Claude, vision-capable, already driving) evaluates it and directs the
  user. Closes the OSC-is-blind trust gap; covers everything outside the LOM
  (focused view, dialogs, browser state). Sibling of "show the work": that
  makes Seshat's changes visible to the user, this makes the user's screen
  visible to Seshat. Caveats: one-time Screen Recording permission for the
  BEAM process; downscale before returning (token cost); window must not be
  minimized; confirm Anubis supports image content in tool results (MCP
  spec does). Trigger: UI questions — not routinely after every action.
  **Promoted to ROADMAP #11.**
- **Project kickoff flow (bigger idea).** Capture the user's initial vision —
  free-form description or a few questions (genre, tempo, key, mood) — so
  early decisions (tempo, library searches, track layout) are steered by it
  instead of arriving piecemeal. Open questions: where does the brief live
  (conversation only? a session-notes tool?), and does it need any tool
  support at all versus pure prompting. Candidate for ROADMAP discussion.
