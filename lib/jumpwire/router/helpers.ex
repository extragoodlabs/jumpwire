defmodule JumpWire.Router.Helpers do
  @moduledoc """
  Functions shared across routing/Plug modules.
  """

  def put_secret_key_base(conn, _) do
    secret_key = Application.fetch_env!(:jumpwire, :signing_token)
    put_in(conn.secret_key_base, secret_key)
  end
end
