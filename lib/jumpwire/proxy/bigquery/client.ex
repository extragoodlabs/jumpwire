defmodule JumpWire.Proxy.BigQuery.Client do
  @moduledoc """
  Client for wrapping proxied requests to BigQuery
  """

  use Tesla
  require Logger

  plug Tesla.Middleware.Logger,
    filter_headers: ["authorization"]

  plug Tesla.Middleware.JSON
  plug Tesla.Middleware.Compression

  def query(method, bq_url, body, headers) do
    encoded_body =
      if map_size(body) == 0 do
        nil
      else
        Jason.encode!(body)
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
