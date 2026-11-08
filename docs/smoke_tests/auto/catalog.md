# Catalog and browser

`search_library`'s job is to turn a description into a loadable preset, and the
only honest test of ranking is whether a plain ask reaches a good candidate.
Tests cover the scoring rules; they cannot tell you the slate is *musically*
right. **Judge the conversation, not the first tool call.**

## `nearest real tags` stays quiet for a word the library has no spelling of

*Last run: 2026-11-08 — passed, both directions. `query: "guitar", tags: ["Warm"]` replied "Tag 'Warm' matches nothing in this library" with no nearest-real-tags list, then the real tags on the 187 query-only matches; `tags: ["Anlaog"]` replied "nearest real tags: Analog (638)".*

Don't expect that list for a word like `Warm`. It is string similarity — it
rescues a typo (`Anlaog` → `Analog`) or a longer form (`Warmth` → `Warm`), not a
word with no counterpart. The nearest string neighbour of "Warm" in a stock
vocabulary is "Marimba" at 0.726, below the threshold, and suppressing it is
correct behaviour, not a gap.

## Usage counts survive a reindex

*Last run: 2026-11-08 — passed. In `query: "reverb", category: audio_effects`, "Ballad Reverb.adv" ranked 3rd (its 2026-08-03 use count had persisted). One load_device onto a return moved it to 2nd; a full reindex_library (5,798 items, 0.7s) left it 2nd.*

Load a candidate, then search again and confirm `search_library` favours it
slightly.

