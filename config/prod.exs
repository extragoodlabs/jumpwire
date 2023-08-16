import Config

# Do not print debug messages in production
config :logger,
  level: :info,
  utc_log: true

config :logger, :console,
  metadata: [:request_id, :org_id, :policy, :manifest, :client]

config :sentry,
  enable_source_code_context: false

config :honeybadger, environment_name: :ignored

config :jumpwire, :acme,
  directory_url: "https://acme-v02.api.letsencrypt.org/directory"
