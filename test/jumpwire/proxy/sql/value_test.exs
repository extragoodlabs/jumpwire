defmodule JumpWire.Proxy.SQL.ValueTest do
  use ExUnit.Case, async: true
  use PropCheck
  alias JumpWire.Proxy.SQL.Value

  test "number parsing" do
    forall val <- number() do
      assert {:ok, val} == Value.from_expr({:number, "#{val}", false})
    end
  end
end
