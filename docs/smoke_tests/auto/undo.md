# Undo and redo

Two independent things: whether Live groups a tool call into **one** history step
(`Handlers.call/2`'s undo wrap, `song.py`'s `begin_undo_step` / `end_undo_step`),
and whether `undo` and `redo` **report honestly** when history can't move
(`history_guard/2` reading `can_undo` / `can_redo`).

Nothing in `mix test` proves either. The suite pins the wire shape —
`begin_undo_step`, the tool's own messages, `end_undo_step`, in that order — but
whether Live collapses them into one history entry happens inside Live, and both
step addresses are send-only. For the guards, the suite supplies the guard's reply
itself, so it proves how Seshat *reacts* to a `false`, never that Live ever says
one.

The step addresses are fork-only: [bridge.md](bridge.md)'s reinstall precondition
applies, and the first test is what catches a skipped reinstall. The guard
addresses are upstream properties that already ship.

## One tool call is one undo step

*Last run: 2026-08-03 — passed. `create_track "Undo Test"` then
`write_midi_notes` ("Undo Clip", 2 notes) into it; **one** `undo` left the track
standing with its slot empty. A second `undo` removed the track. `redo` then
restored the track (still empty), and a second `redo` restored the clip — two
distinct steps, in creation order. The wrap is reaching Live.*

`create_track` (name it), then `write_midi_notes` into it, then **one** `undo`.
The clip and its notes disappear; **the track stays.** A vanished track means the
wrap isn't reaching Live — reinstall and restart before reading anything else here
as a real result. Then `undo` again: the track goes. Then `redo` twice: both come
back one step at a time, in the original order — track first, then the clip
(undo peels them off clip-first; redo puts them back the way they were made).

The failure this exists to prevent: before the wrap, `create_track` followed by
`write_midi_notes` collapsed into **one** step on Live 12.4.3, so a single `undo`
deleted the whole track, notes and all — and the same pair with an intervening
timed-out call landed as two. Unpredictable, not merely coarse.

## Read-only tools cost nothing

*Last run: 2026-08-03 — passed. `get_session_state` and `search_library` issued
between a `write_midi_notes` and its `undo`; the undo still reverted the clip,
not one of the reads, and the track was untouched. Empty begin/end pairs cost
nothing.*

`get_session_state`, then `search_library`, then `undo`. The undo reverts the last
real *change*, not one of the reads — an empty begin/end pair leaves Live's history
untouched, which is what lets every tool be wrapped without maintaining a
mutating-tool list.

## A multi-message tool is still one step

*Last run: 2026-08-03 — passed, both forms, under the tool names of the day
(the return create was `create_return_track`, since folded into `create_track`).
`"Undo Return"` (which appeared as return 1 / send B) was gone after a single
`undo`. Separately,
`write_midi_notes` adding two notes to the existing 6-note "Sloppy" clip reverted
in one `undo` to exactly the prior six — no partial remnant, so the three
messages (create/add/name) revert as a unit.*

`create_track track_type: "return"`, or a `write_midi_notes` over an existing
clip, undone in one call. `write_midi_notes` is three OSC messages (create clip, add notes, name it)
and must revert as a unit, because the wrap encloses the whole dispatch rather
than each datagram.

## An error path still closes its step

*Last run: 2026-08-03 — passed. Both failing calls were made back to back —
`quantize_clip amount: 0` ("0% strength, which cannot move any note") and
`fire_clip` on an empty slot — then **two** real changes: `create_track "Err
Test"` followed by `write_midi_notes` into it. One `undo` removed only the clip
and left the track, so the failed calls neither leaked an open step nor grouped
the two changes that followed. (Two real changes rather than one on purpose: with
a single change, a leaked step would revert identically and prove nothing.)*

Call something that fails cleanly — `fire_clip` on an empty slot, `quantize_clip`
with `amount: 0` — then make a real change and `undo` it. The undo must revert
exactly that change; if the failed call had leaked an open step, the two would be
grouped.

## An ordinary undo reports the request, not the outcome

*Last run: 2026-08-03 — passed. The track disappeared and the reply claimed
nothing about history: "Undo requested. Ableton does not acknowledge undo, so
this confirms the request was sent, not that history moved. Verify once after the
batch with get_session_state." One `redo` brought it back, with the matching
redo-side wording. No reply asserted movement.*

`create_track`, then `undo`: the track disappears, and the reply says the request
was *sent* rather than claiming history moved. Then `redo` once and confirm it
comes back. `/live/song/undo` and `/live/song/redo` never reply, so a reply
asserting movement would be a fabrication.

## A refusal is not a dead end

*Last run: 2026-08-03 — passed, and the refusal itself is now measured against a
live `false`. A scratch `write_midi_notes` cleared the redo stack; `redo` then
errored "Live reported no redo step available, so no redo was sent. Do not retry
unless history has changed; any new edit can clear Live's redo history." A second
scratch write followed by `undo` reverted normally, so the guard re-read Live
rather than caching the refusal. **`can_redo` demonstrably reports `False` from
Live** — the counterpart reading to the still-unmeasured `can_undo` case above.*

After a refusal, make any real change and `undo` it: the refusal must not have
left the guard stuck — the next call reads Live again, not a remembered answer.
The agent form is non-destructive: make a scratch edit to clear the redo stack,
call `redo` to obtain the measured `can_redo=False` refusal, then make another
scratch edit and undo it.
