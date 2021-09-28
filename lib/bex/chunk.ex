defmodule Bex.Chunk do
  defstruct [:offset_within_piece, :length]

  @type t :: %__MODULE__{offset_within_piece: non_neg_integer(), length: pos_integer()}

  @spec read(t, Bex.Piece.t(), :file.io_device()) :: {:ok, term} | :eof | {:error, term}
  def read(
        %__MODULE__{offset_within_piece: offset_within_piece, length: chunk_length},
        %Bex.Piece{} = piece,
        file
      ) do
    piece_byte_location = Bex.Piece.byte_location(piece)
    chunk_byte_location = piece_byte_location + offset_within_piece
    :file.pread(file, chunk_byte_location, chunk_length)
  end

  @spec write(t, Bex.Piece.t(), :file.io_device(), binary()) :: :ok | {:error, term}
  def write(
        %__MODULE__{offset_within_piece: offset_within_piece},
        %Bex.Piece{} = piece,
        file,
        chunk_bytes
      ) do
    location = Bex.Piece.byte_location(piece) + offset_within_piece

    with out <- :file.pwrite(file, location, chunk_bytes),
         {:ok, _new_position} <- :file.position(file, :bof) do
      out
    end
  end
end
