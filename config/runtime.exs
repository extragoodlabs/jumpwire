import Config

with {:ok, token} <- System.fetch_env("JUMPWIRE_TOKEN") do
  config :jumpwire, :upstream, token: token
end

log_level = System.get_env("LOG_LEVEL", "") |> String.downcase()
if log_level in ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"] do
  config :logger, level: String.to_atom(log_level)
end


with {:ok, port} <- System.fetch_env("JUMPWIRE_HTTP_PORT") do
  config :jumpwire, JumpWire.Router,
    enable_http: true,
    http: [port: String.to_integer(port)]
end
with {:ok, port} <- System.fetch_env("JUMPWIRE_HTTPS_PORT") do
  config :jumpwire, JumpWire.Router, https: [port: String.to_integer(port)]
end

with {:ok, cert} <- System.fetch_env("JUMPWIRE_TLS_CERT"),
     {:ok, key} <- System.fetch_env("JUMPWIRE_TLS_KEY") do
  ssl_opts = [certfile: cert, keyfile: key]
  config :jumpwire, JumpWire.Router,
    enable_https: true,
    https: ssl_opts
  config :jumpwire, :proxy,
    enable_tls: true,
    server_ssl: ssl_opts
end

cacert = System.get_env("JUMPWIRE_TLS_CA", CAStore.file_path())
config :jumpwire, JumpWire.Router, https: [cacertfile: cacert]

proxy_cacert = System.get_env("JUMPWIRE_TLS_PROXY_CA", cacert)
if config_env() != :test do
  config :jumpwire, :proxy, client_ssl: [
    verify: :verify_peer,
    cacertfile: proxy_cacert,
  ]
end
config :tesla, Tesla.Adapter.Mint, cacert: cacert

# Configure cloud-specific automatic clustering
case System.get_env("JUMPWIRE_CLOUD") do
  "aws" ->
    config :jumpwire, :telemetry, cloudwatch: [enabled: true]
    config :libcluster, :topologies, [
      jumpwire: [
        strategy: Elixir.ClusterEC2.Strategy.Tags,
        config: [
          ec2_tagname: "application",
          ec2_tagvalue: "jumpwire",
          app_prefix: "jumpwire",
          ip_type: :private,
          polling_interval: 10_000
        ]
      ]
    ]
  "kubernetes" ->
    cluster = System.get_env("JUMPWIRE_CLUSTER", "default")
    config :libcluster, :topologies, [
      jumpwire: [
        strategy: Elixir.Cluster.Strategy.Kubernetes,
        config: [
          mode: :ip,
          kubernetes_node_basename: "jumpwire",
          kubernetes_selector: "jumpwire.io/cluster=#{cluster}",
          kubernetes_namespace: System.get_env("JUMPWIRE_K8S_NAMESPACE", "default")
        ]
      ]
    ]
  _ -> nil
end

case System.get_env("AWS_WEB_IDENTITY_TOKEN_FILE") do
  nil -> nil
  _ -> config :ex_aws, awscli_auth_adapter: ExAws.STS.AuthCache.AssumeRoleWebIdentityAdapter
end

with {:ok, region} <- System.fetch_env("AWS_REGION") do
  config :ex_aws, region: region
end

case System.get_env("JUMPWIRE_FRONTEND") do
  nil -> nil
  "ws://" <> host ->  config :jumpwire, :upstream, url: "ws://#{host}/cluster/websocket"
  "wss://" <> host ->  config :jumpwire, :upstream, url: "wss://#{host}/cluster/websocket"
  "false" -> config :jumpwire, :upstream, url: nil
  host ->
    # Assume TLS by default if the scheme is not passed as part of the host
    config :jumpwire, :upstream, url: "wss://#{host}/cluster/websocket"
end

# Parse the WS URL into an HTTP version
case Application.get_env(:jumpwire, :upstream)[:url] do
  nil -> nil
  url ->
    uri = URI.parse(url)
    scheme =
      case uri.scheme do
        "ws" -> "http"
        "http" -> "http"
        _ -> "https"
      end
    config :jumpwire, :upstream, http_uri: %{uri | scheme: scheme}
end

# Statsd configuration
case System.get_env("JUMPWIRE_STATSD_HOST") do
  nil -> nil
  host -> config :jumpwire, :telemetry, statsd: [host: host]
end
case System.get_env("JUMPWIRE_STATSD_PORT") do
  nil -> nil
  port -> config :jumpwire, :telemetry, statsd: [port: port]
end
case System.get_env("JUMPWIRE_STATSD_SOCKET") do
  nil -> nil
  socket -> config :jumpwire, :telemetry, statsd: [socket_path: socket]
end
case System.get_env("JUMPWIRE_STATSD_TYPE") do
  "datadog" -> config :jumpwire, :telemetry, statsd: [formatter: :datadog]
  _ -> nil
end
config :jumpwire, :telemetry,
  statsd: [prefix: System.get_env("JUMPWIRE_STATSD_PREFIX", "jumpwire")]

