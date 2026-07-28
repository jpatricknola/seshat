# Sound search — from a described sound to the right loaded sound

_Research & options doc · 27 Jul 2026 · feeds [ROADMAP.md](ROADMAP.md), decides
nothing by itself._

The mission-critical flow: **a user describes a sound in natural language —
"a dusty lo-fi electric piano", "a big warm analog bass" — and Seshat surfaces
and loads the best candidates this library actually has.** The catalog
result-quality work
([archive/PLAN_catalog_result_quality.md](archive/PLAN_catalog_result_quality.md))
fixed the mechanical failures (strict-AND tags, alphabetical ranking, dead-end
replies). This doc asks what would move the needle *from here*, ranks each
lever by expected impact, and grounds every claim in measurements of the real
dev catalog (5,795 entries, 27 Jul 2026).

## Where the pipeline loses quality today

Think of it as a funnel. A request survives five stages, and each stage leaks:

**1 · The model guesses the vocabulary.** The library's tag vocabulary is
per-machine and the model only learns it *reactively* — after a zero result,
a truncated result, or a reindex (which shows 6 of 174 tags). First attempts
are guesses: "warm" is not a tag here, `Soft` is; "dusty" is not, `Lofi &
Vinyl` is. The model is fully capable of the mapping — it just can't see the
menu before ordering.

**2 · The catalog's semantic signal is thin.** Measured:

- 2.7 tags per entry on average; 2,768 of 5,795 entries carry ≤ 2.
- Descriptions are ~nothing: 1,523 entries have one, but 1,317 of those are
  just "Created by: …" — roughly **200 entries** in the whole library say
  anything real about the sound.
- Identical-tag clusters are huge: outside drums, the largest sets of entries
  sharing *exactly* the same tags are 111, 96, 72, 63, 54 … — the ~46
  `E-Piano *` presets share the tag set `{Synth Keys, Electric Piano}` and
  nothing any scorer could use to tell "Dirt & Gnarl" from "Classic".
- `samples` (3,567 items, FileId-carrying, would be tag-aware for free) is
  not indexed at all — "a vinyl crackle" is unfindable by search while
  `Crackle Vinyl Pop.wav` sits in the browser.

**3 · Structure Ableton has, we flatten.** Live's database groups tags into
axes — **Character** (25 tags: Acoustic, Analog … Dark, Spacious, Textural),
**Genres** (29), Type, Key, Tunings, Devices, and the Sounds taxonomy — via
`files.parent_id`, which `AbletonDB.read_tags/1` discards. The flattening
creates real traps: this catalog holds both `Distortion` (a device-category
tag) and `Distorted` (a character tag), both `Modulation` and `Modulated`.
Search treats them as unrelated strings; the model can't tell them apart
either. Live's DB also maps 4,535 presets to the device they instantiate
(`file_devices`), which we don't read.

**4 · Ranking can't split what the data can't split.** The scorer decides
39/77 benchmark slots (up from 28); the rest are tied bands the round-robin
rotates through. The result-quality work's own conclusion stands: the
residual needs a **new signal**, not new weights.

**5 · Nobody ever listens, and a wrong pick is expensive.** The final "which
of these five is *the* sound" judgment is made on names and tags — never by
ear. `load_device` used to be one-way; `delete_device` + `bypass_device` (see
lever №3 below, shipped 2026-07-28) closed that, so trying a candidate no
longer costs a manual cleanup in Live. That still pushes the whole system
toward one-shot precision when the honest answer for the last mile is
*iteration* — metadata will never distinguish two `Soft` pads as well as ten
seconds of audio.

**6 · Nothing is learned from success.** `use_count`/recency bias future
rankings (good), but the association that matters — *this description* led to
*this accepted preset* — is thrown away.

## The levers, ranked

Impact is judged against one question: of the realistic "describe a sound"
requests that end badly today, what share does this lever rescue?

| # | Lever | Impact | Effort | Depends on |
|---|---|---|---|---|
| 1 | Teach the vocabulary proactively, with axes | **High** | Low | — |
| 2 | Read tag axes + preset→device from Live's DB | **High** (enables 1, 5) | Low-Med | — |
| 3 | Close the loop: delete_device + hot-swap audition | **High** | Med (shipped 2026-07-28) | — |
| 4 | Widen the slate at tied bands | Med-High | Low | — |
| 5 | LLM enrichment at reindex | **Highest ceiling** | High | API key / MCP turn |
| 6 | Browser preview audition | Med-High | Med | vendored handler |
| 7 | Samples index (opt-in) | Med | Med | — |
| 8 | Remember what a description resolved to | Med (compounds) | Low-Med | — |
| 9 | Eval harness for retrieval quality | Enabler | Low-Med | — |

