defmodule JumpWire.Router do
  use Plug.Router
  use Honeybadger.Plug
  require Logger

  if Mix.env() == :dev or Mix.env() == :test do
    use Plug.Debugger
  end

  plug :match
  plug :fetch_query_params

  plug Plug.Parsers,
    parsers: [{:json, json_decoder: Jason}],
    pass: ["*/*"]

  plug :dispatch

  get "/.well-known/acme-challenge/:token" do
    case JumpWire.ACME.Challenge.got_challenge(token) do
      nil ->
        conn
        |> send_resp(404, "Not found")
        |> halt()

      thumbprint ->
        conn
        |> send_resp(200, "#{token}.#{thumbprint}")
        |> halt()
    end
  end

  get "/ping" do
    # /ping is left unautenticated to make it easy to use with
    # automatic healthchecks
    send_resp(conn, 200, "pong")
  end

  get "/" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{message: "Welcome to JumpWire"}))
  end

  forward "/sso", to: JumpWire.SSO.Router
  forward "/tokens", to: JumpWire.Token.Router
  forward "/api/v1", to: JumpWire.API.Router

  match _ do
    send_resp(conn, 404, "not found")
  end
end
