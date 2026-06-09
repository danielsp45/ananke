defmodule Causal.Harness do
  @moduledoc """
  Deterministic, in-memory test harness for the causal protocol core.

  Drives the protocol core as pure state transitions — no processes, no
  timers, no transport. This gives tests full control over message delivery
  order, which is essential for property-testing the happens-before invariant:

      for every pair of messages M1, M2 at any participant:
        M1 hb M2  ⟹  M1 is delivered before M2

  The harness maintains the same conceptual "network" as the real stack but
  with a controllable message queue:

  - `causal_send/4` drives `handle_causal_send` on the sender's core and
    enqueues the resulting `:transmit` effects.
  - `deliver_one/1` pops the front of the queue and drives `handle_net` on
    the recipient's core, collecting `:deliver` effects.
  - `drain/1` delivers all queued messages in FIFO order.

  Reordering the queue between `deliver_one` calls lets you test arbitrary
  delivery schedules without races.

  ## Usage

      h = Causal.Harness.new([:a, :b, :c])
      h = Causal.Harness.causal_send(h, :a, :b, "msg")
      h = Causal.Harness.drain(h)
      assert Causal.Harness.delivered(h, :b) == [{:a, "msg"}]

  ## Happens-before property scaffold

  The harness is the intended home for the eventual property test:

      # For every random topology and delivery schedule, for every participant p,
      # M1 hb M2 ⟹ delivered(p) lists M1 before M2.
      #
      # TODO: add this property once the real causal core is implemented. It will
      # reuse this harness unchanged — swap :protocol to the real module.
  """

  defstruct [:nodes, :queue, :delivered, :protocol]

  @type id :: term()
  @type wire :: term()
  @type pending :: {from :: id(), to :: id(), wire :: wire()}

  @type t :: %__MODULE__{
          nodes: %{id() => term()},
          queue: [pending()],
          delivered: %{id() => [{from :: id(), payload :: term()}]},
          protocol: module()
        }

  @doc """
  Create a harness with the given participant ids using `protocol` as the core.
  Defaults to `Causal.Protocol.Passthrough`.
  """
  @spec new([id()], module()) :: t()
  def new(ids, protocol \\ Causal.Protocol.Passthrough) do
    %__MODULE__{
      nodes: Map.new(ids, fn id -> {id, protocol.init(id, [])} end),
      queue: [],
      delivered: Map.new(ids, fn id -> {id, []} end),
      protocol: protocol
    }
  end

  @doc """
  Trigger a causal send from `from` to `to` with `payload`.
  Drives `handle_causal_send` on the sender's core and enqueues any resulting
  `:transmit` effects at the back of the queue.
  """
  @spec causal_send(t(), id(), id() | [id()], term()) :: t()
  def causal_send(%__MODULE__{} = h, from, to, payload) do
    core = Map.fetch!(h.nodes, from)
    {new_core, effects} = h.protocol.handle_causal_send(core, to, payload)

    %{h | nodes: Map.put(h.nodes, from, new_core)}
    |> enqueue_transmits(from, effects)
  end

  @doc """
  Deliver the front message in the queue. Drives `handle_net` on the
  recipient's core. Raises if the queue is empty.
  """
  @spec deliver_one(t()) :: t()
  def deliver_one(%__MODULE__{queue: []}), do: raise("Causal.Harness queue is empty")

  def deliver_one(%__MODULE__{queue: [{from, to, wire} | rest]} = h) do
    core = Map.fetch!(h.nodes, to)
    {new_core, effects} = h.protocol.handle_net(core, from, wire)

    %{h | queue: rest, nodes: Map.put(h.nodes, to, new_core)}
    |> collect_deliveries(to, effects)
    |> enqueue_transmits(to, effects)
  end

  @doc "Deliver all queued messages in FIFO order."
  @spec drain(t()) :: t()
  def drain(%__MODULE__{queue: []} = h), do: h
  def drain(h), do: h |> deliver_one() |> drain()

  @doc """
  Returns the deliveries at `id` as `{from, payload}` pairs, in delivery order.
  """
  @spec delivered(t(), id()) :: [{id(), term()}]
  def delivered(%__MODULE__{delivered: d}, id), do: Map.get(d, id, [])

  @doc "Number of messages currently waiting in the queue."
  @spec pending_count(t()) :: non_neg_integer()
  def pending_count(%__MODULE__{queue: q}), do: length(q)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp enqueue_transmits(h, from, effects) do
    new_msgs =
      for {:transmit, to_id_or_ids, wire_msg} <- effects,
          to_id <- List.wrap(to_id_or_ids) do
        {from, to_id, wire_msg}
      end

    %{h | queue: h.queue ++ new_msgs}
  end

  defp collect_deliveries(h, to, effects) do
    new_deliveries = for {:deliver, from_id, payload} <- effects, do: {from_id, payload}
    existing = Map.get(h.delivered, to, [])
    %{h | delivered: Map.put(h.delivered, to, existing ++ new_deliveries)}
  end
end
