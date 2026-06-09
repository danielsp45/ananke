defmodule Ananke.SlidingArray do
  @moduledoc """
  An immutable, growable array over a contiguous index window `[first, next)`.

  Elements are appended at the high end (`next`) and removed from the low end
  (`first`). Every index in `[first, next)` holds an element — the array is
  always dense. Indices are assigned once at insertion and never change;
  external code can hold an index returned by `add/2` and look up the same
  element by it at any later point, as long as the front has not swept past it.

  The backing store is a map, so all operations are amortized O(1).
  """

  @enforce_keys [:entries, :first, :next]
  defstruct [:entries, :first, :next]

  @type index :: non_neg_integer()
  @type t :: %__MODULE__{
          entries: %{index() => term()},
          first: index(),
          next: index()
        }

  @doc "Returns an empty array with `first = next = 0`."
  @spec new() :: t()
  def new, do: %__MODULE__{entries: %{}, first: 0, next: 0}

  @doc """
  Appends `elem` at index `next`, increments `next`, and returns `{index, new_array}`.
  The returned index is the stable identifier for this element.
  """
  @spec add(t(), term()) :: {index(), t()}
  def add(%__MODULE__{entries: e, next: n} = arr, elem) do
    {n, %{arr | entries: Map.put(e, n, elem), next: n + 1}}
  end

  @doc "Returns the oldest element (at `first`), or `nil` if the array is empty."
  @spec peek(t()) :: term()
  def peek(%__MODULE__{first: same, next: same}), do: nil
  def peek(%__MODULE__{entries: e, first: f}), do: Map.get(e, f)

  @doc """
  Removes and returns the oldest element as `{elem, new_array}`, incrementing
  `first`. Returns `{nil, array}` unchanged on an empty array.
  """
  @spec remove(t()) :: {term(), t()}
  def remove(%__MODULE__{first: same, next: same} = arr), do: {nil, arr}

  def remove(%__MODULE__{entries: e, first: f} = arr) do
    {Map.get(e, f), %{arr | entries: Map.delete(e, f), first: f + 1}}
  end

  @doc """
  Returns the element at absolute index `i`, or `nil` if `i` is outside
  `[first, next)`.
  """
  @spec at(t(), index()) :: term()
  def at(%__MODULE__{first: f, next: n}, i) when i < f or i >= n, do: nil
  def at(%__MODULE__{entries: e}, i), do: Map.get(e, i)

  @doc """
  Replaces the element at index `i` with `elem`. `i` must be within
  `[first, next)` — this updates an existing slot, it does not add a new one.
  Raises `ArgumentError` if `i` is out of range.
  """
  @spec put(t(), index(), term()) :: t()
  def put(%__MODULE__{first: f, next: n}, i, _elem) when i < f or i >= n do
    raise ArgumentError, "index #{i} is outside [#{f}, #{n})"
  end

  def put(%__MODULE__{entries: e} = arr, i, elem) do
    %{arr | entries: Map.put(e, i, elem)}
  end

  @doc "Returns the lowest live index (the oldest element's position)."
  @spec first(t()) :: index()
  def first(%__MODULE__{first: f}), do: f

  @doc "Returns the index that the next `add/2` will assign."
  @spec next(t()) :: index()
  def next(%__MODULE__{next: n}), do: n

  @doc "Returns the number of live elements: `next - first`."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{first: f, next: n}), do: n - f
end
