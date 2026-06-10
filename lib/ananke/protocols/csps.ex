defmodule Ananke.CSPS do
  @moduledoc """
  Causal delivery core implementing CSPS + FIFO unicast (Algorithm 1, §5.4).

  Combines Conservative Sender Permission to Send (CSPS) with per-stream FIFO
  ordering to guarantee causal delivery: if m1 happens-before m2, every
  participant that delivers both delivers m1 before m2.

  Sentinel decision (§10.1 Option B): clock starts at 0, `:none` is the
  no-predecessor sentinel for `ls`, `ld`, and the first message's `pid`.

  Wire terms (opaque to shell/transport):
    `{:msg, %WireMsg{}}` | `{:ack, n}` | `{:permit, n}`
  """

  @behaviour Ananke.Protocol

  alias Ananke.{SlidingArray, SlidingMap}

  # ---------------------------------------------------------------------------
  # Structs
  # ---------------------------------------------------------------------------

  defmodule State do
    @enforce_keys [:ck, :u, :p, :ls, :ld, :sb, :rb]
    defstruct [:ck, :u, :p, :ls, :ld, :sb, :rb]
  end

  # Send-buffer entry: per_depends is integer (= p.next at causal_send time).
  defmodule SendMsg do
    @enforce_keys [:rcv, :mid, :pid, :per_depends, :pl]
    defstruct [:rcv, :mid, :pid, :per_depends, :pl]
  end

  # Wire / unacked entry: per is boolean (receiver must add to its permit queue).
  defmodule WireMsg do
    @enforce_keys [:rcv, :mid, :pid, :per, :pl]
    defstruct [:rcv, :mid, :pid, :per, :pl]
  end

  # Receive-buffer entry.
  defmodule Rcv do
    @enforce_keys [:mid, :pl, :per]
    defstruct [:mid, :pl, :per]
  end

  # ---------------------------------------------------------------------------
  # Protocol callbacks
  # ---------------------------------------------------------------------------

  @impl Ananke.Protocol
  def init(_id, _opts) do
    %State{
      ck: 0,
      u: SlidingArray.new(),
      p: SlidingMap.new(),
      ls: %{},
      ld: %{},
      sb: :queue.new(),
      rb: %{}
    }
  end

  @impl Ananke.Protocol
  def handle_causal_send(%State{} = state, dest, payload) do
    m = %SendMsg{
      rcv: dest,
      mid: state.ck,
      pid: Map.get(state.ls, dest, :none),
      per_depends: SlidingMap.next(state.p),
      pl: payload
    }

    state = %{state |
      ls: Map.put(state.ls, dest, state.ck),
      ck: state.ck + 1,
      sb: :queue.in(m, state.sb)
    }

    try_send(state, [])
  end

  @impl Ananke.Protocol
  def handle_net(%State{} = state, from, wire) do
    case wire do
      {:msg, %WireMsg{} = m} -> receive_msg(state, from, m)
      {:ack, n} -> receive_ack(state, from, n)
      {:permit, n} -> receive_permit(state, from, n)
    end
  end

  @impl Ananke.Protocol
  def handle_tick(%State{} = state) do
    retransmits =
      for {_i, m} <- SlidingArray.entries(state.u), m.pl != :bottom do
        {:transmit, m.rcv, {:msg, m}}
      end

    ack_pokes =
      for {{snd, mid}, _idx} <- SlidingMap.entries(state.p) do
        {:transmit, snd, {:ack, mid}}
      end

    {state, retransmits ++ ack_pokes}
  end

  # ---------------------------------------------------------------------------
  # Private handlers
  # ---------------------------------------------------------------------------

  defp receive_msg(%State{} = state, from, %WireMsg{} = m) do
    ld_j = Map.get(state.ld, from, :none)

    if ld_j != :none and m.mid <= ld_j do
      {state, [{:transmit, from, {:ack, m.mid}}]}
    else
      rcv = %Rcv{mid: m.mid, pl: m.pl, per: m.per}
      e = state.rb |> Map.get(from, %{}) |> Map.put(m.pid, rcv)
      drain_rb(%{state | rb: Map.put(state.rb, from, e)}, from, [])
    end
  end

  # Deliver contiguous run from rb[from] starting at ld[from].
  defp drain_rb(%State{} = state, from, effects) do
    ld_j = Map.get(state.ld, from, :none)
    e = Map.get(state.rb, from, %{})

    case Map.fetch(e, ld_j) do
      :error ->
        {state, effects}

      {:ok, b} ->
        p =
          if b.per,
            do: elem(SlidingMap.add(state.p, {from, b.mid}), 1),
            else: state.p

        state = %{state |
          rb: Map.put(state.rb, from, Map.delete(e, ld_j)),
          ld: Map.put(state.ld, from, b.mid),
          p: p
        }

        drain_rb(state, from, effects ++ [{:transmit, from, {:ack, b.mid}}, {:deliver, from, b.pl}])
    end
  end

  defp receive_ack(%State{} = state, from, n) do
    if n < SlidingArray.first(state.u) do
      {state, [{:transmit, from, {:permit, n}}]}
    else
      m = SlidingArray.at(state.u, n)
      u = SlidingArray.put(state.u, n, %{m | pl: :bottom})
      state = %{state | u: u}

      if n == SlidingArray.first(state.u) do
        sweep_u(state, [])
      else
        {state, []}
      end
    end
  end

  # Remove the acked front of u, then sweep past any already-acked entries,
  # emitting a permit each time a needs-permit entry becomes the oldest unacked.
  defp sweep_u(%State{} = state, effects) do
    {_, u} = SlidingArray.remove(state.u)
    sweep_u_loop(%{state | u: u}, effects)
  end

  defp sweep_u_loop(%State{} = state, effects) do
    if SlidingArray.size(state.u) == 0 do
      {state, effects}
    else
      m = SlidingArray.peek(state.u)
      effects = if m.per, do: effects ++ [{:transmit, m.rcv, {:permit, m.mid}}], else: effects

      if m.pl != :bottom do
        {state, effects}
      else
        {_, u} = SlidingArray.remove(state.u)
        sweep_u_loop(%{state | u: u}, effects)
      end
    end
  end

  defp receive_permit(%State{} = state, from, n) do
    p = SlidingMap.remove(state.p, {from, n})
    try_send(%{state | p: p}, [])
  end

  # Release head of sb as long as all permits it depends on have arrived.
  defp try_send(%State{} = state, effects) do
    case :queue.out(state.sb) do
      {:empty, _} ->
        {state, effects}

      {{:value, send_m}, rest} ->
        if SlidingMap.first(state.p) < send_m.per_depends do
          {state, effects}
        else
          wire_m = %WireMsg{
            rcv: send_m.rcv,
            mid: send_m.mid,
            pid: send_m.pid,
            per: SlidingArray.size(state.u) > 0,
            pl: send_m.pl
          }

          {_, u} = SlidingArray.add(state.u, wire_m)
          state = %{state | sb: rest, u: u}
          try_send(state, effects ++ [{:transmit, wire_m.rcv, {:msg, wire_m}}])
        end
    end
  end
end
