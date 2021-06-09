defmodule BencodeTest do
  use ExUnit.Case

  alias Bex.Bencode

  test "decode/1 binary" do
    assert Bencode.decode("5:hello") == {"", "hello"}
  end

  test "decode/1 integer" do
    assert Bencode.decode("i123e") == {"", 123}
    assert Bencode.decode("i-123e") == {"", -123}
    assert Bencode.decode("i0e") == {"", 0}
    assert Bencode.decode("i0e") == {"", -0}
  end

  test "decode/1 list" do
    assert Bencode.decode("le") == {"", []}
    assert Bencode.decode("li1ei2ei3ee") == {"", [1, 2, 3]}
    assert Bencode.decode("li1e1:ai2e1:bi3ee") == {"", [1, "a", 2, "b", 3]}
    assert Bencode.decode("li1el1:a1:b1:cee") == {"", [1, ["a", "b", "c"]]}
  end

  test "decode/1 dict" do
    assert Bencode.decode("de") == {"", %{}}
    assert Bencode.decode("d1:ai1ee") == {"", %{"a" => 1}}
    assert Bencode.decode("d1:ali1ei2ei3eee") == {"", %{"a" => [1, 2, 3]}}
    # from https://www.bittorrent.org/beps/bep_0003.html:
    # Keys must be strings and appear in sorted order (sorted as raw strings, not alphanumerics).
    assert Bencode.decode("d1:0i99e1:ai99e1:bi99e1:zi99ee") ==
             {"", %{"z" => 99, "a" => 99, "b" => 99, "0" => 99}}

    assert Bencode.decode("d1:0i99e1:ai99e1:bi99e1:zi99ee", atom_keys: false) ==
             {"", %{"z" => 99, "a" => 99, "b" => 99, "0" => 99}}

    assert Bencode.decode("d1:0i99e1:ai99e1:bi99e1:zi99ee", atom_keys: true) ==
             {"", %{z: 99, a: 99, b: 99, "0": 99}}

    assert Bencode.decode("d1:ad1:bd1:ci1eeee", atom_keys: false) ==
             {"", %{"a" => %{"b" => %{"c" => 1}}}}

    assert Bencode.decode("d1:ad1:bd1:ci1eeee", atom_keys: true) == {"", %{a: %{b: %{c: 1}}}}
  end

  test "encode/1 binary" do
    assert Bencode.encode("hello") == "5:hello"
  end

  test "encode/1 atom" do
    assert Bencode.encode(:hello) == "5:hello"
  end

  test "encode/1 integer" do
    assert Bencode.encode(123) == "i123e"
    assert Bencode.encode(-123) == "i-123e"
    assert Bencode.encode(0) == "i0e"
    assert Bencode.encode(-0) == "i0e"
  end

  test "encode/1 list" do
    assert Bencode.encode([]) == "le"
    assert Bencode.encode([1, 2, 3]) == "li1ei2ei3ee"
    assert Bencode.encode([1, "a", 2, "b", 3]) == "li1e1:ai2e1:bi3ee"
    assert Bencode.encode([1, ["a", "b", "c"]]) == "li1el1:a1:b1:cee"
  end

  test "encode/1 map" do
    assert Bencode.encode(%{}) == "de"
    assert Bencode.encode(%{a: 1}) == "d1:ai1ee"
    assert Bencode.encode(%{"a" => 1}) == "d1:ai1ee"
    assert Bencode.encode(%{"a" => [1, 2, 3]}) == "d1:ali1ei2ei3eee"
    # from https://www.bittorrent.org/beps/bep_0003.html:
    # Keys must be strings and appear in sorted order (sorted as raw strings, not alphanumerics).
    assert Bencode.encode(%{"z" => 99, "a" => 99, "b" => 99, "0" => 99}) ==
             "d1:0i99e1:ai99e1:bi99e1:zi99ee"

    assert Bencode.encode(%{z: 99, a: 99, b: 99, "0": 99}) ==
             "d1:0i99e1:ai99e1:bi99e1:zi99ee"
  end
end
