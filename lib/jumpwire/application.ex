defmodule JumpWire.Application do
  @moduledoc """
  Startup module for JumpWire.

  Before starting the supervision tree, an HTTP request is made to the upstream controller. The response
  may contain encryption keys, feature flags, shared secrets, etc. If this connection fails and the JWT claims
  do not allow for directly managing encryption keys (through the flag `managed_keys`),
  JumpWire will have no keys in its keyring and will not generate any new ones.
  """

  use Application
  require Logger
  use JumpWire.Retry

  @fuse_name __MODULE__
  @fuse_opts [
    fuse_strategy: {:standard, 5, 1_000},
    fuse_refresh: 5_000,
    rate_limit: {10, 1_000}
  ]
  @retry_opts %ExternalService.RetryOptions{
    backoff: {:exponential, 500},
    cap: 10_000,
  }

  def org_from_token(nil), do: nil
  def org_from_token(token) do
    case JumpWire.token_claims(token) do
      {:ok, %{org: org_id}} -> org_id
      _ -> nil
    end
  end

  defp fetch_keyword(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} -> {:error, :not_found}
      :error -> {:error, :not_found}
      res -> res
    end
  end

  def fetch_secrets(opts, org_id) do
    with {:ok, ws_url} <- fetch_keyword(opts, :url),
         {:ok, token} <- fetch_keyword(opts, :token),
         {:ok, uri} <- URI.new(ws_url) do
      fetch_secrets(uri, token, org_id)
    end
  end

  @spec fetch_secrets(URI.t, String.t, String.t) :: :ok | Tesla.Env.result()
  def fetch_secrets(uri, token, org_id) do
    scheme =
      case uri.scheme do
        "ws" -> "http"
        "http" -> "http"
        _ -> "https"
      end
    url = %{uri | scheme: scheme, path: "/api/configuration/engine"}
    |> URI.to_string()

    client = Tesla.client([
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers, [{"Authorization", "Bearer: #{token}"}]}
    ])

    with {:ok, %{status: 200, body: resp}} <- Tesla.get(client, url) do
      case Map.get(resp, "jumpwire_encryption_keys") do
        false ->
          Logger.debug("Not using controller encryption keys")
          JumpWire.Vault.set_controller_management(false)

        keys when is_map(keys) ->
          Logger.debug("Fetched encryption keys from controller: #{inspect Map.keys(keys)}")
          JumpWire.Vault.set_controller_management(true)
          JumpWire.Vault.store_keys(keys, org_id)

        _ ->
          Logger.warn("Missing encryption keys from controller")
      end

      signing_key = Map.get(resp, "jumpwire_token_signing_key")
      JumpWire.update_env(:proxy, :secret_key, signing_key)
    end
  end

  @impl true
  def start(_type, _args) do
    # Register default ports for websocket schemes, used when parsing
    # a string into a URI structure.
    URI.default_port("ws", 80)
    URI.default_port("wss", 443)

    upstream = Application.get_env(:jumpwire, :upstream)
    org_id =
      case org_from_token(upstream[:token]) do
        nil -> JumpWire.Metadata.get_org_id()

        org_id ->
          Logger.debug("Setting org_id to #{org_id}")
          JumpWire.Metadata.set_org_id(org_id)
          org_id
      end

    version = Application.spec(:jumpwire, :vsn) |> to_string()
    Application.put_env(:honeybadger, :git, version)

    ExternalService.start(@fuse_name, @fuse_opts)
    ExternalService.call!(@fuse_name, @retry_opts, fn ->
      # Fetch secrets from the controller. Network errors and server error codes will be retried.
      case fetch_secrets(upstream, org_id) do
        {:error, :not_found} -> :ok

        {:error, reason} ->
          Logger.error("Network error trying fetch secrets, will retry: #{inspect reason}")
          {:retry, reason}

        {:ok, %{status: code}} when code >= 500 or code == 429 ->
          reason = Plug.Conn.Status.reason_atom(code)
          Logger.error("Error fetching secrets, will retry: #{inspect reason}")
          {:retry, reason}

        {:ok, %{status: code}} ->
          reason = Plug.Conn.Status.reason_atom(code)
          Logger.error("Failed to fetch secrets: #{inspect reason}")
          {:error, reason}

        :ok ->
          Logger.info("Fetched secrets from the web controller")
          :ok
      end
    end)

    user_msgs =
      case JumpWire.validate_config() do
        {:error, error} ->
          # Change the level to limit to log output when intentionally exiting
          Logger.configure(level: :error)
          Logger.error("Invalid configuration: #{error} is misconfigured")
          exit({:shutdown, 1})

        {:ok, info} -> info
      end

    topologies =
      case Node.self() do
        :nonode@nohost -> []
        _ -> Application.get_env(:libcluster, :topologies)
      end

    pg_proxy_opts = Application.get_env(:jumpwire, JumpWire.Proxy.Postgres)
    |> Keyword.delete(:pool_size)

    mysql_proxy_opts = Application.get_env(:jumpwire, JumpWire.Proxy.MySQL)
    |> Keyword.delete(:pool_size)

    proxy_args = %{org_id: org_id}

    children = [
      {Task.Supervisor, name: JumpWire.ProxySupervisor},
      {Task.Supervisor, name: JumpWire.DatabaseConnectionSupervisor},
      {Task.Supervisor, name: JumpWire.ACMESupervisor},

      {Phoenix.PubSub, name: JumpWire.PubSub.server()},
      JumpWire.LocalConfig,
      JumpWire.GlobalConfig,
      {JumpWire.StartupIndicator, {org_id, user_msgs}},

      JumpWire.Cloak.Supervisor,
      JumpWire.Telemetry,

      JumpWire.Router.Supervisor,
      {JumpWire.Proxy.Postgres, {pg_proxy_opts, proxy_args}},
      {JumpWire.Proxy.MySQL, {mysql_proxy_opts, proxy_args}},

      {Cluster.Supervisor, [topologies, [name: JumpWire.ClusterSupervisor]]},

      # Local ACME server
      JumpWire.ACME.Pebble,
    ]

    opts = [strategy: :one_for_one, name: JumpWire.Application]
    Supervisor.start_link(children, opts)
  end
end
