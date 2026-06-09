defmodule Causal.Transport.Local do
  @moduledoc """
  Same-node transport. Resolves a logical participant id to a pid via
  `Causal.Registry` and sends `{:net, from_id, wire_msg}` to that process.

  If `to_id` is not registered (destination not yet started or already stopped),
  the message is silently dropped — consistent with the fair-loss model the
  protocol core expects.
  """

  @behaviour Causal.Transport

  @impl Causal.Transport
  def send_wire(from_id, to_id, wire_msg) do
    case Registry.lookup(Causal.Registry, to_id) do
      [{pid, _}] -> Kernel.send(pid, {:net, from_id, wire_msg})
      [] -> :ok
    end

    :ok
  end
end
