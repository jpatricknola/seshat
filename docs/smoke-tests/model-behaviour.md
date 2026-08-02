# Model behaviour

The only tests in this repo that exercise **what the model says** rather than
what the code does. Nothing in `mix test` reaches any of it, so a rule can be
deleted, truncated away, or moved into a description that swallows it, and every
suite stays green.

**These cannot be run from inside a smoke-test session** — an agent following an
explicit list only proves it can follow the list. Run them in a fresh Claude
Desktop conversation, and report them as uncovered when you can't.

Report which rules held and which drifted, and name the channel each is in — a
rule that fails after moving into a tool description is evidence about the
division argued in `Seshat.Instructions`'s moduledoc, not just about wording.

## The instructions arrive, and arrive whole

*Run mode: user — requires a fresh local Claude Desktop conversation*
*Last run: —*

Check this first; it is silent when it fails. Instructions reach the model only
in a conversation set to run **on your computer** — a cloud session bridged to the
Mac gets the tools (namespaced `mcp__remote-devices__seshat__*`) and no
instructions at all. And the client truncates at **2,048 characters** mid-sentence
without saying so, dropping the *end* of the text. Confirm both in one question,
in a fresh conversation:

> Quote the seshat server instructions you were given, in full.

The tools should be `mcp__seshat__*`, and the quote should end with the last line
of `@text` in [lib/seshat/instructions.ex](../../lib/seshat/instructions.ex). If
it stops early, everything past the cut is being written for nobody.

## Out of reach

*Run mode: user — requires a fresh conversation that received server instructions*
*Last run: —*

(instructions) "Switch my audio output to the headphones." Says plainly it can't,
names where the setting lives in Live, offers no improvised workaround.

## Manual steps

*Run mode: user — requires a fresh conversation that received server instructions*
*Last run: —*

(instructions) A "why can't I see X?" question. The shortest complete path, keys
located physically ("press Tab, above the Caps Lock key"), each step confirmed by
what appears on screen. Not a lecture, and no assumed Live fluency.

## The view follows you

*Run mode: user — requires a fresh conversation and visual setup in Live*
*Last run: —*

(instructions) Both halves. **Post-action:** after a `write_midi_notes`, ask
"where is it?" — expect a description of what is *already* on screen, not
navigation directions. The follow cam moves Live's view but tells the model
nothing, so its own test passes whether or not this rule survives.
**Pre-action:** with Live showing Arrangement, ask to launch a named Session clip
— expect `show_view(Session)` before `fire_clip`, sent directly, with no
`get_view_state` pre-check.

## Reading before re-showing

*Run mode: user — requires a fresh conversation and manual view setup in Live*
*Last run: —*

(instructions) With the browser already open, ask "show me the browser." Expect
`get_view_state` first and *no* redundant `show_view`. This is the half of the
re-show policy the previous test deliberately excludes; both must hold at once.

## Speak music, not plumbing

*Run mode: user — requires an unprompted conversation to judge model language*
*Last run: —*

(instructions + `get_session_state`) Any multi-track exchange. Track names or
1-based numbers throughout; no tool names, raw indices, tags or catalog internals
in prose, **including in replies that have nothing to do with reading state** —
that is what would show the rule being read too narrowly since it moved.

## Directive acts, open offers

*Run mode: user — requires an unprompted conversation to judge model behaviour*
*Last run: —*

(`search_library`) "Load me a warm pad" loads the closest match, says why in a
phrase, names a runner-up. "What should we use for the pad?" offers a short slate
with a musical reason each. Two shapes from one tool.

## Diagnostics stay internal

*Run mode: user — requires an unprompted conversation to judge model language*
*Last run: —*

(`search_library` reply) A search with a vocabulary miss ("warm electric piano").
Musical choices reach the user; tags, tag counts and "no such tag" do not.

## One undo call per tool call that changed Live

*Run mode: user — requires a fresh conversation to test undo orchestration*
*Last run: 2026-08-01 — **failed**; the model read state between undos*

(`undo` + `get_session_state` descriptions) Ask for three named tracks in **one**
user message, then say "undo that request." Expect exactly three `undo` calls and
**one** ordinary `get_session_state` afterwards — no read between undos, no second
read after.

Seshat never sees the original prompt, only the individual tool calls, so this is
the only test that the `undo` and `get_session_state` descriptions teach the model
to repeat the call and verify once. If it undoes once and stops, the fix is those
descriptions.
