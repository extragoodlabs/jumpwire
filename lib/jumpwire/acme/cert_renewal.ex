defmodule JumpWire.ACME.CertRenewal do
  @moduledoc """
  Order a renewal of an ACME generated certificate on a periodic timer.
  """

  use GenServer
  require Logger

  @interval 1000 * 60 * 60 * 24

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: Hydrax.Registry.pid_name(nil, __MODULE__))
  end

  @impl true
  def init(_) do
    state = Application.get_env(:jumpwire, :acme) |> Map.new()
    Process.send_after(self(), :renew_expiring, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:renew_expiring, config) do
    Logger.debug("Checking for certs that should be renewed")
    JumpWire.ACME.renew_expired(config)
    Process.send_after(self(), :renew_expiring, @interval)
    {:noreply, config}
  end
end
