# Catalog and browser

`search_library`'s job is to turn a description into a loadable preset, and the
only honest test of ranking is whether a plain ask reaches a good candidate.
Tests cover the scoring rules; they cannot tell you the slate is *musically*
right. **Judge the conversation, not the first tool call.**

## `nearest real tags` stays quiet for a word the library has no spelling of

*Last run: 2026-08-03 — passed, both directions in one run. `search_library
query: "guitar", tags: ["Warm"]` replied "Tag 'Warm' matches nothing in this
library" with **no** nearest-real-tags list, then went straight to the real tags
on the 187 query-only matches. The contrast case confirmed the mechanism is
alive: `tags: ["Anlaog"]` replied "nearest real tags: Analog (638)".*

Don't expect that list for a word like `Warm`. It is string similarity — it
rescues a typo (`Anlaog` → `Analog`) or a longer form (`Warmth` → `Warm`), not a
word with no counterpart. The nearest string neighbour of "Warm" in a stock
vocabulary is "Marimba" at 0.726, below the threshold, and suppressing it is
correct behaviour, not a gap.

## Usage counts survive a reindex

*Last run: 2026-08-03 — passed. In `search_library query: "reverb", category:
audio_effects`, "Ballad Reverb.adv" ranked **5th**. One `load_device` of it onto
a return moved it to **3rd**. A full `reindex_library` (5,796 items) then left it
still **3rd** — the usage boost survived the rebuild.*

Load a candidate, then search again and confirm `search_library` favours it
slightly.

