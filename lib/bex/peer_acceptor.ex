defmodule Bex.PeerAcceptor do
  @moduledoc false

  use GenServer
  require Logger

  alias Bex.{BitArray, Peer, TorrentControllerWorker, Metainfo}

  def start_link(
        %{
          metainfo: %Metainfo{
            decorated: %Metainfo.Decorated{
              info_hash: info_hash,
              have_pieces: %BitArray{} = _have_pieces
            }
          },
          listening_port: port
        } = options
      ) do
    name = via_tuple(info_hash)
    Logger.debug("Starting #{inspect(name)} on port #{port}")
    GenServer.start_link(__MODULE__, options, name: name)
  end

  def shutdown(info_hash) do
    name = via_tuple(info_hash)
    GenServer.call(name, :shutdown)
  end

  def init(args) do
    {:ok, args, {:continue, :listen}}
  end

  def handle_continue(
        :listen,
        %{
          metainfo: %Metainfo{
            decorated: %Metainfo.Decorated{
              info_hash: info_hash,
              have_pieces: %BitArray{} = _have_pieces
            }
          },
          listening_port: listening_port
        } = state
      ) do
    {:ok, listen_socket, actual_listening_port} = listen_on_port(listening_port)

    Logger.debug("TCP socket listening on port #{actual_listening_port}")

    TorrentControllerWorker.actual_listening_port(info_hash, actual_listening_port)

    Logger.debug(
      "Updated TorrentControllerWorker with actual listening port #{actual_listening_port}"
    )

    state =
      state
      |> Map.put(:listen_socket, listen_socket)
      |> Map.put(:actual_listening_port, actual_listening_port)

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

  def handle_call(:shutdown, _from, state) do
    {:stop, :normal, state}
  end

  def listen_on_port(port) do
    do_listen_on_port(port)
  end

  defp do_listen_on_port(port) do
    case :gen_tcp.listen(port, [:binary, active: false]) do
      {:ok, listen_socket} ->
        {:ok, listen_socket, port}

      e ->
        Logger.warn("#{inspect(e)}: unable to listen on port #{port}, trying #{port + 1}")
        do_listen_on_port(port + 1)
    end
  end

  def via_tuple(name) do
    {:via, Registry, {Bex.Registry, {name, __MODULE__}}}
  end
end
