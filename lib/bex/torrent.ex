defmodule Bex.Torrent do
  require Logger

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

  def add_torrent(
        torrent_file_path,
        download_path,
        options \\ [my_peer_id: generate_peer_id()]
      ) do
    {:ok, metainfo} = load(torrent_file_path)
    Logger.debug("Loaded torrent from #{torrent_file_path}")
    metainfo = validate_existing_data(metainfo, download_path)
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

    # global_defaults <- application global config <- passed_in per torrent
    options =
      default_options()
      |> Keyword.merge(application_global_config)
      |> Keyword.merge(options)
      |> Enum.into(%{})
      |> Map.merge(%{metainfo: metainfo, download_path: download_path})

    {:ok, _} = Bex.AllSupervisor.start_child(options)
  end

  def load(path) do
    with {:ok, s} <- File.read(path),
         {"", %{info: %{pieces: pieces} = info} = metainfo} <-
           Bex.Bencode.decode(s, atom_keys: true) do
      info_hash =
        info
        |> Bex.Bencode.encode()
        |> hash()

      piece_hashes =
        for <<piece_hash::bytes-size(20) <- pieces>> do
          piece_hash
        end

      have_pieces = Enum.map(1..Enum.count(piece_hashes), fn _ -> false end)

      metainfo =
        metainfo
        |> Map.put(:decorated, %{})
        |> Kernel.put_in([:decorated, :info_hash], info_hash)
        |> Kernel.put_in([:decorated, :piece_hashes], piece_hashes)
        |> Kernel.put_in([:decorated, :have_pieces], have_pieces)

      {:ok, metainfo}
    end
  end

  def validate_existing_data(decorated_metainfo, download_path) do
    if File.exists?(download_path) do
      Logger.debug("#{download_path} exists, validating")

      {:ok, file} = File.open(download_path, [:read])

      updated =
        Kernel.update_in(decorated_metainfo, [:decorated, :have_pieces], fn have_pieces ->
          hashes_and_haves =
            Enum.zip(
              Kernel.get_in(decorated_metainfo, [:decorated, :piece_hashes]),
              have_pieces
            )

          piece_length = Kernel.get_in(decorated_metainfo, [:info, :"piece length"])

          hashes_and_haves
          |> Enum.with_index()
          |> Enum.map(fn {{hash, _have}, index} ->
            hash_piece_from_file(file, index, piece_length) == hash
          end)
        end)

      File.close(file)

      updated
    else
      Logger.debug("#{download_path} does not exist, initializing")

      with {:ok, info} <- Map.fetch(decorated_metainfo, :info),
           {:ok, length} <- Map.fetch(info, :length),
           {:ok, file} <- :file.open(download_path, [:write]),
           :ok <- :file.allocate(file, 0, length),
           :ok <- File.close(file) do
        Logger.debug("#{download_path} initialized")
      else
        e ->
          Logger.error(inspect(e))
      end

      decorated_metainfo
    end
  end

  def announce(
        tracker_url,
        %{
          info_hash: _info_hash,
          peer_id: _peer_id,
          ip: _ip,
          port: _port,
          uploaded: _uploaded,
          downloaded: _downloaded,
          left: _left
        } = query
      ) do
    query = URI.encode_query(query)

    with {:ok, response} <-
           HTTPoison.get(
             tracker_url <> "?" <> query,
             []
           ),
         body = response.body,
         {"", decoded} = Bex.Bencode.decode(body, atom_keys: true) do
      {:ok, decoded}
    end
  end

  def write_piece(file, index, piece_length, piece) do
    location = calculate_piece_location(index, piece_length)
    :file.pwrite(file, location, piece)
  end

  def write_chunk(file, index, chunk_offset, piece_length, chunk) do
    location = calculate_piece_location(index, piece_length) + chunk_offset
    out = :file.pwrite(file, location, chunk)
    :file.position(file, :bof)
    out
  end

  def read_piece(file, index, piece_length) do
    location = calculate_piece_location(index, piece_length)

    :file.pread(file, location, piece_length)
  end

  def verify_piece(piece, expected_hash) do
    hash(piece) == expected_hash
  end

  def verify_piece_from_file(file, index, piece_length, expected_hash) do
    hash_piece_from_file(file, index, piece_length) == expected_hash
  end

  def hash_piece_from_file(file, index, piece_length) do
    case read_piece(file, index, piece_length) do
      {:ok, bytes} ->
        hash(bytes)

      {:error, _error} = e ->
        e
    end
  end

  def hash(bytes) do
    :crypto.hash(:sha, bytes)
  end

  def calculate_piece_location(index, piece_length) when index >= 0 do
    index * piece_length
  end

  def have(indexes, i) when is_list(indexes) do
    List.replace_at(indexes, i, true)
  end

  def compute_chunks(total_length, nominal_piece_length, index, nominal_chunk_length) do
    normal_chunks =
      Stream.iterate(%{offset: 0, length: nominal_chunk_length}, fn %{
                                                                      offset: offset,
                                                                      length: chunk_length
                                                                    } ->
        %{offset: offset + chunk_length, length: chunk_length}
      end)

    piece_location = calculate_piece_location(index, nominal_piece_length)

    actual_piece_length =
      if total_length - piece_location >= nominal_piece_length do
        nominal_piece_length
      else
        total_length - piece_location
      end

    number_of_normal_chunks = :erlang.div(actual_piece_length, nominal_chunk_length)

    normal_chunks = Enum.take(normal_chunks, number_of_normal_chunks)

    if Enum.empty?(normal_chunks) do
      [%{offset: 0, length: total_length - piece_location}]
    else
      %{offset: last_chunk_offset, length: last_chunk_length} = List.last(normal_chunks)
      remaining = actual_piece_length - (last_chunk_offset + last_chunk_length)

      if remaining > 0 do
        [
          %{
            offset: last_chunk_offset + last_chunk_length,
            length: actual_piece_length - (last_chunk_offset + last_chunk_length)
          }
          | normal_chunks
        ]
        |> Enum.reverse()
      else
        normal_chunks
      end
    end
  end

  def indexes_to_bitfield(indexes) do
    indexes
    |> Enum.chunk_every(8)
    |> Enum.map(fn indexes_chunk ->
      indexes_chunk
      |> Enum.with_index()
      |> Enum.reduce(0, fn {index, i}, acc ->
        if index do
          Bitwise.bor(acc, Bitwise.bsl(1, i))
        else
          acc
        end
      end)
    end)
    |> :binary.list_to_bin()
  end

  def bitfield_to_indexes(bitfield, length, piece_length) when is_binary(bitfield) do
    computed_number_of_pieces = (length / piece_length) |> Kernel.ceil()

    for <<a::1, b::1, c::1, d::1, e::1, f::1, g::1, h::1 <- bitfield>> do
      [a, b, c, d, e, f, g, h]
      |> Enum.reverse()
      |> Enum.map(fn
        1 -> true
        0 -> false
      end)
    end
    |> Enum.flat_map(fn l -> l end)
    |> Enum.take(computed_number_of_pieces)
  end

  # All later integers sent in the protocol are encoded as four bytes big-endian.
  def encode_number(number) do
    <<number::32-integer-big>>
  end

  def generate_peer_id() do
    header = "-BEX001-"
    header_length = String.length(header)
    random_bytes = :rand.bytes(100) |> Base.encode64()
    bytes_to_take = 20 - header_length - 1
    header <> String.slice(random_bytes, 0..bytes_to_take)
  end
end
