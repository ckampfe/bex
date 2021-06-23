defmodule Bex.TorrentSupervisor do
  use Supervisor
  require Logger

  def start_link(%{metainfo: %{decorated: %{info_hash: info_hash}}} = options) do
    name = via_tuple(info_hash)
    Logger.debug("Starting #{inspect(name)}")
    Supervisor.start_link(__MODULE__, options, name: name)
  end

  @impl true
  def init(options) do
    children = [
      {Bex.PeerSupervisor, options},
      {Bex.PeerAcceptor, options},
      {Bex.TorrentControllerWorker, options}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def shutdown(info_hash) do
    name = via_tuple(info_hash)
    Supervisor.stop(name)
  end

  def via_tuple(info_hash) do
    {:via, Registry, {Bex.Registry, {info_hash, __MODULE__}}}
  end
end
