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

    https_opts = opts[:https]
    https_opts =
      if opts[:use_sni] do
        # Specify a dynamic SNI function for HTTPS. This is used to support
        # certificates generated or loaded at runtime from ACME.
        Keyword.put(https_opts, :sni_fun, &JumpWire.TLS.sni_fun/1)
      else
        https_opts
      end

    children = [
      Samly.Provider,
      {Plug.Cowboy, scheme: :http, plug: JumpWire.Router, options: opts[:http]},
      {Plug.Cowboy, scheme: :https, plug: JumpWire.Router, options: https_opts},
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start_child(child) do
    Supervisor.start_child(__MODULE__, child)
  end
end
