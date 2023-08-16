defmodule JumpWire.Cloak.Storage do
  @callback save_keys(config :: keyword, org_id :: Ecto.UUID.t) :: :ok | {:error, any}
  @callback load_keys(config :: keyword) :: map
  @callback load_keys(config :: keyword, org_id :: Ecto.UUID.t) :: keyword
  @callback delete_key(config :: keyword, {org_id :: Ecto.UUID.t, name :: atom}, module :: atom)
  :: :ok | {:error, any}

  @table_name __MODULE__

  defp create_ets_table() do
    if :ets.info(@table_name) == :undefined do
      :ets.new(@table_name, [:named_table, :protected])
    end
  end

  @doc false
  def read_keys(org_id) do
    case :ets.lookup(@table_name, org_id) do
      [{^org_id, ciphers} | _] -> {:ok, ciphers}
      _ -> {:error, :key_storage}
    end
  end

  @doc """
  Load the keys for all organizations. Each configured storage module will be queried
  and the results will be merged together
  """
  def load_keys(config) do
    ciphers = config
    |> fetch_adapters()
    |> Enum.reduce(config[:ciphers], fn mod, ciphers ->
      loaded = mod.load_keys(config)
      Map.merge(ciphers, loaded, fn _org_id, old, new ->
        Keyword.merge(old, new, fn _name, _old, new -> new end)
      end)
    end)

    # Store the ciphers in an ETS table for encryption/decryption lookup
    create_ets_table()
    Enum.each(ciphers, fn cipher -> :ets.insert(@table_name, cipher) end)

    ciphers
  end

  @doc """
  Load the keys for a particular organization. Each configured storage module will be queried
  and the results will be merged together

  The JumpWire.Cloak.KeyRing calls this function when an organization is being initialized.
  That GenServer owns the protected ETS table containing
  """
  def load_keys(config, org_id) do
    master_key = JumpWire.Cloak.Keys.master_key(config, org_id)
    ciphers = config[:ciphers]
    |> Map.get(org_id, [])
    |> Keyword.put_new(:master, master_key)

    ciphers = config
    |> fetch_adapters()
    |> Enum.reduce(ciphers, fn mod, ciphers ->
      loaded = config
      |> Keyword.put(:ciphers, ciphers)
      |> mod.load_keys(org_id)
      Keyword.merge(ciphers, loaded, fn _name, _old, new -> new end)
    end)

    # Store the ciphers in an ETS table for encryption/decryption lookup
    set_keys(org_id, ciphers)

    ciphers
  end

  def save_keys(config, org_id) do
    with {:ok, ciphers} <- Map.fetch(config[:ciphers], org_id) do
      set_keys(org_id, ciphers)

      config
      |> Keyword.fetch!(:storage_adapters)
      |> Enum.reduce(:ok, fn mod, acc ->
        with :ok <- mod.save_keys(config, org_id), do: acc
      end)
    end
  end

  def delete_key(config, id, module) do
    config
    |> fetch_adapters()
    |> Enum.reduce_while(:ok, fn mod, _ ->
      case mod.delete_key(config, id, module) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  @doc """
  Return a list of all configured storage modules.
  """
  def fetch_adapters(config) do
    Keyword.fetch!(config, :storage_adapters)
  end

  defp set_keys(org_id, ciphers) do
    create_ets_table()
    :ets.insert(@table_name, {org_id, ciphers})
  end
end
