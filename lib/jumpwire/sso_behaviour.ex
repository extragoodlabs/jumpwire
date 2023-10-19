defmodule JumpWire.SSO do
  @moduledoc """
  Shared SSO behaviour for JumpWire.
  """

  @callback fetch_active_assertion(Plug.Conn.t()) :: {:ok, any} | :error
  @callback create_client(assertion :: any(), id :: any(), manifest_id :: any()) :: {:ok, any()} | {:error, any()}
end
