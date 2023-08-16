defmodule JumpWire.Cloak.Storage.DeltaCrdt do
  @moduledoc """
  Synchronizes keys across the cluster using delta CRDTs.
  """

  require Logger
  alias JumpWire.Cloak.{Ciphers, Keys, KeyRing}

  defmodule DiskStorage do
    use Hydrax.DeltaCrdt.DiskStorage
  end

  @behaviour JumpWire.Cloak.Storage
  use Hydrax.DeltaCrdt, crdt_opts: [
    storage_module: {:application, :storage_module},
    on_diffs: {JumpWire.Cloak.Storage.DeltaCrdt, :on_diffs, []}
  ]

  @impl true
  def save_keys(config, org_id) do
    master_key = Keys.master_key(config, org_id)

    config
    |> get_in([:ciphers, org_id])
    |> Keyword.put(:master, master_key)
    |> _save_keys(org_id)

    DiskStorage.flush()
  end

  defp _save_keys(ciphers, org_id) do
    config = [ciphers: ciphers]
    {_, ciphers} = Keyword.pop(ciphers, :master)
    Enum.each(ciphers, fn {name, {module, opts}} ->
      key =
        case module do
          Ciphers.AES.CBC -> nil
          Ciphers.AES.ECB -> nil
          Cloak.Ciphers.AES.GCM -> opts[:key]
          Ciphers.AWS.KMS -> nil
          _ -> nil
        end

      if not is_nil(key) do
        encrypted_key = Cloak.Vault.encrypt!(config, key, :master)
        DeltaCrdt.put(@crdt, {org_id, name}, {module, encrypted_key})
      end
    end)
  end

  @impl true
  def load_keys(config) do
    DeltaCrdt.to_map(@crdt)
    |> Enum.group_by(fn {{org_id, _}, _} -> org_id end)
    |> Stream.map(fn {org_id, keys} ->
      # The master key is not saved as an org cipher, it must always be
      # loaded from the full config.
      case Keys.master_key(config, org_id) do
        nil -> {org_id, nil, keys}
        master_key ->
          config = Keyword.put(config, :ciphers, [master: master_key])
          {org_id, config, keys}
      end
    end)
    |> Stream.reject(fn {_, ciphers, _} -> is_nil(ciphers) end)
    |> Stream.map(fn {org_id, config, keys} ->
      ciphers = keys
      |> Enum.map(fn {{_org_id, name}, cipher} ->
        KeyRing.load_key(config, name, cipher)
      end)
      |> List.flatten()
      |> Keyword.put_new(:master, config[:ciphers][:master])

      {org_id, ciphers}
    end)
    |> Map.new()
  end

  @impl true
  def load_keys(config, org_id) do
    ciphers = DeltaCrdt.to_map(@crdt)
    |> Stream.filter(fn {{id, _name}, _} -> id == org_id end)
    |> Enum.map(fn {{_org_id, name}, cipher} ->
      KeyRing.load_key(config, name, cipher)
    end)
    |> List.flatten()

    Logger.debug("Loaded encryption keys for #{org_id} from CRDT: #{inspect Keyword.keys(ciphers)}")
    ciphers
  end

  @impl true
  def delete_key(_config, id, _module) do
    DeltaCrdt.delete(@crdt, id)
    DiskStorage.flush()
  end

  # NB: on_diffs is NOT called when loading state from DiskStorage
  def on_diffs([]), do: :ok
  def on_diffs([{:add, {org_id, id}, key} | diffs]) do
    JumpWire.Vault.add_key(org_id, id, key)
    on_diffs(diffs)
  end
  def on_diffs([{:remove, {org_id, id}} | diffs]) do
    JumpWire.Vault.delete_key(org_id, id)
    on_diffs(diffs)
  end
end
