defmodule Bex.Bencode do
  # https://www.bittorrent.org/beps/bep_0003.html
  #
  # Strings are length-prefixed base ten followed by a colon and the string. For example 4:spam corresponds to 'spam'.
  # Integers are represented by an 'i' followed by the number in base 10 followed by an 'e'. For example i3e corresponds to 3 and i-3e corresponds to -3. Integers have no size limitation. i-0e is invalid. All encodings with a leading zero, such as i03e, are invalid, other than i0e, which of course corresponds to 0.
  # Lists are encoded as an 'l' followed by their elements (also bencoded) followed by an 'e'. For example l4:spam4:eggse corresponds to ['spam', 'eggs'].
  # Dictionaries are encoded as a 'd' followed by a list of alternating keys and their corresponding values followed by an 'e'. For example, d3:cow3:moo4:spam4:eggse corresponds to {'cow': 'moo', 'spam': 'eggs'} and d4:spaml1:a1:bee corresponds to {'spam': ['a', 'b']}. Keys must be strings and appear in sorted order (sorted as raw strings, not alphanumerics).
  def decode(<<"d", s::binary()>>) do
    decode_dict(s, %{})
  end

  def decode(<<"l", s::binary()>>) do
    decode_list(s, [])
  end

  def decode(<<"i", s::binary()>>) do
    {int, <<"e", s::binary()>>} = Integer.parse(s)
    {s, int}
  end

  def decode(<<"e", s::binary()>>) do
    {s, :done}
  end

  def decode(s) do
    {length, s} = Integer.parse(s)
    <<":", string::binary-size(length), s::binary()>> = s
    {s, string}
  end

  defp decode_dict(s, dict) do
    {s, list} = decode_list(s, [])

    dict =
      list
      |> Enum.chunk_every(2)
      |> Enum.map(fn [k, v] -> {k, v} end)
      |> Enum.into(dict)

    {s, dict}
  end

  defp decode_list(<<"e", s::binary()>>, els) do
    {s, els |> Enum.reverse()}
  end

  defp decode_list(s, els) do
    {s, el} = decode(s)
    decode_list(s, [el | els])
  end

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
