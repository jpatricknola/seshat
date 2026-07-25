> **Archived 2026-07-26 — shipped.** This is the plan as written *before*
> implementation; the code as merged may differ. `reindex_library` and
> `search_library` exist today (`Seshat.Library.Catalog` / `AbletonDB`).
> The still-open follow-ups from this plan now live in [ROADMAP.md](../ROADMAP.md).

# Implementation Plan: Sound Catalog + Smart Instrument Selection

`reindex_library` + `search_library` — tag-aware instrument search

## Context

`list_browser_items` + `load_device` (see
[PLAN_browser_device_loading.md](PLAN_browser_device_loading.md)) made loading
work, but selection is dumb: 267 bass presets come back as a flat list of
names and the LLM picks nearly blind. The fix is a **persistent catalog** that
merges two data sources we already have on disk:

1. **The browser walk** (browser.py) — the only source of loadable `uri`s,
   but no tags and (today) no folder paths.
2. **Ableton's own browser database** — Live 12 ships every factory/Pack
   preset pre-tagged by sound designers (`808 Drifter.adg → 808 Bass | Punchy
   | Sub | Synth Bass`), stored in a readable SQLite file. ~7,600 tagged items
   on this machine. Tags are NOT exposed through the Live Object Model, so
   reading this DB is the only way to get them.

Merged, cached, and served from ETS, this gives instant tag-aware search:
"load a warm analog bass" → `search_library(query: "bass", tags: ["Analog"])`
→ top-5 candidates presented to the user → `load_device`.

**Architecture note:** this does *not* add a database to Seshat. Ableton's
SQLite is read-only source data consulted only at reindex time. Our own store
is one JSON file loaded into ETS by a GenServer — the `Session.State`
pattern. No Ecto. The "LLM does the resolving" rule also stands: the catalog
returns rich rows; ranking and presenting candidates stays in the model.

## Ableton Live DB — reverse-engineered schema (verified on Live 12.3, macOS)

Location: `~/Library/Application Support/Ableton/Live Database/Live-files-<build>.db`
(e.g. `Live-files-12300.db`; pick the newest matching file). WAL mode, open
while Live runs — always open with `?mode=ro` and never write.

| Table | Meaning |
|---|---|
| `files` | Every browser item. `file_id`, `parent_id` (path reconstruction), `name`, `file_type`, `device_id` (e.g. `device:ableton:instr:Drift` — same format as browser uris for core devices) |
| `keywords` | Item↔tag join: `file_id` → `keyw_id`. **Tags are themselves rows in `files`.** `is_auto` flags Live's automatic tags vs deliberate ones |
| `metadata` / `metadata_values` | Per-file key/value: preset descriptions, author credits, device uris |
| `vfolders` / `vfolder_patterns` | Tag-group taxonomy (Sounds/Drums/Audio Effects/MIDI Effects) and Live's own folder-name→tag mapping |
| `ancestors` | Flattened ancestor closure (alternative to walking `parent_id`) |

Working queries (keep for implementation):

```sql
-- tags for every preset
SELECT f.name, GROUP_CONCAT(t.name, '|')
FROM files f
JOIN keywords k ON k.file_id = f.file_id
JOIN files t    ON t.file_id = k.keyw_id
WHERE f.name LIKE '%.adg' OR f.name LIKE '%.adv'
GROUP BY f.file_id;

-- absolute path via recursive parent_id walk
WITH RECURSIVE path(file_id, p) AS (
  SELECT file_id, name FROM files WHERE file_id = :id
  UNION ALL
  SELECT f.file_id, f.name || '/' || path.p
  FROM files f JOIN files c ON c.parent_id = f.file_id
  JOIN path ON path.file_id = c.file_id)
SELECT p FROM path ORDER BY LENGTH(p) DESC LIMIT 1;
```

⚠️ Undocumented schema — may shift between Live versions. Every read is
wrapped so failure degrades to path-derived tags, never breaks search.
User-created tags additionally land as XMP (plain XML) under
`User Library/Ableton Folder Info/12/` — ignore for v1, note as follow-up.

## Part 1 — browser.py: paths in the index + bulk export

Two changes to [priv/abletonosc/browser.py](../priv/abletonosc/browser.py):

1. **Carry folder paths through the DFS.** `_index` stack entries gain the
   parent path (tuple of folder names); cache becomes
   `(name, path, uri, item)`. `/live/browser/get/items` replies gain the path
   (`name, path, uri` triples — bump the reply contract and
   `format_browser_items/2` together) and the filter matches `path + name`,
   not just name.

