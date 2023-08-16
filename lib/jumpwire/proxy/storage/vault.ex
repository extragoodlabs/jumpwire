defmodule JumpWire.Proxy.Storage.Vault do
  @moduledoc """
  Use Vault's dynamic database credentials for connecting to a database.

  Databases can be listed at the `[mount]/config` endpoint. Each database configuration can then
  be read with a call to `[mount]/config/[name]`. A configuration consists of a list of allowed roles,
  a golang templated connection URL, and the database plugin (eg `postgresql-database-plugin`).

  Credentials should only be retrieved when a connection is ready for use. The credentials are typically
  short lived and automatically expire. Expired or almost expired credentials can be rotated without
  breaking the connection.

  JumpWire converts the configuration information into a manifest. This requires parsing the URL, which can be a
  bit brittle, but the only other option is to have the user manually enter a URL in addition to what is in Vault.
  The manifest will not have credentials since those are dynamically created.
  """

  require Logger
  alias JumpWire.Manifest
  alias JumpWire.Metastore

  @behaviour JumpWire.Proxy.Storage

  @renew_path "sys/leases/renew"

  @impl JumpWire.Proxy.Storage
  def enabled?() do
    Application.get_env(:jumpwire, __MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  def client() do
    Application.get_env(:jumpwire, :libvault)
    |> Vault.new()
    |> Vault.set_engine(Vault.Engine.Generic)
    |> Vault.auth()
  end

  def kv_client() do
    with {:ok, vault} <- client() do
      {:ok, Vault.set_engine(vault, Vault.Engine.KVV2)}
    end
  end

  @doc """
  Store the credentials for a manifest in Vault.
  """
  @impl JumpWire.Proxy.Storage
  def store_credentials(db) do
    Logger.debug("Storing database credentials in Vault KV store")
    config_path = kv_path(db.organization_id, db.id)
    with {:ok, vault} <- kv_client(),
         {:ok, _} <- Vault.write(vault, config_path, db.credentials) do
      {:ok, db}
    end
  end

  @doc """
  Fetch credentials from the KV store in Vault. This is used when the credentials were manually
  entered and the role does not have the ability to manage its own password or Vault dopes not have
  connectivity with the database server.
  """
  @impl JumpWire.Proxy.Storage
  def load_credentials(manifest = %Manifest{configuration: %{"vault_database" => db}}) when not is_nil(db) do
    # NB: credentials are dynamically generated when the DB needs to be accessed
    # TODO: read the config again from Vault to ensure it is accurate
    Logger.debug("Skipping KV credentials loading for dynamic Vault database")
    {:ok, %{manifest | credentials: %{}}}
  end

  @impl JumpWire.Proxy.Storage
  def load_credentials(store = %Metastore{vault_database: db}) when not is_nil(db) do
    # NB: credentials are dynamically generated when the DB needs to be accessed
    # TODO: read the config again from Vault to ensure it is accurate
    Logger.debug("Skipping KV credentials loading for dynamic Vault database")
    {:ok, %{store | credentials: %{}}}
  end

  @impl JumpWire.Proxy.Storage
  def load_credentials(db) do
    Logger.debug("Loading database credentials from Vault KV store")
    config_path = kv_path(db.organization_id, db.id)
    with {:ok, vault} <- kv_client(),
         {:ok, creds} <- Vault.read(vault, config_path) do
      db = %{db | credentials: creds}

      {:ok, db}
    end
  end

  @doc """
  Delete any credentials stored in the Vault KV mount for this manifest.
  """
  @impl JumpWire.Proxy.Storage
  def delete_credentials(db) do
    config_path = kv_path(db.organization_id, db.id)
    with {:ok, vault} <- kv_client(),
         {:ok, %{"data" => %{"metadata" => %{"version" => version, "deletion_time" => nil}}}} <- Vault.read(vault, config_path, full_response: true),
         {:ok, _} <- Vault.delete(vault, config_path, versions: [version], full_response: true) do
      {:ok, db}
    end
  end

  @spec list_databases(String.t) :: {:ok, list} | :error
  def list_databases(_org_id) do
    config_path = mount_path(:db_path) |> Path.join("config")

    with {:ok, vault} <- client(),
         {:ok, %{"keys" => keys}} <- Vault.list(vault, config_path) do
      databases = keys
      |> Stream.map(fn key ->
        key_path = Path.join(config_path, key)
        case Vault.read(vault, key_path) do
          {:ok, config} -> parse_db_config(config, key_path, key)
          _ -> nil
        end
      end)
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()

      db_count = Enum.count(databases)
      Logger.debug("Found #{db_count} databases in Vault")

      {:ok, databases}
    else
      {:error, ["Key not found"]} ->
        {:ok, []}
      _ ->
        Logger.warn("Failed to list Vault database roles")
        :error
    end
  end

  defp parse_db_config(
    %{"allowed_roles" => [role | _], "plugin_name" => plugin, "connection_details" => connection_details},
    path,
    key
  ) do
    with {:ok, url} <- Map.fetch(connection_details, "connection_url"),
         {:ok, config} <- parse_database_url(url) do
      name = "vault://#{path}"
      type = database_type(plugin)

      config = config
      |> Map.new()
      |> Map.put(:vault_database, key)
      |> Map.put(:vault_role, role)
      |> Map.put(:__type__, type)

      %{
        id: Uniq.UUID.uuid5(:url, name),
        name: name,
        root_type: type,
        configuration: config,
      }
    else
      _ -> nil
    end
  end
  defp parse_db_config(_config, _path, _key), do: nil

  defp parse_database_url(url) when is_binary(url) do
    # TODO: parse the query options for additional parameters, eg SSL
    uri = URI.parse(url)

    db_opts = [
      hostname: uri.host,
      port: uri.port,
      database: Path.relative(uri.path),
    ]
    {:ok, db_opts}
  end
  defp parse_database_url(_url), do: :error

  @doc """
  Fetch credentials from a database store in Vault. This will use either a dynamic
  or static role to interpolate credentials.
  """
  def credentials(database, role, _org_id) do
    mount = mount_path(:db_path)

    with {:ok, vault} <- client(),
         {:ok, data} <- Vault.read(vault, "#{mount}/config/#{database}"),
           %{"connection_details" => %{"connection_url" => url}} <- data,
         {:ok, config} <- parse_database_url(url),
         {:ok, data} <- Vault.read(vault, "#{mount}/creds/#{role}", full_response: true),
           %{"data" => creds, "lease_duration" => ttl, "lease_id" => id} <- data do
      auth = config
      |> Keyword.take([:hostname, :port])
      |> Keyword.merge([
        username: creds["username"],
        password: creds["password"],
      ])
      {:ok, auth, %{lease: id, duration: ttl}}
    else
      err ->
        Logger.warn("Failed to generate proxy credentials from Vault for #{role} role: #{inspect err}")
        {:error, :vault_credentials}
    end
  end

  @doc """
  Renews a lease from Vault when it is halfway to expiration. This
  will block the calling process while waiting and should generally
  be called asynchronously.
  """
  def renew(lease_id, ttl) do
    Integer.floor_div(ttl * 1000, 2) |> Process.sleep()

    case renew(lease_id) do
      {:ok, lease_id, ttl} ->
        Logger.debug("Vault credentials for lease #{lease_id} renewed for #{ttl}s")
        renew(lease_id, ttl)

      err ->
        Logger.error("Failed to renew #{lease_id} for Vault credentials: #{inspect err}")
    end
  end

  def renew(lease) do
    with {:ok, vault} <- client(),
         {:ok, resp} <- Vault.write(vault, @renew_path, %{"lease_id" => lease}, full_response: true),
           %{"lease_id" => id, "lease_duration" => ttl} <- resp do
      {:ok, id, ttl}
    end
  end

  def kv_mount_path(org_id), do: mount_path(org_id, :kv_path)

  def mount_path(key) do
    opts = Application.get_env(:jumpwire, :libvault)
    Keyword.fetch!(opts, key)
  end
  def mount_path(org_id, key) do
    key
    |> mount_path()
    |> Path.join(org_id)
  end

  def kv_path(org_id, id) do
    mount = kv_mount_path(org_id)
    Path.join([mount, "manifest", id])
  end

  defp database_type("postgresql-database-plugin"), do: :postgresql
  defp database_type("mysql-database-plugin"), do: :mysql
  defp database_type(type) when type in ["postgresql", "mysql"] do
    String.to_existing_atom(type)
  end

  defp database_type(_), do: :unknown
end
