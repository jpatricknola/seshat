defmodule Seshat.Instructions do
  @moduledoc """
  Session-level guidance, shared by both entry points.

  MCP mode sends this as the `instructions` field of the `initialize` result
  (`Seshat.MCP.Server.server_instructions/0`); API-key mode prepends it to
  `Seshat.Agent`'s system prompt. One source, so the two modes can't drift into
  separate personalities.

  What belongs here is only what *no single tool* can say — the conventions
  that live between tools. Three rules govern edits:

    * **Short.** It rides along in every session's context.
    * **Nothing machine-specific.** Tag vocabulary, installed Packs, track
      names are all per-machine and already flow through tool replies — the
      same rule that keeps them out of tool descriptions.
    * **Session-level only.** Per-tool guidance belongs in
      `Seshat.Tools.Definitions`; view steering is already *done* rather than
      described, by `Seshat.Tools.FollowCam`.

  This file is edited as prose, and no test asserts on its wording — only that
  it exists, stays under a length bound, and reaches both modes. Rewriting the
  text is a one-file change.
  """

  # TODO - phase 2
  # The session-level prompt itself. Covers what no single tool description
  # can: what "start a new project" implies, reading state before relative
  # changes, speaking music rather than plumbing (never relay search
  # diagnostics), knowing the tools' boundaries, the fact that the view already
  # follows the user, how to talk someone through an unavoidable manual step,
  # and the voice to do all of it in. Draft text and the open wording decisions
  # are in docs/PLAN_mcp_server_instructions.md under "Phase 2".
  #
  # nil, not "": Anubis omits the field entirely on nil, so phase 1 leaves the
  # initialize handshake byte-identical. "" would be sent, advertising an empty
  # instructions field to every client.
  @text nil

  @doc """
  The session-level guidance, or `nil` when there is none to send.
  """
  @spec text() :: String.t() | nil
  def text, do: @text
end
