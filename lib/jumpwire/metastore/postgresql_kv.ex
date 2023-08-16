defmodule JumpWire.Metastore.PostgresqlKV do
  @moduledoc """
  A metastore configuration for using a PostgreSQL database for
  simple KV lookups.
  """

  use JumpWire.Schema
  import Ecto.Changeset

  @behaviour JumpWire.Metastore

  @primary_key false
  typed_embedded_schema null: false do
    field :table, :string
    field :key_field, :string
    field :value_field, :string
    field :connection, :map
  end

  @doc false
  def changeset(metastore, attrs) do
    # https://www.postgresql.org/docs/9.2/sql-syntax-lexical.html#SQL-SYNTAX-IDENTIFIERS
    pg_id_regex = ~r/\w[\w|$]*/iu
    metastore
    |> cast(attrs, [:table, :key_field, :value_field, :connection])
    |> validate_required([:table, :key_field, :value_field, :connection])
    |> validate_format(:table, pg_id_regex)
    |> validate_format(:key_field, pg_id_regex)
    |> validate_format(:value_field, pg_id_regex)
  end

  @impl true
  def connect(metastore) do
    params = metastore.configuration.connection
    |> Map.put("vault_role", metastore.vault_role)
    |> Map.put("vault_database", metastore.vault_database)
    |> JumpWire.Proxy.Postgres.Setup.postgrex_params(metastore.credentials, metastore.organization_id)

    with {:ok, db_opts, meta} <- params do
      with %{lease: id, duration: ttl} <- meta do
        Task.async(JumpWire.Proxy.Storage.Vault, :renew, [id, ttl])
      end
      Postgrex.start_link(db_opts)
    end
  end

  @impl true
  def fetch(conn, key, %{configuration: opts}) do
    query = """
    SELECT #{opts.value_field}
    FROM #{opts.table}
    WHERE #{opts.key_field} = $1
    """

    key = deserialize_value(key)

    case Postgrex.query(conn, query, [key]) do
      {:ok, %{rows: [[value]]}} -> {:ok, value}
      _ -> :error
    end
  end

  @impl true
  def fetch_all(_, [], _), do: {:ok, []}

  @impl true
  def fetch_all(conn, keys, %{configuration: opts}) do
    conditional = keys
    |> Stream.with_index(1)
    |> Stream.map(fn {_, i} -> "#{opts.key_field} = $#{i}" end)
    |> Enum.join(" OR ")

    query = """
    SELECT #{opts.key_field}, #{opts.value_field}
    FROM #{opts.table}
    WHERE #{conditional}
    """

    keys = Enum.map(keys, &deserialize_value/1)

    case Postgrex.query(conn, query, keys) do
      {:ok, %{rows: rows}} ->
        data = rows |> Stream.map(fn [k, v] -> {k, v} end) |> Map.new()
        {:ok, data}

      _ ->
        :error
    end
  end

  defp deserialize_value(value) when is_binary(value) do
    # TODO: it would be more performant to keep the raw value from the postgres proxy instead of letting
    # the type be serialized and deserialized

    case Ecto.UUID.dump(value) do
      {:ok, raw} -> raw
      _ -> value
    end
  end
  defp deserialize_value(value), do: value
end