### 1 · Teach the vocabulary proactively, with axes — High impact, low effort

The single cheapest big win. The whole Character axis is 25 tags; Genres is
29. That's ~60 words — trivially affordable in a tool reply — and it converts
the model from guessing tags to *choosing* them: "dusty" → `Lofi & Vinyl`,
"warm" → `Soft`/`Analog`, "huge pad" → `Spacious`/`Evolving` become lookups
the model performs perfectly once it can see the menu. Today that menu is
shown only 6 tags at a time, only after something already went wrong.

Concretely: the first `search_library` reply of a server session (or every
zero/truncated reply) prepends one compact block —

> This library's tags — Character: Acoustic, Analog, … Textural. Genres:
> Ambient, … Trap. Kinds: Kick, Pad, Synth Bass, Electric Piano, …

The tool description can't carry it (compile-time, per-machine), but replies
can, and axis grouping is what makes 60 tags digestible rather than 174
undifferentiated ones. Also fixes the `Distortion`-vs-`Distorted` trap: the
reply can label which is character and which is device category.

*Why it's ranked first:* stage 1 is the funnel's mouth. Every later stage can
only rank what a well-formed query matched. Estimated to rescue the largest
class of bad outcomes — first-attempt vocabulary misses — for a day or two of
work.

### 2 · Read what Ableton already wrote: tag axes and preset→device — High impact, low-medium effort

The data for №1 comes from one schema addition to
[`AbletonDB.read_tags/1`](../lib/seshat/library/ableton_db.ex): join each tag
row to its parent (`files.parent_id`) and keep the axis name. Store tags as
`{axis, name}` (catalog format v3). Beyond feeding №1, axes let the scorer
weight a Character match differently from a device-category match, let
`diagnose/1` suggest within the right axis, and give facets an ordering
that isn't raw frequency.

`file_devices` (4,535 rows) is the same trip: it answers "which synth does
this preset actually run on", enabling "an Operator bass" as a real filter
and folding the AUv2/VST3 plugin-format duplicates recorded in
[archive/catalog-aliasing-options.md](archive/catalog-aliasing-options.md).

