defmodule Bex.Encoder do
  # https://www.bittorrent.org/beps/bep_0003.html

  def encode(term) when is_map(term) do
    encoded_pairs =
      term
      |> Enum.into([])
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.flat_map(fn {k, v} -> [encode(k), encode(v)] end)
      |> Enum.join()

    "d#{encoded_pairs}e"
  end

  def encode(term) when is_list(term) do
    encoded_els =
      term
      |> Enum.map(fn el -> encode(el) end)
      |> Enum.join()

    "l#{encoded_els}e"
  end

  def encode(term) when is_integer(term) do
    "i#{term}e"
  end

  def encode(term) when is_binary(term) do
    len = :erlang.byte_size(term)
    "#{len}:#{term}"
  end
end
