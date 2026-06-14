defmodule Ananke do
  @moduledoc """
  Causal-order message delivery between participants.

  ## Sidecar (low-level) form

  Start an endpoint for a participant:

      {:ok, _} = Ananke.start_link(id: :alice)
      {:ok, _} = Ananke.start_link(id: :bob, owner: self())

  Send from anywhere:

      Ananke.send(:alice, :bob, "hello")

  Receive deliveries in the owner process:

      receive do
        {:causal, from, payload} ->
          IO.inspect({from, payload})
      end

  ## Native (`use Ananke.Endpoint`) form

  Define a module that hosts both the protocol state and your own state:

      defmodule MyWorker do
        use Ananke.Endpoint

        @impl Ananke.Endpoint
        def handle_deliver(from, payload, state) do
          {:noreply, Map.update(state, :inbox, [payload], &[payload | &1])}
        end
      end

      {:ok, _} = MyWorker.start_link(id: :worker)
      Ananke.send(:worker, :worker, :echo)

  See `Ananke.Endpoint` for the full callback reference.

  ## Delivery semantics

  With the default `Ananke.Passthrough` core there are **no ordering
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
  `Ananke.Registry`. It is suitable for use in a supervision tree:

      children = [
        {Ananke, id: :alice},
        {Ananke, id: :bob, owner: self()}
      ]

  Options:

  - `:id` (required) — stable logical identifier for this participant.
  - `:owner` — pid that receives `{:causal, from, payload}` deliveries.
    Defaults to the **calling process** (captured at `start_link/1` time, not
    inside `init/1`).
  - `:transport` — transport module (implements `Ananke.Transport`).
    Defaults to `Ananke.Transport.Local`.
  - `:protocol` — protocol core module (implements `Ananke.Protocol`).
    Defaults to `Ananke.Passthrough`.
  - `:tick_ms` — periodic retransmission tick interval in milliseconds.
    Defaults to `200`. Set to `0` to disable.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Ananke.Endpoint.Server.start_link(opts)

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
  @doc """
  Register a remote participant and connect to its node.

  Tells Ananke that `id` lives on `node_name` and establishes a Partisan
  connection to that node. After this call, `Ananke.send/3` can route
  messages to `id` transparently.

  Options:

  - `:ip` (required) — IP address tuple of the remote node, e.g. `{127, 0, 0, 1}`.
  - `:port` (required) — Partisan listen port of the remote node.

  Returns `:ok` on success or `{:error, reason}` if the Partisan join fails.
  No-op if `node_name` is the current node.
  """
  @spec connect(id :: term(), node_name :: node(), keyword()) :: :ok | {:error, term()}
  def connect(id, node_name, opts) do
    Ananke.Transport.Partisan.AddressBook.connect(id, node_name, opts)
  end

  @spec send(from_id :: term(), to_id_or_ids :: term() | [term()], payload :: term()) :: :ok
  def send(from_id, to_id_or_ids, payload) do
    case Registry.lookup(Ananke.Registry, from_id) do
      [{pid, _}] -> GenServer.cast(pid, {:causal_send, to_id_or_ids, payload})
      [] -> :ok
    end

    :ok
  end
end
