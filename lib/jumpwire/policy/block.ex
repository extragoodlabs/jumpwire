defmodule JumpWire.Policy.Block do
  @moduledoc """
  Prevent the record from being passed to the client.
  """

  @behaviour JumpWire.Policy

  @impl true
  def handle(_, _, _, _) do
    {:halt, :blocked}
  end
end
