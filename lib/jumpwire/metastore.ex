defmodule JumpWire.Metastore do
  @moduledoc """
  Describes how to connect to database containing metadata. This
  is used internally by JumpWire and not directly proxied from a client.
  """

  use JumpWire.Schema
  require Logger
  import Ecto.Changeset
  alias __MODULE__

  @type connection() :: any()
  @type value() :: float() | integer() | boolean() | String.t()

  @callback connect(Metastore.t()) :: {:ok, connection()} | :error
  @callback fetch(connection(), value(), Metastore.t()) :: {:ok, value()} | :error
  @callback fetch_all(connection(), [value()], Metastore.t()) :: {:ok, map()} | :error

  typed_embedded_schema null: false do
    field :name, :string
    field :organization_id, :string

    polymorphic_embeds_one :configuration,
      types: [
        postgresql_kv: Metastore.PostgresqlKV,
      ],
      on_replace: :update,
      on_type_not_found: :changeset_error,
      type_field: :type

    field :vault_role, :string, default: nil, null: true
    field :vault_database, :string, default: nil, null: true
    field :credentials, :map, default: nil, null: true
  end

  def from_json(attrs, org_id) do
    %Metastore{organization_id: org_id}
    |> cast(attrs, [:id, :name, :organization_id, :credentials, :vault_database, :vault_role])
    |> validate_required([:id, :name, :organization_id])
    |> cast_polymorphic_embed(:configuration, required: true)
    |> apply_action(:insert)
    |> JumpWire.Credentials.load()
  end

  def hook(_, _) do
    Task.completed(:ok)
  end

  @spec connect(Metastore.t()) :: {:ok, connection()} | :error
  def connect(store) do
    store.configuration.__struct__.connect(store)
  end

  @spec fetch(connection(), value(), Metastore.t()) :: {:ok, value()} | :error
  def fetch(conn, key, store) do
    store.configuration.__struct__.fetch(conn, key, store)
  end

  @spec fetch_all(connection(), [value()], Metastore.t()) :: {:ok, map()} | :error
  def fetch_all(conn, keys, store) do
    store.configuration.__struct__.fetch_all(conn, keys, store)
  end
end
