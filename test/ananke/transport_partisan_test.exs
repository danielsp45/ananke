defmodule Ananke.Transport.PartisanTest do
  use ExUnit.Case, async: false

  alias Ananke.Transport.Partisan.AddressBook

  # These tests use Transport.Partisan with local endpoints.
  # Both endpoints live on the same BEAM node so send_wire takes the
  # short-circuit path (AddressBook.get → node() == node() → Registry dispatch).
  # This exercises the full AddressBook + transport stack without requiring
  # distributed mode. True multi-node tests require --sname / --name.

  setup do
    alice_id = :"alice_#{System.unique_integer([:positive])}"
    bob_id = :"bob_#{System.unique_integer([:positive])}"

    {:ok, alice} =
      Ananke.start_link(
        id: alice_id,
        owner: self(),
        transport: Ananke.Transport.Partisan,
        protocol: Ananke.CSPS,
        tick_ms: 50
      )

    {:ok, bob} =
      Ananke.start_link(
        id: bob_id,
        owner: self(),
        transport: Ananke.Transport.Partisan,
        protocol: Ananke.CSPS,
        tick_ms: 50
      )

    on_exit(fn ->
      if Process.alive?(alice), do: GenServer.stop(alice)
      if Process.alive?(bob), do: GenServer.stop(bob)
    end)

    %{alice: alice_id, bob: bob_id}
  end

  test "single message is delivered via Partisan transport", %{alice: alice, bob: bob} do
    Ananke.send(alice, bob, :hello)
    assert_receive {:causal, ^alice, :hello}, 500
  end

  test "multiple messages arrive in FIFO order", %{alice: alice, bob: bob} do
    Ananke.send(alice, bob, 1)
    Ananke.send(alice, bob, 2)
    Ananke.send(alice, bob, 3)

    assert_receive {:causal, ^alice, 1}, 500
    assert_receive {:causal, ^alice, 2}, 500
    assert_receive {:causal, ^alice, 3}, 500
  end

  test "bidirectional delivery works", %{alice: alice, bob: bob} do
    Ananke.send(alice, bob, :ping)
    Ananke.send(bob, alice, :pong)

    assert_receive {:causal, ^alice, :ping}, 500
    assert_receive {:causal, ^bob, :pong}, 500
  end

  test "address book maps local ids to current node", %{alice: alice, bob: bob} do
    local = node()
    assert {:ok, ^local} = AddressBook.get(alice)
    assert {:ok, ^local} = AddressBook.get(bob)
  end

  test "address book returns error for unknown id" do
    assert :error = AddressBook.get(:nonexistent_id)
  end

  test "causal ordering: B delivers A's message before forwarding to C", %{alice: alice, bob: bob} do
    c_id = :"charlie_#{System.unique_integer([:positive])}"

    {:ok, charlie} =
      Ananke.start_link(
        id: c_id,
        owner: self(),
        transport: Ananke.Transport.Partisan,
        protocol: Ananke.CSPS,
        tick_ms: 50
      )

    on_exit(fn -> if Process.alive?(charlie), do: GenServer.stop(charlie) end)

    Ananke.send(alice, bob, :a_to_b)
    assert_receive {:causal, ^alice, :a_to_b}, 500

    Ananke.send(bob, c_id, :b_to_c)

    assert_receive {:causal, ^bob, :b_to_c}, 500
  end
end
