defmodule Seshat.OSC.MessageTest do
  use ExUnit.Case, async: true

  alias Seshat.OSC.Message

  # OSC string: null-terminated, padded to a 4-byte boundary.
  defp osc_string(s) do
    null_terminated = s <> <<0>>

    case rem(byte_size(null_terminated), 4) do
      0 -> null_terminated
      r -> null_terminated <> :binary.copy(<<0>>, 4 - r)
    end
  end

  describe "decode/1" do
    test "round-trips what encode/2 produces" do
      binary = Message.encode("/live/test", [3, 1.5, "hello"])
      assert {"/live/test", [3, 1.5, "hello"]} = Message.decode(binary)
    end

    test "decodes OSC nil (N) among other type tags, with no payload bytes" do
      # A track_data-style reply: an empty slot contributes nil for each
      # clip.* property — type tag N carries no payload, so the float after
      # it must still decode from the very next 4 bytes.
      binary =
        osc_string("/live/song/get/track_data") <>
          osc_string(",sTNNfFN") <>
          osc_string("Drums") <>
          <<4.0::big-float-32>>

      assert {"/live/song/get/track_data", ["Drums", true, nil, nil, 4.0, false, nil]} =
               Message.decode(binary)
    end

    test "decodes true and false type tags" do
      binary = osc_string("/live/x") <> osc_string(",TF")
      assert {"/live/x", [true, false]} = Message.decode(binary)
    end
  end
end
