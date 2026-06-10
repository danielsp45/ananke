defmodule Ananke.CSPSTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ananke.{CSPS, Harness}

  defp h(ids), do: Harness.new(ids, CSPS)

  # ---------------------------------------------------------------------------
  # Basic delivery
  # ---------------------------------------------------------------------------

  describe "basic delivery" do
    test "single message is delivered" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, "hello")
      h = Harness.quiesce(h)
      assert Harness.delivered(h, :b) == [{:a, "hello"}]
    end

    test "FIFO: messages from the same sender arrive in send order" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, 1)
      h = Harness.causal_send(h, :a, :b, 2)
      h = Harness.causal_send(h, :a, :b, 3)
      h = Harness.quiesce(h)
      assert Harness.delivered(h, :b) == [{:a, 1}, {:a, 2}, {:a, 3}]
    end

    test "bidirectional messaging" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, :ping)
      h = Harness.causal_send(h, :b, :a, :pong)
      h = Harness.quiesce(h)
      assert Harness.delivered(h, :b) == [{:a, :ping}]
      assert Harness.delivered(h, :a) == [{:b, :pong}]
    end

    test "all messages eventually delivered after quiescence" do
      h = h([:a, :b, :c])
      h = Harness.causal_send(h, :a, :b, :ab1)
      h = Harness.causal_send(h, :a, :c, :ac1)
      h = Harness.causal_send(h, :b, :c, :bc1)
      h = Harness.causal_send(h, :c, :a, :ca1)
      h = Harness.quiesce(h)
      assert length(Harness.delivered(h, :b)) == 1
      assert length(Harness.delivered(h, :c)) == 2
      assert length(Harness.delivered(h, :a)) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Causal ordering
  # ---------------------------------------------------------------------------

  describe "causal ordering" do
    test "classic scenario: B delivers A→B then sends to C; C gets A→C before B→C" do
      # A sends m1 to C first, then m2 to B (m2.per=true because A.u already has m1).
      # B delivering m2 adds {a, m2.mid} to B.p, blocking B's send of m3.
      # Only after C acks m1 does A sweep and send the permit to B, unblocking m3.
      h = h([:a, :b, :c])
      h = Harness.causal_send(h, :a, :c, "m1")
      h = Harness.causal_send(h, :a, :b, "m2")

      # Deliver app messages so B has m2 before we trigger B's send.
      h = Harness.deliver_one(h)  # m1 → C
      h = Harness.deliver_one(h)  # m2 → B (per=true, B.p ← {a, m2.mid})

      # B has delivered m2; now sends m3 to C (blocked until permit arrives).
      h = Harness.causal_send(h, :b, :c, "m3")
      h = Harness.quiesce(h)

      assert Harness.delivered(h, :c) == [{:a, "m1"}, {:b, "m3"}]
    end

    test "sender's own messages to different destinations are all delivered" do
      h = h([:a, :b, :c])
      h = Harness.causal_send(h, :a, :b, :first)
      h = Harness.causal_send(h, :a, :c, :second)
      h = Harness.quiesce(h)
      assert Harness.delivered(h, :b) == [{:a, :first}]
      assert Harness.delivered(h, :c) == [{:a, :second}]
    end

    test "causal chain: A→B→C ordering is preserved" do
      h = h([:a, :b, :c])

      h = Harness.causal_send(h, :a, :c, :m1)
      h = Harness.causal_send(h, :a, :b, :m2)

      h = Harness.deliver_one(h)
      h = Harness.deliver_one(h)

      h = Harness.causal_send(h, :b, :c, :m3)

      h = Harness.quiesce(h)

      deliveries_c = Harness.delivered(h, :c)
      m1_idx = Enum.find_index(deliveries_c, &match?({:a, :m1}, &1))
      m3_idx = Enum.find_index(deliveries_c, &match?({:b, :m3}, &1))
      assert m1_idx < m3_idx
    end
  end

  # ---------------------------------------------------------------------------
  # handle_tick retransmission
  # ---------------------------------------------------------------------------

  describe "handle_tick" do
    test "tick with empty state produces no effects" do
      {state, effects} = CSPS.init(:x, []) |> CSPS.handle_tick()
      assert effects == []
      assert state == CSPS.init(:x, [])
    end

    test "tick retransmits when message is lost" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, :msg)

      # Drop the message, then tick A to retransmit.
      h = Harness.drop(h, fn _ -> true end)
      assert Harness.pending_count(h) == 0

      h = Harness.tick(h, :a)
      assert Harness.pending_count(h) == 1

      h = Harness.quiesce(h)
      assert Harness.delivered(h, :b) == [{:a, :msg}]
    end

    test "tick recovers a lost permit via ack-poke" do
      h = h([:a, :b, :c])
      h = Harness.causal_send(h, :a, :c, :m1)
      h = Harness.causal_send(h, :a, :b, :m2)

      h = Harness.deliver_one(h)
      h = Harness.deliver_one(h)
      h = Harness.causal_send(h, :b, :c, :m3)

      # Drain acks, then drop the permit A sends to B.
      h = Harness.drain(h)
      h = Harness.drop(h, fn {_from, to, wire} -> to == :b and match?({:permit, _}, wire) end)

      # B is stuck. Tick B to poke A with an ack, making A resend the permit.
      h = Harness.tick(h, :b)
      h = Harness.quiesce(h)

      deliveries_c = Harness.delivered(h, :c)
      m1_idx = Enum.find_index(deliveries_c, &match?({:a, :m1}, &1))
      m3_idx = Enum.find_index(deliveries_c, &match?({:b, :m3}, &1))
      assert m1_idx < m3_idx
    end
  end

  # ---------------------------------------------------------------------------
  # Fault tolerance
  # ---------------------------------------------------------------------------

  describe "fault tolerance" do
    test "duplicate message delivery is idempotent" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, :once)
      h = Harness.duplicate(h, 0)
      h = Harness.quiesce(h)
      assert Harness.delivered(h, :b) == [{:a, :once}]
    end

    test "reordered messages are still delivered in FIFO order" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, 1)
      h = Harness.causal_send(h, :a, :b, 2)
      h = Harness.causal_send(h, :a, :b, 3)

      h = Harness.reorder(h, &Enum.reverse/1)
      h = Harness.quiesce(h)

      assert Harness.delivered(h, :b) == [{:a, 1}, {:a, 2}, {:a, 3}]
    end

    test "duplicate acks are handled safely" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, :x)
      h = Harness.deliver_one(h)

      ack_idx = Enum.find_index(h.queue, fn {_f, _t, w} -> match?({:ack, _}, w) end)
      h = Harness.duplicate(h, ack_idx)
      h = Harness.quiesce(h)

      assert Harness.delivered(h, :b) == [{:a, :x}]
    end

    test "causal order is preserved even with reversed control messages" do
      h = h([:a, :b, :c])
      h = Harness.causal_send(h, :a, :c, :m1)
      h = Harness.causal_send(h, :a, :b, :m2)
      h = Harness.deliver_one(h)
      h = Harness.deliver_one(h)
      h = Harness.causal_send(h, :b, :c, :m3)

      h = Harness.reorder(h, &Enum.reverse/1)
      h = Harness.quiesce(h)

      deliveries_c = Harness.delivered(h, :c)
      m1_idx = Enum.find_index(deliveries_c, &match?({:a, :m1}, &1))
      m3_idx = Enum.find_index(deliveries_c, &match?({:b, :m3}, &1))
      assert m1_idx != nil and m3_idx != nil
      assert m1_idx < m3_idx
    end
  end

  # ---------------------------------------------------------------------------
  # Harness extension tests
  # ---------------------------------------------------------------------------

  describe "harness extensions" do
    test "tick/2 drives handle_tick without breaking state" do
      h = h([:a, :b])
      h_ticked = Harness.tick(h, :a)
      assert h_ticked.nodes[:a] == h.nodes[:a]
    end

    test "drop/2 removes matching messages from queue" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, :x)
      h = Harness.drop(h, fn {_from, to, _wire} -> to == :b end)
      assert Harness.pending_count(h) == 0
    end

    test "duplicate/2 adds a copy at the queue tail" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, :x)
      h = Harness.duplicate(h, 0)
      assert Harness.pending_count(h) == 2
    end

    test "reorder/2 applies transformation to the queue" do
      h = h([:a, :b])
      h = Harness.causal_send(h, :a, :b, 1)
      h = Harness.causal_send(h, :a, :b, 2)
      h = Harness.reorder(h, &Enum.reverse/1)
      [{_, _, {:msg, m}}] = Enum.take(h.queue, 1)
      # After reverse, the last-added msg (mid=1) is now first in queue.
      assert m.mid == 1
    end

    test "quiesce/1 empties the queue and delivers all messages" do
      h = h([:a, :b, :c])
      h = Harness.causal_send(h, :a, :b, :x)
      h = Harness.causal_send(h, :b, :c, :y)
      h = Harness.quiesce(h)
      assert Harness.pending_count(h) == 0
      assert length(Harness.delivered(h, :b)) == 1
      assert length(Harness.delivered(h, :c)) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  describe "properties" do
    property "FIFO: messages from the same sender arrive in send order" do
      check all msgs <- list_of(term(), min_length: 1, max_length: 10) do
        h = h([:a, :b])

        h = Enum.reduce(msgs, h, fn payload, acc ->
          Harness.causal_send(acc, :a, :b, payload)
        end)

        h = Harness.quiesce(h)

        payloads = h |> Harness.delivered(:b) |> Enum.map(&elem(&1, 1))
        assert payloads == msgs
      end
    end

    property "liveness: all causal-sent messages are eventually delivered" do
      check all msgs <- list_of(term(), min_length: 1, max_length: 8) do
        h = h([:a, :b])

        h = Enum.reduce(msgs, h, fn payload, acc ->
          Harness.causal_send(acc, :a, :b, payload)
        end)

        h = Harness.quiesce(h)
        assert length(Harness.delivered(h, :b)) == length(msgs)
      end
    end

    property "causal safety: A→C messages precede B→C messages at C when causally ordered" do
      # Scenario: A sends to C first, then to B. B delivers A's messages, then
      # sends to C. The CSPS guarantee: every A→C message happens-before every
      # B→C message, so C must deliver all A→C before any B→C.
      check all n_a_c <- integer(1..4),
                n_a_b <- integer(1..4),
                n_b_c <- integer(1..4) do
        # Use tagged payloads so we can identify origin in deliveries.
        a_c_payloads = for i <- 1..n_a_c, do: {:ac, i}
        a_b_payloads = for i <- 1..n_a_b, do: {:ab, i}
        b_c_payloads = for i <- 1..n_b_c, do: {:bc, i}

        h = h([:a, :b, :c])

        h = Enum.reduce(a_c_payloads, h, &Harness.causal_send(&2, :a, :c, &1))
        h = Enum.reduce(a_b_payloads, h, &Harness.causal_send(&2, :a, :b, &1))

        # Deliver all A app messages before B sends to C.
        h = Enum.reduce(1..(n_a_c + n_a_b), h, fn _, acc ->
          Harness.deliver_one(acc)
        end)

        h = Enum.reduce(b_c_payloads, h, &Harness.causal_send(&2, :b, :c, &1))
        h = Harness.quiesce(h)

        assert length(Harness.delivered(h, :c)) == n_a_c + n_b_c
        assert length(Harness.delivered(h, :b)) == n_a_b

        deliveries_c = Harness.delivered(h, :c)

        a_indices =
          deliveries_c
          |> Enum.with_index()
          |> Enum.filter(fn {{_from, pl}, _i} -> match?({:ac, _}, pl) end)
          |> Enum.map(&elem(&1, 1))

        b_indices =
          deliveries_c
          |> Enum.with_index()
          |> Enum.filter(fn {{_from, pl}, _i} -> match?({:bc, _}, pl) end)
          |> Enum.map(&elem(&1, 1))

        for a_idx <- a_indices, b_idx <- b_indices do
          assert a_idx < b_idx,
                 "causal violation: A→C at index #{a_idx} but B→C at #{b_idx}"
        end
      end
    end
  end
end
