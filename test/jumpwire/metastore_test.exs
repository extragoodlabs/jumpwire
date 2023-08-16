defmodule JumpWire.MetastoreTest do
  use ExUnit.Case, async: true
  use JumpWire.Metastore.PostgresqlKVCase
  alias JumpWire.Metastore

  test "load a metastore struct from attributes" do
    org_id = Faker.UUID.v4()
    attrs = %{
      name: "regional lookup",
      id: Faker.UUID.v4(),
      configuration: %{
        type: "postgresql_kv",
        table: "pii",
        key_field: "key",
        value_field: "value",
        connection: %{
          "hostname" => "localhost",
          "database" => "postgres",
          "ssl" => false,
        },
      },
      credentials: %{
        "username" => "postgres",
        "password" => "postgres",
      },
    }

    assert {:ok, store = %Metastore{}} = Metastore.from_json(attrs, org_id)
    assert %Metastore.PostgresqlKV{} = store.configuration
    assert org_id == store.organization_id
    assert is_nil(store.vault_role)
    assert is_nil(store.vault_database)
    assert %{"username" => "postgres", "password" => "postgres"} == store.credentials
  end

  test "fetch from postgres kv store", %{metastore: metastore, kv_data: data} do
    {key, value} = Enum.random(data)

    assert {:ok, conn} = Metastore.connect(metastore)
    assert {:ok, value} == Metastore.fetch(conn, key, metastore)
    assert :error == Metastore.fetch(conn, Uniq.UUID.uuid4(), metastore)
  end

  test "fetch many values from postgres kv store", %{metastore: metastore, kv_data: data} do
    {key, value} = Enum.random(data)

    assert {:ok, conn} = Metastore.connect(metastore)
    expected_key = Ecto.UUID.dump!(key)
    assert {:ok, %{expected_key => value}} == Metastore.fetch_all(conn, [key], metastore)
    assert {:ok, %{}} == Metastore.fetch_all(conn, [Uniq.UUID.uuid4()], metastore)

    expected = 1..4
    |> Stream.map(fn _ -> Enum.random(data) end)
    |> Stream.map(fn {k, v} -> {Ecto.UUID.dump!(k), v} end)
    |> Map.new()
    keys = Map.keys(expected)

    assert {:ok, expected} == Metastore.fetch_all(conn, keys, metastore)
  end
end
