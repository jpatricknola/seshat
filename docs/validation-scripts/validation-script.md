# Seshat validation script

A guided session for a human to run against a live Ableton Live instance.

You play the musician. You read each **Say this** line to Seshat exactly as
written (or close enough — the point is natural language, not incantations),
then check the **Look for** notes before moving on. By the end you will have
built a short lo-fi house sketch and exercised every tool Seshat ships.

This is deliberately *not* a checklist of tool calls. Everything here is
something a person would actually ask for while writing a track. The
verification is woven into the session the way a musician checks their own
work — look at the screen, listen, keep going.

**Time:** about 40 minutes at a relaxed pace.

**Why it matters:** OSC is UDP with no reply, so a wrong address fails
*silently*. A step that produces no visible change is a real bug, not a slow
response. Treat "nothing happened" as a failure and write it down.

---

## Before you start

**Save and close whatever you're working on.** Step 1 opens a brand-new Live
set and deletes its default tracks. Anything unsaved is gone.

Setup checklist:

- [ ] Ableton Live is running with an empty or throwaway set open.
- [ ] AbletonOSC is installed (`mix abletonosc.install`) and enabled as a
      Control Surface in Live's preferences.
- [ ] Seshat's MCP server is connected in your client (Claude Desktop or
      Claude Code) — you can see the `seshat` tools listed.
- [ ] Live is visible on screen next to your chat window. You need to watch
      both.
- [ ] Audio output works — you'll be listening, not just reading.

Keep a note open for failures. The reporting template is at the bottom.

---

## Part 1 — Open the set

> **Say this:**
> *"Let's start a new project. Make me three MIDI tracks: Keys, Bass, and
> Drums."*

**Look for:** Live opens a fresh set. The two default MIDI tracks and two
default audio tracks are gone, replaced by exactly three MIDI tracks named
Keys, Bass and Drums, in that order.

- [ ] Three tracks, correctly named, correct order
- [ ] No leftover default tracks (no "1 MIDI", "2 Audio")

> **Say this:**
> *"What's in the session right now?"*

**Look for:** Seshat reads back the three tracks, the tempo (probably 120),
and the time signature. It should refer to tracks by **name** or by 1-based
number — if it says "track 0", that's a prompt regression worth noting.

- [ ] Track list matches what's on screen
- [ ] Tempo and time signature reported
- [ ] Talks in names / 1-based numbers, not raw indices

> **Say this:**
> *"This is a lo-fi thing, take it down to 86 BPM. And put the metronome on
> while we work."*

**Look for:** the tempo field in Live's transport bar reads 86.00, and the
metronome icon lights up.

- [ ] Tempo changed to 86
- [ ] Metronome on

---

## Part 2 — Find sounds

This part leans on the sound catalog, which is the newest and least-proven
surface. Take your time here.

> **Say this:**
> *"Have you got an index of my library yet? If not, build one — I'll wait."*

**Look for:** if this is your first run, Seshat should warn you it takes up to
a minute and that Live's UI may freeze, then run it. Live *will* look hung
partway through. That's expected. If you've already indexed on this machine,
Seshat should say so and skip it rather than redoing it.

