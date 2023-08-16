defmodule JumpWire.Phony do
  @moduledoc """
  Common test utilities for the main JumpWire datatypes.
  """

  alias JumpWire.{ClientAuth, GlobalConfig, Manifest, Metastore, Policy, Proxy}

  @opaque db_type() :: :postgresql | :mysql
  @typep proxy() :: map()

  @doc """
  Generates a Postgres manifest and registers it in the `:manifests` table.

  Opts:
  - name: Manifest name.
  - username: Defaults to `postgres`.
  - password: Defaults to `postgres`.
  - database: Defaults to `postgres`.
  - hostname: Defaults to `localhost`
  - ssl: Boolean, defaults to `false`
  - skip_setup: Whether to skip manifest register/hook call.
  """
  def generate_pg_manifest(org_id, opts \\ []) do
    manifest =
      %Manifest{
        root_type: :postgresql,
        id: Uniq.UUID.uuid4(),
        name: opts[:name] || Uniq.UUID.uuid4(),
        configuration: db_config(opts),
        credentials: %{
          "username" => opts[:username] || "postgres",
          "password" => opts[:password] || "postgres",
        },
        organization_id: org_id,
      }

    setup_manifest(manifest, opts)
    manifest
  end

  @doc """
  Generates a MySQL manifest and registers it in the `:manifests` table.

  Opts:
  - name: Manifest name.
  - username: Defaults to `postgres`.
  - password: Defaults to `postgres`.
  - database: Defaults to `postgres`.
  - hostname: Defaults to `localhost`.
  - ssl: Boolean, defaults to `false`.
  - skip_setup: Whether to skip manifest register/hook call.
  """
  def generate_mysql_manifest(org_id, opts \\ []) do
    manifest =
      %Manifest{
        root_type: :mysql,
        id: Uniq.UUID.uuid4(),
        name: opts[:name] || Uniq.UUID.uuid4(),
        configuration: db_config(opts),
        credentials: %{
          "username" => opts[:username] || "root",
          "password" => opts[:password] || "root",
        },
        organization_id: org_id,
      }

    setup_manifest(manifest, opts)
    manifest
  end

  @doc """
  Generates a Jumpwire manifest and registers it in the `:manifests` table.

  Opts:
  - name: Manifest name.
  - skip_setup: Whether to skip manifest register/hook call.
  """
  def generate_jumpwire_manifest(org_id, classification, opts \\ []) do
    manifest =
      %Manifest{
        root_type: :jumpwire,
        id: Uniq.UUID.uuid4(),
        name: opts[:name] || Uniq.UUID.uuid4(),
        classification: classification,
        organization_id: org_id,
      }

    setup_manifest(manifest, opts)
    manifest
  end

  defp setup_manifest(manifest, opts) do
    unless opts[:skip_setup] do
      JumpWire.Manifest.hook(manifest, :insert) |> Task.await()
      GlobalConfig.put(:manifests, {manifest.organization_id, manifest.id}, manifest)
    end
  end

  @doc """
  Generates a Policy and registers it in the `:policies` table.

  Opts:
  - name: Policy name.
  - encryption_key: Underlying encryption key. Defaults to `aes`.
  """
  def generate_policy(manifest_id, classification, handling, label, opts \\ []) do
    org_id =
      case GlobalConfig.all(:manifests, {:_, manifest_id}) do
        [%{organization_id: org_id}] -> org_id
        _ -> opts[:org_id]
      end

    policy =
      %Policy{
        version: 2,
        attributes: [MapSet.new(["classification:#{classification}"])],
        allowed_classification: classification,
        encryption_key: opts[:encryption_key] || :aes,
        handling: handling,
        id: Uniq.UUID.uuid4(),
        label: label,
        name: opts[:name] || Uniq.UUID.uuid4(),
        organization_id: org_id
      }

    GlobalConfig.put(:policies, {org_id, policy.id}, policy)
    JumpWire.Policy.hook(policy, :insert)

    policy
  end

  @doc """
  Generates a Schema and registers it in the `:schemas` table.

  Opts:
  - name: Schema name.
  - skip_setup: Whether to skip schema register/hook call.
  """
  def generate_schema(manifest_id, fields, opts \\ []) do
    [%{organization_id: org_id}] = GlobalConfig.all(:manifests, {:_, manifest_id})

    schema =
      %Proxy.Schema{
        fields: fields,
        id: Uniq.UUID.uuid4(),
        manifest_id: manifest_id,
        name: opts[:name] || Uniq.UUID.uuid4(),
        organization_id: org_id
      }

    unless opts[:skip_setup] do
      JumpWire.Proxy.Schema.hook(schema, :insert) |> Task.await()
      GlobalConfig.put(:proxy_schemas, {org_id, manifest_id, schema.name}, schema)
    end

    schema
  end

  @doc """
  Generates a ClientAuth and registers it in the `:client_auth` table. It also returns
  the corresponding token for the client.

  Opts:
  - name: ClientAuth name
  """
  def generate_client_auth({org_id, manifest_id}, classification, opts \\ []) do
    attributes =
      case classification do
        nil -> MapSet.new()
        _ -> MapSet.new(["classification:#{classification}"])
      end

    client_auth =
      %ClientAuth{
        id: Uniq.UUID.uuid4(),
        name: opts[:name] || Uniq.UUID.uuid4(),
        classification: classification,
        organization_id: org_id,
        manifest_id: manifest_id,
        attributes: attributes,
      }

    GlobalConfig.put(:client_auth, {org_id, client_auth.id}, client_auth)
    JumpWire.ClientAuth.hook(client_auth, :insert)

    {client_auth, generate_client_token(client_auth)}
  end

  @doc """
  Generates a token for the given ClientAuth/Manifest.
  """
  def generate_client_token(%ClientAuth{id: id, organization_id: org_id}),
    do: generate_client_token({org_id, id})
  def generate_client_token(%Manifest{id: id, organization_id: org_id, root_type: :jumpwire}),
    do: generate_client_token({org_id, id})
  def generate_client_token({org_id, manifest_id}) do
    secret = Application.fetch_env!(:jumpwire, :proxy)
    |> Keyword.get(:secret_key)
    Plug.Crypto.sign(secret, "manifest", {org_id, manifest_id})
  end

  @doc """
  Generates a Postgres Metastore.

  Opts:
  - name
  - key_field: Defaults to `key`.
  - value_field: Defaults to `value`.
  - hostname: Defaults to `localhost`.
  - database: Defaults to `postgres`.
  - ssl: Boolean, defaults to `false`.
  - username: Defaults to `postgres`.
  - password: Defaults to `postgres`.
  """
  def generate_pg_metastore(org_id, opts \\ []) do
    metastore =
      %Metastore{
        id: Uniq.UUID.uuid4(),
        name: opts[:name] || "test pg metastore",
        configuration: %Metastore.PostgresqlKV{
          connection: db_config(opts),
          table: opts[:table] || "pii",
          key_field: opts[:key_field] || "key",
          value_field: opts[:value_field] || "value",
        },
        credentials: %{
          "username" => opts[:username] || "postgres",
          "password" => opts[:password] || "postgres",
        },
        organization_id: org_id,
      }

    JumpWire.Metastore.hook(metastore, :insert)
    JumpWire.GlobalConfig.put(:metastores, metastore)

    metastore
  end

  @doc """
  Attempts to start from a fresh state by deleting any and all existing data.
  """
  def cleanup_jumpwire_data() do
    # NOTE: Not running delete hooks here
    [
      :policies,
      :client_auth,
      :manifests,
      :proxy_schemas,
      :tokens,
      :reverse_schemas,
      :manifest_metadata,
      :manifest_table_metadata,
    ]
    |> Enum.each(&:ets.delete_all_objects/1)
  end

  @doc """
  Generate enough fake data to test the database proxy.
  Any existing policies/manifest/etc will be lost.
  """
  @spec generate_db_proxy(db_type, String.t, String.t) :: proxy()
  def generate_db_proxy(:postgresql, org_id, database, table) do
    manifest = generate_pg_manifest(org_id, database: database)
    port = Application.get_env(:jumpwire, JumpWire.Proxy.Postgres)[:port]
    generate_db_proxy(manifest, port, table)
  end
  def generate_db_proxy(:mysql, org_id, database, table) do
    manifest = generate_mysql_manifest(org_id, database: database)
    port = Application.get_env(:jumpwire, JumpWire.Proxy.MySQL)[:port]
    generate_db_proxy(manifest, port, table)
  end

  @spec generate_db_proxy(Manifest.t, port, String.t) :: proxy()
  def generate_db_proxy(db_manifest = %Manifest{}, port, table) do
    org_id = db_manifest.organization_id
    {_client, token} = generate_client_auth({org_id, db_manifest.id}, "Internal", name: "db auth internal")
    generate_schema(db_manifest.id, %{"$.ssn" => ["secret"]}, name: table)

    db_params = [
      hostname: db_manifest.configuration["hostname"],
      username: db_manifest.credentials["username"],
      password: db_manifest.credentials["password"],
      database: db_manifest.configuration["database"],
    ]
    proxy_params = [
      hostname: "localhost",
      port: port,
      username: db_manifest.id,
      password: token,
      database: db_params[:database],
    ]

    %{direct: db_params, proxy: proxy_params}
  end

  @doc """
  Insert test data into the database, truncating the existing table
  """
  def generate_records(conn, table, opts \\ []) do
    num_records = Keyword.get(opts, :num_records, 500)

    Postgrex.query!(conn, "truncate #{table}", [])
    1..num_records
    |> Stream.map(fn _ -> generate_user() end)
    |> Enum.each(fn user ->
      Postgrex.query!(
        conn,
        "INSERT INTO #{table} (first_name, last_name, account_id, ssn, username, source) VALUES ($1, $2, $3, $4, $5, $6);",
        [user[:first_name], user[:last_name], user[:account_id], user[:ssn], user[:username], user[:source]]
      )
    end)
  end

  defp generate_user() do
    %{
      first_name: Faker.Person.first_name(),
      last_name: Faker.Person.last_name(),
      account_id: Faker.UUID.v4(),
      ssn: Faker.Gov.Us.ssn(),
      username: Faker.Internet.user_name() <> "_" <> Faker.Internet.user_name(),
      source: Faker.Util.pick(~w|Google Direct Twitter LinkedIn|),
    }
  end

  defp db_config(opts) do
    %{
      "hostname" => opts[:hostname] || "localhost",
      "database" => opts[:database] || "postgres",
      "ssl" => opts[:ssl] || false,
    }
  end
end