2. **`/live/browser/export`** — request `[dest_path(s)]`.
   - Walks *all* categories (existing `MAX_SCAN_NODES`/`MAX_DEPTH` caps apply
     per category), then writes one JSON file to `dest_path`:
     `{"category": [{"name":..., "path": "Bass/Sub & Warm", "uri":...}, ...]}`.
   - Reply: success `[dest_path, "ok", total_items]`; error
     `[dest_path, "error", message]`. Same-address reply on every path, as
     the other handlers.
   - Rationale: one OSC round-trip, no UDP datagram-size or 100-item limits.
     Python and Elixir share a filesystem — Elixir passes a path inside the
     scratchdir it controls.
   - Runs on Live's UI thread like everything else; log a warning that the
     UI may hitch for a few seconds. `samples` stays excluded from export in
     v1 (huge, rarely tag-searched — follow-up).

Re-run `mix abletonosc.install` after editing; `/live/api/reload` picks up
edits to an existing module.

## Part 2 — Elixir: `Seshat.Library.AbletonDB` (read-only tag reader)

New module, no GenServer — pure functions called at reindex time:

- `locate_db/0`: newest `Live-files-*.db` under
  `~/Library/Application Support/Ableton/Live Database/` (macOS; Windows
  location is a follow-up — return `{:error, :not_found}` cleanly).
- `read_tags/1`: open with `exqlite` in read-only mode; return
  `%{file_id => %{name: ..., tags: [...], description: ..., device_id: ...}}`
  using the queries above — `file_id` is the join key because browser uris
  embed it as `FileId_<n>` (see merge section). Path reconstruction is only
  needed if we also want absolute paths in catalog entries (nice for debug,
  not required for the join).
- Any error (missing db, schema drift, locked file) → `{:error, reason}`;
  the caller treats tags as simply unavailable.

New dep: `{:exqlite, "~> 0.27"}` — the bare SQLite3 NIF, **not**
`ecto_sqlite3`. This is the whole "database" footprint.

## Part 3 — Elixir: `Seshat.Library.Catalog` (the persistent layer)

GenServer + ETS table, added to the supervision tree next to
`Session.State`:

- **Persistence:** `~/.seshat/catalog.json` (create dir on first write;
  overridable via app env for tests). Loaded into ETS on boot; missing file
  = empty catalog, tools fall back to `list_browser_items`.
- **Entry shape:**
  `%{uri, name, category, path, tags, tag_source (:ableton | :path | :llm),
  description, use_count, last_loaded_at}`.
- **`reindex/0`:** ask Transport to `query("/live/browser/export", [tmp_path], 60_000)`
  → parse export JSON → `AbletonDB.read_tags/1` → **merge** → write
  `catalog.json` → reload ETS. Returns `{:ok, %{items: n, tagged: m}}`.
- **Merge (pure function, unit-testable):** the join is **exact, verified
  live on this machine**. Preset/sample browser uris embed the DB primary
  key: `query:Sounds#Bass:FileId_5200` → `files.file_id = 5200` → tags.
  This is structural, not coincidental — Live's browser is backed by this
  database (the `Ableton Index` helper process maintains it), so uri and
  DB captured at the same reindex are always consistent. Join order:
  (a) parse `FileId_<n>` from the uri → `files.file_id` (covers presets,
  samples, drum hits — ~95% of preset rows carry tags); (b) bare core
  devices (`query:Synths#Analog`, no FileId) → match `files` rows by
  `device_id`/name — a set of ~50, and device rows carry tags too;
  (c) anything unmatched gets path-derived tags (path segments as tags,
  `tag_source: :path`).
- **`search/1`:** ETS scan with options `query` (case-insensitive AND-of-terms
  over name+path+tags+description), `tags` (must-have list), `category`,
  `max_results`. At catalog scale (~10–20k rows) a full scan is
  single-digit ms — no index needed.
- **`record_load/1`:** bump `use_count`/`last_loaded_at` for a uri; called
  from the `load_device` handler on success. Async write-behind of the JSON
  file (`Process.send_after` debounce) so loads never block on disk.

## Part 4 — Tools (37 → 39)

Per [adding-a-tool.md](../.claude/docs/adding-a-tool.md):

