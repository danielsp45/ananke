defmodule Causal.HarnessTest do
  use ExUnit.Case, async: true

  alias Causal.Harness

  describe "Passthrough via harness" do
    test "single message is delivered" do
      h = Harness.new([:a, :b])
      h = Harness.causal_send(h, :a, :b, "hello")
      h = Harness.drain(h)
      assert Harness.delivered(h, :b) == [{:a, "hello"}]
    end

    test "multiple messages from same sender arrive in send order" do
      h = Harness.new([:a, :b])
      h = Harness.causal_send(h, :a, :b, 1)
      h = Harness.causal_send(h, :a, :b, 2)
      h = Harness.causal_send(h, :a, :b, 3)
      h = Harness.drain(h)
      assert Harness.delivered(h, :b) == [{:a, 1}, {:a, 2}, {:a, 3}]
    end

    test "bidirectional messaging" do
      h = Harness.new([:a, :b])
      h = Harness.causal_send(h, :a, :b, :ping)
      h = Harness.causal_send(h, :b, :a, :pong)
      h = Harness.drain(h)
      assert Harness.delivered(h, :b) == [{:a, :ping}]
      assert Harness.delivered(h, :a) == [{:b, :pong}]
    end

    test "deliver_one processes one message at a time" do
      h = Harness.new([:a, :b])
      h = Harness.causal_send(h, :a, :b, :first)
      h = Harness.causal_send(h, :a, :b, :second)
      assert Harness.pending_count(h) == 2

      h = Harness.deliver_one(h)
      assert Harness.pending_count(h) == 1
      assert Harness.delivered(h, :b) == [{:a, :first}]

      h = Harness.deliver_one(h)
      assert Harness.pending_count(h) == 0
      assert Harness.delivered(h, :b) == [{:a, :first}, {:a, :second}]
    end

    test "empty harness has no deliveries and no pending" do
      h = Harness.new([:a, :b])
      assert Harness.pending_count(h) == 0
      assert Harness.delivered(h, :a) == []
      assert Harness.delivered(h, :b) == []
    end

    test "drain on empty harness is a no-op" do
      h = Harness.new([:a, :b])
      assert Harness.drain(h) == h
    end

    test "three participants, fan-out" do
      h = Harness.new([:src, :b, :c])
      h = Harness.causal_send(h, :src, :b, :msg)
      h = Harness.causal_send(h, :src, :c, :msg)
      h = Harness.drain(h)
      assert Harness.delivered(h, :b) == [{:src, :msg}]
      assert Harness.delivered(h, :c) == [{:src, :msg}]
    end

    test "deliver_one raises on empty queue" do
      h = Harness.new([:a, :b])
      assert_raise RuntimeError, fn -> Harness.deliver_one(h) end
    end

    test "interleaved sends and delivers" do
      h = Harness.new([:a, :b])
      h = Harness.causal_send(h, :a, :b, :m1)
      h = Harness.deliver_one(h)
      h = Harness.causal_send(h, :a, :b, :m2)
      h = Harness.deliver_one(h)
      assert Harness.delivered(h, :b) == [{:a, :m1}, {:a, :m2}]
    end
  end
end
