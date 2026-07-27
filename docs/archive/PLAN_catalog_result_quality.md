# Plan — Catalog result quality

> **Archived 2026-07-27 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. All six parts live in
> `Seshat.Library.Catalog` (`score/2`, `round_robin/2`, `facets/2`,
> `diagnose/1`) and in the `search_library` / `reindex_library` clauses of
> `Seshat.Tools.Handlers`. Part 2's ≥80% slots-by-score criterion was **not**
> met and was amended at implementation to the 39/77 (51%) the design
> delivers — the residual band is undifferentiable by any weighting; see the
> commit message for the benchmark. The still-open follow-ups (samples index,
> ranking headroom, LLM enrichment) moved to
> [ROADMAP.md](../ROADMAP.md) § Sound catalog follow-ups.

The mission-critical flow: a user describes a sound in words, and Seshat must
surface the best loadable instrument. This plan covers the four levers from
[ROADMAP.md](../ROADMAP.md) § Catalog result quality — tag scoring, ranking,
informative replies, and slate diversity — as one coherent change to how
`search_library` matches, orders, and reports.

## Context

`search_library` is the front door of sound discovery, and today its effective
algorithm is *filter, sort alphabetically, take 15*. Measured on a real
5,729-preset catalog (post alias-fold):

- **Ranking has almost no signal.** `score/1` produces two effective bands; in
  5 of 6 realistic searches zero slots were decided by score — all of them by
  the alphabetical `&1.name` tie-break among 47–86 top-band ties. Good
  candidates below the alphabetical cut never reach the model: for "a warm
  guitar", `Jazz Soft Guitar` and `Nylon Old Guitar` lose their slots to
  whatever starts with A–C.
- **Tags filter when they should score.** `matches_tags?` is a strict AND, so
  one tag the library doesn't have zeroes the whole search.
- **The advertised vocabulary is wrong.** The tool description lists 30 tags;
  `Warm`, `Wide`, `Mono`, `Hi-hat` do not exist in the catalog, and the
  description's own worked example ("a warm analog bass" → query `bass` +
  tags `['Analog', 'Warm']`) returns **nothing**. The real vocabulary is
  per-machine (it depends on installed Packs), so a hardcoded list can never
  be right — the tool has to *surface* the real one.
- **Failure is a dead end.** A zero-result reply says "loosen the tags"
  without saying which tag killed the search or what exists instead; a
  truncated reply says "narrow the query" without saying what would narrow it.

The design principle, already settled on the roadmap: **the LLM is the
semantic layer**. Mapping "warm" onto `Soft`/`Acoustic`/absence-of-`Bright` is
the model's job. The catalog's job is (a) to get candidates carrying that
signal into the slate, and (b) to teach the model the local vocabulary through
its replies. No embeddings, no synonym table in the tool.

Everything here is pure Elixir over the ETS table — **no OSC involvement, no
new tools, no schema change to `catalog.json`**. The alias fold (format v2,
[archive/catalog-aliasing-options.md](catalog-aliasing-options.md))
already ships the data this plan reads.

## OSC contract

None. No new addresses; no changes to existing ones. The only OSC in the
neighbourhood is `/live/browser/export` inside `reindex_library`, which this
plan does not touch. (Recorded so `/plan-review` knows the empty section is a
claim, not an omission.)

## Part 1 — Matching: tags become at-least-one + scored, with normalization

**File:** [lib/seshat/library/catalog.ex](../../lib/seshat/library/catalog.ex)
(`matches_tags?/2` and a new `normalize_tag/1`).

- `matches_tags?` changes from *every requested tag must match* to **at least
  one requested tag must match**. Full coverage moves into the score (Part 2).
  Rationale for keeping one-tag-minimum rather than pure scoring: with no
  filter at all, `tags: ["Analog"]` alone would match all 5,729 entries and
  the total would be meaningless; with ≥1, tags still *mean* something while a
  single bad tag no longer zeroes the search. `query`, `category`, and
  empty-`tags` behaviour are unchanged.
