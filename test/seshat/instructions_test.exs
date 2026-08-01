defmodule Seshat.InstructionsTest do
  @moduledoc """
  Contract tests for MCP session-level guidance.

  Deliberately text-agnostic: nothing here asserts on wording, so the prose can
  be rewritten without touching a test. What is guarded is the MCP initialize
  contract, plus the one property that is easy to lose by accident — brevity.
  """

  use ExUnit.Case, async: true

  alias Seshat.Instructions

  # Not editorial taste — a delivery limit. Measured against Claude Desktop on
  # 2026-07-29: server instructions are truncated mid-sentence at 2,048
  # characters, silently, so every character past this is written but never
  # reaches the model. The rules at the end of the text are the ones lost first.
  @max_length 2_048

  describe "text/0" do
    test "returns a string or nil" do
      assert is_nil(Instructions.text()) or is_binary(Instructions.text())
    end

    test "stays short enough to ride along in every session" do
      assert String.length(Instructions.text() || "") < @max_length
    end

    test "is never an empty string — nil is how 'nothing to send' is expressed" do
      refute Instructions.text() == ""
    end

    test "carries no leftover work markers" do
      refute (Instructions.text() || "") =~ "TODO"
    end
  end
end
