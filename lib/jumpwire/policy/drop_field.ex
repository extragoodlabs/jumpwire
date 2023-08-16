defmodule JumpWire.Policy.DropField do
  @moduledoc """
  Nilify a field or set of fields in a record.
  """

  require Logger

  @behaviour JumpWire.Policy

  @impl true
  def handle(record, matches, _policy, _request) do
    paths = Map.keys(matches)
    record = JumpWire.Record.delete_paths(record, paths)
    {:cont, record}
  end
end
