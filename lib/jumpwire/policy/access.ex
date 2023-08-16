defmodule JumpWire.Policy.Access do
  @moduledoc """
  Allow client access to the record, skipping any blocking policies.
  """

  @behaviour JumpWire.Policy

  @impl true
  def handle(record, _, _, _) do
    {{:skip, :block}, record}
  end
end
