defmodule Bex.PeerAcceptor do
  use GenServer
  require Logger

  alias Bex.PeerSupervisor

  def start_link(
        %{"metainfo" => %{"decorated" => %{"info_hash" => info_hash}}, port: port} = options
      ) do
    name = via_tuple(info_hash)
    Logger.debug("Starting #{inspect(name)} on port #{port}")
    GenServer.start_link(__MODULE__, options, name: name)
  end

  def init(args) do
    {:ok, args, {:continue, :listen}}
  end

  def handle_continue(:listen, %{port: port} = state) do
    {:ok, listen_socket} = :gen_tcp.listen(port, [:binary, active: false])
    Logger.debug("TCP socket listening on port #{port}")
    state = Map.put(state, :listen_socket, listen_socket)
    {:noreply, state, {:continue, :accept}}
  end

  def handle_continue(
        :accept,
        %{
          "metainfo" => %{"decorated" => %{"info_hash" => info_hash}},
          listen_socket: listen_socket
        } = state
      ) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)

    Logger.debug("TCP socket #{inspect(socket)} accepted, starting child process to handle")

    peer_supervisor_name = {:via, Registry, {Bex.Registry, {info_hash, Bex.PeerSupervisor}}}

    {:ok, peer_pid} = PeerSupervisor.start_child(peer_supervisor_name, state, socket)

    :gen_tcp.controlling_process(socket, peer_pid)

    Logger.debug(
      "Started Bex.PeerWorker #{inspect(peer_pid)} to handle socket #{inspect(socket)}"
    )

    Bex.TorrentControllerWorker.add_peer(info_hash, peer_pid)

    {:noreply, state, {:continue, :accept}}
  end

  def via_tuple(name) do
    {:via, Registry, {Bex.Registry, {name, __MODULE__}}}
  end
end
