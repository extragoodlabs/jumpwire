defmodule JumpWire.Router.Helpers do
  @moduledoc """
  Functions shared across routing/Plug modules.
  """

  def put_secret_key_base(conn, _) do
    secret_key = Application.fetch_env!(:jumpwire, :signing_token)
    put_in(conn.secret_key_base, secret_key)
  end

  @sso_module Application.compile_env(:jumpwire, [:sso, :module])
  def fetch_active_assertion(conn) do
    @sso_module.fetch_active_assertion(conn)
  end

  def send_json_resp(conn, status, body) do
    Plug.Conn.send_resp(conn, status, Jason.encode!(body))
  end
end
