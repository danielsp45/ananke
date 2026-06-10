# CSPS Causal Delivery — Basic Unicast Algorithm

Reference for the **basic CSPS + FIFO unicast** causal-delivery algorithm (Algorithm 1 in Almeida, 2026, §5.4), **plus the concrete plan for integrating it into Ananke**. This is the algorithm to implement first.

Out of scope here (separate variants, same correctness skeleton):
- **SPS-optimal** algorithm (§5.6) — lower latency, unified buffer + four index variables, indexable sliding map.
- **Multicast** (§5.7) — `dest` becomes a set; cannot be simulated by repeated unicasts.

The document has two halves: **Part A (§1–8)** is the algorithm reference (transport-agnostic). **Part B (§9–14)** is the Ananke-specific implementation plan — where it slots, the decisions already locked, the data-structure work, and the test strategy.

---

# Part A — Algorithm reference

## 1. The guarantee

**Causal delivery:** for any process that delivers both `m1` and `m2`, if `m1` happens-before `m2` then it delivers `m1` before `m2`.

**Happens-before (hb)** over *application* messages is the transitive closure of:
1. `m1 hb m2` if `m1` was **delivered** at a process before that process **causal-sent** `m2`.
2. `m1 hb m2` if the same process **causal-sent** `m1` before `m2`.

Only causal-send and deliver events matter — not network-send or receive. The relation is defined by *delivery-then-send*, and the guarantee only constrains the order of deliveries **at a common receiver**: a predecessor that goes to a different process imposes no constraint on delivery here.

---

## 2. Strategy: CSPS + FIFO ⟹ Causal

The algorithm combines two independently-enforced properties.

**FIFO** (per ordered sender→receiver pair): a receiver delivers a given sender's messages in the order that sender sent them.

**CSPS — Conservative Sender Permission to Send:** a process only **network-sends** a message `m` once **all messages that happened before `m`, sent by any process that sent messages to it, have been delivered.** (CSPS is the conservative instantiation of the more general SPS; the SPS-optimal variant relaxes it.)

The paper proves CSPS + FIFO ⟹ Causal. Intuition: FIFO handles same-sender predecessors; CSPS, applied transitively along any causality path, guarantees cross-sender predecessors are already delivered everywhere before a dependent message is released.

Two control-message types implement CSPS:

- **ack** — the receiver confirms it delivered a message. Acks let a sender learn its earlier messages have landed. An ack carries the message's own id `n`, which is the sender's clock value — so the sender looks it up by **direct array index** (no translation).
- **permit** — granted by the *sender of `m`* to the *receiver of `m`*, telling the receiver "everything I sent before `m` is now delivered, so you may build causally-dependent messages on `m`." A message flagged *needs-permit* may be **delivered** immediately, but the receiver must **hold any causally-dependent message it sends** until the permit arrives. Permits arrive identified by a foreign key `(sender, mid)`, so the receiver needs a **key→index map** to file them — hence the sliding map.

---

## 3. State and message types

```
Msg = {                      # one record reused for send-buffer, unacked buffer, and wire
  rcv : process_id           # receiver
  mid : int                  # message id (this process's clock value)
  pid : int                  # predecessor id: last message THIS process sent to rcv (FIFO link)
  per : int | bool           # DUAL MEANING — see §6. In send-buffer: permit index depended on.
                             #                 On the wire / unacked: boolean "needs a permit".
  pl  : payload | ⊥          # ⊥ once acked (slot kept for ordering, payload dropped)
}

Per = { snd : process_id, mid : int }      # a missing-permit entry; the permit's foreign key

Rcv = { mid : int, pl : payload, per : bool }   # a received-but-not-yet-delivered message
```

```
State (process i):
  ck : int                     # clock: assigns the next message id
  u  : SlidingArray[Msg]       # UNACKED messages, indexed directly by mid
  p  : SlidingMap[Per]         # MISSING permits, keyed by (snd, mid), ordered by local permit index
  ls : map[process_id -> int]  # last message id sent to each destination (default: bottom)
  ld : map[process_id -> int]  # last message id delivered from each sender (default: bottom)
  sb : list[Msg]               # FIFO send-buffer (plain queue; not a sliding structure here)
  rb : map[process_id -> map[int -> Rcv]]   # receive buffer: sender -> (predecessor id -> Rcv)
```

