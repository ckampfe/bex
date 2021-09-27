defmodule Bex.Peer do
  @moduledoc false

  alias Bex.{BitArray, PeerSupervisor, Metainfo}
  require Logger

  defmodule Message do
    defprotocol Serialize do
      @spec to_bytes(t) :: iolist()
      def to_bytes(message)
    end

    defmodule Handshake do
      defstruct [:info_hash, :peer_id, :extension_bytes]
    end

    defimpl Serialize, for: Handshake do
      def to_bytes(
            %Message.Handshake{
              info_hash: info_hash,
              peer_id: peer_id,
              extension_bytes: extension_bytes
            } = message
          )
          when byte_size(info_hash) == 20 and
                 byte_size(peer_id) == 20 and
                 length(extension_bytes) == 8 do
        bt = "BitTorrent protocol"

        [19, bt, message.extension_bytes, message.info_hash, message.peer_id]
      end
    end

    defmodule Choke do
      defstruct []

      def type_tag() do
        0
      end
    end

    defimpl Serialize, for: Choke do
      def to_bytes(_message) do
        [Message.Choke.type_tag()]
      end
    end

    defmodule Unchoke do
      defstruct []

      def type_tag() do
        1
      end
    end

    defimpl Serialize, for: Unchoke do
      def to_bytes(_message) do
        [Message.Unchoke.type_tag()]
      end
    end

    defmodule Interested do
      defstruct []

      def type_tag() do
        2
      end
    end

    defimpl Serialize, for: Interested do
      def to_bytes(_message) do
        [Message.Interested.type_tag()]
      end
    end

    defmodule NotInterested do
      defstruct []

      def type_tag() do
        3
      end
    end

    defimpl Serialize, for: NotInterested do
      def to_bytes(_message) do
        [Message.NotInterested.type_tag()]
      end
    end

    defmodule Have do
      defstruct [:index]

      def type_tag() do
        4
      end
    end

    defimpl Serialize, for: Have do
      def to_bytes(message) when is_integer(message.index) do
        [Message.Have.type_tag(), Message.Serialize.to_bytes(message.index)]
      end
    end

    defmodule Bitfield do
      defstruct [:bitfield]

      def type_tag() do
        5
      end
    end

    defimpl Serialize, for: Bitfield do
      def to_bytes(message) do
        bitfield = BitArray.to_binary(message.bitfield)
        [Message.Bitfield.type_tag(), bitfield]
      end
    end

    defmodule Request do
      defstruct [:index, :begin, :length]

      def type_tag() do
        6
      end
    end

    defimpl Serialize, for: Request do
      def to_bytes(message)
          when is_integer(message.index) and is_integer(message.begin) and
                 is_integer(message.length) do
        [
          Message.Request.type_tag(),
          Message.Serialize.to_bytes(message.index),
          Message.Serialize.to_bytes(message.begin),
          Message.Serialize.to_bytes(message.length)
        ]
      end
    end

    defmodule Piece do
      defstruct [:index, :begin, :chunk]

      def type_tag() do
        7
      end
    end

    defimpl Serialize, for: Piece do
      def to_bytes(message)
          when is_integer(message.index) and is_integer(message.begin) and
                 is_binary(message.chunk) do
        [
          Message.Piece.type_tag(),
          Message.Serialize.to_bytes(message.index),
          Message.Serialize.to_bytes(message.begin),
          message.chunk
        ]
      end
    end

    defmodule Cancel do
      defstruct [:index, :begin, :length]

      def type_tag() do
        8
      end
    end

    defimpl Serialize, for: Cancel do
      def to_bytes(message)
          when is_integer(message.index) and is_integer(message.begin) and
                 is_integer(message.length) do
        [
          Message.Cancel.type_tag(),
          Message.Serialize.to_bytes(message.index),
          Message.Serialize.to_bytes(message.begin),
          Message.Serialize.to_bytes(message.length)
        ]
      end
    end

    defmodule Keepalive do
      defstruct []
    end

    defimpl Serialize, for: Keepalive do
      def to_bytes(_message) do
        []
      end
    end

    defimpl Serialize, for: Integer do
      def to_bytes(message) do
        [<<message::32-integer-big>>]
      end
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

  def send_message(socket, serializable) do
    iolist = Message.Serialize.to_bytes(serializable)
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
