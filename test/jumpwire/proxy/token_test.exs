defmodule JumpWire.Proxy.TokenTest do
  use ExUnit.Case, async: true
  alias JumpWire.Proxy.Token

  @mod nil

  setup do
    # `:secret_key` can be synced from the controller for the org on application start
    secret = Application.fetch_env!(:jumpwire, :proxy) |> Keyword.get(:secret_key)
    manifest_id = Uniq.UUID.uuid4()
    org_id = Uniq.UUID.uuid4()

    data = {org_id, manifest_id}
    token = Plug.Crypto.sign(secret, "manifest", data)

    %{token: token, org_id: org_id, manifest_id: manifest_id}
  end

  test "peeking of tokens", %{token: token, org_id: org_id, manifest_id: manifest_id} do
    assert %{client: manifest_id, org: org_id} == Token.peek(@mod, token)
    assert is_nil(Token.peek(@mod, nil))
  end

  test "decoding tokens", %{token: token, org_id: org_id, manifest_id: manifest_id} do
    assert {:ok, %{client: manifest_id, org: org_id}} == Token.decode_token(@mod, token)
    assert {:error, :invalid} == Token.decode_token(@mod, token, secret: "boom")
    assert {:error, :invalid} = Token.decode_token(@mod, "notatoken")
  end
end
