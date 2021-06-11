defmodule Bex.Peer do
  alias Bex.Torrent
  require Logger

  ### SEND

  def send_handshake(socket, info_hash, peer_id) do
    bt = "BitTorrent protocol"

    message = [
      19,
      bt,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      info_hash,
      peer_id
    ]

    send_message_raw(
      socket,
      message
    )
  end

  def send_keepalive(socket) do
    send_message(socket, <<>>)
  end

  def send_choke(socket) do
    send_message(socket, <<0>>)
  end

  def send_unchoke(socket) do
    send_message(socket, <<1>>)
  end

  def send_interested(socket) do
    send_message(socket, <<2>>)
  end

  def send_not_interested(socket) do
    send_message(socket, <<3>>)
  end

  def send_have(socket, index) do
    encoded_index = Torrent.encode_number(index)
    send_message(socket, <<4, encoded_index>>)
  end

  def send_bitfield(socket, indexes) do
    bitfield = Torrent.indexes_to_bitfield(indexes)
    send_message(socket, <<5, bitfield>>)
  end

  def send_request(socket, index, begin, length) do
    send_message(
      socket,
      [
        6,
        Torrent.encode_number(index),
        Torrent.encode_number(begin),
        Torrent.encode_number(length)
      ]
    )
  end

  def send_piece(socket, index, begin, piece) do
    send_message(socket, <<7, Torrent.encode_number(index), Torrent.encode_number(begin), piece>>)
  end

  def send_cancel(socket, index, begin, length) do
    send_message(
      socket,
      <<8, Torrent.encode_number(index), Torrent.encode_number(begin),
        Torrent.encode_number(length)>>
    )
  end

  def send_message(socket, iolist) do
    length = :erlang.iolist_size(iolist)
    length_as_bytes = Torrent.encode_number(length)
    iolist = [length_as_bytes | iolist] |> IO.inspect(label: "send")
    send_message_raw(socket, iolist)
  end

  def send_message_raw(socket, bytes) do
    :gen_tcp.send(socket, bytes)
  end

  ### RECEIVE

  def parse_message(message_length, packet) do
    chunk_length = message_length - 9

    case packet do
      <<0>> ->
        %{type: :choke}

      <<1>> ->
        %{type: :unchoke}

      <<2>> ->
        %{type: :interested}

      <<3>> ->
        %{type: :not_interested}

      <<4, index::32-integer-big>> ->
        %{type: :have, index: index}

      <<5, bitfield::binary()>> ->
        indexes = Torrent.bitfield_to_indexes(bitfield)
        %{type: :bitfield, indexes: indexes}

      <<6, index::32-integer-big, begin::32-integer-big, length::32-integer-big>> ->
        %{type: :request, index: index, begin: begin, length: length}

      <<7, index::32-integer-big, begin::32-integer-big, chunk::bytes-size(chunk_length)>> ->
        %{type: :piece, index: index, begin: begin, chunk: chunk}

      <<8, index::32-integer-big, begin::32-integer-big, length::32-integer-big>> ->
        %{type: :cancel, index: index, begin: begin, length: length}

      # <<
      #   19,
      #   "BitTorrent protocol",
      #   reserved_bytes::bytes-size(8),
      #   info_hash::bytes-size(20),
      #   peer_id::bytes-size(20)
      # >> ->
      #   %{
      #     type: :handshake,
      #     reserved_bytes: reserved_bytes,
      #     info_hash: info_hash,
      #     peer_id: peer_id
      #   }

      <<>> ->
        %{type: :keepalive}
    end
  end
end
