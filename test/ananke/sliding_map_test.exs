defmodule Ananke.SlidingMapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ananke.SlidingMap, as: SM

  # ---------------------------------------------------------------------------
  # new/0
  # ---------------------------------------------------------------------------

  describe "new/0" do
    test "first is 0" do
      assert SM.first(SM.new()) == 0
    end

    test "next is 0" do
      assert SM.next(SM.new()) == 0
    end

    test "starts empty" do
      m = SM.new()
      assert m.by_key == %{}
      assert m.by_index == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # add/2
  # ---------------------------------------------------------------------------

  describe "add/2" do
    test "first add returns index 0" do
      {idx, _} = SM.add(SM.new(), :k)
      assert idx == 0
    end

    test "returned index equals old next" do
      m = SM.new()
      old_next = SM.next(m)
      {idx, _} = SM.add(m, :k)
      assert idx == old_next
    end

    test "index is retrievable by key" do
      {idx, m} = SM.add(SM.new(), :k)
      assert SM.index(m, :k) == idx
    end

    test "key is retrievable by index" do
      {idx, m} = SM.add(SM.new(), :k)
      assert SM.at(m, idx) == :k
    end

    test "successive adds assign sequential indices" do
      m = SM.new()
      {i0, m} = SM.add(m, :a)
      {i1, m} = SM.add(m, :b)
      {i2, _} = SM.add(m, :c)
      assert [i0, i1, i2] == [0, 1, 2]
    end

    test "add increments next by 1" do
      {_, m} = SM.add(SM.new(), :k)
      assert SM.next(m) == 1
    end

    test "add does not change first when map was non-empty" do
      {_, m} = SM.add(SM.new(), :a)
      {_, m} = SM.add(m, :b)
      assert SM.first(m) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # index/2 and at/2
  # ---------------------------------------------------------------------------

  describe "index/2" do
    test "returns nil for absent key" do
      assert SM.index(SM.new(), :missing) == nil
    end

    test "returns the assigned index for a present key" do
      {idx, m} = SM.add(SM.new(), :k)
      assert SM.index(m, :k) == idx
    end

    test "returns nil after the key is removed" do
      {_, m} = SM.add(SM.new(), :k)
      m = SM.remove(m, :k)
      assert SM.index(m, :k) == nil
    end
  end

  describe "at/2" do
    test "returns nil for an empty index" do
      assert SM.at(SM.new(), 0) == nil
    end

    test "returns the key at a populated index" do
      {idx, m} = SM.add(SM.new(), :k)
      assert SM.at(m, idx) == :k
    end

    test "returns nil after removal creates a gap" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {i1, m} = SM.add(m, :b)
      {_, m} = SM.add(m, :c)
      m = SM.remove(m, :b)
      assert SM.at(m, i1) == nil
    end

    test "returns nil for an index below first" do
      {_, m} = SM.add(SM.new(), :k)
      m = SM.remove(m, :k)
      assert SM.at(m, 0) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # peek/1
  # ---------------------------------------------------------------------------

  describe "peek/1" do
    test "returns nil on an empty map" do
      assert SM.peek(SM.new()) == nil
    end

    test "returns the oldest present key" do
      m = SM.new()
      {_, m} = SM.add(m, :first)
      {_, m} = SM.add(m, :second)
      assert SM.peek(m) == :first
    end

    test "returns the correct key after front is removed" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {_, m} = SM.add(m, :b)
      m = SM.remove(m, :a)
      assert SM.peek(m) == :b
    end

    test "returns nil after all keys are removed" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      m = SM.remove(m, :a)
      assert SM.peek(m) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # remove/2
  # ---------------------------------------------------------------------------

  describe "remove/2" do
    test "absent key is a silent no-op" do
      m = SM.new()
      assert SM.remove(m, :missing) == m
    end

    test "already-removed key is a silent no-op" do
      {_, m} = SM.add(SM.new(), :k)
      m = SM.remove(m, :k)
      before = m
      assert SM.remove(m, :k) == before
    end

    test "removes key from by_key" do
      {_, m} = SM.add(SM.new(), :k)
      m = SM.remove(m, :k)
      assert SM.index(m, :k) == nil
    end

    test "removes index from by_index" do
      {idx, m} = SM.add(SM.new(), :k)
      m = SM.remove(m, :k)
      assert SM.at(m, idx) == nil
    end

    test "removing the front key advances first" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {_, m} = SM.add(m, :b)
      m = SM.remove(m, :a)
      assert SM.first(m) == 1
    end

    test "removing the front key advances first past consecutive gaps" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {_, m} = SM.add(m, :b)
      {_, m} = SM.add(m, :c)
      m = SM.remove(m, :b)
      m = SM.remove(m, :a)
      assert SM.first(m) == 2
    end

    test "removing a non-front key does not change first" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {_, m} = SM.add(m, :b)
      m = SM.remove(m, :b)
      assert SM.first(m) == 0
    end

    test "removing a non-front key creates a gap reported as nil by at" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {i_b, m} = SM.add(m, :b)
      {_, m} = SM.add(m, :c)
      m = SM.remove(m, :b)
      assert SM.at(m, i_b) == nil
      assert SM.first(m) == 0
    end

    test "removing all keys makes first equal next" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {_, m} = SM.add(m, :b)
      m = SM.remove(m, :a)
      m = SM.remove(m, :b)
      assert SM.first(m) == SM.next(m)
    end

    test "does not change next" do
      {_, m} = SM.add(SM.new(), :k)
      old_next = SM.next(m)
      m = SM.remove(m, :k)
      assert SM.next(m) == old_next
    end
  end

  # ---------------------------------------------------------------------------
  # Property tests
  # ---------------------------------------------------------------------------

  defp apply_ops(ops) do
    Enum.reduce(ops, {SM.new(), []}, fn
      {:add, key}, {m, keys} ->
        {_, m} = SM.add(m, key)
        {m, [key | keys]}

      {:remove, key}, {m, keys} ->
        {SM.remove(m, key), List.delete(keys, key)}
    end)
  end

  describe "properties" do
    property "first <= next at all times" do
      check all keys <- list_of(integer(), min_length: 1),
                removes <- list_of(member_of(keys)) do
        ops = Enum.map(keys, &{:add, &1}) ++ Enum.map(removes, &{:remove, &1})
        {m, _} = apply_ops(ops)
        assert SM.first(m) <= SM.next(m)
      end
    end

    property "by_key and by_index are mutual inverses over the live set" do
      check all keys <- uniq_list_of(integer(), min_length: 1),
                removes <- list_of(member_of(keys)) do
        ops = Enum.map(keys, &{:add, &1}) ++ Enum.map(removes, &{:remove, &1})
        {m, _} = apply_ops(ops)

        for {key, idx} <- m.by_key do
          assert Map.get(m.by_index, idx) == key
        end

        for {idx, key} <- m.by_index do
          assert Map.get(m.by_key, key) == idx
        end
      end
    end

    property "first is next (empty) or the minimum present index" do
      check all keys <- uniq_list_of(integer(), min_length: 0),
                removes <- list_of(member_of(if keys == [], do: [0], else: keys)) do
        ops = Enum.map(keys, &{:add, &1}) ++ Enum.map(removes, &{:remove, &1})
        {m, _} = apply_ops(ops)

        if map_size(m.by_index) == 0 do
          assert SM.first(m) == SM.next(m)
        else
          min_present = m.by_index |> Map.keys() |> Enum.min()
          assert SM.first(m) == min_present
        end
      end
    end

    property "after add, index and at both return the assigned value" do
      check all keys <- uniq_list_of(integer(), min_length: 1) do
        {idx_for, m} =
          Enum.map_reduce(keys, SM.new(), fn k, acc ->
            {idx, new_m} = SM.add(acc, k)
            {{k, idx}, new_m}
          end)

        for {k, idx} <- idx_for do
          assert SM.index(m, k) == idx
          assert SM.at(m, idx) == k
        end
      end
    end

    property "remove of an absent key leaves the structure identical" do
      check all keys <- uniq_list_of(integer(), min_length: 1) do
        m = Enum.reduce(keys, SM.new(), fn k, acc -> elem(SM.add(acc, k), 1) end)
        assert SM.remove(m, :definitely_not_a_key) == m
      end
    end

    property "removing the front key advances first to the next present index" do
      check all keys <- uniq_list_of(integer(), min_length: 2) do
        m = Enum.reduce(keys, SM.new(), fn k, acc -> elem(SM.add(acc, k), 1) end)
        front_key = SM.peek(m)
        m_after = SM.remove(m, front_key)

        if map_size(m_after.by_index) == 0 do
          assert SM.first(m_after) == SM.next(m_after)
        else
          min_remaining = m_after.by_index |> Map.keys() |> Enum.min()
          assert SM.first(m_after) == min_remaining
        end
      end
    end

    property "removing a non-front key leaves first unchanged and creates a gap" do
      check all keys <- uniq_list_of(integer(), min_length: 3) do
        m = Enum.reduce(keys, SM.new(), fn k, acc -> elem(SM.add(acc, k), 1) end)
        middle_key = Enum.at(keys, 1)
        middle_idx = SM.index(m, middle_key)
        m_after = SM.remove(m, middle_key)

        assert SM.first(m_after) == SM.first(m)
        assert SM.at(m_after, middle_idx) == nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # entries/1
  # ---------------------------------------------------------------------------

  describe "entries/1" do
    test "returns empty list for empty map" do
      assert SM.entries(SM.new()) == []
    end

    test "returns all {key, index} pairs in insertion order" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {_, m} = SM.add(m, :b)
      {_, m} = SM.add(m, :c)
      assert SM.entries(m) == [{:a, 0}, {:b, 1}, {:c, 2}]
    end

    test "gaps from non-front removal are absent" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {_, m} = SM.add(m, :b)
      {_, m} = SM.add(m, :c)
      m = SM.remove(m, :b)
      assert SM.entries(m) == [{:a, 0}, {:c, 2}]
    end

    test "reflects front removal advancing first" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      {_, m} = SM.add(m, :b)
      m = SM.remove(m, :a)
      assert SM.entries(m) == [{:b, 1}]
    end

    test "returns empty list after all keys removed" do
      m = SM.new()
      {_, m} = SM.add(m, :a)
      m = SM.remove(m, :a)
      assert SM.entries(m) == []
    end

    property "entries keys match by_key exactly" do
      check all keys <- uniq_list_of(integer(), min_length: 0),
                removes <- list_of(member_of(if keys == [], do: [0], else: keys)) do
        m = Enum.reduce(keys, SM.new(), fn k, acc -> elem(SM.add(acc, k), 1) end)
        m = Enum.reduce(removes, m, fn k, acc -> SM.remove(acc, k) end)
        assert SM.entries(m) |> Enum.map(&elem(&1, 0)) |> MapSet.new() ==
                 MapSet.new(Map.keys(m.by_key))
      end
    end

    property "entries indices are in strictly increasing order" do
      check all keys <- uniq_list_of(integer(), min_length: 0) do
        m = Enum.reduce(keys, SM.new(), fn k, acc -> elem(SM.add(acc, k), 1) end)
        indices = SM.entries(m) |> Enum.map(&elem(&1, 1))
        assert indices == Enum.sort(indices)
        assert length(Enum.uniq(indices)) == length(indices)
      end
    end
  end
end
