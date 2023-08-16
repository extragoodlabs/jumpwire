defmodule JumpWire.Proxy.Storage do
  @moduledoc """
  Interface definition for modules that implement credential storage.
  """

  @type db_config() :: JumpWire.Manifest.t() | JumpWire.Metastore.t()

  @callback enabled?() :: boolean
  @callback store_credentials(db_config()) :: {:ok, db_config()} | {:error, any}
  @callback load_credentials(db_config()) :: {:ok, db_config()} | {:error, any}
  @callback delete_credentials(db_config()) :: {:ok, db_config()} | {:error, any}
end
