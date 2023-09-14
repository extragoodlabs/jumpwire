defmodule JumpWire.Proxy.Postgres.Manager do
  @moduledoc """
  Configure a PostgreSQL database and load metadata from a manifest.
  All tables are queried and matched up with configured schemas to allow
  OID-based lookups.
  """

  use GenServer
  alias JumpWire.Proxy.{Database, Postgres}
  alias JumpWire.Manifest
  require Logger

  @channel "jumpwire_ddl"
  @retry_timer 30_000

  def start_supervised(manifest) do
    spec = child_spec(manifest)
    case Hydrax.Supervisor.start_child(spec) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      res -> res
    end
  end

  def name(manifest), do: Hydrax.Registry.pid_name(manifest.id, __MODULE__)

  def start_link(manifest) do
    GenServer.start_link(__MODULE__, manifest, name: name(manifest))
  end

  @impl true
  def init(manifest) do
    JumpWire.Tracer.context(manifest: manifest.id, org_id: manifest.organization_id)

    case enable(manifest) do
      {:ok, conn} ->
        state = %{conn: conn, manifest: manifest, enabled: true}
        {:ok, state}

      err ->
        Logger.error("Failed to enable PostgreSQL database, will retry: #{inspect err}")
        state = %{conn: nil, manifest: manifest, enabled: false}
        Process.send_after(self(), :enable, @retry_timer)
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:notification, _, _, _, _}, state) do
    Logger.debug("Postgres DDL notification received")
    refresh_schemas(state.conn, state.manifest)
    {:noreply, state}
  end

  @impl true
  def handle_info(:enable, state) do
    case enable(state.manifest) do
      {:ok, conn} ->
        state = %{state | enabled: true, conn: conn}
        {:noreply, state}

      err ->
        Logger.error("Failed to enable PostgreSQL database, will retry: #{inspect err}")
        Process.send_after(self(), :enable, @retry_timer)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:refresh_schema, schema}, _from, state) do
    Logger.debug("Updating schema/table mapping")
    Database.set_table_schema(state.manifest.organization_id, state.manifest.id, schema)
    {:reply, :ok, state}
  end

  defp enable(manifest) do
    Logger.debug("Enabling PostgreSQL database")

    with {:ok, conn} <- start_conn(manifest),
         :ok <- Postgres.Setup.enable_database(conn, manifest),
         :ok <- Postgres.Setup.enable_notifications(conn, manifest) do
      Logger.info("PostgreSQL database enabled")
      refresh_schemas(conn, manifest)
      {:ok, conn}
    end
  end

  defp start_conn(manifest) do
    with {:ok, db_opts, meta} <- Postgres.params_from_manifest(manifest),
         notify_opts <- Keyword.put(db_opts, :auto_reconnect, true),
         {:ok, conn} <- Postgrex.Notifications.start_link(notify_opts) do
      with %{lease: id, duration: ttl} <- meta do
        Task.async(JumpWire.Proxy.Storage.Vault, :renew, [id, ttl])
      end

      # listen for DDL notifications
      Postgrex.Notifications.listen(conn, @channel)

      # start a process for performing queries
      Postgrex.start_link(db_opts)
    end
  end

  defp refresh_schemas(conn, manifest) do
    # Find all schemas for the current database manifest
    Logger.debug("Fetching schema metadata")
    tables = query_tables(conn, manifest)

    schemas = JumpWire.Proxy.Schema.list_all(manifest.organization_id, manifest.id)
    |> Stream.map(fn schema -> Database.convert_schema(schema, tables) end)
    |> Map.new()

    # Put the table OIDs in the ETS cache for the manifest.
    JumpWire.GlobalConfig.put(
      :manifest_table_metadata,
      {manifest.organization_id, manifest.id},
      {tables, schemas}
    )
  end

  def refresh_schema(manifest, schema) do
    pid = name(manifest)
    GenServer.call(pid, {:refresh_schema, schema})
  end

  @doc """
  Lookup all OIDs for tables in the db along with column attribute numbers

  Returns a map keyed by table name.
  """
  @spec query_tables(pid(), Manifest.t()) :: map()
  def query_tables(conn, manifest) do
    namespace = Map.get(manifest.configuration, "schema", "public")
    namespaces = [namespace, "pg_catalog"] |> MapSet.new() |> MapSet.to_list()

    placeholders = namespaces |> Stream.with_index(1) |> Stream.map(fn {_, i} -> "$#{i}" end) |> Enum.join(",")
    query = """
    SELECT pg_class.oid, pg_namespace.nspname, table_name, column_name, ordinal_position
    FROM information_schema.columns
    INNER JOIN pg_class ON relname = table_name
    INNER JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE (pg_class.relkind = 'r' OR pg_class.relkind = 'v') AND pg_namespace.nspname IN (#{placeholders});
    """

    case Postgrex.query(conn, query, namespaces) do
      {:ok, %{rows: rows}} ->
        rows
        |> Stream.map(fn [id, namespace, name, column, column_id] ->
          %{name: name, namespace: namespace, id: id, column: column, column_id: column_id}
        end)
        |> Enum.group_by(fn row -> {row.namespace, row.name} end)

      err ->
        Logger.error("Failed to query postgres tables: #{inspect err}")
        []
    end
  end
end
