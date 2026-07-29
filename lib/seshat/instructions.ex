defmodule Seshat.Instructions do
  @moduledoc """
  Session-level guidance, shared by both entry points.

  MCP mode sends this as the `instructions` field of the `initialize` result
  (`Seshat.MCP.Server.server_instructions/0`); API-key mode prepends it to
  `Seshat.Agent`'s system prompt. One source, so the two modes can't drift into
  separate personalities.

  ## What belongs here

  One test decides it, and it is worth applying to every sentence:

  > **If it matters when using a particular tool, it goes in that tool's
  > description. What belongs to no tool goes here.**

  "Refer to tracks by name, not index" matters whenever track state is read, so
  it lives on `get_session_state`. "Present a slate with a musical reason each"
  matters when choosing a sound, so it lives on `search_library`. "Don't relay
  search diagnostics" matters at the moment the diagnostics are produced, so it
  travels with the reply that produces them. None of those belong here, and all
  of them were here once.

  What is left over is guidance with no owner: the register to speak in, how to
  talk someone through a step no tool can take, what to do when a request is
  outside the tools entirely, and the fact that the view has already moved.

  Two further rules govern edits:

    * **Hard-capped at 2,048 characters.** Not editorial taste — the client
      truncates mid-sentence past that and says nothing (measured 2026-07-29),
      so an overlong rule is written and never delivered. Tool schemas have no
      such cap, which is the practical reason the test above matters: a rule
      that could live in a description is free there and scarce here.
    * **Nothing machine-specific.** Tag vocabulary, installed Packs, track
      names are all per-machine and already flow through tool replies — the
      same rule that keeps them out of tool descriptions.

  This file is edited as prose, and no test asserts on its wording — only that
  it exists, stays under the cap, and reaches both modes. Rewriting the text is
  a one-file change.
  """

  # Edited as prose, continually — this is the living prompt, dialed in from
  # real sessions. The voice is behavior only and stays persona-neutral:
  # aesthetic taste arrives later as a producer persona composed on top
  # (ROADMAP: producer personas), and the user's communicated taste always
  # outranks it. Decisions behind each rule:
  # docs/archive/PLAN_mcp_server_instructions.md.
  #
  # Hard ceiling: 2,048 characters. Measured 2026-07-29 — the Claude Desktop
  # client truncates server instructions mid-sentence at that point and says
  # nothing, so anything past it is written but never delivered. The rules at
  # the bottom are the ones that vanish first; keep this comfortably short.
  @text """
  You control the user's live Ableton Live set. User's goal is
  making music, not learning Ableton. Assume no Live UI fluency unless shown.

  Voice: their taste leads, yours serves it. Read the direction they give —
  genre, mood, references, reactions — and execute it as faithfully as the
  library allows. Say what you heard ("warm and slightly broken, so I went
  with the detuned one") and give a one-line musical reason for each pick, so
  it's easy to redirect; name a runner-up when the call is close. Offer the
  next move when it serves where they're heading, never where they didn't
  point.

  - Speak music, not plumbing — never tool names, raw indices, tags, or
    catalog internals.
  - The view follows you. What you create, write to, or delete is already
    selected, pane showing. Say what to look at ("the notes are in the editor
    at the bottom"), never how to navigate there.
  - Out of reach: say so plainly and name where in Live the setting lives.
    Don't improvise.
  - Manual steps, only when unavoidable: shortest complete path, every key
    located physically ("press Tab, above the Caps Lock key"), every step
    confirmed by what appears on screen. No concept explanations; keep
    alternatives for when a step didn't work.
  """

  @doc """
  The session-level guidance, or `nil` when there is none to send.
  """
  @spec text() :: String.t() | nil
  def text, do: @text
end
