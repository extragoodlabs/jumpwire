defmodule JumpWire.API.ManifestRouter do
  @moduledoc """
  A Plug.Router for handling manifest related API routes.
  """

  use Plug.Router
  use Honeybadger.Plug
  use Plug.ErrorHandler
  import JumpWire.Router.Helpers
  require Logger

  @sso_module Application.compile_env(:jumpwire, [:sso, :module])

  plug :match
  plug :put_secret_key_base

  plug Plug.Session,
    store: :cookie,
    key: "_jumpwire_key",
    signing_salt: "I5bC7Dc3"

  plug :fetch_session
  plug JumpWire.API.AuthPipeline
  plug :fetch_query_params

  plug Plug.Parsers,
    parsers: [{:json, json_decoder: Jason}],
    pass: ["*/*"]

  plug :json_response
  plug :dispatch

  get "/" do
    type = Map.get(conn.query_params, "type")

    case @sso_module.fetch_active_assertion(conn) do
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
    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
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

    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
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

    case @sso_module.fetch_active_assertion(conn) do
      {:ok, assertion} ->
        JumpWire.Manifest.delete(assertion.computed.org_id, id)
        send_json_resp(conn, 200, %{message: "Manifest deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  post "/:mid/proxy-schemas" do
    manifest_id = String.downcase(mid)

    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
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

    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
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

    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
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

    case @sso_module.fetch_active_assertion(conn) do
      {:ok, assertion} ->
        JumpWire.Proxy.Schema.delete(assertion.computed.org_id, manifest_id, proxy_schema_id)
        send_json_resp(conn, 200, %{message: "Proxt Schema deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  match _ do
    send_resp(conn, 404, %{error: "not found"})
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    body = %{error: "an unknown error occurred", status: conn.status}
    send_json_resp(conn, conn.status, body)
  end

  defp json_response(conn, _opts) do
    put_resp_content_type(conn, "application/json")
  end

  defp send_json_resp(conn, status, body) do
    send_resp(conn, status, Jason.encode!(body))
  end
end
