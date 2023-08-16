defmodule JumpWire.Cloak.Ciphers.AWS.KMSTest do
  use ExUnit.Case, async: false
  use PropCheck
  use JumpWire.LocalstackContainer
  alias JumpWire.Cloak.Ciphers.AWS.KMS
  alias JumpWire.Cloak.Keys

  @org_id Faker.UUID.v4()

  setup_all do
    {:ok, %{
        "CiphertextBlob" => encrypted_key,
        "Plaintext" => data_key,
        "KeyId" => key_id,
     }} = JumpWire.AWS.KMS.generate_key("alias/jumpwire/#{@org_id}")
    data_key = JumpWire.Base64.decode!(data_key)
    encrypted_key = JumpWire.Base64.decode!(encrypted_key)

    aes_cipher = Keys.aes_config(data_key)
    |> Keys.with_extra_opts(encrypted_key: encrypted_key)
    {_mod, kms_cipher_opts} = Keys.kms_config(key_id, [aes_cipher])

    %{
      encrypted_key: encrypted_key,
      kms_cipher_opts: kms_cipher_opts,
      key: data_key,
      key_id: key_id,
    }
  end

  property "encrypted data can be decrypted", [:verbose], %{kms_cipher_opts: opts} do
    ciphers = [aes: {KMS, opts}]
    config = [ciphers: ciphers]
    JumpWire.Vault.set_keys(ciphers, @org_id)

    forall plaintext <- binary() do
      # Test using the cipher module directly
      assert {:ok, ciphertext} = KMS.encrypt(plaintext, opts)
      assert is_binary(ciphertext)
      refute ciphertext == plaintext
      assert {:ok, plaintext} == KMS.decrypt(ciphertext, opts)

      # Test using the Cloak API
      # TODO: it might make sense to move to the Vault test module
      ciphertext = Cloak.Vault.encrypt!(config, plaintext, :aes)
      assert is_binary(ciphertext)
      refute ciphertext == plaintext
      assert {:ok, plaintext} == JumpWire.Vault.decrypt(ciphertext, @org_id)
    end
  end

  test "encrypted keys are decrypted from data", %{
    kms_cipher_opts: opts, key_id: key_id
  } do
    # Encrypt some data
    plaintext = Faker.Cannabis.medical_use()
    assert {:ok, ciphertext} = KMS.encrypt(plaintext, opts)

    # Remove the data key from the key ring
    {mod, opts} = Keys.kms_config(key_id, [])
    JumpWire.Vault.set_keys([aes: {mod, opts}], @org_id)

    # Try to decrypt the data. The encrypted key should be decrypted with
    # KMS and then added to the key ring
    assert {:update_cipher, _updater} = KMS.decrypt(ciphertext, opts)
    assert {:ok, ^plaintext} = JumpWire.Vault.decrypt(ciphertext, @org_id)
  end
end
