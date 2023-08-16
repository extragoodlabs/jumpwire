defmodule JumpWire.Metastore.PostgresqlKVCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  setup_all do
    org_id = Application.get_env(:jumpwire, JumpWire.Cloak.KeyRing)[:default_org]

    seed = ExUnit.configuration()[:seed]
    table = "pii_#{seed}_#{System.unique_integer([:positive])}"
    metastore = JumpWire.Phony.generate_pg_metastore(org_id, table: table)
    kv_opts = metastore.configuration

    # setup the table in the database
    params = [
      hostname: kv_opts.connection["hostname"],
      username: metastore.credentials["username"],
      password: metastore.credentials["password"],
      database: kv_opts.connection["database"],
    ]
    assert {:ok, conn} = Postgrex.start_link(params)
    Postgrex.query!(conn, "create table if not exists #{kv_opts.table} (#{kv_opts.key_field} uuid, #{kv_opts.value_field} text, PRIMARY KEY(#{kv_opts.key_field}));", [])

    # generate some records
    data = Enum.map(1..10, fn _ ->
      key = Uniq.UUID.uuid4()
      email = Faker.Internet.email()
      Postgrex.query!(
        conn,
        "insert into #{kv_opts.table} (#{kv_opts.key_field}, #{kv_opts.value_field}) values ($1, $2)",
        [Ecto.UUID.dump!(key), email]
      )
      {key, email}
    end)

    on_exit fn ->
      Postgrex.query(conn, "drop table #{kv_opts.table};", [])
      JumpWire.GlobalConfig.delete(:metastores, {metastore.organization_id, metastore.id})
    end

    %{kv_data: data, metastore: metastore}
  end

  using do
    quote do
      @moduletag db: "postgres"
    end
  end
end
