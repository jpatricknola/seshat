---
name: plan
description: Write an implementation plan for the highest-priority roadmap item (or a named one) — research the codebase and OSC surface first, then produce a docs/PLAN_*.md in the house style. Use when the user says "plan the next feature", "what's next", or names a roadmap item to plan.
argument-hint: [roadmap item, e.g. "send levels"; defaults to highest priority]
---

Write an implementation plan for: **$ARGUMENTS** (no argument → the topmost
`Priority` item in [docs/ROADMAP.md](docs/ROADMAP.md)).

You are planning, not implementing. The deliverable is a plan doc the user
reviews before any code is written. This plan is also the contract
`/pr-review` will later judge the implementation against, and `/ship` will
archive — so write items that are *checkable*: someone reading the diff should
be able to say yes/no to each one.

1. **Pick the item and read its roadmap entry closely.** The entry is the
   seed, not the plan — it often already names OSC addresses, tool names, and
   design hints (query-on-demand vs. promote to `Session.State`). Also check
   whether other roadmap entries are prerequisites or riders (e.g. "return
   track names — needed for send levels"); fold true prerequisites into the
   plan's scope and say so.

2. **Research before writing a single plan line.** This is where plans earn
   their keep — the best plan docs in [docs/archive/](docs/archive/) are
   valuable because of what research *changed* about the obvious approach.
   - Verify every OSC address in
     [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) — exact
     address, exact argument list, reply shape. If the capability isn't
     there, the plan gains a Python half: a handler in
     [priv/AbletonOSC/abletonosc/browser.py](priv/AbletonOSC/abletonosc/browser.py)-style vendored
     extension (see that file and `mix abletonosc.install`).
   - Grep the codebase for every touchpoint: which `Handlers` clauses,
     whether it's single-message (Transport direct) or multi-step
     (`%Command{}` + Registry), whether `Session.State` needs a new field
     and listener, whether the LiveView UI shows anything affected.
   - Read any related archived plan or decision doc for constraints already
     discovered — don't rediscover what
     [docs/bridge-options.md](docs/bridge-options.md) already settled.
   - Anything you could not verify (needs live Ableton, needs the installed
     AbletonOSC source) goes in the plan flagged with ⚠️, not silently
     assumed.

3. **Write the plan** to `docs/PLAN_<snake_case_name>.md`, matching the house
   style of the docs in [docs/archive/](docs/archive/):
   - **Context** — the user-visible gap, why now, and any key constraint
     research surfaced. A reader should understand the feature from this
     section alone.
   - **OSC contract** — every address with exact request and reply argument
     lists. This section is load-bearing: it's what makes the rest of the
     plan checkable.
   - **Numbered parts** in implementation order, each naming the exact files
     to touch and following the tool-adding shape where it applies
     (Definitions → Handlers → count bump — see
     [.claude/docs/adding-a-tool.md](.claude/docs/adding-a-tool.md)). Tool
     descriptions deserve a draft in the plan: they're prompt text for a
     model that can't see the code (index base, value range, resolver tool).
   - **Testing** — what's covered pure (no Ableton) and exactly what needs
     the `/smoke-test` checklist with Ableton open. Nothing tests through
     `Transport.query/3`.
   - **Out of scope** — what you're deliberately not doing and where it goes
     (usually: stays on the roadmap). A plan without this section grows
     during implementation.
   - **Open questions** — every question the plan leaves unanswered, in the
     doc itself, each stating what's unknown, why it couldn't be resolved
     now (needs the user's call, needs live Ableton, needs the installed
     AbletonOSC source), and what the plan assumes in the meantime. The ⚠️
     markers in the body should each have an entry here. Omit the section
     only if there are truly none — an empty section is a claim, so mean it.
   - Ordinary design choices don't belong in Open questions: make the call
     and record the reasoning in one or two sentences — a plan that defers
     decisions to "figure out during implementation" isn't a plan. A
     question is only *open* if it genuinely can't be answered at planning
     time.

4. **Link it from the roadmap.** Add a pointer to the plan doc in the item's
   ROADMAP.md entry (the "MCP mode in the browser UI" entry shows the style).
   Do **not** remove or shrink the entry — that happens at `/ship` time.

5. **Address open questions.** take a pass at the open questions recorded in
   the plan. Do your best effort to address them properly, or at least make
   a confident recommendation if you are unable to resolve it.

6. **Stop and summarize.** No implementation. Report: which item you planned,
   the two or three decisions most worth the user's attention, anything
   research contradicted in the roadmap entry, and the Open questions
   verbatim — the ones needing the user's call asked directly, the ones
   needing Ableton noted as blockers to check first during implementation.
   Implementation starts only when the user says go.

   End by recommending `/plan-review` — it re-derives this plan's OSC
   contract independently of you, judges whether the approach is the least
   invasive one that meets the objective, and on disagreement commissions a
   rival plan and adjudicates. Self-review is no substitute: the address
   check in particular is worthless performed by the agent that transcribed
   the addresses. `/lifecycle` runs it automatically as its own phase.


