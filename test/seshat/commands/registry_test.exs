defmodule Seshat.Commands.RegistryTest do
  @moduledoc """
  The pure half of Registry's sequences.

  `execute/1` itself needs a live Ableton (`.claude/rules/testing.md`: nothing
  tests through `Transport.query/3`), so what is covered here is the decision it
  makes from the values Ableton hands back.
  """

  use ExUnit.Case, async: true

  alias Seshat.Commands.Registry

  describe "ensure_created/2" do
    test "a count that went up means the return track was created" do
      assert Registry.ensure_created(0, 1) == :ok
      assert Registry.ensure_created(2, 3) == :ok
    end

    # Live caps a set at 12 returns and the LOM gives no error when it refuses,
    # so the count is the only signal — and at the cap the user needs to hear
    # "delete one first", not "try again".
    test "an unchanged count at Live's 12-return cap names the cap" do
      assert {:error, message} = Registry.ensure_created(12, 12)

      assert message =~ "limit of 12"
      assert message =~ "delete_return_track"
      assert message =~ "Nothing was created or renamed"
    end

    # Below the cap the same non-create means something else went wrong, and
    # blaming the cap would send the user to delete a return they still need.
    test "an unchanged count below the cap blames the message, not the cap" do
      assert {:error, message} = Registry.ensure_created(3, 3)

      assert message =~ "went from 3 to 3"
      assert message =~ "may not have landed"
      refute message =~ "limit of 12 return tracks"
    end

    # A return deleted in Live's UI mid-sequence, or a stale count reply. The
    # message should report what was actually seen rather than assert the count
    # is "still" the old one.
    test "a count that went down reports both numbers honestly" do
      assert {:error, message} = Registry.ensure_created(3, 2)

      assert message =~ "went from 3 to 2"
    end
  end
end
