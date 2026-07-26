# Catalog aliasing: what to do about duplicate presets

> **Archived 2026-07-27 — shipped.** This is the decision record as written
> around implementation; the code as merged may differ. The fold lives in
> `Seshat.Library.Catalog.normalize/1` (PR #19); the still-open follow-ups
> (ranking, tag scoring, vocabulary, samples) are tracked in
> [ROADMAP.md](../ROADMAP.md) § Catalog result quality. The plugin-territory
> evidence near the top postdates the decision and remains the reference for
> any future plugin folding.

Live files one preset under every device that can open it and bakes the
browser path into the uri, so a single `.adg` shows up in the catalog several
times over. `search_library` then shows the user the same preset four times.
This note records the options. **Decision: Option 2, shipped** — `normalize/1`
folds rows into one entry per preset at index time, `catalog.json` is format
version 2. Verified against the full 8,222-row catalog: it folds to 5,729
presets, every path, uri and category survives, the canonical uri is always one
Live actually gave us, and the result is deterministic. Across eight realistic
searches the distinct presets offered in a 25-slot result went from 11–13 to
25.

Options 1 and 3 are kept below as the record of what was weighed.

Two facts about how Seshat is actually used set the weighting, and they cut
against the migration-risk case for keeping the on-disk format frozen:

- **One user.** There is no installed base to migrate.
- **Reindexing is routine.** It is already expected after every new Pack,
  plugin, or saved preset — so a format change riding along with a reindex the
  user would run anyway costs close to nothing.

## The shape of the problem

Measured against a real 8,222-entry catalog:

```
Sweet Lead.adg  →  query:Synths#Analog:Synth%20Lead:FileId_4674
                   query:Synths#Instrument%20Rack:Synth%20Lead:FileId_4674
                   query:Synths#Operator:Synth%20Lead:FileId_4674
                   query:Sounds#Synth%20Lead:FileId_4674
```

One file, one FileId, four rows, two categories, four distinct uris. ~30% of
the catalog is these aliases: 1,798 clusters covering 2,493 surplus rows.
Collapsing them would take **8,222 → 5,729**.

**FileId is a perfect key**, which is what makes any of this safe. Across all
1,798 multi-row clusters:

| field | differs in |
|---|---|
| name | **0** of 1798 |
| tags | **0** of 1798 |
| description | **0** of 1798 |
| category | 1747 — always `instruments` + `sounds` |
| path | 1798 — the only genuine variance |

Zero clusters where two different names share a FileId, and no false merges.

**Scope of this evidence.** It is one machine's catalog, and it is entirely
Ableton factory content: the only categories present are `audio_effects`,
`drums`, `instruments`, `midi_effects`, `sounds`. `EXPORT_CATEGORIES` also
walks `plugins` and `user_library`, and both returned nothing here — so the
"FileId is a perfect key" result is untested against third-party plugins and
user-saved presets, which is where naming and FileId behaviour would be most
likely to diverge. Re-run the clustering check after the first Pack or saved
preset lands.

**Plugins landed, check re-run (27 Jul 2026).** The empty `plugins` walk turned
out to be Live configuration, not a broken walk: plugin sources were disabled
in Preferences → Plug-Ins (`Live-plugins-1.db` had zero rows). Enabling
AUv2/AUv3/VST3 and rescanning produced 66 plugin rows (Apple stock AUs + a
Native Instruments/iZotope collection), and the clustering check still holds on
the resulting 5,795-entry catalog: **no plugin uri carries a FileId** (shape:
`query:Plugins#VST3:Native%20Instruments:Kontakt`), so the fold leaves every
plugin row alone, and across the whole catalog no FileId is shared by two
different names. Two new facts for any future plugin folding: (1) a plugin
installed in two formats is two rows — 19 AUv2/VST3 pairs (Kontakt, Massive,
Ozone 11…) that a FileId key cannot see; (2) the format trees are *not*
mirrors (`Maschine 2 MFX` is AUv2-only, `Reaktor 6 FX` VST3-only), so a naive
name fold is wrong and any fold would need a (vendor, name)-within-`plugins`
rule plus a deliberate format preference. Left unfolded for now — same
one-surplus-row trade as Drum Rack, times nineteen.

**Alias equivalence probed (27 Jul 2026).** The "worth probing out of
interest" check above was run: Sweet Lead loaded onto a scratch track via
`query:Sounds#Synth%20Lead:FileId_4674` and via
`query:Synths#Operator:Synth%20Lead:FileId_4674` lands the identical device
("Sweet Lead", `InstrumentGroupDevice`) both times. Alias interchangeability
is now observed fact, not inference.

One alias escapes it. Counting surplus rows by *name* gives 2,494, one more
than FileId finds — the straggler is **Drum Rack**, a core device carrying no
FileId at all, listed under both `drums` and `instruments`:

```
query:Drums#Drum%20Rack
query:Synths#Drum%20Rack
```

86 entries have no FileId, and this is the only aliased pair among them. So a
FileId-keyed collapse is 2493/2494 complete; catching the last one means
falling back to name+tags for FileId-less rows, which is worth doing only if
Option 2 is taken — Option 1 collapses on whatever key it likes without
committing to it on disk.

So a collapse is lossless except in `category` and `path` — and both of those
losses hurt search. Dropping alternate categories makes a `category: "sounds"`
filter miss 1,747 presets; dropping alternate paths stops "operator" from
finding Operator presets.

## Why `categories` has to be plural

`instruments` and `sounds` are not peer categories — `sounds` is a
character-organized *view* over the same preset files that `instruments`
organizes by device. Three checks agree:

- **Depth.** All 1,856 `sounds` rows are depth 1 (`Synth Lead`). Instrument
  presets are depth 2 (`Analog/Synth Lead`) — device, then character.
- **Exact relation.** In all 1,747 clusters spanning both, the `sounds` path
  equals the `instruments` path minus its device prefix. 1747/1747, no
  exceptions.
- **Vocabulary.** Top-level segments under `instruments` are device names
  (Analog, Operator, Wavetable, Instrument Rack…); under `sounds` they are
  sonic characters (Bass, Pad, Strings, Ambient & Evolving…).

It is not a *pure* view, and that is what settles the schema. Distinct presets:
1,782 in `instruments`, 1,805 in `sounds`, 1,747 in both — leaving 35
instruments-only and 58 sounds-only. Neither side is derivable from the other,
so a collapse cannot pick a canonical category and reconstruct the rest.
`categories: [...]` it is.

### Adjacent gap, deliberately out of scope

`category` also conflates *what a thing is* with *where the browser files it*.
23 of the `instruments` rows are not presets but the devices themselves —
Analog, Collision, Operator, Wavetable, Drum Rack, DS Kick, External
Instrument — carrying no FileId because no preset file backs them. That
device/preset distinction is invisible in the current schema, and it is the
real reason **Drum Rack** is the one alias a FileId key cannot catch: it is a
device listed under both the `drums` and `instruments` roots.

Worth modelling eventually, so `search_library` can separate "the Operator
device" from "an Operator preset". Not part of the aliasing fix.

## Option 1 — collapse at search time

Catalog on disk stays a faithful mirror of Live's browser. `search/1` matches
against every row, then groups the matches by FileId before truncating to
`max_results`, showing one row per preset with its alternate paths listed.

- **For:** no schema change, no version bump, no migration. Recall is
  preserved for free — all four rows still match, the collapse is
  presentation-only. Fixes the user-visible symptom, which is entirely in
  `search_library` output.
- **Against:** every consumer of the raw table must collapse for itself, or
  get duplicates. `count/1` still reports 8,222, which reads as wrong. Grouping
  work repeats on every query — cheap, since it runs on the matched set rather
  than all 8k rows, but not free. And `catalog.json` on disk stays as noisy as
  it is today: dev deliberately pretty-prints it to be read by eye
  (`:catalog_pretty`), and this option leaves 30% of what you'd be reading as
  alias rows.

## Option 2 — normalize at index time (recommended)

Collapse in the pipeline after `merge/2` and before `carry_over_usage/2`.
Staying lossless means making the two varying fields plural: `categories:
[...]`, `paths: [...]`.

- **For:** one row per preset everywhere, so nothing downstream can get this
  wrong. `count/1` becomes honest. The work happens once per reindex instead
  of once per query. Smaller, much more readable file — 5,729 rows instead of
  8,222, which matters because dev pretty-prints it to be read by eye.
- **Against:** a schema change that ripples into `to_json`/`from_json`, the
  search filters, `format_catalog_entries`, the fixture and its tests. Six
  touch points, mechanical but real. Changing the rules later means a reindex.
- **On the format version:** `@format_version` is written by `write_file/2` but
  never read — `load_file/1` matches only on `"entries"`. So an old catalog
  would feed v1 rows to a v2 `from_json/1`, yielding empty `categories`/`paths`
  on every entry: no error, no crash, but category filters return nothing and
  the haystack loses the path. The fix is ~4 lines (require the version in the
  `load_file/1` pattern; return `:stale_format` otherwise). Worth doing, but it
  is insurance, not a reason to prefer another option.
- **Note:** if this is taken, normalization should be a pure `normalize/1`
  called from the pipeline — not a separate post-hoc task. A task would leave
  the catalog in two possible on-disk states, making `search_library` behave
  differently depending on whether someone remembered to run it. A thin `mix`
  task re-applying `normalize/1` to an existing `catalog.json` is fine as a dev
  convenience for iterating on rules without Live, but never as a required step.

## Option 3 — leave it, document it

Record the wart in [TOOL_AUDIT.md](TOOL_AUDIT.md) with the numbers above and
keep the test that pins current behaviour.

- **For:** costs nothing, loses nothing — the analysis is captured either way.
  Duplicate results may simply not annoy anyone in practice; the LLM reads all
  four rows and picks one, and it is the *user* who sees the repetition, not
  the model.
- **Against:** duplicates burn `max_results` slots, so a search capped at 20
  may surface only 7 distinct presets. That degrades the tool quietly, in the
  direction of "Seshat couldn't find much".

## Alias equivalence is already assumed, today

It is tempting to treat "do a preset's alias uris all load the same device?" as
a prerequisite for collapsing. It isn't — the current code already bets on it.

Nobody loads a preset by choosing among its aliases. The model calls
`search_library`, takes **one** uri from the results, and passes it to
`load_device`. So the only question that matters is which alias search puts
first — and today that is arbitrary:

- The ETS table is `:set`, so `:ets.select/2` returns rows in unspecified hash
  order.
- Ranking is `Enum.sort_by(&{-score(&1, opts), &1.name})`. Across a preset's
  aliases every component is identical — same name, same tags, same
  `tag_source`, hence the same `name_score` and `tag_score`. Unless `use_count`
  has diverged they tie exactly.
- `Enum.sort_by/2` is stable, so the tie preserves ETS hash order.

Which alias reaches `load_device` is therefore already unspecified, and not
stable across reindexes. If the aliases were *not* interchangeable, that would
be a live bug now, surfacing non-deterministically.

So this is not a gate on either option. Collapsing replaces an arbitrary pick
with a deliberate one, which is strictly better. Worth probing out of interest
— load one preset via two of its uris and compare the `_loaded_device_name`
reply — but its absence blocks nothing.

The check that does matter is the end-to-end one in
[validation-script.md](validation-script.md) and `/smoke-test`: ask for a sound
by description and see whether the right thing lands. That exercises the goal;
comparing uris exercises a path no caller takes.

## When to reopen

If Option 3 is taken, revisit when repeated results demonstrably cost a real
session — a search that returned nothing useful because the cap filled with
aliases. That's the symptom worth spending a schema change on.

If Seshat ever gains users beyond its author, revisit the weighting at the top
of this note: an installed base makes an on-disk format change expensive in a
way it currently isn't, and would push the balance back toward Option 1.
