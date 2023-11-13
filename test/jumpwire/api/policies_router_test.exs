defmodule JumpWire.PoliciesRouterTest do
  use ExUnit.Case, async: true
  use Plug.Test
  import Mox
  alias JumpWire.API.PoliciesRouter

  @opts PoliciesRouter.init([])

  @org_id "adb4eef3-a8da-457c-8e69-9e589d109f90"

  # Ensure tests are run such that they can use the mock
  setup :verify_on_exit!

  setup do
    # Register cleanup callback
    on_exit(fn ->
      JumpWire.Policy.delete_all(@org_id)
    end)

    :ok
  end

  describe "/" do
    test "GET returns a 200 status with valid SSO" do
      mock_policy = JumpWire.API.RouterMocks.policy("test-policy", "access")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: @org_id}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_policy)
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 201

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 200

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          expected = mock_policy

          assert length(body) == 1
          head = List.first(body)

          assert expected["name"] == head["name"]
          assert expected["handling"] == head["handling"]
          assert expected["configuration"] == head["configuration"]

        {:error, _} ->
          assert false
      end
    end

    test "POST returns a 201 status with valid input" do
      mock_policy = JumpWire.API.RouterMocks.policy("test-policy", "access")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 3, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "[]"

      conn =
        conn(:post, "/", mock_policy)
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 201

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          expected = mock_policy

          assert length(body) == 1
          head = List.first(body)

          assert expected["name"] == head["name"]
          assert expected["handling"] == head["handling"]
          assert expected["configuration"] == head["configuration"]

        {:error, _} ->
          assert false
      end
    end

    test "PUT returns a 201 status with valid input" do
      mock_policy = JumpWire.API.RouterMocks.policy("test-policy", "access")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 4, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 200
      assert conn.resp_body == "[]"

      conn =
        conn(:post, "/", mock_policy)
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 201

      conn =
        conn(:get, "/")
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          expected = mock_policy

          assert length(body) == 1
          head = List.first(body)
          assert expected["name"] == head["name"]

          updated = Map.put(head, "name", "updated-policy")

          conn =
            conn(:put, "/#{head["id"]}", updated)
            |> put_auth_header(token)
            |> PoliciesRouter.call(@opts)

          assert conn.status == 200

          case Jason.decode(conn.resp_body) do
            {:ok, body} ->
              assert body["name"] == "updated-policy"
              assert updated["handling"] == body["handling"]
              assert updated["configuration"] == body["configuration"]

            {:error, _} ->
              assert false
          end

        {:error, _} ->
          assert false
      end
    end

    test "GET /:id returns a 200 status with valid group ID" do
      mock_policy = JumpWire.API.RouterMocks.policy("test-policy", "access")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 2, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_policy)
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 201

      case Jason.decode(conn.resp_body) do
        {:ok, body} ->
          group_id = body["id"]

          conn =
            conn(:get, "/#{group_id}")
            |> put_auth_header(token)
            |> PoliciesRouter.call(@opts)

          assert conn.status == 200

          case Jason.decode(conn.resp_body) do
            {:ok, body} ->
              expected = mock_policy
              assert expected["name"] == body["name"]

            {:error, _} ->
              assert false
          end

        {:error, _} ->
          assert false
      end
    end

    test "DELETE /:id returns a 200 status with valid group ID" do
      mock_policy = JumpWire.API.RouterMocks.policy("test-policy", "access")

      expect(JumpWire.SSO.MockImpl, :fetch_active_assertion, 4, fn _ ->
        {:ok, %{computed: %{org_id: "adb4eef3-a8da-457c-8e69-9e589d109f90"}}}
      end)

      token = JumpWire.API.Token.get_root_token()

      conn =
        conn(:post, "/", mock_policy)
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 201

      {:ok, group} = Jason.decode(conn.resp_body)

      group_id = group["id"]

      conn =
        conn(:get, "/#{group_id}")
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:delete, "/#{group_id}")
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

      assert conn.status == 200

      conn =
        conn(:get, "/#{group_id}")
        |> put_auth_header(token)
        |> PoliciesRouter.call(@opts)

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
end
