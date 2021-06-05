defmodule TorrentTest do
  use ExUnit.Case

  test "hash/1, write_piece/4, read_piece/3, hash_piece/3, calculate_piece_location/2" do
    {:ok, ram_file} = :file.open("ramdisk", [:ram, :read, :write, :binary])

    # 16 KiB
    piece_length = :math.pow(2, 14) |> Kernel.trunc()

    random_number_of_pieces = :rand.uniform(64)

    random_pieces_with_hashes =
      for _ <- 0..(random_number_of_pieces - 1) do
        piece_bytes = :rand.bytes(piece_length)
        hash = Bex.Torrent.hash(piece_bytes)
        {hash, piece_bytes}
      end

    for {{_hash, piece_bytes}, piece_index} <- Enum.with_index(random_pieces_with_hashes) do
      Bex.Torrent.write_piece(ram_file, piece_index, piece_length, piece_bytes)
    end

    {{existing_hash, _bytes}, random_index} =
      random_pieces_with_hashes
      |> Enum.with_index()
      |> Enum.random()

    computed_hash = Bex.Torrent.hash_piece(ram_file, random_index, piece_length)

    assert computed_hash == existing_hash

    :ok = :file.close(ram_file)
  end

  test "have/2" do
    old = [
      true,
      true,
      false,
      true,
      false,
      false,
      true,
      true
    ]

    new = Bex.Torrent.have(old, 4)

    assert new ==
             [
               true,
               true,
               false,
               true,
               true,
               false,
               true,
               true
             ]
  end

  test "indexes_to_bitfield/1" do
    assert Bex.Torrent.indexes_to_bitfield([true, true, true, true, true, true, true, true]) ==
             <<255>>

    assert Bex.Torrent.indexes_to_bitfield([
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             false,
             false,
             false,
             false,
             false,
             false,
             false,
             false
           ]) == <<255, 0>>

    assert Bex.Torrent.indexes_to_bitfield([
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             false,
             false,
             false,
             false,
             false
             # with 3 missing indexes
           ]) == <<255, 0>>

    assert Bex.Torrent.indexes_to_bitfield([
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             false,
             false,
             false,
             false,
             false,
             true,
             true,
             true
           ]) == <<255, 224>>
  end

  test "bitfield_to_indexes/1" do
    assert Bex.Torrent.bitfield_to_indexes(<<255>>) == [
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             true
           ]

    assert Bex.Torrent.bitfield_to_indexes(<<255, 0>>) == [
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             false,
             false,
             false,
             false,
             false,
             false,
             false,
             false
           ]

    assert Bex.Torrent.bitfield_to_indexes(<<255, 224>>) == [
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             false,
             false,
             false,
             false,
             false,
             true,
             true,
             true
           ]

    assert Bex.Torrent.bitfield_to_indexes(<<255, 0>>) ==
             [
               true,
               true,
               true,
               true,
               true,
               true,
               true,
               true,
               false,
               false,
               false,
               false,
               false,
               false,
               false,
               false
             ]
  end

  test "encode_number/1" do
    assert Bex.Torrent.encode_number(1) == <<0, 0, 0, 1>>
    assert Bex.Torrent.encode_number(255) == <<0, 0, 0, 255>>
  end
end
