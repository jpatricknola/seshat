defmodule Seshat.OSC.Message do
  @moduledoc """
  Encodes and decodes OSC messages in binary wire format.

  OSC wire format:
    - Address string: null-terminated, padded to 4-byte boundary
    - Type tag string: "," + types, null-terminated, padded to 4-byte boundary
    - Arguments: each encoded per type, padded to 4-byte boundary

  ## Decoding is deliberately strict

  `decode/1` returns `{:ok, {address, args}}` or `{:error, reason}` and never
  raises: it is fed raw datagrams off a UDP socket, and one malformed packet
  must not take `Seshat.OSC.Transport` down with it.

  Every check it makes is one that real AbletonOSC output passes. Its replies
  and pushes are built by pythonosc's `OscMessageBuilder`
  (`priv/AbletonOSC/pythonosc`), which emits single messages (never bundles),
  spec-compliant zero padding, no trailing bytes, UTF-8 strings, and — for the
  Python types Live's handlers return — only the type tags `i`, `f`, `s`, `T`,
  `F` and `N`.
  So anything rejected here is, in practice, not AbletonOSC talking. Unknown
  type tags are refused rather than skipped: decoding a tag we have never seen
  would hand downstream code a value nothing was written against.

  `encode/2` is the opposite: its arguments come from our own handler code, so
  a bad argument type raises rather than returning an error.
  """

  @supported_tags ~w(i f s T F N)

  @doc """
  Decode an OSC datagram.

  Returns `{:ok, {address, args}}`, or `{:error, reason}` for anything that
  isn't a well-formed OSC message built from the supported type tags. Reasons
  exist to be logged — nothing matches on them — but each failure mode is
  distinguishable.
  """
  @spec decode(binary()) :: {:ok, {String.t(), list()}} | {:error, term()}
  def decode(<<>>), do: {:error, :empty_packet}

  def decode(binary) when is_binary(binary) do
    with {:ok, address, rest} <- read_string(binary),
         :ok <- validate_address(address),
         {:ok, type_string, rest} <- read_string(rest),
         {:ok, tags} <- parse_type_tags(type_string),
         {:ok, args, rest} <- decode_args(tags, rest, []),
         :ok <- expect_end(rest) do
      {:ok, {address, args}}
    end
  end

  # An OSC string is null-terminated and then zero-padded to a 4-byte boundary.
  # All three of those are checked: a missing terminator, a pad that runs past
  # the end of the datagram, and non-zero pad bytes are each an error rather
  # than a raise or a silent misread of the following argument.
  defp read_string(binary) do
    case :binary.match(binary, <<0>>) do
      :nomatch ->
        {:error, :unterminated_string}

      {null_pos, 1} ->
        pad_len = pad_to_4(null_pos + 1) - (null_pos + 1)

        case binary do
          <<str::binary-size(null_pos), 0, pad::binary-size(pad_len), rest::binary>> ->
            if pad == :binary.copy(<<0>>, pad_len) do
              {:ok, str, rest}
            else
              {:error, {:non_zero_string_padding, str}}
            end

          _ ->
            {:error, :padding_past_end_of_packet}
        end
    end
  end

  # Also rejects `#bundle` packets, with a reason that names what arrived.
  defp validate_address("/" <> _ = address), do: validate_utf8(address, :invalid_utf8_address)
  defp validate_address(address), do: {:error, {:invalid_address, address}}

  # A leading `/` is a byte match, so `<<"/", 255>>` is a well-formed OSC string
  # and an invalid Elixir one. Nothing downstream is written for that: an
  # address or a track name carrying one bad byte reaches `Session.State`, then
  # raises `{:invalid_byte, _}` inside Anubis's JSON encoder on every reply that
  # carries it — a crash displaced from the boundary that admitted it, and a
  # mirror that keeps re-raising until it refreshes. Real AbletonOSC cannot
  # produce one: pythonosc's `write_string` is an explicit `val.encode('utf-8')`
  # and an unencodable `str` raises `BuildError` before reaching the wire. The
  # type-tag string needs no check of its own — every byte in it is already
  # matched against `@supported_tags`, which are ASCII.
  defp validate_utf8(str, reason) do
    if String.valid?(str), do: :ok, else: {:error, {reason, str}}
  end

  # Byte-wise on purpose: a type tag string is ASCII by definition, and the
  # bytes here are untrusted, so nothing should go through String/2 functions
  # that assume valid UTF-8.
  defp parse_type_tags("," <> tags) do
    {:ok, for(<<tag::binary-size(1) <- tags>>, do: tag)}
  end

  defp parse_type_tags(other), do: {:error, {:missing_type_tag_string, other}}

  defp pad_to_4(n) do
    case rem(n, 4) do
      0 -> n
      r -> n + (4 - r)
    end
  end

  defp decode_args([], rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_args([tag | tags], data, acc) do
    case decode_arg(tag, data) do
      {:ok, value, rest} -> decode_args(tags, rest, [value | acc])
      {:error, _reason} = error -> error
    end
  end

  defp decode_arg("i", <<val::big-signed-integer-32, rest::binary>>), do: {:ok, val, rest}
  defp decode_arg("f", <<val::big-float-32, rest::binary>>), do: {:ok, val, rest}

  defp decode_arg("s", data) do
    with {:ok, str, rest} <- read_string(data),
         :ok <- validate_utf8(str, :invalid_utf8_argument) do
      {:ok, str, rest}
    end
  end

  defp decode_arg("T", data), do: {:ok, true, data}
  defp decode_arg("F", data), do: {:ok, false, data}
  # OSC nil: type tag only, no payload bytes. AbletonOSC sends it for every
  # clip.* property of an empty slot in a /live/song/get/track_data reply.
  defp decode_arg("N", data), do: {:ok, nil, data}

  # A float payload that is four bytes long but didn't match above is NaN or
  # ±Infinity, which BEAM floats cannot represent. Distinguished from a short
  # payload so the log says which one happened.
  defp decode_arg("f", <<_::binary-size(4), _::binary>>), do: {:error, :non_finite_float}

  defp decode_arg(tag, data) when tag in @supported_tags,
    do: {:error, {:truncated_payload, tag, byte_size(data)}}

  defp decode_arg(tag, _data), do: {:error, {:unsupported_type_tag, tag}}

  defp expect_end(<<>>), do: :ok
  defp expect_end(rest), do: {:error, {:trailing_data, byte_size(rest)}}

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
