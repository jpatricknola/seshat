defmodule Seshat.InstructionsTest do
  @moduledoc """
  Contract tests for the shared session-level guidance.

  Deliberately text-agnostic: nothing here asserts on wording, so the prose can
  be rewritten without touching a test. What is guarded is the contract both
  entry points rely on, plus the one property that is easy to lose by
  accident — brevity.
  """

  use ExUnit.Case, async: true

  alias Seshat.Instructions

  # Instructions ride along in every session's context. The bound is loose on
  # purpose: it catches a runaway, not a rewrite.
  @max_length 3_000

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
