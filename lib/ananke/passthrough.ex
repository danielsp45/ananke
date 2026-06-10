defmodule Ananke.Passthrough do
  @moduledoc """
  Reference protocol core with **no ordering guarantees**.

  Every causal-send immediately emits a `:transmit` effect; every received wire
  message immediately emits a `:deliver` effect. There is no buffering, no
  metadata, and no causal ordering — messages are passed straight through.

  This exists solely to let the full stack (endpoint, transport, public API,
  `use Ananke.Endpoint` macro) run and be tested independently of the real
  algorithm. The happens-before invariant is NOT satisfied; do not use
  `Passthrough` in production.

  The real ordering algorithm will satisfy the same `Ananke.Protocol` contract
  and can be swapped in via the `:protocol` option without touching the shell,
  transport, or application code.
  """

  @behaviour Ananke.Protocol

  @impl Ananke.Protocol
  def init(_id, _opts), do: %{}

  @impl Ananke.Protocol
  def handle_causal_send(state, dest, payload) do
    {state, [{:transmit, dest, payload}]}
  end

  @impl Ananke.Protocol
  def handle_net(state, from, wire_msg) do
    {state, [{:deliver, from, wire_msg}]}
  end

  @impl Ananke.Protocol
  def handle_tick(state), do: {state, []}
end
