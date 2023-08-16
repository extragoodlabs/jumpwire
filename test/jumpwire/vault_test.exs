defmodule JumpWire.VaultTest do
  use ExUnit.Case, async: false
  alias JumpWire.Vault

  @org_id Application.compile_env(:jumpwire, JumpWire.Cloak.KeyRing)[:default_org]

  test "encoding of labels" do
    metadata = %{labels: ["sensitive"]}
    data = "123-45-6789"
    assert {:ok, ciphertext} = Vault.encode_and_encrypt(data, metadata, @org_id, :aes)
    assert {:ok, data, ["sensitive"]} == Vault.decrypt_and_decode(ciphertext, @org_id)
    assert {:ok, [:encrypted, :peeked, "sensitive"]} = Vault.peek_metadata(ciphertext)

    assert {:ok, ciphertext} = Vault.encode_and_encrypt(data, %{}, @org_id)
    assert {:ok, data, []} == Vault.decrypt_and_decode(ciphertext, @org_id)
  end

  test "isolation of keys by organization" do
    assert {:ok, ciphertext} = Vault.encode_and_encrypt("totally secret", %{}, @org_id, :aes)
    assert {:error, :key_storage} == Vault.decrypt_and_decode(ciphertext, "wrong_org")
  end

  test "key rotation" do
    plaintext = "the second law of thermodynamics"
    {:ok, ciphers} = JumpWire.Cloak.Storage.read_keys(@org_id)
    %{num_keys: count, key_id: prev_key_id} = JumpWire.Vault.key_info(@org_id)
    refute is_nil(prev_key_id)
    expected_count = count + 1

    {:ok, aes_encrypted} = JumpWire.Vault.encrypt(plaintext, @org_id, :aes)
    {:ok, master_encrypted} = JumpWire.Vault.encrypt(plaintext, @org_id, :master)

    assert :ok = JumpWire.Vault.rotate(@org_id)
    assert {:ok, plaintext} == JumpWire.Vault.decrypt(aes_encrypted, @org_id)
    assert {:ok, plaintext} == JumpWire.Vault.decrypt(master_encrypted, @org_id)

    {:ok, new_ciphers} = JumpWire.Cloak.Storage.read_keys(@org_id)
    assert %{num_keys: ^expected_count, key_id: key_id} = JumpWire.Vault.key_info(@org_id)
    refute is_nil(key_id)
    refute key_id == prev_key_id
    assert get_tag(new_ciphers, :master) == get_tag(ciphers, :master)
    refute get_tag(new_ciphers, :aes) == get_tag(ciphers, :aes)
    refute get_tag(new_ciphers, :aes_cbc) == get_tag(ciphers, :aes_cbc)
    refute get_tag(new_ciphers, :aes_ecb) == get_tag(ciphers, :aes_ecb)
  end

  test "master key rekeying" do
    plaintext = "the second law of thermodynamics"
    {:ok, ciphers} = JumpWire.Cloak.Storage.read_keys(@org_id)
    {_, master_opts} = ciphers[:master]
    %{num_keys: count} = JumpWire.Vault.key_info(@org_id)

    {:ok, aes_encrypted} = JumpWire.Vault.encrypt(plaintext, @org_id, :aes)
    {:ok, master_encrypted} = JumpWire.Vault.encrypt(plaintext, @org_id, :master)

    new_key = :crypto.strong_rand_bytes(32)
    assert :ok = JumpWire.Vault.rekey(new_key, @org_id)
    on_exit fn -> JumpWire.Vault.rekey(master_opts[:key], @org_id) end

    assert {:ok, plaintext} == JumpWire.Vault.decrypt(aes_encrypted, @org_id)
    assert {:error, %Cloak.MissingCipher{}} = JumpWire.Vault.decrypt(master_encrypted, @org_id)

    {:ok, new_ciphers} = JumpWire.Cloak.Storage.read_keys(@org_id)
    assert %{num_keys: ^count} = JumpWire.Vault.key_info(@org_id)
    assert get_tag(new_ciphers, :master) != get_tag(ciphers, :master)
    assert get_tag(new_ciphers, :aes) == get_tag(ciphers, :aes)
  end

  describe "update app env" do
    setup do
      opts = Application.get_env(:jumpwire, JumpWire.Cloak.KeyRing)
      ciphers = :sys.get_state(JumpWire.Cloak.KeyRing)[:ciphers][@org_id]
      on_exit fn ->
        Application.put_env(:jumpwire, JumpWire.Cloak.KeyRing, opts)
        Vault.set_keys(ciphers, @org_id)
      end
      :ok
    end

    test "with valid keys" do
      keys = %{
        "master" => :crypto.strong_rand_bytes(32) |> Base.encode64(),
        "aes" => %{"aes" => :crypto.strong_rand_bytes(32) |> Base.encode64()},
      }
      assert :ok == Vault.store_keys(keys, @org_id)
      assert %{num_keys: 1} = Vault.key_info(@org_id)
    end
  end

  defp get_tag(ciphers, name) do
    {_, opts} = ciphers[name]
    opts[:tag]
  end
end
