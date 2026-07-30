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
      assert {:ok, {"/live/test", [3, 1.5, "hello"]}} = Message.decode(binary)
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

      assert {:ok, {"/live/song/get/track_data", ["Drums", true, nil, nil, 4.0, false, nil]}} =
               Message.decode(binary)
    end

    test "decodes true and false type tags" do
      binary = osc_string("/live/x") <> osc_string(",TF")
      assert {:ok, {"/live/x", [true, false]}} = Message.decode(binary)
    end
  end

  # Every case here is a shape AbletonOSC cannot produce (see the module's
  # "Decoding is deliberately strict"), so rejection is the contract, not a
  # compatibility risk. What matters is that each returns an error rather than
  # raising: these bytes arrive off a UDP socket owned by a GenServer.
  describe "decode/1 rejects malformed datagrams" do
    test "an empty packet" do
      assert Message.decode(<<>>) == {:error, :empty_packet}
    end

    test "an address with no null terminator" do
      assert Message.decode("/live/song/get/tempo") == {:error, :unterminated_string}
    end

    test "padding that runs past the end of the packet" do
      # Terminated but unpadded: "/abc" + null is 5 bytes, so the pad should run
      # to 8 and the packet stops short. The old decoder's binary_part/3 raised.
      assert Message.decode(<<"/abc", 0>>) == {:error, :padding_past_end_of_packet}
    end

    test "non-zero bytes inside a string's padding" do
      binary = <<"/live/xy", 0, 0xFF, 0, 0>> <> osc_string(",")
      assert {:error, {:non_zero_string_padding, "/live/xy"}} = Message.decode(binary)
    end

    test "an address that does not start with a slash" do
      binary = osc_string("live/x") <> osc_string(",")
      assert {:error, {:invalid_address, "live/x"}} = Message.decode(binary)
    end

    test "a bundle header, which AbletonOSC never sends" do
      binary = osc_string("#bundle") <> <<0::big-64>>
      assert {:error, {:invalid_address, "#bundle"}} = Message.decode(binary)
    end

    test "a packet that ends after the address, with no type-tag string" do
      assert Message.decode(osc_string("/live/x")) == {:error, :unterminated_string}
    end

    test "a type-tag string that does not start with a comma" do
      binary = osc_string("/live/x") <> osc_string("iii")
      assert {:error, {:missing_type_tag_string, "iii"}} = Message.decode(binary)
    end

    test "an unsupported type tag" do
      # `b` (blob) is the realistic one: pythonosc would emit it for a handler
      # returning bytes. Decoding it would hand downstream code a value nothing
      # was written against.
      binary = osc_string("/live/x") <> osc_string(",b") <> <<0, 0, 0, 0>>
      assert {:error, {:unsupported_type_tag, "b"}} = Message.decode(binary)
    end

    test "a truncated integer payload" do
      binary = osc_string("/live/x") <> osc_string(",i") <> <<0, 0>>
      assert {:error, {:truncated_payload, "i", 2}} = Message.decode(binary)
    end

    test "a truncated string argument" do
      binary = osc_string("/live/x") <> osc_string(",s") <> "Drums"
      assert Message.decode(binary) == {:error, :unterminated_string}
    end

    test "a NaN float payload, which BEAM floats cannot represent" do
      binary = osc_string("/live/x") <> osc_string(",f") <> <<0x7F, 0xC0, 0, 0>>
      assert Message.decode(binary) == {:error, :non_finite_float}
    end

    test "trailing bytes after the last argument" do
      binary = osc_string("/live/x") <> osc_string(",i") <> <<0, 0, 0, 1, 9, 9, 9, 9>>
      assert {:error, {:trailing_data, 4}} = Message.decode(binary)
    end

    test "a corrupted byte anywhere in an encoded message never raises" do
      binary = Message.encode("/live/song/get/track_data", [0, "Drums", 1.5])

      for position <- 0..(byte_size(binary) - 1) do
        <<head::binary-size(position), byte, tail::binary>> = binary
        corrupted = <<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>

        result = Message.decode(corrupted)

        # Either shape is fine — a flipped byte in a payload can still be a
        # valid message. What must never happen is a raise.
        assert match?({:ok, {_, _}}, result) or match?({:error, _}, result)
      end
    end
  end
end
