defmodule BitfieldTest do
  use ExUnit.Case
  doctest Bex.Bitfield
  alias Bex.Bitfield

  test "new/1" do
    assert_raise FunctionClauseError, fn ->
      Bitfield.new(-50)
    end

    assert_raise FunctionClauseError, fn ->
      Bitfield.new(0)
    end

    bitfield = Bitfield.new(1000)
    assert bitfield.integer == 0
  end

  test "from_binary/2" do
    assert_raise FunctionClauseError, fn ->
      assert Bitfield.from_binary(<<0, 0, 0, 0>>, 0).integer == 0
    end

    assert Bitfield.from_binary(<<0, 0>>, 16).integer == 0
    assert Bitfield.from_binary(<<1, 0>>, 16).integer == 256
    assert Bitfield.from_binary(<<0, 1>>, 16).integer == 1
    assert Bitfield.from_binary(<<1, 1>>, 16).integer == 257
  end

  test "to_binary/1" do
    assert Bitfield.from_binary(<<0, 0>>, 16) |> Bitfield.to_binary() == <<0, 0>>
    assert Bitfield.from_binary(<<0, 128>>, 16) |> Bitfield.to_binary() == <<0, 128>>
    assert Bitfield.from_binary(<<128, 0, 1>>, 24) |> Bitfield.to_binary() == <<128, 0, 1>>
    assert Bitfield.from_binary(<<3, 0, 1>>, 22) |> Bitfield.to_binary() == <<3, 0, 1>>
  end

  test "to_list/1" do
    list = Bitfield.from_binary(<<0, 0>>, 16) |> Bitfield.to_list()
    assert Enum.count(list) == 16
    assert Enum.all?(list, fn el -> el == false end)

    list = Bitfield.from_binary(<<0, 0>>, 14) |> Bitfield.to_list()
    assert Enum.count(list) == 14
    assert Enum.all?(list, fn el -> el == false end)

    list = Bitfield.from_binary(<<1, 0>>, 14) |> Bitfield.to_list()
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

    list = Bitfield.from_binary(<<255, 4>>, 16) |> Bitfield.to_list()
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

    Bitfield.from_binary(<<255, 63>>, 15).integer
    list = Bitfield.from_binary(<<255, 63>>, 15) |> Bitfield.to_list()
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
      refute Bitfield.from_binary(<<0>>, 8)
             |> Bitfield.get(25)
    end

    refute Bitfield.from_binary(<<0>>, 8)
           |> Bitfield.get(0)

    refute Bitfield.from_binary(<<0, 0, 0>>, 24)
           |> Bitfield.get(0)

    assert Bitfield.from_binary(<<1>>, 8)
           |> Bitfield.get(7)

    assert Bitfield.from_binary(<<128>>, 8)
           |> Bitfield.get(0)

    refute Bitfield.from_binary(<<128>>, 8)
           |> Bitfield.get(2)

    assert Bitfield.from_binary(<<1, 128>>, 16)
           |> Bitfield.get(8)

    refute Bitfield.from_binary(<<1, 128>>, 16)
           |> Bitfield.get(15)

    refute Bitfield.from_binary(<<1, 0>>, 16) |> Bitfield.get(0)
    assert Bitfield.from_binary(<<1, 0>>, 16) |> Bitfield.get(7)
  end

  test "set/2" do
    expected = Bitfield.from_binary(<<128>>, 8)
    assert Bitfield.from_binary(<<128>>, 8) |> Bitfield.set(0) == expected

    expected = Bitfield.from_binary(<<128>>, 8)
    assert Bitfield.from_binary(<<0>>, 8) |> Bitfield.set(0) == expected

    expected = Bitfield.from_binary(<<1>>, 8)
    assert Bitfield.from_binary(<<0>>, 8) |> Bitfield.set(7) == expected
  end

  test "unset/2" do
    expected = Bitfield.from_binary(<<0>>, 8)
    assert Bitfield.from_binary(<<0>>, 8) |> Bitfield.unset(7) == expected

    expected = Bitfield.from_binary(<<0>>, 8)
    assert Bitfield.from_binary(<<1>>, 8) |> Bitfield.unset(7) == expected

    expected = Bitfield.from_binary(<<0>>, 8)
    assert Bitfield.from_binary(<<128>>, 8) |> Bitfield.unset(0) == expected
  end

  test "all?/1" do
    assert Bitfield.from_binary(<<255>>, 8) |> Bitfield.all?()
    refute Bitfield.from_binary(<<0>>, 8) |> Bitfield.all?()
    refute Bitfield.from_binary(<<0, 1>>, 16) |> Bitfield.all?()
    refute Bitfield.from_binary(<<255, 1>>, 16) |> Bitfield.all?()
    refute Bitfield.from_binary(<<255, 0, 255>>, 24) |> Bitfield.all?()
    assert Bitfield.from_binary(<<255, 255, 255>>, 24) |> Bitfield.all?()
  end

  test "none?/1" do
    assert Bitfield.from_binary(<<0>>, 8) |> Bitfield.none?()
    refute Bitfield.from_binary(<<255>>, 8) |> Bitfield.none?()
    refute Bitfield.from_binary(<<0, 1>>, 16) |> Bitfield.none?()
    refute Bitfield.from_binary(<<255, 1>>, 16) |> Bitfield.none?()
    refute Bitfield.from_binary(<<255, 0, 255>>, 24) |> Bitfield.none?()
    refute Bitfield.from_binary(<<255, 255, 255>>, 24) |> Bitfield.none?()
    assert Bitfield.from_binary(<<0, 0, 0>>, 24) |> Bitfield.none?()
  end

  test "set_count/1" do
    assert Bitfield.from_binary(<<0>>, 8) |> Bitfield.set_count() == 0
    assert Bitfield.from_binary(<<1, 0>>, 16) |> Bitfield.set_count() == 1
    assert Bitfield.from_binary(<<7, 0>>, 16) |> Bitfield.set_count() == 3
    assert Bitfield.from_binary(<<7, 7>>, 16) |> Bitfield.set_count() == 6
    assert Bitfield.from_binary(<<0, 7>>, 16) |> Bitfield.set_count() == 3
    assert Bitfield.from_binary(<<0, 255>>, 16) |> Bitfield.set_count() == 8
  end

  test "unset_count/1" do
    assert Bitfield.from_binary(<<0>>, 8) |> Bitfield.unset_count() == 8
    assert Bitfield.from_binary(<<1, 0>>, 16) |> Bitfield.unset_count() == 15
    assert Bitfield.from_binary(<<7, 0>>, 16) |> Bitfield.unset_count() == 13
    assert Bitfield.from_binary(<<7, 7>>, 16) |> Bitfield.unset_count() == 10
    assert Bitfield.from_binary(<<0, 7>>, 16) |> Bitfield.unset_count() == 13
    assert Bitfield.from_binary(<<0, 255>>, 16) |> Bitfield.unset_count() == 8
  end
end
