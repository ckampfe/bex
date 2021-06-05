defmodule Bex.TorrentControllerWorker do
  use GenServer

  require Logger

  alias Bex.PeerSupervisor

  def start_link(%{"metainfo" => %{"decorated" => %{"info_hash" => info_hash}}} = options) do
    name = {:via, Registry, {Bex.Registry, {info_hash, __MODULE__}}}
    Logger.debug("Starting #{inspect(name)}")
    GenServer.start_link(__MODULE__, options, name: name)
  end

  def init(options) do
    options = Map.put(options, :peers, %{})
    {:ok, options, {:continue, :set_up_listen_socket}}
  end

  def handle_continue(:set_up_listen_socket, %{port: port} = state) do
    {:ok, listen_socket} = :gen_tcp.listen(port, [:binary, active: false])
    Logger.debug("TCP socket listening on port #{port}")
    state = Map.put(state, :listen_socket, listen_socket)
    {:noreply, state, {:continue, :announce}}
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

    {:noreply, state, {:continue, :accept_loop}}
  end

  def handle_continue(
        :accept_loop,
        %{
          "metainfo" => %{"decorated" => %{"info_hash" => info_hash}},
          listen_socket: listen_socket
        } = state
      ) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)

    Logger.debug("TCP socket #{inspect(socket)} accepted, starting child process to handle")

    peer_supervisor_name = {:via, Registry, {Bex.Registry, {info_hash, Bex.PeerSupervisor}}}

    {:ok, child_pid} = PeerSupervisor.start_child(peer_supervisor_name, state, socket)

    ref = Process.monitor(child_pid)

    :gen_tcp.controlling_process(socket, child_pid)

    Logger.debug(
      "Started Bex.PeerWorker #{inspect(child_pid)} to handle socket #{inspect(socket)}"
    )

    state =
      Map.update!(state, :peers, fn peers ->
        Map.put(peers, {ref, child_pid}, nil)
      end)

    Logger.debug("Peers: #{inspect(Map.fetch!(state, :peers))}")

    {:noreply, state, {:continue, :accept_loop}}
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
        event: "start"
      }
    )

    {:noreply, state, {:continue, :accept_loop}}
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
end
