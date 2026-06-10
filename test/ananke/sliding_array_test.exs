defmodule Ananke.SlidingArrayTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ananke.SlidingArray, as: SA

  # ---------------------------------------------------------------------------
  # new/0
  # ---------------------------------------------------------------------------

  describe "new/0" do
    test "first is 0" do
      assert SA.first(SA.new()) == 0
    end

    test "next is 0" do
      assert SA.next(SA.new()) == 0
    end

    test "size is 0" do
      assert SA.size(SA.new()) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # add/2
  # ---------------------------------------------------------------------------

  describe "add/2" do
    test "first add returns index 0" do
      {idx, _arr} = SA.add(SA.new(), :a)
      assert idx == 0
    end

    test "returned index equals old next" do
      arr = SA.new()
      old_next = SA.next(arr)
      {idx, _} = SA.add(arr, :x)
      assert idx == old_next
    end

    test "element is retrievable at the returned index" do
      {idx, arr} = SA.add(SA.new(), :hello)
      assert SA.at(arr, idx) == :hello
    end

    test "successive adds assign sequential indices" do
      arr = SA.new()
      {i0, arr} = SA.add(arr, :a)
      {i1, arr} = SA.add(arr, :b)
      {i2, _} = SA.add(arr, :c)
      assert [i0, i1, i2] == [0, 1, 2]
    end

    test "add increments next by 1" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :x)
      assert SA.next(arr) == 1
    end

    test "add does not change first" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :x)
      assert SA.first(arr) == 0
    end

    test "add increments size by 1" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :x)
      assert SA.size(arr) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # peek/1
  # ---------------------------------------------------------------------------

  describe "peek/1" do
    test "returns nil on an empty array" do
      assert SA.peek(SA.new()) == nil
    end

    test "returns the oldest element" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :first)
      {_, arr} = SA.add(arr, :second)
      assert SA.peek(arr) == :first
    end

    test "does not remove the element" do
      {_, arr} = SA.add(SA.new(), :x)
      SA.peek(arr)
      assert SA.size(arr) == 1
    end

    test "peek after remove returns the next oldest" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :a)
      {_, arr} = SA.add(arr, :b)
      {_, arr} = SA.remove(arr)
      assert SA.peek(arr) == :b
    end
  end

  # ---------------------------------------------------------------------------
  # remove/1
  # ---------------------------------------------------------------------------

  describe "remove/1" do
    test "returns {nil, unchanged array} on empty" do
      arr = SA.new()
      assert SA.remove(arr) == {nil, arr}
    end

    test "returns the oldest element" do
      {_, arr} = SA.add(SA.new(), :target)
      {elem, _} = SA.remove(arr)
      assert elem == :target
    end

    test "increments first by 1" do
      {_, arr} = SA.add(SA.new(), :x)
      {_, arr} = SA.remove(arr)
      assert SA.first(arr) == 1
    end

    test "decrements size by 1" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :a)
      {_, arr} = SA.add(arr, :b)
      {_, arr} = SA.remove(arr)
      assert SA.size(arr) == 1
    end

    test "removes elements in insertion order" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :a)
      {_, arr} = SA.add(arr, :b)
      {_, arr} = SA.add(arr, :c)
      {e1, arr} = SA.remove(arr)
      {e2, arr} = SA.remove(arr)
      {e3, _} = SA.remove(arr)
      assert [e1, e2, e3] == [:a, :b, :c]
    end

    test "removing until empty then removing again returns {nil, arr}" do
      {_, arr} = SA.add(SA.new(), :x)
      {_, arr} = SA.remove(arr)
      {elem, _} = SA.remove(arr)
      assert elem == nil
    end
  end

  # ---------------------------------------------------------------------------
  # at/2
  # ---------------------------------------------------------------------------

  describe "at/2" do
    test "returns nil for index below first" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :x)
      {_, arr} = SA.remove(arr)
      assert SA.at(arr, 0) == nil
    end

    test "returns nil for index at or above next" do
      arr = SA.new()
      assert SA.at(arr, 0) == nil
    end

    test "returns the stored element at a valid index" do
      {idx, arr} = SA.add(SA.new(), :value)
      assert SA.at(arr, idx) == :value
    end

    test "index is stable across subsequent adds" do
      arr = SA.new()
      {idx, arr} = SA.add(arr, :stable)
      {_, arr} = SA.add(arr, :other1)
      {_, arr} = SA.add(arr, :other2)
      assert SA.at(arr, idx) == :stable
    end

    test "index is stable across removes that have not yet reached it" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :before)
      {idx, arr} = SA.add(arr, :target)
      {_, arr} = SA.add(arr, :after)
      {_, arr} = SA.remove(arr)
      assert SA.at(arr, idx) == :target
    end
  end

  # ---------------------------------------------------------------------------
  # put/3
  # ---------------------------------------------------------------------------

  describe "put/3" do
    test "replaces the element at a valid index" do
      {idx, arr} = SA.add(SA.new(), :old)
      arr = SA.put(arr, idx, :new)
      assert SA.at(arr, idx) == :new
    end

    test "does not change size" do
      {idx, arr} = SA.add(SA.new(), :x)
      arr = SA.put(arr, idx, :y)
      assert SA.size(arr) == 1
    end

    test "does not change first or next" do
      {idx, arr} = SA.add(SA.new(), :x)
      arr = SA.put(arr, idx, :y)
      assert SA.first(arr) == 0
      assert SA.next(arr) == 1
    end

    test "put below first raises" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :x)
      {_, arr} = SA.remove(arr)
      assert_raise ArgumentError, fn -> SA.put(arr, 0, :y) end
    end

    test "put at or above next raises" do
      arr = SA.new()
      assert_raise ArgumentError, fn -> SA.put(arr, 0, :y) end
    end
  end

  # ---------------------------------------------------------------------------
  # first/1, next/1, size/1
  # ---------------------------------------------------------------------------

  describe "first/1, next/1, size/1" do
    test "size equals next minus first" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :a)
      {_, arr} = SA.add(arr, :b)
      {_, arr} = SA.remove(arr)
      assert SA.size(arr) == SA.next(arr) - SA.first(arr)
    end

    test "first never decreases" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :a)
      {_, arr} = SA.add(arr, :b)
      assert SA.first(arr) == 0
      {_, arr} = SA.remove(arr)
      assert SA.first(arr) == 1
    end

    test "next never decreases" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :a)
      assert SA.next(arr) == 1
      {_, arr} = SA.remove(arr)
      assert SA.next(arr) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Property tests
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "first <= next at all times" do
      check all ops <- list_of(one_of([{:add, term()}, {:remove}]), min_length: 0) do
        arr =
          Enum.reduce(ops, SA.new(), fn
            {:add, v}, a -> elem(SA.add(a, v), 1)
            {:remove}, a -> elem(SA.remove(a), 1)
          end)

        assert SA.first(arr) <= SA.next(arr)
      end
    end

    property "size equals next - first" do
      check all ops <- list_of(one_of([{:add, term()}, {:remove}]), min_length: 0) do
        arr =
          Enum.reduce(ops, SA.new(), fn
            {:add, v}, a -> elem(SA.add(a, v), 1)
            {:remove}, a -> elem(SA.remove(a), 1)
          end)

        assert SA.size(arr) == SA.next(arr) - SA.first(arr)
      end
    end

    property "add: returned index equals old next and element is retrievable" do
      check all elems <- list_of(term(), min_length: 1) do
        {indices, final} =
          Enum.map_reduce(elems, SA.new(), fn e, a ->
            {idx, new_a} = SA.add(a, e)
            {idx, new_a}
          end)

        Enum.zip(indices, elems)
        |> Enum.each(fn {idx, e} ->
          assert SA.at(final, idx) == e
        end)
      end
    end

    property "remove returns elements in insertion order" do
      check all elems <- list_of(term(), min_length: 1) do
        arr = Enum.reduce(elems, SA.new(), fn e, a -> elem(SA.add(a, e), 1) end)

        removed =
          Enum.map_reduce(elems, arr, fn _, a ->
            {e, new_a} = SA.remove(a)
            {e, new_a}
          end)
          |> elem(0)

        assert removed == elems
      end
    end

    property "an index from add refers to the same element after intervening ops" do
      check all before_elems <- list_of(term()),
                target <- term(),
                after_elems <- list_of(term()),
                removes <- integer(0..length(before_elems)) do
        arr = Enum.reduce(before_elems, SA.new(), fn e, a -> elem(SA.add(a, e), 1) end)
        {idx, arr} = SA.add(arr, target)
        arr = Enum.reduce(after_elems, arr, fn e, a -> elem(SA.add(a, e), 1) end)
        arr = Enum.reduce(1..max(removes, 1), arr, fn _, a -> elem(SA.remove(a), 1) end)

        if SA.first(arr) <= idx do
          assert SA.at(arr, idx) == target
        else
          assert SA.at(arr, idx) == nil
        end
      end
    end

    property "put replaces without affecting size, first, or next" do
      check all elems <- list_of(term(), min_length: 1),
                new_val <- term() do
        arr = Enum.reduce(elems, SA.new(), fn e, a -> elem(SA.add(a, e), 1) end)
        idx = SA.first(arr)

        before_size = SA.size(arr)
        before_first = SA.first(arr)
        before_next = SA.next(arr)

        arr = SA.put(arr, idx, new_val)

        assert SA.size(arr) == before_size
        assert SA.first(arr) == before_first
        assert SA.next(arr) == before_next
        assert SA.at(arr, idx) == new_val
      end
    end

    property "at returns nil for every index outside [first, next)" do
      check all elems <- list_of(term()),
                removes <- integer(0..max(length(elems), 0)),
                i <- integer(-5..200) do
        arr = Enum.reduce(elems, SA.new(), fn e, a -> elem(SA.add(a, e), 1) end)

        arr =
          Enum.reduce(1..max(removes, 1), arr, fn _, a -> elem(SA.remove(a), 1) end)

        if i < SA.first(arr) or i >= SA.next(arr) do
          assert SA.at(arr, i) == nil
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # entries/1
  # ---------------------------------------------------------------------------

  describe "entries/1" do
    test "returns empty list for empty array" do
      assert SA.entries(SA.new()) == []
    end

    test "returns all {index, element} pairs in index order" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :a)
      {_, arr} = SA.add(arr, :b)
      {_, arr} = SA.add(arr, :c)
      assert SA.entries(arr) == [{0, :a}, {1, :b}, {2, :c}]
    end

    test "reflects the current window after removes" do
      arr = SA.new()
      {_, arr} = SA.add(arr, :a)
      {_, arr} = SA.add(arr, :b)
      {_, arr} = SA.add(arr, :c)
      {_, arr} = SA.remove(arr)
      assert SA.entries(arr) == [{1, :b}, {2, :c}]
    end

    test "reflects put updates" do
      arr = SA.new()
      {idx, arr} = SA.add(arr, :old)
      arr = SA.put(arr, idx, :new)
      assert SA.entries(arr) == [{0, :new}]
    end

    property "entries indices match [first, next)" do
      check all elems <- list_of(term()) do
        arr = Enum.reduce(elems, SA.new(), fn e, a -> elem(SA.add(a, e), 1) end)
        indices = arr |> SA.entries() |> Enum.map(&elem(&1, 0))
        assert indices == Enum.to_list(SA.first(arr)..(SA.next(arr) - 1)//1)
      end
    end

    property "entries values match at/2 for each index" do
      check all elems <- list_of(term(), min_length: 1) do
        arr = Enum.reduce(elems, SA.new(), fn e, a -> elem(SA.add(a, e), 1) end)

        for {i, v} <- SA.entries(arr) do
          assert SA.at(arr, i) == v
        end
      end
    end
  end
end
