defmodule Bex.TorrentControllerWorker do
  @moduledoc false

  use GenServer

  require Logger

  alias Bex.{PeerWorker, Peer}

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
          metainfo: %Bex.Metainfo{
            decorated: %Bex.Metainfo.Decorated{have_pieces: indexes}
            # info: %Bex.Metainfo.Info{}
          },
          download_path: download_path,
          listening_port: _listening_port,
          my_peer_id: _my_peer_id,
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

    {haves, have_nots} = Enum.split_with(indexes, fn have? -> have? end)
    haves_count = Enum.count(haves)
    have_nots_count = Enum.count(have_nots)
    total = haves_count + have_nots_count

    state =
      if have_nots_count == 0 do
        Logger.debug("#{download_path}: Have all pieces. Seeding.")
        announce(state, "completed")
      else
        Logger.info(
          "#{download_path}: Have #{haves_count} out of #{total} pieces. #{have_nots_count} pieces remaining."
        )

        announce(state, "started")
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
        _from,
        %{
          metainfo:
            %Bex.Metainfo{
              decorated: %Bex.Metainfo.Decorated{have_pieces: indexes} = decorated
            } = metainfo,
          active_downloads: active_downloads
        } = state
      ) do
    # update haves
    indexes = List.replace_at(indexes, index, true)

    active_downloads =
      active_downloads
      |> Enum.reject(fn {active_peer_id, i} ->
        active_peer_id == peer_id && i == index
      end)

    state =
      %{state | metainfo: %{metainfo | decorated: %{decorated | have_pieces: indexes}}}
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
            announce: _announce_url,
            decorated: %{info_hash: _info_hash},
            info: %{length: _length}
          },
          listening_port: _listening_port,
          my_peer_id: _my_peer_id,
          announce_tick: controller_announce_tick
        } = state
      ) do
    state = announce(state)

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
        announce(state, "completed")
        {:noreply, state}

      true ->
        case random_unhad_available_peer_pieces(pieces, available_piece_sets, 4) do
          # [{peer_id, index}]
          {:ok, peer_id_pieces} ->
            peer_id_pieces
            |> Enum.each(fn {peer_id, index} ->
              peer_pid = BiMap.get(peers, peer_id)

              Task.start(fn ->
                PeerWorker.request_piece(peer_pid, index)
                Logger.debug("Asked #{inspect(peer_id)} for #{index}")
              end)
            end)

            state =
              Map.update!(state, :active_downloads, fn active_downloads ->
                peer_id_pieces ++ active_downloads
              end)

            ref = schedule_downloads(controller_downloads_tick)

            state = Map.put(state, :downloads_tick_ref, ref)

            {:noreply, state}

          :have_all_pieces ->
            Logger.debug("Download complete, not scheduling further download")
            {:noreply, state}

          :no_available_peers ->
            Logger.debug("No peers available, not downloading anything.")
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

  def announce(
        %{
          my_peer_id: my_peer_id,
          listening_port: listening_port,
          metainfo: %Bex.Metainfo{
            announce: announce_url,
            decorated: %Bex.Metainfo.Decorated{info_hash: info_hash, have_pieces: _indexes},
            info: %Bex.Metainfo.Info{length: length}
          }
        } = state,
        event \\ nil
      ) do
    Logger.debug("Announcing")

    base_announce_params = %{
      info_hash: info_hash,
      peer_id: my_peer_id,
      ip: "localhost",
      port: listening_port,
      uploaded: 0,
      downloaded: 0,
      left: length
    }

    announce_params =
      if event do
        Map.put(base_announce_params, :event, event)
      else
        base_announce_params
      end

    announce =
      Bex.Torrent.announce(
        announce_url,
        announce_params
      )

    state =
      case announce do
        {:ok, %{peers: announce_peers}} ->
          announce_peers =
            announce_peers
            |> Enum.map(&rename_peer_id_key/1)
            |> Enum.filter(&not_me(&1, my_peer_id))

          state = Map.put(state, :announce_peers, announce_peers)

          for peer <- state[:announce_peers] do
            Task.start(fn ->
              Peer.connect_and_initialize(peer, state)
            end)
          end

          state

        {:error, _error} = e ->
          Logger.warn(
            "#{Base.encode16(info_hash)} Could not announce #{announce_url}: #{inspect(e)}"
          )

          state
      end

    state
  end

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

  def random_unhad_available_peer_pieces(pieces, peer_sets, n) when n > 0 do
    cond do
      Enum.all?(pieces, fn have? -> have? end) ->
        :have_all_pieces

      Enum.all?(peer_sets, fn peer_set -> Enum.empty?(peer_set) end) ->
        :no_available_peers

      true ->
        unhad_available_pieces =
          pieces
          |> Enum.zip(peer_sets)
          |> Enum.with_index(fn {have?, peer_set}, index ->
            {have?, peer_set, index}
          end)
          |> Enum.reject(fn {have?, peer_set, _index} ->
            have? || Enum.empty?(peer_set)
          end)
          |> Enum.shuffle()
          |> Enum.take(n)
          |> Enum.map(fn {_have?, peer_set, index} ->
            peer_id = Enum.random(peer_set)
            {peer_id, index}
          end)

        {:ok, unhad_available_pieces}
    end
  end

  def rename_peer_id_key(%{"peer id": peer_id} = peer) do
    peer
    |> Map.put(:peer_id, peer_id)
    |> Map.delete(:"peer id")
  end

  def not_me(%{peer_id: peer_id} = _peer, my_peer_id) do
    peer_id != my_peer_id
  end
end
