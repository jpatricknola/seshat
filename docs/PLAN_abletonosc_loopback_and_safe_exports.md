# Implementation Plan: Loopback-only AbletonOSC and safe browser exports

Roadmap items #1 and #2 — one AbletonOSC fork commit, one submodule pin bump,
one install, and one Live restart.

## Context

AbletonOSC currently creates its command socket on `0.0.0.0:11000`, so every
OSC address that can control Live is reachable from any host allowed through
the machine's network boundary. After every received datagram it also rewrites
the default reply destination to that sender's IP. Direct callback replies and
asynchronous pushes are different paths in the implementation:

- `OSCServer.process_message/2` sends a callback's returned tuple to the
  originating IP on the fixed response port, 11001.
- listeners, `/live/startup`, `/live/error`, `/live/test`, and other callbacks
  that call `OSCServer.send/3` themselves use the mutable default
  `_remote_addr`.

Seshat needs neither upstream behavior. `Manager` constructs `OSCServer` with
its defaults, the Elixir transport always sends to `127.0.0.1:11000`, and no
other component in this repository uses networked OSC control. The boundary
can therefore be made local-only without adding configuration or changing any
tool.

Roadmap #2 rides with this change because it touches the same fork and otherwise
costs a second submodule commit, install, and Live restart.
`/live/browser/export` currently accepts an arbitrary destination path and opens
it with Live's privileges. The roadmap proposed reducing that input to a
filename. Reading the call chain surfaced a smaller and safer contract: there is
only one client, and it does not need to choose the name at all. Python can
create a unique file inside `~/.seshat/browser-exports/` and return the resolved
absolute path. Removing the input entirely eliminates traversal and collision
rules instead of trying to enumerate them.

The fork is a submodule. Implementation therefore follows the repository's
two-commit delivery rule: check out `priv/AbletonOSC`'s `master`, commit and
push the Python plus `SESHAT.md` there, then commit the resulting submodule pin
with the Elixir, tests, and docs in Seshat. Live runs the installed copy, not
the submodule, so `mix abletonosc.install` and a Live restart are required
before runtime verification means anything.

## OSC and network contract

### UDP boundary

| Flow | Source | Destination | Contract |
|---|---|---|---|
| Commands | `127.0.0.1:11001` — `Transport` sends from the socket it binds, ephemeral only in its deaf fallback | `127.0.0.1:11000` | AbletonOSC accepts IPv4 loopback traffic only |
| Callback replies | `127.0.0.1:11000` | originating loopback IP, port `11001` | Existing address and argument shapes stay unchanged |
| Listener/status pushes | `127.0.0.1:11000` | fixed `127.0.0.1:11001` | The destination never changes in response to incoming traffic |

`OSCServer.__init__` keeps its `local_addr` and `remote_addr` parameters for
unit reuse, but its default `local_addr` changes from
`("0.0.0.0", OSC_LISTEN_PORT)` to
`("127.0.0.1", OSC_LISTEN_PORT)`. `process()` stops assigning to
`self._remote_addr`. The per-message reply path in `process_message()` remains
unchanged: after the bind change, the only possible sender hostname is
loopback, and retaining that path is less invasive than rewriting reply
dispatch.

No authentication token is added to OSC. Remote control, if it is ever wanted,
belongs behind the deployment-gated authenticated HTTP surface; it must not
reopen the UDP socket by restoring the wildcard default.

### Changed browser-export address

| Address | Request | Success reply | Error reply |
|---|---|---|---|
| `/live/browser/export` | no arguments | `resolved_absolute_path, "ok", total_items` | `resolved_absolute_path_or_empty, "error", message` |

The export JSON schema and category behavior stay unchanged:

```json
{
  "sounds": [
    {
      "name": "808 Drifter.adg",
      "path": "Bass/808 & Sub",
      "uri": "query:Sounds#Bass:FileId_5200"
    }
  ]
}
```

The handler rejects any supplied arguments. It writes only a uniquely created
regular file matching
`~/.seshat/browser-exports/seshat-browser-export-*.json`. Python returns the
normalized absolute path it actually used; Elixir treats that value as
untrusted until it proves that the file is a non-symlinked regular file directly
inside the expected export directory with the expected name shape.

This is a breaking wire change by design. There is no compatibility path for
the old `[dest_path]` request: older Elixir and newer Python, or vice versa,
must fail clearly and require `mix abletonosc.install`, not silently retain the
unsafe behavior.

Every other OSC address, request argument list, and reply shape remains
unchanged.

## Part 1 — Fork: make the AbletonOSC network boundary local-only

Files in the submodule:

- `priv/AbletonOSC/abletonosc/osc_server.py`
- `priv/AbletonOSC/SESHAT.md`