`u` and the clock **share one index space** (`u` is indexed by `mid`). `p` has its own, independent index space (local permit order). Unmapped map keys read as bottom.

---

## 4. Handlers

Pseudocode in `{state, effects}` form: instead of sending, each handler **emits** `{:transmit, to, wire}` and `{:deliver, from, payload}` effects, in order. (Renderings are mine; paper line numbers given for cross-checking.)

### causal_send(j, payload) — lines 37–43
```
m = Msg{ rcv=j, mid=ck, pid=ls[j], per=p.next, pl=payload }
ls[j] = ck                     # remember this as the FIFO predecessor for the next msg to j
ck    = ck + 1
sb.add(m)                      # enqueue (non-blocking; returns immediately)
try_send()
```
`per = p.next` records that `m` depends on **every permit owed so far** (all permit indices `< p.next`).

### try_send() — lines 28–36
```
while sb not empty:
  m = sb.peek
  if p.first < m.per:          # a permit m depends on is still missing
    return                     # head can't go ⇒ (FIFO) nothing behind it can either
  sb.remove()
  m.per = (u.size > 0)         # REASSIGN per to a boolean: does this send need a follow-up permit?
  u.add(m)                     # record unacked at index m.mid
  emit {:transmit, m.rcv, m}   # network-send
```
Called after `causal_send` and after `receive permit`. The gate `p.first < m.per` means: the oldest still-missing permit has an index below what `m` depends on ⇒ wait.

### receive(j, msg, m) — lines 44–56
```
if m.mid <= ld[j]:                       # duplicate of an already-delivered message
  emit {:transmit, j, ack(m.mid)}        # re-ack anyway (a prior ack may have been lost)
  return                                 # (paper writes b.mid here — typo for m.mid)
e = rb[j]
e[m.pid] = Rcv(m)                        # file by predecessor id; idempotent on duplicate
while ld[j] in keys(e):                  # is the successor of the last delivered present?
  b = e.remove(ld[j])
  ld[j] = b.mid
  if b.per:                              # sender flagged this as needing a permit
    p.add(Per{snd=j, mid=b.mid})         # we now owe a permit before building on b
  emit {:transmit, j, ack(b.mid)}
  emit {:deliver, j, b.pl}               # deliver in causal order
```
FIFO is reconstructed by chaining on `pid`: deliver only the message whose predecessor is the one just delivered, looping to drain any run that became contiguous.

### receive(j, ack, n) — lines 57–70
```
if n < u.first:                          # already acked & removed
  emit {:transmit, j, permit(n)}         # send permit anyway (idempotent; prior one may be lost)
  return
u[n].pl = ⊥                              # mark acked: drop payload, keep the ordering slot
if n == u.first:                         # oldest unacked just got acked → sweep forward
  u.remove()
  while u.size > 0:
    m = u.peek
    if m.per:                            # m is now oldest unacked ⇒ its predecessors all delivered
      emit {:transmit, m.rcv, permit(m.mid)}   # so its permit may be sent
    if m.pl != ⊥:                        # reached the new oldest STILL-unacked → stop
      return
    u.remove()                           # already-acked: discard and keep sweeping
```
A permit for `m` is sent exactly when `m` becomes the oldest unacked — i.e. when every message with a smaller id is acked (= delivered). `m` itself need not be acked: the permit attests `m`'s **predecessors** are delivered.

### receive(j, permit, n) — lines 71–73
```
p.remove(Per{snd=j, mid=n})              # by key; absent ⇒ harmless no-op (tolerates dup/resend)
try_send()
```

