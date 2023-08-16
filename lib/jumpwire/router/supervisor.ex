defmodule JumpWire.Router.Supervisor do
  @moduledoc """
  Supervisor for Plug and Cowboy.
  """

  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(args) do
    opts = Application.get_env(:jumpwire, JumpWire.Router) |> Keyword.merge(args)

    http_child = if opts[:enable_http] do
      [{Plug.Cowboy, scheme: :http, plug: JumpWire.Router, options: opts[:http]}]
    else
      []
    end

    # Specify a dynamic SNI function for HTTPS. This is used to support
    # certificates generated or loaded at runtime from ACME.
    https_child = if opts[:enable_https] do
      https_opts = opts[:https] |> Keyword.put(:sni_fun, &JumpWire.TLS.sni_fun/1)
      [{Plug.Cowboy, scheme: :https, plug: JumpWire.Router, options: https_opts}]
    else
      []
    end

    children = [Samly.Provider | http_child ++ https_child]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start_child(child) do
    Supervisor.start_child(__MODULE__, child)
  end
end
