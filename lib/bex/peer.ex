defmodule Bex.Peer do
  @moduledoc false

  alias Bex.{BitArray, PeerSupervisor, Torrent, Metainfo}
  require Logger

  defmodule Message do
    defmodule Choke do
      defstruct []

      def type_tag() do
        0
      end
    end

    defmodule Unchoke do
      defstruct []

      def type_tag() do
        1
      end
    end

    defmodule Interested do
      defstruct []

      def type_tag() do
        2
      end
    end

    defmodule NotInterested do
      defstruct []

      def type_tag() do
        3
      end
    end

    defmodule Have do
      defstruct [:index]

      def type_tag() do
        4
      end
    end

    defmodule Bitfield do
      defstruct [:bitfield]

      def type_tag() do
        5
      end
    end

    defmodule Request do
      defstruct [:index, :begin, :length]

      def type_tag() do
        6
      end
    end

    defmodule Piece do
      defstruct [:index, :begin, :chunk]

      def type_tag() do
        7
      end
    end

    defmodule Cancel do
      defstruct [:index, :begin, :length]

      def type_tag() do
        8
      end
    end

    defmodule Keepalive do
      defstruct []
    end

    def parse(packet) do
      case packet do
        <<0>> ->
          %Message.Choke{}

        <<1>> ->
          %Message.Unchoke{}

        <<2>> ->
          %Message.Interested{}

        <<3>> ->
          %Message.NotInterested{}

        <<4, index::32-integer-big>> ->
          %Message.Have{index: index}

        <<5, bitfield::binary()>> ->
          %Message.Bitfield{bitfield: bitfield}

        <<6, index::32-integer-big, begin::32-integer-big, length::32-integer-big>> ->
          %Message.Request{index: index, begin: begin, length: length}

        <<7, index::32-integer-big, begin::32-integer-big, chunk::binary()>> ->
          %Message.Piece{index: index, begin: begin, chunk: chunk}

        <<8, index::32-integer-big, begin::32-integer-big, length::32-integer-big>> ->
          %Message.Cancel{index: index, begin: begin, length: length}

        <<>> ->
          %Message.Keepalive{}
      end
    end
  end

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
          metainfo: %Metainfo{decorated: %Metainfo.Decorated{info_hash: info_hash}}
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
    send_message(socket, <<Message.Choke.type_tag()>>)
  end

  def send_unchoke(socket) do
    send_message(socket, <<Message.Unchoke.type_tag()>>)
  end

  def send_interested(socket) do
    send_message(socket, <<Message.Interested.type_tag()>>)
  end

  def send_not_interested(socket) do
    send_message(socket, <<Message.NotInterested.type_tag()>>)
  end

  def send_have(socket, index) do
    encoded_index = Torrent.encode_number(index)
    send_message(socket, [Message.Have.type_tag(), encoded_index])
  end

  def send_bitfield(socket, %BitArray{} = bitfield) do
    bitfield = BitArray.to_binary(bitfield)
    send_message(socket, [Message.Bitfield.type_tag(), bitfield])
  end

  def send_request(socket, index, begin, length) do
    send_message(
      socket,
      [
        Message.Request.type_tag(),
        Torrent.encode_number(index),
        Torrent.encode_number(begin),
        Torrent.encode_number(length)
      ]
    )
  end

  def send_piece(socket, index, begin, piece) do
    send_message(socket, [
      Message.Piece.type_tag(),
      Torrent.encode_number(index),
      Torrent.encode_number(begin),
      piece
    ])
  end

  def send_cancel(socket, index, begin, length) do
    send_message(
      socket,
      [
        Message.Cancel.type_tag(),
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

  def generate_peer_id() do
    header = "-BEX001-"
    header_length = String.length(header)
    random_bytes = :rand.bytes(100) |> Base.encode64()
    bytes_to_take = 20 - header_length - 1
    header <> String.slice(random_bytes, 0..bytes_to_take)
  end
end
