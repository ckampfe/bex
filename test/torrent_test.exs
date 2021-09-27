defmodule TorrentTest do
  use ExUnit.Case

  alias Bex.{Torrent, Chunk}

  test "compute_chunks/4, 1 special" do
    # 32768 bytes
    piece_length = :math.pow(2, 15) |> Kernel.trunc()
    chunk_length = :math.pow(2, 14) |> Kernel.trunc()

    # 6 pieces
    total_length = piece_length * 5 + 1000

    assert Torrent.compute_chunks(total_length, piece_length, 0, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 1, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 2, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 3, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 4, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 5, chunk_length) == [
             %Chunk{length: 1000, offset_within_piece: 0}
           ]
  end

  test "compute_chunks/4, 2 special" do
    # 32768 bytes
    piece_length = :math.pow(2, 15) |> Kernel.trunc()
    chunk_length = :math.pow(2, 14) |> Kernel.trunc()

    # 6 pieces
    total_length = piece_length * 5 + chunk_length + 1000

    assert Torrent.compute_chunks(total_length, piece_length, 0, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 1, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 2, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 3, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 4, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: chunk_length, offset_within_piece: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 5, chunk_length) == [
             %Chunk{length: chunk_length, offset_within_piece: 0},
             %Chunk{length: 1000, offset_within_piece: chunk_length}
           ]
  end
end
