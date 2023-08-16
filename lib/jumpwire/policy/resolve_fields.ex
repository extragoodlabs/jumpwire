defmodule JumpWire.Policy.ResolveFields do
  @moduledoc """
  Replace matching fields using a different datastore than the one being queried.
  """

  use JumpWire.Schema
  alias JumpWire.Record
  import Ecto.Changeset
  require Logger

  @behaviour JumpWire.Policy

  @primary_key false
  typed_embedded_schema null: false do
    field :metastore_id, :string
    field :route_key, :string
    field :route_values, {:array, :string}
    field :type, Ecto.Atom, default: :resolve_fields
  end

  @doc false
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:type, :metastore_id, :route_key, :route_values])
    |> validate_required([:metastore_id, :route_key, :route_values])
  end

  @impl true
  def handle(record, matches, policy, _request) do
    {route_field, _} =
      Enum.find(record.labels, {nil, []}, fn {_path, labels} ->
        Enum.member?(labels, policy.configuration.route_key)
      end)

    route_field =
      case route_field do
        "$." <> field -> field
        field -> field
      end

    with field when not is_nil(field) <- route_field,
         {:ok, value} <- Map.fetch(record.data, field),
           true <- Enum.member?(policy.configuration.route_values, value) do
      resolve_fields(record, matches, policy)
    else
      _ -> {:cont, record}
    end
  end

  defp resolve_fields(record, fields, policy) do
    Logger.debug("Resolving fields from a remote data source")
    key = {policy.organization_id, policy.configuration.metastore_id}

    with {:ok, store} <- JumpWire.GlobalConfig.fetch(:metastores, key),
         {:ok, conn} <- JumpWire.Metastore.connect(store) do
      # NB: we can reduce the number of network RT by calling JumpWire.Metastore.fetch_all/3 with
      # all of the values from `fields`. However, this has some edge cases that are tricky to handle
      # right now. The main limitation is that the key could be repeated across multiple fields,
      # and we would need to figure out how to map the result from the metastore query back to that.
      Enum.reduce_while(fields, {:cont, record}, fn {path, value}, {:cont, acc} ->
        labels = Map.get(record.labels, path, [])
        labels = Record.load_labels(value, labels)
        if :resolved in labels do
          {:cont, {:cont, acc}}
        else
          case resolve_field(acc, conn, path, value, store) do
            {:ok, record} -> {:cont, {:cont, record}}
            err -> {:halt, {:halt, err}}
          end
        end
      end)
    else
      _ ->
        Logger.error("Failed to connect to metastore")
        {:halt, {:error, :metastore_failure}}
    end
  end

  defp resolve_field(record, conn, path, value, store) do
    case JumpWire.Metastore.fetch(conn, value, store) do
      {:ok, value} ->
        policies = Map.update(record.policies, :resolved_fields, [path], fn paths -> [path | paths] end)
        {:ok, data} = Record.put_by_path(record.data, path, value, record.label_format)
        record = %{record | data: data, policies: policies}
        {:ok, record}

      _ ->
        Logger.error("Failed to fetch field from metastore")
        {:error, :metastore_failure}
    end
  end
end