- Tag comparison normalizes both sides: downcase, strip non-alphanumerics,
  and retry with a trailing `s` stripped from the requested tag. This makes
  `hi-hat` match `Closed Hihat` and `pads` match `Pad` — mechanical string
  folding, not semantics. Substring semantics stay (`bass` still matches
  `808 Bass`).

## Part 2 — Scoring: from two bands to a real ordering

**File:** [lib/seshat/library/catalog.ex](../../lib/seshat/library/catalog.ex)
(`score/2`, `haystack/1` helpers).

New score, integer components, highest first in the sort:

| component | value | why |
|---|---|---|
| requested tag matched exactly (normalized) | +4 each | explicit user intent, strongest signal |
| requested tag matched as substring only | +2 each | weaker but real (`bass` → `808 Bass`) |
| every query term a whole token in the name | +6 | `Pad` the word, not `pad` in "Padlock" |
| every query term a substring of the name | +4 | current top band, demoted below token hits |
| ≥1 query term in the name | +2 | current middle band |
| every query term found in name∪tags (not merely path/description) | +2 | kind words live in tags; path hits are weaker |
| `tag_source == :ableton` | +1 | kept from today |
| usage | `min(use_count, 3)`, plus +2 if `last_loaded_at` ≤ 14 days, +1 if ≤ 90 | recency-decayed instead of flat |

The three name components are mutually exclusive tiers — a `cond` like
today's, only the highest applicable one counts — and the two per-tag
components are likewise exclusive per tag (exact beats substring; a tag scores
one or the other, never both). Everything else stacks additively. Without
this, a tiered and an additive reading diverge materially: additive makes
all-terms-whole-token worth 12 and all-terms-substring worth 6, which changes
how name quality trades against tag matches.

Tie-break becomes `entry.uri` (deterministic across reindexes), replacing
`&1.name`.

**Acceptance criterion** (checkable in the diff's tests and re-measurable by
hand): on the dev catalog, across the six ROADMAP benchmark queries, at least
80% of returned slots are decided by score rather than tie-break — versus 1
of 150 today. Measurement procedure in Testing.

## Part 3 — Slate diversity at the cut line

**File:** [lib/seshat/library/catalog.ex](../../lib/seshat/library/catalog.ex)
(`search/1` truncation).

Even a good scorer leaves tied bands on broad queries. When the score band
that straddles `max_results` is larger than the slots remaining, fill those
slots by **round-robin across device root** instead of taking the band in
sort order. The root is the first segment of the entry's first *device-prefixed*
path — the first path of depth ≥ 2 in the sorted `paths` list (`Operator`,
`Analog`, `AUv2`, …) — falling back to the first segment of the first path
when every path is depth 1 (sounds-only presets, whose paths are bare
character folders like `Synth Lead`). Taking the first path unconditionally
would not rotate across devices: `sounds` paths carry no device prefix, so an
Operator bass preset (`paths: ["Bass", "Operator/Bass"]`) would group under
`Bass` while an Analog one (`["Analog/Bass", "Bass"]`) groups under `Analog`,
purely by accident of the device's initial. Entries in bands wholly above the cut are untouched; within the
round-robin, order stays uri-sorted so the result is deterministic.

This is also the generic fix for plugin-slate pollution: the 26 Apple utility
AUs all share the root `AUv2`, so they can flood at most one round-robin turn
of a "reverb" slate instead of 15 alphabetical slots — no hardcoded vendor
demotion needed.

## Part 4 — Search returns facets; a diagnose pass for zero results

**File:** [lib/seshat/library/catalog.ex](../../lib/seshat/library/catalog.ex).

