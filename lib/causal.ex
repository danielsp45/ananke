defmodule Causal do
  @moduledoc """
  Causal-order message delivery between participants.

  ## Sidecar (low-level) form

  Start an endpoint for a participant:

      {:ok, _} = Causal.start_link(id: :alice)
      {:ok, _} = Causal.start_link(id: :bob, owner: self())

  Send from anywhere:

      Causal.send(:alice, :bob, "hello")

  Receive deliveries in the owner process:

      receive do
        {:causal, from, payload} ->
          IO.inspect({from, payload})
      end

  ## Native (`use Causal.Endpoint`) form

  Define a module that hosts both the protocol state and your own state:

      defmodule MyWorker do
        use Causal.Endpoint

        @impl Causal.Endpoint
        def handle_deliver(from, payload, state) do
          {:noreply, Map.update(state, :inbox, [payload], &[payload | &1])}
        end
      end

      {:ok, _} = MyWorker.start_link(id: :worker)
      Causal.send(:worker, :worker, :echo)

  See `Causal.Endpoint` for the full callback reference.

  ## Delivery semantics

  With the default `Causal.Protocol.Passthrough` core there are **no ordering
  guarantees** — it is a straight pass-through for testing the stack. Replace
  `:protocol` with a real causal core to get causal-order delivery.

  ## Note on identity and restarts

  A restarted endpoint with the same `:id` begins with fresh protocol state and
  is causally a new participant. Protocol state is never persisted. v1 assumes
  no process failures.
  """

  @doc """
  Start a causal endpoint for participant `id`.

  The endpoint process is linked to the calling process and registers `id` in
  `Causal.Registry`. It is suitable for use in a supervision tree:

      children = [
        {Causal, id: :alice},
        {Causal, id: :bob, owner: self()}
      ]

  Options:

  - `:id` (required) — stable logical identifier for this participant.
  - `:owner` — pid that receives `{:causal, from, payload}` deliveries.
    Defaults to the **calling process** (captured at `start_link/1` time, not
    inside `init/1`).
  - `:transport` — transport module (implements `Causal.Transport`).
    Defaults to `Causal.Transport.Local`.
  - `:protocol` — protocol core module (implements `Causal.Protocol`).
    Defaults to `Causal.Protocol.Passthrough`.
  - `:tick_ms` — periodic retransmission tick interval in milliseconds.
    Defaults to `200`. Set to `0` to disable.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Causal.Endpoint.Server.start_link(opts)

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Asynchronously send `payload` from `from_id` to `to_id_or_ids`.

  Returns `:ok` immediately — this is a fire-and-forget cast. It never blocks
  and never waits for delivery confirmation. If the application needs a reply,
  it must be implemented as an ordinary application-level message.

  `to_id_or_ids` may be a single id or a list of ids. Multicast over a list
  is forwarded to the protocol core; the core decides how many wire messages
  to emit.

  If `from_id` is not registered (endpoint not started), the call is a no-op.
  """
  @spec send(from_id :: term(), to_id_or_ids :: term() | [term()], payload :: term()) :: :ok
  def send(from_id, to_id_or_ids, payload) do
    case Registry.lookup(Causal.Registry, from_id) do
      [{pid, _}] -> GenServer.cast(pid, {:causal_send, to_id_or_ids, payload})
      [] -> :ok
    end

    :ok
  end
end
