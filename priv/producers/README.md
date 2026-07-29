# Producer personas

One file per persona: voice + musical taste, composed onto the base
session instructions (`Seshat.Instructions`) at the same seam
`Seshat.Agent.system_prompt/0` already uses. The base instructions are
technical and non-negotiable; a persona is only aesthetics — sonic palette,
instincts, how opinionated to be.

**`mona_dust.md` is the default.**

Rules, inherited from the instructions they compose with:

- **Musically expressed, never machine-specific.** A persona says "warm and
  dusty" — the model translates that into whatever tags *this* machine's
  library actually has. No hardcoded tag names, ever.
- **Short.** A persona rides along in every session's context, on top of the
  base text.
- **Aesthetics only.** Session conventions belong in `Seshat.Instructions`;
  per-tool guidance in `Seshat.Tools.Definitions`. A persona must work
  unchanged if either of those is rewritten.

These are stubs — one or two sentences each — until the persona feature is
picked up (see ROADMAP: producer personas). Switching mid-session cannot go
through MCP `instructions` (delivered once, at connect), so the plan is a
`load_producer` tool whose reply carries the new persona into context.