- **`search_library(query, tags, category, max_results)`** — description must
  teach the selection workflow, since it's the whole prompt in MCP mode:
  search the catalog first (instant, tag-aware); prefer it over
  `list_browser_items` whenever it returns results; **consider the musical
  context from get_session_state and the conversation (genre, tempo, other
  tracks) when ranking**; present the top 3–5 candidates to the user with a
  one-line reason each instead of silently loading the first hit — unless the
  user asked you to just pick; tags are curated by Ableton (list the common
  character tags: Analog, Digital, Bright, Punchy, Sub, Distorted, Rhythmic,
  808 Bass…); if the catalog is empty, say so and offer `reindex_library`.
  Handler formats rows as `name — tags [path] (uri)` lines.
- **`reindex_library()`** — no params. Description: run once on first use and
  after installing new Packs/presets; takes up to a minute; Live's UI may
  hitch. Handler `catch :exit` → "export timed out — is Ableton running?"
- **`load_device`** — handler gains a `Catalog.record_load(uri)` on the
  success path (no definition change). Also update `list_browser_items`'s
  description to mention `search_library` as the preferred first stop.

## Part 5 — Tests + docs

1. [definitions_test.exs](../test/seshat/tools/definitions_test.exs): 37 → 39
   + names. MCP parity is automatic.
2. Unit tests (no Ableton): merge/join (device_id match, trailing-path match,
   unmatched → path tags), `search/1` (AND-terms, tag filter, empty catalog),
   catalog persistence round-trip (tmp dir via app env,
   `start_supervised!`), `AbletonDB.read_tags/1` against a tiny fixture
   SQLite file checked into `test/support/fixtures/` (build it in the test
   setup with exqlite — 3 files, 2 tags — so we also document the schema we
   depend on as executable code).
3. [abletonosc-api-docs.md](abletonosc-api-docs.md): add `/live/browser/export`
   + the reply-shape change to `/live/browser/get/items` under the Seshat
   extension section.
4. [CLAUDE.md](../CLAUDE.md): 37 → 39, module-map rows for
   `Seshat.Library.Catalog` / `Seshat.Library.AbletonDB`, one line on
   `~/.seshat/catalog.json`. [README.md](../README.md): reindex step.
5. `mix precommit`.

**Sequencing:** browser.py (paths + export) → AbletonDB reader → Catalog +
merge → tools/handlers → tests → docs → `mix precommit`.

## Verification (end-to-end, needs Ableton Live running)

1. `mix abletonosc.install`, reload, `Transport.query("/live/browser/export", [path], 60_000)`
   → "ok" + count; JSON file parses; paths present.
2. `iex`: `AbletonDB.read_tags(db)` returns tags for a known preset
   (`808 Drifter.adg → 808 Bass, Punchy, Sub, ...`); works while Live is
   open (WAL read-only).
3. `Catalog.reindex()` → tagged-match rate printed; expect ~95% `:ableton`
   tags on presets (measured: 3,073 of 3,238 preset rows in this machine's
   DB carry tags, and FileId spot-checks matched 4/4 across sounds, drums,
   audio_effects, instruments).
4. MCP workflow: "load a warm analog bass on track 1" → `search_library`
   → model presents 5 candidates with reasons → user picks → `load_device`
   → correct device lands, `use_count` bumped.
5. Kill Ableton: `search_library` still answers from the persisted catalog;
   `reindex_library` fails with the actionable timeout message.
6. `mix precommit` green with Ableton closed.

## Risks / follow-ups

- ~~Path join rate~~ **resolved**: uris embed `files.file_id` directly
  (verified live — see merge section), so the join is exact, not
  heuristic. Path matching survives only as the tier-(c) fallback.
- **Ableton schema drift** — the dependency surface is now just
  `files(file_id, name, device_id)` + `keywords`, which shrinks the risk;
  the DB filename encodes the build (`Live-files-12300.db` serves every
  installed 12.3.x here), so a schema change arrives as a new filename,
  not a silent mutation. Every AbletonDB read still fails soft, and the
  fixture test documents exactly what we assume. FileIds are only
  meaningful against the same DB build the uris came from — never join
  fresh uris against a stale DB read or vice versa; do both in one
  reindex pass (which the design already does).
- **Staleness** — reindex is manual by design. A failed `load_device` on a
  stale uri already errors cleanly; the tool description tells the model to
  suggest reindexing.
- Follow-ups, deliberately out of v1: LLM enrichment for untagged/third-party
  items (needs an API key or an MCP-client-driven tagging turn); user XMP tag
  reading; `samples` category export; Windows DB location; audition/hot-swap
  loop (`delete_device` tool) from the selection brainstorm — composes on top
  of this unchanged.
