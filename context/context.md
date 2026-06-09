# Project Context

> A causal-delivery library for Elixir / the BEAM, providing causally-ordered
> message delivery between processes — both intra-node and inter-node — based on
> the topology-agnostic, hybrid-buffering SPS+FIFO algorithm of Almeida (2026).

This document is the high-level orientation for the project: what it is, why it
exists, the core ideas it rests on, and the intended architecture. It is meant
to be the first thing a new contributor (human or agent) reads.

---

## 1. What we are building

A library that guarantees **causal delivery** of messages between participants:
if message `m1` causally precedes message `m2` (Lamport's happened-before), then
no participant delivers `m2` before `m1`. Causal order is the sweet spot in the
ordering hierarchy — strictly stronger than FIFO, but without the global
coordination cost of total order — and it is the strongest ordering that remains
spatially scalable.

The library targets two deployment scopes with a single API:

- **Intra-machine**: causally-ordered delivery between processes on the same
  BEAM node.
- **Inter-machine**: causally-ordered delivery between processes across a
  network of BEAM nodes.

### What "causal delivery" means here (and what it is NOT)

This is a **runtime ordering guarantee**, enforced by the messaging layer, not
an after-the-fact analysis feature. It must not be confused with:

- **Causality *tracking*** (e.g. recording a cause→effect graph for audit /
  observability, as some event-bus libraries do). That records relationships
  after delivery; it does not constrain delivery order.
- **FIFO ordering.** The BEAM already gives per-sender-pair FIFO for free. FIFO
  says nothing about messages from *different* senders. Causal delivery repairs
  exactly the cross-sender, transitive case that FIFO does not cover.

The contract we enforce, stated precisely, is:

> For any participant that delivers both `m1` and `m2`:
> `m1 hb m2  ⟹  deliver(m1) occurs before deliver(m2)`.

where `hb` (happened-before, restricted to application messages) is the
transitive closure of:
1. `m1 hb m2` if a process **delivers** `m1` before it **causal-sends** `m2`;
2. `m1 hb m2` if a process **causal-sends** `m1` before it **causal-sends** `m2`.

### Why this is worth building

There is no maintained, documented, Elixir-native library that provides causal
*delivery* middleware. The ecosystem has clock primitives (vector clocks,
version vectors), and CRDT/distribution libraries (DeltaCrdt, Horde,
Phoenix.Tracker, Partisan) that track causality *internally* to converge state —
but none expose a general-purpose, causally-ordered transport for arbitrary
messages. Partisan contains an experimental, undocumented causal backend, which
underlines the gap rather than filling it.

---

## 2. The algorithm we are implementing

We implement the algorithm from:

> Paulo Sérgio Almeida. *Space-Optimal, Computation-Optimal, Topology-Agnostic,
> Throughput-Scalable Causal Delivery through Hybrid Buffering.* INESC TEC &
> University of Minho, 2026. arXiv:2601.11487.

### Why this algorithm

Classic receiver-buffering algorithms (RST, KS) tag every message with metadata
describing its causal past. That metadata is `O(n)` for broadcast and up to
`O(n²)` for the general unicast/multicast case — prohibitive at the scale of
thousands of participants. Topology-exploiting approaches (spanning trees, causal
separators) avoid the metadata but are tied to a specific communication
structure and need reconfiguration on failure.

Almeida's algorithm is:

- **Topology-agnostic** — correct over *any* communication graph; makes no
  assumption about who talks to whom, needs no overlay, no tree, no separators.
- **Space-optimal** — effectively **constant** metadata per message in transit,
  independent of the number of participants. Per-process state grows only with
  in/out-degree (the peers a process actually talks to), never with the global
  participant count.
- **Computation-optimal** — amortized effectively constant time per message,
  via carefully designed data structures.
- **Throughput-scalable** — allows pipelining (multiple messages in transit per
  pair), so aggregated throughput scales with compute rather than being capped
  by network latency.
- Tolerant of an **asynchronous, unreliable network**: messages may be lost,
  duplicated, and reordered.

The tradeoff it accepts is **delivery latency** (it is not latency-optimal). It
is the right choice when throughput and per-message processing cost matter more
than the latency of any individual message — and the only topology-agnostic
choice that scales to very large participant counts.

### Core idea: SPS + FIFO ⟹ Causal

Rather than buffering only at the receiver, the algorithm uses **hybrid
buffering**:

- **Sender-buffering** to enforce **SPS** (Sender Permission to Send): a process
  delays *releasing* a message to the network until it is safe — i.e. until the
  causal predecessors it depends on have been delivered at their destinations.
  Safety is signalled by `permit` control messages.
- **Receiver-buffering** to enforce **FIFO** per sender, allowing pipelining
  (so the sender need not wait for one message to be acked before sending the
  next).

The key theorem: **FIFO + SPS ⟹ causal delivery.** Because causality is enforced
by *when messages are released*, the messages themselves carry only `O(1)`
metadata, and there is no per-message causal-history tag.

### Two variants — implementation order

The paper gives two enforcement strategies with the **same external contract**
and the **same correctness property**:

1. **CSPS (Conservative SPS), Algorithm 1** — the simple, elegant base. Uses a
   FIFO send-buffer, a separate unacked sliding-array, and a missing-permits
   sliding-map. Network-send order equals causal-send order.
2. **SPS-optimal, Algorithm 2** — relaxes three of CSPS's conservative
   conditions to improve delivery latency. Network-send order **no longer
   coincides** with causal-send order, requiring a *unified buffer*, four
   incremental index variables (`m1`, `m2`, `p2`, `u2`), and an *indexable*
   sliding map to preserve amortized-constant computation.

**We implement CSPS first, then SPS.** CSPS is a complete, correct, shippable
library on its own; SPS is a drop-in second strategy behind the same behaviour.
CSPS also serves as a **correctness oracle** for SPS: any execution where SPS
delivers in an order CSPS would not is a bug.

---

## 3. High-level architecture

The design is built around a clean separation between **ordering** (the
algorithm) and **transport/topology** (the network). The algorithm's
topology-agnosticism is what makes this separation not just possible but
elegant — the topology becomes a free variable we can set for performance
without touching correctness.

```
┌─────────────────────────────────────────────────────────────┐
│  Application                                                  │
│    causal_send(participant, payload)   →   deliver(payload)   │
└───────────────┬───────────────────────────────▲──────────────┘
                │                                │
┌───────────────▼───────────────────────────────┴──────────────┐
│  Causal Delivery Core            (the algorithm)              │
│                                                               │
│   • Strategy: CSPS (Algorithm 1)  →  later SPS (Algorithm 2)  │
│   • Receiver-buffering → FIFO  (rb, ld, pid-chaining)         │
│   • Sender-buffering   → SPS   (send/unacked buffer, permits) │
│   • ack / permit control messages, periodic retransmission    │
│   • Data structures: SlidingArray, SlidingMap (+ indexable)   │
│                                                               │
│   Requires from the layer below ONLY:                         │
│     fair-loss eventual delivery between any pair that retries │
│   (tolerates loss / duplication / reordering itself)          │
└───────────────┬───────────────────────────────▲──────────────┘
                │  send(participant_id, ctrl/msg) │  receive(...)
┌───────────────▼───────────────────────────────┴──────────────┐
│  Transport behaviour          (pluggable seam)               │
│    @callback send(to_participant, message)                    │
│    @callback members() / monitoring / participant registry    │
│                                                               │
│   Implementations:                                            │
│     • LocalTransport      (intra-node, BEAM message passing)  │
│     • DistErlTransport    (inter-node, distributed Erlang)    │
│     • PartisanTransport    ◄── topology / overlay layer       │
└───────────────────────────────┬───────────────────────────────┘
                                 │
┌────────────────────────────────▼──────────────────────────────┐
│  Partisan          (membership + topology + routing)          │
│    full-mesh │ client-server │ HyParView (partial view)        │
│    failure detection, channels, node-level message forwarding  │
└────────────────────────────────────────────────────────────────┘
```

### Layer responsibilities

| Layer | Owns | Does NOT own |
|---|---|---|
| Causal Delivery Core | **Ordering** — FIFO + SPS, buffers, permits, acks, retransmission, dedup | Membership, routing, topology |
| Transport behaviour | Getting a message to a named participant; exposing membership/monitor events | Ordering guarantees |
| Partisan | **Topology** — overlay shape, node membership, failure detection, node-to-node routing | Causal ordering, process-level addressing |

---

## 4. Where Partisan fits — exploiting it for the topology layer

The central architectural bet: **the algorithm handles ordering; Partisan
handles topology.** Because the algorithm is topology-agnostic, the choice of
overlay is purely a performance/deployment decision and does not affect
correctness. This lets us:

- Select an overlay at runtime to match the deployment — full mesh for small
  clusters, client-server for a star/datacenter shape, HyParView for large /
  high-churn / partial-view scenarios that exceed disterl's ~60–200 node ceiling.
- Get **membership and failure detection** for free, feeding the participant
  registry and informing retransmission/cleanup.
- Run a clean **evaluation**: fix the algorithm, vary only the Partisan overlay,
  measure throughput/latency. (Performance evaluation is the open problem the
  paper itself flags as future work.)

### What we rely on Partisan for — and what we explicitly do NOT

The algorithm was *designed* to need very little from the transport. We depend on
Partisan for exactly two things:

1. **Topology / membership / failure detection** — the overlay shape, who is in
   the cluster, and notification when nodes join/leave/fail.
2. **Fair-loss eventual delivery** — "if messages keep being sent between two
   processes, eventually some message gets through." This is the *only* delivery
   guarantee the algorithm's liveness needs.

We deliberately do **NOT** rely on Partisan for:

- **Ordering.** The algorithm enforces FIFO itself (per-pair `pid`-chaining at
  the receiver), at the correct *participant-pair* granularity. Partisan's
  ordering is per *node*/*channel* and is the wrong granularity; depending on it
  would couple correctness to channel configuration. Corollary: it is safe to
  spread different participant-pairs across channels for parallelism, but a
  single pair's correctness must never depend on which channel its messages took.
- **Exactly-once / no-duplication.** The algorithm is idempotent against
  duplicates; Partisan need not guarantee this.
- **Reliable (TCP) delivery as a correctness crutch.** The algorithm's own
  ack/retransmission layer provides reliability. Leaning on TCP reliability
  re-imports the very costs the paper avoids (head-of-line blocking across
  causally-unrelated messages; silent byte loss on TCP reconnection). The
  unreliable-network model is what keeps the door open to lighter transports.

### The integration seam: participant model vs node model

The one genuine bridge to build. The algorithm operates on **participants**
(globally-unique ids; may be added over time; state sized by in/out-degree, not
global N). Partisan operates on **nodes** (BEAM nodes in the overlay). Many
participants live on one node.

So the `PartisanTransport` must maintain a **participant registry / addressing
layer** on top of Partisan's node routing:

```
send(participant_j, message)
   → resolve participant_j → hosting node N        (registry)
   → forward to N over the overlay                  (Partisan)
   → on N, demux to the right participant process   (registry)
   → invoke that participant's receive handler      (Core)
```

Partisan's membership and monitoring events keep this registry current as
participants and nodes come and go. This addressing/demux layer is the concrete
place where Almeida's process model meets Partisan's node model, and it is the
main piece of "glue" the project must design explicitly.

---

## 5. Build order (milestones)

Correctness-first, with the transport seam defined early so topology work slots
in without a rewrite.

1. **Data structures** — `SlidingArray`, `SlidingMap` (and the indexable
   variant), standalone, with property tests and benchmarks confirming amortized
   behavior. A bug here masquerades as an algorithm bug, so verify in isolation
   first. *(Note: the paper assumes mutable in-place arrays à la Rust `smallvec`;
   the BEAM has no such thing. Whether the amortized-constant claims survive on
   functional/persistent structures vs `:ets`/`:atomics` is both an
   implementation decision and an interesting sub-result. v1 goes functional;
   revisit when chasing throughput.)*
2. **FIFO receiver-buffering** — `rb`, `ld`, `pid`-chaining, delivery loop.
   Shared verbatim by both CSPS and SPS; build once.
3. **Transport behaviour + `LocalTransport`** — define the pluggable seam and
   prove the core end-to-end intra-node. Establishes the participant registry
   abstraction.
4. **CSPS (Algorithm 1)** — send-buffer, unacked sliding-array, missing-permits
   sliding-map, ack/permit handling, periodic retransmission. Full property-test
   suite for **safety** (`m1 hb m2 ⟹ deliver order`) and **liveness** (every
   causal-sent message eventually delivered; no starvation — the property where
   prior sender-buffering algorithms like Cykas fail). **Ship this.**
5. **Inter-node transport** — `DistErlTransport`, then `PartisanTransport` with
   the participant↔node addressing layer. Overlay becomes a config choice.
6. **SPS-optimal (Algorithm 2)** — unified buffer, four index variables,
   indexable sliding map, the three relaxations. Validate against CSPS as oracle
   on identical tests. Ship as a second strategy behind the same behaviour.
7. **Evaluation** — fix algorithm, vary Partisan overlay; measure throughput and
   latency at scale. Addresses the paper's stated open problem.

---

## 6. Key invariants & properties to test

- **Safety (causal delivery):** for every participant, `m1 hb m2` implies
  `deliver(m1)` before `deliver(m2)`.
- **FIFO:** messages from the same sender are delivered in causal-send order
  (predecessor `pid` is the last-delivered from that sender at delivery time).
- **Liveness:** every causal-sent message is eventually delivered; no starvation
  under any interleaving (the Cykas failure mode).
- **Fault tolerance:** correctness preserved under message loss, duplication,
  and reordering (idempotent handling of `msg`/`ack`/`permit`; retransmission of
  unacked messages and missing permits).
- **Metadata:** per-message metadata is `O(1)` (independent of participant
  count); per-process state depends only on in/out-degree + in-flight counts.

---

## 7. Glossary

- **causal-send / deliver** — the two application-visible events. `network-send`
  and `receive` are internal protocol events.
- **SPS / CSPS** — Sender Permission to Send; the conservative variant CSPS only
  network-sends a message once all messages that happened-before it (from any
  process that sent to this one) have been delivered.
- **permit** — control message granting a sender permission to release a
  subsequent message to the network.
- **ack** — control message confirming a message was delivered at its receiver.
- **sliding array / sliding map** — the amortized-constant-time data structures
  underpinning the unacked buffer and missing-permits tracking.
- **participant** — a protocol process with a globally-unique id (the
  algorithm's "process"). Distinct from a **node** (a BEAM node in the Partisan
  overlay).
- **topology-agnostic** — correctness does not depend on the communication
  graph; the overlay is a free performance variable.

---

## 8. Reference

- Almeida, P. S. (2026). *Space-Optimal, Computation-Optimal, Topology-Agnostic,
  Throughput-Scalable Causal Delivery through Hybrid Buffering.* arXiv:2601.11487.
  (INESC TEC & University of Minho.)
- Lamport, L. (1978). *Time, Clocks, and the Ordering of Events in a Distributed
  System.* CACM 21(7).
- Raynal, Schiper, Toueg (1991); Kshemkalyani & Singhal (1998) — classic
  receiver-buffering (RST, KS) for contrast.
- Mattern & Fünfrocken (1994, MF); Tong & Kuper (2024, Cykas) — prior
  sender-buffering, whose limitations this algorithm overcomes.
- Meiklejohn & Miller (2018). *Partisan: Enabling Cloud-Scale Erlang
  Applications.* — the topology/transport substrate.
