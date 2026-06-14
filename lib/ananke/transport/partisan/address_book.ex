defmodule Ananke.Transport.Partisan.AddressBook do
  use GenServer

  @table :ananke_address_book

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Register a local id, mapping it to the current node."
  def register(id) do
    put(id, node())
  end

  @doc "Map a remote id to a node name."
  def put(id, node_name) do
    :ets.insert(@table, {id, node_name})
    :ok
  end

  @doc "Register a remote id and establish a Partisan connection to its node."
  def connect(id, node_name, opts) do
    put(id, node_name)
    partisan_join(node_name, opts)
  end

  @doc "Look up the node name for an id."
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, node_name}] -> {:ok, node_name}
      [] -> :error
    end
  end

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    load_static_peers()
    {:ok, %{}}
  end

  defp load_static_peers do
    peers = Application.get_env(:ananke, :peers, [])

    Enum.each(peers, fn {id, opts} ->
      node_name = Keyword.fetch!(opts, :node)
      put(id, node_name)
      partisan_join(node_name, opts)
    end)
  end

  defp partisan_join(node_name, _opts) when node_name == node(), do: :ok

  defp partisan_join(node_name, opts) do
    ip = Keyword.fetch!(opts, :ip)
    port = Keyword.fetch!(opts, :port)

    node_spec = %{
      name: node_name,
      listen_addrs: [%{ip: ip, port: port}],
      channels: :partisan_config.channels()
    }

    :partisan_peer_service.join(node_spec)
  end
end
