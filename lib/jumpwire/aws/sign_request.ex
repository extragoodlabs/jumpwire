defmodule JumpWire.AWS.SignRequest do
  @moduledoc """
  Tesla middleware to generate a signed header for AWS requests.

  Based on https://github.com/ryanbrainard/tesla_aws_sigv4 but with better ExAws config handling.
  """

  @behaviour Tesla.Middleware

  @impl true
  def call(env, next, opts) do
    service = Keyword.fetch!(opts, :service)
    config = ExAws.Config.new(service, Keyword.get(opts, :config, %{}))

    env
    |> sign_request(service, config)
    |> Tesla.run(next)
  end

  defp sign_request(env, service, config) do
    {:ok, headers} =
      ExAws.Auth.headers(
        env.method,
        env.url,
        service,
        config,
        env.headers,
        env.body || ""
      )

    %{env | headers: headers}
  end
end
