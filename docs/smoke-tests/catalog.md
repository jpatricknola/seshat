# Catalog and browser

`search_library`'s job is to turn a description into a loadable preset, and the
only honest test of ranking is whether a plain ask reaches a good candidate.
Tests cover the scoring rules; they cannot tell you the slate is *musically*
right. **Judge the conversation, not the first tool call.**

## A plain ask in words reaches a good candidate

*Last run: —*

"Find me a warm guitar". `Warm` is not a real tag in a stock library, which is
the point. If the model sends `Warm` as its only tag the search correctly returns
nothing (tags filter at ≥1); what must happen next is that the reply names the
failed tag and the real tags on what the query alone matched, and the model
retries with one of those and lands on the acoustic/soft guitars. One wasted call
is the designed cost; **a dead end is the failure**, even though nothing errored.

## `nearest real tags` stays quiet for a word the library has no spelling of

*Last run: —*

Don't expect that list for a word like `Warm`. It is string similarity — it
rescues a typo (`Anlaog` → `Analog`) or a longer form (`Warmth` → `Warm`), not a
word with no counterpart. The nearest string neighbour of "Warm" in a stock
vocabulary is "Marimba" at 0.726, below the threshold, and suppressing it is
correct behaviour, not a gap.

## The slate spans devices, and its facets narrow

*Last run: —*

Not 15 neighbours from one folder. A truncated reply lists real tags with counts
you can narrow by — try one and confirm it narrows. Confirm the model presents
3–5 candidates with reasons rather than loading the first hit unasked.

## Usage counts survive a reindex

*Last run: —*

Load a candidate, then search again and confirm `search_library` favours it
slightly.

## Browser preview sounds without touching the set

*Last run: —*

`/live/browser/preview_item` and `/live/browser/stop_preview` are served by the
fork but have no Seshat tool (ROADMAP: browser preview audition), so the MCP
surface can't reach them. Drive them with
`.claude/skills/smoke-test/scripts/osc_send.py`, passing a `uri` from
`search_library`, with Live's cue output routed somewhere audible and the cue
level up.

Confirm it sounds *without* anything being added to the set (`get_session_state`,
`get_track_devices`), and that `stop_preview` silences it. A silent preview with
cue routed nowhere is expected, not a bug — which is exactly why the cue caveat
has to reach the eventual tool's description.