Implementation:

1. Change `OSCServer.__init__`'s default `local_addr` to
   `("127.0.0.1", OSC_LISTEN_PORT)` and update its docstring to state that
   Seshat's fork is local-only by default.
2. Remove the `process()` assignment that rewrites `_remote_addr` from the
   latest datagram's source. Remove the associated comment claiming
   multi-client listener routing is intended.
3. Keep `remote_addr=("127.0.0.1", OSC_RESPONSE_PORT)` and the explicit
   per-callback reply routing in `process_message()` unchanged.
4. Add a `SESHAT.md` entry under fixes to upstream code that records both
   deviations, why upstream deliberately differs, and the merge hazard. State
   that a future network controller gets an explicit opt-in bind constant
   rather than a restored wildcard.

There is no `Manager` change: it already constructs `OSCServer()` with no
arguments and logs `_local_addr`, so the new default is used and visible in
Live's log automatically.

## Part 2 — Fork: make browser exports caller-path-free

Files in the submodule:

- `priv/AbletonOSC/abletonosc/browser.py`
- `priv/AbletonOSC/SESHAT.md`

Implementation:

1. Add an export-root constant resolved with
   `os.path.abspath(os.path.expanduser("~/.seshat/browser-exports"))`.
   **Not `os.path.realpath`**: Elixir derives the same root with
   `Path.expand/1`, which does not resolve symlinks, so a symlinked `~/.seshat`
   would make Python return a path under the link *target* and fail Elixir's
   root check on every reindex. `realpath` buys nothing here either — a
   symlinked export directory is written through by both spellings; the guard
   against a hostile final component is `mkstemp`'s exclusive create on the
   Python side and `File.lstat/1` on the Elixir side.
2. Change `_export/1` to reject non-empty `params`, log the rejection at error
   level (the only place a caller sending the obsolete `[dest_path]` form can
   observe what happened — its reply goes to port 11001, not to the sender's
   socket), and describe the new no-argument contract in the module header.
3. Keep the existing category walk and "no categories indexed" error before
   allocating an output file.
4. Create the export directory with owner-only permissions where the embedded
   Python runtime permits it, then use `tempfile.mkstemp` in that directory
   with prefix `seshat-browser-export-` and suffix `.json`. `mkstemp` supplies
   exclusive creation and a mode that is not widened by this code.
5. Add a stale-export cleanup helper and run it when `BrowserHandler` starts
   and immediately before creating a new export. It may remove only direct
   children of the export root whose basename matches
   `seshat-browser-export-*.json`, whose `os.lstat` mode is a regular file, and
   whose modification time is at least ten minutes old. It must leave fresh
   matching files, symlinks, directories, and every non-matching entry alone;
   log per-file inspection or removal failures and continue. Elixir can no
   longer clean up a file whose name it never learned: a query timeout, a lost
   reply datagram, or failed Elixir path validation can leave a multi-megabyte
   orphan in a directory the OS does not sweep. The age gate is load-bearing:
   `Transport` does not yet serialize queries, so an unconditional sweep could
   delete a completed export before an overlapping caller reads it. Ten minutes
   is comfortably beyond the 120-second query timeout while still bounding
   orphan retention across the next export or AbletonOSC restart.
6. Write JSON through `os.fdopen(fd, "w")`. On encoding or write failure,
   close the descriptor, remove the partial file, log the failure, and return
   an error envelope. No partial pathname survives an error.
7. Return the normalized absolute path on success.
8. Update `SESHAT.md`'s BrowserHandler entry with the fixed-directory,
   Python-generated-file contract.

Parts 1 and 2 land in one commit on the fork's `master` branch and are pushed
before the parent repository records the new submodule SHA.

## Part 3 — Elixir: consume and clean up only validated export files

File:

- `lib/seshat/library/catalog.ex`

Implementation:

1. Remove `Catalog.reindex/1`'s `System.tmp_dir!/0` path generation and call
   `Transport.query("/live/browser/export", [], @export_timeout)`.
2. On an `"ok"` reply, normalize and validate the returned path before any
   filesystem operation:
   - its parent is exactly `Path.expand("~/.seshat/browser-exports")` — the
     same string Python produces with `expanduser` + `abspath` (Part 2, step 1);
   - its basename matches `seshat-browser-export-*.json`;
   - `File.lstat/1` reports a regular file, not a symlink or directory.
3. Expose the path check as a small `@doc false` helper taking both `path` and
   `expected_root`, so tests can exercise it against a tmp root instead of the
   user's home directory. The helper owns the `File.lstat/1` check too — it is
   not purely path arithmetic, and splitting the filesystem half back out is
   how that half ends up untested.
