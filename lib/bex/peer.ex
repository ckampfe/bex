defmodule Bex.Peer do
  alias Bex.{PeerSupervisor, Torrent}
  require Logger

  ### SEND

  def connect_and_initialize(%{peer_id: peer_id, ip: ip, port: port} = _peer, state) do
    ip_as_charlist = String.to_charlist(ip)

    with {:ok, address} <- :inet_parse.address(ip_as_charlist),
         {:ok, socket} <- :gen_tcp.connect(address, port, [:binary, active: false]) do
      initialize_peer(socket, state)
    else
      {:error, _error} = e ->
        Logger.warn("#{peer_id}: #{inspect(e)}")
    end
  end

  def initialize_peer(
        socket,
        %{
          metainfo: %{decorated: %{info_hash: info_hash}}
        } = state
      ) do
    Logger.debug("TCP socket #{inspect(socket)} accepted, starting child process to handle")

    peer_supervisor_name = PeerSupervisor.via_tuple(info_hash)

    {:ok, peer_pid} = PeerSupervisor.start_child(peer_supervisor_name, state, socket)

    :gen_tcp.controlling_process(socket, peer_pid)

    Logger.debug(
      "Started Bex.PeerWorker #{inspect(peer_pid)} to handle socket #{inspect(socket)}"
    )
  end

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

    send_message(
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
    send_message(socket, [4, encoded_index])
  end

  def send_bitfield(socket, indexes) do
    bitfield = Torrent.indexes_to_bitfield(indexes)
    send_message(socket, [5, bitfield])
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
    send_message(socket, [7, Torrent.encode_number(index), Torrent.encode_number(begin), piece])
  end

  def send_cancel(socket, index, begin, length) do
    send_message(
      socket,
      [
        8,
        Torrent.encode_number(index),
        Torrent.encode_number(begin),
        Torrent.encode_number(length)
      ]
    )
  end

  def send_message(socket, iolist) do
    :gen_tcp.send(socket, iolist)
  end

  ### RECEIVE

  def parse_message(packet) do
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
        %{type: :bitfield, bitfield: bitfield}

      <<6, index::32-integer-big, begin::32-integer-big, length::32-integer-big>> ->
        %{type: :request, index: index, begin: begin, length: length}

      <<7, index::32-integer-big, begin::32-integer-big, chunk::binary()>> ->
        %{type: :piece, index: index, begin: begin, chunk: chunk}

      <<8, index::32-integer-big, begin::32-integer-big, length::32-integer-big>> ->
        %{type: :cancel, index: index, begin: begin, length: length}

      <<>> ->
        %{type: :keepalive}
    end
  end
end
