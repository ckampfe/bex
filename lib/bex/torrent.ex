defmodule Bex.Torrent do
  @moduledoc false

  alias Bex.{BitArray, Metainfo, Piece, Chunk}
  require Logger

  def load(path) do
    {:ok, s} = File.read(path)
    Metainfo.from_string(s)
  end

  def validate_existing_data(
        %Metainfo{
          decorated: %Metainfo.Decorated{
            have_pieces: %BitArray{} = have_pieces,
            piece_hashes: piece_hashes
          },
          info: %Bex.Metainfo.Info{"piece length": piece_length, length: length}
        } = metainfo,
        download_path
      ) do
    if File.exists?(download_path) do
      Logger.debug("#{download_path} exists, validating")

      {:ok, file} = File.open(download_path, [:read])

      have_pieces =
        piece_hashes
        |> Enum.with_index()
        |> Enum.reduce(have_pieces, fn {expected_hash, index}, bitfield ->
          piece = %Piece{index: index, length: piece_length}

          if Bex.Piece.verify(piece, file, expected_hash) do
            BitArray.set(bitfield, index)
          else
            bitfield
          end
        end)

      metainfo = Kernel.put_in(metainfo, [:decorated, :have_pieces], have_pieces)

      File.close(file)

      metainfo
    else
      Logger.debug("#{download_path} does not exist, initializing")

      with {:ok, file} <- :file.open(download_path, [:write]),
           :ok <- :file.allocate(file, 0, length),
           :ok <- File.close(file) do
        Logger.debug("#{download_path} initialized")
      else
        e ->
          Logger.error(inspect(e))
      end

      metainfo
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

  def hash(bytes) do
    :crypto.hash(:sha, bytes)
  end

  def compute_chunks(total_length, nominal_piece_length, index, nominal_chunk_length) do
    normal_chunks =
      Stream.iterate(%Chunk{offset_within_piece: 0, length: nominal_chunk_length}, fn %Chunk{
                                                                                        offset_within_piece:
                                                                                          offset,
                                                                                        length:
                                                                                          chunk_length
                                                                                      } ->
        %Chunk{offset_within_piece: offset + chunk_length, length: chunk_length}
      end)

    piece = %Bex.Piece{index: index, length: nominal_piece_length}
    piece_location = Bex.Piece.byte_location(piece)

    actual_piece_length =
      if total_length - piece_location >= nominal_piece_length do
        nominal_piece_length
      else
        total_length - piece_location
      end

    number_of_normal_chunks = :erlang.div(actual_piece_length, nominal_chunk_length)

    normal_chunks = Enum.take(normal_chunks, number_of_normal_chunks)

    if Enum.empty?(normal_chunks) do
      [%Chunk{offset_within_piece: 0, length: total_length - piece_location}]
    else
      %Chunk{offset_within_piece: last_chunk_offset, length: last_chunk_length} =
        List.last(normal_chunks)

      remaining = actual_piece_length - (last_chunk_offset + last_chunk_length)

      if remaining > 0 do
        [
          %Chunk{
            offset_within_piece: last_chunk_offset + last_chunk_length,
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
