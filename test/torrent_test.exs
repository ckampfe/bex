defmodule TorrentTest do
  use ExUnit.Case

  alias Bex.Torrent

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
      Torrent.write_piece(ram_file, piece_index, piece_length, piece_bytes)
    end

    {{existing_hash, _bytes}, random_index} =
      random_pieces_with_hashes
      |> Enum.with_index()
      |> Enum.random()

    computed_hash = Torrent.hash_piece_from_file(ram_file, random_index, piece_length)

    assert computed_hash == existing_hash

    :ok = :file.close(ram_file)
  end

  test "encode_number/1" do
    assert Torrent.encode_number(1) == <<0, 0, 0, 1>>
    assert Torrent.encode_number(255) == <<0, 0, 0, 255>>
  end

  test "compute_chunks/4, 1 special" do
    # 32768 bytes
    piece_length = :math.pow(2, 15) |> Kernel.trunc()
    chunk_length = :math.pow(2, 14) |> Kernel.trunc()

    # 6 pieces
    total_length = piece_length * 5 + 1000

    assert Torrent.compute_chunks(total_length, piece_length, 0, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 1, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 2, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 3, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 4, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 5, chunk_length) == [
             %{length: 1000, offset: 0}
           ]
  end

  test "compute_chunks/4, 2 special" do
    # 32768 bytes
    piece_length = :math.pow(2, 15) |> Kernel.trunc()
    chunk_length = :math.pow(2, 14) |> Kernel.trunc()

    # 6 pieces
    total_length = piece_length * 5 + chunk_length + 1000

    assert Torrent.compute_chunks(total_length, piece_length, 0, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 1, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 2, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 3, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 4, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: chunk_length, offset: chunk_length}
           ]

    assert Torrent.compute_chunks(total_length, piece_length, 5, chunk_length) == [
             %{length: chunk_length, offset: 0},
             %{length: 1000, offset: chunk_length}
           ]
  end
end
