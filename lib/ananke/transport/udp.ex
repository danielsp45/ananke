defmodule Ananke.Transport.UDP do
  @moduledoc """
  UDP transport for inter-node communication.

  # TODO(v2): resolve to_id → {host, port} via a distributed participant registry
  # TODO(v2): encode wire_msg (e.g. :erlang.term_to_binary) and send via :gen_udp
  # TODO(v2): start a listener GenServer that receives UDP datagrams, decodes
  #           them, and dispatches {:net, from_id, wire_msg} to the correct
  #           local endpoint via the Registry
  # TODO(v2): handle MTU limits and fragmentation for large wire messages
  """

  @behaviour Ananke.Transport

  @impl Ananke.Transport
  def send_wire(_from_id, _to_id, _wire_msg) do
    # TODO(v2): implement UDP delivery
    :ok
  end
end
