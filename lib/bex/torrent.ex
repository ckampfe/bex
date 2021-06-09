defmodule Bex.Torrent do
  require Logger

  def add_torrent(path) do
    {:ok, metainfo} = load(path)
    Logger.debug("Loaded torrent from #{path}")

    # TODO these all become config vars
    options = %{
      "metainfo" => metainfo,
      port: 6882,
      peer_id: "BEXaaaaaaaaaaaaaaaaa",
      max_downloads: 10,
      peer_checkin_tick: :timer.seconds(5),
      peer_keepalive_tick: :timer.minutes(1),
      controller_announce_tick: :timer.minutes(1),
      controller_interest_tick: :timer.seconds(15)
    }

    {:ok, _} = Bex.AllSupervisor.start_child(options)
  end

  def load(path) do
    with {:ok, s} <- File.read(path),
         {"", metainfo} <- Bex.Bencode.decode(s) do
      info_hash =
        metainfo
        |> Map.fetch!("info")
        |> Bex.Bencode.encode()
        |> hash()

      piece_hashes =
        for <<piece_hash::bytes-size(20) <- Kernel.get_in(metainfo, ["info", "pieces"])>> do
          piece_hash
        end

      have_pieces = Enum.map(1..Enum.count(piece_hashes), fn _ -> false end)

      metainfo =
        metainfo
        |> Map.put("decorated", %{})
        |> Kernel.put_in(["decorated", "info_hash"], info_hash)
        |> Kernel.put_in(["decorated", "piece_hashes"], piece_hashes)
        |> Kernel.put_in(["decorated", "have_pieces"], have_pieces)

      {:ok, metainfo}
    end
  end

  def validate_existing_data(decorated_metainfo, data_path) do
    if File.exists?(data_path) do
      Logger.debug("#{data_path} exists, validating")

      {:ok, file} = File.open(data_path, [:read])

      updated =
        Kernel.update_in(decorated_metainfo, ["decorated", "have_pieces"], fn have_pieces ->
          hashes_and_haves =
            Enum.zip(
              Kernel.get_in(decorated_metainfo, ["decorated", "piece_hashes"]),
              have_pieces
            )

          piece_length = Kernel.get_in(decorated_metainfo, ["info", "piece length"])

          hashes_and_haves
          |> Enum.with_index()
          |> Enum.map(fn {{hash, _have}, index} ->
            hash_piece(file, index, piece_length) == hash
          end)
        end)

      File.close(file)

      updated
    else
      Logger.debug("#{data_path} does not exist, initializing")

      with {:ok, info} <- Map.fetch(decorated_metainfo, "info"),
           {:ok, length} <- Map.fetch!(info, "length"),
           {:ok, file} <- File.open(data_path, [:write]) do
        :file.allocate(file, 0, length)
      end
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
         {"", decoded} = Bex.Bencode.decode(body) do
      decoded
    end
  end

  def write_piece(file, index, piece_length, piece) do
    location = calculate_piece_location(index, piece_length)
    :file.pwrite(file, location, piece)
  end

  def read_piece(file, index, piece_length) do
    location = calculate_piece_location(index, piece_length)

    :file.pread(file, location, piece_length)
  end

  def hash_piece(file, index, piece_length) do
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

  def bitfield_to_indexes(bitfield) when is_binary(bitfield) do
    for <<byte <- bitfield>> do
      for i <- 0..7 do
        if Bitwise.bsr(Bitwise.band(byte, Bitwise.bsl(1, i)), i) == 1 do
          true
        else
          false
        end
      end
    end
    |> Enum.flat_map(fn l -> l end)
  end

  # All later integers sent in the protocol are encoded as four bytes big-endian.
  def encode_number(number) do
    <<number::32-integer-big>>
  end
end
