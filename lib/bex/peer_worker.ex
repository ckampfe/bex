defmodule Bex.PeerWorker do
  use GenServer, restart: :transient
  alias Bex.{Peer, TorrentControllerWorker, Torrent}

  require Logger

  ### PUBLIC API

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    {:ok, args, {:continue, :setup}}
  end

  def remote_ip_and_port(pid) do
    GenServer.call(pid, :remote_ip_and_port)
  end

  def interested(pid) do
    GenServer.call(pid, :interested)
  end

  def not_interested(pid) do
    GenServer.call(pid, :not_interested)
  end

  def choke(pid) do
    GenServer.call(pid, :choke)
  end

  def unchoke(pid) do
    GenServer.call(pid, :unchoke)
  end

  def request_piece(pid, index) do
    GenServer.call(pid, {:request_piece, index})
  end

  ### CALLBACKS

  def handle_continue(
        :setup,
        %{
          metainfo: %{decorated: %{info_hash: info_hash}},
          socket: socket,
          peer_id: peer_id
        } = state
      ) do
    # setting this to active now says that
    # this process will be the one to receive tcp messages
    :ok = :inet.setopts(socket, active: true)

    state =
      state
      |> Map.put(:choked, true)
      |> Map.put(:interested, false)

    checkin_tick = :timer.seconds(5)

    schedule_controller_checkin(checkin_tick)

    :ok = Peer.send_handshake(socket, info_hash, peer_id)

    Logger.debug("Handshake sent to #{inspect(socket)}")

    {:noreply, state}
  end

  def handle_continue(
        :post_handshake,
        %{
          metainfo: %{decorated: %{have_pieces: have_pieces}},
          socket: socket,
          choked: choked,
          interested: interested
        } = state
      ) do
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

  def handle_call(:remote_ip_and_port, _from, %{socket: socket} = state) do
    reply = :inet.peername(socket)
    {:reply, reply, state}
  end

  def handle_call(:interested, _from, %{socket: socket} = state) do
    state =
      if !state[:interested] do
        :ok = Peer.send_interested(socket)
        Logger.debug("Let peer #{inspect(socket)} know we're interested")
        Map.put(state, :interested, true)
      else
        Logger.debug("Already let peer #{inspect(socket)} know we're interested, not sending")
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:not_interested, _from, %{socket: socket} = state) do
    state =
      if state[:interested] do
        :ok = Peer.send_not_interested(socket)
        Logger.debug("Let peer #{inspect(socket)} know we're not interested")
        Map.put(state, :interested, false)
      else
        Logger.debug("Already let peer #{inspect(socket)} know we're not interested, not sending")
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:choke, _from, %{socket: socket} = state) do
    state = Map.put(state, :choked, true)
    :ok = Peer.send_choke(socket)
    {:reply, :ok, state}
  end

  def handle_call(:unchoke, _from, %{socket: socket} = state) do
    state = Map.put(state, :choked, false)
    :ok = Peer.send_unchoke(socket)
    Logger.debug("Unchoking #{inspect(socket)}")
    {:reply, :ok, state}
  end

  def handle_call(
        {:request_piece, index},
        _from,
        %{
          metainfo: %{
            info: %{"piece length": piece_length, length: total_length}
          },
          chunk_size_bytes: chunk_size_bytes,
          socket: socket
        } = state
      ) do
    Logger.debug("Requesting piece #{index} from #{inspect(socket)}")

    chunks = Torrent.compute_chunks(total_length, piece_length, index, chunk_size_bytes)

    Logger.debug("Chunks for #{index}: #{inspect(chunks)}")

    Enum.each(chunks, fn %{offset: offset, length: length} ->
      Logger.debug("Requesting chunk #{offset} for index #{index} from #{inspect(socket)}")
      :ok = Peer.send_request(socket, index, offset, length)
    end)

    {:reply, :ok, state}
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
        %{socket: socket} = state
      ) do
    if info_hash == state[:metainfo][:decorated][:info_hash] do
      Logger.debug("Received accurate handshake")
      {:noreply, state, {:continue, :post_handshake}}
    else
      :gen_tcp.close(socket)

      {:stop,
       {:shutdown,
        "Info hash received from #{peer_id} (#{info_hash}) did not match existing (#{state["metainfo"]["decorated"]["info_hash"]})"},
       state}
    end
  end

  def handle_info(
        {:tcp, socket, <<message_length::32-big-unsigned-integer, rest::binary()>>},
        %{
          metainfo: %{
            decorated: %{info_hash: info_hash, piece_hashes: piece_hashes},
            info: %{"piece length": piece_length}
          },
          socket: socket,
          download_path: download_path
        } = state
      ) do
    case Peer.parse_message(message_length, rest) do
      %{type: :choke} ->
        :ok = Peer.send_choke(socket)
        Logger.debug("Received choke from #{inspect(socket)}, choked them")
        {:noreply, state}

      %{type: :unchoke} ->
        state = Map.put(state, :choked, false)
        :ok = Peer.send_unchoke(socket)
        Logger.debug("Received unchoke from #{inspect(socket)}, unchoked them")
        {:noreply, state}

      %{type: :interested} ->
        Logger.debug("Received interested from #{inspect(socket)}")
        todo("interested")

      %{type: :not_interested} ->
        Logger.debug("Received not_interested from #{inspect(socket)}")
        todo("not interested")

      %{type: :have, index: _index} ->
        todo("have")

      %{type: :bitfield, indexes: peer_indexes} ->
        state = Map.put(state, :peer_indexes, peer_indexes)
        Logger.debug("Received and stored bitfield from #{inspect(socket)}")
        {:noreply, state}

      %{type: :request, index: _index, begin: _begin, length: _length} ->
        todo("request")

      %{type: :piece, index: index, begin: begin, chunk: chunk} ->
        Logger.debug("Received chunk: index: #{index}, begin: #{begin}, attempting to verify")

        # expected_hash = Enum.at(piece_hashes, index)

        # with true <- Torrent.verify_piece(piece, expected_hash),
        #      {:ok, file} <- File.open(download_path, [:read]),
        #      :ok <- Torrent.write_piece(file, index, piece_length, piece),
        #      true <- Torrent.verify_piece_from_file(file, index, piece_length, expected_hash),
        #      :ok <- File.close(file) do
        #   TorrentControllerWorker.have(info_hash, index)
        #   {:noreply, state}
        # else
        #   e ->
        #     Logger.warn("#{index} did not match hash, #{inspect(e)}")
        #     {:noreply, state}
        # end

        todo("piece")

      %{type: :cancel, index: _index, begin: _begin, length: _length} ->
        todo("cancel")

      # %{type: :handshake, info_hash: info_hash, peer_id: peer_id, reserved_bytes: _reserved_bytes} ->
      #   IO.inspect("MATCH2")

      #   if info_hash == state[:metainfo][:decorated][:info_hash] do
      #     Logger.debug("Received accurate handshake")
      #     {:noreply, state, {:continue, :post_handshake}}
      #   else
      #     :gen_tcp.close(socket)

      #     {:stop,
      #      {:shutdown,
      #       "Info hash received from #{peer_id} (#{info_hash}) did not match existing (#{state["metainfo"]["decorated"]["info_hash"]})"},
      #      state}
      #   end

      %{type: :keepalive} ->
        Logger.debug("Received keepalive from #{inspect(socket)}")
        {:noreply, state}
    end
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.error("#{inspect(socket)}: #{reason}")
    reason = inspect(reason)
    {:stop, {:shutdown, reason}, state}
  end

  def handle_info({:tcp_closed, socket}, state) do
    reason = "The peer on the other end (#{inspect(socket)}) severed the connection."
    Logger.debug(reason)
    {:stop, {:shutdown, reason}, state}
  end

  def handle_info(:keepalive, %{socket: socket, peer_keepalive_tick: peer_keepalive_tick} = state) do
    Peer.send_keepalive(socket)
    Logger.debug("Keepalive sent to #{inspect(socket)}, scheduling another")
    schedule_keepalive(peer_keepalive_tick)
    {:noreply, state}
  end

  def handle_info(
        :checkin,
        %{
          metainfo: %{decorated: %{info_hash: info_hash}},
          peer_checkin_tick: peer_checkin_tick
        } = state
      ) do
    if state[:peer_indexes] do
      TorrentControllerWorker.peer_checkin(info_hash, state[:peer_indexes])
    end

    Process.send_after(self(), :checkin, peer_checkin_tick)

    {:noreply, state}
  end

  ### IMPL

  defp schedule_controller_checkin(peer_checkin_tick) do
    Process.send_after(self(), :checkin, peer_checkin_tick)
  end

  defp schedule_keepalive(peer_keepalive_tick) do
    Process.send_after(self(), :keepalive, peer_keepalive_tick)
  end

  defp todo(message) do
    raise message
  end
end
