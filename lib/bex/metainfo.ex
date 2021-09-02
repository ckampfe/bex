defmodule Bex.Metainfo do
  alias Bex.{Bencode, Torrent}

  defstruct [:announce, :"created by", :"creation date", :encoding, :info, :decorated]

  defmodule Info do
    defstruct [:length, :name, :"piece length", :pieces, :private]
  end

  defmodule Decorated do
    defstruct [:info_hash, :piece_hashes, :have_pieces]
  end

  def from_string(s) do
    with {"", %{info: %{pieces: pieces} = info} = raw_metainfo} <-
           Bencode.decode(s, atom_keys: true) do
      info = Kernel.struct!(Info, info)

      info_hash =
        info
        |> Map.from_struct()
        |> Bencode.encode()
        |> Torrent.hash()

      piece_hashes =
        for <<piece_hash::bytes-size(20) <- pieces>> do
          piece_hash
        end

      have_pieces = Enum.map(1..Enum.count(piece_hashes), fn _ -> false end)

      decorated =
        %{}
        |> Map.put(:info_hash, info_hash)
        |> Map.put(:piece_hashes, piece_hashes)
        |> Map.put(:have_pieces, have_pieces)
        |> then(fn decorated ->
          Kernel.struct(Decorated, decorated)
        end)

      metainfo =
        __MODULE__
        |> Kernel.struct(raw_metainfo)
        |> Map.put(:info, info)
        |> Map.put(:decorated, decorated)

      {:ok, metainfo}
    end
  end
end
