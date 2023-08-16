defmodule JumpWire.Proxy.Postgres.Setup do
  alias __MODULE__
  alias JumpWire.Manifest
  alias JumpWire.Proxy.{Postgres, Schema}
  require Logger

  @handle_suffix "_jw_handle"
  @encrypted_suffix "_jw_enc"
  @handlers [nothing: 0, encrypt: 1, tokenize: 2]

  @doc """
  Hook that executes when a Postgres schema is upserted
  """
  def on_schema_upsert(manifest = %Manifest{}, schema = %Schema{}) do
    case JumpWire.Proxy.SQL.enable_table(manifest, schema) do
      :ok ->
        JumpWire.Proxy.Postgres.Manager.refresh_schema(manifest, schema)
        JumpWire.Proxy.measure_database(manifest)

      err ->
        Logger.error("Failed to enable encryption for #{manifest.root_type} table #{schema.id}: #{inspect(err)}")
        err
    end
  end

  @doc """
  Create Postgrex parameters from a map of options.
  """
  @spec postgrex_params(map(), map(), String.t()) :: {:ok, Keyword.t(), nil | Keyword.t()}
  def postgrex_params(config, credentials, org_id) do
    database = Map.get(config, "database")
    hostname = Map.get(config, "hostname", "localhost")
    sni = String.to_charlist(hostname)

    {:ok, db_opts, meta} =
      config
      |> Map.merge(credentials)
      |> Map.put_new("port", 5432)
      |> resolve_credentials(org_id)

    ssl = Map.get(config, "ssl", true)
    ssl_opts = Application.get_env(:jumpwire, :proxy)[:client_ssl]
    cert_dir = :code.priv_dir(:jumpwire) |> Path.join("cert")

    cacertfile =
      if String.ends_with?(hostname, ".rds.amazonaws.com") do
        # Use the AWS RDS cert bundle for all RDS connections
        Path.join(cert_dir, "aws-rds-bundle.pem")
      else
        Keyword.get(ssl_opts, :cacertfile)
      end

    ssl_opts =
      ssl_opts
      |> Keyword.put(:customize_hostname_check,
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      )
      |> Keyword.put(:server_name_indication, sni)
      |> Keyword.put(:cacertfile, cacertfile)

    params = Keyword.merge(db_opts, database: database, ssl: ssl, ssl_opts: ssl_opts)
    {:ok, params, meta}
  end

  defp resolve_credentials(%{"vault_database" => vault_db, "vault_role" => vault_role}, org_id)
  when not is_nil(vault_db) and not is_nil(vault_role) do
    JumpWire.Proxy.Storage.Vault.credentials(vault_db, vault_role, org_id)
  end

  defp resolve_credentials(
    %{"username" => user, "hostname" => host, "password" => password, "port" => port},
    _org_id
  ) do
    port =
      if is_binary(port) do
        case Integer.parse(port) do
          {port, ""} -> port
          _ -> 5432
        end
      else
        port
      end

    params = [username: user, hostname: host, port: port, password: password]
    {:ok, params, nil}
  end

  @doc """
  Establishes a connection with the database.

  NOTE: When using one-off connections, you'll want to clean up the connection by
  calling `GenServer.stop(conn)` afterwards.
  """
  @spec get_conn(Manifest.t(), [Postgrex.start_option()]) ::
          {:ok, conn :: pid()} | {:error, Postgrex.Error.t() | term}
  def get_conn(manifest, extra_opts \\ []) do
    with {:ok, db_opts, meta} <- Postgres.params_from_manifest(manifest) do
      db_opts = Keyword.merge(db_opts, extra_opts)

      with %{lease: id, duration: ttl} <- meta do
        Task.async(JumpWire.Proxy.Storage.Vault, :renew, [id, ttl])
      end

      Postgrex.start_link(db_opts)
    end
  end

  @doc """
  Returns a connection in a singleton fashion: it is only created once (per
  manifest) and it is cached locally. This connection is persistent and managed
  by DBConnection.ConnectionPool.
  """
  @spec get_pooled_conn(Manifest.t()) ::
          {:ok, conn :: pid()} | {:error, Postgrex.Error.t() | term}
  def get_pooled_conn(manifest) do
    conn = JumpWire.LocalConfig.get(:manifest_connections, manifest.id)

    if is_pid(conn) and Process.alive?(conn) do
      {:ok, conn}
    else
      pool_size = Application.get_env(:jumpwire, __MODULE__)[:pool_size] || 4

      case get_conn(manifest, pool_size: pool_size) do
        {:ok, conn} ->
          res = JumpWire.LocalConfig.put_new(:manifest_connections, manifest.id, conn)

          conn =
            if res == false do
              # This may happen in the event of a race condition, in which multiple connections
              # were open at around the same time. We'll close the connection we just opened and
              # instead use the one that got stored in the cache.
              GenServer.stop(conn)
              JumpWire.LocalConfig.get(:manifest_connections, manifest.id)
            else
              # Start a monitor to remove the PID from the ETS table if the process dies for any reason
              Task.Supervisor.async_nolink(JumpWire.DatabaseConnectionSupervisor, fn ->
                Process.monitor(conn)

                receive do
                  {:DOWN, _ref, :process, _pid, _reason} ->
                    Logger.warning("Pooled DB connection process exited")
                    JumpWire.LocalConfig.delete(:manifest_connections, manifest.id)
                end
              end)

              conn
            end

          {:ok, conn}

        {:error, reason} ->
          Logger.error("Unable to start connection on manifest #{manifest.id}: #{inspect(reason)}")

          {:error, reason}
      end
    end
  end

  @doc """
  Create a connection to PostgreSQL that is automatically cleaned up.

  The supplied function is called with the opened connection, and after
  returning the connection process is stopped.
  """
  @spec with_ephemeral_conn(Manifest.t(), term, [Postgrex.start_option()], cb :: term) ::
          cb_result :: term | {:error, Postgrex.Error.t() | term}
  def with_ephemeral_conn(manifest, default \\ :error, extra_opts \\ [], fun) do
    case get_conn(manifest, extra_opts) do
      {:ok, conn} ->
        resp = fun.(conn)
        GenServer.stop(conn)
        resp

      _ ->
        default
    end
  end

  @doc """
  Executes the given `fun` with a pooled connection passed as parameter.
  """
  @spec with_pooled_conn(Manifest.t(), term, cb :: term) ::
          cb_result :: term | {:error, Postgrex.Error.t() | term}
  def with_pooled_conn(manifest, default \\ :error, fun) do
    case get_pooled_conn(manifest) do
      {:ok, conn} -> fun.(conn)
      _ -> default
    end
  end

  @doc """
  Run a Postgrex query, catching exceptions and turning them into errors.

  Why doesn't Postgrex do this? :-/
  """
  def safe_query(conn, query, params \\ [], opts \\ []) do
    try do
      Postgrex.query(conn, query, params, opts)
    rescue
      e in DBConnection.ConnectionError ->
        Logger.error(inspect(e))
        {:error, e.message}

      e in DBConnection.OwnershipError ->
        Logger.error(inspect(e))
        {:error, e.message}
    end
  end

  def transaction(conn, fun) do
    Postgrex.transaction(conn, fun)
  end

  def format_query_param(index, zero_base \\ true) do
    if zero_base do
      "$#{index + 1}"
    else
      "$#{index}"
    end
  end

  @doc """
  Enable field-level data handling within a Postgres DB.
  Minimum supported version is 9.5.

  The pgcrypto module is considered “trusted”, that is, it can be installed by non-superusers who have CREATE privilege on the current database.

  This should be run whenever a postgresql manifest is created or updated.
  """
  def enable_database(manifest = %Manifest{root_type: :postgresql}) do
    with_ephemeral_conn(manifest, fn conn ->
      # always try to setup notifications, even if the other
      # triggers/extensions fail to get created
      res = enable_database(conn, manifest)

      case enable_notifications(conn, manifest) do
        :ok ->
          :ok

        err ->
          Logger.error("Failed to setup notifications: #{inspect(err)}")
          err
      end

      res
    end)
  end

  def enable_database(conn, %Manifest{id: id, organization_id: org_id}) when is_pid(conn) do
    with {:ok, _} <- safe_query(conn, "CREATE EXTENSION IF NOT EXISTS pgcrypto;", []),
         {:ok, _} <- safe_query(conn, "CREATE EXTENSION IF NOT EXISTS hstore;", []),
         {:ok, _} <- safe_query(conn, sql_schema(), []),
         {:ok, _} <- safe_query(conn, sql_schema_encryption_index(), []),
         {:ok, _} <- safe_query(conn, sql_schema_token_index(), []),
         {:ok, _} <- safe_query(conn, sql_encrypt_function(org_id), []),
         {:ok, _} <- safe_query(conn, sql_hash_function(), []),
         {:ok, _} <- safe_query(conn, sql_update_encrypt_function(), []),
         {:ok, _} <- safe_query(conn, sql_update_tokenize_function(id), []) do
      :ok
    end
  end

  def enable_notifications(conn, _manifest) do
    with {:ok, _} <- safe_query(conn, sql_notify_function()) do
      # not pattern matching on the trigger since it doesn't have a
      # create if not exists version, so there may be a duplicate
      # already in the DB
      safe_query(conn, sql_notify_trigger())
      :ok
    end
  end

  def disable_database(manifest = %Manifest{root_type: :postgresql}) do
    with_ephemeral_conn(manifest, fn conn ->
      case disable_database(conn) do
        {:ok, _} -> :ok
        err -> err
      end
    end)
  end

  def disable_database(conn) when is_pid(conn) do
    Postgrex.transaction(conn, fn conn ->
      with {:ok, _} <- Postgrex.query(conn, "DROP FUNCTION IF EXISTS jumpwire_notify CASCADE", []),
           {:ok, _} <- Postgrex.query(conn, "DROP FUNCTION IF EXISTS jumpwire_update_encrypt CASCADE", []),
           {:ok, _} <- Postgrex.query(conn, "DROP FUNCTION IF EXISTS jumpwire_update_tokenize CASCADE", []),
           {:ok, _} <- Postgrex.query(conn, "DROP FUNCTION IF EXISTS jumpwire_encrypt CASCADE", []),
           {:ok, _} <- Postgrex.query(conn, "DROP FUNCTION IF EXISTS jumpwire_hash CASCADE", []),
           {:ok, res} <- Postgrex.query(conn, "DROP TABLE IF EXISTS jumpwire_proxy_schema_fields", []) do
        res
      else
        {:error, err} ->
          Logger.error("Failed to disable encryption: #{inspect(err)}")
          Postgrex.rollback(conn, err)
      end
    end)
  end

  @doc """
  Enable encryption/tokenization for all tables related to the given manifest that
  have relevant labels.
  """
  def enable_tables(manifest = %Manifest{root_type: :postgresql}) do
    JumpWire.Proxy.Schema.list_all(manifest.organization_id, manifest.id)
    |> Enum.each(fn schema ->
      case enable_table(manifest, schema) do
        :ok ->
          :ok

        err ->
          Logger.error("Failed to enable table #{schema.name}: #{inspect(err)}")
          err
      end
    end)
  end

  @spec enable_table(JumpWire.Proxy.Schema.t()) :: :ok | {:error, any}
  @doc """
  Enable the encrypted/tokenized fields for a specific table.

  This should be run whenever a postgresql schema is created or updated.
  """
  def enable_table(schema = %Schema{}) do
    case JumpWire.GlobalConfig.fetch(:manifests, {schema.organization_id, schema.manifest_id}) do
      {:ok, manifest = %{root_type: :postgresql}} -> enable_table(manifest, schema)
      {:ok, _} -> :ok
      _ -> {:error, :manifest_not_found}
    end
  end

  @spec enable_table(JumpWire.Manifest.t(), JumpWire.Proxy.Schema.t()) :: :ok | {:error, any}
  def enable_table(manifest = %Manifest{root_type: :postgresql}, schema) do
    labels = Manifest.policy_labels(manifest)

    # enable table only if it has labels that need encryption/tokenization
    do_enable =
      schema.fields
      |> Stream.flat_map(fn {_name, labels} -> labels end)
      |> Stream.uniq()
      |> Stream.filter(fn label ->
        Enum.member?(labels[:encrypt], label) or Enum.member?(labels[:tokenize], label)
      end)
      |> Enum.empty?()
      |> Kernel.not()

    with_ephemeral_conn(manifest, fn conn ->
      setup_fun =
        if do_enable, do: &Setup.enable_table/3, else: &Setup.disable_table/3

      case setup_fun.(conn, schema, labels) do
        {:ok, _} -> :ok
        err -> err
      end
    end)
  end

  @spec disable_table(pid, JumpWire.Proxy.Schema.t(), any) :: {:ok, any} | {:error, any}
  def disable_table(conn, schema = %Schema{}, _labels) when is_pid(conn) do
    Logger.debug("Running cleanup for schema #{schema.id}")
    Postgrex.transaction(conn, fn conn ->
      # Drop triggers first, since they write to handling columns
      # Then drop handling columns
      with {:ok, _} <- Postgrex.query(conn, "DROP TRIGGER IF EXISTS jumpwireEncrypt ON #{schema.name};", []),
           {:ok, _} <- Postgrex.query(conn, "DROP TRIGGER IF EXISTS jumpwireTokenize ON #{schema.name};", []),
           {:ok, _} <- Postgrex.query(conn, "DELETE FROM jumpwire_proxy_schema_fields WHERE table_name = $1;", [schema.name]),
           {:ok, %{rows: columns}} <- Postgrex.query(conn, sql_list_columns(), [schema.name]) do

        # list jw_handle fields
        handle_columns =
          columns
          |> Stream.filter(fn [col_name, _col_type] ->
            String.ends_with?(col_name, @handle_suffix)
          end)

        if Enum.empty?(handle_columns) do
          :ok
        else
          remove_handling_columns(conn, schema, handle_columns)
        end
      else
        err ->
          Logger.error("Failed to disable table handling for schema #{schema.id}: #{inspect(err)}")
          Postgrex.rollback(conn, err)
      end
    end)
  end

  @spec remove_handling_columns(pid, JumpWire.Proxy.Schema.t(), any) :: {:ok, any} | {:error, any}
  defp remove_handling_columns(conn, schema = %Schema{}, handle_columns) do
    where_columns_handled =
      handle_columns
      |> Enum.map_join(" OR ", fn [col_name, _col_type] -> col_name <> " != 0" end)

    query = "SELECT count(*) FROM #{schema.name} WHERE #{where_columns_handled};"

    # To safely remove bookkeeping columns, we must first count number of rows that have encryption/tokenization.
    # If count is 0, safe to remove jw columns
    with {:ok, %{rows: [[count]]}} <- Postgrex.query(conn, query, []),
         0 <- count do
      handle_columns
      |> Stream.map(fn [col_name, _] -> String.split(col_name, @handle_suffix) end)
      |> Enum.reduce_while(:ok, fn [field | _], _acc ->
        with {:ok, _} <- Postgrex.query(conn, drop_sql_shadow_index(schema.name, field), []),
             {:ok, _} <- Postgrex.query(conn, drop_sql_shadow_handle(schema.name, field), []),
             {:ok, _} <- Postgrex.query(conn, drop_sql_shadow_enc(schema.name, field), []) do
          {:cont, :ok}
        else
          err ->
            Logger.error("Failed to unset metadata for schema #{schema.id}: #{inspect(err)}")
            {:cont, {:error, err}}
        end
      end)
    else
      err ->
        Logger.warn(
          "Failed to remove handling columns: unlabeled fields may need migration: #{inspect(err)}"
        )

        {:error, :pending_migrations}
    end
  end

  @spec enable_table(pid, JumpWire.Proxy.Schema.t(), [String.t()]) :: {:ok, any} | {:error, any}
  def enable_table(conn, schema = %Schema{}, labels) when is_pid(conn) do
    Postgrex.transaction(conn, fn conn ->
      # WARNING: this is a potential SQL injection!
      # for some reason paramerizing the table name causes a syntax error
      with {:ok, _} <- Postgrex.query(conn, "DROP TRIGGER IF EXISTS jumpwireEncrypt ON #{schema.name};", []),
           {:ok, _} <- Postgrex.query(conn, "DROP TRIGGER IF EXISTS jumpwireTokenize ON #{schema.name};", []),
           {:ok, _} <- Postgrex.query(conn, "DELETE FROM jumpwire_proxy_schema_fields WHERE table_name = $1;", [schema.name]),
           {:ok, _} <- Postgrex.query(conn, sql_encrypt_trigger(schema.name), []),
           {:ok, _} <- Postgrex.query(conn, sql_tokenize_trigger(schema.name), []),
           {:ok, %{rows: [[oid]]}} <-
             Postgrex.query(conn, "SELECT oid from pg_class where relname = $1", [schema.name]) do
        JumpWire.GlobalConfig.put(:reverse_schemas, {schema.organization_id, oid}, schema.id)
        upsert_metadata(conn, schema, labels)
      else
        err ->
          Logger.error("Failed to enable table handling for schema #{schema.id}: #{inspect(err)}")
          Postgrex.rollback(conn, err)
      end
    end)
  end

  def upsert_metadata(manifest = %Manifest{}, labels) do
    with_ephemeral_conn(manifest, fn conn ->
      JumpWire.Proxy.Schema.list_all(manifest.organization_id, manifest.id)
      |> Enum.each(fn schema ->
        upsert_metadata(conn, schema, labels)
      end)
    end)
  end

  @spec upsert_metadata(pid, Schema.t(), [String.t()]) :: {:ok, any} | {:error, any}
  def upsert_metadata(conn, schema = %Schema{}, labels) do
    Enum.reduce(schema.fields, nil, fn {name, field_labels}, _ ->
      field =
        case name do
          "$." <> field -> field
          _ -> name
        end

      field_labels = MapSet.new(field_labels)
      encrypted = field_labels |> MapSet.disjoint?(labels[:encrypt]) |> Kernel.not()
      token_format = if not MapSet.disjoint?(field_labels, labels[:tokenize]), do: "hash"
      upsert_params = [schema.name, field, encrypted, token_format]

      Postgrex.transaction(conn, fn conn ->
        with {:ok, _} <- Postgrex.query(conn, sql_schema_upsert(), upsert_params),
             {:ok, _} <- Postgrex.query(conn, sql_shadow_handle(schema.name, field), []),
             {:ok, _} <- Postgrex.query(conn, sql_shadow_index(schema.name, field), []),
             {:ok, res} <- Postgrex.query(conn, sql_shadow_enc(schema.name, field), []) do
          res
        else
          err ->
            Logger.error("Failed to set metadata for schema #{schema.id}: #{inspect(err)}")
            Postgrex.rollback(conn, err)
        end
      end)
    end)
  end

  def table_stats(schema = %Schema{}) do
    case JumpWire.GlobalConfig.fetch(:manifests, {schema.organization_id, schema.manifest_id}) do
      {:ok, manifest = %{root_type: :postgresql}} -> table_stats(manifest, schema)
      {:ok, _} -> :ok
      _ -> {:error, :manifest_not_found}
    end
  end

  def table_stats(manifest = %Manifest{root_type: :postgresql}, schema) do
    labels = Manifest.policy_labels(manifest)

    with_pooled_conn(manifest, fn conn ->
      table_stats(conn, schema, labels)
    end)
  end

  def table_stats(conn, schema = %Schema{}, labels) when is_pid(conn) do
    total =
      case safe_query(conn, "SELECT COUNT(*) FROM #{schema.name}", []) do
        {:ok, %{rows: [[total]]}} -> total
        _ -> :unknown
      end

    stats =
      diff_table_columns_with_schema_labels(conn, schema, labels)
      |> Stream.map(fn {field, what_to_do} ->
        case what_to_do do
          %{is: _, should_be: :encrypt} ->
            count = count_encrypted_field(conn, schema.name, field)
            {:encrypted, field, count, total}

          %{is: _, should_be: :tokenize} ->
            count = count_tokenized_field(conn, schema.name, field)
            {:tokenized, field, count, total}

          %{is: _, should_be: :nothing} ->
            enc = count_encrypted_field(conn, schema.name, field)
            tok = count_tokenized_field(conn, schema.name, field)

            case {enc, tok} do
              {:unknown, :unknown} ->
                Logger.warn("Failed to count field #{field} for handling stats")
                {:unknown, field, :unknown, total}

              {0, 0} ->
                {:encrypted, field, 0, 0}

              {0, count} ->
                {:tokenized, field, count, 0}

              {count, _} ->
                {:encrypted, field, count, 0}
            end

          _ ->
            {:unknown, field, :unknown, total}
        end
      end)
      |> Stream.reject(fn {is, _, _, _} -> is == :unknown end)
      |> Enum.reduce(
        %{encrypted: %{}, tokenized: %{}},
        fn {handling, field, count, target}, acc ->
          Map.update!(acc, handling, fn fields ->
            Map.put(fields, field, %{count: count, target: target})
          end)
        end
      )

    Keyword.new(Map.put(stats, :rows, %{count: total, target: total}))
  end

  defp count_encrypted_field(conn, table, field) do
    count_handled_field(conn, table, field, @handlers[:encrypt])
  end

  defp count_tokenized_field(conn, table, field) do
    count_handled_field(conn, table, field, @handlers[:tokenize])
  end

  defp count_handled_field(conn, table, field, handle_type) do
    handle = field <> @handle_suffix

    query = """
    SELECT COUNT(*) FROM #{table}
    WHERE #{handle} = $1;
    """

    case safe_query(conn, query, [handle_type]) do
      {:ok, %{rows: [[count]]}} -> count
      _err -> :unknown
    end
  end

  def lookup_primary_key(conn, table) when is_pid(conn) do
    case safe_query(conn, sql_select_primary_key_field(table)) do
      {:ok, %{rows: [[col] | _]}} -> {:ok, col}
      err -> {:error, err}
    end
  end

  @doc """
  This method inspects the columns in the database table
  and compares them to the normalized schema and policy labels.

  It looks for columns with suffix of _jw_handle to indicate the
  column is (or was) goverened by a JW policy.

  The diff is used to determine if column data needs to be migrated
  from encrypted or tokenized back to its original form, or vice versa.

  The return value is a map with the following structure:
  %{
    column_name: %{is: current, should_be: policy},
    ...
  }
  where 'is' is :nothing || :handled
  and 'should_be' is :nothing || :encrypt || :tokenize
  """
  def diff_table_columns_with_schema_labels(conn, schema = %Schema{}, policy_labels) do
    # list columns in table that have JW handling
    columns = list_handled_columns(conn, schema)

    # reduce schema fields to intended handling
    schema_fields =
      schema.fields
      |> Enum.reduce(%{}, fn {field, labels}, acc ->
        field =
          case field do
            "$." <> f -> f
            _ -> field
          end

        ls = MapSet.new(labels)

        cond do
          not MapSet.disjoint?(policy_labels[:tokenize], ls) -> Map.put(acc, field, :tokenize)
          not MapSet.disjoint?(policy_labels[:encrypt], ls) -> Map.put(acc, field, :encrypt)
          true -> Map.put(acc, field, :nothing)
        end
      end)

    # determine if handled columns mismatch policy handling
    columns
    |> Enum.reduce(%{}, fn {column, is}, acc ->
      should_be = Map.get(schema_fields, column, :nothing)
      Map.put(acc, column, %{is: is, should_be: should_be})
    end)
    |> Enum.reject(fn {_column, handling} ->
      handling[:is] == :nothing and handling[:should_be] == :nothing
    end)
  end

  defp list_handled_columns(conn, schema = %Schema{}) do
    # list columns in table matching schema name
    rows =
      case safe_query(conn, sql_list_columns(), [schema.name]) do
        {:ok, result} ->
          result.rows

        {:error, err} ->
          Logger.error("Unmigration failed: #{inspect(err)}", schema: schema.name)
          []
      end

    # determine which columns that have JW handling
    rows
    |> Stream.map(fn [name, _typ] ->
      case String.replace_suffix(name, @handle_suffix, "") do
        ^name -> {name, :nothing}
        column -> {column, :handled}
      end
    end)
    |> Enum.reduce(%{}, fn {column, is}, acc ->
      # give precendence to column having handling rather than relying on columns ordered alpha
      case acc[column] do
        :handled -> acc
        _ -> Map.put(acc, column, is)
      end
    end)
  end

  def sql_schema() do
    # update when a policy or schema changes
    """
    CREATE TABLE IF NOT EXISTS jumpwire_proxy_schema_fields (
        table_name varchar(64) NOT NULL,
        field varchar(64) NOT NULL,
        encrypt boolean,
        token_format varchar(64),
        CONSTRAINT table_field UNIQUE(table_name, field)
    );
    """
  end

  def sql_schema_encryption_index() do
    """
    CREATE INDEX IF NOT EXISTS jumpwire_proxy_schema_fields_table_name_encrypt
    ON jumpwire_proxy_schema_fields (table_name, encrypt);
    """
  end

  def sql_schema_token_index() do
    """
    CREATE INDEX IF NOT EXISTS jumpwire_proxy_schema_fields_table_name_token_format
    ON jumpwire_proxy_schema_fields (table_name, token_format);
    """
  end

  def sql_schema_upsert() do
    """
    INSERT INTO jumpwire_proxy_schema_fields (table_name, field, encrypt, token_format)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT ON CONSTRAINT table_field DO UPDATE SET encrypt = EXCLUDED.encrypt, token_format = EXCLUDED.token_format;
    """
  end

  def sql_shadow_handle(table, field) do
    """
    ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS #{field}#{@handle_suffix} INT;
    """
  end

  def sql_shadow_index(table, field) do
    """
    CREATE INDEX IF NOT EXISTS #{table}_#{field}#{@handle_suffix}_index
    ON #{table} (#{field}#{@handle_suffix});
    """
  end

  def sql_shadow_enc(table, field) do
    """
    ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS #{field}#{@encrypted_suffix} TEXT;
    """
  end

  def drop_sql_shadow_handle(table, field) do
    """
    ALTER TABLE #{table} DROP COLUMN IF EXISTS #{field}#{@handle_suffix};
    """
  end

  def drop_sql_shadow_index(table, field) do
    """
    DROP INDEX IF EXISTS #{table}_#{field}#{@handle_suffix}_index;
    """
  end

  def drop_sql_shadow_enc(table, field) do
    """
    ALTER TABLE #{table} DROP COLUMN IF EXISTS #{field}#{@encrypted_suffix};
    """
  end

  def sql_select_primary_key_field(table) do
    """
    SELECT a.attname
    FROM   pg_index i
    JOIN   pg_attribute a ON a.attrelid = i.indrelid
                        AND a.attnum = ANY(i.indkey)
    WHERE  i.indrelid = '#{table}'::regclass
    AND    i.indisprimary;
    """
  end

  def sql_encrypt_trigger(table) do
    # WARNING: this is a potential SQL injection!
    # for some reason paramerizing the table name causes a syntax error
    """
    CREATE TRIGGER jumpwireEncrypt
    BEFORE INSERT OR UPDATE
    ON #{table}
    FOR EACH ROW
    EXECUTE FUNCTION jumpwire_update_encrypt();
    """
  end

  def sql_tokenize_trigger(table) do
    # WARNING: this is a potential SQL injection!
    # for some reason paramerizing the table name causes a syntax error
    """
    CREATE TRIGGER jumpwireTokenize
    BEFORE INSERT OR UPDATE
    ON #{table}
    FOR EACH ROW
    EXECUTE FUNCTION jumpwire_update_tokenize();
    """
  end

  def sql_update_encrypt_function() do
    """
    CREATE OR REPLACE FUNCTION jumpwire_update_encrypt()
    RETURNS TRIGGER
    LANGUAGE PLPGSQL
    AS $$
    DECLARE
    prefix constant text := 'jumpwire_';
    handle_suffix constant text := '#{@handle_suffix}';
    b boolean;
    s record;
    encrypted text;
    BEGIN
      for s in
          SELECT field FROM jumpwire_proxy_schema_fields WHERE table_name = TG_TABLE_NAME AND encrypt
      loop
        execute 'select $1.'||s.field||' NOT LIKE $2' USING NEW, (prefix || '%') INTO b;
        if b then
          execute 'select jumpwire_encrypt($1.'||s.field||'::text)' USING new INTO encrypted;
          NEW := NEW #= hstore(ARRAY[s.field::text, encrypted]);
        end if;
        NEW := NEW #= hstore(ARRAY[s.field || handle_suffix, '#{@handlers[:encrypt]}']);
      end loop;
      RETURN NEW;
    END; $$ STRICT;
    """
  end

  def sql_update_tokenize_function(manifest_id) do
    """
    CREATE OR REPLACE FUNCTION jumpwire_update_tokenize()
    RETURNS TRIGGER
    LANGUAGE PLPGSQL
    AS $$
    DECLARE
    prefix constant text := 'SldUT0tO';
    manifest constant bytea := '#{manifest_id}';
    field_suffix constant text := '#{@encrypted_suffix}';
    handle_suffix constant text := '#{@handle_suffix}';
    b boolean;
    s record;
    token text;
    encrypted text;
    BEGIN
      for s in
        SELECT field FROM jumpwire_proxy_schema_fields
        WHERE table_name = TG_TABLE_NAME AND token_format = 'hash'
      loop
        execute 'select $1.'||s.field||' NOT LIKE $2' USING NEW, (prefix || '%') INTO b;
        if b then
          execute 'select jumpwire_encrypt($1.'||s.field||'::text)' USING new INTO encrypted;
          execute 'select jumpwire_hash($1, $2.'||s.field||'::text, $3, $4)' USING s.field, new, manifest, TG_RELID INTO token;
          NEW := NEW #= hstore(ARRAY[s.field::text, token, s.field || field_suffix, encrypted]);
        end if;
        NEW := NEW #= hstore(ARRAY[s.field || handle_suffix, '#{@handlers[:tokenize]}']);
      end loop;
      RETURN NEW;
    END; $$ STRICT;
    """
  end

  def sql_encrypt_function(org_id) do
    {key, tag} = JumpWire.Vault.default_aes_key(org_id, :cbc)
    key = Base.encode16(key)
    tag = tag |> Cloak.Tags.Encoder.encode() |> Base.encode16()

    """
    CREATE OR REPLACE FUNCTION jumpwire_encrypt(field text)
    RETURNS text
    LANGUAGE PLPGSQL
    AS $$
    DECLARE
    key constant bytea := '\\x#{key}';
    tag constant bytea := '\\x0100#{tag}';
    prefix constant text := 'jumpwire_';
    checksum bytea;
    iv bytea;
    encrypted text;
    encoded text;
    BEGIN
      checksum := decode(md5(field), 'hex');
      iv := gen_random_bytes(16);
      encrypted := encrypt_iv(checksum || field::bytea, key, iv, 'aes-cbc/pad:pkcs');
      encoded := prefix || encode(tag || iv || encrypted::bytea, 'base64');
      encoded := replace(encoded, E'\n', '');
      RETURN encoded;
    END; $$ STRICT;
    """
  end

  def sql_hash_function() do
    """
    CREATE OR REPLACE FUNCTION jumpwire_hash(field name, value text, manifest bytea, schema oid)
    RETURNS text
    LANGUAGE PLPGSQL
    AS $$
    DECLARE
    prefix constant bytea := 'JWTOKN';
    hash text;
    token text;
    table_id bytea;
    field_length bytea;
    BEGIN
      hash := digest(value, 'sha256');

      field_length := int4send(octet_length(field::bytea));
      table_id := '\x04' || int4send(schema::integer);
      token := prefix || '\x24' || manifest || table_id || field_length || field::bytea || hash::bytea;

      token := encode(token::bytea, 'base64');
      token := replace(token, E'\n', '');
      RETURN token;
    END; $$ STRICT;
    """
  end

  def sql_list_columns() do
    """
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_name=$1
    ORDER BY column_name ASC
    """
  end

  def sql_notify_function() do
    """
    CREATE OR REPLACE FUNCTION jumpwire_notify()
    RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      NOTIFY jumpwire_ddl;
    END;
    $$;
    """
  end

  def sql_notify_trigger() do
    """
    CREATE EVENT TRIGGER jumpwire_ddl_end
    ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE', 'DROP TABLE')
    EXECUTE PROCEDURE jumpwire_notify();
    """
  end
end
