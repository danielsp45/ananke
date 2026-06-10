<p align="center">
  <img src=".github/logo.png" alt="Ananke" width="100%"/>
</p>

---

Ananke is an Elixir library that guarantees **causal delivery** of messages between participants — both intra-node and inter-node. If message `m1` causally precedes message `m2`, no participant will ever deliver `m2` before `m1`.

Causal ordering is strictly stronger than the per-sender FIFO the BEAM already provides, but avoids the global coordination cost of total order. It is the strongest ordering that remains spatially scalable.

## The algorithm

Ananke implements the algorithm from:

> Paulo Sérgio Almeida. *Space-Optimal, Computation-Optimal, Topology-Agnostic, Throughput-Scalable Causal Delivery through Hybrid Buffering.* INESC TEC & University of Minho, 2026. [arXiv:2601.11487](https://arxiv.org/abs/2601.11487).

### Why this algorithm?

Classic causal-delivery algorithms (RST, KS) attach per-message metadata describing its entire causal history — `O(n)` overhead for broadcast, up to `O(n²)` for general unicast. Topology-exploiting approaches (spanning trees, causal separators) escape that cost, but only by assuming a fixed communication structure and needing reconfiguration on failure.

Almeida's algorithm achieves all of the following simultaneously:

| Property | What it means |
|---|---|
| **Topology-agnostic** | Correct over any communication graph; no overlay, no spanning tree |
| **Space-optimal** | Effectively constant metadata per message, regardless of participant count |
| **Computation-optimal** | Amortized constant time per message, via purpose-built sliding data structures |
| **Throughput-scalable** | Pipelining: multiple messages in transit per pair; throughput scales with compute, not latency |
| **Fault-tolerant** | Correct under message loss, duplication, and reordering |

The tradeoff it accepts is delivery latency — it is not latency-optimal.

### Core idea: CSPS + FIFO ⟹ Causal

Instead of tagging every message with its causal history, the algorithm uses **hybrid buffering**:

- **Sender-side:** enforces **CSPS** (Conservative Sender Permission to Send). A message is not released to the network until all causally prior messages — from any sender — have been delivered. The sender learns this through `ack` and `permit` control messages.
- **Receiver-side:** enforces **FIFO** per sender by chaining each message to its per-destination predecessor, allowing pipelining without blocking.

The paper proves that FIFO + CSPS together imply causal delivery. Because the ordering is enforced by *when messages are released*, each message carries only `O(1)` metadata — no causal-history tags.

Ananke implements **Algorithm 1 (CSPS)** from the paper as its first strategy. A second, lower-latency strategy (Algorithm 2, SPS-optimal) is planned and will be a drop-in replacement behind the same API.

## Usage

Add to your dependencies:

```elixir
def deps do
  [
    {:ananke, "~> 0.1.0"}
  ]
end
```

### Sidecar form

Start an endpoint for each participant and use `Ananke.send/3` to send:

```elixir
{:ok, _} = Ananke.start_link(id: :alice)
{:ok, _} = Ananke.start_link(id: :bob, owner: self())

Ananke.send(:alice, :bob, "hello")

receive do
  {:causal, from, payload} ->
    IO.inspect({from, payload})
end
```

### Native endpoint form

Define a module that hosts both the protocol state and your own state:

```elixir
defmodule MyWorker do
  use Ananke.Endpoint

  @impl Ananke.Endpoint
  def handle_deliver(from, payload, state) do
    {:noreply, Map.update(state, :inbox, [payload], &[payload | &1])}
  end
end

{:ok, _} = MyWorker.start_link(id: :worker)
Ananke.send(:worker, :worker, :echo)
```

### Options

| Option | Default | Description |
|---|---|---|
| `:id` | required | Stable logical identifier for this participant |
| `:owner` | calling process | PID that receives `{:causal, from, payload}` deliveries |
| `:transport` | `Ananke.Transport.Local` | Transport module (implements `Ananke.Transport`) |
| `:protocol` | `Ananke.Passthrough` | Protocol core module (implements `Ananke.Protocol`) |
| `:tick_ms` | `200` | Retransmission tick interval in ms; `0` to disable |

To enable causal ordering, pass `protocol: Ananke.CSPS`. The default `Ananke.Passthrough` is a straight pass-through for testing the stack in isolation.

## Delivery semantics

`Ananke.send/3` is a fire-and-forget cast — it returns `:ok` immediately and never blocks. The library guarantees that if `m1` happened-before `m2` (i.e., a participant delivered `m1` before causal-sending `m2`, or sent `m1` before `m2` to the same destination), then every participant that receives both will deliver `m1` first.

A restarted endpoint with the same `:id` begins with fresh protocol state and is causally a new participant. Protocol state is not persisted.

## Reference

```bibtex
@misc{almeida2026spaceoptimalcomputationoptimaltopologyagnosticthroughputscalable,
  title={Space-Optimal, Computation-Optimal, Topology-Agnostic, Throughput-Scalable Causal Delivery through Hybrid Buffering},
  author={Paulo Sérgio Almeida},
  year={2026},
  eprint={2601.11487},
  archivePrefix={arXiv},
  primaryClass={cs.DC},
  url={https://arxiv.org/abs/2601.11487},
}
```
