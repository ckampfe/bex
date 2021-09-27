defmodule Bex.Chunk do
  defstruct [:offset_within_piece, :length]

  def read(
        %__MODULE__{offset_within_piece: offset_within_piece, length: chunk_length},
        %Bex.Piece{} = piece,
        file
      ) do
    piece_byte_location = Bex.Piece.byte_location(piece)
    chunk_byte_location = piece_byte_location + offset_within_piece
    :file.pread(file, chunk_byte_location, chunk_length)
  end

  def write(
        %__MODULE__{offset_within_piece: offset_within_piece},
        %Bex.Piece{} = piece,
        file,
        chunk_bytes
      ) do
    location = Bex.Piece.byte_location(piece) + offset_within_piece
    out = :file.pwrite(file, location, chunk_bytes)
    :file.position(file, :bof)
    out
  end
end
