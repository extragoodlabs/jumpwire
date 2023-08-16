defmodule JumpWire.ETSTest do
  use ExUnit.Case, async: false

  @table :test

  defmodule Mock do
    use JumpWire.ETS, tables: [:test]
  end

  setup do
    start_supervised Mock
    :ok
  end

  test "CRUD on individual objects" do
    obj = %{id: Uniq.UUID.uuid4(), organization_id: "org_abc"}
    key = {obj.organization_id, obj.id}

    Mock.put(@table, obj)

    assert [obj] == Mock.get(@table)
    assert obj == Mock.get(@table, key)

    Mock.delete(@table, key)
    assert [] == Mock.get(@table)
    assert nil == Mock.get(@table, key)
  end

  test "delete by org id" do
    obj = %{id: Uniq.UUID.uuid4(), organization_id: "org_abc"}
    Mock.put(@table, obj)

    Mock.delete(@table, {"other_org", :_})
    assert [obj] == Mock.get(@table)

    Mock.delete(@table, {obj.organization_id, :_})
    assert [] == Mock.get(@table)
    assert nil == Mock.get(@table, {obj.organization_id, obj.id})
  end

  test "delete by id without org id" do
    obj = %{id: Uniq.UUID.uuid4(), organization_id: "org_abc"}
    Mock.put(@table, obj)

    Mock.delete(@table, {:_, Uniq.UUID.uuid4()})
    assert [obj] == Mock.get(@table)

    Mock.delete(@table, {:_, obj.id})
    assert [] == Mock.get(@table)
    assert nil == Mock.get(@table, {obj.organization_id, obj.id})
  end

  test "deletion with triple-element tuple key" do
    obj = %{id: Uniq.UUID.uuid4(), organization_id: "org_abc"}
    key = {obj.organization_id, obj.id, "deleteme"}

    Mock.put(@table, key, obj)
    Mock.delete(@table, {obj.organization_id, obj.id, :_})
    assert [] == Mock.get(@table)

    Mock.put(@table, key, obj)
    Mock.delete(@table, {:_, obj.id, :_})
    assert [] == Mock.get(@table)

    Mock.put(@table, key, obj)
    Mock.delete(@table, {obj.organization_id, :_, :_})
    assert [] == Mock.get(@table)

    Mock.put(@table, key, obj)
    Mock.delete(@table, {obj.organization_id, obj.id, :_})
    assert [] == Mock.get(@table)
  end
end
