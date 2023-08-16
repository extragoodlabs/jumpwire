import Config

# Do not include timestamps in development logs, but show raw events
config :logger, :console, format: "[$level] $metadata$message\n",
  metadata: [:org_id, :module, :source, :record, :manifest, :client]

config :libcluster,
  debug: true,
  topologies: [
    jumpwire: [strategy: Elixir.Cluster.Strategy.LocalEpmd],
  ]

config :jumpwire, JumpWire.Proxy.Postgres,
  port: 6543,
  pool_size: 2
config :jumpwire, JumpWire.Proxy.MySQL,
  port: 3307,
  pool_size: 2

config :git_hooks,
  auto_install: true,
  verbose: true

config :jumpwire, :upstream,
  ssl_verify: :verify_none,
  reconnect_interval: 1_000

config :jumpwire, JumpWire.Proxy.Storage.File, enabled: true

# Set to `true` to enable pebble for local
# letsencrypt/ACME cert issuance debugging
config :jumpwire, :pebble, server: true
config :jumpwire, :acme,
  hostname: "localhost",
  directory_url: "https://localhost:14000/dir",
  generate: true,
  email: "noreply@jumpwire.io"

config :sentry,
  enable_source_code_context: true,
  root_source_code_path: File.cwd!()

config :versioce,
  post_hooks: [
    Versioce.PostHooks.Git.Add,
    Versioce.PostHooks.Git.Commit,
    Versioce.PostHooks.Git.Tag,
  ]

config :versioce, :git,
  commit_message_template: "Bump version to v{version}",
  tag_template: "{version}",
  tag_message_template: "Release v{version}"

secrets_path = Path.expand("#{config_env()}.secrets.exs", __DIR__)
if File.exists?(secrets_path) do
  import_config secrets_path
end
