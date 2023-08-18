defmodule JumpWire.RouterTest do
  use ExUnit.Case, async: true
  use Plug.Test
  alias JumpWire.Router

  @opts Router.init([])

  test "ping always pongs" do
    conn = conn(:get, "/ping")
    |> Router.call(@opts)

    assert conn.status == 200
    assert conn.resp_body == "pong"
  end

  test "status requires authentication" do
    conn = conn(:get, "/api/v1/status") |> Router.call(@opts)
    assert conn.status == 401

    token = JumpWire.API.Token.generate(get: ["status"])
    conn = conn(:get, "/api/v1/status")
    |> put_auth_header(token)
    |> Router.call(@opts)
    assert conn.status == 200
    assert {:ok, body} = Jason.decode(conn.resp_body)
    assert %{"web_connected" => false} = body
  end

  test "valid token with no permissions is denied" do
    token = JumpWire.API.Token.generate(%{})
    conn = conn(:get, "/api/v1/status")
    |> put_auth_header(token)
    |> Router.call(@opts)
    assert conn.status == 401
  end

  test "root token can be used as a bearer token" do
    token = JumpWire.API.Token.get_root_token()
    conn = conn(:get, "/api/v1/status")
    |> put_auth_header(token)
    |> Router.call(@opts)
    assert conn.status == 200
  end

  test "generating tokens" do
    token = JumpWire.API.Token.get_root_token()
    body = %{permissions: %{"get" => ["status"]}}
    conn = conn(:post, "/api/v1/token", Jason.encode!(body))
    |> put_auth_header(token)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)

    assert conn.status == 201
    assert {:ok, %{"token" => token}} = Jason.decode(conn.resp_body)
    assert {_, %{"GET" => ["status"]}} = JumpWire.API.Guardian.peek(token)
  end

  test "get info on active token" do
    token = JumpWire.API.Token.generate(get: ["token"])
    {id, permissions} = JumpWire.API.Guardian.peek(token)

    conn = conn(:get, "/api/v1/token")
    |> put_auth_header(token)
    |> Router.call(@opts)
    assert conn.status == 200
    assert {:ok, body} = Jason.decode(conn.resp_body)
    assert body == %{"id" => id, "permissions" => permissions}
  end

  describe "client_auth" do
    setup do
      org_id = JumpWire.Metadata.get_org_id()
      manifest_id = Uniq.UUID.uuid4()
      {client, _token} = JumpWire.Phony.generate_client_auth({org_id, manifest_id}, nil)
      token = JumpWire.API.Token.get_root_token()
      %{client: client, token: token}
    end

    test "can be signed on fetched", %{client: client, token: token} do
      conn = conn(:get, "/api/v1/client/#{client.id}")
      |> put_auth_header(token)
      |> Router.call(@opts)

      assert conn.status == 200
      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body == %{
        "id" => client.id,
        "organization_id" => "jumpwire_test",
        "manifest_id" => client.manifest_id,
        "name" => client.name,
        "attributes" => [],
      }
    end

    test "can be signed on demand", %{client: client, token: token} do
      conn = conn(:put, "/api/v1/client/#{client.id}/token")
      |> put_auth_header(token)
      |> Router.call(@opts)

      assert conn.status == 200
      assert {:ok, %{"token" => client_token}} = Jason.decode(conn.resp_body)
      assert {:ok, {"jumpwire_test", client.id}} == JumpWire.Proxy.verify_token(client_token)
    end

    test "can be signed with a custom ttl", %{client: client, token: token} do
      conn = conn(:put, "/api/v1/client/#{client.id}/token?ttl=1")
      |> put_auth_header(token)
      |> Router.call(@opts)

      assert conn.status == 200
      assert {:ok, %{"token" => client_token}} = Jason.decode(conn.resp_body)
      assert {:ok, {"jumpwire_test", client.id}} == JumpWire.Proxy.verify_token(client_token)
      :timer.sleep(1000)
      assert {:error, :expired} == JumpWire.Proxy.verify_token(client_token)
    end
  end

  defp put_auth_header(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
