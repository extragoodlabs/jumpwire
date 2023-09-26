import Config

config :jumpwire, :environment, config_env()

config :jumpwire,
  ecto_repos: [],
  config_dir: "priv/config"

# Configures Elixir's Logger
config :logger,
  backends: [
    :console,
    Sentry.LoggerBackend,
    JumpWire.UiLog.Backend,
  ],
  compile_time_purge_matching: [[module: TelemetryMetricsCloudwatch.Caches]]
config :logger, :console,
  format: "$time [$level] $metadata$message\n",
  metadata: [:request_id, :org_id, :module, :source, :manifest, :client]
config :logger, JumpWire.UiLog.Backend,
  level: :warning

config :tesla, :adapter, Tesla.Adapter.Mint

config :libcluster, :topologies, []

config :jumpwire, JumpWire.Router,
  use_sni: true,
  https: [port: 4443],
  http: [port: 4004]

config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, {:awscli, "default", 30}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, {:awscli, "default", 30}, :instance_role]

config :jumpwire, :upstream,
  url: nil,
  ssl_verify: :verify_peer,
  params: []

config :jumpwire, :telemetry,
  statsd: [],
  cloudwatch: [enabled: false]

config :hydrax, :supervisor,
  children: [
    JumpWire.Websocket,
    JumpWire.ACME.Challenge,
    JumpWire.ACME.CertRenewal,
    # Using a child spec is required, anonymous functions will cause
    # an error when releasing
    %{id: Task, restart: :temporary, start: {Task, :start_link, [JumpWire.ACME, :ensure_cert, []]}},
  ]

config :jumpwire, :proxy,
  use_sni: true,
  secret_key: nil,
  client_ssl: [],
  server_ssl: [],
  parse_requests: true,
  parse_responses: true

config :jumpwire, JumpWire.Proxy.Postgres,
  keepalive: true,
  port: 5432,
  pool_size: 4
config :jumpwire, JumpWire.Proxy.MySQL,
  port: 3306,
  pool_size: 4

config :sentry,
  included_environments: [:staging, :prod],
  environment_name: config_env()

config :honeybadger,
  environment_name: config_env(),
  exclude_envs: [:dev, :test, :ignored],
  use_logger: true,
  sasl_logging_only: false

config :logger, Sentry.LoggerBackend,
  level: :warn,
  metadata: [:request_id, :module],
  capture_log_messages: true

config :jumpwire, JumpWire.Cloak.KeyRing,
  storage_adapters: [{JumpWire.Cloak.Storage.DeltaCrdt, true}],
  managed_keys: false

config :hydrax, JumpWire.Cloak.Storage.DeltaCrdt, storage_module: JumpWire.Cloak.Storage.DeltaCrdt.DiskStorage
config :hydrax, JumpWire.Cloak.Storage.DeltaCrdt.DiskStorage, filename: 'jumpwire_keys'

config :telemetry_metrics_prometheus, port: 9568

config :jumpwire, :metadata,
  org_id: "org_generic",
  node_id: nil

config :samly, Samly.State, store: JumpWire.SSO.SamlyState
config :samly, Samly.Provider, idp_id_from: :path_segment

config :jumpwire, :pebble,
  path: "priv/pebble",
  config: "config.json"

config :jumpwire, :acme,
  generate: false,
  key_size: 4096,
  directory_url: "https://acme-staging-v02.api.letsencrypt.org/directory",
  # default to 30 days
  cert_renewal_seconds: 60 * 60 * 24 * 30,
  cert_delay_seconds: 0,
  cert_dir: "priv/pki",
  hostname: nil,
  email: nil

config :jumpwire, JumpWire.Analytics,
  enabled: false,
  api_url: "https://events.jumpwire.io",
  api_key: "phc_GxUkxISBf1whq6dhJ3Ucb7hlPh7OqExJm8qSQqxhhCE",
  timeout: 5_000

import_config "#{config_env()}.exs"