### tick() — periodic retransmission, lines 74–79
```
for m in u where m.pl != ⊥:              # unacked payloads: retransmit
  emit {:transmit, m.rcv, m}
for entry in p:                          # each missing permit: poke its sender with an ack
  emit {:transmit, entry.snd, ack(entry.mid)}
```
The second loop is subtle: the sender may have already removed the message from its unacked buffer (so it won't retransmit it), but an ack for an absent id triggers a permit re-send (the `n < u.first` branch above). So the receiver acks to provoke a lost permit's retransmission.

---

## 5. Why it works (sketch)

- **FIFO** (Prop 5.1): each message carries its same-stream predecessor id; a message is delivered only when that predecessor was the last delivered.
- **CSPS** (Prop 5.2): a flagged sent message creates a missing-permit entry on delivery; a permit for id `n` is only sent once every smaller id is acked (hence delivered); a buffered message is released only once all permits it depends on are in. Together: a message is network-sent only when all happened-before messages from contributing senders are delivered.
- **Liveness** (Lemmas 5.3–5.4, Prop 5.5): every unacked message is eventually delivered and acked (retransmission + always-ack-even-duplicates); every missing permit is eventually received (ack-poke triggers re-send); so no buffered message waits forever.

---

## 6. Implementation notes & traps

**(1) Bottom-sentinel trap — read this first.** The paper starts `ck` at 0 and defaults integer maps to 0. That makes the **first message of every stream get lost**: its `mid = 0`, the receiver's `ld[j]` defaults to `0`, and the duplicate check `m.mid <= ld[j]` becomes `0 <= 0` → true → the first message is dropped as a "duplicate." The predecessor link also collapses (`pid = 0` is indistinguishable from "no predecessor = 0"). Fix by making the *no-message* sentinel genuinely distinct from every real id. Two equivalent options:
  - **Start `ck` at 1** and reserve `0` as bottom — *and also start the unacked sliding array `u` at index 1*, because `u` is indexed by `mid` (see note 4). The permits map `p` still starts at 0 (independent index space).
  - **Keep `ck` at 0** and use a dedicated sentinel (`nil` / `:none`, not `0`) for `ls`, `ld`, and the first message's `pid`.

  > **Ananke decision: Option B** (`ck = 0`, `:none` sentinel). See §10.1 for the rationale — it requires no change to `SlidingArray`, and `:none` is a valid Elixir map key so the `rb` delivery loop works directly.

  Either way: "nothing yet" must never equal a valid message id.

**(2) The `per` field has two different meanings.** While a message sits in the send-buffer, `per` is an **integer** — the permit index the message depends on (`p.next` at causal-send time). At network-send it is **overwritten with a boolean** — whether the send needs a follow-up permit (`u.size > 0`). The wire/unacked copy carries the boolean; the receiver reads it as a boolean. Model this explicitly; don't let one field's two meanings blur. (Ananke models it as two distinct representations — see §11.)

**(3) Single clock, per-destination FIFO.** Ids come from one process-wide clock regardless of destination, but FIFO is enforced per ordered pair by chaining each message to the **last message sent to that same destination** (`ls[j]`), carried as `pid`. Consecutive messages to `j` may have non-consecutive `mid`s; the `pid` link is what orders them at `j`.

**(4) `u` indexed by id; `p` needs a map.** Acks carry the sender's own clock id, which is directly the index into `u` — O(1), no translation. Permits carry a foreign `(snd, mid)` key from another process's id space, with no relation to local order — so `p` must be a sliding **map** with a key→index translation. This asymmetry is the whole reason there are two different data structures.

**(5) No window, no backpressure, unbounded buffers.** There is no capacity parameter `W` and no fixed-size buffer. `sb`, `u`, `rb`, and `p` grow as needed. Never cap them, never block or refuse a send because "too many in flight," never use ring/modular indexing. The "unlimited messages in transit" property is a feature of this algorithm.

**(6) `sb` is a plain FIFO queue here.** Because CSPS releases messages strictly in causal-send order, the send-buffer is an ordinary queue and `try_send` only ever inspects its head. (Only the SPS-optimal variant must abandon this for a unified buffer, because there the send order diverges from the causal-send order.)

  > **Ananke decision:** back `sb` with Erlang `:queue` (or a two-list amortized queue), **not** a plain list with tail-append — appending to a list tail is O(n) and silently breaks the amortized-constant claim. Only head peek/remove and tail add are ever used.

**(7) Idempotency is mandatory — it's the unreliable-network tolerance.** Do not treat these as optional edge cases: re-ack already-delivered duplicates; overwrite (don't append) when a duplicate lands in `rb`; re-send a permit on an ack for an already-removed id; treat removing an absent permit as a no-op. The fault-injection tests will exercise every one of these.

