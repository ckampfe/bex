defmodule PieceTest do
  use ExUnit.Case

  alias Bex.{Torrent, Piece}

  test "hash/1, write_piece/4, read_piece/3, hash_piece/3, calculate_piece_location/2" do
    {:ok, ram_file} = :file.open("ramdisk", [:ram, :read, :write, :binary])

    # 16 KiB
    piece_length = :math.pow(2, 14) |> Kernel.trunc()

    random_number_of_pieces = :rand.uniform(64)

    random_pieces_with_hashes =
      for _ <- 0..(random_number_of_pieces - 1) do
        piece_bytes = :rand.bytes(piece_length)
        hash = Torrent.hash(piece_bytes)
        {hash, piece_bytes}
      end

    for {{_hash, piece_bytes}, piece_index} <- Enum.with_index(random_pieces_with_hashes) do
      piece = %Piece{index: piece_index, length: piece_length}
      Piece.write(piece, ram_file, piece_bytes)
    end

    {{existing_hash, _bytes}, random_index} =
      random_pieces_with_hashes
      |> Enum.with_index()
      |> Enum.random()

    piece = %Piece{index: random_index, length: piece_length}

    assert Piece.verify(piece, ram_file, existing_hash)

    :ok = :file.close(ram_file)
  end
end
