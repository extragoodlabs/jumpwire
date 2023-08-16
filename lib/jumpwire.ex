defmodule JumpWire do
  require Logger

  @doc """
  Return high level information about the cluster.
  """
  def cluster_info(org_id) do
    databases =
      with true <- JumpWire.Proxy.Storage.Vault.enabled?(),
           {:ok, dbs} <- JumpWire.Proxy.Storage.Vault.list_databases(org_id) do
        dbs
      else
        _ -> nil
      end

    %{
      "ports" => JumpWire.Proxy.ports(),
      "keys" => JumpWire.Vault.key_info(org_id),
      "databases" => databases,
      "domain" => JumpWire.Proxy.domain(),
      "nodes" => cluster_node_info(),
    }
  end

  @doc """
  Return information about all nodes in the cluster, including the node this is called on.
  """
  def cluster_node_info(cluster \\ JumpWire.GlobalConfig) do
    Horde.Cluster.members(cluster)
    |> Stream.map(fn {_, node} ->
      case :rpc.call(node, JumpWire, :node_info, []) do
        {:ok, info} -> {node, info}
        {:badrpc, _} -> {node, %{}}
      end
    end)
    |> Stream.map(fn {node, info} -> {to_string(node), info} end)
    |> Map.new()
  end

  @doc """
  Return information about the local node.
  """
  def node_info() do
    version = Application.spec(:jumpwire) |> Keyword.get(:vsn) |> to_string()
    time = System.system_time(:millisecond)
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    {:ok, %{version: version, system_time: time, uptime: uptime_ms}}
  end

  @doc """
  Update an app key with a new keyword, overwriting any existing value.
  """
  @spec update_env(atom, atom, any) :: :ok
  def update_env(key, subkey, value) do
    opts = Application.get_env(:jumpwire, key)
    |> Keyword.put(subkey, value)
    Application.put_env(:jumpwire, key, opts, persistent: true)
  end

  @spec validate_config() :: :ok | {:error, any}
  def validate_config() do
    with key <- Application.get_env(:jumpwire, :proxy)[:secret_key],
         :ok <- check_nil(key, "token signing key") do
      initialize_root_token()
    end
  end

  defp check_nil(nil, msg), do: {:error, msg}
  defp check_nil(_, _), do: :ok

  defp initialize_root_token() do
    case JumpWire.API.Token.get_root_token() do
      nil ->
        token = JumpWire.API.Token.generate_root_token()
        Logger.warn("Generating a new root token! It is strongly recommended to explicitly set JUMPWIRE_ROOT_TOKEN instead.")
        {:ok, [{"Root token", token}]}

      _token -> {:ok, []}
    end
  end

  @doc """
  Parse a JWT and return metadata from the token's claims. Does not validate the token signature.
  """
  def token_claims(nil), do: {:error, :invalid_token}
  def token_claims(token) do
    case JOSE.JWT.peek_payload(token) do
      %JOSE.JWT{fields: claims} ->
        case claims do
          %{"https://jumpwire.ai/org/id" => org, "sub" => sub} ->
            {:ok, %{claims: claims, org: org, cluster: sub}}

          # Deprecated org-wide tokens
          %{"sub" => sub} ->
            {:ok, %{claims: claims, org: sub, cluster: sub}}
        end

      _ -> {:error, :invalid_token}
    end
  end
end
