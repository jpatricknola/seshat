---
name: ship
description: Close out a shipped feature — update ROADMAP.md, archive its plan doc, sync CLAUDE.md. Use after a feature lands, when the user says something "shipped" or "is done", or when ROADMAP.md still lists work that exists in the code.
argument-hint: [what shipped, e.g. "send levels"]
---

Close out a shipped feature: **$ARGUMENTS**

[docs/ROADMAP.md](docs/ROADMAP.md) is the single living list of what's *not
built yet*, and it only works if shipping updates it. Walk every step; several
are often no-ops, but check rather than assume.

1. **Confirm it actually shipped.** Find the implementing code (grep for the
   tool name or module) and confirm it is present on the branch you're closing
   out from; `git log` shows how it got there. Presence in the code is the
   test, *not* a merge to the default branch — closing out on the feature
   branch before its PR merges is normal. If the code isn't there, stop and
   say so — never remove roadmap items ahead of reality.

2. **Remove it from [docs/ROADMAP.md](docs/ROADMAP.md).** Delete the item or
   section. If only part shipped, rewrite the entry to just the remainder. If
   the work surfaced follow-ups worth doing later, add them where they fit —
   the roadmap gains items the same way it loses them.

   **Do not leave a "shipped" banner or recap paragraph in ROADMAP.md.** The
   roadmap documents future work only; ship history belongs in git, CLAUDE.md's
   Current focus, and the archived plan doc. Mention shipped work in an item
   only when an open item needs it as context.

   Renumber the remaining items and any *internal* cross-references. Do **not**
   go hunting for rank references in other files: nothing outside ROADMAP.md is
   allowed to cite an item by rank (the roadmap's own preamble states this), so
   an out-of-file rank reference is a bug in that file, not renumbering work you
   owe. If you notice one, rewrite it to name the item's title instead.

3. **Check the plan's `## Live verification` section before archiving.** The
   tests themselves live in [docs/smoke_tests/](docs/smoke_tests/) and stay there
   — nothing is promoted or retired, because a smoke test guards a *silent*
   failure mode that outlasts the feature shipping. What archives is the plan's
   record of what a run observed, which is why it matters that the record is
   there. So:

   - **Every citation must carry a result**, written by `/smoke-test`. A
     citation with nothing under it means the test never ran — say so in the
     summary, name it, and leave the section as it is. Archiving a plan whose
     checks are blank is fine; *implying they passed* is not.
   - **If any test still reads `*Last run: —*`** in `docs/smoke_tests/`, mention
     it. Shipping with unrun tests is a decision the user is allowed to make,
     but not one they should discover later.
   - A test whose behaviour this feature **removed** gets deleted from its file.
     That is the only reason to delete one.

4. **Archive the plan doc, if one exists.** If the feature had a detailed plan
   in [docs/](docs/) (outside `archive/`), move it to
   [docs/archive/](docs/archive/) and prepend the banner style the other
   archived docs use:

   > **Archived YYYY-MM-DD — shipped.** This is the plan as written *before*
   > implementation; the code as merged may differ. <One line on where the
   > feature lives now, and where any still-open follow-ups went.>

   Use today's real date.

   **Then fix the links the move just broke, in both directions.** The doc is
   now one directory deeper, so every relative link inside it is wrong: `](../`
   becomes `](../../`, and a bare `](something.md)` naming a sibling in
   `docs/` becomes `](../something.md)` — links to docs that were *already*
   archived are the only ones that still resolve. Then `grep` the repo for the
   plan's filename and repoint every inbound reference at
   `archive/<name>.md`. Neither half is optional: a dead link in an archived
   plan is how the reasoning behind a shipped decision stops being findable,
   which is the entire reason the plan is kept.

5. **Sync [CLAUDE.md](CLAUDE.md).** New module → add it to the module map.
   Changed flow or conventions → fix the relevant section. No changes needed
   is a fine answer, but look.

6. **Check [.claude/docs/](.claude/docs/)** — if the feature changed how
   tools are added, how commands flow, or added OSC gotchas, update the
   matching doc.

   If the feature touched `priv/AbletonOSC`, check two more: every new address
   is in [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md), and the
   divergence is listed in the fork's `SESHAT.md`. `vendored_addresses_test`
   enforces the first only for our own prefixes (`/live/browser/*`,
   `/live/return_track/*`, `/live/master/*`, the two song-structure
   addresses) — an address added under a prefix upstream owns, like
   `/live/clip/quantize`, is documented by hand or not at all.

7. **Verify** with `mix precommit` if anything outside `docs/` changed, then
   summarize: what was removed from the roadmap, what was archived, which live
   tests the plan cited and which of those actually ran, how many tests in
   `docs/smoke_tests/` still read `*Last run: —*`, and what follow-ups were
   added.
