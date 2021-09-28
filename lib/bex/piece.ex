defmodule Bex.Piece do
  defstruct [:index, :length]

  @type t :: %__MODULE__{index: non_neg_integer(), length: pos_integer()}

  @spec read(t, :file.io_device()) :: {:ok, term} | :eof | {:error, term}
  def read(%__MODULE__{length: length} = piece, file) do
    location = byte_location(piece)
    :file.pread(file, location, length)
  end

  @spec write(t, :file.io_device(), binary()) :: :ok | {:error, term}
  def write(%__MODULE__{} = piece, file, piece_bytes) do
    location = byte_location(piece)
    :file.pwrite(file, location, piece_bytes)
  end

  @spec verify(t, :file.io_device(), binary()) :: boolean() | {:error, term}
  def verify(%__MODULE__{} = piece, file, expected_hash) do
    case read(piece, file) do
      {:ok, bytes} ->
        Bex.Torrent.hash(bytes) == expected_hash

      {:error, _error} = e ->
        e
    end
  end

  @spec byte_location(t) :: non_neg_integer()
  def byte_location(%__MODULE__{index: index, length: length} = _piece) when index >= 0 do
    index * length
  end
end
