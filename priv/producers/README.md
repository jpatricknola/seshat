# Producer personas

One file per persona: **musical taste only**, composed onto the base
session instructions (`Seshat.Instructions`). A persona is a sonic palette,
genre instincts, and production tendencies — which presets to reach for, how
much reverb, how hot the drums sit. What "good" sounds like, expressed as
the *decisions* a producer would make. All *behavior* — how to run a slate,
how opinionated to be, register, production-move habits — lives in the base
and is identical across personas: "add some reverb to the keys" plays out
the same way under every producer, and only the amount and character
differ. Tone may flavor slightly; structure never does.

**`mona_dust.md` is the default.**

Rules, inherited from the instructions they compose with:

- **Musically expressed, never machine-specific.** A persona says "warm and
  dusty" — the model translates that into whatever tags *this* machine's
  library actually has. No hardcoded tag names, ever.
- **Short.** A persona rides along in every session's context, on top of the
  base text.
- **Taste only, never behavior.** Session conventions, voice, and register
  belong in `Seshat.Instructions`; per-tool guidance in
  `Seshat.Tools.Definitions`. A persona must work unchanged if either of
  those is rewritten — and swapping personas must change *what* Seshat
  reaches for, never *how* it works.

These are stubs — one or two sentences each — until the persona feature is
picked up (see ROADMAP: producer personas). Switching mid-session cannot go
through MCP `instructions` (delivered once, at connect), so the plan is a
`load_producer` tool whose reply carries the new persona into context.
