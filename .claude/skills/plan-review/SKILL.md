---
name: plan-review
description: Challenge an implementation plan before any code is written — verify its OSC contract independently, judge whether the approach is adequate and proportionate, and on disagreement commission a rival plan and adjudicate between them. Use after /plan, or when a plan doc needs a second opinion before implementation starts.
argument-hint: [plan doc path; defaults to the single active docs/PLAN_*.md]
---

Challenge the plan at: **$ARGUMENTS** (no path → the single active
`docs/PLAN_*.md`; if several are active, the one the roadmap links from).

Invoked directly, this skill means **§ Review** — that is the whole of it.
§ Rival and § Judge are the escalation § Review can call for, and they only
work as their own agents with inputs `$ARGUMENTS` has no room for (§ Rival
needs the reviewer's brief; § Judge needs both plan paths). `/lifecycle` runs
them that way; § Review step 7 says what to do outside it.

The point of this skill is to catch, while a plan is still prose, what would
otherwise be caught after an implementation has faithfully built the wrong
thing. A wrong OSC address is the canonical case: UDP fails silently, so a
wrong address is never wrong *loudly*. This phase is not the only net under it
— [implement](.claude/skills/implement/SKILL.md) re-verifies each address as it
writes the call, and [pr-review](.claude/skills/pr-review/SKILL.md) checks
every one against the canonical docs. It is the *cheapest* net: catching it
here costs one agent, catching it at pr-review costs an implement cycle and a
fix round. And a plan wrong in its **shape** rather than its details has no
downstream net at all — pr-review judges the code against the plan, so an
implementation that faithfully builds the wrong thing passes every gate after
this one.

---

## § Review

You are challenging the plan, not rewriting it. Beyond the corrections in
step 5, change nothing in the doc.

1. **Read the roadmap entry first — before the plan.** Open the item's entry
   in [docs/ROADMAP.md](docs/ROADMAP.md) and form your own view of
   what the item needs. If you read the plan first you can only check whether
   it hangs together internally; the plan's own framing becomes the objective,
   and a plan that solves an adjacent problem immaculately will pass.

2. **Read what is already settled.** [docs/bridge-options.md](docs/bridge-options.md)
   and any related doc in [docs/archive/](docs/archive/). Staying on
   AbletonOSC is a decision, not an accident — a reviewer that relitigates a
   settled decision every run is worse than no reviewer.

3. **Now read the plan, and run these checks.**

   - **OSC contract, re-derived.** Every address in the plan's contract
     section, checked verbatim against
     [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md) —
     exact address, exact argument list, reply shape. Derive them yourself;
     do not trust the plan's transcription. Addresses that are ours rather
     than upstream's live in
     [priv/AbletonOSC/abletonosc/browser.py](priv/AbletonOSC/abletonosc/browser.py)-style
     vendored handlers. Downstream will re-check these — but only once code
     exists, which is exactly why you do it now.
   - **Adequacy.** Fully implemented, does this plan deliver the roadmap
     entry's user-visible outcome? The failure mode is a plan that is
     internally perfect and solves the wrong problem.
   - **Invasiveness.** Is there a smaller change with the same outcome? The
     recurring axes here: query-on-demand vs. promoting a field into
     `Session.State` (new field + listener + broadcast, touched by
     everything); extending an existing tool's params vs. adding a tool (tool
     surface growth is a standing cost); a clause in
     `Handlers` vs. a new module; a single Transport call vs. `%Command{}` +
     Registry; Elixir-side vs. a vendored Python handler — that last one puts
     a `mix abletonosc.install` re-run on the user and breaks on AbletonOSC
     upgrades.
   - **Risk, stated as blast radius.** What does this touch that everything
     else depends on — `Transport`, `Session.State`, the tool schema surface?
     Cross that with verifiability: nothing tests through `Transport.query/3`,
     so a change whose correctness can only be established with Ableton open
     is a change the test suite cannot defend. High blast radius *plus* low
     verifiability is what should stop a plan; either alone usually should
     not.
   - **Checkability.** Every numbered part must be yes/no decidable from a
     diff. "Wire it up appropriately" is where an implementer invents scope.
   - **Grounding.** Every file path named in the plan exists; every module and
     function it references exists; the conventions it cites are real (0-based
     track indices, string keys at handler clauses, pan -1.0..1.0, volume
     0.0..1.0).
   - **Structural completeness.** The plan carries every section
     [plan](.claude/skills/plan/SKILL.md) step 3 requires — Context, OSC
     contract, numbered parts, Testing, Out of scope, Open questions. Out of
     scope is the one that costs when it's missing: it's what keeps
     implementation from growing. And a Testing section promising coverage
     through `Transport.query/3` is promising a test nobody can write.
   - **The missing-part sweep.** New tool but no count bump in
     `definitions_test.exs`? New module but no CLAUDE.md module-map row? New
     `Session.State` field with no listener? Tool description not drafted as
     prompt text for a model that cannot see the code?
   - **Open-questions triage.** Are they genuinely open, or deferred
     decisions wearing a question mark? Anything tagged as needing the user's
     call is exactly what an unattended implementer will silently invent —
     either force a resolution or promote it to an assumption the implementer
     must record.

4. **Default to approve.** The failure mode of a plan reviewer is not missing
   things, it is finding things: plan churn that leaves each round longer and
   more hedged than the last. A finding needs a concrete downstream failure —
   *"if the implementer follows part 3 literally, X breaks"* — not a
   preference about the doc.

