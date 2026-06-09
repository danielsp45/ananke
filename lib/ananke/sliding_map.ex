defmodule Ananke.SlidingMap do
  @moduledoc """
  An immutable sliding map over a monotonically increasing index window `[first, next)`.

  Like `SlidingArray`, each entry is assigned a stable index at insertion.
  Unlike `SlidingArray`, entries are identified by an opaque key from an
  external id space, removal targets an arbitrary key (not just the front),
  and the window is therefore sparse: gaps open whenever a non-front key is
  removed.

  `first` is always the lowest index that is still present, or equals `next`
  when the map is empty. When the front entry is removed, `first` is advanced
  forward past any gaps until it reaches the next present index. This advance
  is amortized O(1) because each index is skipped at most once across the
  lifetime of the map.

  Two maps are kept in sync on every mutation:
  - `by_key`   — key → index  (translation from external id to stable index)
  - `by_index` — index → key  (equivalent of the paper's presence bit-array)
  """

  @enforce_keys [:by_key, :by_index, :first, :next]
  defstruct [:by_key, :by_index, :first, :next]

  @type key :: term()
  @type index :: non_neg_integer()
  @type t :: %__MODULE__{
          by_key: %{key() => index()},
          by_index: %{index() => key()},
          first: index(),
          next: index()
        }

  @doc "Returns an empty map with `first = next = 0`."
  @spec new() :: t()
  def new, do: %__MODULE__{by_key: %{}, by_index: %{}, first: 0, next: 0}

  @doc """
  Assigns `key` the index `next`, records it in both directions, increments
  `next`, and returns `{index, new_map}`.
  """
  @spec add(t(), key()) :: {index(), t()}
  def add(%__MODULE__{by_key: bk, by_index: bi, next: n} = map, key) do
    {n,
     %{
       map
       | by_key: Map.put(bk, key, n),
         by_index: Map.put(bi, n, key),
         next: n + 1
     }}
  end

  @doc "Returns the index assigned to `key`, or `nil` if the key is not present."
  @spec index(t(), key()) :: index() | nil
  def index(%__MODULE__{by_key: bk}, key), do: Map.get(bk, key)

  @doc "Returns the key at index `i`, or `nil` if that index is empty or out of range."
  @spec at(t(), index()) :: key() | nil
  def at(%__MODULE__{by_index: bi}, i), do: Map.get(bi, i)

  @doc "Returns the key at `first` (the oldest present entry), or `nil` if empty."
  @spec peek(t()) :: key() | nil
  def peek(%__MODULE__{first: same, next: same}), do: nil
  def peek(%__MODULE__{by_index: bi, first: f}), do: Map.get(bi, f)

  @doc """
  Removes `key` from the map. If `key` is absent, returns the map unchanged
  (silent no-op). If the removed entry was at `first`, advances `first` forward
  past any now-empty indices to the next present index, or to `next` if the map
  becomes empty.
  """
  @spec remove(t(), key()) :: t()
  def remove(%__MODULE__{by_key: bk} = map, key) do
    case Map.get(bk, key) do
      nil ->
        map

      idx ->
        updated = %{
          map
          | by_key: Map.delete(bk, key),
            by_index: Map.delete(map.by_index, idx)
        }

        if idx == map.first, do: advance_first(updated), else: updated
    end
  end

  @doc "Returns the lowest present index, or `next` when the map is empty."
  @spec first(t()) :: index()
  def first(%__MODULE__{first: f}), do: f

  @doc "Returns the index that the next `add/2` will assign."
  @spec next(t()) :: index()
  def next(%__MODULE__{next: n}), do: n

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp advance_first(%__MODULE__{first: f, next: n} = map) when f < n do
    if Map.has_key?(map.by_index, f),
      do: map,
      else: advance_first(%{map | first: f + 1})
  end

  defp advance_first(map), do: map
end