4. Read and decode only a validated file. Return an actionable error for an
   unsafe path, a stale extension reply shape, an unreadable file, or invalid
   JSON.
5. Carry the validated path alongside the decoded export long enough for
   `reindex/1` to remove it in an `after` block. Cleanup must run after every
   downstream outcome—merge failure, catalog persistence failure, or success.
   Never call `File.rm/1` on an unvalidated reply path.
6. Match the new error envelope explicitly. A reply in the old contract or a
   timeout says to rerun `mix abletonosc.install` and restart Live rather than
   implying that reindex succeeded.

The catalog's persisted `catalog.json`, ETS replacement, Ableton database
merge, and tool reply remain otherwise unchanged.

## Part 4 — Regression tests

Files:

- `test/seshat/osc/vendored_addresses_test.exs`
- `test/seshat/library/catalog_test.exs`
- `test/mix/tasks/abletonosc_install_test.exs`

Pure checks, with Ableton closed:

1. Add a merge-regression tripwire for the fork's network boundary:
   - `osc_server.py` contains the loopback default;
   - it no longer contains the last-sender `_remote_addr` assignment;
   - `SESHAT.md` records the divergence.
   This follows the existing source-level guard for the listener-unbind fix:
   the behavior runs only inside Live, while an upstream merge is the likely
   way it regresses.
2. Extend the source-level browser-export tripwire:
   - the handler no longer derives a destination from request parameters;
   - it creates exports with `mkstemp` under the fixed export root;
   - stale cleanup has both the ten-minute age gate and an `os.lstat`
     regular-file guard.
   These assertions protect the security contract across upstream merges; the
   Live smoke test remains the behavioral proof because importing the handler
   requires Live's embedded Python environment.
3. Unit-test the catalog path helper:
   - accepts an expected regular export file;
   - rejects a path outside the root;
   - rejects a nested path, wrong prefix/suffix, missing file, directory, and
     symlink;
   - normalization cannot turn `..` into an accepted outside path.
4. Extend the installer fixture assertion so the installed
   `abletonosc/osc_server.py` and `abletonosc/browser.py` are byte-identical to
   the submodule copies. The wholesale-copy and idempotence tests otherwise
   remain unchanged.
5. Do not import or run the fork's Python pytest package: collection sends
   `/live/api/reload` to Live. Syntax-check the changed Python by hand instead
   (Testing step 4) — **do not add an ExUnit test that shells out to
   `python3`**. Nothing in `mix test` invokes Python today, and `mix precommit`
   must not start depending on an interpreter that Live supplies and this
   repository does not.

No test calls `Transport.query/3`, opens production OSC ports, or depends on
Ableton.

## Part 5 — Canonical documentation and guardrails

Files:

- `docs/abletonosc-api-docs.md`
- `.claude/docs/ableton-osc-reference.md`
- `.claude/rules/osc.md`
- `.claude/skills/smoke-test/SKILL.md`
- `README.md`
- `CLAUDE.md`
- `priv/AbletonOSC/SESHAT.md` (committed in the fork in Parts 1–2)

Changes:

1. The API reference names `127.0.0.1:11000` as the command destination,
   explains that replies and listener pushes are fixed to loopback port
   11001, and replaces `/live/browser/export`'s old path-taking rows and prose
   with the no-argument contract.
2. The OSC working notes record the loopback-only invariant and remove the
   statement that replies generally follow an arbitrary originating IP.
3. The OSC rule says never widen either UDP bind or restore reply retargeting
   without first activating and completing the deployment-gated security work.
4. The smoke-test skill gains the installed-bind and export checks from the
   Testing section below.
5. The README's port description states that both halves of the bridge are
   local-only.
6. `CLAUDE.md`'s fork sections gain `osc_server.py`. Today it enumerates the
   fork's divergences as three handler modules of our own plus two additions to
   `view.py`, and names `_stop_listen` as the one *fix* to upstream code —
   `osc_server.py` becomes a third kind of divergence, a deliberate **change**
   to upstream behaviour rather than an extension. That list is what a future
   session and a future upstream merge read to know which upstream files we have
   touched, so a divergence missing from it is invisible outside the fork's own
   `SESHAT.md`. Name the new `vendored_addresses_test` tripwire alongside the
   `_stop_listen` one in the same paragraph.

`REPOSITORY_REVIEW.md` and `SECURITY_BACKLOG.md` remain evidence documents.
At ship time, `/ship` removes roadmap items #1 and #2, marks their security
evidence resolved, and archives this plan; implementation must not rewrite the
historical review finding.

## Part 6 — Delivery order

