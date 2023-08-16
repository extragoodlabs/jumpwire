defmodule JumpWire.ConfigLoaderTest do
  use ExUnit.Case, async: false
  alias JumpWire.ConfigLoader

  @fixture_dir "priv/fixtures/test-config"

  test "loading manifests from a yaml file" do
    org_id = Faker.UUID.v4()
    data = ConfigLoader.from_disk(@fixture_dir, org_id)

    expected = [
      %JumpWire.Manifest{
        id: "0779b97a-c04a-48f9-9483-22e8b0487de4",
        name: "api db",
        root_type: :postgresql,
        configuration: %{
          "type" => "postgresql",
          "database" => "db",
          "hostname" => "api_db",
          "port" => 5432,
          "ssl" => false,
        },
        credentials: %{"password" => "apipassword", "username" => "apiuser"},
        classification: nil,
        organization_id: org_id,
      }
    ]
    assert expected == Map.get(data, :manifests)
    assert expected == JumpWire.GlobalConfig.all(:manifests, {org_id, :_})
  end

  test "loading policies from a yaml file" do
    org_id = Faker.UUID.v4()
    data = ConfigLoader.from_disk(@fixture_dir, org_id)

    expected = [
      %JumpWire.Policy{
        id: "d86448be-db98-4ec5-a635-576829e05ec7",
        version: 2,
        name: "resolve eu pii",
        organization_id: org_id,
        handling: :resolve_fields,
        label: "pii",
        configuration: %JumpWire.Policy.ResolveFields{
          metastore_id: "cb48a801-389b-4844-89e7-2b41e88317af",
          route_key: "country_code",
          route_values: ["DE", "FR", "GE"],
        },
      },
      %JumpWire.Policy{
        id: "69165a17-8560-47f4-82b2-43c7346d23f6",
        version: 2,
        name: "resolve uk pii",
        organization_id: org_id,
        handling: :resolve_fields,
        label: "pii",
        configuration: %JumpWire.Policy.ResolveFields{
          metastore_id: "559c0fd7-dd28-456e-9e02-890fcc912977",
          route_key: "country_code",
          route_values: ["GB"],
        },
      },
      %JumpWire.Policy{
        id: "6c33d804-5276-44d0-b63f-14aa82a415a4",
        version: 2,
        name: "resolve us pii",
        organization_id: org_id,
        handling: :resolve_fields,
        label: "pii",
        configuration: %JumpWire.Policy.ResolveFields{
          metastore_id: "6db2d212-216b-4710-bc99-00ec63601840",
          route_key: "country_code",
          route_values: ["US"],
        },
      },
    ]
    assert expected == Map.get(data, :policies) |> Enum.sort_by(fn x -> x.name end)
    all_policies = JumpWire.Policy.list_all(org_id)
    Enum.each(expected, fn p -> assert Enum.member?(all_policies, p) end)
  end

  test "loading metastores from a yaml file" do
    org_id = Faker.UUID.v4()
    data = ConfigLoader.from_disk(@fixture_dir, org_id)

    expected = [
      %JumpWire.Metastore{
        id: "cb48a801-389b-4844-89e7-2b41e88317af",
        name: "eu pii db",
        configuration: %JumpWire.Metastore.PostgresqlKV{
          connection: %{"hostname" => "pii_eu_db", "database" => "db", "port" => 5432, "ssl" => false},
          table: "pii",
          key_field: "key",
          value_field: "value",
        },
        credentials: %{"password" => "piipassword", "username" => "piiuser"},
        organization_id: org_id,
      },
      %JumpWire.Metastore{
        id: "559c0fd7-dd28-456e-9e02-890fcc912977",
        name: "uk pii db",
        configuration: %JumpWire.Metastore.PostgresqlKV{
          connection: %{"hostname" => "pii_uk_db", "database" => "db", "port" => 5432, "ssl" => false},
          table: "pii",
          key_field: "key",
          value_field: "value",
        },
        credentials: %{"password" => "piipassword", "username" => "piiuser"},
        organization_id: org_id,
      },
      %JumpWire.Metastore{
        id: "6db2d212-216b-4710-bc99-00ec63601840",
        name: "us pii db",
        configuration: %JumpWire.Metastore.PostgresqlKV{
          connection: %{"hostname" => "pii_us_db", "database" => "db", "port" => 5432, "ssl" => false},
          table: "pii",
          key_field: "key",
          value_field: "value",
        },
        credentials: %{"password" => "piipassword", "username" => "piiuser"},
        organization_id: org_id,
      },
    ]
    assert expected == Map.get(data, :metastores) |> Enum.sort_by(fn x -> x.name end)
    assert expected == JumpWire.GlobalConfig.all(:metastores, {org_id, :_}) |> Enum.sort_by(fn x -> x.name end)
  end

  test "loading client_auth from a yaml file" do
    org_id = Faker.UUID.v4()
    data = ConfigLoader.from_disk(@fixture_dir, org_id)

    expected = [%JumpWire.ClientAuth{
      id: "20fe7ce9-e304-444a-94a4-3ab7045b6d78",
      name: "client",
      organization_id: org_id,
      manifest_id: "0779b97a-c04a-48f9-9483-22e8b0487de4",
      attributes: MapSet.new(["classification:Internal"])
    }]
    assert expected == Map.get(data, :client_auth) |> Enum.sort_by(fn x -> x.name end)
    assert expected == JumpWire.GlobalConfig.all(:client_auth, {org_id, :_}) |> Enum.sort_by(fn x -> x.name end)
  end

  test "loading proxy_schemas from a yaml file" do
    org_id = Faker.UUID.v4()
    data = ConfigLoader.from_disk(@fixture_dir, org_id)

    session_schema = %JumpWire.Proxy.Schema{
      id: "f764dd5b-fb38-401a-b414-edfa8230fd11",
      name: "sessions",
      organization_id: org_id,
      manifest_id: "0779b97a-c04a-48f9-9483-22e8b0487de4",
      fields: %{
        "$.schedule_date_and_time" => ["pii"],
        "$.name" => ["pii"],
      },
    }
    country_schema = %JumpWire.Proxy.Schema{
      id: "618740c0-bd81-42c9-99c9-a9fe21e8c13c",
      name: "countries",
      organization_id: org_id,
      manifest_id: "0779b97a-c04a-48f9-9483-22e8b0487de4",
      fields: %{
        "$.iso_code" => ["country_code"],
      },
    }
    expected = [country_schema, session_schema]


    assert expected == Map.get(data, :proxy_schemas) |> Enum.sort_by(fn s -> s.name end)
    assert expected == (
      JumpWire.Proxy.Schema.list_all(org_id)
      |> Enum.sort_by(fn s -> s.name end)
    )
  end

  test "parse group permissions" do
    org_id = Faker.UUID.v4()
    contents = %{
      "groups" => %{
        "engineers" => %{
          "source" => "jumpwire",
          "members" => ["foo@example.com"],
          "permissions" => [
            "select:pii",
            "update:pii",
            "insert:pii",
            "select:sensitive",
          ]
        }
      }
    }
    data = ConfigLoader.from_map(contents, org_id)
    policies = [
      %JumpWire.Policy{
        version: 2,
        handling: :access,
        apply_on_match: true,
        attributes: [MapSet.new(["group:engineers", "not:delete:pii"])],
        label: "pii",
        organization_id: org_id,
      },
      %JumpWire.Policy{
        version: 2,
        handling: :block,
        apply_on_match: true,
        label: "pii",
        attributes: [MapSet.new(["group:engineers"])],
        organization_id: org_id,
      },
      %JumpWire.Policy{
        version: 2,
        handling: :access,
        apply_on_match: true,
        attributes: [
          MapSet.new([
            "group:engineers",
            "not:delete:sensitive",
            "not:insert:sensitive",
            "not:update:sensitive",
          ])
        ],
        label: "sensitive",
        organization_id: org_id,
      },
      %JumpWire.Policy{
        version: 2,
        handling: :block,
        apply_on_match: true,
        label: "sensitive",
        attributes: [MapSet.new(["group:engineers"])],
        organization_id: org_id,
      },
    ]

    assert policies == (
      Map.get(data, :groups)
      |> Enum.flat_map(fn g -> g.policies end)
      |> Enum.map(fn p -> %{p | id: nil, name: nil} end)
    )

    all_policies = JumpWire.GlobalConfig.all(:policies, {org_id, :_})
    |> Enum.map(fn p -> %{p | id: nil, name: nil} end)

    Enum.each(policies, fn p -> assert Enum.member?(all_policies, p) end)
  end
end
