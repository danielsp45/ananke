defmodule Ananke.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children = [{Registry, keys: :unique, name: Ananke.Registry}]
    Supervisor.start_link(children, strategy: :one_for_one, name: Ananke.Supervisor)
  end
end
