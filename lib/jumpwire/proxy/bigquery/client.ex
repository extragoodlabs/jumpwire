defmodule JumpWire.Proxy.BigQuery.Client do
  use Tesla
  require Logger

  plug Tesla.Middleware.Logger,
    filter_headers: ["authorization"]

  plug Tesla.Middleware.JSON

  def query(method, bq_url, body, headers) do
    encoded_body =
      cond do
        map_size(body) == 0 -> nil
        true -> Jason.encode!(body)
      end

    request(
      method: method,
      url: bq_url,
      query: [],
      headers: headers,
      body: encoded_body,
      # https://github.com/elixir-tesla/tesla/issues/394
      opts: [adapter: [protocols: [:http1]]]
    )
  end
end
