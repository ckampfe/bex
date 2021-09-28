defmodule Bex.Metainfo do
  alias Bex.{Bencode, BitArray, Torrent}

  defstruct [:announce, :"created by", :"creation date", :encoding, :info, :decorated]

  @type t :: %__MODULE__{
          announce: String.t(),
          "created by": String.t(),
          "creation date": String.t(),
          encoding: String.t(),
          info: Bex.Metainfo.Info.t(),
          decorated: Bex.Metainfo.Decorated.t()
        }

  defmodule Info do
    defstruct [:length, :name, :"piece length", :pieces, :private]

    @type t :: %__MODULE__{}
  end

  defmodule Decorated do
    defstruct [:info_hash, :piece_hashes, :have_pieces]

    @type t :: %__MODULE__{
            info_hash: binary(),
            piece_hashes: list(binary()),
            have_pieces: Bex.BitArray.t()
          }
  end

  @spec from_string(String.t()) :: {:ok, t}
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

      bitfield =
        piece_hashes
        |> Enum.count()
        |> BitArray.new()

      decorated =
        %{}
        |> Map.put(:info_hash, info_hash)
        |> Map.put(:piece_hashes, piece_hashes)
        |> Map.put(:have_pieces, bitfield)
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
