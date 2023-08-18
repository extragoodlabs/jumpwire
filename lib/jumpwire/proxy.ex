defmodule JumpWire.Proxy do
  alias JumpWire.Manifest
  require Logger

  @token_max_age 86_400 * 3650

  @doc """
  Create a signed token used for authenticating a proxy client.
  """
  @type signing_opts() :: [ttl: integer()]
  @spec sign_token(String.t(), String.t(), opts :: signing_opts()) :: String.t()
  def sign_token(org_id, client_id, opts \\ []) do
    Application.get_env(:jumpwire, :proxy, [])
    |> Keyword.get(:secret_key)
    |> sign_token(org_id, client_id, opts)
  end

  @spec sign_token(String.t(), String.t(), String.t(), signing_opts()) :: String.t()
  def sign_token(secret, org_id, client_id, opts) do
    ttl = Keyword.get(opts, :ttl) || @token_max_age
    Plug.Crypto.sign(secret, "manifest", {org_id, client_id}, max_age: ttl)
  end

  @doc """
  Checks a token used for authentication. If the token is valid, the manifest ID will be returned.
  """
  @spec verify_token(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, atom}
  def verify_token(token) do
    Application.get_env(:jumpwire, :proxy, [])
    |> Keyword.get(:secret_key)
    |> verify_token(token)
  end

  @spec verify_token(String.t, String.t) :: {:ok, {String.t(), String.t()}} | {:error, atom}
  def verify_token(secret, token) do
    Plug.Crypto.verify(secret, "manifest", token)
  end

  @doc """
  List the ports that JumpWire listens on for connections.
  """
  def ports() do
    pg_proxy_opts = Application.get_env(:jumpwire, JumpWire.Proxy.Postgres)
    mysql_proxy_opts = Application.get_env(:jumpwire, JumpWire.Proxy.MySQL)
    api_opts = Application.get_env(:jumpwire, JumpWire.Router)

    %{
      postgres: pg_proxy_opts[:port],
      mysql: mysql_proxy_opts[:port],
      http: api_opts[:http][:port],
      https: api_opts[:https][:port]
    }
  end

  @doc """
  Return the external domain used to proxy traffic.
  """
  def domain() do
    Application.get_env(:jumpwire, :proxy) |> Keyword.get(:domain)
  end

  def measure_proxies() do
    JumpWire.GlobalConfig.get(:manifests)
    |> Stream.filter(fn %{root_type: type} -> type == :postgresql or type == :mysql end)
    |> Enum.group_by(fn m -> m.organization_id end)
    |> Enum.each(fn {id, manifests} ->
      count = Enum.count(manifests)
      :telemetry.execute([:database], %{total: count}, %{node: node(), organization: id})
    end)

    JumpWire.GlobalConfig.get(:policies)
    |> Enum.group_by(fn p -> {p.organization_id, p.handling} end)
    |> Enum.each(fn {{organization_id, handling}, policies} ->
      count = Enum.count(policies)

      :telemetry.execute([:policy, :handling], %{total: count}, %{
        node: node(),
        handling: handling,
        organization: organization_id
      })
    end)

    JumpWire.Telemetry.Reporter.export_proxy_metrics()
  end

  def measure_databases() do
    JumpWire.GlobalConfig.get(:manifests)
    |> Stream.filter(fn %{root_type: type} -> type == :postgresql or type == :mysql end)
    |> Enum.each(&measure_database/1)
  end

  def measure_database(manifest = %Manifest{root_type: :postgresql}) do
    JumpWire.Proxy.Schema.list_all(manifest.organization_id, manifest.id)
    |> Enum.each(fn schema ->
      JumpWire.Proxy.Postgres.Setup.table_stats(manifest, schema)
      |> record_table_stats(manifest, schema)
    end)
  end

  def measure_database(manifest = %Manifest{root_type: :mysql}) do
    JumpWire.Proxy.Schema.list_all(manifest.organization_id, manifest.id)
    |> Enum.each(fn schema ->
      JumpWire.Proxy.MySQL.Setup.table_stats(manifest, schema)
      |> record_table_stats(manifest, schema)
    end)
  end

  def measure_database(%Manifest{id: id, root_type: type}) do
    Logger.warn("Attempting to measure manifest #{id} of unknown type #{type}")
    nil
  end

  @doc """
  Check whether all data in fields marked for encryption is actually encrypted/tokenized.
  """
  def schema_migrated?(stats) do
    case stats[:rows] do
      %{count: total, target: _} when is_number(total) and total > 0 ->
        encrypted = Enum.all?(stats[:encrypted], fn {_, %{count: count, target: target}} -> count == target end)
        tokenized = Enum.all?(stats[:tokenized], fn {_, %{count: count, target: target}} -> count == target end)
        encrypted and tokenized

      %{count: total, target: _} when is_number(total) and total == 0 ->
        true

      _ ->
        false
    end
  end

  def record_table_stats(stats, manifest, schema) do
    case stats[:rows] do
      %{count: :unknown, target: _} ->
        nil

      %{count: total, target: _} ->
        labels = %{
          database: manifest.id,
          table: schema.name,
          organization: manifest.organization_id
        }

        encryption_stats =
          stats
          |> Keyword.get(:encrypted, [])
          |> Stream.reject(fn {_, %{count: count, target: _}} -> count == :unknown end)
          |> Stream.map(fn {field, %{count: count, target: target}} ->
            percent = if total == 0, do: 1.0, else: count / total
            :telemetry.execute([:database, :encryption], %{percent: percent}, Map.put(labels, :field, field))

            {field, %{count: count, target: target, percent: percent}}
          end)
          |> Map.new()

        tokenization_stats =
          stats
          |> Keyword.get(:tokenized, [])
          |> Stream.reject(fn {_, count} -> count == :unknown end)
          |> Stream.map(fn {field, %{count: count, target: target}} ->
            percent = if total == 0, do: 1.0, else: count / total
            :telemetry.execute([:database, :tokenization], %{percent: percent}, Map.put(labels, :field, field))

            {field, %{count: count, target: target, percent: percent}}
          end)
          |> Map.new()

        msg = %{
          manifest: manifest.id,
          schema: schema.id,
          encrypted_fields: encryption_stats,
          tokenized_fields: tokenization_stats,
          organization_id: manifest.organization_id
        }

        JumpWire.Websocket.push("stats:database", msg)
    end
  end

  def connect(manifest = %Manifest{root_type: :postgresql}) do
    JumpWire.Proxy.Postgres.Setup.get_conn(manifest)
  end
  def connect(manifest = %Manifest{root_type: :mysql}) do
    JumpWire.Proxy.MySQL.Setup.get_conn(manifest)
  end

  def fetch_secrets_module() do
    cond do
      JumpWire.Proxy.Storage.Vault.enabled?() ->
        {:ok, JumpWire.Proxy.Storage.Vault}

      JumpWire.Proxy.Storage.File.enabled?() ->
        {:ok, JumpWire.Proxy.Storage.File}

      true ->
        nil
    end
  end

  @doc """
  Return a list of all possible actions when parsing DB requests.
  """
  def db_actions(), do: ["select", "insert", "update", "delete"]

  def list_labels(org_id) do
    JumpWire.Proxy.Schema.list_all(org_id)
    |> Stream.flat_map(fn schema ->
      schema.fields |> Map.values() |> List.flatten()
    end)
    |> Enum.uniq()
  end
end
