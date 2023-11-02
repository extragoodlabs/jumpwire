defmodule JumpWire.API.Router do
  @moduledoc """
  A Plug.Router for handling internal API calls with authentication.
  """

  use Plug.Router
  use Honeybadger.Plug
  use Plug.ErrorHandler
  alias JumpWire.API.Token
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

  get "/status" do
    body = JumpWire.HealthCheck.status()
    send_json_resp(conn, 200, body)
  end

  get "/token" do
    {id, permissions} = Guardian.Plug.current_claims(conn)
    body = %{"id" => id, "permissions" => permissions}
    send_json_resp(conn, 200, body)
  end

  post "/token" do
    permissions = Map.get(conn.body_params, "permissions", [])
    token = Token.generate(permissions)
    send_json_resp(conn, 201, %{token: token})
  end

  get "/auth/:token" do
    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
         {:ok, {_nonce, type}} <- Token.verify_jit_auth_request(token) do
      body =
        JumpWire.Manifest.get_by_type(assertion.computed.org_id, type)
        |> Stream.map(fn m -> {m.id, m.name} end)
        |> Map.new()

      send_json_resp(conn, 200, body)
    else
      _ ->
        send_json_resp(conn, 403, %{error: "Invalid token"})
    end
  end

  put "/auth/:token" do
    with {:ok, manifest_id} <- Map.fetch(conn.body_params, "manifest_id"),
         {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
         org_id <- assertion.computed.org_id,
         {:ok, {nonce, type}} <- Token.verify_jit_auth_request(token),
         {:ok, %{root_type: ^type}} <- JumpWire.Manifest.fetch(org_id, manifest_id),
         {:ok, client} <- @sso_module.create_client(assertion, nonce, manifest_id) do
      JumpWire.PubSub.broadcast("*", {:client_authenticated, org_id, manifest_id, nonce, client})

      body = %{message: "Authentication request approved!", client_id: client.id}
      send_json_resp(conn, 200, body)
    else
      err ->
        Logger.error("Authentication token was not valid: #{inspect(err)}")
        send_json_resp(conn, 403, %{error: "Invalid token"})
    end
  end

  get "/client/:id" do
    org_id = JumpWire.Metadata.get_org_id()

    case JumpWire.ClientAuth.fetch(org_id, id) do
      {:ok, client} ->
        client = Map.take(client, [:id, :attributes, :manifest_id, :name, :organization_id])
        send_json_resp(conn, 200, client)

      err ->
        Logger.error("Could not retrieve client_auth: #{inspect(err)}")
        send_json_resp(conn, 400, %{error: "Invalid client ID"})
    end
  end

  put "/client/:id/token" do
    org_id = JumpWire.Metadata.get_org_id()

    opts =
      case Map.get(conn.params, "ttl", "") |> Integer.parse() do
        {ttl, ""} -> [ttl: ttl]
        _ -> []
      end

    with {:ok, client} <- JumpWire.ClientAuth.fetch(org_id, id),
         {:ok, manifest} <- JumpWire.Manifest.fetch(org_id, client.manifest_id) do
      token = JumpWire.Proxy.sign_token(org_id, client.id, opts)
      ports = JumpWire.Proxy.ports()

      body = %{
        token: token,
        id: client.id,
        manifest_id: manifest.id,
        domain: JumpWire.Proxy.domain(),
        port: ports[manifest.root_type],
        protocol: manifest.root_type,
        database: JumpWire.Manifest.database_name(manifest)
      }

      send_json_resp(conn, 200, body)
    else
      err ->
        Logger.error("Could not retrieve client_auth: #{inspect(err)}")
        send_json_resp(conn, 400, %{error: "Invalid client ID"})
    end
  end

  forward "/manifests", to: JumpWire.API.ManifestRouter
  forward "/groups", to: JumpWire.API.GroupsRouter

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
