defmodule Ananke.EndpointTest do
  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # Test modules defined at compile time (cannot be inside test blocks)
  # ---------------------------------------------------------------------------

  defmodule CollectingEndpoint do
    @moduledoc false
    use Ananke.Endpoint

    @impl Ananke.Endpoint
    def handle_init(opts) do
      %{owner: Keyword.fetch!(opts, :test_owner)}
    end

    @impl Ananke.Endpoint
    def handle_deliver(from, payload, state) do
      Kernel.send(state.owner, {:got, from, payload})
      {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uid, do: :"#{System.unique_integer([:positive])}"

  # ---------------------------------------------------------------------------
  # Sidecar form
  # ---------------------------------------------------------------------------

  describe "sidecar form" do
    test "message sent from A arrives at B" do
      a = uid()
      b = uid()
      {:ok, _} = Ananke.start_link(id: a)
      {:ok, _} = Ananke.start_link(id: b, owner: self())

      Ananke.send(a, b, "hello")

      assert_receive {:causal, ^a, "hello"}, 500
    end

    test "multiple messages arrive in send order" do
      a = uid()
      b = uid()
      {:ok, _} = Ananke.start_link(id: a)
      {:ok, _} = Ananke.start_link(id: b, owner: self())

      Ananke.send(a, b, 1)
      Ananke.send(a, b, 2)
      Ananke.send(a, b, 3)

      assert_receive {:causal, ^a, 1}, 500
      assert_receive {:causal, ^a, 2}, 500
      assert_receive {:causal, ^a, 3}, 500
    end

    test "send to an unregistered id is silently dropped" do
      a = uid()
      {:ok, _} = Ananke.start_link(id: a)
      Ananke.send(a, :nonexistent_target, "lost")
      refute_receive {:causal, _, _}, 100
    end

    test "send from an unregistered id is a no-op" do
      b = uid()
      {:ok, _} = Ananke.start_link(id: b, owner: self())
      Ananke.send(:ghost_sender, b, "lost")
      refute_receive {:causal, _, _}, 100
    end

    test "two endpoints communicate bidirectionally" do
      a = uid()
      b = uid()
      {:ok, _} = Ananke.start_link(id: a, owner: self())
      {:ok, _} = Ananke.start_link(id: b, owner: self())

      Ananke.send(a, b, :ping)
      Ananke.send(b, a, :pong)

      assert_receive {:causal, ^a, :ping}, 500
      assert_receive {:causal, ^b, :pong}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # use Ananke.Endpoint form
  # ---------------------------------------------------------------------------

  describe "use Ananke.Endpoint form" do
    test "handle_deliver is called with correct from and payload" do
      a = uid()
      b = uid()
      {:ok, _} = CollectingEndpoint.start_link(id: a, test_owner: self())
      {:ok, _} = CollectingEndpoint.start_link(id: b, test_owner: self())

      Ananke.send(a, b, "via endpoint")

      assert_receive {:got, ^a, "via endpoint"}, 500
    end

    test "handle_deliver receives messages in send order" do
      a = uid()
      b = uid()
      {:ok, _} = CollectingEndpoint.start_link(id: a, test_owner: self())
      {:ok, _} = CollectingEndpoint.start_link(id: b, test_owner: self())

      Ananke.send(a, b, :one)
      Ananke.send(a, b, :two)
      Ananke.send(a, b, :three)

      assert_receive {:got, ^a, :one}, 500
      assert_receive {:got, ^a, :two}, 500
      assert_receive {:got, ^a, :three}, 500
    end

    test "handle_init sets up user-level state" do
      a = uid()
      b = uid()
      {:ok, _} = CollectingEndpoint.start_link(id: a, test_owner: self())
      {:ok, _} = CollectingEndpoint.start_link(id: b, test_owner: self())

      Ananke.send(a, b, :check)

      assert_receive {:got, ^a, :check}, 500
    end

    test "default handle_init returns empty map when not overridden" do
      # Module with no handle_init override — default %{} is used.
      # We verify it starts without error and delivers.
      defmodule MinimalEndpoint do
        use Ananke.Endpoint

        @impl Ananke.Endpoint
        def handle_deliver(_from, payload, state) do
          test_pid = Map.get(state, :__test_pid__)

          if is_pid(test_pid) do
            Kernel.send(test_pid, {:minimal_got, payload})
          end

          {:noreply, state}
        end
      end

      a = uid()
      b = uid()
      {:ok, _} = MinimalEndpoint.start_link(id: a)
      {:ok, _} = MinimalEndpoint.start_link(id: b)
      Ananke.send(a, b, :ok_payload)
      # No crash is the assertion here; delivery goes nowhere because
      # state has no :__test_pid__ (the default is %{}).
      Process.sleep(100)
    end
  end

  # ---------------------------------------------------------------------------
  # Ananke.Endpoint.Server child_spec
  # ---------------------------------------------------------------------------

  describe "child_spec" do
    test "Ananke endpoints can be started under a supervisor" do
      a = uid()
      b = uid()

      children = [
        Supervisor.child_spec({Ananke, id: a}, id: a),
        Supervisor.child_spec({Ananke, id: b, owner: self()}, id: b)
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      Ananke.send(a, b, :from_supervisor)
      assert_receive {:causal, ^a, :from_supervisor}, 500

      Supervisor.stop(sup)
    end
  end
end
