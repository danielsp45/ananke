defmodule Causal.Protocol do
  @moduledoc """
  Behaviour contract for the causal-delivery protocol core.

  The core is **pure**: it takes state and an event and returns new state plus a
  list of effects. It never sends messages, never reads the clock, never touches
  the network. All side effects are delegated to the endpoint shell.

  This separation means the core can be driven entirely from a deterministic
  in-memory harness (see `Causal.Harness`) — no processes, no timing — which is
  where property tests for the happens-before invariant live.
  """

  @typedoc """
  Effect returned by a core handler. The endpoint shell executes these in order:

  - `{:transmit, to_id, wire_msg}` — hand `wire_msg` to the transport for
    delivery to `to_id`. `wire_msg` is opaque to the shell and transport; only
    the core constructs and interprets it. `to_id` may be a list for multicast
    (shell iterates).
  - `{:deliver, from_id, payload}` — release `payload` to the application. The
    shell forwards it to the owner (sidecar form) or calls `handle_deliver/3`
    (native form). Effects must be executed in order to preserve delivery
    sequence.
  """
  @type effect ::
          {:transmit, to_id :: term(), wire_msg :: term()}
          | {:deliver, from_id :: term(), payload :: term()}

  @doc "Initialise core state for a participant with the given logical id."
  @callback init(id :: term(), opts :: keyword()) :: state :: term()

  @doc """
  A causal-send was requested by the application.

  Returns updated state and a list of effects. Typically emits one or more
  `:transmit` effects per destination (after applying any sender-side buffering
  the algorithm requires).
  """
  @callback handle_causal_send(state :: term(), dest :: term(), payload :: term()) ::
              {state :: term(), [effect()]}

  @doc """
  A wire message arrived from `from`.

  Returns updated state and effects. May emit `:deliver` effects for payloads
  that are now causally ready to hand to the application, plus `:transmit`
  effects for any control messages (ack, permit) the algorithm emits.
  """
  @callback handle_net(state :: term(), from :: term(), wire_msg :: term()) ::
              {state :: term(), [effect()]}

  @doc """
  Periodic maintenance tick.

  Called by the endpoint on a configurable interval. May emit `:transmit`
  effects for retransmission of unacknowledged messages or missing permits.
  """
  @callback handle_tick(state :: term()) :: {state :: term(), [effect()]}
end
