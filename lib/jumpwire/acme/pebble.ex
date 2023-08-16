defmodule JumpWire.ACME.Pebble do
  @moduledoc """
  Run a local ACME server using Pebble.
  """

  use GenServer
  require Logger

  @wrapper Path.join(:code.priv_dir(:jumpwire), "port-wrapper.sh")

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def binary() do
    System.get_env("GOPATH", "~/go")
    |> Path.expand()
    |> Path.join("bin/pebble")
  end

  defp start_port(pebble) do
    config_file = Path.join(pebble[:path], pebble[:config])

    Port.open({:spawn_executable, @wrapper},
      [:binary, args: [pebble[:binary], "-config", config_file]])
  end

  def init(_args) do
    pebble = Application.get_env(:jumpwire, :pebble, [])
    |> Keyword.put_new(:binary, binary())

    if pebble[:server] do
      {:ok, start_port(pebble)}
    else
      :ignore
    end
  end

  def handle_info({_port, {:data, data}}, state) do
    Logger.debug(data)
    {:noreply, state}
  end

  def handle_info(_data, state) do
    {:noreply, state}
  end
end
