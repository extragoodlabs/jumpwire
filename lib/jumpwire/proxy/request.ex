defmodule JumpWire.Proxy.Request do
  @moduledoc """
  This module defines the structure and main functions for working with proxied requests. Requests in this
  format are abstracted from their source protocol, and as such only a limited subset of information is available.
  """

  use TypedStruct
  alias JumpWire.Proxy.SQL.Field

  typedstruct enforce: true do
    field :update, [Field.t()], default: []
    field :select, [Field.t()], default: []
    field :delete, [Field.t()], default: []
    field :insert, [Field.t()], default: []
    field :upstream, JumpWire.Manifest.t(), enforce: false
    field :source, any(), default: nil
  end

  def put_field(request, type, field) do
    Map.update!(request, type, fn existing ->
      [field | existing]
    end)
  end

  def put_fields(request, type, fields) do
    Map.update!(request, type, fn existing ->
      fields ++ existing
    end)
  end
end
