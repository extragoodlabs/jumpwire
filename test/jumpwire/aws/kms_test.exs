defmodule JumpWire.AWS.KMSTest do
  use ExUnit.Case, async: true
  use JumpWire.LocalstackContainer
  alias JumpWire.AWS.KMS

  test "generating data key" do
    key_name = "alias/jumpwire/#{Faker.UUID.v4()}"

    assert {:ok, %{
               "CiphertextBlob" => encrypted_key,
               "Plaintext" => data_key,
               "KeyId" => _key_id,
            }} = KMS.generate_key(key_name)

    assert {:ok, _key} = JumpWire.Base64.decode(data_key)
    assert {:ok, _key} = JumpWire.Base64.decode(encrypted_key)
  end
end
