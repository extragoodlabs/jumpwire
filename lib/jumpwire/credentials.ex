defmodule JumpWire.Credentials do
  @moduledoc """
  Context module for handling CRUD operations on credentials.
  """

  alias JumpWire.Manifest
  alias JumpWire.Metastore
  alias JumpWire.Proxy.Storage
  require Logger

  @proxy_types Manifest.proxy_types()

  @type db_config() :: Manifest.t() | Metastore.t() | map()
  @type result() :: {:ok, db_config()} | {:error, any()}

  @doc """
  Take literal connection credentials and store them in the configured secret store.
  """
  @spec store(Storage.db_config()) :: result()
  def store(db_config) do
    case db_config do
      %Manifest{root_type: type} when type in @proxy_types ->
        _store(db_config)

      %Metastore{configuration: %Metastore.PostgresqlKV{}} ->
        _store(db_config)

      _ ->
        {:ok, db_config}
    end
  end

  defp _store(%{credentials: nil}), do: {:error, :invalid}
  defp _store(db_config) do
    case JumpWire.Proxy.fetch_secrets_module() do
      {:ok, mod} ->
        mod.store_credentials(db_config)

      _ ->
        Logger.debug("No secret store configured")
        {:ok, db_config}
    end
  end

  @doc """
  Attempt to load the credentials from a configured secret store.
  """
  @spec load(result()) :: result()
  def load({:ok, db_config}) do
    case db_config do
      %Manifest{root_type: type, credentials: nil} when type in @proxy_types ->
        JumpWire.Tracer.context(manifest: db_config.id)
        _load(db_config)

      %Metastore{configuration: %Metastore.PostgresqlKV{}, credentials: nil} ->
        JumpWire.Tracer.context(metastore: db_config.id)
        _load(db_config)

      _ ->
        {:ok, db_config}
    end
  end
  def load(result), do: result

  defp _load(db_config) do
    case JumpWire.Proxy.fetch_secrets_module() do
      {:ok, mod} ->
        mod.load_credentials(db_config)

      _ ->
        Logger.error("No secret store configured, cannot load connection credentials")
        {:error, :not_configured}
    end
  end

  @spec delete(Storage.db_config()) :: result()
  def delete(db_config)  do
    case db_config do
      %Manifest{root_type: type} when type in @proxy_types ->
        _delete(db_config)

      %Metastore{configuration: %Metastore.PostgresqlKV{}} ->
        _delete(db_config)

      _ ->
        {:ok, db_config}
    end
  end

  defp _delete(db_config) do
    case JumpWire.Proxy.fetch_secrets_module() do
      {:ok, mod} ->
        mod.delete_credentials(db_config)
      _ ->
        Logger.debug("No secret store configured")
        {:ok, db_config}
    end
  end
end
