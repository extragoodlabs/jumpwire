defmodule JumpWire.Proxy.SQL do
  @moduledoc """
  Functions that apply to multiple SQL databases.
  """

  alias JumpWire.Manifest
  require Logger

  def enable_table(%Manifest{root_type: :postgresql}, schema) do
    JumpWire.Proxy.Postgres.Setup.enable_table(schema)
  end

  def enable_table(%Manifest{root_type: :mysql}, schema) do
    JumpWire.Proxy.MySQL.Setup.enable_table(schema)
  end

  def enable_table(_, _), do: :ok
end
