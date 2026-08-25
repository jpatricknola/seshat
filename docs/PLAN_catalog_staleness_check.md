# Plan: Catalog staleness check — notice without being asked

Roadmap item: **"Catalog staleness check — notice without being asked"**.

## Context

`search_library` can serve a valid but outdated `catalog.json` indefinitely after
the user installs a Pack, plugin, or preset. The user currently has to remember
that a reindex exists and decide when it is needed. Ableton's browser database is
the source used during reindexing, so its modification time is a cheap local
freshness signal: when it is newer than the catalog's build timestamp, search can
return the still-usable results while warning that a rebuild is available.

The writer already records `indexed_at`, but research found a load-bearing bug:
every debounced usage-counter write currently regenerates that timestamp. Loading
one device could therefore make an old catalog appear newly indexed. The build
timestamp must belong to the browser export/reindex and survive all later usage
writes unchanged.

This lands with the atomic writer because both features depend on the same
persistence metadata and error paths.

## OSC contract

No OSC addresses, Transport calls, AbletonOSC changes, install, or Live restart.
Freshness uses only `catalog.json` and the database path already resolved by
`Seshat.Library.AbletonDB.locate_db/1`.

## Part 1 — preserve and expose catalog build time

In `lib/seshat/library/catalog.ex`:

- Decode `indexed_at` with the persisted entries and keep it in the Catalog
  GenServer state.
- Assign a new UTC build timestamp only for `{:replace, entries}` (the successful
  in-memory half of reindexing).
- Pass that same timestamp through atomic reindex writes, debounced usage writes,
  explicit flushes, and termination flushes. A usage write must never make the
  catalog look freshly rebuilt.
- Add `Catalog.freshness/1`, returning `:fresh`, `:stale`, `:missing`, or
  `:unknown`. It checks that the persistence file still exists, resolves the
  newest Ableton database through `AbletonDB.locate_db/1`, and compares its mtime
  with the retained build timestamp. Missing/unparseable build metadata is stale;
  an unavailable database is unknown rather than a warning, so offline search
  continues quietly.
- Accept an optional database directory in Catalog start options so tests can use
  isolated fixture paths without changing global application configuration.

## Part 2 — surface freshness from `search_library`

In `lib/seshat/tools/handlers.ex`:

- Check freshness at the start of a populated-catalog search.
- For `:stale`, return the normal usable results plus a notice that Ableton's
  library changed since the catalog was built. Tell the model to warn the user
  and offer `reindex_library`, including that it can take up to a minute and make
  Live's UI temporarily unresponsive.
- For `:missing` while ETS still has entries, return those in-memory results with
  equivalent rebuild guidance. The existing empty-catalog error remains the
  first-use path.
- `:fresh` and `:unknown` add no text. A missing Ableton database must not break
  the catalog's documented offline-search behavior.

## Part 3 — tests

In `test/seshat/library/catalog_test.exs`:

- Pin fresh, stale, missing-file, missing-database, and invalid/missing build-time
  outcomes against isolated temporary files.
- Prove a usage-counter flush preserves `indexed_at` rather than advancing it.
- Keep the atomic-write and persistence-failure coverage from the paired change.

In `test/seshat/tools/handlers_test.exs`:

- Exercise a populated stale catalog through the real `search_library` dispatch
  and pin the warning, reindex offer, duration, and Live UI warning.
- Prove fresh and unavailable-database searches do not gain a warning.

Run `mix precommit` after all parts.

## Live verification

No OSC behavior changed, but pure tests cannot establish whether ordinary Live
startup/shutdown activity changes the browser database mtime without changing
its contents.

- `smoke_tests/manual/engineered-state.md § An unchanged library stays fresh across a Live restart` — verifies that a normal SQLite checkpoint does not turn freshness into a recurring false warning.

**Uncovered:** installing a real Pack while Live is running. The unit suite pins
that a newer `-wal` file marks the catalog stale, but no Pack should be installed
only to manufacture that condition.

## Out of scope

- Automatically running `reindex_library`. The rebuild remains explicit because
  it can take up to a minute and freeze Live's UI.
- Polling or a startup reindex. A check without a connected conversation has no
  useful place to deliver the warning.
- Windows database discovery. `AbletonDB.locate_db/1` continues to fail soft on
  unsupported layouts, which freshness reports as `:unknown`.
- Comparing plugin folders or User Library paths directly. Ableton's selected
  browser database remains the single cheap signal named by the roadmap item.
