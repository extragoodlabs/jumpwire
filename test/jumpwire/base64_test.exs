defmodule JumpWire.Base64Test do
  use ExUnit.Case, async: true

  test "encoding of base64 binaries" do
    data = <<1, 9, 115, "jumpwire">>
    expected = Base.encode64(data)
    assert expected == JumpWire.Base64.encode(data)
    assert {:ok, data} == JumpWire.Base64.decode(expected)
  end
end
