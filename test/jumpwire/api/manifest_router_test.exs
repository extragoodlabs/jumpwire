defmodule JumpWire.API.ManifestRouterTest do
  use ExUnit.Case, async: true
  use Plug.Test
  import Mox
  alias JumpWire.API.ManifestRouter

  @opts ManifestRouter.init([])

  # Ensure tests are run such that they can use the mock
  setup :verify_on_exit!

  setup do
    # Register cleanup callback
    on_exit(fn ->
      JumpWire.GlobalConfig.delete_all(:manifests)
    end)

    :ok
  end

  describe "/" do
    test "GET returns a 200 status with valid SSO" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn(:put, "/", mock_manifest)
      |> put_auth_header(token)
      |> ManifestRouter.call(@opts)

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

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

    test "PUT returns a 201 status with valid input" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "[]"

      conn =
        conn(:put, "/", mock_manifest)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          expected = [mock_manifest]

          assert length(body) == 1
          assert expected == drop_id(body)

        {:error, _} ->
          assert false
      end
    end

    test "GET /:id returns a 200 status with valid manifest ID" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:put, "/", mock_manifest)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          manifest_id = body["id"]

          conn =
            conn(:get, "/#{manifest_id}")
            |> put_auth_header(token)
            |> ManifestRouter.call(@opts)

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

    test "DELETE /:id returns a 200 status with valid manifest ID" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 4, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:put, "/", mock_manifest)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, manifest} = Jason.decode(conn.resp_body)

      manifest_id = manifest["id"]

      conn =
        conn(:get, "/#{manifest_id}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:delete, "/#{manifest_id}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:get, "/#{manifest_id}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 404
    end
  end

  describe "/:mid/proxy-schemas" do
    test "GET returns a 200 status with valid SSO" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_schema = JumpWire.API.RouterMocks.proxy_schema("test-schema", manifest_id)

      # add a schema
      conn =
        conn(:post, "/#{manifest_id}/proxy-schemas", mock_schema)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      # get the schemas
      conn =
        conn(:get, "/#{manifest_id}/proxy-schemas")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          assert length(body) == 1
          body = hd(body)

          assert body["name"] == mock_schema["name"]
          assert body["id"] != nil
          assert body["manifest_id"] == manifest_id

          mock_schema_fields_count = mock_schema["fields"] |> Map.keys() |> length()
          assert body["fields"] |> Map.keys() |> length() == mock_schema_fields_count

        {:error, _} ->
          assert false
      end
    end

    test "PUT returns a 201 status with valid input" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_schema = JumpWire.API.RouterMocks.proxy_schema("test-schema", manifest_id)

      conn =
        conn(:post, "/#{manifest_id}/proxy-schemas", mock_schema)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, schema} = Jason.decode(conn.resp_body)

      assert schema["name"] == mock_schema["name"]
      assert schema["id"] != nil
      assert schema["manifest_id"] == manifest_id

      mock_schema_fields_count = mock_schema["fields"] |> Map.keys() |> length()
      assert schema["fields"] |> Map.keys() |> length() == mock_schema_fields_count
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_schema = JumpWire.API.RouterMocks.proxy_schema("test-schema", manifest_id)

      # add a schema
      conn =
        conn(:post, "/#{manifest_id}/proxy-schemas", mock_schema)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, schema} = Jason.decode(conn.resp_body)

      # get the schemas
      conn =
        conn(:get, "/#{manifest_id}/proxy-schemas/#{schema["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          assert body["name"] == mock_schema["name"]
          assert body["id"] != nil
          assert body["manifest_id"] == manifest_id

          mock_schema_fields_count = mock_schema["fields"] |> Map.keys() |> length()
          assert body["fields"] |> Map.keys() |> length() == mock_schema_fields_count

        {:error, _} ->
          assert false
      end
    end

    test "DELETE /:id returns a 200 status with valid schema ID" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 5, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_schema = JumpWire.API.RouterMocks.proxy_schema("test-schema", manifest_id)

      # add a schema
      conn =
        conn(:post, "/#{manifest_id}/proxy-schemas", mock_schema)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, schema} = Jason.decode(conn.resp_body)

      # get the schemas
      conn =
        conn(:get, "/#{manifest_id}/proxy-schemas/#{schema["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:delete, "/#{manifest_id}/proxy-schemas/#{schema["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:get, "/#{manifest_id}/proxy-schemas/#{schema["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 404
    end
  end

  describe "/:mid/client-auths" do
    test "GET returns a 200 status with valid SSO" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_client_auth = JumpWire.API.RouterMocks.client_auth("test-client-auth", manifest_id)

      # add a client_auth
      conn =
        conn(:post, "/#{manifest_id}/client-auths", mock_client_auth)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      # get the client_auths
      conn =
        conn(:get, "/#{manifest_id}/client-auths")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          assert length(body) == 1
          body = hd(body)

          assert body["name"] == mock_client_auth["name"]
          assert body["id"] != nil
          assert body["manifest_id"] == manifest_id

        {:error, _} ->
          assert false
      end
    end

    test "PUT returns a 201 status with valid input" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_client_auth = JumpWire.API.RouterMocks.client_auth("test-client-auth", manifest_id)

      conn =
        conn(:post, "/#{manifest_id}/client-auths", mock_client_auth)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, client_auth} = Jason.decode(conn.resp_body)

      assert client_auth["id"] != nil
      assert client_auth["manifest_id"] == manifest_id
    end

    test "GET /:id returns a 200 status with a valid client_auth ID" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_client_auth = JumpWire.API.RouterMocks.client_auth("test-client-auth", manifest_id)

      # add a client_auth
      conn =
        conn(:post, "/#{manifest_id}/client-auths", mock_client_auth)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, client_auth} = Jason.decode(conn.resp_body)

      # get the client_auths
      conn =
        conn(:get, "/#{manifest_id}/client-auths/#{client_auth["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          assert body["name"] == mock_client_auth["name"]
          assert body["id"] != nil
          assert body["manifest_id"] == manifest_id

        {:error, _} ->
          assert false
      end
    end

    test "DELETE /:id returns a 200 status with valid client_auth ID" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 5, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_client_auth = JumpWire.API.RouterMocks.client_auth("test-client-auth", manifest_id)

      # add a client_auth
      conn =
        conn(:post, "/#{manifest_id}/client-auths", mock_client_auth)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, client_auth} = Jason.decode(conn.resp_body)

      # get the client_auths
      conn =
        conn(:get, "/#{manifest_id}/client-auths/#{client_auth["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:delete, "/#{manifest_id}/client-auths/#{client_auth["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:get, "/#{manifest_id}/client-auths/#{client_auth["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 404
    end
  end

  describe "/:mid/client-auths" do
    test "GET returns a 200 status with valid SSO" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_client_auth = JumpWire.API.RouterMocks.client_auth("test-client-auth", manifest_id)

      # add a client_auth
      conn =
        conn(:post, "/#{manifest_id}/client-auths", mock_client_auth)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      # get the client_auths
      conn =
        conn(:get, "/#{manifest_id}/client-auths")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          assert length(body) == 1
          body = hd(body)

          assert body["name"] == mock_client_auth["name"]
          assert body["id"] != nil
          assert body["manifest_id"] == manifest_id

        {:error, _} ->
          assert false
      end
    end

    test "PUT returns a 201 status with valid input" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_client_auth = JumpWire.API.RouterMocks.client_auth("test-client-auth", manifest_id)

      conn =
        conn(:post, "/#{manifest_id}/client-auths", mock_client_auth)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, client_auth} = Jason.decode(conn.resp_body)

      assert client_auth["name"] == mock_client_auth["name"]
      assert client_auth["id"] != nil
      assert client_auth["manifest_id"] == manifest_id
    end

    test "GET /:id returns a 200 status with a valid client_auth ID" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_client_auth = JumpWire.API.RouterMocks.client_auth("test-client-auth", manifest_id)

      # add a client_auth
      conn =
        conn(:post, "/#{manifest_id}/client-auths", mock_client_auth)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, client_auth} = Jason.decode(conn.resp_body)

      # get the client_auths
      conn =
        conn(:get, "/#{manifest_id}/client-auths/#{client_auth["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          assert body["name"] == mock_client_auth["name"]
          assert body["id"] != nil
          assert body["manifest_id"] == manifest_id

        {:error, _} ->
          assert false
      end
    end

    test "DELETE /:id returns a 200 status with valid client_auth ID" do
      mock_manifest = JumpWire.API.RouterMocks.manifest("test-manifest")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 5, fn _ ->
        {:ok, %{computed: %{org_id: "test-org-id"}}}
      end)

      {:ok, manifest} = add_manifest(mock_manifest)

      token = JumpWire.API.Token.get_root_token()
      manifest_id = manifest["id"]

      mock_client_auth = JumpWire.API.RouterMocks.client_auth("test-client-auth", manifest_id)

      # add a client_auth
      conn =
        conn(:post, "/#{manifest_id}/client-auths", mock_client_auth)
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 201

      {:ok, client_auth} = Jason.decode(conn.resp_body)

      # get the client_auths
      conn =
        conn(:get, "/#{manifest_id}/client-auths/#{client_auth["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:delete, "/#{manifest_id}/client-auths/#{client_auth["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:get, "/#{manifest_id}/client-auths/#{client_auth["id"]}")
        |> put_auth_header(token)
        |> ManifestRouter.call(@opts)

      assert conn.status == 404
    end
  end

  defp put_auth_header(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp drop_id(response) when is_list(response) do
    Enum.map(response, fn r -> Map.drop(r, ["id"]) end)
  end

  defp drop_id(response) when is_map(response) do
    Map.drop(response, ["id"])
  end

  defp add_manifest(manifest) do
    token = JumpWire.API.Token.get_root_token()

    conn =
      conn(:put, "/", manifest)
      |> put_auth_header(token)
      |> ManifestRouter.call(@opts)

    Jason.decode(conn.resp_body)
  end
end
