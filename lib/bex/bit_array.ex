defmodule Bex.BitArray do
  defstruct [:repr, :number_of_pieces]

  def new(number_of_pieces) when is_integer(number_of_pieces) and number_of_pieces > 0 do
    %__MODULE__{
      repr: :array.new(number_of_pieces, default: false),
      number_of_pieces: number_of_pieces
    }
  end

  def new([el | _] = list) when is_list(list) and is_boolean(el) do
    number_of_pieces = Enum.count(list)
    repr = :array.new(number_of_pieces, default: false)

    repr =
      list
      |> Enum.with_index()
      |> Enum.reduce(repr, fn {el, i}, acc ->
        if el do
          :array.set(i, true, acc)
        else
          acc
        end
      end)

    %__MODULE__{
      repr: repr,
      number_of_pieces: number_of_pieces
    }
  end

  def new([el | _] = list) when is_list(list) and is_integer(el) do
    list
    |> Enum.map(fn
      1 -> true
      0 -> false
    end)
    |> new()
  end

  def from_binary(binary, number_of_pieces)
      when is_binary(binary) and is_integer(number_of_pieces) do
    list =
      for <<bit::1 <- binary>> do
        bit
      end
      |> Enum.take(number_of_pieces)

    new(list)
  end

  def to_binary(%__MODULE__{number_of_pieces: number_of_pieces} = this) do
    raw_binary =
      this
      |> to_list()
      |> Enum.map(fn
        true -> 1
        false -> 0
      end)
      |> pad_to_8_bits()
      |> Integer.undigits(2)
      |> :binary.encode_unsigned(:big)

    bitspace = next_greatest_multiple_of_8(number_of_pieces)

    expected_bytes_size = (bitspace / 8) |> Kernel.ceil()
    padding_bytes = expected_bytes_size - byte_size(raw_binary)

    if padding_bytes > 0 do
      Enum.reduce(0..(padding_bytes - 1), raw_binary, fn _, acc ->
        # in the case that we only set bits further into the structure, ie,
        # <<0, 128>> (going from MSB to LSB),
        # we will need to pad the leading bytes, as :binary.encode_unsigned will
        # return, for example, :binary.encode_unsigned(128) == <<128>>,
        # rather than <<0, 128>>, as we need given a bit space with size `>8 && <17`
        <<0>> <> acc
      end)
    else
      raw_binary
    end
  end

  def to_list(%__MODULE__{repr: repr}) do
    :array.to_list(repr)
  end

  def equals?(
        %__MODULE__{
          number_of_pieces: number_of_pices_1
        } = this,
        %__MODULE__{
          number_of_pieces: number_of_pices_2
        } = that
      ) do
    if number_of_pices_1 != number_of_pices_2 do
      false
    else
      to_list(this) == to_list(that)
    end
  end

  def get(%__MODULE__{repr: repr, number_of_pieces: number_of_pieces}, index)
      when is_integer(index) and index >= 0 and index < number_of_pieces do
    :array.get(index, repr)
  end

  def set(%__MODULE__{repr: repr} = this, index) do
    %{this | repr: :array.set(index, true, repr)}
  end

  def unset(%__MODULE__{repr: repr} = this, index) do
    %{this | repr: :array.set(index, false, repr)}
  end

  def set_count(%__MODULE__{repr: repr}) do
    :array.foldl(
      fn _i, v, acc ->
        if v do
          acc + 1
        else
          acc
        end
      end,
      0,
      repr
    )
  end

  def unset_count(%__MODULE__{number_of_pieces: number_of_pieces} = this) do
    number_of_pieces - set_count(this)
  end

  def all?(%__MODULE__{number_of_pieces: number_of_pieces} = this) do
    set_count(this) == number_of_pieces
  end

  def any?(%__MODULE__{} = this) do
    set_count(this) > 0
  end

  def none?(%__MODULE__{number_of_pieces: number_of_pieces} = this) do
    unset_count(this) == number_of_pieces
  end

  defp next_greatest_multiple_of_8(n) do
    Bitwise.band(n + 7, -8)
  end

  defp pad_to_8_bits(bitlist) do
    len = Enum.count(bitlist)
    expected_size = next_greatest_multiple_of_8(len)
    diff = expected_size - len
    pad_bits = Stream.repeatedly(fn -> 0 end) |> Enum.take(diff)
    bitlist ++ pad_bits
  end

  if Code.ensure_loaded?(:erts_debug) &&
       Code.ensure_loaded?(:erlang) &&
       Kernel.function_exported?(:erts_debug, :size, 1) &&
       Kernel.function_exported?(:erlang, :system_info, 1) do
    @doc """
    The total size in bytes of the BitArray structure
    """
    def size_bytes(%__MODULE__{} = this) do
      :erts_debug.size(this) * :erlang.system_info(:wordsize)
    end
  end
end
