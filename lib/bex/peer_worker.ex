defmodule Bex.PeerWorker do
  @moduledoc false

  use GenServer, restart: :transient
  alias Bex.{BitArray, Peer, TorrentControllerWorker, Torrent, Metainfo, Chunk, Piece}

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

  def shutdown(pid) do
    GenServer.call(pid, :shutdown)
  end

  ### CALLBACKS

  def handle_continue(
        :setup,
        %{
          metainfo: %Metainfo{decorated: %Metainfo.Decorated{info_hash: info_hash}},
          socket: socket,
          my_peer_id: my_peer_id
        } = state
      ) do
    state =
      state
      |> Map.put(:choked, true)
      |> Map.put(:interested, false)

    checkin_tick = :timer.seconds(5)

    schedule_controller_checkin(checkin_tick)

    :ok = Peer.send_handshake(socket, info_hash, my_peer_id)

    :ok = active_once(socket)

    Logger.debug("Handshake sent to #{inspect(socket)}")

    {:noreply, state}
  end

  def handle_continue(
        :post_handshake,
        %{
          metainfo: %Metainfo{
            decorated: %Metainfo.Decorated{have_pieces: %BitArray{} = have_pieces}
          },
          socket: socket,
          choked: choked,
          interested: interested
        } = state
      ) do
    handle_info(:keepalive, state)

    if BitArray.any?(have_pieces) do
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

    these_outstanding_chunks =
      Enum.map(chunks, fn %{offset: offset, length: length} = chunk ->
        Logger.debug("Requesting chunk #{offset} for index #{index} from #{inspect(socket)}")
        :ok = Peer.send_request(socket, index, offset, length)
        chunk
      end)
      |> Enum.into(MapSet.new())

    existing_outstanding_chunks = Map.get(state, :outstanding_chunks, %{})

    existing_outstanding_chunks =
      Map.put(existing_outstanding_chunks, index, these_outstanding_chunks)

    state = Map.put(state, :outstanding_chunks, existing_outstanding_chunks)

    {:reply, :ok, state}
  end

  def handle_call(:shutdown, _from, state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:tcp, _socket,
         <<
           19,
           "BitTorrent protocol",
           _reserved_bytes::bytes-size(8),
           info_hash::bytes-size(20),
           remote_peer_id::bytes-size(20)
         >>},
        %{
          socket: socket,
          metainfo: %Bex.Metainfo{
            decorated: %Bex.Metainfo.Decorated{info_hash: existing_info_hash}
          }
        } = state
      ) do
    if info_hash == existing_info_hash do
      Logger.debug("Received accurate handshake from #{inspect(remote_peer_id)}")
      peer_pid = self()

      TorrentControllerWorker.add_peer(info_hash, remote_peer_id, peer_pid)

      state = Map.put(state, :remote_peer_id, remote_peer_id)

      Logger.debug(
        "Registered #{inspect(remote_peer_id)} -> #{inspect(peer_pid)} with TorrentControllerWorker"
      )

      :ok = :inet.setopts(socket, active: :once, packet: 4)

      {:noreply, state, {:continue, :post_handshake}}
    else
      :gen_tcp.close(socket)

      {:stop,
       {:shutdown,
        "Info hash received from #{remote_peer_id} (#{info_hash}) did not match existing (#{state["metainfo"]["decorated"]["info_hash"]})"},
       state}
    end
  end

  def handle_info(
        {:tcp, socket, rest},
        %{
          metainfo: %{
            decorated: %{info_hash: info_hash, piece_hashes: piece_hashes},
            info: %{"piece length": piece_length, length: _length}
          },
          socket: socket,
          download_path: download_path,
          remote_peer_id: remote_peer_id
        } = state
      ) do
    case Peer.Message.parse(rest) do
      %{type: :choke} ->
        Logger.debug("Received choke from #{inspect(socket)}, choked them")

        state =
          if !state[:choked] do
            state = Map.put(state, :choked, true)
            :ok = Peer.send_choke(socket)
            Logger.debug("Choked #{inspect(socket)})")
            state
          else
            state
          end

        :ok = active_once(socket)
        {:noreply, state}

      %{type: :unchoke} ->
        Logger.debug("Received unchoke from #{inspect(socket)}, unchoked them")

        state =
          if state[:choked] do
            state = Map.put(state, :choked, false)
            :ok = Peer.send_unchoke(socket)
            Logger.debug("Unchoked #{inspect(socket)}")
            state
          else
            state
          end

        :ok = active_once(socket)
        {:noreply, state}

      %{type: :interested} ->
        Logger.debug("Received interested from #{inspect(socket)}")

        state =
          if state[:choked] do
            state = Map.put(state, :choked, false)
            :ok = Peer.send_unchoke(socket)
            Logger.debug("Unchoked #{inspect(socket)}")
            state
          else
            state
          end

        :ok = active_once(socket)
        {:noreply, state}

      %{type: :not_interested} ->
        Logger.debug("Received not_interested from #{inspect(socket)}")
        :ok = active_once(socket)
        {:noreply, state}

      %{type: :have, index: index} ->
        :ok = active_once(socket)
        :ok = TorrentControllerWorker.have(info_hash, remote_peer_id, index)
        {:noreply, state}

      %{type: :bitfield, bitfield: bitfield_binary} ->
        peer_bitfield = BitArray.from_binary(bitfield_binary, length(piece_hashes))
        state = Map.put(state, :peer_bitfield, peer_bitfield)
        Logger.debug("Received and stored bitfield from #{inspect(socket)}")
        :ok = active_once(socket)
        {:noreply, state}

      %{type: :request, index: index, begin: begin, length: length} ->
        with {:ok, file} <- File.open(download_path, [:write, :read, :raw]),
             piece = %Piece{index: index, length: piece_length},
             chunk = %Chunk{offset_within_piece: begin, length: length},
             {:ok, chunk_bytes} <- Chunk.read(chunk, piece, file) do
          :ok = Peer.send_piece(socket, index, begin, chunk_bytes)
          Logger.debug("Sent chunk #{index} #{begin} #{length} to peer")
        end

        :ok = active_once(socket)

        {:noreply, state}

      %{type: :piece, index: index, begin: begin, chunk: chunk_bytes} ->
        Logger.debug("Received chunk of length #{byte_size(chunk_bytes)}")
        Logger.debug("Received chunk: index: #{index}, begin: #{begin}, attempting to verify")

        state =
          with {:ok, file} <- File.open(download_path, [:write, :read, :raw]),
               piece = %Piece{index: index, length: piece_length},
               chunk = %Chunk{offset_within_piece: begin, length: nil},
               :ok <- Chunk.write(chunk, piece, file, chunk_bytes),
               :ok <- File.close(file) do
            Logger.info("Got chunk #{index}, #{begin}")

            outstanding_chunks = Map.get(state, :outstanding_chunks, %{})

            outstanding_chunks_for_index =
              Map.get_lazy(outstanding_chunks, index, fn -> MapSet.new() end)

            Logger.info(
              "Outstanding chunks for index #{index} pre: #{inspect(outstanding_chunks_for_index)}"
            )

            outstanding_chunks_for_index =
              MapSet.delete(outstanding_chunks_for_index, %{
                offset: begin,
                length: byte_size(chunk)
              })

            Logger.info(
              "Outstanding chunks for index #{index} post: #{inspect(outstanding_chunks_for_index)}"
            )

            outstanding_chunks = Map.put(outstanding_chunks, index, outstanding_chunks_for_index)

            state = Map.put(state, :outstanding_chunks, outstanding_chunks)

            state =
              if Enum.empty?(outstanding_chunks_for_index) do
                Logger.info("Got piece #{index}")
                expected_hash = Enum.at(piece_hashes, index) |> IO.inspect(label: "Expected Hash")

                with {:ok, file} <- File.open(download_path, [:read, :raw, :binary]),
                     true <-
                       Piece.verify(piece, file, expected_hash),
                     :ok <- File.close(file) do
                  :ok = TorrentControllerWorker.have(info_hash, remote_peer_id, index)
                  :ok = Peer.send_have(socket, index)
                  state
                else
                  e ->
                    Logger.warn("#{index} did not match hash, #{inspect(e)}")
                    state
                end
              else
                state
              end

            state
          else
            e ->
              Logger.error("Error with chunk #{index}, #{begin}, #{inspect(e)}")
              state
          end

        :ok = active_once(socket)

        {:noreply, state}

      %{type: :cancel, index: _index, begin: _begin, length: _length} ->
        :ok = active_once(socket)
        todo("cancel")

      %{type: :keepalive} ->
        Logger.debug("Received keepalive from #{inspect(socket)}")
        :ok = active_once(socket)
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
          peer_checkin_tick: peer_checkin_tick,
          remote_peer_id: remote_peer_id
        } = state
      ) do
    if state[:peer_bitfield] do
      TorrentControllerWorker.peer_checkin(info_hash, remote_peer_id, state[:peer_bitfield])
    end

    schedule_controller_checkin(peer_checkin_tick)

    {:noreply, state}
  end

  ### IMPL

  defp schedule_controller_checkin(peer_checkin_tick) do
    Process.send_after(self(), :checkin, peer_checkin_tick)
  end

  defp schedule_keepalive(peer_keepalive_tick) do
    Process.send_after(self(), :keepalive, peer_keepalive_tick)
  end

  def active_once(socket) do
    :inet.setopts(socket, [{:active, :once}])
  end

  defp todo(message) do
    raise message
  end
end
