defmodule JumpWire.API.RouterTest do
  use ExUnit.Case, async: true
  use Plug.Test
  import Mox
  alias JumpWire.API.Router

  @opts Router.init([])

  # Ensure tests are run such that they can use the mock
  setup :verify_on_exit!

  setup do
    mock_manifest = %{
      "name" => "test-manifest-name",
      "root_type" => "postgresql",
      "configuration" => %{
        "type" => "postgresql",
        "database" => "jumpwire",
        "hostname" => "localhost",
        "ssl" => false,
        "port" => 5432
      },
      "classification" => "test-classification",
      "organization_id" => "test-org-id",
      "credentials" => %{
        "username" => "test-username",
        "password" => "test-password"
      }
    }

    # Register cleanup callback
    on_exit(fn ->
      JumpWire.GlobalConfig.delete_all(:manifests)
    end)

    {:ok, mock_manifest: mock_manifest}
  end

  describe "/manifests" do
    test "GET returns a 200 status with valid SSO", %{mock_manifest: mock_manifest} do
      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:put, "/manifests", mock_manifest)
        |> put_auth_header(token)
        |> Router.call(@opts)

      conn =
        conn(:get, "/manifests")
        |> put_auth_header(token)
        |> Router.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          expected = [mock_manifest]

          assert length(body) == 1
          assert expected == drop_id(body)

        {:error, _} ->
          assert false
      end
    end

    test "PUT returns a 201 status with valid input", %{mock_manifest: mock_manifest} do
      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:get, "/manifests")
        |> put_auth_header(token)
        |> Router.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "[]"

      conn =
        conn(:put, "/manifests", mock_manifest)
        |> put_auth_header(token)
        |> Router.call(@opts)

      assert conn.status == 201

      conn =
        conn(:get, "/manifests")
        |> put_auth_header(token)
        |> Router.call(@opts)

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          expected = [mock_manifest]

          assert length(body) == 1
          assert expected == drop_id(body)

        {:error, _} ->
          assert false
      end
    end

    test "GET /:id returns a 200 status with valid manifest ID", %{mock_manifest: mock_manifest} do
      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:put, "/manifests", mock_manifest)
        |> put_auth_header(token)
        |> Router.call(@opts)

      assert conn.status == 201

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          manifest_id = body["id"]

          conn =
            conn(:get, "/manifests/#{manifest_id}")
            |> put_auth_header(token)
            |> Router.call(@opts)

          assert conn.status == 200

          case Jason.decode(conn.resp_body) do
            {:ok, body} ->
              assert mock_manifest == Map.delete(body, "id")

            {:error, _} ->
              assert false
          end

        {:error, _} ->
          assert false
      end
    end

    test "DELETE /:id returns a 200 status with valid manifest ID", %{mock_manifest: mock_manifest} do
      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 4, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:put, "/manifests", mock_manifest)
        |> put_auth_header(token)
        |> Router.call(@opts)

      assert conn.status == 201

      {:ok, manifest} = Jason.decode(conn.resp_body)

      manifest_id = manifest["id"]

      conn =
        conn(:get, "/manifests/#{manifest_id}")
        |> put_auth_header(token)
        |> Router.call(@opts)

      assert conn.status == 200

      conn =
        conn(:delete, "/manifests/#{manifest_id}")
        |> put_auth_header(token)
        |> Router.call(@opts)

      assert conn.status == 200

      conn =
        conn(:get, "/manifests/#{manifest_id}")
        |> put_auth_header(token)
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end

  defp put_auth_header(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp drop_id(response) do
    Enum.map(response, fn m -> Map.delete(m, "id") end)
  end
end
