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

3. **Archive the plan doc, if one exists.** If the feature had a detailed plan
   in [docs/](docs/) (outside `archive/`), move it to
   [docs/archive/](docs/archive/) and prepend the banner style the other
   archived docs use:

   > **Archived YYYY-MM-DD — shipped.** This is the plan as written *before*
   > implementation; the code as merged may differ. <One line on where the
   > feature lives now, and where any still-open follow-ups went.>

   Use today's real date.

4. **Sync [CLAUDE.md](CLAUDE.md).** New module → add it to the module map.
   Changed flow or conventions → fix the relevant section. No changes needed
   is a fine answer, but look.

5. **Check [.claude/docs/](.claude/docs/)** — if the feature changed how
   tools are added, how commands flow, or added OSC gotchas, update the
   matching doc.

6. **Verify** with `mix precommit` if anything outside `docs/` changed, then
   summarize: what was removed from the roadmap, what was archived, what
   follow-ups were added.