**(8) Effect ordering.** Preserve the order effects are emitted within a handler, especially `:deliver` effects — they must surface in the order the loop delivers them.

---

## 7. Mapping to the pure core

| Handler | Core function | Typical effects emitted |
|---|---|---|
| causal_send | `handle_causal_send(state, dest, payload)` | `{:transmit, rcv, wire}` (0+) |
| receive msg/ack/permit | `handle_net(state, from, wire)` | `{:deliver, from, pl}`, `{:transmit, to, wire}` |
| tick | `handle_tick(state)` | `{:transmit, to, wire}` (retransmits) |

`wire` is opaque to the shell and transport; only the core builds and reads it. The shell executes the returned effects in order and stores the new state. Keep the core pure — no sockets, no processes — so it runs under the deterministic simulator against the happens-before oracle.

---

# Part B — Ananke integration plan

## 8. Where it lands

CSPS is a new `Ananke.Protocol` implementation — **`Ananke.CSPS`** — sitting beside `Ananke.Passthrough`. It satisfies the same behaviour (`init/2`, `handle_causal_send/3`, `handle_net/3`, `handle_tick/1`) and the same `{state, effects}` contract, so:

- The endpoint (`Ananke.Endpoint`, `Ananke.Endpoint.Server`), the transport layer, and the public `Ananke` API are **untouched**.
- It is selected via the `:protocol` option (`protocol: Ananke.CSPS`).
- It is driven and verified through the existing `Ananke.Harness`.

`Ananke.Passthrough` stays as the trivial, no-ordering baseline for exercising the stack/transport independently of the algorithm. `Ananke.CSPS` becomes the default once proven.

The core needs **no knowledge of its own participant id**: every reply is addressed to the incoming `from` (or to `m.rcv`, which is carried in the message), so `init/2` may ignore `id` exactly as `Passthrough` does (keep it only for debug logging).

## 9. Fit check against the existing data structures

Cross-checking the algorithm against the structures already built:

- **`SlidingMap` semantics are exactly right for `p`.** The permit gate `p.first < m.per` relies on `first` being the *minimum present index*, advancing only when the front entry is removed (gaps from out-of-order permit removal must NOT advance `first`). That is precisely `SlidingMap`'s defined behaviour.
- **`u` fills contiguously.** Because `ck` increments by exactly 1 per `causal_send` and `sb` releases strictly in causal-send order, messages enter `u` in increasing, gap-free `mid` order — so `u.add` lands each message at index `= mid`. No arbitrary-index insertion is needed for adds (only `put` for the `pl = ⊥` mark on ack).

## 10. Decisions locked before coding

### 10.1 Sentinel: Option B (`ck = 0`, `:none` sentinel)
- `ls`, `ld` default to `:none`; a first message's `pid = :none`.
- Requires **zero change** to `SlidingArray`: both the clock and `u` start at 0, consistently.
- `:none` is a valid map key, so the `rb` delivery loop (`ld[j] in keys(e)`) works directly — the first message (`pid = :none`) is found under key `:none`, delivered, and then `ld[j]` becomes a real id.
- Duplicate check becomes: `ld[j] != :none and m.mid <= ld[j]`.

### 10.2 `sb` = `:queue`
- Erlang `:queue` (amortized O(1) head-remove / tail-add). Never a plain list with `++`.

## 11. Wire & state model (Elixir)

**Wire terms** (opaque tagged tuples; only `Ananke.CSPS` builds/reads them):
- `{:msg, %Msg{}}` — fields `rcv, mid, pid, per (boolean), pl`
- `{:ack, n}`
- `{:permit, n}`

