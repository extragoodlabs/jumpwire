defmodule JumpWire.Token.VerifyAuthorization do
  import Plug.Conn
  @behaviour Plug

  @impl Plug
  def init(opts \\ []) do
    opts
  end

  @impl Plug
  def call(conn, _opts) do
    with {:ok, header} <- fetch_authorization_header(conn),
         {:ok, {organization_id, manifest_id}} <- JumpWire.Proxy.verify_token(header) do
      JumpWire.Tracer.context(org_id: organization_id, manifest: manifest_id)
      conn
      |> assign(:organization_id, organization_id)
      |> assign(:manifest_id, manifest_id)
    else
      :not_found ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:unauthorized, Jason.encode!(%{"msg" => "Missing Bearer token"}))
        |> halt()

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:unauthorized, Jason.encode!(%{"msg" => "Invalid Bearer token"}))
        |> halt()
    end
  end

  @spec fetch_authorization_header(Plug.Conn.t()) :: :not_found | {:ok, String.t()}
  def fetch_authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> header | _] -> {:ok, String.trim(header)}
      _ -> :not_found
    end
  end
end
