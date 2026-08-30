# Judged in conversation

What the model *says and chooses*, not what the tools return. Every test here
needs a fresh conversation with Seshat connected, and the thing being checked is
the reply — its wording, what it offered, what it declined to do, which tool it
reached for first.

Nothing in `mix test` reaches any of it, which is what makes this file matter: a
rule can be deleted, truncated away, or moved into a tool description that
swallows it, and every suite stays green.

None of this is reachable by an agent sweep either, and the reason is worth
stating once: an agent running these would be grading its own output. An agent
following an explicit list only proves it can follow the list. The judgement has
to come from outside the conversation being judged.

**Run them unprompted.** The failure mode is a leading question — asking "did
you show the Session view first?" produces a yes regardless. Ask for the musical
outcome and watch what happens.

**Set-up shared by most of these:** a fresh conversation *on the machine running
Seshat*, so `Seshat.Instructions` actually arrives. A cloud session bridged to
the Mac gets the tools and none of the guidance, which is a different thing to
test and a different result — see [README.md](../../../README.md).

**Name the channel, not just the verdict.** Report which rules held and which
drifted, and where each rule lives — a rule that fails *after* being moved from
`Seshat.Instructions` into a tool description is evidence about the division
argued in that module's moduledoc, not just about wording.

## Claude Desktop lists the tools at all

*Why manual: requires a fresh Claude Desktop conversation*
*Last run: —*

In a fresh conversation. It is the client nothing else here exercises and the one
with a history of failing quietly; a schema it dislikes shows up as an empty tool
list, not an error message.

## The instructions arrive, and arrive whole

*Why manual: requires a fresh local Claude Desktop conversation*
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

## Speak music, not plumbing

*Why manual: requires an unprompted conversation to judge model language*
*Last run: —*

(instructions + `get_session_state`) Any multi-track exchange. Track names or
1-based numbers throughout; no tool names, raw indices, tags or catalog internals
in prose, **including in replies that have nothing to do with reading state** —
that is what would show the rule being read too narrowly since it moved.

## Directive acts, open offers

*Why manual: requires an unprompted conversation to judge model behaviour*
*Last run: —*

(`search_library`) "Load me a warm pad" loads the closest match, says why in a
phrase, names a runner-up. "What should we use for the pad?" offers a short slate
with a musical reason each. Two shapes from one tool.

## Diagnostics stay internal

*Why manual: requires an unprompted conversation to judge model language*
*Last run: —*

(`search_library` reply) A search with a vocabulary miss ("warm electric piano").
Musical choices reach the user; tags, tag counts and "no such tag" do not.

## Out of reach

*Why manual: requires a fresh conversation that received server instructions*
*Last run: —*

(instructions) "Switch my audio input device to my interface." Says plainly it
can't, names where the setting lives in Live, and offers no improvised AX,
shell, or keyboard workaround. Audio *output* is now a narrow supported target;
that does not make adjacent Settings controls reachable by assumption.

## Manual steps

*Why manual: requires a fresh conversation that received server instructions*
*Last run: —*

(instructions) A "why can't I see X?" question. The shortest complete path, keys
located physically ("press Tab, above the Caps Lock key"), each step confirmed by
what appears on screen. Not a lecture, and no assumed Live fluency.

## The view follows you

*Why manual: requires a fresh conversation and visual setup in Live*
*Last run: —*

(instructions) Both halves. **Post-action:** after a `write_midi_notes`, ask
"where is it?" — expect a description of what is *already* on screen, not
navigation directions. The follow cam moves Live's view but tells the model
nothing, so its own test passes whether or not this rule survives.
**Pre-action:** with Live showing Arrangement, ask to launch a named Session clip
— expect `show_view(Session)` before `fire_clip`, sent directly, with no
`get_view_state` pre-check.

## Reading before re-showing

*Why manual: requires a fresh conversation and manual view setup in Live*
*Last run: —*

(instructions) With the browser already open, ask "show me the browser." Expect
`get_view_state` first and *no* redundant `show_view`. This is the half of the
re-show policy the previous test deliberately excludes; both must hold at once.

## One undo call per tool call that changed Live

*Why manual: requires a fresh conversation to test undo orchestration*
*Last run: 2026-08-01 — **failed**; the model read state between undos*

(`undo` + `get_session_state` descriptions) Ask for three named tracks in **one**
user message, then say "undo that request." Expect exactly three `undo` calls and
**one** ordinary `get_session_state` afterwards — no read between undos, no second
read after.

