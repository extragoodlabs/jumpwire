defmodule JumpWire.ProxyTest do
  use JumpWire.ProxyCase, async: false

  test "schema_migrated? returns false for empty stats" do
    assert false == JumpWire.Proxy.schema_migrated?(%{})
  end

  test "schema_migrated? returns true for stats with no rows" do
    assert true == JumpWire.Proxy.schema_migrated?(%{rows: %{count: 0, target: 0}})
  end

  test "schema_migrated? returns false for stats with fields that dont equal targets" do
    stats = %{
      rows: %{count: 5, target: 5},
      encrypted: %{
        first: %{count: 0, target: 5},
        last: %{count: 5, target: 5}
      },
      tokenized: %{}
    }
    assert false == JumpWire.Proxy.schema_migrated?(stats)

    stats = %{
      rows: %{count: 5, target: 5},
      encrypted: %{},
      tokenized: %{
        cc: %{count: 0, target: 5},
        ssn: %{count: 5, target: 5}
      }
    }
    assert false == JumpWire.Proxy.schema_migrated?(stats)
  end

  test "schema_migrated? returns true for stats with fields that equal targets" do
    stats = %{
      rows: %{count: 5, target: 5},
      encrypted: %{
        first: %{count: 5, target: 5},
        last: %{count: 5, target: 5}
      },
      tokenized: %{}
    }
    assert true == JumpWire.Proxy.schema_migrated?(stats)

    stats = %{
      rows: %{count: 5, target: 5},
      encrypted: %{},
      tokenized: %{
        cc: %{count: 5, target: 5},
        ssn: %{count: 5, target: 5}
      }
    }
    assert true == JumpWire.Proxy.schema_migrated?(stats)
  end
end