5. **Split what you found: correction or rival.** A **correction** is
   anything applicable without changing the plan's shape — a wrong address, a
   missing count bump, an unstated assumption. Apply corrections to the plan
   doc yourself *and* list them in your report, so the doc stays true for
   [pr-review](.claude/skills/pr-review/SKILL.md) and `/ship` while the
   implementer still sees them. Everything else — a different approach, a
   different decomposition — you cannot fix by editing, and you owe a rival
   plan.

6. **The bar for commissioning a rival.** All three, or it is a correction or
   a note:
   - Named concretely: files, addresses, approach. Not "consider something
     simpler."
   - Same objective, **smaller or safer** — never larger. An alternative that
     adds capability is out of bounds.
   - Clearly better, not arguable. Where reasonable people would split, the
     plan's author already made the call and it stands.

7. **Report.** Verdict first, on its own line:

   `PLAN_VERDICT: approve | approve_with_corrections | rival`

   Then: your independent reading of the objective; findings ranked by
   severity, each citing the plan section; corrections applied, listed
   verbatim; and — on `rival` — the brief: what is wrong with the approach and
   what direction the alternative should take. That brief is the rival
   author's entire starting point, so make it self-contained.

   Outside `/lifecycle`, `rival` is where you stop: give the user the brief and
   let them decide whether a competing plan is worth two more agents. Do not
   run § Rival yourself — its only value is that a different agent, which has
   not read the plan, writes it.

---

## § Rival

You are writing a competing plan. Your inputs are the roadmap entry and the
reviewer's findings. **Do not read the original plan while writing.**

1. Write your plan to `docs/PLAN_<same_snake_case_name>_alt.md` — **never** the
   canonical `docs/PLAN_<name>.md`, which still holds the plan you are
   competing with. Follow steps 1–3 of
   [plan](.claude/skills/plan/SKILL.md) against the brief for everything else:
   your own research, your own verified OSC contract, your own complete doc in
   full house style, every section that skill requires. (Its step 3 names the
   canonical filename — that instruction is for the original author, not for
   you.) A rival that arrives as a critique or a sketch loses to a finished
   plan regardless of merit, so clear the same bar the original cleared.

2. Do not touch the original doc and do not edit the ROADMAP link — the judge
   handles both.

3. Address the objection without overshooting it. You are not obliged to
   differ from the original anywhere the original is right, and you have no
   way of knowing where that is — which is the point. Where two independently
   derived plans agree, the judge learns the shared part is solid; where they
   diverge is the decision.

4. **Only when the plan is finished**, read the original once and append a
   short **"Differences from `PLAN_<name>.md`"** section: descriptive only,
   the divergences and what each turns on. Do not revise your own plan after
   reading it. That section is for the judge, not for the implementer — the
   judge removes it either way, so keep it separable from the plan proper.

5. Report the path you wrote and a two-paragraph case for your approach.

---

## § Judge

You are choosing between two plans and your decision is the only one in this
pipeline that nothing downstream reviews. Nobody checks you.

1. **Read the roadmap entry, then both plans, and form your own view** before
   reading anything argued.

2. **Re-derive the decisive facts yourself.** Every OSC address in *both*
   contracts against
   [docs/abletonosc-api-docs.md](docs/abletonosc-api-docs.md); every
   file path in both plans. A wrong address is invisible in prose, it is
   frequently what actually decides which plan is correct, and you cannot
   take either author's word for it. Where the two plans agree on a contract
   they derived independently, treat the agreement as evidence.

3. **Read the reviewer's findings last, as contested claims — not facts.**
   They are the only argued position you will see, and they were written by
   the agent that commissioned the challenger.

4. **Decide.** State it on its own line:

   `JUDGE_VERDICT: A | B | A_with_amendments | B_with_amendments | neither`

   where A is the original plan and B the rival. Amendments are bounded: a
   named part grafted from the loser, each citing its source plan and part
   number. If you want more than a few grafts you are rewriting rather than
   judging — that is `neither`.

5. **Promote the winner** (skip on `neither`):
   - The winner's content lands at the canonical `docs/PLAN_<name>.md`,
     amendments applied. If the rival won, its content replaces the
     original's at that filename — and drop its **"Differences from
     `PLAN_<name>.md`"** section as you move it: at the canonical path that
     section names a file that no longer exists, and what it says belongs in
     the rejected-approach section below.
   - Delete the `_alt.md` file. The ROADMAP link points at the canonical
     path and never has to change, and `/ship` only ever sees one doc.
     **Exactly one `docs/PLAN_*.md` must be left active when you finish** —
     everything downstream assumes it (`implement` stops and asks when there
     are several; `/ship` archives one and would strand the other).
   - Fold a short **"Approach considered and rejected"** section into the
     winner: what the losing plan proposed, and why you chose otherwise. The
     archived plans in [docs/archive/](docs/archive/) earn their keep
     by recording what research changed about the obvious approach — a
     rejected rival is the strongest instance of that this process produces,
     and deleting it unrecorded is the one real loss available here.

6. **Report**: the verdict line, `PLAN_PATH: docs/PLAN_<name>.md`, what
   decided it, every amendment applied, and any finding you rejected and why.
   On `neither`, explain what both plans miss and stop — that is a judgment
   about the roadmap item itself, which belongs to the user. Leave both docs
   in place in that case and name both paths in your report: nothing may
   proceed on either plan, so the two-active-docs state is the correct one and
   whoever picks this up needs to see both.
