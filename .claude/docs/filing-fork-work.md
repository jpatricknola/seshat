# Filing fork work

**Anything that is bridge work only belongs as an issue on
[the fork](https://github.com/jpatricknola/AbletonOSC), not in a Seshat
document.** File it there and cite it from wherever Seshat needed it. Do not
write the Python from Seshat, do not commit in `priv/AbletonOSC`, and never
narrow a feature to avoid the request.

Bridge-only work is anything whose fix lands entirely in the fork:

- **A missing address** for a LOM member Seshat needs.
- **A bridge defect** — an address that lies, drops, mis-shapes a reply, or
  raises where it should answer.
- **Wrong or missing fork documentation** — an `API.md` row that misstates a
  value range or reply shape, a `FORK_GAPS.md` disposition contradicted by
  measurement.
- **A measured wire fact** the fork's docs should own and don't.

If the fix is partly ours, split it: the fork half is an issue, the Seshat half
is a plan or a roadmap item, and each cites the other.

The rule this serves is already in [CLAUDE.md](../../CLAUDE.md): the installed
LOM is Seshat's capability boundary, not the fork's current address list, and
the fork owns every fact about the wire. A missing address is ordinary feature
scope. What was missing was a *channel* — requests used to live only inside a
plan doc, where the fork's implementer never saw them, and got silently
downgraded to "optional" on the way.

## When to file

At **plan time**, as soon as research finds the gap — not at implementation
time. `/plan` step 2 is where the address list gets verified against
[API.md](../../priv/AbletonOSC/API.md); anything absent becomes an issue in the
same pass, so the fork work can start while the Elixir half is still being
written.

For defects and documentation errors, file the moment you are sure — including
mid-implementation and mid-review. A bridge bug does **not** go in
`docs/ROADMAP.md`; that queue is Seshat's work, and an item there only the fork
can fix will sit unread by the one person who can act on it.

File one issue per feature, not per address — related members share a review and
a merge on the fork's side, and a single deploy on ours. (Keep that second
reason out of the issue itself; see the split below.)

Check [FORK_GAPS.md](../../priv/AbletonOSC/FORK_GAPS.md) first. If the member is
already listed there with a disposition, say so in the issue and link it; the
gap file is the fork's own record and the issue is the request against it.

## What the issue must contain

For a **defect or a documentation error**: what the address does, what it should
do, and how you know — the measurement, its date, and the Live version it was
taken against. Everything under "the split" below applies unchanged.

For a **requested address**, per address:

- **The address and its exact argument list.**
- **The reply shape**, including the failure channel. Say whether it always
  replies, and what an error looks like. A getter that stays silent on failure
  is unusable to a caller that has to time out to learn anything.
- **Why the consumer needs it** — the concrete failure the address prevents,
  not the feature it belongs to. "The tool blames the clip when the real cause
  was focus" is a reason; "needed for convert" is not.
- **What it does not do.** Any limitation you already know, stated so it lands
  in `API.md` rather than being discovered later. Overselling an address is
  worse than not having it.
- **Listener or not**, and why. The fork's convention is that observable
  properties get a `start_listen`/`stop_listen` pair; say if the member is
  observable, and flag anything about the subject that makes the shared helper
  awkward.
- **Acceptance** — one or two observable outcomes that decide whether it works.
- **Honest expectation.** If you think a requested address is probably
  redundant, or is insurance rather than a fix, say so. The implementer's
  judgement improves with it, and a request that oversells one member spends
  credibility the next one needs.

Per issue:

- **Documentation obligations** — the `API.md` rows, which `FORK_GAPS.md` entry
  the commit closes, and any prose that names the member elsewhere.
- **Whether it is a runtime handler or documentation only**, because that tells
  the fork's implementer whether verifying their own change needs the script
  reloaded into a running Live.

## The split: the issue is bridge work, the plan is Seshat work

**The issue describes what the bridge should do, and nothing else.** The fork
has its own consumers and its own repository; it does not know Seshat exists and
should not have to. Everything about *our* side stays in the plan doc, which is
where the person paying those costs is reading.

In the issue: the address, its arguments, its reply and failure shapes, the
`API.md` and `FORK_GAPS.md` obligations, whether it is a runtime handler,
acceptance, and a rationale written in terms of **a client** — what a caller
cannot currently determine, and what goes wrong without it.

Not in the issue: our pin bump, `mix abletonosc.install`, our Live restart, our
tool names, our roadmap item, our plan's sequencing, "the model", or the feature
title the request came from. Cost-of-adoption arguments belong nowhere near it —
"worth doing now because it rides a restart we're already paying for" is our
scheduling, not the fork's problem.

Write the rationale so it reads as a bridge limitation, not a Seshat
inconvenience. *"`focus_view` is a silent setter, so a client that sets focus has
no way to learn whether it landed"* is a bridge limitation. *"Our convert tool
blames the clip and sends the model down a wrong path"* is the same fact in a
vocabulary the fork cannot act on.

Describe the contract, not the implementation. Handler code is the fork's to
write; a Python sketch in the issue is fine if it clarifies a shape, but the
requirements are what is being agreed.

[#28](https://github.com/jpatricknola/AbletonOSC/issues/28) is the worked
example, filed 2026-08-30 for `focused_document_view` and
`highlighted_clip_slot`.

## After filing: cite it, never restate it

**The issue holds every detail of the bridge change. Seshat documents link to
it and say what Seshat does.** A handler, an argument list or a reply shape
written down in both places is a description that goes stale in one of them,
and the stale copy is always the one someone reads.

- **Cite the issue where it is needed**, by number and title — in the plan doc
  at the part that depends on it, and in the `docs/ROADMAP.md` entry if the
  item cannot be built without it. `/pr-review` reads the plan; an uncited
  dependency reads as scope that appeared from nowhere.
- **State the consequence for Seshat, not the content of the change.** "Sent
  blind until #28 lands; the tool refuses safely but names the wrong cause" is
  Seshat's business. Re-describing the getter's reply shape is the fork's.
- **Say whether the work is blocked or degraded without it.** A plan or roadmap
  entry that only works if the fork says yes is one with an unstated dependency.
  Blocked means the part is void until the issue lands — say so plainly.
  Degraded means it ships with a named rough edge — say what the edge is, so
  nobody parks buildable work waiting on something it does not need.
- When the fork merges it, **bump Seshat's gitlink to the merged
  `origin/master` commit**, run `mix abletonosc.install`, restart Live, and
  verify the address against the running bridge before writing the Elixir that
  depends on it. A merged handler is not a working one.
