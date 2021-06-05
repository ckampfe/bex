defmodule Bex.PeerWorker do
  use GenServer
  alias Bex.Peer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    {:ok, args, {:continue, :pre_handshake}}
  end

  def handle_continue(:pre_handshake, %{socket: socket} = state) do
    # setting this to active now says that
    # this process will be the one to receive tcp messages
    :ok = :inet.setopts(socket, active: true)

    state =
      state
      |> Map.put(:choked, true)
      |> Map.put(:interested, false)

    {:noreply, state, {:continue, :send_handshake}}
  end

  def handle_continue(
        :send_handshake,
        %{
          "metainfo" => %{"decorated" => %{"info_hash" => info_hash}},
          socket: socket,
          peer_id: peer_id
        } = state
      ) do
    :ok = Peer.send_handshake(socket, info_hash, peer_id)

    Logger.debug("Handshake sent to #{inspect(socket)}")

    {:noreply, state}
  end

  def handle_continue(
        :post_handshake,
        %{
          "metainfo" => %{"decorated" => %{"have_pieces" => have_pieces}},
          socket: socket,
          choked: choked,
          interested: interested
        } = state
      ) do
    state = Map.put(state, :handshake_complete, true)

    handle_info(:keepalive, state)

    if Enum.any?(have_pieces) do
      Logger.debug("Have >0 pieces, sending bitfield to #{inspect(socket)}")
      Peer.send_bitfield(socket, have_pieces)
    else
      Logger.debug("Do not have any pieces, not sending bitfield to #{inspect(socket)}")
    end

    if choked do
      Peer.send_choke(socket)
    else
      Peer.send_unchoke(socket)
    end

    if interested do
      Peer.send_interested(socket)
    else
      Peer.send_not_interested(socket)
    end

    {:noreply, state}
  end

  def handle_info(
        {:tcp, _socket,
         <<
           19,
           "BitTorrent protocol",
           _reserved_bytes::bytes-size(8),
           info_hash::bytes-size(20),
           peer_id::bytes-size(20)
         >>},
        state
      ) do
    if info_hash == state["metainfo"]["decorated"]["info_hash"] do
      Logger.debug("Received accurate handshake")
      {:noreply, state, {:continue, :post_handshake}}
    else
      {:stop,
       "Info hash received from #{peer_id} (#{info_hash}) did not match existing (#{state["metainfo"]["decorated"]["info_hash"]})"}
    end
  end

  def handle_info(
        {:tcp, socket, <<message_length::32-big-unsigned-integer, rest::binary()>>},
        state
      ) do
    case Peer.parse_message(rest, message_length) do
      %{type: :choke} ->
        Logger.debug("Received choke from #{inspect(socket)}")
        {:noreply, state}

      %{type: :unchoke} ->
        todo("unchoke")

      %{type: :interested} ->
        todo("interested")

      %{type: :not_interested} ->
        todo("not interested")

      %{type: :have, index: _index} ->
        todo("have")

      %{type: :bitfield, indexes: peer_indexes} ->
        state = Map.put(state, :peer_indexes, peer_indexes)
        Logger.debug("Received and stored bitfield from #{inspect(socket)}")
        {:noreply, state}

      %{type: :request, index: _index, begin: _begin, length: _length} ->
        todo("request")

      %{type: :piece, index: _index, begin: _begin, piece: _piece} ->
        todo("piece")

      %{type: :cancel, index: _index, begin: _begin, length: _length} ->
        todo("cancel")

      %{type: :handshake, info_hash: info_hash, peer_id: peer_id} ->
        if info_hash == state["metainfo"]["decorated"]["info_hash"] do
          Logger.debug("Received accurate handshake")
          state = Map.put(state, :handshake_complete, true)
          handle_info(:keepalive, state)
          {:noreply, state, {:continue, :send_initial_messages}}
        else
          {:stop,
           "Info hash received from #{peer_id} (#{info_hash}) did not match existing (#{state["metainfo"]["decorated"]["info_hash"]})"}
        end

      %{type: :keepalive} ->
        Logger.debug("Received keepalive from #{inspect(socket)}")
        {:noreply, state}
    end
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.error("#{inspect(socket)}: #{reason}")
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, _state) do
    {:stop, "The peer on the other end (#{inspect(socket)})severed the connection."}
  end

  def handle_info(:keepalive, %{socket: socket} = state) do
    Peer.send_keepalive(socket)
    Logger.debug("Keepalive sent to #{inspect(socket)}, scheduling another")
    schedule_keepalive()
    {:noreply, state}
  end

  def schedule_keepalive() do
    Process.send_after(self(), :keepalive, :timer.minutes(1))
  end

  def todo(message \\ "todo") do
    raise message
  end
end