1. Run `git -C priv/AbletonOSC checkout master`.
2. Implement Parts 1 and 2 plus the fork's `SESHAT.md` update.
3. Commit and push that fork change.
4. Implement the Elixir consumer, tests, and parent-repository docs.
5. Stage the new submodule SHA in the same parent commit as the Elixir
   contract change. Do not leave either side independently shippable: this is
   intentionally a breaking internal wire change.
6. Run the pure verification commands.
7. Run `mix abletonosc.install`, restart Live or toggle the control surface,
   then complete the Live smoke checklist.

## Testing

### Pure and automated

Run with Ableton closed:

1. `mix format --check-formatted`
2. `MIX_ENV=test mix compile --warnings-as-errors`
3. Focused tests:
   - `mix test test/seshat/osc/vendored_addresses_test.exs`
   - `mix test test/seshat/library/catalog_test.exs`
   - `mix test test/mix/tasks/abletonosc_install_test.exs`
4. Compile every Python source under `priv/AbletonOSC` without importing the
   package.
5. `mix precommit`

The sequencing constraint this plan was written under is **discharged**: test
isolation shipped 2026-07-30 (see
[archive/PLAN_test_isolation.md](archive/PLAN_test_isolation.md)), so
`MIX_ENV=test` points the transport at throwaway ports and the whole suite is
safe to run with Live open. No need to close Live for any step above.

### ⚠️ Live smoke test

After the fork commit is installed with `mix abletonosc.install` and Live has
been restarted or AbletonOSC toggled off and on:

1. Run `lsof -nP -iUDP:11000`. The only AbletonOSC bind must display
   `127.0.0.1:11000`; `*:11000` or `0.0.0.0:11000` is a failure.
2. Call `/live/test` through the running Seshat transport and receive `"ok"`.
   This callback uses the fixed default reply route rather than returning a
   tuple through `process_message`, so it directly verifies that removing
   retargeting did not break default sends.
3. Call `get_session_state(refresh: true)`, then change a mirrored value such
   as tempo or track volume by hand in Live and confirm a subsequent
   `get_session_state` sees it. This verifies both callback replies and
   asynchronous listener pushes still reach `127.0.0.1:11001`.
4. Before running `reindex_library`, place two matching regular fixtures in the
   export root: one with a modification time more than ten minutes old and one
   fresh. Reindex must complete, produce a valid catalog, remove the stale
   fixture, preserve the fresh fixture, and clean up its own newly created
   export. Remove the fresh fixture by hand after the assertion.
5. Send the obsolete form
   `/live/browser/export ["/tmp/seshat-should-not-exist.json"]` using a
   send-only OSC client. The requested file must not be created; Live's log
   should contain a clean validation message rather than a traceback.
6. Watch Live's `Log.txt` throughout. No traceback, bind error, unknown-address
   error on the valid calls, or leaked file descriptor is acceptable.

An external second-host probe is optional, not evidence the plan depends on:
the kernel bind shown by `lsof` is the authoritative check that no non-loopback
interface is listening.

## Out of scope

- Binding or source-validating Seshat's UDP 11001 listener, and making
  `Message.decode/1` total — roadmap #3.
- Serializing `Transport` queries and cleaning up timed-out callers — its own
  correctness roadmap item.
- HTTP authentication, public Phoenix binding, rate limiting, or multi-user
  identity — deployment-gated in `docs/SECURITY_BACKLOG.md`.
- An OSC authentication scheme. OSC stays local; remote access belongs behind
  authenticated HTTP.
- Support for TouchOSC or another networked OSC controller. A future need gets
  an explicit bind configuration and a fresh security design.
- Changing browser-export JSON contents, catalog merging/ranking, or catalog
  persistence.
- Repairing or adopting the fork's Python pytest suite.

## Open questions

No user design decision remains. Two runtime facts cannot be proven without
installing the changed fork into Live and are explicit implementation gates:

1. **⚠️ Does Live's embedded Python accept the loopback bind and preserve both
   default sends and listener pushes?** Source inspection says yes:
   `OSCServer` is an ordinary IPv4 UDP socket, direct callback replies keep
   their existing path, and every default-send consumer already targets
   `_remote_addr`. Assume yes; Live smoke items 1–3 must pass before shipping.
2. **⚠️ Do Live's embedded Python and the BEAM resolve
   `~/.seshat/browser-exports` to the same directory with mutually readable
   permissions?** Both run as the same logged-in user, and Python returns the
   resolved absolute path rather than asking Elixir to reproduce it. Assume
   yes; the Elixir root check and Live smoke item 4 fail clearly if that
   assumption is wrong. If it fails, replace the implicit home with one
   explicitly configured absolute export root shared by both runtimes—do not
   weaken path validation.
