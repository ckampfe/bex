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

  def add_peer(info_hash, peer_id, peer_pid) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:add_peer, peer_id, peer_pid})
  end

  def peer_checkin(info_hash, peer_id, peer_indexes) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:peer_checkin, peer_id, peer_indexes})
  end

  def have(info_hash, peer_id, index) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:have, peer_id, index})
  end

  def get_not_haves(info_hash) do
    name = via_tuple(info_hash)
    GenServer.call(name, :get_not_haves)
  end

  def get_peers_for_index(info_hash, index) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:get_peers_for_index, index})
  end

  def pause(info_hash) do
    pause_ticks(info_hash)
    shutdown_peers(info_hash)
  end

  def pause_ticks(info_hash) do
    name = via_tuple(info_hash)
    GenServer.call(name, :pause_ticks)
  end

  def shutdown_peers(info_hash) do
    multicall(info_hash, {PeerWorker, :shutdown, []})
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
          listening_port: listening_port,
          my_peer_id: my_peer_id,
          announce_tick: _,
          interest_tick: _,
          downloads_tick: _
        } = state
      ) do
    state =
      state
      # %{peer_id -> pid}
      |> Map.put(:peers, BiMap.new())
      |> Map.put(
        :available_piece_sets,
        Enum.map(indexes, fn _ ->
          MapSet.new()
        end)
      )
      |> Map.put(:active_downloads, [])

    Logger.debug("Announcing")

    announce =
      Bex.Torrent.announce(
        announce_url,
        %{
          info_hash: info_hash,
          peer_id: my_peer_id,
          ip: "localhost",
          port: listening_port,
          uploaded: 0,
          downloaded: 0,
          left: length,
          event: "started"
        }
      )

    state =
      case announce do
        {:ok, %{peers: announce_peers}} ->
          Map.put(state, :announce_peers, announce_peers)

        {:error, _error} = e ->
          Logger.warn(inspect(e))
          state
      end

    tick_refs = schedule_initial_ticks(state)

    state = Map.merge(state, tick_refs)

    {:noreply, state}
  end

  def handle_call({:multicall, {m, f, a}}, _from, %{peers: peers} = state) do
    peer_pids = BiMap.values(peers)

    reply =
      peer_pids
      |> Enum.map(fn pid ->
        Task.async(fn ->
          apply(m, f, [pid | a])
        end)
      end)
      |> Enum.map(fn task -> Task.await(task) end)

    {:reply, reply, state}
  end

  def handle_call(
        {:have, peer_id, index},
        # {from_pid, _tag} = _from,
        _from,
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
      active_downloads
      |> IO.inspect(label: "active downloads pre")
      |> Enum.reject(fn {active_peer_id, i} ->
        active_peer_id == peer_id && i == index
      end)
      |> IO.inspect(label: "active downloads post")

    state =
      state
      |> Kernel.put_in([:metainfo, :decorated, :have_pieces], indexes)
      |> Map.put(:active_downloads, active_downloads)

    {:reply, :ok, state}
  end

  def handle_call(
        {:add_peer, peer_id, peer_pid},
        _from,
        state
      ) do
    _peer_ref = Process.monitor(peer_pid)

    state =
      Map.update!(state, :peers, fn peers ->
        BiMap.put(peers, peer_id, peer_pid)
      end)

    {:reply, :ok, state}
  end

  def handle_call(
        {:peer_checkin, peer_id, peer_indexes},
        {from_pid, _tag} = _from,
        %{available_piece_sets: _piece_peer_sets} = state
      ) do
    Logger.debug("Received checkin from (#{peer_id}, #{inspect(from_pid)}), merging")

    state =
      Map.update!(state, :available_piece_sets, fn available_piece_sets ->
        available_piece_sets
        |> Enum.zip(peer_indexes)
        |> Enum.map(fn {piece_set, peer_has?} ->
          if peer_has? do
            MapSet.put(piece_set, peer_id)
          else
            piece_set
          end
        end)
      end)

    {:reply, :ok, state}
  end

  def handle_call(
        :get_not_haves,
        _from,
        %{metainfo: %{decorated: %{have_pieces: pieces}}} = state
      ) do
    reply =
      Enum.with_index(pieces)
      |> Enum.flat_map(fn {have?, index} ->
        if !have? do
          [index]
        else
          []
        end
      end)

    {:reply, reply, state}
  end

  def handle_call(
        {:get_peers_for_index, index},
        _from,
        %{available_piece_sets: piece_peer_sets} = state
      ) do
    reply = Enum.at(piece_peer_sets, index)
    {:reply, reply, state}
  end

  def handle_call(
        :pause_ticks,
        _from,
        %{
          announce_tick_ref: announce_tick_ref,
          downloads_tick_ref: downloads_tick_ref,
          interest_tick_ref: interest_tick_ref
        } = state
      ) do
    for ref <- [announce_tick_ref, downloads_tick_ref, interest_tick_ref] do
      Process.cancel_timer(ref)
    end

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
          listening_port: listening_port,
          my_peer_id: my_peer_id,
          announce_tick: controller_announce_tick
        } = state
      ) do
    Logger.debug("Announcing")

    announce =
      Bex.Torrent.announce(
        announce_url,
        %{
          info_hash: info_hash,
          peer_id: my_peer_id,
          ip: "localhost",
          port: listening_port,
          uploaded: 0,
          downloaded: 0,
          left: length
        }
      )

    state =
      case announce do
        {:ok, %{peers: announce_peers}} ->
          announce_peers =
            announce_peers
            # rename `peer id` to `peer_id`
            |> Enum.map(fn %{"peer id": peer_id} = peer ->
              Map.put(peer, :peer_id, peer_id)
            end)
            # remove my peer id if it's there
            |> Enum.filter(fn %{peer_id: peer_id} ->
              peer_id != my_peer_id
            end)

          Map.put(state, :announce_peers, announce_peers)

        {:error, _error} = e ->
          Logger.warn(inspect(e))
          state
      end

    ref = schedule_announce(controller_announce_tick)

    state = Map.put(state, :announce_tick_ref, ref)

    {:noreply, state}
  end

  def handle_info(
        :update_interest_states,
        %{
          metainfo: %{decorated: %{have_pieces: indexes}},
          available_piece_sets: available_piece_sets,
          interest_tick: controller_interest_tick,
          peers: peers
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

    Enum.each(not_interested_peers, fn peer_id ->
      peer_pid = BiMap.get(peers, peer_id)
      PeerWorker.not_interested(peer_pid)
    end)

    Enum.each(interested_peers, fn peer_id ->
      peer_pid = BiMap.get(peers, peer_id)
      PeerWorker.interested(peer_pid)
    end)

    Logger.debug("#{Enum.count(not_interested_peers)} peers not of interest")
    Logger.debug("#{Enum.count(interested_peers)} peers of interest")

    ref = schedule_update_interest(controller_interest_tick)

    state = Map.put(state, :interest_tick_ref, ref)

    {:noreply, state}
  end

  def handle_info(
        :downloads,
        %{
          metainfo: %{decorated: %{have_pieces: pieces}},
          peers: peers,
          # active_downloads: active_downloads,
          downloads_tick: controller_downloads_tick,
          available_piece_sets: available_piece_sets
        } = state
      ) do
    cond do
      Enum.empty?(peers) ->
        Logger.debug("No available peers to download from")
        schedule_downloads(controller_downloads_tick)
        {:noreply, state}

      Enum.all?(pieces) ->
        Logger.debug("Download finished")
        {:noreply, state}

      true ->
        # n = max_downloads - Enum.count(active_downloads)

        # if n == 0 do
        #   Logger.debug("At max downloads, not adding more")
        # end

        # unhad_pieces = random_unhad_pieces(pieces, n)

        # random_peers_with_pieces =
        #   random_peers_with_pieces(unhad_pieces, available_piece_sets)
        #   |> Enum.filter(fn {_index, peer} ->
        #     !is_nil(peer)
        #   end)
        #   |> Enum.into(%{})

        # if Enum.empty?(random_peers_with_pieces) do
        #   Logger.debug("No peers with pieces")
        # end

        # these_actives =
        #   for {unhad_index, peer_id} <- random_peers_with_pieces do
        #     peer_pid = BiMap.get(peers, peer_id)
        #     :ok = PeerWorker.request_piece(peer_pid, unhad_index)
        #     {peer_id, unhad_index}
        #   end

        # state =
        #   Map.update!(state, :active_downloads, fn active_downloads ->
        #     these_actives ++ active_downloads
        #   end)

        # schedule_downloads(controller_downloads_tick)

        # {:noreply, state}

        with {:ok, unhad_index} <- random_unhad_piece(pieces),
             {:ok, peer_id_with_piece} <-
               random_peer_with_piece(unhad_index, available_piece_sets),
             peer_pid = BiMap.get(peers, peer_id_with_piece),
             :ok <- PeerWorker.request_piece(peer_pid, unhad_index) do
          Logger.debug("Asked #{inspect(peer_id_with_piece)} for #{unhad_index}")

          state =
            Map.update!(state, :active_downloads, fn active_downloads ->
              [{peer_id_with_piece, unhad_index} | active_downloads]
            end)

          ref = schedule_downloads(controller_downloads_tick)

          state = Map.put(state, :downloads_tick_ref, ref)

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

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{peers: peers} = state
      ) do
    Logger.debug("#{inspect({ref, pid})} went down for #{inspect(reason)}")

    peer_id = BiMap.get_key(peers, pid)

    Logger.debug("Removing peer (#{peer_id}, #{inspect(pid)})")

    state =
      state
      |> Map.update!(:peers, fn peers ->
        BiMap.delete_value(peers, pid)
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
          interest_tick: controller_interest_tick,
          announce_tick: controller_announce_tick,
          downloads_tick: controller_download_tick
        } = _state
      ) do
    announce_ref = schedule_announce(controller_announce_tick)
    update_interest_ref = schedule_update_interest(controller_interest_tick)
    downloads_ref = schedule_downloads(controller_download_tick)

    %{
      announce_tick_ref: announce_ref,
      interest_tick_ref: update_interest_ref,
      downloads_tick_ref: downloads_ref
    }
  end

  def schedule_update_interest(controller_interest_tick) do
    ref = Process.send_after(self(), :update_interest_states, controller_interest_tick)
    Logger.debug("Interest state update scheduled to occur in #{controller_interest_tick}ms")
    ref
  end

  def schedule_announce(controller_announce_tick) do
    ref = Process.send_after(self(), :announce, controller_announce_tick)
    Logger.debug("Announce scheduled to occur in #{controller_announce_tick}ms")
    ref
  end

  def schedule_downloads(controller_downloads_tick) do
    ref = Process.send_after(self(), :downloads, controller_downloads_tick)
    Logger.debug("Downloads scheduled to occur in #{controller_downloads_tick}ms")
    ref
  end

  # def random_unhad_pieces(pieces, n) when n >= 0 do
  #   pieces
  #   |> Stream.with_index()
  #   |> Stream.reject(fn {have?, _index} -> have? end)
  #   |> Stream.map(fn {_have?, index} -> index end)
  #   |> Enum.take(n)
  # end

  # def random_peers_with_pieces(indexes, peer_sets) do
  #   Enum.reduce(indexes, %{}, fn index, acc ->
  #     peer_set = Enum.at(peer_sets, index)

  #     if Enum.empty?(peer_set) do
  #       Map.put(acc, index, nil)
  #     else
  #       Map.put(acc, index, Enum.random(peer_set))
  #     end
  #   end)
  # end

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
