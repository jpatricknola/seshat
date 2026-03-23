defmodule Seshat.OSC.Message do
  @moduledoc """
  Encodes OSC messages into binary wire format.

  OSC wire format:
    - Address string: null-terminated, padded to 4-byte boundary
    - Type tag string: "," + types, null-terminated, padded to 4-byte boundary
    - Arguments: each encoded per type, padded to 4-byte boundary
  """

  @spec decode(binary()) :: {String.t(), list()}
  def decode(binary) do
    {address, rest} = read_string(binary)
    {type_string, rest} = read_string(rest)
    types = type_string |> String.trim_leading(",") |> String.graphemes()
    {args, _rest} = Enum.map_reduce(types, rest, &decode_arg/2)
    {address, args}
  end

  defp read_string(binary) do
    null_pos = find_null(binary, 0)
    str = binary_part(binary, 0, null_pos)
    padded = pad_to_4(null_pos + 1)
    rest = binary_part(binary, padded, byte_size(binary) - padded)
    {str, rest}
  end

  defp find_null(bin, pos) do
    if :binary.at(bin, pos) == 0, do: pos, else: find_null(bin, pos + 1)
  end

  defp pad_to_4(n) do
    case rem(n, 4) do
      0 -> n
      r -> n + (4 - r)
    end
  end

  defp decode_arg("i", <<val::big-signed-integer-32, rest::binary>>), do: {val, rest}
  defp decode_arg("f", <<val::big-float-32, rest::binary>>), do: {val, rest}
  defp decode_arg("s", data), do: read_string(data)
  defp decode_arg("T", data), do: {true, data}
  defp decode_arg("F", data), do: {false, data}

  @spec encode(String.t(), list()) :: binary()
  def encode(address, args) do
    type_tags = Enum.map_join(args, &type_tag/1)
    encoded_args = Enum.map(args, &encode_arg/1)

    IO.iodata_to_binary([
      pad_string(address),
      pad_string("," <> type_tags)
      | encoded_args
    ])
  end

  defp type_tag(n) when is_integer(n), do: "i"
  defp type_tag(f) when is_float(f), do: "f"
  defp type_tag(s) when is_binary(s), do: "s"

  defp encode_arg(n) when is_integer(n), do: <<n::big-signed-integer-32>>
  defp encode_arg(f) when is_float(f), do: <<f::big-float-32>>
  defp encode_arg(s) when is_binary(s), do: pad_string(s)

  defp pad_string(s) do
    null_terminated = s <> <<0>>
    padding = 4 - rem(byte_size(null_terminated), 4)
    padding = if padding == 4, do: 0, else: padding
    null_terminated <> :binary.copy(<<0>>, padding)
  end
end
