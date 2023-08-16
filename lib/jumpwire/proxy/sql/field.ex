defmodule JumpWire.Proxy.SQL.Field do
  @moduledoc """
  Represents a field in a SQL statement.
  """

  use TypedStruct

  typedstruct do
    field :column, String.t, enforce: true
    field :table, String.t
    field :schema, String.t
  end
end
