defmodule JumpWire.Analytics do
  @moduledoc """
  Capture and report anonymized information about product usage.
  """

  require Logger

  def capture(event, properties) do
    opts = Application.get_env(:jumpwire, __MODULE__)

    if opts[:enabled] do
      Task.Supervisor.async_nolink(JumpWire.AnalyticsSupervisor, fn -> capture(event, properties, opts) end)
    end
  end

  defp capture(event, properties, opts) do
    node_info =
      case JumpWire.node_info() do
        {:ok, info} -> info
        _ -> %{}
      end

    version = Map.get(node_info, :version, "unknown")
    user_agent = "jumpwire-#{version}"
    id = JumpWire.Metadata.get_node_id()

    cpu =
      case :erlang.system_info(:logical_processors) do
        :uknown -> 0
        count -> count
      end

    node_properties = %{
      "version" => version,
      "arch" => :erlang.system_info(:system_architecture) |> to_string(),
      "cpu_count" => cpu,
    }

    client = Tesla.client([
      Tesla.Middleware.JSON,
      Tesla.Middleware.FollowRedirects,
      {Tesla.Middleware.Headers, [{"user-agent", user_agent}]},
      {Tesla.Middleware.BaseUrl, opts[:api_url]},
      {Tesla.Middleware.Timeout, timeout: opts[:timeout]},
      {Tesla.Middleware.Retry, [
          delay: 500,
          should_retry: fn
            {:ok, %{status: 200}} -> false
            _ -> true
          end
        ]
      },
    ])

    body = %{
      "api_key" => opts[:api_key],
      "distinct_id" => id,
      "event" => event,
      "properties" => properties,
      "$set" => node_properties,
    }

    case Tesla.post(client, "/capture", body) do
      {:ok, %{status: 200}} -> Logger.debug("Sent '#{event}' event")
      err -> Logger.debug("Failed to report '#{event}' event: #{inspect err}")
    end
  end

  @doc """
  Report that the system has successfully loaded its configuration.
  """
  def config_loaded(_org_id, data) do
    client_count = Map.get(data, :client_auth, []) |> Enum.count()
    group_count = Map.get(data, :groups, []) |> Enum.count()
    manifests = Map.get(data, :manifests, [])
    pg_count = manifests |> Stream.filter(fn m -> m.root_type == :postgresql end) |> Enum.count()
    mysql_count = manifests |> Stream.filter(fn m -> m.root_type == :mysql end) |> Enum.count()
    metastore_count = Map.get(data, :metastores, []) |> Enum.count()
    policy_count = Map.get(data, :policies, []) |> Enum.count()
    schemas = Map.get(data, :proxy_schemas, [])
    schema_count = Enum.count(schemas)
    label_count = schemas
    |> Stream.map(fn s -> s.fields end)
    |> Stream.flat_map(fn f -> Map.values(f) end)
    |> Stream.uniq()
    |> Enum.count()

    properties = %{
      "clients" => client_count,
      "groups" => group_count,
      "postgresql_manifests" => pg_count,
      "mysql_manifests" => mysql_count,
      "metastores" => metastore_count,
      "policies" => policy_count,
      "schemas" => schema_count,
      "labels" => label_count,
    }
    capture("loaded", properties)
  end

  @doc """
  Report that a client has connected and authenticated to the proxy.
  """
  def proxy_authenticated(_org_id, db_type) do
    properties = %{"database" => to_string(db_type)}
    capture("client.authenticated", properties)
  end
end
