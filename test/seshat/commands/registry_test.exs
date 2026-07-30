defmodule Seshat.Commands.RegistryTest do
  @moduledoc """
  The pure half of Registry's sequences.

  `execute/1` itself needs a live Ableton (`.claude/rules/testing.md`: nothing
  tests through `Transport.query/3`), so what is covered here is the decision it
  makes from the values Ableton hands back.
  """

  use ExUnit.Case, async: true

  alias Seshat.Commands.Registry

  describe "ensure_return_created/2" do
    test "a count that rose by exactly one means the return track was created" do
      assert Registry.ensure_return_created(0, 1) == :ok
      assert Registry.ensure_return_created(2, 3) == :ok
    end

    # A return added by hand in Live while the tool ran, or a stale count reply.
    # `before_count` is the index we are about to rename, so a jump of two means
    # we no longer know which return is ours — and renaming anyway would rename
    # the user's.
    test "a count that jumped by more than one refuses to guess which return is ours" do
      assert {:error, message} = Registry.ensure_return_created(3, 5)

      assert message =~ "went from 3 to 5"
      assert message =~ "more than one"
      assert message =~ "Nothing was renamed"
      refute message =~ "limit of 12"
    end

    # Live caps a set at 12 returns and the LOM gives no error when it refuses,
    # so the count is the only signal — and at the cap the user needs to hear
    # "delete one first", not "try again".
    test "an unchanged count at Live's 12-return cap names the cap" do
      assert {:error, message} = Registry.ensure_return_created(12, 12)

      assert message =~ "limit of 12"
      assert message =~ "delete_return_track"
      assert message =~ "Nothing was created or renamed"
    end

    # Below the cap the same non-create means something else went wrong, and
    # blaming the cap would send the user to delete a return they still need.
    test "an unchanged count below the cap blames the message, not the cap" do
      assert {:error, message} = Registry.ensure_return_created(3, 3)

      assert message =~ "went from 3 to 3"
      assert message =~ "may not have landed"
      refute message =~ "limit of 12 return tracks"
    end

    # A return deleted in Live's UI mid-sequence, or a stale count reply. The
    # message should report what was actually seen rather than assert the count
    # is "still" the old one.
    test "a count that went down reports both numbers honestly" do
      assert {:error, message} = Registry.ensure_return_created(3, 2)

      assert message =~ "went from 3 to 2"
    end
  end

  describe "ensure_track_created/2" do
    test "a count that rose by exactly one means the track was created" do
      assert Registry.ensure_track_created(0, 1) == :ok
      assert Registry.ensure_track_created(7, 8) == :ok
    end

    # The concurrent-mutation case: the user pressing Command-T in Live while the
    # tool runs is ordinary here. A `>` comparison would have returned :ok and
    # renamed index 3, which may be the track they just made.
    test "a count that jumped by more than one refuses to guess which track is ours" do
      assert {:error, message} = Registry.ensure_track_created(3, 5)

      assert message =~ "went from 3 to 5"
      assert message =~ "more than one track"
      assert message =~ "Nothing was renamed"
    end

    # Nothing on the wire reveals the Live edition, so the message names the
    # edition cap as one possible cause without asserting it — and the return
    # flow's confident 12-return cap must not leak in here.
    test "an unchanged count reports both numbers and hedges on the cause" do
      assert {:error, message} = Registry.ensure_track_created(3, 3)

      assert message =~ "went from 3 to 3"
      assert message =~ "Nothing was renamed"
      assert message =~ "Intro/Lite"
      refute message =~ "limit of 12"
    end

    # A track deleted in Live's UI mid-sequence, or a stale count reply. Report
    # what was seen rather than assert the count is "still" the old one.
    test "a count that went down reports both numbers honestly" do
      assert {:error, message} = Registry.ensure_track_created(3, 2)

      assert message =~ "went from 3 to 2"
      assert message =~ "Nothing was renamed"
    end
  end
end
