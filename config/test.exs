import Config

config :logger,
  level: :error,
  backends: [:console],
  compile_time_purge_matching: [
    [module: TelemetryMetricsCloudwatch.Cache],
    [module: JumpWire.Proxy.Postgres.Manager],
    [module: JumpWire.Policy],
    [module: JumpWire.Proxy.Schema]
  ]

config :tesla, adapter: JumpWire.TeslaMock

config :jumpwire, JumpWire.Router,
  http: [port: 4003],
  https: [port: 4444]

config :jumpwire, JumpWire.Proxy.Postgres, port: 6544
config :jumpwire, JumpWire.Proxy.MySQL, port: 3308
config :jumpwire, JumpWire.Proxy.MySQLTest, port: 3306

config :ex_aws,
  access_key_id: "test",
  secret_access_key: "test"

config :jumpwire, :upstream, url: nil

config :jumpwire, :events, adapter: JumpWire.Events.Adapters.GenServer

config :jumpwire, JumpWire.Proxy.Storage.File, enabled: true

ca_file = Path.join(Path.dirname(__DIR__), "priv/cert/minica.pem")

config :jumpwire, :proxy,
  secret_key: "+bIY69N+xMkWicPflECOSTPPznB3GtIv/OF8so52ZUg=",
  ssl: [verify: :verify_peer, cacertfile: ca_file],
  client_ssl: [verify: :verify_peer, cacertfile: ca_file]

config :jumpwire, signing_token: "v+6ICodXeSGjqEQUMpjWuOJNpBWOfXuuk/ogKCvRtbU="

config :jumpwire, JumpWire.Cloak.KeyRing,
  master_key: "9XzcAgOCLNf46trUABvzAnbJM970klxKb7U8PAwP8gg=",
  default_org: "org_jumpwire_test",
  managed_keys: false

config :jumpwire, :metadata, org_id: "org_jumpwire_test"

config :jumpwire, :pebble, server: true

config :jumpwire, :acme,
  directory_url: "https://localhost:14000/dir",
  hostname: "jumpwire.local",
  email: "noreply@jumpwire.io"

config :hydrax, JumpWire.Cloak.Storage.DeltaCrdt.DiskStorage, filename: 'jumpwire_test_keys'

config :bcrypt_elixir, :log_rounds, 4

config :telemetry_metrics_prometheus, port: 9569

config :mox, :verify_on_exit, true

# Use localstack for KMS calls by default. This may be updated by
# running tests.
config :ex_aws, :kms,
  scheme: "http",
  host: "localhost",
  port: 4566

config :jumpwire, :sso, module: JumpWire.SSO.MockImpl
