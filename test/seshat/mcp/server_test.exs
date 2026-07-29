defmodule Seshat.MCP.ServerTest do
  @moduledoc """
  Guards the invariant that MCP mode sends exactly the shared instructions.

  Same spirit as `Seshat.MCP.ToolsTest`'s parity guard: the server must not
  grow its own copy of session-level guidance. Deliberately says nothing about
  what the text *is* — that is prose, edited in `Seshat.Instructions` alone.
  """

  use ExUnit.Case, async: true

  describe "server_instructions/0" do
    test "sends the shared instructions verbatim" do
      assert Seshat.MCP.Server.server_instructions() == Seshat.Instructions.text()
    end

    test "is a public zero-arity function, which is what Anubis calls" do
      Code.ensure_loaded!(Seshat.MCP.Server)
      assert function_exported?(Seshat.MCP.Server, :server_instructions, 0)
    end
  end
end
