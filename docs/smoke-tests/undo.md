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

*Last run: —*

`create_track` (name it), then `write_midi_notes` into it, then **one** `undo`.
The clip and its notes disappear; **the track stays.** A vanished track means the
wrap isn't reaching Live — reinstall and restart before reading anything else here
as a real result. Then `undo` again: the track goes. Then `redo` twice: both come
back, one step at a time, clip first, in the original order.

The failure this exists to prevent: before the wrap, `create_track` followed by
`write_midi_notes` collapsed into **one** step on Live 12.4.3, so a single `undo`
deleted the whole track, notes and all — and the same pair with an intervening
timed-out call landed as two. Unpredictable, not merely coarse.

## Read-only tools cost nothing

*Last run: —*

`get_session_state`, then `search_library`, then `undo`. The undo reverts the last
real *change*, not one of the reads — an empty begin/end pair leaves Live's history
untouched, which is what lets every tool be wrapped without maintaining a
mutating-tool list.

## A multi-message tool is still one step

*Last run: —*

`create_return_track`, or a `write_midi_notes` over an existing clip, undone in one
call. `write_midi_notes` is three OSC messages (create clip, add notes, name it)
and must revert as a unit, because the wrap encloses the whole dispatch rather
than each datagram.

## An error path still closes its step

*Last run: —*

Call something that fails cleanly — `fire_clip` on an empty slot, `quantize_clip`
with `amount: 0` — then make a real change and `undo` it. The undo must revert
exactly that change; if the failed call had leaked an open step, the two would be
grouped.

## An ordinary undo reports the request, not the outcome

*Last run: —*

`create_track`, then `undo`: the track disappears, and the reply says the request
was *sent* rather than claiming history moved. Then `redo` once and confirm it
comes back. `/live/song/undo` and `/live/song/redo` never reply, so a reply
asserting movement would be a fabrication.

## `can_undo=False` is reachable at an empty history

*Last run: — ⚠️ unmeasured*

File → New Live Set (hold Command and press N), touch nothing, then call `undo`.
Expect the error — "Live reported no undo step available, so no undo was sent" —
and **not** a success string.

This is the one reading the 2026-08-02 probe could not reach without discarding
the open set. What *was* measured about both properties — plain `bool` attributes,
not hardwired true, tracking availability independently in both directions — is in
[../abletonosc-api-docs.md](../abletonosc-api-docs.md#song-getters), and the redo
guard stands on it either way. If `undo` reports the request as sent instead,
`can_undo` alone is always true, and the finding is that the **undo guard should
be dropped rather than widened**; say so in the report, and fold the reading into
the API docs.

## A refusal is not a dead end

*Last run: —*

After a refusal, make any real change and `undo` it: the refusal must not have
left the guard stuck — the next call reads Live again, not a remembered answer.
