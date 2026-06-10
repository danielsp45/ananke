defmodule Ananke.Transport do
  @moduledoc """
  Behaviour for moving a wire message from one participant to another.

  The transport is the **only** layer that knows how to resolve a logical
  participant id to a network address or local pid. The shell and the protocol
  core are entirely unaware of this resolution — that is what makes
  `Ananke.send/3` work identically whether the peer is local or remote.

  Implementations must NOT impose ordering guarantees beyond fair-loss eventual
  delivery ("if messages keep being sent, eventually some gets through"). The
  protocol core handles reliability and ordering itself.
  """

  @doc """
  Deliver `wire_msg` (opaque to the transport) from `from_id` to `to_id`.

  Resolves `to_id` to a destination and hands off the message. Must return
  `:ok` without blocking — delivery is best-effort. If `to_id` cannot be
  resolved, drop silently.
  """
  @callback send_wire(from_id :: term(), to_id :: term(), wire_msg :: term()) :: :ok
end
