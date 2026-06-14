defmodule Ananke.Endpoint.Server do
  @moduledoc false
  # Internal GenServer backing the sidecar (low-level) form of a causal
  # endpoint. Started via `Ananke.start_link/1`; not part of the public API.
  #
  # State shape:
  #   %{id, core_mod, core_state, owner, transport, tick_ms}
  #
  # The shell contains ZERO ordering logic. It calls the protocol core,
  # executes the returned effects, and nothing else.

  use GenServer

  # ---------------------------------------------------------------------------
  # Public
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    # Capture the caller pid here — self() inside init/1 would be the GenServer.
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start_link(__MODULE__, opts)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    transport = Keyword.get(opts, :transport, Ananke.Transport.Local)
    protocol = Keyword.get(opts, :protocol, Ananke.Passthrough)
    tick_ms = Keyword.get(opts, :tick_ms, 200)
    owner = Keyword.fetch!(opts, :owner)

    core_state = protocol.init(id, opts)
    {:ok, _} = Registry.register(Ananke.Registry, id, nil)

    if transport == Ananke.Transport.Partisan do
      Ananke.Transport.Partisan.AddressBook.register(id)
    end

    schedule_tick(tick_ms)

    {:ok,
     %{
       id: id,
       core_mod: protocol,
       core_state: core_state,
       owner: owner,
       transport: transport,
       tick_ms: tick_ms
     }}
  end

  @impl GenServer
  def handle_cast({:causal_send, dest, payload}, state) do
    {new_core, effects} = state.core_mod.handle_causal_send(state.core_state, dest, payload)
    new_state = %{state | core_state: new_core}
    exec_effects(effects, new_state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:net, from, wire_msg}, state) do
    {new_core, effects} = state.core_mod.handle_net(state.core_state, from, wire_msg)
    new_state = %{state | core_state: new_core}
    exec_effects(effects, new_state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    {new_core, effects} = state.core_mod.handle_tick(state.core_state)
    new_state = %{state | core_state: new_core}
    exec_effects(effects, new_state)
    schedule_tick(state.tick_ms)
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp exec_effects(effects, state) do
    Enum.each(effects, fn
      {:transmit, to_id_or_ids, wire_msg} ->
        to_id_or_ids
        |> List.wrap()
        |> Enum.each(&state.transport.send_wire(state.id, &1, wire_msg))

      {:deliver, from_id, payload} ->
        Kernel.send(state.owner, {:causal, from_id, payload})
    end)
  end

  defp schedule_tick(ms) when ms > 0, do: Process.send_after(self(), :tick, ms)
  defp schedule_tick(_), do: :ok
end