Seshat never sees the original prompt, only the individual tool calls, so this is
the only test that the `undo` and `get_session_state` descriptions teach the model
to repeat the call and verify once. If it undoes once and stops, the fix is those
descriptions.

## Headphones resolve and switch within the user-visible budget

*Why manual: requires a fresh local conversation, safe routed hardware, and a stopwatch*
*Last run: —*

(`get_audio_outputs` + `set_audio_output` descriptions) With Live using a
non-headphone output, Settings closed, another application frontmost, and AX
permission already granted, start a fresh local MCP conversation. Submit one
user message and start the stopwatch:

> Switch my audio output to the headphones.

The model calls `get_audio_outputs`, resolves “headphones” to one exact returned
device name, then calls `set_audio_output` in the same user request. The output
must audibly move and Live's Audio Output Device value must show that device
within 10 seconds. Settings is closed and the prior application is frontmost at
the end; there is no separate cleanup tool call, shell/computer-control
improvisation, or claim that the setting is out of reach.

Run the complete request three times, resetting Live to the non-headphone output
before each run. Any run over 10 seconds fails the feature even if the helper's
own timing is smaller. Calling the setter with a guessed name instead of reading
the machine's choices means the resolver guidance is insufficient; leaving
Settings or focus changed means the supposedly atomic helper transaction leaked
UI state.

## A plain ask in words reaches a good candidate

*Why manual: requires an unprompted conversation to judge model behaviour*
*Last run: —*

"Find me a warm guitar". `Warm` is not a real tag in a stock library, which is
the point. If the model sends `Warm` as its only tag the search correctly returns
nothing (tags filter at ≥1); what must happen next is that the reply names the
failed tag and the real tags on what the query alone matched, and the model
retries with one of those and lands on the acoustic/soft guitars. One wasted call
is the designed cost; **a dead end is the failure**, even though nothing errored.

## The slate spans devices, and its facets narrow

*Why manual: includes judging how the model presents choices in conversation*
*Last run: —*

Not 15 neighbours from one folder. A truncated reply lists real tags with counts
you can narrow by — try one and confirm it narrows. Confirm the model presents
3–5 candidates with reasons rather than loading the first hit unasked.

## The audition loop works as a conversation

*Why manual: requires musical judgment by ear in a natural conversation*
*Last run: —*

`search_library` for electric pianos → load one on a MIDI track with a clip →
fire → "next" (delete + load) → "keep that one" — the set ends holding only the
winner. Then an effect A/B via `bypass_device`.

## Mixer and note edits route to one call each

*Why manual: judges whether the replies speak music — the routing half is automated by `mix routing.eval`*
*Last run: —*

The 2026-08-27 consolidation bet that one `set_mixer` and one `edit_notes`
route better than the thirteen and three names they replaced. **Which tool the
model reaches for is no longer judged here**: `mix routing.eval` runs the same
two prompts through a fresh headless client against a record-only server and
scores the calls deterministically — see
[CLAUDE.md](../../../CLAUDE.md) § Verification for how to run it, and the
archived [PLAN_routing_evals.md](../../archive/PLAN_routing_evals.md) for the
decision run's detail. Run that for the routing verdict.

What remains for a person is the residue no trace can score. In a fresh
conversation with a set of a few named tracks and a return: "bring the master
down a touch and mute the reverb return," then, naming the track and clip,
"in the Bass track's first clip, make the third note a little quieter."

Expect both replies to speak music — the master "came down a touch", the
reverb "is muted", the third note "a little softer" — with no tool names, no
`target: master`, no raw indices or velocities the user never asked for. A
reply that narrates the calls means the "speak music" rule in
`Seshat.Instructions` isn't carrying through a consolidated multi-property
call; that is a finding about the instructions, not the tools.

## Show-first sequencing

*Why manual: requires a fresh conversational request and manual starting view*
*Last run: —*

Start in Arrangement, ask naturally to launch a named Session clip. Expect
`show_view(Session)` before `fire_clip` — the grid appears, then the launch happens
on screen — and expect it sent *directly*, with no `get_view_state` pre-check: six
serialized reads to avoid one harmless idempotent send would only delay the
action.

Then the Arrangement case: start in Session, ask to set the song loop brace.
Expect `show_view(Arranger)` before `set_loop`.

## No redundant pre-show

*Why manual: requires a fresh conversational request and manual starting view*
*Last run: —*

