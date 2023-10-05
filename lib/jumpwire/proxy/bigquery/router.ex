defmodule JumpWire.Proxy.BigQuery.Router do
  @moduledoc """
  A Plug.Router for proxying queries to BigQuery and applying policies.
  """

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

  alias JumpWire.Proxy.BigQuery.Client

  match "/*path" do
    # Extract SQL, apply policies on query, stop in case of error/block.
    with sql <- extract_sql(conn),
         {:ok, policy_sql} <- apply_policies(sql),
         request_body <- replace_sql(conn, policy_sql),
         {:ok, response} <- Client.query(conn.method, bq_url(conn), request_body, bq_headers(conn)) do
      send_resp(conn, response.status, Jason.encode!(response.body))
    else
      {:error, :blocked} ->
        Logger.info("BigQuery request blocked by policy")
        send_resp(conn, 401, "not authorized")
      err ->
        Logger.error("Unexpected BigQuery error: #{inspect(err)}")
        send_resp(conn, 500, "error")
    end
  end

  defp extract_sql(%{body_params: body}) do
    case body do
      %{"configuration" => %{"query" => %{"query" => query}}} when is_binary(query) -> query
      _ -> nil
    end
  end

  defp replace_sql(%{body_params: original}, replacement) do
    case original do
      %{"configuration" => %{"query" => %{"query" => query}}} when is_binary(query) ->
        put_in(original, ["configuration", "query", "query"], replacement)

      _ ->
        original
    end
  end

  defp apply_policies(sql) do
    case sql do
      nil ->
        {:ok, nil}

      _ ->
        # TODO run request policies
        {:ok, sql}
    end
  end

  defp bq_url(%{path_params: %{"path" => path}}) do
    uri = Enum.join(path, "/")
    "https://bigquery.googleapis.com/#{uri}"
  end

  defp bq_headers(%{req_headers: headers}) do
    without_host =
      headers
      |> Stream.reject(fn {k, _} -> Enum.member?(["host", "content-length", "accept-encoding", "accept"], k) end)
      |> Enum.to_list()

    [{"host", "bigquery.googleapis.com"}, {"accept", "application/json"} | without_host]
  end
end
