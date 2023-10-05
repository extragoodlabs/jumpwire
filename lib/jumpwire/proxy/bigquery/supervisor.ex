defmodule JumpWire.Proxy.BigQuery.Supervisor do
  @moduledoc """
  Supervisor for Plug and Cowboy.
  """

  use Supervisor
  require Logger

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(args) do
    opts = Application.get_env(:jumpwire, JumpWire.Proxy.BigQuery) |> Keyword.merge(args)

    children = [
      {Plug.Cowboy, scheme: :http, plug: JumpWire.Proxy.BigQuery.Router, options: opts[:http]},
      # {Plug.Cowboy, scheme: :https, plug: JumpWire.Proxy.BigQuery.Router, options: opts[:https]},
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start_child(child) do
    Supervisor.start_child(__MODULE__, child)
  end
end
