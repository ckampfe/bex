defmodule Bex.TorrentControllerWorker do
  use GenServer

  require Logger

  def start_link(%{"metainfo" => %{"decorated" => %{"info_hash" => info_hash}}} = options) do
    name = via_tuple(info_hash)
    Logger.debug("Starting #{inspect(name)}")
    GenServer.start_link(__MODULE__, options, name: name)
  end

  def add_peer(info_hash, peer) do
    name = via_tuple(info_hash)
    GenServer.call(name, {:add_peer, peer})
  end

  def init(options) do
    state = Map.put(options, :peers, %{})
    {:ok, state, {:continue, :announce}}
  end

  def handle_continue(
        :announce,
        %{
          "metainfo" => %{
            "announce" => announce_url,
            "decorated" => %{"info_hash" => info_hash},
            "info" => %{"length" => length}
          },
          port: port
        } = state
      ) do
    schedule_next_announce(state)

    Logger.debug("Announcing")

    Bex.Torrent.announce(
      announce_url,
      %{
        info_hash: info_hash,
        peer_id: "BEXaaaaaaaaaaaaaaaaa",
        ip: "localhost",
        port: port,
        uploaded: 0,
        downloaded: 0,
        left: length,
        event: "started"
      }
    )

    {:noreply, state}
  end

  def handle_call(
        {:add_peer, peer_pid},
        _from,
        state
      ) do
    peer_ref = Process.monitor(peer_pid)

    state =
      Map.update!(state, :peers, fn peers ->
        Map.put(peers, {peer_ref, peer_pid}, nil)
      end)

    {:reply, :ok, state}
  end

  def handle_info(
        :announce,
        %{
          "metainfo" => %{
            "announce" => announce_url,
            "decorated" => %{"info_hash" => info_hash},
            "info" => %{"length" => length}
          },
          port: port,
          peer_id: peer_id
        } = state
      ) do
    schedule_next_announce(state)

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

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, object, reason}, state) do
    Logger.debug("#{inspect({ref, object})} went down for #{inspect(reason)}")

    state =
      Map.update!(state, :peers, fn peers ->
        Map.delete(peers, {ref, object})
      end)

    {:noreply, state}
  end

  def schedule_next_announce(_state) do
    announce_time = :timer.seconds(60)
    Process.send_after(self(), :announce, announce_time)
    Logger.debug("Announce scheduled to occur in #{announce_time}")
  end

  def via_tuple(name) do
    {:via, Registry, {Bex.Registry, {name, __MODULE__}}}
  end
end
