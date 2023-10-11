defmodule JumpWire.SSOBehaviour do
  @callback fetch_active_assertion(Plug.Conn.t()) :: {:ok, any} | :error
end
