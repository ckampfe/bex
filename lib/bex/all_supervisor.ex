defmodule Bex.AllSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(options) do
    spec = {Bex.TorrentSupervisor, options}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def children() do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
