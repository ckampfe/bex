defmodule Bex.PeerSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(%{metainfo: %{decorated: %{info_hash: info_hash}}} = options) do
    name = via_tuple(info_hash)
    Logger.debug("Starting #{inspect(name)}")
    DynamicSupervisor.start_link(__MODULE__, options, name: name)
  end

  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(name_or_pid, options, socket) do
    options = Map.put(options, :socket, socket)
    spec = {Bex.PeerWorker, options}
    DynamicSupervisor.start_child(name_or_pid, spec)
  end

  def via_tuple(info_hash) do
    {:via, Registry, {Bex.Registry, {info_hash, __MODULE__}}}
  end
end