*Risk:* the schema is undocumented; keep the existing wrap-everything error
posture (axis becomes `nil`, search degrades to today's behaviour).

### 3 · Close the loop: delete_device + bypass + hot-swap — High impact on the outcome, not on search

**Shipped 2026-07-28** — see
[archive/PLAN_audition_loop.md](archive/PLAN_audition_loop.md). Restated here
because the thesis holds beyond this one feature: forgiveness beats
precision. If trying a candidate costs one sentence ("next"), a slate that's
merely *good* still ends with the right sound loaded — the user's ear does
the last-mile ranking no metadata can. The loop: `load_device` → listen →
"try the next one" → `delete_device` + load next; `bypass_device` gives
effects the same A/B.

*Estimated effect:* converts most "close but not quite" outcomes — which no
retrieval improvement fully eliminates — from failures into one extra turn.

### 4 · Widen the slate where the scorer is blind — Medium-high impact, low effort

When the band straddling the cut is much larger than the slots left (the 46
E-Pianos), the reply currently shows a rotated sample and hides the rest. But
the *names* carry exactly the signal the tags lack — "Dirt & Gnarl",
"Detuned", "Crep Slide" — and the model reads names fluently. Cheap fix: when
a tied band is truncated, append a names-only line for the rest of the band
(names are short; 30 more names ≈ 150 tokens, far cheaper than a second
search). The model then does by reading what no scorer can do by weighting.

This is the honest answer to the "ranking headroom" item on the roadmap:
don't rank the undifferentiated band better — *show it*, compactly.

### 5 · LLM enrichment at reindex — highest ceiling, highest cost

The only lever that adds *new* semantic signal per entry: at reindex time, an
LLM writes 3–6 character tags + a ten-word description for each entry from
its name, device, path, pack and existing tags ("E-Piano Dirt & Gnarl" →
`gritty, distorted, lo-fi, aggressive`). It attacks stage 2 directly —
the 2,768 thin-tagged entries and the 111-deep identical clusters — and its
output feeds every downstream stage: matching, ranking, facets, diagnosis,
and the model's final choice.

Honest caveats, which is why it isn't №1 despite the ceiling:

- **Cost/plumbing:** ~5,800 entries per machine, needs an API key or an
  MCP-client-driven tagging session; reruns after Pack installs.
- **Name-derived tags have a floor:** the LLM sees the same name the
  searching model would see in №4's widened slate. The *marginal* value over
  №4 is real (enriched tags are searchable and rankable, not just readable at
  the cut) but smaller than it first looks.
- Batch it (hundreds of entries per call), cache by FileId, only enrich
  entries below a tag-count threshold — then it's a one-time ~$1-5 pass, not
  a standing cost.

Do it *after* №1/№2/№4 prove insufficient, and *measure* it (№9) — it's the
biggest hammer and the easiest to over-credit.

### 6 · Audition without loading: browser preview — Medium-high impact, medium effort

Live's Python API has `Browser.preview_item(item)` / `stop_preview()`
(confirmed in the [Live API stub](https://github.com/cylab/AbletonLive-API-Stub/blob/master/Live.xml);
it's what Push uses to audition the browser). Two additions to the vendored
[browser.py](../priv/abletonosc/browser.py) (`/live/browser/preview_item`,
`/live/browser/stop_preview`) plus `preview_sound` / `stop_preview` tools
give the flow: present five candidates → preview each for the user → load the
one they name. No track mutation, no cleanup, works for samples too (where
it's the *only* audition path — a sample can't be hot-swap-loaded
meaningfully).

*Risks to verify on a spike:* preview routing depends on the browser's
preview/cue settings; preset (vs sample) preview coverage varies by Pack.
Sequence after №3 — hot-swap is the more universal loop; preview is the
faster, lighter one where it works.

### 7 · Samples index — medium impact, bounded

Coverage, not ranking: today an entire request class ("vinyl crackle",
"riser", "field recording texture") returns nothing from search. Already
spec'd on the roadmap (opt-in walk, FileId-tagged for free, out of default
results). Impact is real but confined to sample-shaped requests; for
melodic-instrument requests it changes nothing. Do the walk-cost check first
(samples is why the 20k-node scan cap exists).

### 8 · Remember what a description resolved to — medium impact, compounds

`record_load/2` already counts loads; the missing half is *why* the load
happened. Persist the accepted search context with it — the query/tags that
produced the loaded uri — and surface it on similar later searches ("for
'warm bass' you previously chose `808 Drifter`"). Cheap version: `Handlers`
keeps the session's last `search_library` args and attaches them to
`record_load`; search adds a small bonus when a past accepted context
overlaps the current request, and the reply *says so*. Over months this
becomes the personalization no factory metadata can provide. Worth doing
early precisely because it only pays off with elapsed time.

### 9 · An eval harness that measures relevance — enabler for everything above

The result-quality work measured "slots decided by score" — a proxy for
tie-breaking, not for *relevance*. Before spending on №5–№7, build the real
yardstick: ~30 natural-language requests ("a dusty lo-fi electric piano", "a
huge dark pad", …) each with a hand-marked set of acceptable presets from
this catalog, scored as hit@5 / hit@15, runnable in `iex` against
`Catalog.search/1` with the model's plausible query formulations. A morning
of listening builds the gold set; every lever above then gets a before/after
number instead of an anecdote. (An LLM-as-judge variant can approximate the
gold set for breadth, with the human set as anchor.)

## What not to do (re-examined, still no)

- **Embeddings / semantic index** — the roadmap's "not planned" stance
  holds, and now with more evidence. Text embeddings would bridge the same
  vocabulary gap №1 closes for ~60 words of reply text, at the cost of a
  model dependency, an index to keep in sync, and a second retrieval path to
  debug. Audio embeddings (CLAP-style) would genuinely solve the last mile —
  but there is no audio to embed without loading and rendering every preset,
  which is a research project, not a feature. The ear-in-the-loop levers
  (№3, №6) buy the same outcome with the user's own ears.
- **A synonym table in the tool** ("warm" → Soft). Hardcodes one library's
  vocabulary and one language's adjectives into the tool layer; №1 gives the
  model the real menu and lets it do what it's already best at.
- **More scorer weight tuning.** Measured to exhaustion by the result-quality
  work: +1 slot across six queries for the best remaining variant. The
  residual is a data problem (№2, №5) and a presentation problem (№4).

## Recommended sequence

1. **№9 eval harness** (a morning) — so everything after has a number.
2. **№2 + №1 axes & proactive vocabulary** (a day or two) — biggest certain
   win, attacks the funnel's mouth.
3. **№4 widened tied-band slate** (hours) — closes the roadmap's "ranking
   headroom" item honestly.
4. **№3 delete_device / hot-swap** — shipped 2026-07-28, the universal
   last-mile loop.
5. **№8 accepted-search memory** (a day) — start accruing personalization now.
6. Then measure, and let the numbers pick between **№5 enrichment**, **№6
   preview**, and **№7 samples** — enrichment only if the eval still shows
   first-slate misses on thin-tagged entries.

If the sequence holds, steps 1–5 are roughly a week of work and address every
stage of the funnel except deep per-entry semantics — which is exactly the
part that should not be bought until the eval proves it's still missing.
