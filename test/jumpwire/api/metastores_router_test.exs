defmodule JumpWire.MetastoresRouterTest do
  use ExUnit.Case, async: true
  use Plug.Test
  import Mox
  alias JumpWire.API.MetastoresRouter

  @opts MetastoresRouter.init([])

  # Ensure tests are run such that they can use the mock
  setup :verify_on_exit!

  setup do
    # Register cleanup callback
    on_exit(fn ->
      JumpWire.GlobalConfig.delete_all(:metastores)
    end)

    :ok
  end

  describe "/" do
    test "GET returns a 200 status with credential metastore" do
      mock_metastore = JumpWire.API.RouterMocks.metastore_with_creds("test-metastore")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_metastore)
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 201

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          expected = mock_metastore

          assert length(body) == 1
          head = List.first(body)

          assert expected["name"] == head["name"]
          assert head["organization_id"] == "adb4eef3-a8da-457c-8e69-9e589d109f90"

          assert expected["configuration"]["table"] == head["configuration"]["table"]
          assert expected["configuration"]["key_field"] == head["configuration"]["key_field"]
          assert expected["configuration"]["value_field"] == head["configuration"]["value_field"]

          assert expected["configuration"]["connection"]["hostname"] == head["configuration"]["connection"]["hostname"]
          assert expected["configuration"]["connection"]["port"] == head["configuration"]["connection"]["port"]
          assert expected["configuration"]["connection"]["ssl"] == head["configuration"]["connection"]["ssl"]

        {:error, _} ->
          assert false
      end
    end

    test "GET returns a 400 status when credentials are missing from metastore" do
      mock_metastore = JumpWire.API.RouterMocks.metastore_without_creds("test-metastore")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 1, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_metastore)
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 400
    end

    test "PUT returns a 201 status with valid input" do
      mock_metastore = JumpWire.API.RouterMocks.metastore_with_creds("test-metastore")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "[]"

      conn =
        conn(:post, "/", mock_metastore)
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 201

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          expected = mock_metastore

          assert length(body) == 1
          head = List.first(body)

          assert expected["name"] == head["name"]
          assert head["organization_id"] == "adb4eef3-a8da-457c-8e69-9e589d109f90"

          assert expected["configuration"]["table"] == head["configuration"]["table"]
          assert expected["configuration"]["key_field"] == head["configuration"]["key_field"]
          assert expected["configuration"]["value_field"] == head["configuration"]["value_field"]

          assert expected["configuration"]["connection"]["hostname"] == head["configuration"]["connection"]["hostname"]
          assert expected["configuration"]["connection"]["port"] == head["configuration"]["connection"]["port"]
          assert expected["configuration"]["connection"]["ssl"] == head["configuration"]["connection"]["ssl"]

        {:error, _} ->
          assert false
      end
    end

    test "GET /:id returns a 200 status with valid metastore ID" do
      mock_metastore = JumpWire.API.RouterMocks.metastore_with_creds("test-metastore")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_metastore)
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 201

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          group_id = body["id"]

          conn =
            conn(:get, "/#{group_id}")
            |> put_auth_header(token)
            |> MetastoresRouter.call(@opts)

          assert conn.status == 200

          case Jason.decode(conn.resp_body) do
            {:ok, body} ->
              expected = mock_metastore

              assert expected["name"] == body["name"]
              assert body["organization_id"] == "adb4eef3-a8da-457c-8e69-9e589d109f90"

              assert expected["configuration"]["table"] == body["configuration"]["table"]
              assert expected["configuration"]["key_field"] == body["configuration"]["key_field"]
              assert expected["configuration"]["value_field"] == body["configuration"]["value_field"]

              assert expected["configuration"]["connection"]["hostname"] == body["configuration"]["connection"]["hostname"]
              assert expected["configuration"]["connection"]["port"] == body["configuration"]["connection"]["port"]
              assert expected["configuration"]["connection"]["ssl"] == body["configuration"]["connection"]["ssl"]

            {:error, _} ->
              assert false
          end

        {:error, _} ->
          assert false
      end
    end

    test "DELETE /:id returns a 200 status with valid metastore ID" do
      mock_metastore = JumpWire.API.RouterMocks.metastore_with_creds("test-metastore")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 4, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_metastore)
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 201

      {:ok, metastore} = Jason.decode(conn.resp_body)

      group_id = metastore["id"]

      conn =
        conn(:get, "/#{group_id}")
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:delete, "/#{group_id}")
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:get, "/#{group_id}")
        |> put_auth_header(token)
        |> MetastoresRouter.call(@opts)

      assert conn.status == 404
    end
  end

  defp put_auth_header(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
