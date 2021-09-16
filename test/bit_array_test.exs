defmodule BitArrayTest do
  use ExUnit.Case
  alias Bex.BitArray
  doctest BitArray

  test "new/1" do
    assert_raise FunctionClauseError, fn ->
      BitArray.new(-50)
    end

    assert_raise FunctionClauseError, fn ->
      BitArray.new(0)
    end

    bitarray = BitArray.new(1000)
    assert bitarray
  end

  test "from_binary/2" do
    assert_raise FunctionClauseError, fn ->
      assert BitArray.from_binary(<<0, 0, 0, 0>>, 0)
    end

    assert BitArray.from_binary(<<0, 0>>, 16)
    assert BitArray.from_binary(<<1, 0>>, 16)
    assert BitArray.from_binary(<<0, 1>>, 16)
    assert BitArray.from_binary(<<1, 1>>, 16)
  end

  test "to_binary/1" do
    assert BitArray.from_binary(<<0, 0>>, 16) |> BitArray.to_binary() == <<0, 0>>
    assert BitArray.from_binary(<<0, 128>>, 16) |> BitArray.to_binary() == <<0, 128>>
    assert BitArray.from_binary(<<128, 0, 1>>, 24) |> BitArray.to_binary() == <<128, 0, 1>>
    # note that this bit gets truncatd because it is at position 23 (0-23) in a 24 bit space,
    # and we say the bitarray only has 22 bits
    assert BitArray.from_binary(<<3, 0, 1>>, 22) |> BitArray.to_binary() == <<3, 0, 0>>
  end

  test "to_list/1" do
    list = BitArray.from_binary(<<0, 0>>, 16) |> BitArray.to_list()
    assert Enum.count(list) == 16
    assert Enum.all?(list, fn el -> el == false end)

    list = BitArray.from_binary(<<0, 0>>, 14) |> BitArray.to_list()
    assert Enum.count(list) == 14
    assert Enum.all?(list, fn el -> el == false end)

    list = BitArray.from_binary(<<1, 0>>, 14) |> BitArray.to_list()
    assert Enum.count(list) == 14
    assert Enum.at(list, 7)

    # note: ordering is most significant byte first
    assert list == [
             false,
             false,
             false,
             false,
             false,
             false,
             false,
             true,
             false,
             false,
             false,
             false,
             false,
             false
           ]

    list = BitArray.from_binary(<<255, 4>>, 16) |> BitArray.to_list()
    assert Enum.count(list) == 16

    # note: ordering is most significant byte first
    assert list == [
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             false,
             false,
             false,
             false,
             false,
             true,
             false,
             false
           ]

    list = BitArray.from_binary(<<255, 63>>, 15) |> BitArray.to_list()
    assert Enum.count(list) == 15

    # note: ordering is most significant byte first
    assert list == [
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             true,
             false,
             false,
             true,
             true,
             true,
             true,
             true
           ]
  end

  test "get" do
    assert_raise FunctionClauseError, fn ->
      refute BitArray.from_binary(<<0>>, 8)
             |> BitArray.get(25)
    end

    refute BitArray.from_binary(<<0>>, 8)
           |> BitArray.get(0)

    refute BitArray.from_binary(<<0, 0, 0>>, 24)
           |> BitArray.get(0)

    assert BitArray.from_binary(<<1>>, 8)
           |> BitArray.get(7)

    assert BitArray.from_binary(<<128>>, 8)
           |> BitArray.get(0)

    refute BitArray.from_binary(<<128>>, 8)
           |> BitArray.get(2)

    assert BitArray.from_binary(<<1, 128>>, 16)
           |> BitArray.get(8)

    refute BitArray.from_binary(<<1, 128>>, 16)
           |> BitArray.get(15)

    refute BitArray.from_binary(<<1, 0>>, 16) |> BitArray.get(0)
    assert BitArray.from_binary(<<1, 0>>, 16) |> BitArray.get(7)
  end

  test "set/2" do
    expected = BitArray.from_binary(<<128>>, 8)

    assert BitArray.equals?(
             BitArray.from_binary(<<128>>, 8) |> BitArray.set(0),
             expected
           )

    expected = BitArray.from_binary(<<128>>, 8)

    assert BitArray.equals?(
             BitArray.from_binary(<<0>>, 8) |> BitArray.set(0),
             expected
           )

    expected = BitArray.from_binary(<<1>>, 8)

    assert BitArray.equals?(
             BitArray.from_binary(<<0>>, 8) |> BitArray.set(7),
             expected
           )
  end

  test "unset/2" do
    expected = BitArray.from_binary(<<0>>, 8)

    assert BitArray.equals?(
             BitArray.from_binary(<<0>>, 8) |> BitArray.unset(7),
             expected
           )

    expected = BitArray.from_binary(<<0>>, 8)

    assert BitArray.equals?(
             BitArray.from_binary(<<1>>, 8) |> BitArray.unset(7),
             expected
           )

    expected = BitArray.from_binary(<<0>>, 8)

    assert BitArray.equals?(
             BitArray.from_binary(<<128>>, 8) |> BitArray.unset(0),
             expected
           )
  end

  test "all?/1" do
    assert BitArray.from_binary(<<255>>, 8) |> BitArray.all?()
    refute BitArray.from_binary(<<0>>, 8) |> BitArray.all?()
    refute BitArray.from_binary(<<0, 1>>, 16) |> BitArray.all?()
    refute BitArray.from_binary(<<255, 1>>, 16) |> BitArray.all?()
    refute BitArray.from_binary(<<255, 0, 255>>, 24) |> BitArray.all?()
    assert BitArray.from_binary(<<255, 255, 255>>, 24) |> BitArray.all?()
  end

  test "any?/1" do
    assert BitArray.from_binary(<<255>>, 8) |> BitArray.any?()
    refute BitArray.from_binary(<<0, 0, 0, 0>>, 32) |> BitArray.any?()
    assert BitArray.from_binary(<<0, 0, 1, 0, 0>>, 40) |> BitArray.any?()
  end

  test "none?/1" do
    assert BitArray.from_binary(<<0>>, 8) |> BitArray.none?()
    refute BitArray.from_binary(<<255>>, 8) |> BitArray.none?()
    refute BitArray.from_binary(<<0, 1>>, 16) |> BitArray.none?()
    refute BitArray.from_binary(<<255, 1>>, 16) |> BitArray.none?()
    refute BitArray.from_binary(<<255, 0, 255>>, 24) |> BitArray.none?()
    refute BitArray.from_binary(<<255, 255, 255>>, 24) |> BitArray.none?()
    assert BitArray.from_binary(<<0, 0, 0>>, 24) |> BitArray.none?()
  end

  test "set_count/1" do
    assert BitArray.from_binary(<<0>>, 8) |> BitArray.set_count() == 0
    assert BitArray.from_binary(<<1, 0>>, 16) |> BitArray.set_count() == 1
    assert BitArray.from_binary(<<7, 0>>, 16) |> BitArray.set_count() == 3
    assert BitArray.from_binary(<<7, 7>>, 16) |> BitArray.set_count() == 6
    assert BitArray.from_binary(<<0, 7>>, 16) |> BitArray.set_count() == 3
    assert BitArray.from_binary(<<0, 255>>, 16) |> BitArray.set_count() == 8
  end

  test "unset_count/1" do
    assert BitArray.from_binary(<<0>>, 8) |> BitArray.unset_count() == 8
    assert BitArray.from_binary(<<1, 0>>, 16) |> BitArray.unset_count() == 15
    assert BitArray.from_binary(<<7, 0>>, 16) |> BitArray.unset_count() == 13
    assert BitArray.from_binary(<<7, 7>>, 16) |> BitArray.unset_count() == 10
    assert BitArray.from_binary(<<0, 7>>, 16) |> BitArray.unset_count() == 13
    assert BitArray.from_binary(<<0, 255>>, 16) |> BitArray.unset_count() == 8
  end
end
