defmodule JumpWire.GroupsRouterTest do
  use ExUnit.Case, async: true
  use Plug.Test
  import Mox
  alias JumpWire.API.GroupsRouter

  @opts GroupsRouter.init([])

  # Ensure tests are run such that they can use the mock
  setup :verify_on_exit!

  setup do
    # Register cleanup callback
    on_exit(fn ->
      JumpWire.GlobalConfig.delete_all(:groups)
    end)

    :ok
  end

  describe "/" do
    test "GET returns a 200 status with valid SSO" do
      mock_group = JumpWire.API.RouterMocks.group("test-group", ["select:secret", "update:secret"])

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn = conn(:post, "/", mock_group)
      |> put_auth_header(token)
      |> GroupsRouter.call(@opts)

      assert conn.status == 201

      conn = conn(:get, "/")
      |> put_auth_header(token)
      |> GroupsRouter.call(@opts)

      assert conn.status == 200

      assert {:ok, [head]} = Jason.decode(conn.resp_body)
      assert length(head["policies"]) == 2
      assert mock_group["name"] == head["name"]
    end

    test "PUT returns a 201 status with valid input" do
      mock_group = JumpWire.API.RouterMocks.group("test-group", ["filed:secret", "other:secret"])

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn = conn(:get, "/")
      |> put_auth_header(token)
      |> GroupsRouter.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "[]"

      conn = conn(:post, "/", mock_group)
      |> put_auth_header(token)
      |> GroupsRouter.call(@opts)

      assert conn.status == 201

      conn = conn(:get, "/")
      |> put_auth_header(token)
      |> GroupsRouter.call(@opts)

      assert {:ok, [head]} = Jason.decode(conn.resp_body)
      assert length(head["policies"]) == 2
      assert mock_group["name"] == head["name"]
    end

    test "GET /:id returns a 200 status with valid group ID" do
      mock_group = JumpWire.API.RouterMocks.group("test-group", ["filed:secret", "other:secret"])

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_group)
        |> put_auth_header(token)
        |> GroupsRouter.call(@opts)

      assert conn.status == 201

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          group_id = body["id"]

          conn =
            conn(:get, "/#{group_id}")
            |> put_auth_header(token)
            |> GroupsRouter.call(@opts)

          assert conn.status == 200

          case Jason.decode(conn.resp_body) do
            {:ok, body} ->
              assert mock_group["name"] == body["name"]
              assert length(body["policies"]) == 2
              assert body["organization_id"] == "adb4eef3-a8da-457c-8e69-9e589d109f90"

            {:error, _} ->
              assert false
          end

        {:error, _} ->
          assert false
      end
    end

    test "DELETE /:id returns a 200 status with valid group ID" do
      mock_group = JumpWire.API.RouterMocks.group("test-group", ["filed:secret", "other:secret"])

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 4, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_group)
        |> put_auth_header(token)
        |> GroupsRouter.call(@opts)

      assert conn.status == 201

      {:ok, group} = Jason.decode(conn.resp_body)

      group_id = group["id"]

      conn =
        conn(:get, "/#{group_id}")
        |> put_auth_header(token)
        |> GroupsRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:delete, "/#{group_id}")
        |> put_auth_header(token)
        |> GroupsRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:get, "/#{group_id}")
        |> put_auth_header(token)
        |> GroupsRouter.call(@opts)

      assert conn.status == 404
    end
  end

  defp put_auth_header(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
