defmodule JumpWire.Proxy.MySQL.Setup do
  alias JumpWire.Manifest
  alias JumpWire.Proxy.{MySQL, Schema}
  require Logger

  @handle_suffix "_jw_handle"
  @encrypted_suffix "_jw_enc"
  @handlers [nothing: 0, encrypt: 1, tokenize: 2]
  @function_version "v2"
  @encrypt_function_name "jumpwire_encrypt_#{@function_version}"

  @er_sp_already_exists 1304
  @er_dup_fieldname 1060
  @er_dup_keyname 1061

  @doc """
  Hook that executes when a MySQL schema is upserted
  """
  def on_schema_upsert(manifest = %Manifest{}, schema = %Schema{}) do
    case JumpWire.Proxy.SQL.enable_table(manifest, schema) do
      :ok ->
        JumpWire.Proxy.measure_database(manifest)

      err ->
        Logger.error("Failed to enable encryption for #{manifest.root_type} table #{schema.id}: #{inspect(err)}")
        err
    end
  end

  @doc """
  Establishes a connection with the database.

  NOTE: When using one-off connections, you'll want to clean up the connection by
  calling `GenServer.stop(conn)` afterwards.
  """
  @spec get_conn(Manifest.t(), [MyXQL.start_option()]) ::
    {:ok, conn :: pid()}
    | {:error, MyXQL.Error.t()}
  def get_conn(manifest, extra_opts \\ []) do
    with {:ok, db_opts, meta} <- MySQL.params_from_manifest(manifest) do
      db_opts = Keyword.merge(db_opts, extra_opts)
      with %{lease: id, duration: ttl} <- meta do
        Task.async(JumpWire.Proxy.Storage.Vault, :renew, [id, ttl])
      end
      MyXQL.start_link(db_opts)
    end
  end

  @doc """
  Returns a connection in a singleton fashion: it is only created once (per
  manifest) and it is cached locally. This connection is persistent and managed
  by DBConnection.ConnectionPool.
  """
  @spec get_pooled_conn(Manifest.t()) ::
    {:ok, conn :: pid()}
    | {:error, MyXQL.Error.t()}
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
          Logger.error("Unable to start connection on manifest #{manifest.id}: #{inspect reason}")
          {:error, reason}
      end
    end
  end

  @doc """
  Create a connection to PostgreSQL that is automatically cleaned up.

  The supplied function is called with the opened connection, and after
  returning the connection process is stopped.
  """
  @spec with_ephemeral_conn(Manifest.t(), term, [MyXQL.start_option()], cb :: term) ::
    cb_result :: term
    | {:error, MyXQL.Error.t()}
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
    cb_result :: term
    | {:error, MyXQL.Error.t()}
  def with_pooled_conn(manifest, default \\ :error, fun) do
    case get_pooled_conn(manifest) do
      {:ok, conn} -> fun.(conn)
      _ -> default
    end
  end

  @doc """
  Run a MyXQL query, catching exceptions and turning them into errors.

  The query options will have query_type set to :text by default.
  This is needed for SQL statements that create/drop objects
  """
  @spec safe_query(MyXQL.conn, iodata, Keyword.t)
  :: {:ok, MyXQL.Result.t} | {:error, any}
  def safe_query(conn, query, params \\ []) do
    # SQL statements with parameters must be binary for preparation
    # Otherwise default to text for creating db objects
    query_type = case params do
      [_ | _] -> :binary
      _ -> :text
    end

    try do
      MyXQL.query(conn, query, params, [query_type: query_type])
    rescue
      e in DBConnection.ConnectionError ->
        {:error, e.message}

      e in DBConnection.OwnershipError ->
        {:error, e.message}
    end
  end

  def transaction(conn, fun) do
    MyXQL.transaction(conn, fun)
  end

  @spec create_function(MyXQL.conn, iodata) :: :ok | {:error, any}
  def create_function(conn, query) do
    case safe_query(conn, query) do
      {:ok, _} -> :ok

      {:error, %MyXQL.Error{message: msg, mysql: %{code: @er_sp_already_exists}}} ->
        Logger.warn("Failed to create function: #{msg}")
        {:error, :conflict}

      {:error, %MyXQL.Error{mysql: %{code: @er_dup_fieldname}}} -> :ok
      {:error, %MyXQL.Error{mysql: %{code: @er_dup_keyname}}} -> :ok
      err -> err
    end
  end

  @doc """
  Run a list of MyXQL queries, catching exceptions and turning
  them into errors.

  MyXQL has a query_many function, but it is unusable until
  https://github.com/elixir-ecto/myxql/issues/151 is resolved.
  """
  def safe_query_many(conn, queries) do
    Enum.reduce_while(queries, :ok, fn query, _ ->
      case safe_query(conn, query) do
        err = {:error, _} -> {:halt, err}
        res -> {:cont, res}
      end
    end)
  end

  def create_many(conn, queries) do
    Enum.reduce_while(queries, :ok, fn query, _ ->
      case create_function(conn, query) do
        err = {:error, _} -> {:halt, err}
        res -> {:cont, res}
      end
    end)
  end

  def format_query_param(_index, _zero_base \\ true) do
    "?"
  end

  @doc """
  Enable field-level data handling within a MySQL DB.
  Minimum supported version is 8.0

  This should be run whenever a mysql manifest is created or updated.

  https://dev.mysql.com/doc/refman/8.0/en/implicit-commit.html

  DB level objects:
  - jumpwire_encrypt
  - jumpwire_hash
  - jumpwire_encrypt_TABLE_insert
  - jumpwire_encrypt_TABLE_update

  The last two can be table locked I guess
  """
  def enable_database(manifest = %Manifest{root_type: :mysql}) do
    with_ephemeral_conn(manifest, fn conn ->
      set_traditional_sql_mode!(conn)

      case enable_database(conn, manifest) do
        :ok -> :ok
        err ->
          Logger.error("Failed to setup JumpWire for database #{manifest.id}: #{inspect err}")
          err
      end
    end)
  end

  @spec enable_database(MyXQL.conn, Manifest.t) :: :ok | {:error, any}
  def enable_database(conn, %Manifest{organization_id: org_id}) do
    with {:ok, type} <- db_type(conn),
         :ok <- enable_encryption(conn, type, org_id) do
      case create_function(conn, sql_hash_function()) do
        {:error, :conflict} ->
          # Ignore for now, the hash function rarely changes
          :ok

        res -> res
      end
    end
  end

  def disable_database(manifest = %Manifest{root_type: :mysql}) do
    with_ephemeral_conn(manifest, fn conn ->
      set_traditional_sql_mode!(conn)

      case disable_database(conn, manifest) do
        {:ok, _} -> :ok
        err -> err
      end
    end)
  end
  def disable_database(conn, manifest) do
    database = manifest.configuration["database"]

    with {:ok, %{rows: triggers}} <- safe_query(conn, "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '#{database}' AND TRIGGER_NAME LIKE 'jumpwire_%'"),
         {:ok, _} <- safe_query_many(conn, Enum.map(triggers, fn [trigger] -> "DROP TRIGGER #{trigger}" end)),
         {:ok, _} <- safe_query(conn, "DROP FUNCTION IF EXISTS #{encrypt_function_name()}"),
         {:ok, _} <- safe_query(conn, "DROP FUNCTION IF EXISTS jumpwire_hash_#{@function_version}") do
      :ok
    else
      err -> err
    end
  end

  @doc """
  Enable encryption/tokenization for all tables related to the given manifest that
  have relevant labels.
  """
  def enable_tables(manifest = %Manifest{}) do
    labels = Manifest.policy_labels(manifest)

    with_ephemeral_conn(manifest, fn conn ->
      set_traditional_sql_mode!(conn)

      JumpWire.GlobalConfig.all(:proxy_schemas, {manifest.organization_id, manifest.id, :_})
      |> Enum.each(fn schema ->
        case enable_table(conn, schema, labels) do
        {:ok, _} -> :ok
          :ok -> :ok
          err ->
            Logger.error("Failed to enable table #{schema.name}: #{inspect err}")
            err
        end
      end)
    end)
  end

  @doc """
  Enable the encrypted/tokenized fields for a specific table.

  This should be run whenever a mysql schema is created or updated.
  """
  def enable_table(schema = %Schema{}) do
    case JumpWire.GlobalConfig.fetch(:manifests, {schema.organization_id, schema.manifest_id}) do
      {:ok, manifest = %{root_type: :mysql}} -> enable_table(manifest, schema)
      {:ok, _} -> :ok
      _ -> {:error, :manifest_not_found}
    end
  end
  def enable_table(manifest = %Manifest{root_type: :mysql}, schema) do
    labels = Manifest.policy_labels(manifest)

    with_ephemeral_conn(manifest, fn conn ->
      set_traditional_sql_mode!(conn)

      case enable_table(conn, schema, labels) do
        {:ok, _} -> :ok
        :ok -> :ok
        err ->
          Logger.error("Failed to enable table #{schema.name}: #{inspect err}")
          err
      end
    end)
  end

  def enable_table(conn, schema = %Schema{}, labels) do
    {encrypted_fields, tokenized_fields} =
      Enum.reduce(schema.fields, {[], []}, fn {name, field_labels}, {enc, tok} ->
        field =
          case name do
            "$." <> field -> field
            _ -> name
          end
        field_labels = MapSet.new(field_labels)
        cond do
          not MapSet.disjoint?(field_labels, labels[:encrypt]) ->
            {[field | enc], tok}

          not MapSet.disjoint?(field_labels, labels[:tokenize]) ->
            {enc, [field | tok]}

          true ->
            {enc, tok}
        end
      end)

    all_fields = encrypted_fields ++ tokenized_fields

    # WARNING: this is a potential SQL injection!
    # table/field names cannot be parameterized

    shadow_handle_queries = Enum.map(all_fields, fn field ->
      "ALTER TABLE #{schema.name} ADD COLUMN #{field}#{@handle_suffix} INT;"
    end)
    shadow_index_queries = Enum.map(all_fields, fn field ->
      "ALTER TABLE #{schema.name} ADD Index #{schema.name}_#{field}#{@handle_suffix}_index (#{field}#{@handle_suffix});"
    end)
    shadow_enc_queries = Enum.map(all_fields, fn field ->
      "ALTER TABLE #{schema.name} ADD COLUMN #{field}#{@encrypted_suffix} TEXT;"
    end)

    with :ok <- create_many(conn, shadow_handle_queries),
         :ok <- create_many(conn, shadow_index_queries),
         :ok <- create_many(conn, shadow_enc_queries),
         {:ok, _} <- safe_query_many(conn, sql_update_encrypt_trigger(schema.name, encrypted_fields)),
         {:ok, _} <- safe_query_many(conn, sql_update_tokenize_trigger(schema.manifest_id, schema.name, tokenized_fields)) do
      JumpWire.GlobalConfig.put(:reverse_schemas, {schema.organization_id, schema.name}, schema.id)
      :ok
    else
      err ->
        Logger.error("Failed to enable table handling for schema #{schema.id}: #{inspect err}")
        safe_query(conn, "UNLOCK TABLES;")
        err
    end
  end

  def table_stats(schema = %Schema{}) do
    case JumpWire.GlobalConfig.fetch(:manifests, {schema.organization_id, schema.manifest_id}) do
      {:ok, manifest = %{root_type: :mysql}} -> table_stats(manifest, schema)
      {:ok, _} -> :ok
      _ -> {:error, :manifest_not_found}
    end
  end

  def table_stats(manifest = %Manifest{root_type: :mysql}, schema) do
    labels = Manifest.policy_labels(manifest)

    with_pooled_conn(manifest, fn conn ->
      set_traditional_sql_mode!(conn)
      table_stats(conn, schema, labels)
    end)
  end

  defp set_traditional_sql_mode!(conn) do
    MyXQL.query!(conn, "SET @@SESSION.sql_mode = ?", ["TRADITIONAL"])
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
          Map.update!(acc, handling, fn fields -> Map.put(fields, field, %{count: count, target: target}) end)
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
    WHERE #{handle} = ?;
    """

    case safe_query(conn, query, [handle_type]) do
      {:ok, %{rows: [[count]]}} -> count
      err ->
        Logger.error("Unable to count field stats for #{table}: #{inspect err}")
        :unknown
    end
  end

  def lookup_primary_key(conn, table) when is_pid(conn) do
    case safe_query(conn, sql_select_primary_key_field(table)) do
      {:ok, %{rows: [[col] | _]}} -> {:ok, col}
      err -> {:error, err}
    end
  end

  defp sql_select_primary_key_field(table) do
    """
    SELECT COLUMN_NAME
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = '#{table}'
      AND COLUMN_KEY = 'PRI';
    """
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

  def enable_encryption(conn, type, org_id) do
    query = sql_encrypt_function(type, org_id)
    name = encrypt_function_name()
    with {:error, :conflict} <- create_function(conn, query),
         {:ok, _} <- safe_query(conn, "DROP FUNCTION IF EXISTS #{name}") do
      Logger.info("Dropped conflicting function #{name}")
      create_function(conn, query)
    end
  end

  @doc """
  Return the versioned name of the MySQL function used for
  encrypting data.
  """
  def encrypt_function_name(), do: @encrypt_function_name

  @doc """
  Generate the SQL function used for encrypting data.

  MySQL uses AES-CBC with 256 bit keys.
  MariaDB ises AES-ECB with 128 bit keys.
  """
  def sql_encrypt_function(:mysql, org_id) do
    {key, tag} = JumpWire.Vault.default_aes_key(org_id, :cbc)
    key = Base.encode16(key)
    tag = <<1, 0>> <> Cloak.Tags.Encoder.encode(tag) |> Base.encode16()
    """
    CREATE FUNCTION #{encrypt_function_name()}(field LONGTEXT)
    RETURNS MEDIUMTEXT
    CONTAINS SQL
    READS SQL DATA
    SQL SECURITY DEFINER
    BEGIN
      DECLARE secret_key TINYBLOB DEFAULT UNHEX('#{key}');
      DECLARE tag TINYBLOB DEFAULT UNHEX('#{tag}');
      DECLARE prefix TINYTEXT DEFAULT 'jumpwire_';
      DECLARE encrypted MEDIUMBLOB;
      DECLARE encoded MEDIUMTEXT;
      DECLARE iv TINYBLOB;
      DECLARE checksum TINYBLOB;
      SET block_encryption_mode = 'aes-256-cbc';

      SET iv = RANDOM_BYTES(16);
      SET checksum = UNHEX(MD5(field));
      SET encrypted = AES_ENCRYPT(CONCAT(checksum, field), secret_key, iv);
      SET encrypted = CONCAT(tag, CONCAT(iv, encrypted));
      SET encoded = TO_BASE64(encrypted);
      SET encoded = REPLACE(encoded, '\n', '');
      RETURN CONCAT(prefix, encoded);
    END;
    """
  end

  def sql_encrypt_function(:mariadb, org_id) do
    {key, tag} = JumpWire.Vault.default_aes_key(org_id, :ecb)
    key = Base.encode16(key)
    tag = <<1, 0>> <> Cloak.Tags.Encoder.encode(tag) |> Base.encode16()
    """
    CREATE FUNCTION #{encrypt_function_name()}(field LONGTEXT)
    RETURNS MEDIUMTEXT
    CONTAINS SQL
    READS SQL DATA
    SQL SECURITY DEFINER
    BEGIN
      DECLARE secret_key TINYBLOB DEFAULT UNHEX('#{key}');
      DECLARE tag TINYBLOB DEFAULT UNHEX('#{tag}');
      DECLARE prefix TINYTEXT DEFAULT 'jumpwire_';
      DECLARE encrypted MEDIUMBLOB;
      DECLARE encoded MEDIUMTEXT;
      DECLARE checksum TINYBLOB;

      SET checksum = UNHEX(MD5(field));
      SET encrypted = AES_ENCRYPT(CONCAT(checksum, field), secret_key);
      SET encoded = TO_BASE64(CONCAT(tag, encrypted));
      SET encoded = REPLACE(encoded, '\n', '');
      RETURN CONCAT(prefix, encoded);
    END;
    """
  end

  def sql_hash_function() do
    """
    CREATE FUNCTION jumpwire_hash_#{@function_version}(field TINYTEXT, value LONGTEXT, manifest TINYTEXT, table_id TINYTEXT)
    RETURNS TINYTEXT
    CONTAINS SQL
    DETERMINISTIC
    SQL SECURITY DEFINER
    BEGIN
      DECLARE prefix TINYTEXT DEFAULT 'JWTOKN';
      DECLARE hash TINYBLOB;
      DECLARE token TINYBLOB;
      DECLARE field_length TINYBLOB;
      DECLARE table_length TINYBLOB;

      SET hash = UNHEX(SHA2(value, 256));
      SET field_length = UNHEX(LPAD(CONV(OCTET_LENGTH(field), 10, 16), 8, 0));
      SET table_length = UNHEX(CONV(OCTET_LENGTH(table_id), 10, 16));
      SET token = CONCAT(prefix, 0x24, manifest, table_length, table_id, field_length, field, hash);

      RETURN REPLACE(TO_BASE64(token), '\n', '');
    END;
    """
  end

  def sql_update_encrypt_trigger(table, fields) do
    [
      "LOCK TABLES #{table} WRITE",
      "DROP TRIGGER IF EXISTS jumpwire_encrypt_#{table}_insert",
      sql_encrypt_trigger(table, fields, "insert"),
      "DROP TRIGGER IF EXISTS jumpwire_encrypt_#{table}_update",
      sql_encrypt_trigger(table, fields, "update"),
      "UNLOCK TABLES",
    ]
  end

  def sql_encrypt_trigger(table, fields, event) do
    field_statements = fields
    |> Stream.map(fn field ->
      """
      IF NEW.#{field} IS NOT NULL AND NEW.#{field} NOT LIKE 'jumpwire_%' THEN
         SET NEW.#{field} = #{encrypt_function_name()}(NEW.#{field});
      END IF;
      SET NEW.#{field <> @handle_suffix} = #{@handlers[:encrypt]};
      """
    end)
    |> Enum.join("\n")

    """
    CREATE TRIGGER jumpwire_encrypt_#{table}_#{event}
    BEFORE #{event} ON #{table}
    FOR EACH ROW
    BEGIN
      #{field_statements}
    END;
    """
  end

  def sql_update_tokenize_trigger(manifest_id, table, fields) do
    [
      "LOCK TABLES #{table} WRITE",
      "DROP TRIGGER IF EXISTS jumpwire_tokenize_#{table}_insert",
      sql_tokenize_trigger(manifest_id, table, fields, "insert"),
      "DROP TRIGGER IF EXISTS jumpwire_tokenize_#{table}_update",
      sql_tokenize_trigger(manifest_id, table, fields, "update"),
      "UNLOCK TABLES",
    ]
  end

  def sql_tokenize_trigger(manifest_id, table, fields, event) do
    field_statements = fields
    |> Stream.map(fn field ->
      enc_field = field <> @encrypted_suffix
      """
      IF NEW.#{enc_field} IS NULL OR NEW.#{enc_field} NOT LIKE 'jumpwire_%' THEN
        SET NEW.#{enc_field} = #{encrypt_function_name()}(NEW.#{field});
         SET NEW.#{field} = jumpwire_hash_#{@function_version}('#{field}', NEW.#{field}, '#{manifest_id}', '#{table}');
      END IF;
      SET NEW.#{field <> @handle_suffix} = #{@handlers[:tokenize]};
      """
    end)
    |> Enum.join("\n")

    """
    CREATE TRIGGER jumpwire_tokenize_#{table}_#{event}
    BEFORE #{event} ON #{table}
    FOR EACH ROW
    BEGIN
      #{field_statements}
    END;
    """
  end

  def sql_list_columns() do
    """
    SELECT COLUMN_NAME, DATA_TYPE
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = ?
    ORDER BY COLUMN_NAME ASC;
    """
  end

  @doc """
  Determine whether this is a MariaDB or MySQL database based on the version. For MariaDB, the version
  string will contain "mariadb" in it - eg "10.9.4-MariaDB-1:10.9.4+maria~ubu2204"
  """
  def db_type(conn) do
    with {:ok, %{rows: [[version]]}} <- safe_query(conn, "SELECT VERSION()") do
      version = String.downcase(version)
      if String.contains?(version, "maria") do
        {:ok, :mariadb}
      else
        {:ok, :mysql}
      end
    end
  end
end
