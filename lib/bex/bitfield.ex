defmodule Bex.Bitfield do
  defstruct [:integer, :number_of_pieces]

  @moduledoc """
  'bitfield' is only ever sent as the first message.
  Its payload is a bitfield with each index that downloader has sent set to one and the rest set to zero.
  Downloaders which don't have anything yet may skip the 'bitfield' message.
  The first byte of the bitfield corresponds to indices 0 - 7 from high bit to low bit, respectively.
  The next one 8-15, etc. Spare bits at the end are set to zero.
  """

  def new(number_of_pieces) when is_integer(number_of_pieces) and number_of_pieces >= 1 do
    %__MODULE__{
      integer: 0,
      number_of_pieces: number_of_pieces
    }
  end

  def from_binary(binary, number_of_pieces)
      when is_binary(binary) and
             is_integer(number_of_pieces) and
             number_of_pieces >= 1 and
             number_of_pieces <= byte_size(binary) * 8 do
    integer = binary_to_integer(binary)

    %__MODULE__{
      integer: integer,
      number_of_pieces: number_of_pieces
    }
  end

  def to_binary(%__MODULE__{integer: integer, number_of_pieces: number_of_pieces}) do
    binary = integer_to_binary(integer)
    expected_bits_size = next_greatest_multiple_of_8(number_of_pieces)
    expected_bytes_size = (expected_bits_size / 8) |> Kernel.ceil()
    padding_bytes = expected_bytes_size - byte_size(binary)

    if padding_bytes > 0 do
      Enum.reduce(0..(padding_bytes - 1), binary, fn _, acc ->
        <<0>> <> acc
      end)
    else
      binary
    end
  end

  def to_list(%__MODULE__{number_of_pieces: number_of_pieces} = self) do
    as_binary = to_binary(self)

    for <<bit::1-big <- as_binary>> do
      bit == 1
    end
    |> Enum.reverse()
    |> Enum.take(number_of_pieces)
  end

  def get(%__MODULE__{integer: integer, number_of_pieces: number_of_pieces}, index)
      when index <= number_of_pieces do
    mask = bitmask(index)
    Bitwise.band(integer, mask) == mask
  end

  def set(%__MODULE__{integer: integer} = self, index) do
    mask = bitmask(index)
    %{self | integer: Bitwise.bor(integer, mask)}
  end

  def unset(%__MODULE__{integer: integer} = self, index) do
    mask = bitmask(index)
    %{self | integer: Bitwise.band(integer, Bitwise.bnot(mask))}
  end

  defp bitmask(index) do
    Bitwise.bsl(1, index)
  end

  defp binary_to_integer(binary) do
    :binary.decode_unsigned(binary, :big)
  end

  defp integer_to_binary(integer) do
    :binary.encode_unsigned(integer, :big)
  end

  defp next_greatest_multiple_of_8(n) do
    Bitwise.band(n + 7, -8)
  end
end
