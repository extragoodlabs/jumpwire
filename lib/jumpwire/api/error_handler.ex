defmodule JumpWire.API.ErrorHandler do
  @moduledoc """
  Error handler used when Guardian is unable to authenticate the connection.
  """

  import Plug.Conn
  require Logger

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, error = {_, reason}, _opts) do
    Logger.warn("API authentication error: #{inspect error}")

    body = %{message: to_string(reason)}
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
  end
end
