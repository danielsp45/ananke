defmodule Ananke.Transport.Partisan.Listener do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_), do: {:ok, %{}}

  @impl GenServer
  def handle_info({:ananke_net, from_id, to_id, wire_msg}, state) do
    case Registry.lookup(Ananke.Registry, to_id) do
      [{pid, _}] -> send(pid, {:net, from_id, wire_msg})
      [] -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
