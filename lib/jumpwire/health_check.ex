defmodule JumpWire.HealthCheck do
  @moduledoc """
  Check high-level health and metadatata information about the cluster.
  """

  @doc """
  Check the current status of the cluster. Endpoints called here should
  rely on configuration or cached information and avoid any expensive
  calls that would block live data processing.
  """
  @spec status() :: map()
  def status() do
    credential_modules = %{
      "Vault" => JumpWire.Proxy.Storage.Vault.enabled?(),
      "File" => JumpWire.Proxy.Storage.File.enabled?(),
    }
    |> Stream.filter(fn {_, enabled} -> enabled end)
    |> Enum.map(fn {name, _} -> name end)

    clusters =
      case JumpWire.Websocket.list_clusters() do
        {:ok, clusters} -> clusters
        _ -> %{}
      end

    connected = Enum.any?(clusters, fn {_, joined} -> joined end)

    %{
      "credential_adapters" => credential_modules,
      "key_adapters" => JumpWire.Cloak.KeyRing.default_storage_adapters(),
      "ports" => JumpWire.Proxy.ports(),
      "domain" => JumpWire.Proxy.domain(),
      "clusters_joined" => clusters,
      "web_connected" => connected,
    }
  end
end
