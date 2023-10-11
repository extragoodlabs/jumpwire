defmodule JumpWire.SSOBehaviour do
  @moduledoc """
  Shared SSO behaviour for JumpWire.
  """

  @callback fetch_active_assertion(Plug.Conn.t()) :: {:ok, any} | :error
end
