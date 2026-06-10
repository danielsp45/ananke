# Partisan Integration Plan

Integration of [Partisan v5.0.3](https://partisan.hexdocs.pm) as the inter-machine transport for Ananke, replacing the stub `Transport.UDP` and exposing topology selection alongside the existing protocol selection.

---

## 1. What changes and what does not

**Unchanged:**
- The `Ananke.Protocol` behaviour and all implementations (`Passthrough`, `CSPS`, future `SPS`).
- The endpoint shell (`Ananke.Endpoint`, `Ananke.Endpoint.Server`).
- The `Ananke.Transport` behaviour — it is already the right seam.
- `Transport.Local` — still used for single-node / test scenarios.
- `Ananke.Registry` — still used for local dispatch of inbound messages.
- The public `Ananke.send/3` API.

**New:**
- `Transport.Partisan` — implements `Ananke.Transport`, routes outbound messages via Partisan.
- `Transport.Partisan.Listener` — a GenServer started once per BEAM node that receives inbound Partisan messages and dispatches them locally via `Ananke.Registry`.
- `Transport.Partisan.AddressBook` — a GenServer that maps Ananke logical ids to Partisan node names.
- Partisan added as a mix dependency.
- New `:topology` option on `Ananke.start_link/1` and `use Ananke.Endpoint`.

---

## 2. Partisan background (from docs)

### Messaging
The primary send primitive is:
```erlang
partisan:forward_message(Node, ServerRef, Msg, Opts)
```
- `Node` — the Erlang node name of the destination BEAM node (e.g. `:"alice@192.168.1.1"`).
- `ServerRef` — a registered process name (atom) or remote pid on `Node`.
- `Msg` — an arbitrary Erlang term; Partisan handles serialisation.
- `Opts` — a map or keyword list. Relevant keys: `channel` (which channel to use).

### Node identity
A node advertises itself as a `node_spec`:
```erlang
#{name => node(),               % Erlang node name
  listen_addrs => [#{ip => inet:ip_address(), port => 1..65535}],
  channels => #{channel() => channel_opts()}}
```
`partisan:node_spec/0` returns the local node's spec. Remote peers are joined via
`partisan_peer_service:join(NodeSpec)`.

### Topologies
Set via the `peer_service_manager` application config key:

| Atom | Topology |
|---|---|
| `partisan_pluggable_peer_service_manager` | Full mesh (default) |
| `partisan_hyparview_peer_service_manager` | HyParView partial mesh |
| `partisan_client_server_peer_service_manager` | Star |
| `partisan_static_peer_service_manager` | Static/explicit |

With full mesh and HyParView, `forward_message` is transparent regardless of whether a
direct connection exists — Partisan handles routing. The CSPS algorithm is
topology-agnostic and does not need to know which path a message took.

### Channels
Channels are atoms. Ananke will use the default channel (`partisan:default_channel()`).
Partisan also exposes a `causal_label` forward option and a `partisan_causality_backend`
module, but these are not used here — CSPS is the causal layer.

---

## 3. The address book problem

One BEAM node can host **multiple Ananke logical ids** (e.g. in tests, or when
multiple application-level participants share a node). Partisan addresses at the
BEAM-node level (`node()` atoms), not at the Ananke-id level. Therefore the address
book maps:

```
Ananke logical id  →  Erlang node name
```

The listener on each node uses `Ananke.Registry` to resolve the logical id to a
local pid for final dispatch.

### Address book design

`Transport.Partisan.AddressBook` is a local GenServer backed by an ETS table:

```elixir
# Register a local id (called from Ananke.Endpoint.Server init/1 when transport is Partisan)
AddressBook.register(id)          # maps id → node() (local node name)

# Register a remote peer learned via Partisan membership events or explicit config
AddressBook.put(id, node_name)

# Lookup
AddressBook.get(id) :: {:ok, node()} | :error
```

**Bootstrapping**: when a node joins via Partisan, it needs to tell the cluster which
logical ids it hosts. Two mechanisms are planned (see §7).

---

## 4. `Transport.Partisan`

```elixir
defmodule Ananke.Transport.Partisan do
  @behaviour Ananke.Transport

  @impl Ananke.Transport
  def send_wire(from_id, to_id, wire_msg) do
    case AddressBook.get(to_id) do
      {:ok, node} ->
        partisan.forward_message(
          node,
          Ananke.Transport.Partisan.Listener,   # registered name on every node
          {:ananke_net, from_id, to_id, wire_msg},
          %{channel: :partisan.default_channel()}
        )
      :error ->
        :ok   # silent drop — same contract as Transport.Local
    end
  end
end
```

The wire message envelope is `{:ananke_net, from_id, to_id, wire_msg}`. The inner
`wire_msg` is the opaque CSPS term (unchanged). Partisan serialises the whole tuple.

---

## 5. `Transport.Partisan.Listener`

A single GenServer **registered globally as an atom** via `name: Ananke.Transport.Partisan.Listener`.
This is the `ServerRef` used in `forward_message`. Partisan resolves atom ServerRefs
with `Name ! Message` (Erlang's global atom registration), which is distinct from
Elixir's `Registry` — so the Listener must use the GenServer `:name` option, not
`Registry.register`.

```elixir
def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

def handle_info({:ananke_net, from_id, to_id, wire_msg}, state) do
  case Registry.lookup(Ananke.Registry, to_id) do
    [{pid, _}] -> send(pid, {:net, from_id, wire_msg})
    []         -> :ok
  end
  {:noreply, state}
end
```

`Ananke.Registry` (Elixir's Registry) is still used for all endpoint pids — only
the Listener itself needs global atom registration. The Listener is started by
`Ananke.Application` alongside the Registry.

---

## 6. Topology option

Topology is an application-level concern (Partisan is configured globally per BEAM
node, not per endpoint). The `:topology` option is accepted at `Ananke.start_link/1`
and `use Ananke.Endpoint` for ergonomic configuration, but it is applied once at
application startup via:

```elixir
Application.put_env(:partisan, :peer_service_manager, manager_module)
```

The mapping from user-facing atom to Partisan module:

```elixir
@topologies %{
  full_mesh:     :partisan_pluggable_peer_service_manager,
  hyparview:     :partisan_hyparview_peer_service_manager,
  client_server: :partisan_client_server_peer_service_manager,
  static:        :partisan_static_peer_service_manager
}
```

Default remains `full_mesh`. If `:topology` is not set, Partisan's own default
(`partisan_pluggable_peer_service_manager`) applies.

---

## 7. Peer discovery

Partisan establishes connections via `partisan_peer_service:join(NodeSpec)` where
`NodeSpec` contains the peer's IP and port. It does not do automatic discovery —
someone must know someone else's address first.

**Static config only (current scope).** The operator provides a list of
`{id, node_name, ip, port}` tuples in application config. `AddressBook` is
pre-populated at startup and Partisan joins are issued for each peer.
No dynamic discovery.

```elixir
# config/config.exs
config :ananke, :peers, [
  {alice: [node: :"alice@192.168.1.1", ip: {192,168,1,1}, port: 10100]},
  {bob:   [node: :"bob@192.168.1.2",   ip: {192,168,1,2}, port: 10100]}
]
```

Dynamic discovery (seed-based gossip, Consul, DNS-SD) is out of scope for now.

---

## 8. Dependency and configuration

```elixir
# mix.exs
{:partisan, "~> 5.0"}

# config/config.exs (minimal)
config :partisan,
  peer_service_manager: :partisan_pluggable_peer_service_manager,
  listen_port: 10100      # or omit for random (dev only)
```

Partisan starts its own supervision tree as an OTP application — no changes to
`Ananke.Application` beyond starting the `Listener` and `AddressBook` processes.

---

## 9. Build sequence

1. Add `partisan` dependency; confirm it starts cleanly alongside the existing test suite.
2. Implement `Transport.Partisan.AddressBook` (ETS-backed, static config only).
3. Implement `Transport.Partisan.Listener` and add it to `Ananke.Application`.
4. Implement `Transport.Partisan.send_wire/3`.
5. Add `:topology` option plumbing (start_link → Application.put_env).
6. Integration test: two BEAM nodes on the same machine, static config, CSPS, causal delivery verified end-to-end.
7. Implement seed-based discovery on top of static.
8. Document the `:transport` / `:topology` / `:seed_nodes` option surface.

---

## 10. Open questions

- **Partisan serialisation format**: Partisan docs say it handles serialisation, but
  do not specify the format. Confirm it uses `:erlang.term_to_binary` and that CSPS
  wire structs (Elixir structs with atom keys) survive the round-trip without custom
  encoders.
- **Multiple ids per node in HyParView**: With partial-mesh topologies, Partisan
  routes messages through intermediaries. Confirm the `{:ananke_net, ...}` envelope
  passes through unchanged and is only unwrapped at the final destination node.
