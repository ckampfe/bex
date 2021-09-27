defmodule PeerTest do
  use ExUnit.Case
  doctest Bex.Peer

  alias Bex.Peer.Message

  test "Peer.Message.Serialize.to_bytes/1 Integer" do
    assert Message.Serialize.to_bytes(99) == [<<0, 0, 0, 99>>]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Handshake" do
    extension_bytes = :rand.bytes(8) |> :erlang.binary_to_list()
    info_hash = :rand.bytes(20)
    peer_id = :rand.bytes(20)

    m = %Message.Handshake{
      info_hash: info_hash,
      peer_id: peer_id,
      extension_bytes: extension_bytes
    }

    assert Message.Serialize.to_bytes(m) == [
             19,
             "BitTorrent protocol",
             extension_bytes,
             info_hash,
             peer_id
           ]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Choke" do
    m = %Message.Choke{}
    assert Message.Serialize.to_bytes(m) == [0]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Unchoke" do
    m = %Message.Unchoke{}
    assert Message.Serialize.to_bytes(m) == [1]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Interested" do
    m = %Message.Interested{}
    assert Message.Serialize.to_bytes(m) == [2]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.NotInterested" do
    m = %Message.NotInterested{}
    assert Message.Serialize.to_bytes(m) == [3]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Have" do
    m = %Message.Have{index: 99}
    assert Message.Serialize.to_bytes(m) == [4, [<<0, 0, 0, 99>>]]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Bitfield" do
    bitfield =
      10
      |> Bex.BitArray.new()
      |> Bex.BitArray.set(7)

    m = %Message.Bitfield{bitfield: bitfield}
    assert Message.Serialize.to_bytes(m) == [5, <<1, 0>>]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Request" do
    m = %Message.Request{index: 99, begin: 0, length: 1024}

    assert Message.Serialize.to_bytes(m) == [
             6,
             [<<0, 0, 0, 99>>],
             [<<0, 0, 0, 0>>],
             [<<0, 0, 4, 0>>]
           ]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Piece" do
    m = %Message.Piece{index: 8, begin: 0, chunk: <<1, 2, 3, 4>>}

    assert Message.Serialize.to_bytes(m) == [
             7,
             [<<0, 0, 0, 8>>],
             [<<0, 0, 0, 0>>],
             <<1, 2, 3, 4>>
           ]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Cancel" do
    m = %Message.Cancel{index: 99, begin: 0, length: 1024}

    assert Message.Serialize.to_bytes(m) == [
             8,
             [<<0, 0, 0, 99>>],
             [<<0, 0, 0, 0>>],
             [<<0, 0, 4, 0>>]
           ]
  end

  test "Peer.Message.Serialize.to_bytes/1 Message.Keepalive" do
    m = %Message.Keepalive{}
    assert Message.Serialize.to_bytes(m) == []
  end
end
