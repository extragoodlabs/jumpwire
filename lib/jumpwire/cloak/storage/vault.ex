defmodule JumpWire.Cloak.Storage.Vault do
  require Logger
  alias JumpWire.Cloak.Keys

  @behaviour JumpWire.Cloak.Storage

  @impl true
  def load_keys(config) do
    Logger.debug("Loading encryption keys from Vault")
    {:ok, vault} = client()

    case Vault.list(vault, kv_path()) do
      {:ok, %{"keys" => orgs}} ->
        Enum.reduce(orgs, %{}, fn path, acc ->
          org_id = Path.basename(path)
          ciphers = load_keys(config, org_id, vault)
          Map.put(acc, org_id, ciphers)
        end)

      err ->
        Logger.error("Failed to list Vault keys: #{inspect err}")
        %{}
    end
  end

  @impl true
  def load_keys(config, org_id) do
    {:ok, vault} = client()
    load_keys(config, org_id, vault)
  end

  @spec load_keys(Keyword.t, String.t, Vault.t) :: Keyword.t
  def load_keys(config, org_id, vault) do
    if config[:managed_keys] do
      Logger.info("Vault is configured but encryption keys are managed by the upstream controller")
      []
    else
      _load_keys(org_id, vault)
    end
  end

  defp _load_keys(org_id, vault) do
    Logger.debug("Loading encryption keys from Vault for #{org_id}")
    master_cipher =
      case Vault.read(vault, kv_path(org_id, :master)) do
        {:ok, %{"key" => key}} ->
          key = Base.decode64!(key)
          Keys.aes_config(key)

        _ ->
          Logger.warn("Could not load master key form Vault! A new one will be generated.")
          Keys.generate_aes_key()
      end

    aes_ciphers =
      with {:ok, keys} <- Vault.read(vault, kv_path(org_id, :aes)) do
        Enum.flat_map(keys, fn {name, key} ->
          key = Base.decode64!(key)
          name = String.to_atom(name)
          opts = Keys.aes_config(key)
          cbc_opts = Keys.aes_cbc_config(opts)
          ecb_opts = Keys.aes_ecb_config(opts)
          [{name, opts}, {:"#{name}_cbc", cbc_opts}, {:"#{name}_ecb", ecb_opts}]
        end)
      else
        _ ->
          Logger.warn("No AES keys found in Vault")
          []
      end

    ciphers = [master: master_cipher] ++ aes_ciphers
    Logger.debug("Loaded encryption keys from Vault: #{inspect Keyword.keys(ciphers)}")
    ciphers
  end

  @impl true
  def save_keys(config, org_id) do
    {:ok, vault} = client()
    config
    |> get_in([:ciphers, org_id])
    |> _save_keys(org_id, vault)
  end

  defp _save_keys(ciphers, org_id, vault) do
    Logger.debug("Saving encryption keys to Vault for #{org_id}")
    master_path = kv_path(org_id, :master)
    aes_path = kv_path(org_id, :aes)

    {{_, master_cipher}, ciphers} = Keyword.pop(ciphers, :master)
    ciphers = Enum.group_by(ciphers, fn {_, {mod, _}} -> mod end)

    master_key = master_cipher[:key] |> Base.encode64()
    master_key_data = %{key: master_key}

    aes_data = ciphers
    |> Map.get(Cloak.Ciphers.AES.GCM)
    |> Enum.reduce(%{}, fn {name, {_, opts}}, acc ->
      key = opts[:key] |> Base.encode64()
      Map.put(acc, name, key)
    end)

    with {:ok, _} <- Vault.write(vault, master_path, master_key_data),
         {:ok, _} <- Vault.write(vault, aes_path, aes_data) do
      :ok
    end
  end

  @impl true
  def delete_key(config, {org_id, _name}, _module) do
    # NB: Vault doesn't support deleting a single key within the KV store. The passed
    # in config object should already have the deleted cipher removed, so we can just
    # save the entire thing to Vault and overwrite the existing keys.
    save_keys(config, org_id)
  end

  def client() do
    Application.get_env(:jumpwire, :libvault)
    |> Vault.new()
    |> Vault.auth()
  end

  def kv_path() do
    Application.get_env(:jumpwire, :libvault)
    |> Keyword.get(:kv_path)
  end

  def kv_path(org_id, path) do
    base = kv_path() |> Path.join(org_id)
    case path do
      :aes -> Path.join(base, "aes_keys")
      :master -> Path.join(base, "master_key")
      path -> Path.join(base, "#{path}")
    end
  end
end
