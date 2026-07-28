# Decision record — `create_project` removed

> **Status: shipped 2026-07-28.** The tool, its `:new_project` Registry
> command, and the AppleScript machinery are gone. This document records why.

The validation run of 2026-07-27 surfaced the bug: "Let's start a new project.
Make me three MIDI tracks" left 7 tracks in the set — the 4 factory defaults
`clear_default_tracks` failed to delete, plus the 3 new ones. The follow-up
discussion (2026-07-28) concluded the tool should be removed rather than
fixed:

- **The AppleScript Cmd+N step only "worked" when it was redundant.** Seshat
  requires Ableton already running, and Live launches into a fresh set — so
  when `open_new_set/0` succeeded cleanly, a fresh set was already open. When
  the open set had unsaved changes it was worse than redundant: Live's "save
  changes?" dialog swallows the keystroke and blocks everything, and no code
  can click Don't Save on the user's behalf without discarding their work.
- **`clear_default_tracks` never worked and couldn't.** Its deletes were
  fire-and-forget into the post-Cmd+N settling window (`wait_for_ableton/2`
  polled `/live/test`, which answers as soon as the control surface is up, not
  when the set has finished loading) — in the validation run all four were
  lost. Live also refuses to delete a set's last track, so even a perfect run
  would have left one default behind (4 tracks for a 3-track request). And it
  deleted **every** track `(count-1)..0`, not "the defaults" — only the Cmd+N
  preceding it kept it from wiping real work.
- **A stripped default Live Set replaces the whole thing.** The user's Default
  Set is now a single blank MIDI track (in Live 12: save the stripped set via
  File → Save Live Set As Default Set, or right-click a template under the
  browser's Templates label → "Set Default Live Set" — a file merely sitting
  in the Templates folder is *not* the default). Live launches into that
  blank set, so "start a new project" is just `create_track` calls against
  the open set. When a set with real work is open, saving and Cmd+N stay with
  the human — the one step Seshat could never do safely anyway.

Removed: the `create_project` tool (Definitions + Handlers), the
`:new_project` command and its helpers in Registry (`open_new_set/0`,
`wait_for_ableton/2`, `clear_default_tracks/0`, `create_tracks/1`), the
`tracks` field on `%Command{}`, and the tool's rows in the docs. This was the
only place Seshat shelled out to AppleScript; with it gone, everything is OSC.
