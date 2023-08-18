defmodule JumpWire.Cloak.KeyRing do
  use GenServer
  require Logger
  alias JumpWire.Cloak.Keys

  @doc """
  List storage adapters as configured at startup. This does not query
  the running GenServer, so in theory this list could change over time.
  """
  @spec default_storage_adapters() :: [String.t]
  def default_storage_adapters() do
    Application.get_env(:jumpwire, __MODULE__)
    |> JumpWire.Cloak.Storage.fetch_adapters()
    |> Stream.filter(fn {_mod, enabled} ->
      enabled in ["true", "1", "yes", "on", true]
    end)
    |> Enum.map(fn {adapter, _} ->
      case Module.split(adapter) do
        ["JumpWire", "Cloak", "Storage" | rest] -> Enum.join(rest)
        name -> Enum.join(name)
      end
    end)
  end

  def start_link(config \\ []) do
    # Merge passed in configuration with otp_app configuration
    app_config = Application.get_env(:jumpwire, __MODULE__)
    config = Keyword.merge(app_config, config)
    |> Keyword.update!(:storage_adapters, fn adapters ->
      adapters
      |> Stream.filter(fn {_mod, enabled} ->
        enabled in ["true", "1", "yes", "on", true]
      end)
      |> Enum.map(fn {mod, _} -> mod end)
    end)

    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    # Keys are scoped per-organization.
    # Horde and the CRDTs must be running to load/save keys to the DeltaCrdt storage.
    Logger.info("Loading all encryption keys")
    ciphers = state
    |> Keyword.put_new(:ciphers, %{})
    |> JumpWire.Cloak.Storage.load_keys()

    state = Keyword.put(state, :ciphers, ciphers)
    {:ok, state, {:continue, :load_default_org}}
  end

  @impl GenServer
  def handle_continue(:load_default_org, state) do
    state = JumpWire.Metadata.get_org_id() |> load_keys(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:save_keys, org_id}, config) do
    JumpWire.Tracer.context(org_id: org_id)
    JumpWire.Cloak.Storage.save_keys(config, org_id)
    {:noreply, config}
  end

  @impl GenServer
  def handle_cast({:add_key, org_id, key_id, key}, state) do
    JumpWire.Tracer.context(org_id: org_id)
    Logger.debug("Adding encryption key #{key_id}")

    master_key = Keys.master_key(state, org_id)
    new_ciphers = state
    |> Keyword.put(:ciphers, [master: master_key])
    |> load_key(key_id, key)

    state =
      Keyword.update!(state, :ciphers, fn ciphers ->
        Map.update(ciphers, org_id, new_ciphers, fn org_ciphers ->
          Keyword.merge(org_ciphers, new_ciphers)
        end)
      end)

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:delete_key, org_id, :master}, state) do
    JumpWire.Tracer.context(org_id: org_id)
    Logger.warn("Refusing to delete the master key")
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:delete_key, org_id, name}, state) do
    JumpWire.Tracer.context(org_id: org_id)
    Logger.debug("Removing encryption key #{name}")
    with {{^name, {module, _}}, ciphers} <- pop_in(state[:ciphers], [org_id, name]) do
      config = put_in(state, [:ciphers, org_id], ciphers)
      JumpWire.Cloak.Storage.delete_key(config, {org_id, name}, module)
      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  defp lazy_key_gen(ciphers, _config, false) do
    # Generate default keys if the ciphers do not already have
    # them. This will be skipped if the cluster is used keys managed
    # by the upstream controller.
    ciphers
    |> Keyword.put_new_lazy(:aes, fn ->
      Logger.info("Generating new default AES key")
      Keys.generate_aes_key()
    end)
  end
  defp lazy_key_gen(ciphers, _, _), do: ciphers

  @impl GenServer
  def handle_call({:load_keys, org_id}, _from, config) do
    config = load_keys(org_id, config)
    {:reply, :ok, config}
  end

  @impl GenServer
  def handle_call({:set_keys, org_id, ciphers}, _from, config) do
    Logger.info("Setting keyring to provided keys")

    config = put_in(config, [:ciphers, org_id], ciphers)
    JumpWire.Cloak.Storage.save_keys(config, org_id)
    {:reply, :ok, config}
  end

  @impl GenServer
  def handle_call({:update_key, org_id, key_id, updater}, _from, config) when is_function(updater) do
    Logger.debug("Updating key in keyring")

    config = update_in(config, [:ciphers, org_id, key_id], fn {mod, opts} -> {mod, updater.(opts)} end)
    JumpWire.Cloak.Storage.save_keys(config, org_id)
    {:reply, :ok, config}
  end

  @impl GenServer
  def handle_call({:aes_key, mode, org_id}, _from, config) do
    JumpWire.Tracer.context(org_id: org_id)
    key_name =
      case mode do
        :gcm -> :aes
        :cbc -> :aes_cbc
        :ecb -> :aes_ecb
        _ -> :aes
      end

    key =
      with {:ok, ciphers} <- Map.fetch(config[:ciphers], org_id),
           {_, {_, opts}} <- Enum.find(ciphers, fn {name, {_module, _opts}} ->
             name == key_name
           end),
           {:ok, key} <- Keyword.fetch(opts, :key),
           {:ok, tag} <- Keyword.fetch(opts, :tag) do
          {key, tag}
      else
        _ -> nil
      end

    {:reply, key, config}
  end

  @impl GenServer
  def handle_call({:key_info, org_id}, _from, config) do
    JumpWire.Tracer.context(org_id: org_id)
    ciphers = get_in(config, [:ciphers, org_id])

    # NB: because all key types are rotated together, it should be
    # safe to assume that there are an equal number of keys for each
    # cipher in the keyring (excluding the master key)
    key_count = ciphers
    |> Keyword.delete(:master)
    |> Enum.group_by(fn {_label, {mod, _opts}} -> mod end)
    |> Stream.map(fn {_, ciphers} -> Enum.count(ciphers) end)
    |> Enum.max()

    aes_key_id =
      with {:ok, {_mod, cipher}} <- Keyword.fetch(ciphers, :aes),
           {:ok, key_id} <- Keyword.fetch(cipher, :key_id) do
        key_id
      else
        _ ->
          Logger.error("Could not retrieve AES key id")
          nil
      end

    info = %{num_keys: key_count, key_id: aes_key_id}
    {:reply, info, config}
  end

  @impl GenServer
  def handle_call({:rotate, org_id}, _from, config) do
    JumpWire.Tracer.context(org_id: org_id)
    Logger.info("Rotating encryption keys")

    ciphers = get_in(config, [:ciphers, org_id])
    {master, ciphers} = Keyword.pop!(ciphers, :master)

    aes_config = Keys.generate_aes_key()
    aes_keys = [
      {:aes, aes_config},
      {:aes_cbc, Keys.aes_cbc_config(aes_config)},
      {:aes_ecb, Keys.aes_ecb_config(aes_config)},
    ]

    ciphers = Enum.reduce(aes_keys, ciphers, fn {label, config}, ciphers ->
      case Keyword.pop(ciphers, label) do
        {nil, ciphers} -> [{label, config} | ciphers]
        {old_key, ciphers} ->
          old_label = old_key |> elem(1) |> Keyword.fetch!(:key_id) |> String.to_atom()
          [{label, config}, {old_label, old_key} | ciphers]
      end
    end)

    config = put_in(config, [:ciphers, org_id], [{:master, master} | ciphers])
    JumpWire.Cloak.Storage.save_keys(config, org_id)

    {:reply, :ok, config}
  end

  @impl GenServer
  def handle_call({:rekey, org_id, new_key}, _from, config) do
    JumpWire.Tracer.context(org_id: org_id)
    Logger.warn("Changing master key, all subkeys will be re-encrypted")

    master_key = Keys.aes_config(new_key)
    config = update_in(config, [:ciphers, org_id], fn ciphers ->
      Keyword.replace!(ciphers, :master, master_key)
    end)

    JumpWire.Cloak.Storage.save_keys(config, org_id)

    {:reply, :ok, config}
  end

  def load_key(config, name, {Cloak.Ciphers.AES.GCM, key}) do
    case decrypt_or_log(config, key) do
      {:ok, plaintext} ->
        opts = Keys.aes_config(plaintext)
        cbc_opts = Keys.aes_cbc_config(opts)
        ecb_opts = Keys.aes_ecb_config(opts)
        [{name, opts}, {:"#{name}_cbc", cbc_opts}, {:"#{name}_ecb", ecb_opts}]

      _error -> []
    end
  end
  def load_key(_config, _name, cipher) do
    Logger.warn("Cannot load unknown cipher: #{inspect cipher}")
    []
  end

  defp decrypt_or_log(config, key) do
    case Cloak.Vault.decrypt(config, key) do
      {:error, %Cloak.MissingCipher{}} ->
        key_id = encrypted_key_tag(key)
        Logger.error("Cannot load subkey, missing master key #{key_id}")
        {:error, :missing_cipher}

      {:error, err} ->
        Logger.error("Unable to load key: #{inspect err}")
        {:error, err}

      result -> result
    end
  end

  defp encrypted_key_tag(key) do
    case JumpWire.Vault.decode(key) do
      {:ok, [tag], _} -> tag
      _ -> :unknown
    end
  end

  defp load_keys(org_id, config) do
    JumpWire.Tracer.context(org_id: org_id)
    if is_nil get_in(config, [:ciphers, org_id]) do
      Logger.info("Loading encryption keys")
      managed_keys = Keyword.fetch!(config, :managed_keys)
      ciphers = config
      |> JumpWire.Cloak.Storage.load_keys(org_id)
      |> lazy_key_gen(config, managed_keys)

      # Reuse the default AES key for CBC and ECB encryption modes
      ciphers =
        case Keyword.fetch(ciphers, :aes) do
          {:ok, aes} ->
            ciphers
            |> Keyword.put_new_lazy(:aes_cbc, fn -> Keys.aes_cbc_config(aes) end)
            |> Keyword.put_new_lazy(:aes_ecb, fn -> Keys.aes_ecb_config(aes) end)

          _ ->
            ciphers
        end

      config = put_in(config, [:ciphers, org_id], ciphers)

      # Ensure that the configuration is saved
      JumpWire.Cloak.Storage.save_keys(config, org_id)

      config
    else
      Logger.debug("Keys already loaded, skipping")
      config
    end
  end
end
