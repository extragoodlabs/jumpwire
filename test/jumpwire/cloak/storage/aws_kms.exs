defmodule JumpWire.Cloak.Storage.AWS.KMSTest do
  use ExUnit.Case, async: false
  use JumpWire.LocalstackContainer
  alias JumpWire.Cloak.Storage.AWS.KMS

  test "generate a new data key" do
    org_id = Faker.UUID.v4()

    assert [aes: {JumpWire.Cloak.Ciphers.AWS.KMS, opts}] = KMS.load_keys([], org_id)
    keys = Keyword.fetch!(opts, :keys)
    assert Enum.count(keys) >= 1

    for {_, opts} <- keys do
      encrypted_key = Keyword.get(opts, :encrypted_key)
      refute is_nil(encrypted_key)
    end
  end
end
