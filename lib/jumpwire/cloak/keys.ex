defmodule JumpWire.Cloak.Keys do
  def aes_config(key) do
    key_id = :crypto.hash(:md5, key) |> Base.encode16()
    {
      Cloak.Ciphers.AES.GCM,
      tag: "AES.GCM.V1.#{key_id}",
      key_id: key_id,
      key: key,
      iv_length: 12,
    }
  end

  @doc """
  Transform an AES GCM/CTR config into a CBC config using the same key.
  """
  def aes_cbc_config({_mod, opts}) do
    key_id = Keyword.fetch!(opts, :key_id)
    opts = opts
    |> Keyword.put(:tag, "JUMPWIRE.AES.CBC.V1.#{key_id}")
    |> Keyword.delete(:iv_length)
    {JumpWire.Cloak.Ciphers.AES.CBC, opts}
  end

  @doc """
  Transform an AES GCM/CTR config into a ECB config using the same key.
  """
  def aes_ecb_config({_mod, opts}) do
    key_id = Keyword.fetch!(opts, :key_id)
    opts = opts
    |> Keyword.put(:tag, "JUMPWIRE.AES.ECB.V1.#{key_id}")
    |> Keyword.delete(:iv_length)
    |> Keyword.update!(:key, fn <<key::binary-size(16), _::binary>> ->
      # JumpWire.Cloak.Ciphers.AES.ECB defaults to 128 bit keys while other modes use 256 bits
      # We use the first half of the AES-GCM key to handle this discrepancy
      key
    end)
    {JumpWire.Cloak.Ciphers.AES.ECB, opts}
  end

  def kms_config(id, keys) do
    {
      JumpWire.Cloak.Ciphers.AWS.KMS,
      tag: "AWS.KMS.V1",
      key_id: id,
      keys: keys,
    }
  end

  def with_extra_opts({mod, opts}, new_opts) when is_list(new_opts) do
    {mod, Keyword.merge(opts, new_opts)}
  end

  @spec generate_aes_key() :: {module, keyword}
  def generate_aes_key() do
    :crypto.strong_rand_bytes(32) |> aes_config()
  end

  @doc """
  Find the master key for a given organization if it exists.
  """
  @spec master_key(Keyword.t, String.t) :: nil | {module, Keyword.t}
  def master_key(config, org_id) do
    ciphers = config[:ciphers] |> Map.get(org_id, [])
    case Keyword.fetch(ciphers, :master) do
      {:ok, key} -> key
      _ ->
        # Use a key from the app config. This should only happen in
        # dev/test.
        case Keyword.fetch(config, :master_key) do
          {:ok, key} -> key |> JumpWire.Base64.decode!() |> aes_config()
          _ -> nil
        end
    end
  end
end
