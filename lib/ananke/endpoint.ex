defmodule Ananke.Endpoint do
  @moduledoc """
  Behaviour and `use` macro for the native-feeling causal endpoint.

  ## Usage

      defmodule MyApp.Worker do
        use Ananke.Endpoint

        # Optional: provide initial user-level state.
        @impl Ananke.Endpoint
        def handle_init(opts) do
          %{name: Keyword.fetch!(opts, :name)}
        end

        # Required: handle a causally-ordered delivery.
        @impl Ananke.Endpoint
        def handle_deliver(from, payload, state) do
          IO.inspect({from, payload}, label: state.name)
          {:noreply, state}
        end
      end

      # In a supervisor:
      {MyApp.Worker, id: :worker_a, name: "Alice"}

      # Or manually:
      {:ok, _} = MyApp.Worker.start_link(id: :worker_a, name: "Alice")

      # Send from anywhere:
      Ananke.send(:worker_a, :worker_b, "hello")

  ## GenServer options

  Pass standard `GenServer.start_link/3` options (`:name`, `:timeout`, etc.)
  alongside the causal options. They are split automatically.

  ## Causal options

  - `:id` (required) — stable logical identifier for this participant.
  - `:transport` — transport module. Defaults to `Ananke.Transport.Local`.
  - `:protocol` — protocol core module. Defaults to `Ananke.Passthrough`.
  - `:tick_ms` — periodic tick interval in ms. Defaults to `200`.

  ## Adding your own GenServer callbacks

  You can define additional `handle_info/2` and `handle_cast/2` clauses for
  application messages. The generated causal clauses use specific patterns
  (`{:net, _, _}` and `:tick`) that will not conflict with your own patterns.
  Do not add clauses matching those patterns.

  ## Identity and restarts

  A crashed endpoint that restarts with the same `:id` starts with **fresh
  protocol state** and is causally a new participant. Protocol state is never
  persisted across restarts. v1 assumes no process failures.
  """

  @doc """
  Returns the initial user-level state. `opts` is the full keyword list passed
  to `start_link/1`. Override to provide custom initial state; default is `%{}`.
  """
  @callback handle_init(opts :: keyword()) :: term()

  @doc """
  Called once per causally-ordered delivery.

  `from` is the sender's logical id. `payload` is the application payload.
  `state` is the user-level state (as returned by `handle_init/1`).
  Return `{:noreply, new_state}`.
  """
  @callback handle_deliver(from :: term(), payload :: term(), state :: term()) ::
              {:noreply, term()}

  @optional_callbacks [handle_init: 1]

  # ---------------------------------------------------------------------------
  # __using__ macro — generates the combined GenServer in the user's module
  # ---------------------------------------------------------------------------

  defmacro __using__(_opts) do
    quote location: :keep do
      use GenServer
      @behaviour Ananke.Endpoint

      @gs_opts [:name, :timeout, :debug, :spawn_opt, :hibernate_after]

      def start_link(opts) do
        {gs_opts, init_opts} = Keyword.split(opts, @gs_opts)
        GenServer.start_link(__MODULE__, init_opts, gs_opts)
      end

      @impl GenServer
      def init(opts) do
        id = Keyword.fetch!(opts, :id)
        transport = Keyword.get(opts, :transport, Ananke.Transport.Local)
        protocol = Keyword.get(opts, :protocol, Ananke.Passthrough)
        tick_ms = Keyword.get(opts, :tick_ms, 200)

        core_state = protocol.init(id, opts)
        {:ok, _} = Registry.register(Ananke.Registry, id, nil)
        Ananke.Endpoint.schedule_tick(tick_ms)

        cs = %{
          id: id,
          core_mod: protocol,
          core_state: core_state,
          transport: transport,
          tick_ms: tick_ms
        }

        us = handle_init(opts)
        {:ok, {cs, us}}
      end

      @doc false
      def handle_init(_opts), do: %{}
      defoverridable handle_init: 1

      @impl GenServer
      def handle_cast({:causal_send, dest, payload}, {cs, us}) do
        {new_core, effects} = cs.core_mod.handle_causal_send(cs.core_state, dest, payload)
        new_cs = %{cs | core_state: new_core}
        new_us = Ananke.Endpoint.exec_effects(effects, new_cs, us, __MODULE__)
        {:noreply, {new_cs, new_us}}
      end

      @impl GenServer
      def handle_info({:net, from, wire_msg}, {cs, us}) do
        {new_core, effects} = cs.core_mod.handle_net(cs.core_state, from, wire_msg)
        new_cs = %{cs | core_state: new_core}
        new_us = Ananke.Endpoint.exec_effects(effects, new_cs, us, __MODULE__)
        {:noreply, {new_cs, new_us}}
      end

      @impl GenServer
      def handle_info(:tick, {cs, us}) do
        {new_core, effects} = cs.core_mod.handle_tick(cs.core_state)
        new_cs = %{cs | core_state: new_core}
        new_us = Ananke.Endpoint.exec_effects(effects, new_cs, us, __MODULE__)
        Ananke.Endpoint.schedule_tick(cs.tick_ms)
        {:noreply, {new_cs, new_us}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers called from generated code — must be public
  # ---------------------------------------------------------------------------

  @doc false
  def exec_effects(effects, cs, user_state, module) do
    Enum.reduce(effects, user_state, fn
      {:transmit, to_id_or_ids, wire_msg}, us ->
        to_id_or_ids
        |> List.wrap()
        |> Enum.each(&cs.transport.send_wire(cs.id, &1, wire_msg))

        us

      {:deliver, from_id, payload}, us ->
        {:noreply, new_us} = module.handle_deliver(from_id, payload, us)
        new_us
    end)
  end

  @doc false
  def schedule_tick(ms) when ms > 0, do: Process.send_after(self(), :tick, ms)
  def schedule_tick(_), do: :ok
end
