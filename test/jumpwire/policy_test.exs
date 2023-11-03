defmodule JumpWire.PolicyTest do
  use JumpWire.Metastore.PostgresqlKVCase
  use PropCheck
  import ExUnit.CaptureLog
  alias JumpWire.Policy
  alias JumpWire.Record

  @org_id Application.compile_env(:jumpwire, JumpWire.Cloak.KeyRing)[:default_org]

  @policy %Policy{
    handling: :block,
    id: Uniq.UUID.uuid4(),
    label: "pii",
    name: "canopy ssn",
    attributes: [MapSet.new(["classification:Confidential"])],
    organization_id: @org_id,
  }

  setup_all do
    record = %Record{
      data: %{"ssn" => "123-45-6789"},
      labels: %{"$.ssn" => ["pii"]},
      source: "PolicyTest",
    }

    %{
      metadata: %{
        classification: "Internal",
        type: :db_proxy,
        client_id: Uniq.UUID.uuid4(),
        manifest_id: Uniq.UUID.uuid4(),
        module: JumpWire.Proxy.Postgres,
        attributes: MapSet.new(["*", "classification:Internal", "label:pii"]),
      },
      record: record,
      org_id: @org_id,
    }
  end

  test "decode policy from json" do
    policy_blob = %{
      "handling" => "block",
      "id" => Uniq.UUID.uuid4(),
      "label" => "pii",
      "name" => "canopy ssn",
      "allowed_classification" => "Confidential",
      "attributes" => [["classification:Confidential"]],
    }
    attributes = [MapSet.new(["classification:Confidential"])]
    assert (
      {:ok, %Policy{
          handling: :block,
          allowed_classification: "Confidential",
          label: "pii",
          organization_id: @org_id,
          attributes: ^attributes,
       }} = Policy.from_json(policy_blob, @org_id)
    )
  end

  test "decode resolve_fields policy from json", %{org_id: org_id} do
    policy_blob = %{
      "handling" => "resolve_fields",
      "id" => Uniq.UUID.uuid4(),
      "label" => "pii",
      "name" => "resolve eu pii",
      "configuration" => %{
        "type" => "resolve_fields",
        "metastore_id" => Uniq.UUID.uuid4(),
        "route_key" => "country_code",
        "route_values" => ["de", "se", "it"],
      },
    }
    assert (
      {:ok, %Policy{
          handling: :resolve_fields,
          label: "pii",
          organization_id: org_id,
          configuration: %Policy.ResolveFields{
            route_key: "country_code",
            route_values: ["de", "se", "it"],
          },
       }} = Policy.from_json(policy_blob, org_id)
    )

    assert {:error, _} = Policy.from_json(put_in(policy_blob, ["configuration", "route_key"], nil), org_id)
    assert {:error, _} = Policy.from_json(put_in(policy_blob, ["configuration", "type"], "blah"), org_id)
  end

  test "block records based on field key", %{metadata: metadata, record: record} do
    assert {:halt, :blocked} == Policy.apply_policy(@policy, record, metadata)

    record = %{record | data: %{"not_ssn" => "123-45-6789"}}
    assert {:cont, record} == Policy.apply_policy(@policy, record, metadata)
  end

  test "drop a matching field", %{metadata: metadata, record: record} do
    policy = %{@policy | handling: :drop_field}
    expected = %{}
    assert {:cont, %Record{data: ^expected}} = Policy.apply_policy(policy, record, metadata)
  end

  test "match by plain keys", %{metadata: metadata} do
    record = %Record{
      data: %{"ssn" => "123-45-6789"},
      labels: %{"ssn" => ["pii"]},
      source: "PolicyTest",
      label_format: :key,
    }
    policy = %{@policy | handling: :drop_field}
    expected = %{}
    assert {:cont, %Record{data: ^expected}} = Policy.apply_policy(policy, record, metadata)
  end

  test "exclude from policy by classification", %{metadata: metadata, record: record} do
    attributes = MapSet.new(["*", "classification:Confidential"])
    metadata = %{metadata | attributes: attributes}
    assert {:cont, record} == Policy.apply_policy(@policy, record, metadata)

    attributes = MapSet.new(["*", "classification:Public"])
    metadata = %{metadata | attributes: attributes}
    assert {:halt, :blocked} == Policy.apply_policy(@policy, record, metadata)
  end

  test "encrypt labeled fields", %{metadata: metadata} do
    policy = %{@policy | handling: :encrypt}
    ssn = "123-45-6789"
    {:ok, name} = JumpWire.Vault.encode_and_encrypt("encrypt me", %{labels: ["pii"]}, @org_id)
    record = %Record{
      data: %{"ssn" => ssn, "name" => name},
      labels: %{"$.ssn" => ["pii"], "$.name" => ["pii"]},
      source: "PolicyTest",
    }

    assert {:cont, %Record{data: data, policies: policies}} = Policy.apply_policy(policy, record, metadata)
    refute data["ssn"] == ssn
    assert data["name"] == record.data["name"]
    assert %{encrypted: ["$.ssn"]} == policies
    assert {:ok, ssn, ["pii"]} == JumpWire.Vault.decrypt_and_decode(data["ssn"], @org_id)
  end

  test "decrypt labeled fields", %{metadata: metadata} do
    policy = %{@policy | handling: :decrypt}
    metadata = %{metadata | classification: "Confidential"}
    ssn = "123-45-6789"
    {:ok, encrypted} = JumpWire.Vault.encode_and_encrypt(ssn, %{labels: ["pii"]}, @org_id)
    record = %Record{
      data: %{"ssn" => encrypted, "name" => "real human name"},
      labels: %{"$.ssn" => ["pii"], "$.name" => ["pii"]},
      source: "PolicyTest",
    }

    assert {:cont, %Record{data: data, labels: labels, policies: policies}} =
      Policy.apply_policy(policy, record, metadata)
    assert data["ssn"] == ssn
    assert data["name"] == record.data["name"]
    assert %{decrypted: ["$.ssn", "$.name"]} == policies
    assert labels["$.ssn"] == ["pii"]
  end

  test "apply policy without matching attributes", %{metadata: metadata} do
    policy = %Policy{
      version: 2,
      handling: :encrypt,
      id: Uniq.UUID.uuid4(),
      label: "pii",
      name: "encrypt pii",
      attributes: [MapSet.new(["classification:Confidential", "is:admin"])],
      organization_id: @org_id,
    }

    metadata = %{metadata | attributes: MapSet.new(["classification:Confidential"])}
    ssn = "123-45-6789"
    {:ok, encrypted} = JumpWire.Vault.encode_and_encrypt(ssn, %{labels: ["pii"]}, @org_id)
    record = %Record{
      data: %{"ssn" => encrypted, "name" => "real human name"},
      labels: %{"$.ssn" => ["pii"], "$.name" => ["pii"]},
      source: "PolicyTest",
    }

    assert {:cont, %Record{data: data, labels: labels, policies: policies}} =
      Policy.apply_policy(policy, record, metadata)
    assert data["ssn"] == encrypted
    refute data["name"] == record.data["name"]
    assert %{encrypted: ["$.name"]} == policies
    assert labels["$.ssn"] == ["pii"]
  end

  test "invert attributes starting with `not` prefix", %{metadata: metadata} do
    policy = %Policy{
      version: 2,
      handling: :block,
      id: Uniq.UUID.uuid4(),
      label: "pii",
      name: "drop pii",
      attributes: [MapSet.new(["not:group:support", "select:pii"])],
      organization_id: @org_id,
    }

    record = %Record{
      data: %{"name" => "real human name"},
      labels: %{"$.name" => ["pii"]},
      source: "PolicyTest",
    }

    metadata = %{metadata | attributes: MapSet.new(["select:pii", "group:support"])}
    assert {:halt, :blocked} == Policy.apply_policy(policy, record, metadata)

    metadata = %{metadata | attributes: MapSet.new(["select:pii", "group:admins"])}
    assert {:cont, record} == Policy.apply_policy(policy, record, metadata)
  end

  test "invert attributes for apply_on_match", %{metadata: metadata} do
    policy = %Policy{
      version: 2,
      handling: :block,
      id: Uniq.UUID.uuid4(),
      label: "pii",
      name: "drop pii",
      attributes: [MapSet.new(["not:group:admins", "select:pii"])],
      apply_on_match: true,
      organization_id: @org_id,
    }

    record = %Record{
      data: %{"name" => "real human name"},
      labels: %{"$.name" => ["pii"]},
      source: "PolicyTest",
    }

    metadata = %{metadata | attributes: MapSet.new(["select:pii", "group:support"])}
    assert {:halt, :blocked} == Policy.apply_policy(policy, record, metadata)

    metadata = %{metadata | attributes: MapSet.new(["select:pii", "group:admins"])}
    assert {:cont, record} == Policy.apply_policy(policy, record, metadata)
  end

  test "decrypt labeled fields based on attributes", %{metadata: metadata} do
    policy = %Policy{
      version: 2,
      handling: :encrypt,
      id: Uniq.UUID.uuid4(),
      label: "pii",
      name: "encrypt pii",
      attributes: [MapSet.new(["classification:Confidential"])],
      organization_id: @org_id,
    }

    metadata = %{metadata | attributes: MapSet.new(["*", "classification:Confidential"])}
    ssn = "123-45-6789"
    {:ok, encrypted} = JumpWire.Vault.encode_and_encrypt(ssn, %{labels: ["pii"]}, @org_id)
    record = %Record{
      data: %{"ssn" => encrypted, "name" => "real human name"},
      labels: %{"$.ssn" => ["pii"], "$.name" => ["pii"]},
      source: "PolicyTest",
    }

    assert {:cont, %Record{data: data, labels: labels, policies: policies}} =
      Policy.apply_policy(policy, record, metadata)
    assert data["ssn"] == ssn
    assert data["name"] == record.data["name"]
    assert %{decrypted: ["$.ssn", "$.name"]} == policies
    assert labels["$.ssn"] == ["pii"]
  end

  test "tokenize labeled fields", %{metadata: metadata} do
    policy = %{@policy | handling: :tokenize}
    ssn = "123-45-6789"
    record = %Record{
      data: %{"ssn" => ssn},
      labels: %{"$.ssn" => ["pii"]},
      source: "PolicyTest",
      extra_field_info: %{tables: %{"$.ssn" => 7}},
    }

    assert {:cont, record} = Policy.apply_policy(policy, record, metadata)
    assert %{"ssn" => "SldUT0tO" <> _} = record.data
    assert %{tokenized: ["$.ssn"]} == record.policies

    # reverse the token
    attributes = MapSet.new(["classification:Internal"])
    policy = %{policy | attributes: [attributes]}
    assert {:cont, %Record{data: data}} = Policy.apply_policy(policy, record, metadata)
    assert %{"ssn" => ssn} == data
  end

  test "policies with no label defined", %{metadata: metadata, record: record} do
    # create a policy without apply_on_match
    policy = %Policy{
      handling: :block,
      id: Uniq.UUID.uuid4(),
      name: "block ssn",
      apply_on_match: false,
      attributes: [
        MapSet.new(["classification:Confidential"]),
        MapSet.new(["not:label:pii"]),
      ],
      organization_id: @org_id,
    }
    # continue if not pii
    meta = Map.update!(metadata, :attributes, fn attr ->
      MapSet.delete(attr, "label:pii")
    end)
    assert {:cont, ^record} = Policy.apply_policy(policy, record, meta)

    # continue if confidential and pii
    meta = Map.update!(metadata, :attributes, fn attr ->
      MapSet.put(attr, "classification:Confidential")
    end)
    assert {:cont, ^record} = Policy.apply_policy(policy, record, meta)

    # block otherwise
    assert {:halt, :blocked} = Policy.apply_policy(policy, record, metadata)

    # create a policy with apply_on_match
    policy = %Policy{
      handling: :block,
      id: Uniq.UUID.uuid4(),
      name: "block ssn",
      apply_on_match: true,
      attributes: [
        MapSet.new(["classification:Confidential", "label:pii"]),
      ],
      organization_id: @org_id,
    }

    # block if confidential and pii
    meta = Map.update!(metadata, :attributes, fn attr ->
      MapSet.put(attr, "classification:Confidential")
    end)
    assert {:halt, :blocked} = Policy.apply_policy(policy, record, meta)

    # continue otherwise
    assert {:cont, ^record} = Policy.apply_policy(policy, record, metadata)
  end

  property "policies are returned in a defined order", [:verbose], %{metadata: metadata} do
    # generate all combinations of policy types, including duplicates
    actions = [:block, :drop_field, :resolve_fields, :encrypt]

    policy = let action <- oneof(actions) do
      JumpWire.Phony.generate_policy(metadata.manifest_id, metadata.classification, action, "pii")
    end

    forall {org_id, policies} <- {JumpWire.TestUtils.Prop.uuid4(), resize(10, list(policy))} do
      policies = Enum.map(policies, fn policy ->
        {{org_id, policy.id}, %{policy | organization_id: org_id}}
      end)
      JumpWire.GlobalConfig.set(:policies, org_id, policies)
      actions = Enum.with_index(actions)
      JumpWire.Policy.list_all(org_id)
      |> Enum.reduce(0, fn %{handling: handling}, last ->
        pos = Keyword.fetch!(actions, handling)
        assert pos >= last
        last
      end)

      true
    end
  end

  describe "policy to resolve fields" do
    setup %{org_id: org_id, metastore: metastore, kv_data: kv_data} do
      policy = %Policy{
        handling: :resolve_fields,
        id: Uniq.UUID.uuid4(),
        label: "pii",
        name: "resolve pii",
        organization_id: org_id,
        attributes: [MapSet.new(["classification:Internal"])],
        apply_on_match: true,
        configuration: %Policy.ResolveFields{
          metastore_id: metastore.id,
          route_key: "country_code",
          route_values: ["de", "se", "it"],
        }
      }

      {key, value} = Enum.random(kv_data)

      data = %{
        "user_email" => key,
        "user_name" => "real human name",
        "country_isoCode" => "it",
        "country_name" => "Italy",
      }
      record = %Record{
        data: data,
        labels: %{"$.user_email" => ["pii"], "$.country_isoCode" => ["country_code"]},
        source: "PolicyTest",
      }

      %{policy: policy, record: record, value: value}
    end

    test "replaces matching fields", %{policy: policy, metadata: metadata, record: record, value: email} do
      assert {:cont, result} = Policy.apply_policy(policy, record, metadata)
      assert Map.put(record.data, "user_email", email) == result.data
      assert %{resolved_fields: ["$.user_email"]} == result.policies
    end

    test "does nothing on wrong classification", %{policy: policy, metadata: metadata, record: record} do
      # Test that the data is not resolved when the classification doesn't match
      attributes = MapSet.new(["classification:DoubleSecret"])
      policy = %{policy | attributes: [attributes]}
      assert {:cont, result} = Policy.apply_policy(policy, record, metadata)
      assert record.data == result.data
      assert %{} == result.policies
    end

    test "halts when resolving fails", %{policy: policy, metadata: metadata, record: record} do
      metastore = JumpWire.Phony.generate_pg_metastore(@org_id, table: "bad_table")
      policy = Map.update!(policy, :configuration, fn config ->
        Map.put(config, :metastore_id, metastore.id)
      end)

      on_exit fn ->
        JumpWire.GlobalConfig.delete(:metastores, {metastore.organization_id, metastore.id})
      end

      capture_log fn ->
        assert {:halt, {:error, :metastore_failure}} = Policy.apply_policy(policy, record, metadata)
      end
    end
  end

  describe "accept policy can skip block policies" do
    setup %{org_id: org_id} do
      # note that order matters here, as the function under test doesn't sort policies
      # access policy must come first
      policies = [
        %Policy{
          id: Uniq.UUID.uuid4(),
          version: 2,
          name: "Engineers pii access",
          attributes: [
            MapSet.new(["group:Engineers", "not:delete:pii", "not:update:pii"])
          ],
          apply_on_match: true,
          handling: :access,
          label: "pii",
          allowed_classification: nil,
          encryption_key: :aes,
          organization_id: "org_bXmvSisixfCwO1oa",
          client_id: nil,
          configuration: nil
        },
        %Policy{
          id: Uniq.UUID.uuid4(),
          version: 2,
          name: "Engineers pii default deny",
          attributes: [MapSet.new(["group:Engineers"])],
          apply_on_match: true,
          handling: :block,
          label: "pii",
          allowed_classification: nil,
          encryption_key: :aes,
          organization_id: org_id,
          client_id: nil,
          configuration: nil
        },
      ]

      record = %Record{
        data: %{"name" => "real human name"},
        labels: %{"$.name" => ["pii"]},
        source: "PolicyTest",
      }

      %{policies: policies, record: record}
    end

    test "when matched accept policy", %{policies: policies, metadata: metadata, record: record} do
      metadata = %{metadata | attributes: MapSet.new(["select:pii", "group:Engineers"])}
      assert record == Policy.apply_policies(policies, record, metadata)
    end

    test "except when no accept policies match", %{policies: policies, metadata: metadata, record: record} do
      metadata = %{metadata | attributes: MapSet.new(["delete:pii", "group:Engineers"])}
      assert :blocked == Policy.apply_policies(policies, record, metadata)
    end
  end
end
