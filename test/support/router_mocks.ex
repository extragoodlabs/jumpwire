defmodule JumpWire.API.RouterMocks do
  @moduledoc """
  Mocks for the JumpWire API Router
  """
  @mock_org_id "test-org-id"

  def manifest(name) do
    %{
      "name" => name,
      "root_type" => "postgresql",
      "configuration" => %{
        "type" => "postgresql",
        "database" => "jumpwire",
        "hostname" => "localhost",
        "ssl" => false,
        "port" => 5432
      },
      "classification" => "test-classification",
      "organization_id" => @mock_org_id,
      "credentials" => %{
        "username" => "test-username",
        "password" => "test-password"
      }
    }
  end

  def proxy_schema(name, manifest_id) do
    %{
      "name" => name,
      "manifest_id" => manifest_id,
      "fields" => %{
        "name" => "pii",
        "address" => "pii",
        "favorite_cheese" => "secret"
      }
    }
  end

  def client_auth(name, manifest_id) do
    %{
      "name" => name,
      "manifest_id" => manifest_id
    }
  end

  def group(name, permissions) do
    %{
      "name" => name,
      "permissions" => permissions
    }
  end

  def policy(name, handling) do
    %{
      "name" => name,
      "handling" => handling,
      "label" => "pii",
      "configuration" => %{
        "type" => "resolve_fields",
        "metastore_id" => "cb48a801-389b-4844-89e7-2b41e88317af",
        "route_key" => "country_code",
        "route_values" => ["DE", "FR", "GE"]
      }
    }
  end

  def metastore_with_creds(name) do
    %{
      "name" => name,
      "credentials" => %{
        "username" => "test-username",
        "password" => "test-password"
      },
      "configuration" => %{
        "type" => "postgresql_kv",
        "connection" => %{
          "hostname" => "pii_edb",
          "port" => 5432,
          "database" => "db",
          "ssl" => false
        },
        "table" => "pii",
        "key_field" => "key",
        "value_field" => "value"
      }
    }
  end

  def metastore_without_creds(name) do
    %{
      "name" => name,
      "configuration" => %{
        "type" => "postgresql_kv",
        "connection" => %{
          "hostname" => "pii_edb",
          "port" => 5432,
          "database" => "db",
          "ssl" => false
        },
        "table" => "pii",
        "key_field" => "key",
        "value_field" => "value"
      }
    }
  end
end
