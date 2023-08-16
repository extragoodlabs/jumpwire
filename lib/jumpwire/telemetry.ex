defmodule JumpWire.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    opts = Application.get_env(:jumpwire, :telemetry)

    # NB: cloudwatch doesn't support distributions and prometheus doesn't support
    # summary. CloudWatch will safely ignore the distributions, but prometheus will
    # blow up if passed a summary.

    cloudwatch =
      with {true, opts} <- Keyword.pop(opts[:cloudwatch], :enabled),
           {:ok, _} <- ExAws.Auth.validate_config(ExAws.Config.new(:monitoring, [])) do
        [{TelemetryMetricsCloudwatch, [{:metrics, base_metrics() ++ summaries()} | opts]}]
      else
        _ -> []
      end

    prom_config = Application.get_all_env(:telemetry_metrics_prometheus)

    children = [
      {
        :telemetry_poller,
        measurements: measurements(),
        period: :timer.seconds(30),
        name: JumpWire.Telemetry.Measurements
      },
      {
        :telemetry_poller,
        measurements: slow_measurements(),
        period: :timer.hours(1),
        name: JumpWire.Telemetry.SlowMeasurements
      },
      {TelemetryMetricsPrometheus, [{:metrics, base_metrics() ++ distributions()} | prom_config]},
      {TelemetryMetricsStatsd, [{:metrics, metrics()} | opts[:statsd]]},
      # Uncomment for local metrics debugging
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()},
    ] ++ cloudwatch
    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics() do
    base_metrics() ++ distributions() ++ summaries()
  end

  def proxy_metrics() do
    [
      counter("database.access.count",
        description: "number of times a labeled field has been accessed",
        tags: [:session, :client, :database, :organization, :label]
      ),
    ]
  end

  def base_metrics() do
    [
      # VM Metrics
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      last_value("policy.handling.total",
        description: "number of policies configured for each data handling action",
        tags: [:handling, :organization]
      ),

      # Proxy metrics
      last_value("database.total",
        description: "number of databases proxied through this node",
        tags: [:organization]
      ),
      sum("database.connection.total",
        description: "number of active database connections from a client",
        tags: [:database, :client, :organization]
      ),
      last_value("database.encryption.percent",
        description: "percentage of rows for a given field that are encrypted",
        tags: [:database, :table, :field, :organization]
      ),
      last_value("database.tokenization.percent",
        description: "percentage of rows for a given field that are tokenized",
        tags: [:database, :table, :field, :organization]
      ),
      last_value("database.decryption.percent",
        description: "percentage of rows for a given field that are decrypted",
        tags: [:database, :table, :field, :organization]
      ),
      last_value("database.detokenization.percent",
        description: "percentage of rows for a given field that are detokenized",
        tags: [:database, :table, :field, :organization]
      ),
    ] ++ proxy_metrics()
  end

  def distributions() do
    [
      distribution("policy.database.client.duration",
        policy_duration_opts() ++
          [reporter_options: [buckets: [10, 100, 500, 1000, 10_000, 60_000]]]
      ),
      distribution("database.client.duration",
        database_duration_opts() ++
          [reporter_options: [buckets: [10, 100, 500, 1000, 10_000, 60_000]]]
      ),
    ]
  end

  def summaries() do
    [
      summary("policy.database.client.duration", policy_duration_opts()),
      summary("database.client.duration", database_duration_opts()),
    ]
  end

  def measurements() do
    [
      {JumpWire.Proxy, :measure_proxies, []},
    ]
  end

  def slow_measurements() do
    [
      {JumpWire.Proxy, :measure_databases, []},
    ]
  end

  defp policy_duration_opts() do
    [description: "duration of a given policy in milliseconds",
     tags: [:policy, :database, :client, :organization],
     unit: {:microsecond, :millisecond}]
  end

  defp database_duration_opts() do
    [description: "duration of a database query in milliseconds",
     tags: [:database, :client, :organization],
     unit: {:microsecond, :millisecond}]
  end
end
