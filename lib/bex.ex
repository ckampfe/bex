defmodule Bex do
  require Logger

  alias Bex.{
    Torrent,
    PeerAcceptor,
    TorrentControllerWorker,
    TorrentSupervisor,
    Metainfo
  }

  def add_torrent(
        torrent_file_path,
        download_path,
        options \\ [my_peer_id: Torrent.generate_peer_id()]
      ) do
    {:ok, metainfo} = Torrent.load(torrent_file_path)
    Logger.debug("Loaded torrent from #{torrent_file_path}")

    application_global_config = Application.get_all_env(:bex)

    # default_options() <- application global config <- passed_in per torrent
    torrent_options =
      default_options()
      |> Keyword.merge(application_global_config)
      |> Keyword.merge(options)
      |> Enum.into(%{})
      |> Map.merge(%{
        metainfo: metainfo,
        download_path: download_path,
        torrent_file_path: torrent_file_path
      })

    %{
      metainfo: %Metainfo{
        decorated: %Metainfo.Decorated{
          info_hash: info_hash,
          have_pieces: %BitArray{} = _have_pieces
        }
      }
    } = torrent_options

    {:ok, _} = Bex.AllSupervisor.start_child(torrent_options)

    info_hash_as_hex = Base.encode16(info_hash)

    {:ok, info_hash, info_hash_as_hex}
  end

  def resume(_info_hash) do
    # allow TorrentWorkerController to begin adding peers, downloads, uploads
  end

  def pause(info_hash) do
    # keep TorrentWorkerController and peers running but prevent uploads and downloads
    # shutdown PeerAcceptor
    PeerAcceptor.shutdown(info_hash)
    # shutdown existing peers
    # keep TorrentWorkerController alive, but pause timers
    TorrentControllerWorker.pause(info_hash)
  end

  def delete(info_hash) do
    # shutdown TorrentWorkerController and peers
    pause(info_hash)
    TorrentSupervisor.shutdown(info_hash)
  end

  def torrents() do
    Bex.AllSupervisor.children()
    |> Enum.flat_map(fn {_, pid, _, _} -> Registry.keys(Bex.Registry, pid) end)
    |> Enum.map(fn {info_hash, _module} ->
      info_hash_as_hex = Base.encode16(info_hash)
      {info_hash_as_hex, info_hash}
    end)
  end

  def default_options() do
    [
      listening_port: 6881,
      global_max_connections: 500,
      global_max_upload_slots: 20,
      per_torrent_max_connections: 40,
      per_torrent_max_upload_slots: 4,
      chunk_size_bytes: :math.pow(2, 14) |> Kernel.trunc(),
      peer_checkin_tick: :timer.seconds(10),
      peer_keepalive_tick: :timer.minutes(1),
      announce_tick: :timer.minutes(1),
      interest_tick: :timer.seconds(15),
      downloads_tick: :timer.seconds(1)
    ]
  end
end
