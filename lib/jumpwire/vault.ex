defmodule JumpWire.Vault do
  alias JumpWire.Cloak.{KeyRing, Keys}

  @prefix "jumpwire_"

  @doc """
  Returns the first AES key for the org in the Cloak keyring.
  """
  def default_aes_key(org_id, mode \\ :gcm), do: GenServer.call(KeyRing, {:aes_key, mode, org_id})

  @doc """
  Rotate keys.

  A new primary key will be generated, and the old one will be kept in the keyring
  for decrypting existing data.
  """
  def rotate(org_id), do: GenServer.call(KeyRing, {:rotate, org_id}, 60_000)

  @doc """
  Change the master key.

  All subkeys will be reencrypted with the new master key and the old one will be
  discarded.
  """
  def rekey(key, org_id), do: GenServer.call(KeyRing, {:rekey, org_id, key}, 60_000)

  def load_keys(org_id), do: GenServer.call(KeyRing, {:load_keys, org_id}, 60_000)
  def save_keys(org_id), do: GenServer.cast(KeyRing, {:save_keys, org_id})

  @doc """
  Set the keys for an organization, overwriting any existing keys in the keyring.
  """
  def set_keys(ciphers, org_id), do: GenServer.call(KeyRing, {:set_keys, org_id, ciphers})

  @doc """
  Add a new key to the keyring for an organization
  """
  def add_key(org_id, key_id, key) do
    GenServer.cast(KeyRing, {:add_key, org_id, key_id, key})
  end

  @doc """
  Remove a key to the keyring for an organization by its ID.
  """
  def delete_key(org_id, key_id) do
    GenServer.cast(KeyRing, {:delete_key, org_id, key_id})
  end

  @doc """
  Return metadata about the keys in the keyring.
  """
  def key_info(org_id), do: GenServer.call(KeyRing, {:key_info, org_id})

  @doc """
  Update the options for a specific cipher in the organization's key ring.
  """
  @spec update_key_opts(String.t, String.t, (Keyword.t -> Keyword.t)) :: :ok
  def update_key_opts(org_id, key_id, updater) when is_function(updater) do
    GenServer.call(KeyRing, {:update_key, org_id, key_id, updater})
  end

  def encode(%{labels: labels}) do
    labels
    |> Stream.map(&to_string/1)
    |> Enum.join("|")
    |> Cloak.Tags.Encoder.encode()
  end
  def encode(_metadata), do: <<1, 0>>

  def decode(binary) do
    with %{remainder: data, tag: labels} <- Cloak.Tags.Decoder.decode(binary) do
      {:ok, parse_labels(labels), data}
    end
  end

  def peek_metadata(@prefix <> ciphertext) do
    with {:ok, binary} <- JumpWire.Base64.decode(ciphertext),
         {:ok, labels, _} <- decode(binary) do
      {:ok, [:encrypted, :peeked | labels]}
    end
  end
  def peek_metadata(_), do: {:error, :invalid_format}

  def peek_tag(@prefix <> ciphertext) do
    with {:ok, binary} <- JumpWire.Base64.decode(ciphertext),
         {:ok, _labels, binary} <- decode(binary),
         %{tag: tag} <- Cloak.Tags.Decoder.decode(binary) do
      {:ok, tag}
    end
  end
  def peek_tag(_), do: {:error, :invalid_format}

  def peek_tag!(ciphertext) do
    case peek_tag(ciphertext) do
      {:ok, tag} -> tag
      _ -> raise RuntimeError, "Cannot decode tag from invalid ciphertext"
    end
  end

  @spec encrypt(String.t, String.t, atom) :: {:ok, String.t} | {:error, any}
  def encrypt(data, org_id, key \\ :aes) do
    with {:ok, ciphers} <- JumpWire.Cloak.Storage.read_keys(org_id) do
      Cloak.Vault.encrypt([ciphers: ciphers], data, key)
    end
  end

  @spec decrypt(String.t, String.t) :: {:ok, String.t} | :error | {:error, any}
  def decrypt(data, org_id) do
    with {:ok, ciphers} <- JumpWire.Cloak.Storage.read_keys(org_id) do
      case find_module_to_decrypt(ciphers, data) do
        nil -> {:error, Cloak.MissingCipher.exception(ciphertext: data)}
        cipher -> decrypt(data, org_id, cipher)
      end
    end
  end

  defp decrypt(data, org_id, {label, {module, opts}}) do
    # Do more processing if decrypt/2 needs to update the state of the key ring.
    # Otherwise, allow the successful call to return.
    with {:update_cipher, updater} <- module.decrypt(data, opts),
         :ok <- update_key_opts(org_id, label, updater) do
      decrypt(data, org_id)
    end
  end

  defp find_module_to_decrypt(ciphers, ciphertext) do
    Enum.find(ciphers, fn {_label, {module, opts}} ->
      module.can_decrypt?(ciphertext, opts)
    end)
  end

  @spec encode_and_encrypt(String.t, map, String.t, atom) :: {:ok, String.t} | {:error, any}
  def encode_and_encrypt(data, metadata, org_id, key \\ :aes) do
    with {:ok, ciphertext} <- encrypt(data, org_id, key) do
      prefix = encode(metadata)
      {:ok, @prefix <> JumpWire.Base64.encode(prefix <> ciphertext)}
    end
  end

  @spec decrypt_and_decode(String.t, String.t) :: {:ok, String.t, [atom]} | :error | {:error, any}
  def decrypt_and_decode(@prefix <> data, org_id) do
    with {:ok, binary} <- JumpWire.Base64.decode(data),
         {:ok, labels, ciphertext} <- decode(binary),
         {:ok, plaintext} <- decrypt(ciphertext, org_id) do
      {:ok, plaintext, labels}
    end
  end
  def decrypt_and_decode(_, _), do: {:error, :invalid_format}

  defp parse_labels(labels) do
    String.split(labels, "|", trim: true)
  end

  @doc """
  Store encryption keys that were dynamically loaded from the control
  plane.
  """
  @spec store_keys(map, String.t) :: :ok | {:error, any}
  def store_keys(keys, org_id) do
    with {:ok, master_key} <- Map.fetch(keys, "master"),
         {:ok, master_key} <- JumpWire.Base64.decode(master_key) do
      ciphers = [master: Keys.aes_config(master_key)]

      # TODO: this logic is largely copied from
      # JumpWire.Cloak.Storage.Vault.load_keys/3 and can be deduped at
      # some point.

      ciphers = keys
      |> Map.get("aes", %{})
      |> Enum.reduce(ciphers, fn {name, key}, acc ->
        key = JumpWire.Base64.decode!(key)
        name = String.to_atom(name)
        opts = Keys.aes_config(key)
        cbc_opts = Keys.aes_cbc_config(opts)
        ecb_opts = Keys.aes_ecb_config(opts)

        acc
        |> Keyword.put(name, opts)
        |> Keyword.put(:"#{name}_cbc", cbc_opts)
        |> Keyword.put(:"#{name}_ecb", ecb_opts)
      end)

      with :ok <- JumpWire.update_env(JumpWire.Cloak.KeyRing, :ciphers, %{org_id => ciphers}) do
        # Normally this function is called during application startup and the KeyRing process will not be alive yet.
        # If it is running for some reason, the process needs to replace its keys with the ones provided here.
        case Process.whereis(JumpWire.Cloak.KeyRing) do
          nil -> :ok
          _pid -> set_keys(ciphers, org_id)
        end
      end
    end
  end

  @doc """
  Update the app env to indicate whether the control plane is the
  source of truth for encryption keys. If true, keys will be sent
  over the websocket connection when they are generated.

  This should only be used in single-tenant deployments as it does not
  scope the flag to a specific organization.
  """
  @spec set_controller_management(boolean) :: :ok
  def set_controller_management(managed_keys) do
    JumpWire.update_env(JumpWire.Cloak.KeyRing, :managed_keys, managed_keys)
  end
end
