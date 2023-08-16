defmodule JumpWire.RecordTest do
  use ExUnit.Case, async: true
  alias JumpWire.Record

  @org_id Application.compile_env(:jumpwire, JumpWire.Cloak.KeyRing)[:default_org]

  test "loading of labels from encrypted data" do
    {:ok, data} = JumpWire.Vault.encode_and_encrypt("my data", %{labels: ["test"]}, @org_id)

    assert [:encrypted, :peeked, "test"] == Record.load_labels(data, [])
    assert [:encrypted, :peeked, "test"] == Record.load_labels(data, ["test"])
    assert [:peeked, "test"] == Record.load_labels(data, [:peeked, "test"])
  end
end