- [ ] Warns before starting (doesn't just silently freeze Live)
- [ ] Completes without timing out
- [ ] On a second run, correctly reports the catalog already exists

> **Say this:**
> *"I want a warm, slightly out-of-tune electric piano for the Keys track.
> What have I got?"*

**Look for:** several candidates with a one-line reason each — *not* one
result loaded without asking. This is the behaviour the tool description asks
for, and it's the difference between a search tool and an assistant.

- [ ] Returns a handful of options, not one
- [ ] Reasons reference the musical context (lo-fi, 86 BPM), not just the name
- [ ] Results look like real presets in your library, not invented names

> **Say this:** *(pick one)*
> *"Load the second one."*

**Look for:** the device appears on the Keys track in Live's device view.
Seshat should confirm by naming **what actually landed**, which may differ
from what you asked for if the URI resolved oddly.

- [ ] Device visible on Keys in Live
- [ ] Seshat names the device that actually loaded

> **Say this:**
> *"Bass next — something warm and analog, nothing too clicky."*

**Look for:** the same shape of interaction. Pick one and let it load onto
Bass.

- [ ] Options offered, choice respected, device lands on **Bass** (not Keys)

> **Say this:**
> *"For drums I want a dusty, vinyl-ish kit."*

**Look for:** a drum rack or kit preset loaded onto Drums.

- [ ] Drum kit on the Drums track

> **Say this:**
> *"Actually, search Live's browser directly for anything called 'Operator'
> — I want to see the raw browser results."*

**Look for:** this should bypass the catalog and hit Live's browser live.
Slower than the catalog search, and the results carry folder paths.

- [ ] Returns Operator and/or its presets
- [ ] Noticeably slower than the catalog search (that's the tell it's a real
      round-trip)

> **Say this:**
> *"What's on each of my three tracks now?"*

**Look for:** the device chain per track, in order, matching what you see in
Live when you click each track.

- [ ] Chains match the screen for all three tracks

---

## Part 3 — The first idea

> **Say this:**
> *"Give me a four-bar chord progression on Keys — something moody in F
> minor. Lay it in the first scene."*

**Look for:** a clip appears in the Keys track, scene 1 slot. Double-click it
— you should see actual chords (stacked notes), not a single melodic line,
and they should be in F minor.

- [ ] Clip exists in the right slot
- [ ] Clip length matches four bars (16 beats at 4/4)
- [ ] Notes are stacked into chords
- [ ] It's actually F minor

> **Say this:**
> *"Show me the clip grid — what's where?"*

**Look for:** Seshat describes the grid: three tracks, their types, which
slots hold clips, scene names. Only the Keys clip should be listed as
occupied. Compare it against the Session view on screen, slot by slot.

- [ ] Grid description matches the screen exactly
- [ ] Reports track **types** (all MIDI here)
- [ ] Empty slots correctly reported as empty

> **Say this:**
> *"Play it."*

- [ ] Clip fires, transport rolls, you hear the chords
- [ ] It sounds like the electric piano you picked, at 86 BPM

> **Say this:**
> *"Stop."*

- [ ] Playback stops

---

## Part 4 — Bass and drums

> **Say this:**
> *"Now a bassline under those chords. Keep it simple — roots, mostly on the
> downbeats, and leave some space."*

**Look for:** before writing, Seshat should check what's already in the Keys
clip so the bass actually follows the progression rather than guessing. A
bass clip lands on the Bass track, scene 1.

- [ ] Reads the Keys clip first (it should say so)
- [ ] Bass notes follow the chord roots
- [ ] Written into scene 1 on Bass, not somewhere else
- [ ] Bass sits in a sensible octave (not up with the chords)

> **Say this:**
> *"Drums — a laid-back boom-bap pattern, one bar, and loop it."*

**Look for:** a drum clip in the Drums track. Open it: kick, snare and hats
should be on the standard General MIDI drum pitches (C1 kick, D1 snare, F#1
hat) so the drum rack actually makes those sounds.

- [ ] Drum clip exists
- [ ] Notes land on drum-rack pads that produce sound (not silent empty pads)
- [ ] Pattern is one bar

> **Say this:**
> *"Play the whole first scene."*

**Look for:** all three clips launch together.

- [ ] All three fire as one scene
- [ ] It sounds like a piece of music

Leave it playing for a moment, then:

> **Say this:**
> *"Stop just the drums."*

- [ ] Drums clip stops, Keys and Bass keep playing

> **Say this:**
> *"Alright, stop everything."*

- [ ] Full stop

---

## Part 5 — Editing what's already there

This is the read–modify–write loop. It's new, and it's the part most likely to
overwrite something it shouldn't. Watch the note count carefully.

> **Say this:**
> *"Read me back what's in the Keys clip."*

**Look for:** every note listed with a **note name** (not just a MIDI number),
its start beat, length and velocity. Spot-check three notes against the clip
in Live.

- [ ] Note names present and correct
- [ ] Start beats and durations match the clip editor
- [ ] Note count matches what you see

> **Say this:**
> *"Those chords are too stiff. Humanize the velocities a bit — some softer,
> some accented — but don't change any pitches or timing."*

**Look for:** velocities vary afterwards. Pitches and positions must be
**identical**. This is the trap: a lazy implementation rewrites the clip and
loses the voicing.

- [ ] Velocities now varied
- [ ] Same number of notes as before
- [ ] Pitches unchanged
- [ ] Timing unchanged

> **Say this:**
> *"Take the bass down an octave."*

- [ ] Bass notes moved down exactly 12 semitones
- [ ] Note count unchanged, rhythm unchanged
- [ ] Sounds lower, not broken

> **Say this:**
> *"There's too much going on in bar 3 of the drums — clear out the hats in
> that bar only."*

**Look for:** a surgical removal. Hats gone from bar 3; kick and snare in bar
3 untouched; everything in bars 1, 2 and 4 untouched.

- [ ] Only hi-hats removed
- [ ] Only in bar 3
- [ ] Kick/snare intact

> **Say this:**
> *"Hmm, undo that."*

- [ ] Hats come back

> **Say this:**
> *"No, I was right the first time — redo."*

- [ ] Hats gone again

---

## Part 6 — Building an arrangement

> **Say this:**
> *"Call this first scene 'Verse'."*

- [ ] Scene 1 renamed in the Session view master column

> **Say this:**
> *"Duplicate the Verse so I've got somewhere to build a chorus, and name the
> new one 'Chorus'."*

**Look for:** a second scene, containing copies of all three clips, named
Chorus.

- [ ] Scene 2 exists with all three clips copied
- [ ] Named Chorus

> **Say this:**
> *"In the Chorus, make the chords bigger — add a higher voicing on top. Leave
> the Verse alone."*

**Look for:** the Chorus Keys clip changes; the Verse Keys clip does not. Open
both and compare.

- [ ] Chorus clip has added notes
- [ ] **Verse clip is untouched** — this is the important half

> **Say this:**
> *"Name that clip 'Chorus keys'."*

- [ ] Clip title shows in the Session view slot

> **Say this:**
> *"Add an empty scene at the end for a breakdown, and call it 'Break'."*

- [ ] Scene 3 exists, named Break, all slots empty

> **Say this:**
> *"Copy the Verse bass into the Break — I just want bass there on its own."*

- [ ] Bass clip appears in the Break row, other Break slots stay empty

> **Say this:**
> *"Show me the grid again."*

**Look for:** three scenes with correct names; Verse and Chorus full, Break
holding only bass. Check every cell against the screen.

- [ ] All three scene names correct
- [ ] Occupied/empty pattern matches the screen exactly
- [ ] Clip names reported (including "Chorus keys")

> **Say this:**
> *"Play the Chorus."*

- [ ] Scene 2 launches, all three clips

> **Say this:**
> *"Now the Break."*

- [ ] Scene 3 launches; only bass sounds

> **Say this:**
> *"Select the Verse scene and the Keys track for me so I can see them."*

**Look for:** selection moves in Live's UI — Keys track highlighted, Verse row
selected.

- [ ] Live's selection actually moved

> **Say this:**
> *"Stop."*

---

## Part 7 — Mixing

> **Say this:**
> *"The drums are too loud. Pull them down a bit."*

**Look for:** the Drums fader moves *down*, not to a fixed value. Seshat
should read the current volume first to make a relative change.

- [ ] Fader moved down
- [ ] Not slammed to zero or reset to a default

> **Say this:**
> *"Push the keys out to the left a touch, and give the bass dead centre."*

- [ ] Keys pan knob moves left of centre (a touch, not hard left)
- [ ] Bass pan at centre

> **Say this:**
> *"Solo the bass for a second so I can hear it on its own."*

- [ ] Bass solo lights up

> **Say this:**
> *"OK, unsolo. And mute the keys, I want to hear the rhythm section."*

- [ ] Solo off, Keys muted

> **Say this:**
> *"Unmute the keys."*

- [ ] Keys back

> **Say this:**
> *"What parameters has the bass instrument got?"*

**Look for:** a parameter list with names, current values, and min–max ranges.

- [ ] Parameters listed with ranges
- [ ] Names match what you see in Live's device panel

> **Say this:**
> *"Close the filter down on the bass — I want it darker."*

**Look for:** the filter cutoff knob visibly moves down in Live, and Seshat
reports the new display value (e.g. "1.2 kHz"). It should move a *fraction* of
the range, not jump to the minimum.

- [ ] Correct knob moved (the filter, not something random)
- [ ] Moved down, by a musical amount
- [ ] Seshat reports the human-readable value

> **Say this:**
> *"Arm the drums track, I might play something in."*

- [ ] Drums record-arm button lights

> **Say this:**
> *"Actually, disarm it."*

- [ ] Arm off

> **Say this:**
> *"Set the song loop to the first eight bars and turn looping on."*

**Look for:** this one is an *Arrangement* view control, so switch to
Arrangement (Tab) to check. The loop brace should span bars 1–9.

- [ ] Loop brace enabled and spanning the first eight bars

Switch back to Session view (Tab) before continuing.

---

## Part 8 — Making a mess and cleaning it up

Real sessions involve mistakes. These steps check that failures fail *loudly*.

> **Say this:**
> *"Add an audio track called Vocals."*

- [ ] New audio track named Vocals, at the end

> **Say this:**
> *"Write a melody on the Vocals track."*

**Look for:** ⚠️ **This is a trap.** MIDI can't be written to an audio track.
`write_midi_notes` now checks the track type itself and **refuses with an
explanation** naming the track — the silent no-op is gone, so a phantom
success here is a genuine failure whichever layer produced it. Ideally Seshat
notices before calling the tool at all and offers a MIDI track instead; the
tool's own error is the backstop.

- [ ] Refuses, and explains why
- [ ] Does **not** claim success

> **Say this** (only if this set has a group track — skip otherwise):
> *"Write a melody on the group track itself."*

**Look for:** the same refusal by a different route. A group track reports MIDI
input but has no clip slots of its own, so an unguarded write would be dropped
and reported as success. Seshat should name it as a group track and offer one of
the tracks inside it.

- [ ] Refuses, names it as a group track

> **Say this:**
> *"Try writing notes to track 47."*

**Look for:** a clean error, quickly. A nonexistent index gets no reply from
Ableton at all, so the guard gives up after ~2 seconds and says so — a brief
pause is expected, a 5-second hang or a crash is not.

- [ ] Clean error message
- [ ] Fast — a couple of seconds at most

> **Say this:**
> *"Play the Keys clip in the Break scene."*

**Look for:** ⚠️ **Another trap** — Break holds bass only, so the Keys slot
there is empty. Firing an empty slot is Live's way of *stopping* a track, so a
tool that just sent it would silence Keys while reporting a launch. Seshat
should refuse, say that slot is empty, and point at `stop_clip` if stopping
was the intent.

- [ ] Refuses, names the empty slot
- [ ] Reports no launch that didn't happen

> **Say this:**
> *"Duplicate the Keys track."*

- [ ] Copy of Keys appears, with its clips and its instrument

> **Say this:**
> *"Rename that copy to 'Keys 2'."*

- [ ] Renamed

> **Say this:**
> *"Delete the Keys 2 track and the Vocals track, I don't need them."*

- [ ] Both gone, original three tracks intact

> **Say this:**
> *"Delete the bass clip out of the Break scene, and then delete the Break
> scene entirely."*

- [ ] Clip gone, then scene gone
- [ ] Verse and Chorus untouched

> **Say this:**
> *"Where are we at — read me the grid and the session one more time."*

**Look for:** three tracks, two scenes (Verse, Chorus), everything consistent
with the screen after all that churn. This is the real test of whether state
tracking survived a messy session.

- [ ] Grid matches screen
- [ ] Session state matches screen (names, tempo 86, mix positions)

---

## Part 9 — Wrap up

> **Say this:**
> *"Turn the metronome off and play me the Verse one last time."*

- [ ] Metronome off, Verse plays

> **Say this:**
> *"Stop. That's a wrap."*

- [ ] Stopped

You now have a small but real lo-fi sketch. Save it if you like it.

---

## What this covered

The tools this walkthrough was written against, in the order they appear above.
The surface has grown since; this table is a record of what the 2026-07-27 script
covers, not a current inventory. (`create_project` was removed after that run, so
Part 1's "new project" prompt now resolves to `create_track` calls against the
blank Default Set — see
[archive/create-project-removal.md](../archive/create-project-removal.md).)

| Part | Tools exercised |
|---|---|
| 1 | `create_track`, `get_session_state`, `set_tempo`, `set_metronome` |
| 2 | `reindex_library`, `search_library`, `load_device`, `list_browser_items`, `get_track_devices` |
| 3 | `write_midi_notes`, `get_clip_slots`, `fire_clip`, `start_playing`, `stop_playing` |
| 4 | `write_midi_notes`, `get_clip_notes`, `fire_scene`, `stop_clip` |
| 5 | `get_clip_notes`, `remove_notes`, `undo`, `redo` |
| 6 | `set_scene_name`, `duplicate_scene`, `create_scene`, `duplicate_clip`, `set_clip_name`, `delete_clip`, `delete_scene`, `select_track`, `select_scene` |
| 7 | `set_track_volume`, `set_track_pan`, `set_track_solo`, `set_track_mute`, `get_device_parameters`, `set_device_parameter`, `set_track_arm`, `set_loop` |
| 8 | `create_track`, `duplicate_track`, `set_track_name`, `delete_track` |

**Not covered:** anything shipped after 2026-07-27 — sends and returns, device
removal and bypass, MIDI capture, per-clip properties, session record, and
whatever has landed since. The table above is the definitive list of what *is*
covered; assume any tool absent from it is untested by this script, and see
`/smoke-test` for that surface in the meantime.

---

## Watch these especially

Ranked by how new the code is and how quietly it can fail:

1. **`get_clip_slots`** (Parts 3, 6, 8) — newest tool. Every grid read should
   match the screen cell for cell.
2. **`get_clip_notes` → `remove_notes` → `write_midi_notes`** (Part 5) — the
   edit loop. Silent data loss is the risk: check note counts before and
   after.
3. **The sound catalog** (Part 2) — tag search quality and whether Seshat
   offers choices rather than grabbing the first hit.
4. **The audio-track trap** (Part 8) — the one place where the *absence* of an
   error is the bug.
5. **Relative changes** ("a bit", "a touch") throughout Part 7 — these require
   reading current state first. A jump to a hardcoded value is a failure even
   though something visibly moved.

---

## Reporting

For each failure, note:

- **Which step** — the Part and the line you said.
- **What you asked for** — your exact words.
- **What Seshat said** — did it claim success?
- **What Live actually did** — including "nothing".
- **Which tool** — expand the tool call in your client if you can.

Then split the results three ways:

- **Broken** — Seshat claimed success, Live didn't change. Almost always a
  wrong OSC address or wrong argument order. Check the address against
  [abletonosc-api-docs.md](../abletonosc-api-docs.md) first.
- **Wrong** — something happened, but not what you asked for. Usually a tool
  description or prompting problem, not a wiring problem.
- **Judgement** — it worked, but the musical result was poor (dull chords, a
  stiff drum pattern, an odd preset choice). Note these separately: they're
  prompt-quality signals, not defects.

The last category is the one only a human running this script can report. Be
opinionated about it.
