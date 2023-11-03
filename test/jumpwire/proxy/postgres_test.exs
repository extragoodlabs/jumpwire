defmodule JumpWire.Proxy.PostgresTest do
  use JumpWire.ProxyCase, async: false
  alias JumpWire.Proxy.Postgres.Setup

  @moduletag db: "postgres"

  setup_all %{org_id: org_id, token: token} do
    # attempt to use SSL if not running in CI
    ssl = System.get_env("CI", "false") |> String.to_existing_atom() |> Kernel.not()
    pg_manifest = %Manifest{
      root_type: :postgresql,
      id: Uniq.UUID.uuid4(),
      name: "test pg db",
      configuration: %{
        "hostname" => "localhost",
        "database" => "postgres",
        "ssl" => ssl,
        "vault_database" => nil,
        "vault_role" => nil,
      },
      credentials: %{
        "username" => "postgres",
        "password" => "postgres",
      },
      organization_id: org_id,
    }
    JumpWire.GlobalConfig.put(:manifests, pg_manifest)
    JumpWire.Manifest.hook(pg_manifest, :insert) |> Task.await()
    classified_manifest = %{pg_manifest | classification: "Internal", id: Uniq.UUID.uuid4()}
    JumpWire.GlobalConfig.put(:manifests, classified_manifest)
    JumpWire.Manifest.hook(classified_manifest, :insert) |> Task.await()

    conf = Application.get_env(:jumpwire, JumpWire.Proxy.Postgres)
    params = [
      hostname: "localhost",
      port: conf[:port],
      username: pg_manifest.id,
      password: token,
      database: "postgres",
      backoff_type: :stop,
      max_restarts: 0,
    ]

    %{params: params, manifest: pg_manifest, classified_manifest: classified_manifest}
  end

  setup_all %{manifest: manifest} do
    # connect directly to the database and insert some data
    db_params = [
      hostname: manifest.configuration["hostname"],
      username: manifest.credentials["username"],
      password: manifest.credentials["password"],
      database: manifest.configuration["database"],
    ]
    assert {:ok, conn} = Postgrex.start_link(db_params)
    table = "test_secret_data_#{ExUnit.configuration()[:seed]}"
    table2 = "test_secret_data_joins_#{ExUnit.configuration()[:seed]}"

    org_id = manifest.organization_id
    schema = %JumpWire.Proxy.Schema{
      fields: %{"$.value" => ["secret"], "$.phone" => ["phone_number"]},
      id: Uniq.UUID.uuid4(),
      manifest_id: manifest.id,
      name: table,
      organization_id: org_id,
    }
    schema2 = %JumpWire.Proxy.Schema{
      fields: %{"$.value" => ["secret"]},
      id: Uniq.UUID.uuid4(),
      manifest_id: manifest.id,
      name: table2,
      organization_id: org_id,
    }
    schemas = [{{org_id, schema.manifest_id, schema.id}, schema}, {{org_id, schema.manifest_id, schema2.id}, schema2}]
    JumpWire.GlobalConfig.set(:proxy_schemas, org_id, schemas)

    {:ok, _} = Postgrex.query(conn, "create table #{table} (id SERIAL PRIMARY KEY, value text, phone text);", [])
    {:ok, _} = Postgrex.query(conn, "create table #{table2} (id SERIAL PRIMARY KEY, value TEXT, #{table}_id integer);", [])
    on_exit fn ->
      Postgrex.query(conn, "drop table #{table2};", [])
      Postgrex.query(conn, "drop table #{table};", [])
      Postgrex.query(conn, "drop table jumpwire_proxy_schema_fields;", [])
    end

    %{conn: conn, table: table, table2: table2, schema: schema, schema2: schema2}
  end

  setup %{conn: conn, table: table, table2: table2} do
    on_exit fn ->
      Postgrex.query!(conn, "drop function if exists jumpwire_update_encrypt cascade;", [])
      Postgrex.query!(conn, "drop function if exists jumpwire_update_tokenize cascade;", [])
      Postgrex.query!(conn, "drop function if exists jumpwire_encrypt cascade;", [])
      Postgrex.query!(conn, "drop function if exists jumpwire_hash cascade;", [])
      Postgrex.query!(conn, "truncate #{table} cascade", [])
      Postgrex.query!(conn, "truncate #{table2} cascade", [])
    end
  end

  test "authenticate with manifest token", %{params: params} do
    assert {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, _} = Postgrex.query(pid, "select * from pg_catalog.pg_tables;", [])
  end

  test "authenticate using SSL", %{params: params} do
    # Generate a self-signed certificate
    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca_cert = X509.Certificate.self_signed(ca_key, "/CN=Root CA", template: :root_ca)
    key = X509.PrivateKey.new_rsa(2048)
    cert = key
    |> X509.PublicKey.derive()
    |> X509.Certificate.new(
      "/CN=Self-signed",
      ca_cert,
      ca_key,
      template: :server,
      extensions: [
        subject_alt_name: X509.Certificate.Extension.subject_alt_name(["localhost"])
      ]
    )

    # save the certs and key to disk
    path = "/tmp/#{ExUnit.configuration()[:seed]}_pg"
    keyfile = path <> "_key.pem"
    certfile = path <> ".pem"
    cacertfile = path <> "_ca.pem"
    File.write!(keyfile, X509.PrivateKey.to_pem(key))
    File.write!(certfile, X509.Certificate.to_pem(cert))
    File.write!(cacertfile, X509.Certificate.to_pem(ca_cert))

    proxy_opts = Application.get_env(:jumpwire, :proxy)
    on_exit fn ->
      Application.put_env(:jumpwire, :proxy, proxy_opts)
      Enum.each([keyfile, certfile, cacertfile], &File.rm_rf!/1)
    end

    # update the proxy server to use the SSL cert
    proxy_opts = proxy_opts
    |> Keyword.put(:server_ssl, [certfile: certfile, keyfile: keyfile, verify_fun: &:ssl_verify_hostname.verify_fun/3])
    |> Keyword.put(:use_sni, false)
    Application.put_env(:jumpwire, :proxy, proxy_opts)

    # connect with SSL
    sni = params[:hostname] |> String.to_charlist()
    params = params
    |> Keyword.put(:ssl, true)
    |> Keyword.put(:ssl_opts, [cacertfile: cacertfile, verify: :verify_peer, server_name_indication: sni])
    assert {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, _} = Postgrex.query(pid, "select * from pg_catalog.pg_tables;", [])
  end

  test "authenticate with original credentials fails", %{params: params} do
    params = params
    |> Keyword.replace(:password, "postgres")
    |> Keyword.replace(:username, "postgres")

    Process.flag(:trap_exit, true)

    assert {:ok, pid} = Postgrex.start_link(params)
    assert {:error, %DBConnection.ConnectionError{}} = Postgrex.query(pid, "select * from pg_catalog.pg_tables;", [])
  end

  test "decrypt data based on manifest classification", %{
    params: params, conn: conn, table: table, schema: schema, manifest: manifest
  } do
    value = "123-45-6789"
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)

    # insert directly, outside of jumpwire
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", [value])
    assert {:ok, %{rows: [[encrypted]]}} = Postgrex.query(conn, "select value from #{table};", [])
    refute value == encrypted

    # query from jumpwire
    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, %{rows: [[^value]]}} = Postgrex.query(pid, "select value from #{table};", [])
    assert {:ok, %{rows: [[^value]]}} = Postgrex.query(pid, "select value as secret from #{table};", [])
  end

  test "db manifest classification skips encryption", %{
    params: params, conn: conn, table: table, schema: schema, classified_manifest: manifest
  } do
    params = Keyword.put(params, :username, manifest.id)

    value = "123-45-6789"
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)

    # insert directly, outside of jumpwire
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", [value])
    assert {:ok, %{rows: [[result]]}} = Postgrex.query(conn, "select value from #{table};", [])
    assert value == result

    # query from jumpwire
    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, %{rows: [[^value]]}} = Postgrex.query(pid, "select value from #{table};", [])
  end

  test "disconnect when a manifest is deleted", %{params: params, manifest: manifest} do
    assert {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, _} = Postgrex.query(pid, "select null;", [])
    JumpWire.PubSub.broadcast!("*", {:delete, :manifest, manifest})
    assert {:error, _} = Postgrex.query(pid, "select null;", [])
  end

  test "encrypted column stats", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = Setup.enable_database(manifest)
    :ok = Setup.enable_table(manifest, schema)

    stats = Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 0, target: 0}
    assert stats[:encrypted] == %{"value" => %{count: 0, target: 0}}
    assert stats[:tokenized] == %{"phone" => %{count: 0, target: 0}}

    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    stats = Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 1, target: 1}
    assert stats[:encrypted] == %{"value" => %{count: 1, target: 1}}
    assert stats[:tokenized] == %{"phone" => %{count: 1, target: 1}}

    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", ["123-456-7890"])
    stats = Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 3, target: 3}
    assert stats[:encrypted] == %{"value" => %{count: 3, target: 3}}
    assert stats[:tokenized] == %{"phone" => %{count: 3, target: 3}}
  end

  test "decrypted column stats reflect policy changes", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = Setup.enable_database(manifest)
    :ok = Setup.enable_table(manifest, schema)

    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", ["123-456-7890"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", ["123-456-7890"])

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

    stats = Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 4, target: 4}
    assert stats[:encrypted] == %{"value" => %{count: 4, target: 0}}
  end

  test "decrypted column stats reflect schema label changes", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = Setup.enable_database(manifest)
    :ok = Setup.enable_table(manifest, schema)

    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", ["123-456-7890"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", ["123-456-7890"])

    org_id = manifest.organization_id
    schema = %JumpWire.Proxy.Schema{
      fields: %{"$.phone" => ["phone_number"]},
      id: Uniq.UUID.uuid4(),
      manifest_id: manifest.id,
      name: table,
      organization_id: org_id,
    }

    stats = Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 4, target: 4}
    assert stats[:encrypted] == %{"value" => %{count: 4, target: 0}}
  end

  test "detokenized column stats reflects policy change", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = Setup.enable_database(manifest)
    :ok = Setup.enable_table(manifest, schema)

    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", ["123-456-7890"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", ["123-456-7890"])

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

    stats = Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 4, target: 4}
    assert stats[:tokenized] == %{"phone" => %{count: 4, target: 0}}
  end

  test "detokenized column stats reflects schema label change", %{conn: conn, manifest: manifest, schema: schema, table: table} do
    :ok = Setup.enable_database(manifest)
    :ok = Setup.enable_table(manifest, schema)

    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", ["123-45-6789"])
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", ["123-456-7890"])

    org_id = manifest.organization_id
    schema = %JumpWire.Proxy.Schema{
      fields: %{"$.value" => ["secret"]},
      id: Uniq.UUID.uuid4(),
      manifest_id: manifest.id,
      name: table,
      organization_id: org_id,
    }

    stats = Setup.table_stats(manifest, schema)
    assert stats[:rows] == %{count: 2, target: 2}
    assert stats[:tokenized] == %{"phone" => %{count: 2, target: 0}}
  end

  test "cannot access manifests from different orgs", %{manifest: manifest, params: params} do
    other_manifest = %{manifest | id: Uniq.UUID.uuid4(), organization_id: Ecto.UUID.generate()}
    JumpWire.GlobalConfig.put(:manifests, other_manifest)

    Process.flag(:trap_exit, true)

    {:ok, conn} = params
    |> Keyword.replace(:username, other_manifest.id)
    |> Postgrex.start_link()

    assert capture_log(fn ->
      assert catch_exit(Postgrex.query(conn, "select * from pg_catalog.pg_tables;", []))
    end) =~ "invalid_password"
  end

  test "de-tokenize data based on manifest classification", %{
    params: params, conn: conn, table: table, schema: schema, manifest: manifest
  } do
    value = "555-123-4567"
    %{rows: [[oid]]} = Postgrex.query!(conn, "select table_name::regclass::oid from information_schema.tables where table_name = $1;", [table])
    prefix = <<"JWTOKN", 36, manifest.id::binary, 4, oid::32, 5::32, "phone">>
    expected = prefix <> :crypto.hash(:sha256, value) |> Base.encode64()

    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)

    # insert directly, outside of jumpwire
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", [value])
    assert {:ok, %{rows: [[token]]}} = Postgrex.query(conn, "select phone from #{table};", [])
    assert expected == token

    assert {:ok, %{rows: [[encrypted]]}} = Postgrex.query(conn, "select phone_jw_enc from #{table};", [])
    assert {:ok, ^value, _} = JumpWire.Vault.decrypt_and_decode(encrypted, manifest.organization_id)

    # query from jumpwire
    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, %{rows: [[^value]]}} = Postgrex.query(pid, "select phone from #{table};", [])
    assert {:ok, %{rows: [[^value]]}} = Postgrex.query(pid, "select phone as secret from #{table};", [])
  end

  test "db manifest classification skips tokenization", %{
    params: params, conn: conn, table: table, schema: schema, classified_manifest: manifest
  } do
    params = Keyword.put(params, :username, manifest.id)

    value1 = "555-123-4567"
    value2 = "555-987-6543"

    # insert directly, outside of jumpwire
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", [value1])

    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)

    # insert directly, outside of jumpwire
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", [value2])

    # query from jumpwire
    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, %{rows: [[^value1], [^value2]]}} = Postgrex.query(pid, "select phone from #{table};", [])
  end

  test "tokenize raw data on the fly", %{
    params: params, conn: conn, table: table, manifest: manifest
  } do
    org_id = manifest.organization_id
    client = %ClientAuth{
      id: Uniq.UUID.uuid4(),
      name: "pg auth",
      organization_id: org_id,
    }
    JumpWire.GlobalConfig.put(:client_auth, client)
    key = Application.get_env(:jumpwire, :proxy)[:secret_key]
    password = Plug.Crypto.sign(key, "manifest", {org_id, client.id})
    params = Keyword.put(params, :password, password)

    value = "555-123-4567"
    %{rows: [[oid]]} = Postgrex.query!(conn, "select table_name::regclass::oid from information_schema.tables where table_name = $1;", [table])
    prefix = <<"JWTOKN", 36, manifest.id::binary, 4, oid::32, 5::32, "phone">>
    token = prefix <> :crypto.hash(:sha256, value) |> Base.encode64()

    # insert directly outside of jumpwire
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (phone) values ($1);", [value])

    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, %{rows: [[^token]]}} = Postgrex.query(pid, "select phone from #{table};", [])

    # check that aliasing the field doesn't change the token
    assert {:ok, %{rows: [[^token]]}} = Postgrex.query(pid, "select phone as not_phone from #{table};", [])
  end

  test "tracks query time", ctx = %{params: params, table: table} do
    {:ok, conn} = Postgrex.start_link(params)
    pid = self()
    handler_id = "test-#{table}"

    :telemetry.attach(
      handler_id,
      [:database, :client],
      fn name, measurements, metadata, _ ->
        send(pid, {:telemetry_event, name, metadata, measurements})
      end,
      nil
    )

    assert {:ok, %{rows: []}} = Postgrex.query(conn, "select value from #{table};", [])

    # We'll actually receive two measurements because Postgrex performs a bootstrap query.
    # For our test purposes, that's entirely okay and there's no need to filter it out.
    assert_receive {:telemetry_event, [:database, :client], metadata, measurements}
    assert metadata.client == ctx.client.id
    assert metadata.database == ctx.manifest.configuration["database"]
    assert metadata.organization == ctx.org_id
    assert measurements.count == 1
    assert measurements.duration > 0

    :telemetry.detach(handler_id)
  end

  test "reversing of tokens from the DB", %{
    conn: conn, table: table, manifest: manifest, schema: schema
  } do
    org_id = manifest.organization_id
    :ok = Setup.enable_database(manifest)
    :ok = Setup.enable_table(manifest, schema)
    JumpWire.GlobalConfig.set(:manifest_metadata, org_id, [])

    [[_, _, phone] | _] = conn
    |> insert_fake_rows(table)
    |> Enum.reject(fn [_, _, phone] -> is_nil(phone) end)

    {:ok, %{rows: [[token, _] | _]}} =
      Postgrex.query(conn, "select phone, phone_jw_enc from #{table} where phone is not null order by id asc;", [])

    assert {:ok, token} = JumpWire.Token.decode(token)
    assert [] ==
      JumpWire.GlobalConfig.all(:manifest_metadata, {:_, manifest.id, :_})

    assert {:ok, phone, []} ==
      JumpWire.Token.reverse_token(org_id, token)

    # Check that the table name is cached from the token OID
    assert [table] ==
      JumpWire.GlobalConfig.all(:manifest_metadata, {:_, manifest.id, :_})
  end

  test "enabling table without encryption policy doesn't add handling columns", %{conn: conn, manifest: manifest, schema: schema} do
    org_id = manifest.organization_id
    policies = JumpWire.Policy.list_all(org_id)

    no_encryption = policies
    |> Enum.map(fn policy ->
      {{org_id, policy.id}, %{policy | label: "notsecret"}}
    end)
    |> Map.new()

    JumpWire.GlobalConfig.set(:policies, org_id, no_encryption)
    assert :ok == Setup.enable_database(manifest)
    :ok = Setup.enable_table(manifest, schema)

    {:ok, %{rows: columns}} = Postgrex.query(conn, Setup.sql_list_columns(), [schema.name])
    handle_columns = columns
    |> Stream.filter(fn [col_name, _col_type] ->
      String.ends_with?(col_name, "_jw_handle")
    end)

    assert true == Enum.empty?(handle_columns)
  end

  test "enabling then disabling table removes handling columns", %{conn: conn, manifest: manifest, schema: schema} do
    org_id = manifest.organization_id
    policies = JumpWire.Policy.list_all(org_id)
    :ok = Setup.enable_database(manifest)
    :ok = Setup.enable_table(manifest, schema)

    {:ok, %{rows: columns}} = Postgrex.query(conn, Setup.sql_list_columns(), [schema.name])
    handle_columns =
        columns
        |> Stream.filter(fn [col_name, _col_type] ->
          String.ends_with?(col_name, "_jw_handle")
        end)

    assert false == Enum.empty?(handle_columns)

    no_encryption =
      policies
      |> Enum.map(fn policy ->
        {{org_id, policy.id}, %{policy | label: "notsecret"}}
      end)
      |> Map.new()

    JumpWire.GlobalConfig.set(:policies, org_id, no_encryption)
    :ok = Setup.enable_table(manifest, schema)

    {:ok, %{rows: columns}} = Postgrex.query(conn, Setup.sql_list_columns(), [schema.name])
    handle_columns =
        columns
        |> Stream.filter(fn [col_name, _col_type] ->
          String.ends_with?(col_name, "_jw_handle")
        end)

    assert true == Enum.empty?(handle_columns)
  end

  test "disabling of a manifest", %{conn: conn, table: table, manifest: manifest, schema: schema} do
    value = "123-45-6789"
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)

    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", [value])
    assert {:ok, %{rows: [[encrypted]]}} = Postgrex.query(conn, "select value from #{table}", [])
    refute value == encrypted

    assert :ok == Setup.disable_database(manifest)
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", [value])
    assert {:ok, %{rows: [_row1, [^value]]}} = Postgrex.query(conn, "select value from #{table}", [])
  end

  test "parsing of large queries", %{params: params} do
    query = """
    SELECT "con"."conname" AS "constraint_name", "con"."nspname" AS "table_schema", "con"."relname" AS "table_name", "att2"."attname" AS "column_name", "ns"."nspname" AS "referenced_table_schema", "cl"."relname" AS "referenced_table_name", "att"."attname" AS "referenced_column_name", "con"."confdeltype" AS "on_delete", "con"."confupdtype" AS "on_update", "con"."condeferrable" AS "deferrable", "con"."condeferred" AS "deferred" FROM ( SELECT UNNEST ("con1"."conkey") AS "parent", UNNEST ("con1"."confkey") AS "child", "con1"."confrelid", "con1"."conrelid", "con1"."conname", "con1"."contype", "ns"."nspname", "cl"."relname", "con1"."condeferrable", CASE WHEN "con1"."condeferred" THEN 'INITIALLY DEFERRED' ELSE 'INITIALLY IMMEDIATE' END as condeferred, CASE "con1"."confdeltype" WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT' WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END as "confdeltype", CASE "con1"."confupdtype" WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT' WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END as "confupdtype" FROM "pg_class" "cl" INNER JOIN "pg_namespace" "ns" ON "cl"."relnamespace" = "ns"."oid" INNER JOIN "pg_constraint" "con1" ON "con1"."conrelid" = "cl"."oid" WHERE "con1"."contype" = 'f' AND (("ns"."nspname" = 'public' AND "cl"."relname" = 'user') OR ("ns"."nspname" = 'public' AND "cl"."relname" = 'outbox') OR ("ns"."nspname" = 'public' AND "cl"."relname" = 'organisations') OR ("ns"."nspname" = 'public' AND "cl"."relname" = 'sessions')) ) "con" INNER JOIN "pg_attribute" "att" ON "att"."attrelid" = "con"."confrelid" AND "att"."attnum" = "con"."child" INNER JOIN "pg_class" "cl" ON "cl"."oid" = "con"."confrelid"  AND "cl"."relispartition" = 'f'INNER JOIN "pg_namespace" "ns" ON "cl"."relnamespace" = "ns"."oid" INNER JOIN "pg_attribute" "att2" ON "att2"."attrelid" = "con"."conrelid" AND "att2"."attnum" = "con"."parent"
    """

    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, _} = Postgrex.query(pid, query, [])
  end

  test "updating schema", %{conn: conn, manifest: manifest} do
    value = "123-45-6789"
    table = "test_secret_data_#{ExUnit.configuration()[:seed]}_update"

    manifest = %{manifest | id: Uniq.UUID.uuid4()}
    JumpWire.GlobalConfig.put(:manifests, manifest)

    org_id = manifest.organization_id
    schema = %JumpWire.Proxy.Schema{
      fields: %{"$.squirrel" => ["secret"]},
      id: Uniq.UUID.uuid4(),
      manifest_id: manifest.id,
      name: table,
      organization_id: org_id,
    }
    key = {org_id, schema.manifest_id, schema.id}
    JumpWire.GlobalConfig.put(:proxy_schemas, key, schema)

    {:ok, _} = Postgrex.query(conn, "create table #{table} (id SERIAL, PRIMARY KEY(id));", [])
    on_exit fn ->
      Postgrex.query(conn, "drop table #{table};", [])
    end

    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)

    {:ok, _} = Postgrex.query(conn, "alter table #{table} add squirrel text", [])

    # run a query to encrypt data
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (squirrel) values ($1);", [value])
    assert {:ok, %{rows: [[encrypted]]}} = Postgrex.query(conn, "select squirrel from #{table}", [])
    refute value == encrypted

    # reduce log noise
    JumpWire.GlobalConfig.delete(:proxy_schemas, key)
  end

  test "rotate keys for encryption functions", %{
    conn: conn, table: table, schema: schema, manifest: manifest
  } do
    # setup initial functions
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)

    value = "123-45-6789"

    # insert directly to encrypt the data
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", [value])

    # rotate keys
    assert :ok = JumpWire.Vault.rotate(manifest.organization_id)
    assert :ok == Setup.enable_database(manifest)

    # insert directly with the new keys
    {:ok, _} = Postgrex.query(conn, "insert into #{table} (value) values ($1);", [value])

    # check the data
    assert {:ok, %{rows: [[enc1], [enc2]]}} = Postgrex.query(conn, "select value from #{table};", [])
    refute value == enc1
    refute value == enc2
    refute JumpWire.Vault.peek_tag!(enc1) == JumpWire.Vault.peek_tag!(enc2)
  end

  test "columns with the same name are not erased during join", %{
    params: params, conn: conn, table: table, table2: table2, manifest: manifest, schema: schema, schema2: schema2
  } do
    assert :ok = Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)
    assert :ok == Setup.enable_table(manifest, schema2)

    data_rows = conn
    |> insert_fake_rows(table, table2)

    # query from jumpwire
    {:ok, pid} = Postgrex.start_link(params)
    {:ok, %{rows: db_rows}} = Postgrex.query(pid, """
      SELECT #{table}.id, #{table}.phone, #{table}.value AS "#{table}.value", #{table2}.value AS "#{table2}.value"
      FROM #{table} LEFT OUTER JOIN #{table2} ON #{table}.id = #{table2}.#{table}_id
      ORDER BY #{table}.id ASC;
      """, [])

    # expect that columns with same name retain original values through jumpwire
    db_rows
    |> Enum.zip(data_rows)
    |> Enum.each(fn {[_, _, value1, value2], {[data1, _], [data2]}} ->
      assert value1 == data1
      assert value2 == data2
    end)
  end

  test "access policy overrides block policies for db queries query", %{
    conn: conn, params: params, org_id: org_id, manifest: manifest, schema: schema, table: table
  } do
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)
    insert_fake_rows(conn, table)

    # allow selects only for secrets
    policy = %JumpWire.Policy{
      version: 2,
      id: Uniq.UUID.uuid4(),
      handling: :block,
      label: "secret",
      organization_id: org_id,
      attributes: [MapSet.new(["select:secret"])],
    }
    key = {org_id, policy.id}

    on_exit fn -> JumpWire.GlobalConfig.delete(:policies, key) end
    JumpWire.GlobalConfig.put(:policies, key, policy)

    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, %{rows: _rows}} = Postgrex.query(pid, "SELECT id, value FROM #{table}", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
      Postgrex.query(pid, "UPDATE #{table} SET value = 'abc'", [])
  end

  test "blocking of queries based on type of query", %{
    conn: conn, params: params, org_id: org_id, manifest: manifest, schema: schema, table: table, client: client
  } do
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)
    insert_fake_rows(conn, table)

    # create one policy to block all secrets access
    policy = %JumpWire.Policy{
      version: 2,
      id: Uniq.UUID.uuid4(),
      handling: :block,
      label: "secret",
      organization_id: org_id,
      attributes: [],
    }
    key = {org_id, policy.id}
    on_exit fn -> JumpWire.GlobalConfig.delete(:policies, key) end
    JumpWire.GlobalConfig.put(:policies, key, policy)

    # allow updates to secrets for this client
    policy = %JumpWire.Policy{
      version: 2,
      id: Uniq.UUID.uuid4(),
      handling: :access,
      label: "secret",
      organization_id: org_id,
      apply_on_match: true,
      attributes: [MapSet.new(["client:#{client.id}", "not:delete:secret"])],
    }
    key = {org_id, policy.id}
    on_exit fn -> JumpWire.GlobalConfig.delete(:policies, key) end
    JumpWire.GlobalConfig.put(:policies, key, policy)

    {:ok, pid} = Postgrex.start_link(params)

    assert {:ok, %{rows: _rows}} = Postgrex.query(pid, "UPDATE #{table} SET value = 'abc'", [])
  end

  test "blocking of queries without explicit fields", %{
    conn: conn, params: params, org_id: org_id, manifest: manifest, schema: schema, table: table
  } do
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)
    insert_fake_rows(conn, table)

    {:ok, pid} = Postgrex.start_link(params)

    # allow all operations for phone_number
    policy = %JumpWire.Policy{
      version: 2,
      id: Uniq.UUID.uuid4(),
      handling: :block,
      label: "phone_number",
      organization_id: org_id,
      attributes: [
        MapSet.new(["select:phone_number"]),
        MapSet.new(["update:phone_number"]),
        MapSet.new(["delete:phone_number"]),
      ],
    }
    key = {org_id, policy.id}
    on_exit fn -> JumpWire.GlobalConfig.delete(:policies, key) end
    JumpWire.GlobalConfig.put(:policies, key, policy)

    assert {:ok, _} = Postgrex.query(pid, "DELETE FROM #{table}", [])

    # allow selects only for secrets
    policy = %JumpWire.Policy{
      version: 2,
      id: Uniq.UUID.uuid4(),
      handling: :block,
      label: "secret",
      organization_id: org_id,
      attributes: [MapSet.new(["select:secret"])],
    }
    key = {org_id, policy.id}

    on_exit fn -> JumpWire.GlobalConfig.delete(:policies, key) end
    JumpWire.GlobalConfig.put(:policies, key, policy)

    assert {:ok, %{rows: _rows}} = Postgrex.query(pid, "SELECT id, value FROM #{table}", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
      Postgrex.query(pid, "DELETE FROM #{table}", [])
  end

  test "applying policies to wildcard inserts", %{
    conn: conn, params: params, org_id: org_id, manifest: manifest, schema: schema, table: table
  } do
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)
    insert_fake_rows(conn, table)

    # allow everything on secrets except inserts
    policy = %JumpWire.Policy{
      version: 2,
      id: Uniq.UUID.uuid4(),
      handling: :block,
      label: "secret",
      organization_id: org_id,
      apply_on_match: true,
      attributes: [MapSet.new(["insert:secret"])],
    }
    key = {org_id, policy.id}

    on_exit fn -> JumpWire.GlobalConfig.delete(:policies, key) end
    JumpWire.GlobalConfig.put(:policies, key, policy)

    {:ok, pid} = Postgrex.start_link(params)
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = Postgrex.query(
      pid,
      "INSERT INTO #{table} (value, phone) VALUES ($1, $2)",
      [Faker.Gov.Us.ssn(), Faker.Phone.EnUs.phone()]
    )

    {:ok, pid} = Postgrex.start_link(params)
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = Postgrex.query(
      pid,
      "INSERT INTO #{table} VALUES ($1, $2)",
      [Faker.Gov.Us.ssn(), Faker.Phone.EnUs.phone()]
    )

    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, _result} = Postgrex.query(
      pid,
      "INSERT INTO #{table} (phone) VALUES ($1)",
      [Faker.Phone.EnUs.phone()]
    )
  end

  test "applying policies to prepared statements", %{
    conn: conn, params: params, org_id: org_id, manifest: manifest, schema: schema, table: table
  } do
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)
    insert_fake_rows(conn, table)

    # allow everything on secrets except inserts
    policy = %JumpWire.Policy{
      version: 2,
      id: Uniq.UUID.uuid4(),
      handling: :block,
      label: "secret",
      organization_id: org_id,
      apply_on_match: true,
      attributes: [MapSet.new(["insert:secret"])],
    }
    key = {org_id, policy.id}

    on_exit fn -> JumpWire.GlobalConfig.delete(:policies, key) end
    JumpWire.GlobalConfig.put(:policies, key, policy)

    {:ok, pid} = Postgrex.start_link(params)
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
      Postgrex.prepare(
        pid,
        "",
        "INSERT INTO #{table} (value, phone) VALUES ($1, $2)"
      )
  end

  test "applying request filter policy", %{
    conn: conn, params: params, org_id: org_id, manifest: manifest, schema: schema, table: table
  } do
    JumpWire.GlobalConfig.set(:policies, org_id, [])
    assert :ok == Setup.enable_database(manifest)
    assert :ok == Setup.enable_table(manifest, schema)
    rows = insert_fake_rows(conn, table)
    [id, value, _] = rows
    |> Enum.find(fn [_, v, _] -> not is_nil(v) end)

    policy = %JumpWire.Policy{
      version: 2,
      id: Uniq.UUID.uuid4(),
      handling: :filter_request,
      organization_id: org_id,
      apply_on_match: true,
      attributes: [MapSet.new(["*"])],
      configuration: %JumpWire.Policy.FilterRequest{table: table, field: "value"},
    }
    key = {org_id, policy.id}

    on_exit fn -> JumpWire.GlobalConfig.delete(:policies, key) end
    JumpWire.GlobalConfig.put(:policies, key, policy)

    params = Keyword.update!(params, :username, fn username ->
      "#{username}##{value}"
    end)
    {:ok, pid} = Postgrex.start_link(params)
    assert {:ok, %{rows: [[^id]]}} = Postgrex.query(pid, "SELECT id FROM #{table}", [])
  end

  defp insert_fake_rows(conn, table) do
    rows = [
      [Faker.Gov.Us.ssn, Faker.Phone.EnUs.phone],
      [nil, Faker.Phone.EnUs.phone],
      [Faker.Gov.Us.ssn, nil],
      [nil, nil]
    ]
    |> Enum.shuffle()

    Enum.map(rows, fn r ->
      %{rows: [[id]]} = Postgrex.query!(conn, "insert into #{table} (value, phone) values ($1, $2) returning id;", r)
      [id | r]
    end)
  end

  defp insert_fake_rows(conn, table, table2) do
    rows = [
      {[Faker.Gov.Us.ssn, Faker.Phone.EnUs.phone], [Faker.Address.street_address]},
      {[nil, Faker.Phone.EnUs.phone], [Faker.Address.street_address]},
      {[Faker.Gov.Us.ssn, nil], [Faker.Address.street_address]},
      {[nil, nil], [nil]}
    ]
    |> Enum.shuffle()

    rows
    |> Enum.each(fn {r1, r2} ->
      {:ok, res} = Postgrex.query(conn, "insert into #{table} (value, phone) values ($1, $2) returning id;", r1)
      [fk_id] = Enum.at(res.rows, 0)
      {:ok, _} = Postgrex.query(conn, "insert into #{table2} (#{table}_id, value) values ($1, $2) returning id, value, #{table}_id", [fk_id | r2])
    end)

    rows
  end
end
