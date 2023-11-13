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