**The `per` dual meaning — modelled as two distinct representations, never one mutated field:**
- Send-buffer entry carries `per_depends :: integer` (`= p.next` at causal-send time).
- When `try_send` releases it, it builds a *separate* wire/`u` `%Msg{}` whose `per :: boolean` (`= u.size > 0`).

Because Elixir is immutable you construct a new struct on release anyway — so make the type change explicit rather than reusing one field name for both meanings.

**`Ananke.CSPS.State`:**

| Field | Type | Notes |
|---|---|---|
| `ck` | `integer` | clock, starts at 0 |
| `u` | `Ananke.SlidingArray` | unacked, indexed by `mid` |
| `p` | `Ananke.SlidingMap` | missing permits, keyed by `{snd, mid}` |
| `ls` | `map` | last id sent to each dest, default `:none` |
| `ld` | `map` | last id delivered from each sender, default `:none` |
| `sb` | `:queue` | FIFO send-buffer |
| `rb` | `map → map` | sender → (`pid` → `%Rcv{}`) |

`try_send` is a private helper returning `{state, effects}`, shared by `handle_causal_send` and the `permit` branch of `handle_net`.

## 12. Data-structure work to do first (close before CSPS)

`tick/1` iterates whole structures, which neither currently exposes. Add and test these **before** starting CSPS, so a `tick` bug can't masquerade as an algorithm bug:

- **`SlidingArray`**: an enumeration over live elements `[first, next)` — for `for m in u where m.pl != ⊥` (retransmit loop). E.g. `entries/1` or `reduce/3`.
- **`SlidingMap`**: an enumeration over present entries — for `for entry in p` (ack-poke loop). E.g. `values/1` or `entries/1`.

Both get their own unit + property tests.

## 13. Test strategy

The `Ananke.Harness` needs three extensions to exercise CSPS:

1. **`tick(h, id)`** — drive `handle_tick` for a node (currently absent).
2. **Fault injection** — drop / duplicate / reorder queued messages. The queue is a plain list, so: reorder = permute, drop = filter, dup = re-enqueue. This is what exercises the §6.7 idempotency requirements.
3. **Quiescence driver** — alternate deliver/tick until no node has pending queue entries or unacked/unpermitted state, for liveness assertions.

Properties (from `context.md` §6):

- **Safety (the centerpiece).** Track the happens-before relation as the run executes (delivery-then-send and send-then-send edges); assert each participant's delivery order respects `hb`. Reusable verbatim as the SPS oracle later.
- **Liveness.** After quiescence: every causal-sent message delivered exactly once; no starvation under adversarial interleavings (the Cykas failure mode).
- **Fault tolerance.** Re-run safety + liveness with loss/dup/reorder injected.

Finally, run the existing endpoint integration tests against `protocol: Ananke.CSPS` — they assert ordered delivery and should pass unchanged, now actually *guaranteeing* the order rather than getting it incidentally from `Passthrough`.

## 14. Build sequence

1. Add + test `entries`/`values` enumeration on `SlidingArray` and `SlidingMap`.
2. Lock §10 decisions in code scaffolding (sentinel `:none`, `sb` = `:queue`).
3. Define `Msg`, `Rcv`, wire terms, and `Ananke.CSPS.State`.
4. Implement the four handlers, with `try_send` as a shared private helper; keep the core pure.
5. Extend `Ananke.Harness`: `tick`, fault injection, quiescence driver.
6. Build the hb oracle + safety / liveness / fault property suites.
7. Select `Ananke.CSPS` as `:protocol`; re-run endpoint integration tests.
8. **Ship.** SPS-optimal (Algorithm 2) follows as a second strategy behind the same behaviour, validated against CSPS as oracle on identical tests.

---

## 15. Reference

- Almeida, P. S. (2026). *Space-Optimal, Computation-Optimal, Topology-Agnostic, Throughput-Scalable Causal Delivery through Hybrid Buffering.* arXiv:2601.11487. (INESC TEC & University of Minho.) — Algorithm 1, §5.4.
- See `context/context.md` for the project-level architecture, milestones, and invariants.
