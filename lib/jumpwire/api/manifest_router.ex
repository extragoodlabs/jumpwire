defmodule JumpWire.API.ManifestRouter do
  @moduledoc """
  A Plug.Router for handling manifest related API routes.
  """

  use Plug.Router
  require Logger
  import JumpWire.Router.Helpers

  plug :match
  plug :dispatch

  get "/" do
    type = Map.get(conn.query_params, "type")

    case fetch_active_assertion(:stub) do
      {:ok, assertion} ->
        body =
          if type do
            JumpWire.Manifest.get_by_type(assertion.computed.org_id, String.downcase(type))
            |> Stream.map(fn m -> {m.id, m.name} end)
            |> Map.new()
          else
            JumpWire.Manifest.all(assertion.computed.org_id)
          end

        send_json_resp(conn, 200, body)

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  put "/" do
    with {:ok, assertion} <- fetch_active_assertion(:stub),
         uuid <- Uniq.UUID.uuid4(),
         {:ok, manifest} <-
           conn.body_params
           |> Map.put("id", uuid)
           |> JumpWire.Manifest.from_json(assertion.computed.org_id),
         _ <- JumpWire.Manifest.put(assertion.computed.org_id, manifest),
         {:ok, manifest} <- JumpWire.Manifest.fetch(assertion.computed.org_id, manifest.id) do
      send_json_resp(conn, 201, manifest)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      {:error, reason} ->
        Logger.error("Failed to process manifest: #{inspect(reason)}")
        send_resp(conn, 400, "Failed to process manifest")

      _ ->
        send_json_resp(conn, 500, %{error: "Failed to create manifest"})
    end
  end

  get "/:id" do
    id = String.downcase(id)

    with {:ok, assertion} <- fetch_active_assertion(:stub),
         {:ok, manifest} <- JumpWire.Manifest.fetch(assertion.computed.org_id, id) do
      send_json_resp(conn, 200, manifest)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      _ ->
        send_json_resp(conn, 404, %{error: "Manifest not found"})
    end
  end

  delete "/:id" do
    id = String.downcase(id)

    case fetch_active_assertion(:stub) do
      {:ok, assertion} ->
        JumpWire.Manifest.delete(assertion.computed.org_id, id)
        send_json_resp(conn, 200, %{message: "Manifest deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  post "/:mid/proxy-schemas" do
    manifest_id = String.downcase(mid)

    with {:ok, assertion} <- fetch_active_assertion(:stub),
         uuid <- Uniq.UUID.uuid4(),
         {:ok, raw_schema} <-
           conn.body_params
           |> Map.put("id", uuid)
           |> Map.put("manifest_id", manifest_id)
           |> JumpWire.Proxy.Schema.from_json(assertion.computed.org_id),
         _ <- JumpWire.Proxy.Schema.put(assertion.computed.org_id, raw_schema),
         {:ok, schema} <- JumpWire.Proxy.Schema.fetch(assertion.computed.org_id, manifest_id, uuid) do
      schema = %JumpWire.Proxy.Schema{schema | fields: JumpWire.Proxy.Schema.denormalize_schema_fields(schema)}
      send_json_resp(conn, 201, schema)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      {:error, reason} ->
        Logger.error("Failed to process schema: #{inspect(reason)}")
        send_resp(conn, 400, "Failed to process schema")

      _ ->
        send_json_resp(conn, 500, %{error: "Failed to create schema"})
    end
  end

  get "/:mid/proxy-schemas" do
    manifest_id = String.downcase(mid)

    with {:ok, assertion} <- fetch_active_assertion(:stub),
         schemas <- JumpWire.Proxy.Schema.list_all(assertion.computed.org_id, manifest_id) do
      schemas =
        Enum.map(schemas, fn s ->
          %JumpWire.Proxy.Schema{s | fields: JumpWire.Proxy.Schema.denormalize_schema_fields(s)}
        end)

      send_json_resp(conn, 200, schemas)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      _ ->
        send_json_resp(conn, 404, %{error: "Proxy Schemas not found"})
    end
  end

  get "/:mid/proxy-schemas/:id" do
    manifest_id = String.downcase(mid)
    proxy_schema_id = String.downcase(id)

    with {:ok, assertion} <- fetch_active_assertion(:stub),
         {:ok, schema} <- JumpWire.Proxy.Schema.fetch(assertion.computed.org_id, manifest_id, proxy_schema_id) do
      schema = %JumpWire.Proxy.Schema{schema | fields: JumpWire.Proxy.Schema.denormalize_schema_fields(schema)}
      send_json_resp(conn, 200, schema)
    else
      {:error, :not_found} ->
        send_json_resp(conn, 404, %{error: "Proxy Schema not found"})

      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      _ ->
        send_json_resp(conn, 404, %{error: "Proxy Schema not found"})
    end
  end

  delete "/:mid/proxy-schemas/:id" do
    manifest_id = String.downcase(mid)
    proxy_schema_id = String.downcase(id)

    case fetch_active_assertion(:stub) do
      {:ok, assertion} ->
        JumpWire.Proxy.Schema.delete(assertion.computed.org_id, manifest_id, proxy_schema_id)
        send_json_resp(conn, 200, %{message: "Proxt Schema deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  post "/:mid/client-auths" do
    manifest_id = String.downcase(mid)

    with {:ok, assertion} <- fetch_active_assertion(:stub),
         uuid <- Uniq.UUID.uuid4(),
         {:ok, raw_client_auth} <-
           conn.body_params
           |> Map.put("id", uuid)
           |> Map.put("manifest_id", manifest_id)
           |> JumpWire.ClientAuth.from_json(assertion.computed.org_id),
         _ <- JumpWire.ClientAuth.put(assertion.computed.org_id, raw_client_auth),
         {:ok, client_auth} <- JumpWire.ClientAuth.fetch(assertion.computed.org_id, manifest_id, uuid) do
      send_json_resp(conn, 201, client_auth)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      {:error, reason} ->
        Logger.error("Failed to process client auth: #{inspect(reason)}")
        send_resp(conn, 400, "Failed to process client auth")

      _ ->
        send_json_resp(conn, 500, %{error: "Failed to create client auth"})
    end
  end

  get "/:mid/client-auths" do
    manifest_id = String.downcase(mid)

    with {:ok, assertion} <- fetch_active_assertion(:stub),
         client_auths <- JumpWire.ClientAuth.list_all(assertion.computed.org_id, manifest_id) do
      send_json_resp(conn, 200, client_auths)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      _ ->
        send_json_resp(conn, 404, %{error: "Client auths not found"})
    end
  end

  get "/:mid/client-auths/:id" do
    manifest_id = String.downcase(mid)
    client_auth_id = String.downcase(id)

    with {:ok, assertion} <- fetch_active_assertion(:stub),
         {:ok, client_auth} <- JumpWire.ClientAuth.fetch(assertion.computed.org_id, manifest_id, client_auth_id) do
      send_json_resp(conn, 200, client_auth)
    else
      {:error, :not_found} ->
        send_json_resp(conn, 404, %{error: "Client Auth not found"})

      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      _ ->
        send_json_resp(conn, 404, %{error: "Client Auth not found"})
    end
  end

  delete "/:mid/client-auths/:id" do
    manifest_id = String.downcase(mid)
    client_auth_id = String.downcase(id)

    case fetch_active_assertion(:stub) do
      {:ok, assertion} ->
        JumpWire.ClientAuth.delete(assertion.computed.org_id, manifest_id, client_auth_id)
        send_json_resp(conn, 200, %{message: "Client Auth deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  match _ do
    send_resp(conn, 404, %{error: "not found"})
  end
end
