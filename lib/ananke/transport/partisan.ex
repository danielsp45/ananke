defmodule Ananke.Transport.Partisan do
  @behaviour Ananke.Transport

  alias Ananke.Transport.Partisan.{AddressBook, Listener}

  @impl Ananke.Transport
  def send_wire(from_id, to_id, wire_msg) do
    case AddressBook.get(to_id) do
      {:ok, dest_node} when dest_node == node() ->
        case Registry.lookup(Ananke.Registry, to_id) do
          [{pid, _}] -> send(pid, {:net, from_id, wire_msg})
          [] -> :ok
        end

      {:ok, dest_node} ->
        :partisan.forward_message(
          dest_node,
          Listener,
          {:ananke_net, from_id, to_id, wire_msg},
          %{channel: :partisan.default_channel()}
        )

      :error ->
        :ok
    end

    :ok
  end
end
