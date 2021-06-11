defmodule Bex.TorrentControllerWorker do
  use GenServer

  require Logger

  alias Bex.PeerWorker

  ### PUBLIC API

  def start_link(%{metainfo: %{decorated: %{info_hash: info_hash}}} = options) do
    name = via_tuple(info_hash)
    Logger.debug("Starting #{inspect(name)}")
    GenServer.start_link(__MODULE__, options, name: name)
  end

  def via_tuple(name) do
    {:via, Registry, {Bex.Registry, {name, __MODULE__}}}
  end

  def add_peer(info_hash, peer) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:add_peer, peer})
  end

  def peer_checkin(info_hash, peer_indexes) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:peer_checkin, peer_indexes})
  end

  def have(info_hash, index) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:have, index})
  end

  def multicall(info_hash, {m, f, a} = mfa) when is_atom(m) and is_atom(f) and is_list(a) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:multicall, mfa})
  end

  ### CALLBACKS

  def init(options) do
    {:ok, options, {:continue, :initialize}}
  end

  def handle_continue(
        :initialize,
        %{
          metainfo: %{
            announce: announce_url,
            decorated: %{info_hash: info_hash, have_pieces: indexes},
            info: %{length: length}
          },
          port: port,
          peer_id: peer_id,
          max_downloads: _,
          controller_announce_tick: _,
          controller_interest_tick: _,
          controller_downloads_tick: _
        } = state
      ) do
    state =
      state
      |> Map.put(:peers, MapSet.new())
      |> Map.put(
        :available_piece_sets,
        Enum.map(indexes, fn _ ->
          MapSet.new()
        end)
      )
      |> Map.put(:active_downloads, [])

    Logger.debug("Announcing")

    Bex.Torrent.announce(
      announce_url,
      %{
        info_hash: info_hash,
        peer_id: peer_id,
        ip: "localhost",
        port: port,
        uploaded: 0,
        downloaded: 0,
        left: length,
        event: "started"
      }
    )

    schedule_initial_ticks(state)

    {:noreply, state}
  end

  def handle_call({:multicall, {m, f, a}}, _from, %{peers: peers} = state) do
    reply =
      peers
      |> Enum.map(fn {_ref, pid} ->
        Task.async(fn ->
          apply(m, f, [pid | a])
        end)
      end)
      |> Enum.map(fn task -> Task.await(task) end)

    {:reply, reply, state}
  end

  def handle_call(
        {:have, index},
        {from_pid, _tag} = _from,
        %{
          metainfo: %{
            decorated: %{have_pieces: indexes}
          },
          active_downloads: active_downloads
        } = state
      ) do
    # update haves
    indexes = List.replace_at(indexes, index, true)

    active_downloads =
      Enum.reject(active_downloads, fn {peer_pid, i} ->
        peer_pid == from_pid && i == index
      end)

    state =
      state
      |> Kernel.put_in([:metainfo, :decorated, :have_pieces], indexes)
      |> Map.put(:active_downloads, active_downloads)

    {:reply, :ok, state}
  end

  def handle_call(
        {:add_peer, peer_pid},
        _from,
        state
      ) do
    peer_ref = Process.monitor(peer_pid)

    state =
      Map.update!(state, :peers, fn peers ->
        MapSet.put(peers, {peer_ref, peer_pid})
      end)

    {:reply, :ok, state}
  end

  def handle_call(
        {:peer_checkin, peer_indexes},
        {from_pid, _tag} = from,
        %{available_piece_sets: _piece_peer_sets} = state
      ) do
    Logger.debug("Received checkin from #{inspect(from)}, merging")

    state =
      Map.update!(state, :available_piece_sets, fn available_piece_sets ->
        available_piece_sets
        |> Enum.zip(peer_indexes)
        |> Enum.map(fn {piece_set, peer_has?} ->
          if peer_has? do
            MapSet.put(piece_set, from_pid)
          else
            piece_set
          end
        end)
      end)

    {:reply, :ok, state}
  end

  def handle_info(
        :announce,
        %{
          metainfo: %{
            announce: announce_url,
            decorated: %{info_hash: info_hash},
            info: %{length: length}
          },
          port: port,
          peer_id: peer_id,
          controller_announce_tick: controller_announce_tick
        } = state
      ) do
    Logger.debug("Announcing")

    Bex.Torrent.announce(
      announce_url,
      %{
        info_hash: info_hash,
        peer_id: peer_id,
        ip: "localhost",
        port: port,
        uploaded: 0,
        downloaded: 0,
        left: length
      }
    )

    schedule_announce(controller_announce_tick)

    {:noreply, state}
  end

  def handle_info(
        :update_interest_states,
        %{
          metainfo: %{decorated: %{have_pieces: indexes}},
          available_piece_sets: available_piece_sets,
          controller_interest_tick: controller_interest_tick
        } = state
      ) do
    # partition peers into two sets:
    # 1. those who have a piece we need
    # 2. those who do not have a piece we need

    {_not_interested, interested_peers} =
      indexes
      |> Enum.zip(available_piece_sets)
      |> Enum.split_with(fn {have?, _peers_who_have} ->
        have?
      end)

    all_peers =
      Enum.reduce(available_piece_sets, MapSet.new(), fn peers, acc ->
        MapSet.union(acc, peers)
      end)

    interested_peers =
      interested_peers
      |> Enum.map(fn {_have?, peers} -> peers end)
      |> Enum.reduce(MapSet.new(), fn peers, acc ->
        MapSet.union(acc, peers)
      end)

    not_interested_peers = MapSet.difference(all_peers, interested_peers)

    Enum.each(not_interested_peers, fn peer ->
      PeerWorker.not_interested(peer)
    end)

    Enum.each(interested_peers, fn peer ->
      PeerWorker.interested(peer)
    end)

    Logger.debug("#{Enum.count(not_interested_peers)} peers not of interest")
    Logger.debug("#{Enum.count(interested_peers)} peers of interest")

    schedule_update_interest(controller_interest_tick)

    {:noreply, state}
  end

  def handle_info(
        :downloads,
        %{
          metainfo: %{decorated: %{have_pieces: pieces}},
          peers: peers,
          max_downloads: max_downloads,
          active_downloads: active_downloads,
          controller_downloads_tick: controller_downloads_tick,
          available_piece_sets: available_piece_sets
        } = state
      ) do
    cond do
      Enum.count(active_downloads) >= max_downloads ->
        Logger.debug("Reached max concurrent downloads, not staring any more downloads")
        schedule_downloads(controller_downloads_tick)
        {:noreply, state}

      Enum.empty?(peers) ->
        Logger.debug("No available peers to download from")
        schedule_downloads(controller_downloads_tick)
        {:noreply, state}

      true ->
        with {:ok, unhad_index} <- random_unhad_piece(pieces),
             {:ok, peer_with_piece} <- random_peer_with_piece(unhad_index, available_piece_sets),
             :ok <- PeerWorker.request_piece(peer_with_piece, unhad_index) do
          Logger.debug("Asked #{inspect(peer_with_piece)} for #{unhad_index}")

          state =
            Map.update!(state, :active_downloads, fn active_downloads ->
              [{peer_with_piece, unhad_index} | active_downloads]
            end)

          schedule_downloads(controller_downloads_tick)

          {:noreply, state}
        else
          :have_all_pieces ->
            Logger.debug("Download complete, not scheduling further download")
            {:noreply, state}

          {:empty_peer_set, index} ->
            Logger.debug("No peers have #{index}")
            schedule_downloads(controller_downloads_tick)
            {:noreply, state}

          :empty_peer_sets ->
            Logger.debug("No peers available, not downloading anything.")
            schedule_downloads(controller_downloads_tick)
            {:noreply, state}

          e ->
            Logger.error(inspect(e))
            schedule_downloads(controller_downloads_tick)
            {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    Logger.debug("#{inspect({ref, pid})} went down for #{inspect(reason)}")

    state =
      state
      |> Map.update!(:peers, fn peers ->
        MapSet.delete(peers, {ref, pid})
      end)
      |> Map.update!(:available_piece_sets, fn available_piece_sets ->
        Enum.map(available_piece_sets, fn piece_set ->
          MapSet.delete(piece_set, pid)
        end)
      end)
      |> Map.update!(:active_downloads, fn active_downloads ->
        Enum.reject(active_downloads, fn {peer_pid, _index} ->
          peer_pid == pid
        end)
      end)

    {:noreply, state}
  end

  ### IMPL

  def schedule_initial_ticks(
        %{
          controller_interest_tick: controller_interest_tick,
          controller_announce_tick: controller_announce_tick,
          controller_downloads_tick: controller_download_tick
        } = _state
      ) do
    schedule_announce(controller_announce_tick)
    schedule_update_interest(controller_interest_tick)
    schedule_downloads(controller_download_tick)
  end

  def schedule_update_interest(controller_interest_tick) do
    Process.send_after(self(), :update_interest_states, controller_interest_tick)
    Logger.debug("Interest state update scheduled to occur in #{controller_interest_tick}ms")
  end

  def schedule_announce(controller_announce_tick) do
    Process.send_after(self(), :announce, controller_announce_tick)
    Logger.debug("Announce scheduled to occur in #{controller_announce_tick}ms")
  end

  def schedule_downloads(controller_downloads_tick) do
    Process.send_after(self(), :downloads, controller_downloads_tick)
    Logger.debug("Downloads scheduled to occur in #{controller_downloads_tick}ms")
  end

  def random_unhad_piece(pieces) when is_list(pieces) do
    unhad_pieces =
      pieces
      |> Enum.with_index()
      |> Enum.reject(fn {have?, _index} -> have? end)

    if Enum.empty?(unhad_pieces) do
      :have_all_pieces
    else
      {_have?, index} = Enum.random(unhad_pieces)
      {:ok, index}
    end
  end

  def random_peer_with_piece(index, [] = peer_sets)
      when is_integer(index) and is_list(peer_sets) do
    :empty_peer_sets
  end

  def random_peer_with_piece(index, peer_sets) when is_integer(index) and is_list(peer_sets) do
    peer_set = Enum.at(peer_sets, index)

    if Enum.empty?(peer_set) do
      {:empty_peer_set, index}
    else
      {:ok, Enum.random(peer_set)}
    end
  end
end
