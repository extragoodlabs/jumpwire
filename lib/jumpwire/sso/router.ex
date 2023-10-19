defmodule JumpWire.SSO.Router do
  @moduledoc """
  Routing and Plugs for SSO related functionality.
  """

  use Plug.Router
  require Logger
  alias JumpWire.API.Token
  import JumpWire.Router.Helpers

  @sso_module Application.compile_env(:jumpwire, [:sso, :module])

  plug :match

  # Required for CSRF token handling in the Samly router
  plug :put_secret_key_base

  plug Plug.Session,
    store: :cookie,
    key: "_jumpwire_key",
    signing_salt: "I5bC7Dc3"

  plug :fetch_session

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug :dispatch

  get "/debug" do
    data = Samly.get_active_assertion(conn) |> Jason.encode!()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, data)
  end

  get "/" do
    idps = Application.get_env(:samly, Samly.Provider)[:identity_providers] || []
    idp_ids = Enum.map(idps, fn idp -> Map.get(idp, :id) end)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(idp_ids))
  end

  @sso_result_template """
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
  <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
    <head>
      <meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>
      <script>
        function copyCode() {
          var copyText = document.getElementById("code");
          navigator.clipboard.writeText(copyText.value);
        }
      </script>
    </head>
    <body>
      <div style="width: 70%; margin: auto; border: 1px solid #81b29a; text-align: center; padding-bottom: 8px">
        <p>✅ Successfully authenticated!</p>
        <p>Enter the following code in the CLI:</p>
        <pre><%= @token %></pre>
        <input id="code" type="hidden" value="<%= @token %>" />
        <button onclick="copyCode()">Copy code</button>
      </div>
    </body>
  </html>
  """

  get "/result" do
    assertion_key = get_session(conn, "samly_assertion_key")

    case assertion_key do
      {_idp, _name} ->
        token = Token.sign_sso_key(assertion_key)

        conn
        |> put_resp_header("content-type", "text/html")
        |> send_resp(200, EEx.eval_string(@sso_result_template, assigns: [token: token]))

      _ ->
        send_resp(conn, 403, "No SSO assertion found")
    end
  end

  post "/validate" do
    with {:ok, token} <- Map.fetch(conn.body_params, "sso_code"),
         {:ok, key} <- Token.verify_sso_key(token),
         {:ok, _assertion} <- @sso_module.fetch_assertion(conn, key) do
      Logger.debug("Verified SSO token for #{inspect(key)}")
      body = %{message: "Successfully authenticated"} |> Jason.encode!()
      # TODO: optionally flesh out API permissions from SSO attributes
      permissions = %{all: [:root]}

      conn
      |> put_session("samly_assertion_key", key)
      |> put_resp_header("content-type", "application/json")
      |> JumpWire.API.Guardian.Plug.sign_in(key, permissions)
      |> JumpWire.API.Guardian.Plug.remember_me(key, permissions)
      |> send_resp(200, body)
    else
      _ ->
        Logger.warn("Failed to validate SSO session")
        body = %{error: "Invalid SSO token provided"} |> Jason.encode!()

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(403, body)
    end
  end

  get "/whoami" do
    conn = put_resp_header(conn, "content-type", "application/json")

    case Samly.get_active_assertion(conn) do
      nil ->
        body = %{error: "Invalid SSO session"} |> Jason.encode!()
        send_resp(conn, 403, body)

      assertion ->
        subject_name = assertion.subject.name
        idp_id = assertion.idp_id
        body = %{idp: idp_id, subject_name: subject_name} |> Jason.encode!()
        send_resp(conn, 200, body)
    end
  end

  forward("/", to: Samly.Router)
end
