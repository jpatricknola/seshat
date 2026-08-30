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
     [priv/AbletonOSC/API.md](priv/AbletonOSC/API.md) — exact
     address, exact argument list, reply shape. If the capability isn't
     there, **the plan gains a Python half** — `priv/AbletonOSC` is our fork,
     so a missing address is ours to add, whether that means a new handler
     (see [browser.py](priv/AbletonOSC/abletonosc/browser.py)) or an edit to
     upstream's own files. Verify the Live API call against the real source
     in `priv/AbletonOSC`, not against the installed copy in Remote Scripts,
     which is an output of `mix abletonosc.install` and may lag the fork.

     A Python half is normal feature scope, not a deterrent. **Never reject,
     defer, downgrade, narrow, or rank a feature lower because it needs a
     fork update; everything the installed LOM exposes is fair game.**

     **Before writing that the LOM lacks something, check it at tier 1 or 2**
     — the Live binary's registration table, then Live's own shipped Remote
     Scripts. `LomTypes.pyc` is the Max for Live registry and `dump_lom`
     records only classes, so neither can prove a member absent; module-level
     functions such as `Live.Conversions.audio_to_midi_clip` appear in
     neither. Commands and the tier table:
     [.claude/docs/ableton-lom.md](.claude/docs/ableton-lom.md). The
     plan must still describe the work accurately: it lands as a commit in
     the submodule plus a pin bump here, it puts a
     `mix abletonosc.install` + Live restart on the user, and **no test in
     this repo executes it** — so its verification lives entirely in the
     plan's Live verification section (step 3). Say which parts only Ableton
     can confirm rather than implying the suite covers them.

     **File the request as a GitHub issue on the fork, in this same pass, and
     cite it in the plan.** Follow
     [.claude/docs/filing-fork-work.md](.claude/docs/filing-fork-work.md)
     — it owns the format and what each request must state, and it covers
     bridge defects and wrong fork documentation as well as missing
     addresses. One issue per
     feature, not per address. Do not leave the request inside the plan doc
     only: the fork's implementer never reads it there, which is how a needed
     address gets quietly relabelled optional and shipped without. Say what
     the plan does if the request is declined.
   - Grep the codebase for every touchpoint: which `Handlers` clauses,
     whether it's single-message (Transport direct) or multi-step
     (`%Command{}` + Registry), whether `Session.State` needs a new field and
     listener, and whether the streamable HTTP MCP surface is affected.
   - Read any related archived plan or decision doc for constraints already
     discovered — don't rediscover what
     [docs/evaluating/bridge-options.md](docs/evaluating/bridge-options.md) already settled.
   - Anything you could not verify (needs live Ableton, needs Live's own API
     stubs) goes in the plan flagged with ⚠️, not silently assumed. The
     AbletonOSC source itself is *not* in that category any more — it's
     checked into `priv/AbletonOSC`, so read it.

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
   - **Testing** — what's covered pure (no Ableton). Nothing tests through
     `Transport.query/3`.
   - **Live verification** — the tests in [docs/smoke_tests/](docs/smoke_tests/)
     this change needs, each cited by file and title, plus what they leave
     uncovered. Run `/smoke-write` to derive them: it owns the rules for
     which properties of a change imply which tests, and writes any that don't
     exist yet into the right file. Deciding this now, before the code exists,
     is the point — it forces naming what `mix test` cannot reach while the
     reasoning is fresh, and it puts the verification in front of
     `/plan-review` instead of leaving it to whoever ships. `/smoke-test`
     writes its results back under each citation.
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
   ROADMAP.md entry (existing linked entries show the style).
   Do **not** remove or shrink the entry — that happens at `/ship` time.

5. **Address open questions — by experiment, not by reasoning, wherever
   Ableton can answer.** Take a pass at every open question the plan recorded
   and try to *close* it. A question that needs live Ableton is not a reason
   to leave it open: check whether Live is actually running
   (`ps aux | grep Ableton`), and if it is, measure the answer.

   **Assume the running Live session exists only for the issue being worked
   on.** Experimenting in it is fine and expected — load a device, create a
   return track, assign a selection, read a parameter's real range. Snapshot
   what you touch and undo it afterwards, but don't refuse to touch anything.
   The rig is written up under "Measuring the Live API without building the
   feature first" in
   [priv/AbletonOSC/API.md](priv/AbletonOSC/API.md):
   a temporary probe handler in the *installed* Remote Scripts copy,
   `/live/api/reload` plus a probe address over fire-and-forget UDP, answers
   read out of Live's `Log.txt`, then `mix abletonosc.install` to restore. No
   Live restart, no fork commit, minutes not hours. Fold every measurement
   back into the plan: the answer in the Open questions section, and the
   assumption it replaces corrected wherever the body relied on it.

   **The only question that may stay open is one no available resource can
   answer** — not one that merely needs a running DAW, a browser search, or a
   file you haven't read yet. If Live isn't running, or a question genuinely
   needs something you cannot reach, say exactly what is missing and make a
   confident recommendation the implementer can act on.

6. **Stop and summarize.** No implementation. Report: which item you planned,
   the two or three decisions most worth the user's attention, anything
   research contradicted in the roadmap entry, what you measured against live
   Ableton and what it changed, and the Open questions verbatim — the ones
   needing the user's call asked directly, and for any still open, what
   resource was missing (per step 5, "needs Ableton" is not an answer when
   Ableton is running). Implementation starts only when the user says go.

   End by recommending `/plan-review` — it re-derives this plan's OSC
   contract independently of you, judges whether the approach is the least
   invasive one that meets the objective, and on disagreement commissions a
   rival plan and adjudicates. Self-review is no substitute: the address
   check in particular is worthless performed by the agent that transcribed
   the addresses. `/lifecycle` runs it automatically as its own phase.
