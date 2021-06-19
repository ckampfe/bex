defmodule Bex.PeerAcceptor do
  use GenServer
  require Logger

  alias Bex.Peer

  def start_link(
        %{metainfo: %{decorated: %{info_hash: info_hash}}, listening_port: port} = options
      ) do
    name = via_tuple(info_hash)
    Logger.debug("Starting #{inspect(name)} on port #{port}")
    GenServer.start_link(__MODULE__, options, name: name)
  end

  def init(args) do
    {:ok, args, {:continue, :listen}}
  end

  def handle_continue(
        :listen,
        %{listening_port: listening_port} = state
      ) do
    {:ok, listen_socket} = :gen_tcp.listen(listening_port, [:binary, active: false])

    Logger.debug("TCP socket listening on port #{listening_port}")
    state = Map.put(state, :listen_socket, listen_socket)
    {:noreply, state, {:continue, :accept}}
  end

  def handle_continue(
        :accept,
        %{
          listen_socket: listen_socket
        } = state
      ) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)

    Peer.initialize_peer(socket, state)

    {:noreply, state, {:continue, :accept}}
  end

  def via_tuple(name) do
    {:via, Registry, {Bex.Registry, {name, __MODULE__}}}
  end
end
