defmodule JumpWire.API.RouterMocks do
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
        "favorite_cheese" => "secret",
      }
    }
  end
end
