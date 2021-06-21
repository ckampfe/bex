defmodule Bex do
  require Logger
  alias Bex.{Torrent, PeerAcceptor, TorrentControllerWorker}

  def add_torrent(
        torrent_file_path,
        download_path,
        options \\ [my_peer_id: Torrent.generate_peer_id()]
      ) do
    {:ok, metainfo} = Torrent.load(torrent_file_path)
    Logger.debug("Loaded torrent from #{torrent_file_path}")
    metainfo = Torrent.validate_existing_data(metainfo, download_path)
    Logger.debug("Validated #{torrent_file_path} #{download_path}")
    have_pieces = Kernel.get_in(metainfo, [:decorated, :have_pieces])
    {haves, have_nots} = Enum.split_with(have_pieces, fn have? -> have? end)
    haves_count = Enum.count(haves)
    have_nots_count = Enum.count(have_nots)
    total = haves_count + have_nots_count

    if have_nots_count == 0 do
      Logger.info(
        "#{download_path}: Have #{haves_count} out of #{total} pieces. #{have_nots_count} pieces remaining."
      )
    else
      Logger.debug("#{download_path}: Have all pieces. Seeding.")
    end

    application_global_config = Application.get_all_env(:bex)

    # default_options() <- application global config <- passed_in per torrent
    options =
      default_options()
      |> Keyword.merge(application_global_config)
      |> Keyword.merge(options)
      |> Enum.into(%{})
      |> Map.merge(%{metainfo: metainfo, download_path: download_path})

    {:ok, _} = Bex.AllSupervisor.start_child(options)

    %{metainfo: %{decorated: %{info_hash: info_hash}}} = options

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

  def delete(_info_hash) do
    # shutdown TorrentWorkerController and peers
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
      downloads_tick: :timer.seconds(5)
    ]
  end
end