# CloudWatch configuration
config :jumpwire, :telemetry,
  cloudwatch: [
    namespace: System.get_env("JUMPWIRE_CLOUDWATCH_NAMESPACE", "jumpwire"),
  ]
case System.get_env("JUMPWIRE_CLOUDWATCH_INTERVAL_SECONDS", "") |> Integer.parse() do
  {interval, _} -> config :jumpwire, :telemetry, cloudwatch: [push_interval: interval * 1_000]
  _ -> nil
end
case System.get_env("JUMPWIRE_CLOUDWATCH_ENABLED") do
  "true" -> config :jumpwire, :telemetry, cloudwatch: [enabled: true]
  "false" -> config :jumpwire, :telemetry, cloudwatch: [enabled: false]
  _ -> nil
end

with {:ok, port} <- System.fetch_env("JUMPWIRE_PROMETHEUS_PORT"),
     {port, ""} <- Integer.parse(port) do
  config :telemetry_metrics_prometheus, port: port
end

with {:ok, key} <- System.fetch_env("JUMPWIRE_ENCRYPTION_KEY") do
  config :jumpwire, JumpWire.Cloak.KeyRing, master_key: key
end

# Disk persistence for keys
with {:ok, file} <- System.fetch_env("JUMPWIRE_ENCRYPTION_KEY_FILE") do
  config :hydrax, JumpWire.Cloak.Storage.DeltaCrdt.DiskStorage, filename: String.to_charlist(file)
end

with {:ok, domain} <- System.fetch_env("JUMPWIRE_DOMAIN") do
  config :jumpwire, :proxy, domain: domain
  config :jumpwire, :acme, hostname: domain
end

with {:ok, port} <- System.fetch_env("JUMPWIRE_POSTGRES_PROXY_PORT"),
     {port, ""} <- Integer.parse(port) do
  config :jumpwire, JumpWire.Proxy.Postgres, port: port
end

with {:ok, pool_size} <- System.fetch_env("JUMPWIRE_POSTGRES_PROXY_POOL_SIZE"),
     {pool_size, ""} <- Integer.parse(pool_size) do
  config :jumpwire, JumpWire.Proxy.Postgres, pool_size: pool_size
end

with {:ok, port} <- System.fetch_env("JUMPWIRE_MYSQL_PROXY_PORT"),
     {port, ""} <- Integer.parse(port) do
  config :jumpwire, JumpWire.Proxy.MySQL, port: port
end

with {:ok, pool_size} <- System.fetch_env("JUMPWIRE_MYSQL_PROXY_POOL_SIZE"),
     {pool_size, ""} <- Integer.parse(pool_size) do
  config :jumpwire, JumpWire.Proxy.MySQL, pool_size: pool_size
end

# Vault configuration. This will not matter unless valid authentication is also supplied.
case System.fetch_env("VAULT_KV_VERSION") do
  {:ok, "1"} -> config :jumpwire, :libvault, engine: Vault.Engine.KVV1
  _ -> config :jumpwire, :libvault, engine: Vault.Engine.KVV2
end
with {:ok, _} <- System.fetch_env("VAULT_SKIP_VERIFY") do
  config :jumpwire, :libvault,
    http_options: [
      adapter: {Tesla.Adapter.Mint, [transport_opts: [verify: :verify_none]]}
    ]
end
with {:ok, cacert} <- System.fetch_env("VAULT_CACERT") do
  config :jumpwire, :libvault,
    http_options: [
      adapter: {Tesla.Adapter.Mint, [transport_opts: [cacertfile: cacert]]}
    ]
end

config :jumpwire, :libvault,
  kv_path: System.get_env("VAULT_KV_PATH", "secret/jumpwire"),
  db_path: System.get_env("VAULT_DB_PATH", "database"),
  host: System.get_env("VAULT_ADDR", "https://localhost:8200")

with {:ok, namespace} <- System.fetch_env("VAULT_NAMESPACE") do
  # Set the namespace as an HTTP header on all Vault operations
  config :jumpwire, :libvault,
    http_options: [
      middleware: [
        Tesla.Middleware.FollowRedirects,  # set by default when there is no middleware configured
        {Tesla.Middleware.Headers, [{"X-Vault-Namespace", namespace}]},
      ]
    ]
end

enable_vault = fn ->
  config :jumpwire, JumpWire.Cloak.KeyRing,
    storage_adapters: [{JumpWire.Cloak.Storage.Vault, true}]
  # Disable disk storage for cloak CRDT when vault is enabled. Keys are encrypted in the disk
  # file, and they will attempt to be loaded without the master key to decrypt them.
  config :hydrax, JumpWire.Cloak.Storage.DeltaCrdt, storage_module: nil

  config :jumpwire, JumpWire.Proxy.Storage.Vault, enabled: true
end

# Various Vault authentication methods. The last valid one takes precedence.
with {:ok, role_id} <- System.fetch_env("VAULT_APPROLE_ID"),
     {:ok, secret_id} <- System.fetch_env("VAULT_APPROLE_SECRET") do
  enable_vault.()
  config :jumpwire, :libvault,
    auth: Vault.Auth.Approle,
    credentials: %{role_id: role_id, secret_id: secret_id}