- `search/1` returns `{entries, total, facets}` (a breaking change to an
  internal API; both callers are in `Handlers` and tests). `facets` is the tag
  frequency list across **all** matches (pre-truncation), minus the requested
  tags, minus tags carried by more than 60% of matches (a tag that's on
  everything can't narrow anything), top 6. Computed only when `total >
  length(entries)` — an untruncated result needs no narrowing help.
- New `diagnose/1`, called by `Handlers` only when `total == 0`. One extra
  ETS scan computing, per constraint independently: how many entries the
  query alone matches, how many carry each requested tag anywhere in the
  catalog, and — for a tag matching zero — the nearest real tags by
  `String.jaro_distance/2` (≥ 0.75) plus substring containment against the
  distinct tag vocabulary. Pure, no state.

## Part 5 — Replies that teach

**File:** [lib/seshat/tools/handlers.ex](../../lib/seshat/tools/handlers.ex)
(`format_catalog_entries/2` → `/3`, the `search_library` and
`reindex_library` clauses).

- **Zero results** (draft copy, shaped by `diagnose/1`):

  > No matches. Tag 'Warm' matches nothing in this library — nearest real
  > tags: Soft (491), Warmth (12). 'Analog' alone matches 638. Retry with the
  > real tags, or drop the query down to just the kind of sound.

- **Truncation** (facets replace the generic advice):

  > Showing 15 of 127 matches — top tags among them: Analog (40), FM (22),
  > Evolving (18), Sub (11). Add one as a tag to narrow.

- **`reindex_library` reply** gains the local vocabulary, so the model learns
  it exactly when it changes. The handler has no view of the entries, so
  `Catalog.reindex/1`'s success shape grows to
  `%{items, tagged, distinct_tags, top_tags}` (top tags with counts, computed
  in the `{:replace, entries}` callback) — the one place the fresh entry list
  is already in hand:

  > Reindexed the sound catalog: 5,795 item(s), 5,760 tagged by Ableton.
  > 214 distinct tags — most common: One Shot (2483), Punchy (861), Acoustic
  > (679), Analog (638), Basic (598), Digital (545), … search_library is
  > ready.

## Part 6 — The tool description stops lying

**File:** [lib/seshat/tools/definitions.ex](../../lib/seshat/tools/definitions.ex)
(`search_library` description and its `tags` parameter). No new tool → no
count bump in `definitions_test.exs`; MCP parity is generated.

Draft description (replaces the current one; the WHEN CHOOSING guidance and
one-preset-one-entry explanation survive unchanged):

> Search the sound catalog: a persistent, tag-aware index of every
> instrument, preset, drum kit and effect in this user's Ableton Live
> library. PREFER THIS OVER list_browser_items — it is instant, it searches
> folder paths and tags as well as names, and it works even when Ableton is
> closed. Fall back to list_browser_items only when this returns nothing.
> Most presets carry tags written by Ableton's own sound designers. The tag
> vocabulary is this user's library, not a fixed list — reindex_library and
> every truncated result report the real tags with counts; trust those over
> guesses. Put the kind of sound in `query` and character words in `tags`:
> tags are scored, not strict — at least one must match, and results carrying
> more of them rank higher, so guessing ['Analog', 'Warm'] still returns the
> Analog matches even if 'Warm' isn't a real tag here. If nothing comes back,
> the reply names which tag failed and the nearest real ones — retry with
> those rather than abandoning the search. WHEN CHOOSING: weigh the musical
> context — the tempo, the other tracks and the genre from get_session_state
> and from what the user has said — and present the top 3–5 candidates with a
> one-line reason each, then let the user pick. Only load the first hit
> without asking if the user told you to just pick one. Each result is one
> preset: `name — tags [folder paths] (uri)`. A preset Live files under
> several devices lists all of them, so 'Analog/Synth Lead · Operator/Synth
> Lead' is a single sound either device can play — not two options. The uri
> goes straight to load_device. If the catalog is empty, say so and offer to
> run reindex_library.

At ship time, touch [TOOL_AUDIT.md](../TOOL_AUDIT.md)'s `search_library` row —
the strict-AND filtering and the wrong advertised vocabulary are exactly the
kind of wart that table exists to track, and both stop being true here.

The `tags` parameter description changes to match the new semantics:

> Character or kind tags, e.g. ['Analog', 'Soft']. At least one must match;
> the more that match, the higher the result ranks. Case-insensitive,
> punctuation-insensitive substrings — 'bass' matches '808 Bass', 'hi-hat'
> matches 'Closed Hihat'.

## Testing

All pure — nothing in this plan can touch `Transport.query/3`.

- **`catalog_test.exs`**: new `describe` blocks for the matcher (≥1-tag rule,
  normalization: `hi-hat`→`Closed Hihat`, `pads`→`Pad`), scoring (each
  component asserted in isolation on hand-built entries; whole-token beats
  substring; requested-tag count dominates; recency bonus), diversity (a
  hand-built tied band wider than the cap round-robins across roots,
  deterministically), facets (requested and >60% tags excluded), and
  `diagnose/1` (nonexistent tag yields nearest-tag suggestions; the
  "warm analog bass" case from the ROADMAP returns Analog candidates instead
  of nothing). The 28-row real-catalog fixture gains assertions that "sweet
  lead" still ranks its preset first under the new scorer.
- **`handlers_test.exs`**: the three reply formats (zero-result with
  diagnosis, truncated with facets, reindex with vocabulary) asserted on
  their exact copy.
- **Benchmark (manual, dev machine)**: run the six ROADMAP queries in `iex`
  against the real dev `catalog.json` before and after; record the
  slots-by-score metric in the PR description. Target ≥80% score-decided
  (today: 1 of 150). This is the acceptance measurement for Part 2's weights
  — the weights are informed guesses until this confirms them, and tuning
  them against the benchmark is part of implementation, not scope creep.
- **`/smoke-test` addition**: one end-to-end ask — "find me a warm guitar" —
  confirming the model reaches `Jazz Soft Guitar`-class candidates and
  presents them with reasons.

## Out of scope

- **Opt-in `samples` index** — separate coverage item on the roadmap;
  orthogonal to ranking.
- **`kind: device | preset` modelling** and plugin AUv2/VST3 format folding —
  recorded in [archive/catalog-aliasing-options.md](catalog-aliasing-options.md);
  Part 3's round-robin already caps the symptom.
- **LLM enrichment, user XMP tags, embeddings** — roadmap "Sound catalog
  follow-ups" / "not planned", unchanged.
- **`list_browser_items`** — untouched; it stays the raw fallback.
- **Dynamic MCP tool descriptions** (re-generating the description from the
  live vocabulary) — MCP components are compile-time generated; the replies
  carry the dynamic truth instead.

## Open questions

1. **Weights are tuned against one library.** The benchmark catalog is a
   single machine's factory content; a library dominated by third-party Packs
   could rank differently. Can't be resolved now (needs other users'
   catalogs). **Promoted to an assumption by `/plan-review`:** factory-content
   weighting is assumed, and it is cheap to assume — Seshat has one user, so
   the only library the weights can be wrong for is the one they were tuned
   on. The implementer records the before/after benchmark numbers in the PR
   description (per Testing) so the weights can be re-tuned when a second
   library ever shows up. Not a blocker; nothing for the implementer to
   decide.
2. **Does ≥1-tag filtering ever hide a good result?** If the model sends only
   wrong-guess tags (all zero-match), the search returns nothing where pure
   scoring would have returned query matches. The zero-result diagnosis makes
   recovery one step, so the plan accepts this. **Resolved by `/plan-review`:
   keep the ≥1 filter.** With no filter, `tags: ["Analog"]` matches all 5,729
   entries and `total` stops meaning anything, which Part 4's facets and
   truncation copy both lean on; the all-tags-miss case is exactly what
   `diagnose/1` was built for, and its reply routes the model straight to the
   retry. Implement as written.
