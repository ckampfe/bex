defmodule Bex.Piece do
  defstruct [:index, :length]

  def read(%__MODULE__{length: length} = piece, file) do
    location = byte_location(piece)
    :file.pread(file, location, length)
  end

  def write(%__MODULE__{} = piece, file, piece_bytes) do
    location = byte_location(piece)
    :file.pwrite(file, location, piece_bytes)
  end

  def verify(%__MODULE__{} = piece, file, expected_hash) do
    case read(piece, file) do
      {:ok, bytes} ->
        Bex.Torrent.hash(bytes) == expected_hash

      {:error, _error} = e ->
        e
    end
  end

  def byte_location(%__MODULE__{index: index, length: length} = _piece) when index >= 0 do
    index * length
  end
end
