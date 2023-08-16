defmodule JumpWire.API.AuthorizationPlug do
  @moduledoc """
  Plug for authorizing a connection to API resources using permissions
  encoded into a token or session.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {_id, permissions} <- Guardian.Plug.current_claims(conn),
         permissions <- get_method_permissions(conn.method, permissions),
         :ok <- check_path_permissions(conn.path_info, permissions) do
      conn
    else
      _ -> failed_response(conn)
    end
  end

  defp get_method_permissions(method, permissions) when is_map(permissions) do
    Map.get(permissions, :all, [])
    ++ Map.get(permissions, "all", [])
    ++ Map.get(permissions, method, [])
  end
  defp get_method_permissions(_, _), do: []

  defp check_path_permissions(_, []), do: :error
  defp check_path_permissions(_, [:root | _]), do: :ok
  defp check_path_permissions([path | _], [path | _]), do: :ok
  defp check_path_permissions(path, [_ | rest]) do
    check_path_permissions(path, rest)
  end

  defp failed_response(conn) do
    Logger.warn("Unauthorized API call")
    body = %{message: "unauthorized"}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
    |> halt()
  end
end
