defmodule JumpWire.SSO.SamlyState do
  @moduledoc """
  Stores SAML assertion in a CRDT-synced ETS table.
  """

  alias Samly.Assertion
  alias JumpWire.GlobalConfig

  @behaviour Samly.State.Store

  @assertions_table :samly_assertions

  @impl Samly.State.Store
  def init(_opts) do
    @assertions_table
  end

  @impl Samly.State.Store
  def get_assertion(_conn, assertion_key, assertions_table) do
    case GlobalConfig.fetch(assertions_table, assertion_key) do
      {:ok, %Assertion{} = assertion} -> assertion
      _ -> nil
    end
  end

  @impl Samly.State.Store
  def put_assertion(conn, assertion_key, assertion, assertions_table) do
    GlobalConfig.put(assertions_table, assertion_key, assertion)
    conn
  end

  @impl Samly.State.Store
  def delete_assertion(conn, assertion_key, assertions_table) do
    GlobalConfig.delete(assertions_table, assertion_key)
    conn
  end
end
