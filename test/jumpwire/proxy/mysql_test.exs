defmodule JumpWire.Proxy.MySQLTest do
  use JumpWire.ProxyCase, async: false
  alias JumpWire.Proxy.MySQL

  @moduletag db: "mysql"

  setup_all %{org_id: org_id, token: token} do
    port = Application.get_env(:jumpwire, __MODULE__)[:port]

    # attempt to use SSL if not running in CI
    ssl = System.get_env("CI", "false") |> String.to_existing_atom() |> Kernel.not()
    mysql_manifest = %Manifest{
      root_type: :mysql,
      id: Uniq.UUID.uuid4(),
      configuration: %{
        "ssl" => ssl,
        "database" => "jumpwire_test",
        "hostname" => "localhost",
        "port" => port,
      },
      credentials: %{
        "username" => "root",
        "password" => "root",
        "vault_database" => nil,
        "vault_role" => nil,
      },
      organization_id: org_id,
    }
    JumpWire.GlobalConfig.put(:manifests, mysql_manifest)
    classified_manifest = %{mysql_manifest | classification: "Internal", id: Uniq.UUID.uuid4()}
    JumpWire.GlobalConfig.put(:manifests, classified_manifest)

    conf = Application.get_env(:jumpwire, MySQL)
    params = [
      hostname: "localhost",
      port: conf[:port],
      username: mysql_manifest.id,
      password: token,
      database: "jumpwire_test",
      backoff_type: :stop,
      max_restarts: 0,
      show_sensitive_data_on_connection_error: true,
    ]
    %{params: params, manifest: mysql_manifest, classified_manifest: classified_manifest}
  end

  setup_all %{manifest: manifest} do
    # connect directly to the database and insert some data
    db_params = [
      hostname: manifest.configuration["hostname"],
      username: manifest.credentials["username"],
      password: manifest.credentials["password"],
      database: manifest.configuration["database"],
      port: manifest.configuration["port"],
    ]
    with {database, params} <- Keyword.pop(db_params, :database),
         {:ok, pid} <- MyXQL.start_link(params),
         {:ok, _} <- MyXQL.query(pid, "DROP DATABASE IF EXISTS #{database}", [], query_type: :text),
         {:ok, _} <- MyXQL.query(pid, "CREATE DATABASE #{database}", [], query_type: :text) do
      GenServer.stop(pid)
    end

    assert {:ok, conn} = MyXQL.start_link(db_params)
    table = "test_secret_data_#{ExUnit.configuration()[:seed]}"

    org_id = manifest.organization_id
    schema = %JumpWire.Proxy.Schema{
      fields: %{"$.value" => ["secret"], "$.phone" => ["phone_number"]},
      id: Uniq.UUID.uuid4(),
      manifest_id: manifest.id,
      name: table,
      organization_id: org_id,
    }
    schemas = [{{org_id, schema.manifest_id, schema.id}, schema}]
    JumpWire.GlobalConfig.set(:proxy_schemas, org_id, schemas)

    {:ok, _} = MyXQL.query(conn, "create table #{table} (id SERIAL, value text, phone text);", [])
    on_exit fn ->
      MyXQL.query(conn, "drop table #{table};", [])
      MyXQL.query(conn, "drop table jumpwire_proxy_schema_fields;", [])
    end

    %{conn: conn, table: table, schema: schema}
  end

  setup %{conn: conn, table: table} do
    on_exit fn ->
      opts = [query_type: :text]
      MyXQL.query!(conn, "drop function if exists jumpwire_encrypt_v1;", [], opts)
      MyXQL.query!(conn, "drop function if exists jumpwire_hash_v1;", [], opts)
      MyXQL.query!(conn, "truncate #{table}", [])
      %{rows: triggers} = MyXQL.query!(conn, "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_TABLE = '#{table}'")
      Enum.each(triggers, fn [trigger] ->
        MyXQL.query!(conn, "DROP TRIGGER #{trigger}", [], opts)
      end)
    end
  end

  test "replacing of encryption key", %{conn: conn, manifest: manifest} do
    assert :ok == MySQL.Setup.enable_database(manifest)

    assert {:ok, type} = MySQL.Setup.db_type(conn)
    aes_mode =
      case type do
        :mariadb -> :ecb
        _ -> :cbc
      end

    {key, _} = JumpWire.Vault.default_aes_key(manifest.organization_id, aes_mode)
    key = Base.encode16(key)

    name = MySQL.Setup.encrypt_function_name()
    %{rows: [row]} = MyXQL.query!(conn, "SHOW CREATE FUNCTION #{name}")
    [_, _, body | _] = row
    [_, db_key] = Regex.run(~r/secret_key .* UNHEX\('(\w+)'\)/, body)

    assert db_key == key
  end

  test "removing capability flag" do
    expected_flags = Enum.sort([
      :client_protocol_41,
      :client_plugin_auth,
      :client_secure_connection,
      :client_found_rows,
      :client_multi_results,
      :client_multi_statements,
      :client_transactions
    ])
    flags = MyXQL.Protocol.Flags.put_capability_flags([:client_deprecate_eof | expected_flags])
    assert MyXQL.Protocol.Flags.has_capability_flag?(flags, :client_deprecate_eof)
    flags = MySQL.Messages.unset_capability_flag(flags, :client_deprecate_eof)
    refute MyXQL.Protocol.Flags.has_capability_flag?(flags, :client_deprecate_eof)
    assert expected_flags == MyXQL.Protocol.Flags.list_capability_flags(flags) |> Enum.sort()
  end

  test "authenticate with manifest token", %{params: params} do
    assert {:ok, pid} = MyXQL.start_link(params)
    assert {:ok, _} = MyXQL.query(pid, "show tables;", [])
  end

  test "authenticate with original credentials fails", %{params: params} do
    params = params
    |> Keyword.replace(:password, "root")
    |> Keyword.replace(:username, "root")

    Process.flag(:trap_exit, true)

    assert {:ok, pid} = MyXQL.start_link(params)
    assert catch_exit(MyXQL.query(pid, "show tables;"))
  end

  test "querying for null values", %{params: params, table: table} do
    {:ok, conn} = MyXQL.start_link(params)
    val = "123"
    assert {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", [val])
    assert {:ok, %{rows: [[^val, nil]]}} = MyXQL.query(conn, "select value, phone from #{table};")
    assert {:ok, %{rows: [[^val, nil]]}} = MyXQL.query(conn, "select value, phone from #{table};", [], query_type: :text)

    # have enough columns returned that more than one byte is used for the null bitmap
    query = """
    select value, value as v2, phone, value as v3, phone as p2, phone as p3,
    true, false, value as v4, phone as p4, null from #{table}
    """
    assert {:ok, %{rows: [row]}} = MyXQL.query(conn, query)
    assert [val, val, nil, val, nil, nil, 1, 0, val, nil, nil] == row
  end

  test "decrypt data based on manifest classification", %{
    params: params, conn: conn, table: table, schema: schema, manifest: manifest
  } do
    value = "123-45-6789"
    assert :ok == MySQL.Setup.enable_database(manifest)
    assert :ok == MySQL.Setup.enable_table(manifest, schema)

    # insert directly, outside of jumpwire
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", [value])
    assert {:ok, %{rows: [[encrypted]]}} = MyXQL.query(conn, "select value from #{table};", [])
    refute value == encrypted

    # query from jumpwire
    {:ok, pid} = MyXQL.start_link(params)
    assert {:ok, %{rows: [[^value]]}} = MyXQL.query(pid, "select value from #{table};", [])
    assert {:ok, %{rows: [[^value]]}} = MyXQL.query(pid, "select value as secret from #{table};", [])
  end

  test "db manifest classification skips encryption", %{
    params: params, conn: conn, table: table, schema: schema, classified_manifest: manifest
  } do
    params = Keyword.put(params, :username, manifest.id)

    value = "123-45-6789"
    assert :ok == MySQL.Setup.enable_database(manifest)
    assert :ok == MySQL.Setup.enable_table(manifest, schema)

    # insert directly, outside of jumpwire
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", [value])
    assert {:ok, %{rows: [[^value]]}} = MyXQL.query(conn, "select value from #{table};")

    # query from jumpwire
    {:ok, pid} = MyXQL.start_link(params)
    assert {:ok, %{rows: [[^value]]}} = MyXQL.query(pid, "select value from #{table};")
  end

  test "disconnect when a manifest is deleted", %{params: params, manifest: manifest} do
    assert {:ok, pid} = MyXQL.start_link(params)
    assert {:ok, _} = MyXQL.query(pid, "select null;", [])
    JumpWire.PubSub.broadcast!("*", {:delete, :manifest, manifest})
    assert {:error, _} = MyXQL.query(pid, "select null;", [])
  end

  test "encrypted column stats", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = MySQL.Setup.enable_database(manifest)
    :ok = MySQL.Setup.enable_table(manifest, schema)

    stats = MySQL.Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 0, target: 0}
    assert stats[:encrypted] == %{"value" => %{count: 0, target: 0}}
    assert stats[:tokenized] == %{"phone" => %{count: 0, target: 0}}

    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    stats = MySQL.Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 1, target: 1}
    assert stats[:encrypted] == %{"value" => %{count: 1, target: 1}}
    assert stats[:tokenized] == %{"phone" => %{count: 1, target: 1}}

    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", ["123-456-7890"])
    stats = MySQL.Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 3, target: 3}
    assert stats[:encrypted] == %{"value" => %{count: 3, target: 3}}
    assert stats[:tokenized] == %{"phone" => %{count: 3, target: 3}}
  end

  test "decrypted column stats reflect policy changes", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = MySQL.Setup.enable_database(manifest)
    :ok = MySQL.Setup.enable_table(manifest, schema)

    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", ["123-456-7890"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", ["123-456-7890"])

    # NOTE by resetting global config, this test cannot run in parallel with others
    org_id = manifest.organization_id
    policies = JumpWire.Policy.list_all(org_id)

    no_encryption =
      policies
      |> Enum.map(fn policy ->
        case policy.label do
          "secret" -> {{org_id, policy.id}, %{policy | label: "notsecret"}}
          _ -> {{org_id, policy.id}, policy}
        end
      end)
      |> Map.new()

    JumpWire.GlobalConfig.set(:policies, org_id, no_encryption)

    stats = MySQL.Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 4, target: 4}
    assert stats[:encrypted] == %{"value" => %{count: 4, target: 0}}

    # Revert policy change
    reset_policies(policies, org_id)
  end

  test "decrypted column stats reflect schema label changes", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = MySQL.Setup.enable_database(manifest)
    :ok = MySQL.Setup.enable_table(manifest, schema)

    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", ["123-456-7890"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", ["123-456-7890"])

    org_id = manifest.organization_id
    schema = %JumpWire.Proxy.Schema{
      fields: %{"$.phone" => ["phone_number"]},
      id: Uniq.UUID.uuid4(),
      manifest_id: manifest.id,
      name: table,
      organization_id: org_id,
    }

    stats = MySQL.Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 4, target: 4}
    assert stats[:encrypted] == %{"value" => %{count: 4, target: 0}}
  end

  test "detokenized column stats reflects policy change", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = MySQL.Setup.enable_database(manifest)
    :ok = MySQL.Setup.enable_table(manifest, schema)

    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", ["123-456-7890"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", ["123-456-7890"])

    # NOTE by resetting global config, this test cannot run in parallel with others
    org_id = manifest.organization_id
    policies = JumpWire.Policy.list_all(org_id)

    no_tokenization =
      policies
      |> Enum.map(fn policy ->
        case policy.label do
          "phone_number" -> {{org_id, policy.id}, %{policy | label: "notphone_number"}}
          _ -> {{org_id, policy.id}, policy}
        end
      end)
      |> Map.new()

    JumpWire.GlobalConfig.set(:policies, org_id, no_tokenization)

    stats = MySQL.Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 4, target: 4}
    assert stats[:tokenized] == %{"phone" => %{count: 4, target: 0}}

    # Revert policy change
    reset_policies(policies, org_id)
  end

  test "detokenized column stats reflects schema label change", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = MySQL.Setup.enable_database(manifest)
    :ok = MySQL.Setup.enable_table(manifest, schema)

    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", ["123-45-6789"])
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", ["123-456-7890"])

    org_id = manifest.organization_id
    schema = %JumpWire.Proxy.Schema{
      fields: %{"$.value" => ["secret"]},
      id: Uniq.UUID.uuid4(),
      manifest_id: manifest.id,
      name: table,
      organization_id: org_id,
    }

    stats = MySQL.Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 2, target: 2}
    assert stats[:tokenized] == %{"phone" => %{count: 2, target: 0}}
  end

  test "cannot access manifests from different orgs", %{manifest: manifest, params: params} do
    other_manifest = %{manifest | id: Uniq.UUID.uuid4(), organization_id: Ecto.UUID.generate()}
    JumpWire.GlobalConfig.put(:manifests, other_manifest)

    Process.flag(:trap_exit, true)

    {:ok, conn} = params
    |> Keyword.replace(:username, other_manifest.id)
    |> MyXQL.start_link()

    assert catch_exit(MyXQL.query(conn, "show tables;"))
  end

  test "de-tokenize data based on manifest classification", %{
    params: params, conn: conn, table: table, schema: schema, manifest: manifest
  } do
    value = "555-123-4567"
    table_size = byte_size(table)
    prefix = <<"JWTOKN", 36, manifest.id::binary, table_size, table::binary, 5::32, "phone">>
    expected = prefix <> :crypto.hash(:sha256, value) |> Base.encode64()

    assert :ok == MySQL.Setup.enable_database(manifest)
    assert :ok == MySQL.Setup.enable_table(manifest, schema)

    # insert directly, outside of jumpwire
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", [value])
    assert {:ok, %{rows: [[token]]}} = MyXQL.query(conn, "select phone from #{table};", [])
    assert expected == token

    assert {:ok, %{rows: [[encrypted]]}} = MyXQL.query(conn, "select phone_jw_enc from #{table};", [])
    assert {:ok, ^value, _} = JumpWire.Vault.decrypt_and_decode(encrypted, manifest.organization_id)

    # query from jumpwire
    {:ok, pid} = MyXQL.start_link(params)
    assert {:ok, %{rows: [[^value]]}} = MyXQL.query(pid, "select phone from #{table};", [])
    assert {:ok, %{rows: [[^value]]}} = MyXQL.query(pid, "select phone as secret from #{table};", [])
  end

  test "db manifest classification skips tokenization", %{
    params: params, conn: conn, table: table, schema: schema, classified_manifest: manifest
  } do
    params = Keyword.put(params, :username, manifest.id)

    value1 = "555-123-4567"
    value2 = "555-987-6543"

    # insert directly, outside of jumpwire
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", [value1])

    assert :ok == MySQL.Setup.enable_database(manifest)
    assert :ok == MySQL.Setup.enable_table(manifest, schema)

    # insert directly, outside of jumpwire
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", [value2])

    # query from jumpwire
    {:ok, pid} = MyXQL.start_link(params)
    assert {:ok, %{rows: [[^value1], [^value2]]}} = MyXQL.query(pid, "select phone from #{table};", [])
  end

  test "tokenize raw data on the fly", %{
    params: params, conn: conn, table: table, manifest: manifest
  } do
    org_id = manifest.organization_id
    client = %ClientAuth{
      id: Uniq.UUID.uuid4(),
      name: "proxy auth",
      organization_id: org_id,
    }
    JumpWire.GlobalConfig.put(:client_auth, client)
    password = Application.get_env(:jumpwire, :proxy)[:secret_key]
    |> Plug.Crypto.sign("manifest", {org_id, client.id})
    params = Keyword.put(params, :password, password)

    value = "555-123-4567"
    len = byte_size(table)
    prefix = <<"JWTOKN", 36, manifest.id::binary, len, table::binary, 5::32, "phone">>
    token = prefix <> :crypto.hash(:sha256, value) |> Base.encode64()

    # insert directly outside of jumpwire
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (phone) values (?);", [value])

    {:ok, pid} = MyXQL.start_link(params)
    assert {:ok, %{rows: [[^token]]}} = MyXQL.query(pid, "select phone from #{table};")
  end

  test "disabling of a manifest", %{
    conn: conn, table: table, schema: schema, manifest: manifest
  } do
    value = "123-45-6789"
    assert :ok == MySQL.Setup.enable_database(manifest)
    assert :ok == MySQL.Setup.enable_table(manifest, schema)

    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", [value])
    assert {:ok, %{rows: [[encrypted]]}} = MyXQL.query(conn, "select value from #{table}")
    refute value == encrypted

    assert :ok == MySQL.Setup.disable_database(manifest)
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", [value])
    assert {:ok, %{rows: [_row1, [^value]]}} = MyXQL.query(conn, "select value from #{table}")
  end

  test "tracks query time (query_type=text)", %{params: params, table: table} do
    {:ok, pid} = MyXQL.start_link(params)
    self = self()

    :telemetry.attach(
      "test-#{table}-text",
      [:database, :client],
      fn name, measurements, _metadata, _ ->
        assert measurements.count == 1
        assert measurements.duration > 0
        send(self, {:telemetry_event, name, measurements})
      end,
      nil
    )

    # For text queries we need to run two queries, so the previous one is tracked. This happens because,
    # in the event of multi-resultset, I couldn't find a deterministic way to know for sure a query has
    # completed. For more context, please refer to the corresponding function at the MySQL proxy.
    assert {:ok, %{rows: []}} = MyXQL.query(pid, "select value from #{table};", [], query_type: :text)
    assert {:ok, %{rows: []}} = MyXQL.query(pid, "select value from #{table};", [], query_type: :text)
    assert_receive {:telemetry_event, [:database, :client], _}
  end

  test "tracks query time (query_type=binary)", ctx = %{params: params, table: table} do
    {:ok, pid} = MyXQL.start_link(params)
    self = self()

    :telemetry.attach(
      "test-#{table}-binary",
      [:database, :client],
      fn name, measurements, metadata, _ ->
        assert metadata.client == ctx.client.id
        assert metadata.database == ctx.manifest.configuration["database"]
        assert metadata.organization == ctx.org_id

        assert measurements.count == 1
        assert measurements.duration > 0
        send(self, {:telemetry_event, name, measurements})
      end,
      nil
    )

    # For binary queries we don't need to run multiple queries, as the `COM_STMT_CLOSE` message
    # will trigger the query timer.
    assert {:ok, %{rows: []}} = MyXQL.query(pid, "select value from #{table};", [])
    assert_receive {:telemetry_event, [:database, :client], _}
  end

  # Regression test for JW-538.
  test "preserves smaller integer type for binary queries", %{
    conn: conn, params: params
  } do
    # Prepare table with 3-byte integer column, filled with single row.
    table_name = "photos"
    {:ok, _} = MyXQL.query(conn, "create table #{table_name} (id MEDIUMINT);", [])
    on_exit fn ->
      MyXQL.query(conn, "drop table #{table_name};", [])
    end
    random_id = Enum.random(1..10_000)
    assert {:ok, _} = MyXQL.query(conn, "insert into #{table_name} (id) values (?);", [random_id])

    # Fetch column with additional EOF-like marker, to avoid accidental match.
    {:ok, proxy_conn} = MyXQL.start_link(params)
    query = """
    select id, "STOP" from #{table_name}
    """
    assert {:ok, %{rows: [row]}} = MyXQL.query(proxy_conn, query, [], query_type: :binary)
    assert [random_id, "STOP"] == row
  end

  test "rotate keys for encryption functions", %{
    conn: conn, table: table, schema: schema, manifest: manifest
  } do
    # setup initial functions
    assert :ok == MySQL.Setup.enable_database(manifest)
    assert :ok == MySQL.Setup.enable_table(manifest, schema)

    value = "123-45-6789"

    # insert directly to encrypt the data
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", [value])

    # rotate keys
    assert :ok = JumpWire.Vault.rotate(manifest.organization_id)
    assert :ok == MySQL.Setup.enable_database(manifest)

    # insert directly with the new keys
    {:ok, _} = MyXQL.query(conn, "insert into #{table} (value) values (?);", [value])

    # check the data
    assert {:ok, %{rows: [[enc1], [enc2]]}} = MyXQL.query(conn, "select value from #{table};", [])
    refute value == enc1
    refute value == enc2
    refute JumpWire.Vault.peek_tag!(enc1) == JumpWire.Vault.peek_tag!(enc2)
  end

  defp reset_policies(policies, org_id) do
    reset =
      policies
      |> Enum.map(fn policy -> {{org_id, policy.id}, policy} end)
      |> Map.new()
    JumpWire.GlobalConfig.set(:policies, org_id, reset)
  end
end