end
with {:ok, token} <- System.fetch_env("VAULT_TOKEN") do
  enable_vault.()
  config :jumpwire, :libvault,
    auth: Vault.Auth.Token,
    credentials: %{token: token}
end

# AWS KMS settings
config :jumpwire, JumpWire.Cloak.KeyRing, storage_adapters: [
  {JumpWire.Cloak.Storage.AWS.KMS, System.get_env("JUMPWIRE_AWS_KMS_ENABLE")}
]
config :jumpwire, JumpWire.Cloak.Storage.AWS.KMS,
  key_name: System.get_env("JUMPWIRE_AWS_KMS_KEY_NAME", "jumpwire")

# Error reporting tools
with {:ok, key} <- System.fetch_env("HONEYBADGER_API_KEY") do
  config :honeybadger,
    api_key: key,
    environment_name: :prod  # override the "ignored" environment
end
with {:ok, env} <- System.fetch_env("JUMPWIRE_ENV") do
  name = String.to_existing_atom(env)
  config :sentry, environment_name: name
  config :honeybadger, environment_name: name
end
with {:ok, dsn} <- System.fetch_env("SENTRY_DSN"), do: config :sentry, dsn: dsn

with {:ok, path} <- System.fetch_env("JUMPWIRE_CONFIG_PATH") do
  config :jumpwire, config_dir: path
end

case System.fetch_env("JUMPWIRE_PARSE_REQUESTS") do
  {:ok, "true"} -> config :jumpwire, :proxy, parse_requests: true
  {:ok, "false"} -> config :jumpwire, :proxy, parse_requests: false
  {:ok, "1"} -> config :jumpwire, :proxy, parse_requests: true
  {:ok, "0"} -> config :jumpwire, :proxy, parse_requests: false
  _ -> nil
end

case System.fetch_env("JUMPWIRE_PARSE_RESPONSES") do
  {:ok, "true"} -> config :jumpwire, :proxy, parse_responses: true
  {:ok, "false"} -> config :jumpwire, :proxy, parse_responses: false
  {:ok, "1"} -> config :jumpwire, :proxy, parse_responses: true
  {:ok, "0"} -> config :jumpwire, :proxy, parse_responses: false
  _ -> nil
end

with {:ok, cert_dir} <- System.fetch_env("ACME_CERT_DIRECTORY") do
  config :jumpwire, :acme, cert_dir: cert_dir
end

case System.fetch_env("ACME_GENERATE_CERT") do
  {:ok, "true"} -> config :jumpwire, :acme, generate: true
  {:ok, "false"} -> config :jumpwire, :acme, generate: false
  {:ok, "1"} -> config :jumpwire, :acme, generate: true
  {:ok, "0"} -> config :jumpwire, :acme, generate: false
  _ -> nil
end

with {:ok, email} <- System.fetch_env("ACME_EMAIL") do
  config :jumpwire, :acme, email: email
end

with {:ok, token} <- System.fetch_env("JUMPWIRE_ROOT_TOKEN") do
  config :jumpwire, signing_token: token
end

with {:ok, path} <- System.fetch_env("JUMPWIRE_SSO_METADATA_PATH"),
     {:ok, idp_id} <- System.fetch_env("JUMPWIRE_SSO_IDP") do
  sp_id = System.get_env("JUMPWIRE_SSO_SPID", "jumpwire")
  signed_envelopes =
    case System.fetch_env("JUMPWIRE_SSO_SIGNED_ENVELOPES") do
      {:ok, "true"} -> true
      {:ok, "false"} -> false
      {:ok, "1"} -> true
      {:ok, "0"} -> false
      _ -> true
    end

  generated_name = System.get_env("JUMPWIRE_SSO_GENERATED_CERTNAME", "localhost")

  config :jumpwire, :sso,
    group_attribute: System.get_env("JUMPWIRE_SSO_GROUPS_ATTRIBUTE", "Group")

  config :samly, Samly.Provider,
    service_providers: [
      %{
        id: sp_id,
        entity_id: "urn:jumpwire.io:jumpwire",
        generated_cert: generated_name,
        certfile: System.get_env("JUMPWIRE_TLS_CERT", ""),
        keyfile: System.get_env("JUMPWIRE_TLS_KEY", ""),
        org_name: "JumpWire",
        org_displayname: "JumpWire",
        org_url: "https://jumpwire.io",
        contact_name: "JumpWire Admin",
        contact_email: "noreply@jumpwire.io",
      }
    ],
    identity_providers: [
      %{
        id: idp_id,
        sp_id: sp_id,
        base_url: "/sso",
        metadata_file: path,
        sign_requests: true,
        sign_metadata: true,
        allow_idp_initiated_flow: true,
        signed_assertion_in_resp: true,
        signed_envelopes_in_resp: signed_envelopes,
        pre_session_create_pipeline: JumpWire.SSO.SamlyPipeline,
      }
    ]
end
