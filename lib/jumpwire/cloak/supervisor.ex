defmodule JumpWire.Cloak.Supervisor do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    children = [
      JumpWire.Cloak.Storage.DeltaCrdt.DiskStorage,
      JumpWire.Cloak.Storage.DeltaCrdt,
      JumpWire.Cloak.KeyRing,
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
