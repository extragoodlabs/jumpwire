defmodule JumpWire.Token.VerifyToken do
  import Plug.Conn
  @behaviour Plug

  @impl Plug
  def init(opts \\ []) do
    [param_name: "token"]
    |> Keyword.merge(opts)
  end

  @impl Plug
  def call(conn, opts) do
    with {:ok, token} <- fetch_token_from_params(conn, opts),
         {:ok, decode64_token} <- Base.decode64(token) do
      conn
      |> assign(:decode64_token, decode64_token)
      |> assign(:param_token, token)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(:bad_request, Jason.encode!(%{"msg" => "Token is missing or incorrectly encoded"}))
        |> halt()
    end
  end

  @spec fetch_token_from_params(Plug.Conn.t(), Keyword.t()) :: :no_token_found | {:ok, String.t()}
  def fetch_token_from_params(conn, opts) do
    param_name = opts[:param_name]

    case Map.get(conn.query_params, param_name) do
      nil -> :no_token_found
      token -> {:ok, String.trim(token)}
    end
  end
end
