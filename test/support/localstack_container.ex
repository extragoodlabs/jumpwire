defmodule JumpWire.LocalstackContainer do
  @moduledoc """
  Functions to build and interact with Localstack containers.

  https://localstack.cloud/
  """

  alias Excontainers.Container
  use ExUnit.CaseTemplate

  @edge_port 4566
  @version "2.0"

  def new() do
    Docker.Container.new(
      "localstack/localstack:#{@version}",
      environment: %{
        "AWS_DEFAULT_REGION" => "us-east-2",
        "DISABLE_EVENTS" => "1",
        "EDGE_PORT" => "#{@edge_port}",
        "EAGER_SERVICE_LOADING" => "1",
        "SERVICES" => "kms",
      },
      exposed_ports: [@edge_port],
      wait_strategy: Docker.CommandWaitStrategy.new(["bash", "-c", "curl -s -f http://127.0.0.1:#{@edge_port}/health | grep '\"kms\": \"running\"'"])
    )
  end

  def port(pid), do: Container.mapped_port(pid, @edge_port)
  def services(pid) do
    Container.config(pid)
    |> Map.get(:environment)
    |> Map.get("SERVICES")
    |> String.split(",")
    |> Enum.map(&String.to_existing_atom/1)
  end

  using do
    quote do
      import Excontainers.ExUnit

      shared_container(:localstack, JumpWire.LocalstackContainer.new())

      setup_all %{localstack: pid} do
        port = JumpWire.LocalstackContainer.port(pid)

        Enum.each([:kms], fn service ->
          config = Application.get_env(:ex_aws, service)
          |> Keyword.put(:port, port)

          Application.put_env(:ex_aws, :kms, config)
        end)

        :ok
      end
    end
  end
end