Start in Session, ask to change a clip's loop brace or notes. Expect no
`show_view(Detail/Clip)` beforehand — the existing follow cam already leaves the
edited clip on screen right after the write.

## The selected-track pane

*Why manual: requires manual selection and an unprompted conversation*
*Last run: —*

With a *different* track selected, ask to change a device parameter on a named
track. Expect `select_track` then `show_view(Detail/DeviceChain)` before the
mutation — `set_device_parameter` is the one mutation with no follow cam behind
it, so a skipped pre-show here shows the wrong track's chain.

## Pure navigation and hiding in words

*Why manual: requires an unprompted conversation to judge model behaviour*
*Last run: —*

Ask only "show me the timeline" and "show me the notes again." Expect `show_view`
alone — no invented follow-up mutation, no keyboard instructions.

Then ask "hide the browser, I need the room" and, in a separate turn, "close the
detail panel." Expect `hide_view(Browser)` and `hide_view(Detail)` respectively —
not a keystroke instruction, and not `show_view` of something else. Then "what am
I looking at?" should call `get_view_state` and answer in the user's vocabulary
("Session view, browser closed"), never tool names or raw flags.

## Groove with nothing assigned says so

*Why manual: requires confirming the set has no assigned grooves and judging model wording*
*Last run: —*

`set_groove_amount` with **no** grooves assigned anywhere in the set — nothing
changes audibly, and the model's reply (fed by the tool description) says so
rather than promising swing.

## A generation request routes to one call and names the form

*Why manual: requires a fresh unprompted client conversation and judging the model's tool choice and language*
*Last run: —*

Since `generate_midi` shipped, **MIDI is the default form** (the user-stories
contract): a material request that names no form must land as composed MIDI,
and only an explicit audio ask selects `generate_audio`. This check judges
that boundary as well as the one-call shape.

In a fresh local Claude Desktop conversation with Seshat connected, ask:

> Make me a four-bar dusty lo-fi beat — kick, snare and hats.

Expect exactly one `generate_midi` call carrying all three drum parts — not
one call per part, not a `create_track`/`write_midi_notes` chain, and not
`generate_audio`. The reply speaks in musical terms, says the result is MIDI,
names the tracks and the Session slot, and mentions that one undo removes the
whole beat. Instruments are either loaded (picked from the library with a
one-line reason) or the reply says plainly the tracks are silent and offers to
pick sounds — never silent tracks presented as finished.

Then ask:

> Another take, a little lazier.

Expect one `generate_midi` call targeting the next empty scene on the same
tracks — the accepted take is never overwritten, and the reply never claims
the first take was replaced.

Then ask, explicitly audio:

> Now give me a four-bar dusty breakbeat loop as audio, on a new track.

Expect exactly one `generate_audio` call. The reply says the result is audio,
names the track and slot, and does not claim the raw render is grid-aligned or
seamlessly loopable. A "darker" follow-up take uses `variation_of` (or a fresh
description only if the model explicitly explains why variation is not
available), lands in the next empty slot, and never claims the first take was
replaced.

## A sung take routes to setup, record, then convert

*Why manual:* a fresh conversation in a real client, judged on which tools the
model reaches for unprompted.

*Last run: —*

In a new conversation with an audio track already in the set: *"I want to sing
the guitar solo — record me for four bars and then turn it into MIDI so I can
put a guitar sound on it."*

What should happen: the input is set up and the track armed **before** the
recording starts, and Seshat says when to start singing rather than recording
into silence while you wait. After the take, one `convert_audio_to_midi` call
with `mode: "melody"` — not `harmony`, not `drums`. Then a guitar patch chosen
from the library and loaded onto the new track, with a one-line reason for the
pick.

What should *not* happen: an offer to write the part with `write_midi_notes`
instead; a second recording attempt when the first take was fine; the word
"convert" presented as a menu item you have to find; any raw index or tool name
spoken aloud.

The routing question this settles is whether `mode` is chosen from what the
user said they were doing. "Sing the solo" is monophonic and therefore
`melody`; a `harmony` here means the enum's description is not carrying its
weight, since the wrong mode produces a plausible-looking result that is wrong
in a way the user has to listen for.

Also confirm that Live is never brought to the front and no menu opens: the
conversion runs over OSC now, and a reply that warns about either is describing
a mechanism that no longer exists. The call may sit for a few seconds while
Live analyses — that wait is the tool waiting for the new track to appear, and
the reply must name the track it found rather than telling you to go look.
