defmodule Bex.Bitfield do
  defstruct [:integer, :number_of_pieces, :bitspace]

  @moduledoc """
  'bitfield' is only ever sent as the first message.
  Its payload is a bitfield with each index that downloader has sent set to one and the rest set to zero.
  Downloaders which don't have anything yet may skip the 'bitfield' message.
  The first byte of the bitfield corresponds to indices 0 - 7 from high bit to low bit, respectively.
  The next one 8-15, etc. Spare bits at the end are set to zero.
  """

  def new(number_of_pieces) when is_integer(number_of_pieces) and number_of_pieces >= 1 do
    bitspace = next_greatest_multiple_of_8(number_of_pieces)

    %__MODULE__{
      integer: 0,
      number_of_pieces: number_of_pieces,
      bitspace: bitspace
    }
  end

  def from_binary(binary, number_of_pieces)
      when is_binary(binary) and
             is_integer(number_of_pieces) and
             number_of_pieces >= 1 and
             number_of_pieces <= byte_size(binary) * 8 do
    integer = binary_to_integer(binary)
    bitspace = next_greatest_multiple_of_8(number_of_pieces)

    %__MODULE__{
      integer: integer,
      number_of_pieces: number_of_pieces,
      bitspace: bitspace
    }
  end

  def to_binary(%__MODULE__{integer: integer, number_of_pieces: number_of_pieces}) do
    binary = integer_to_binary(integer)
    expected_bits_size = next_greatest_multiple_of_8(number_of_pieces)
    expected_bytes_size = (expected_bits_size / 8) |> Kernel.ceil()
    padding_bytes = expected_bytes_size - byte_size(binary)

    if padding_bytes > 0 do
      Enum.reduce(0..(padding_bytes - 1), binary, fn _, acc ->
        # in the case that we only set bits further into the structure, ie,
        # <<0, 128>> (going from MSB to LSB),
        # we will need to pad the leading bytes, as :binary.encode_unsigned will
        # return, for example, :binary.encode_unsigned(128) == <<128>>,
        # rather than <<0, 128>>, as we need given a bit space with size `>8 && <17`
        <<0>> <> acc
      end)
    else
      binary
    end
  end

  def to_list(%__MODULE__{number_of_pieces: number_of_pieces} = this) do
    as_binary = to_binary(this)

    for <<bit::1 <- as_binary>> do
      bit == 1
    end
    |> Enum.take(number_of_pieces)
  end

  def get(
        %__MODULE__{integer: integer, number_of_pieces: number_of_pieces, bitspace: bitspace},
        index
      )
      when index <= number_of_pieces do
    mask = bitmask_for_index(index, bitspace)
    Bitwise.band(integer, mask) == mask
  end

  def set(%__MODULE__{integer: integer, bitspace: bitspace} = this, index) do
    mask = bitmask_for_index(index, bitspace)
    %{this | integer: Bitwise.bor(integer, mask)}
  end

  def unset(%__MODULE__{integer: integer, bitspace: bitspace} = this, index) do
    mask = bitmask_for_index(index, bitspace)
    %{this | integer: Bitwise.band(integer, Bitwise.bnot(mask))}
  end

  # naive, linear solution, but it works
  def all?(%__MODULE__{integer: integer}) do
    bits = Integer.digits(integer, 2)
    :erlang.rem(Enum.count(bits), 8) == 0 && Enum.all?(bits, fn d -> d == 1 end)
  end

  def none?(%__MODULE__{integer: integer}) do
    bits = Integer.digits(integer, 2)
    Enum.all?(bits, fn d -> d == 0 end)
  end

  def set_count(%__MODULE__{integer: integer}) do
    integer
    |> Integer.digits(2)
    |> Enum.filter(fn bit -> bit == 1 end)
    |> Enum.count()
  end

  def unset_count(%__MODULE__{number_of_pieces: number_of_pieces} = this) do
    set_count = set_count(this)
    number_of_pieces - set_count
  end

  def any_set?(%__MODULE__{} = this) do
    set_count(this) > 0
  end

  def any_unset?(%__MODULE__{} = this) do
    unset_count(this) > 0
  end

  defp bitmask_for_index(index, bitspace) do
    shift = bitspace - index - 1
    Bitwise.bsl(1, shift)
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
