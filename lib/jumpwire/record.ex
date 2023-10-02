defmodule JumpWire.Record do
  @moduledoc """
  Structure and utility functions to encapsulate a piece of data as it is processed.
  """

  use TypedEctoSchema
  alias __MODULE__

  @primary_key false
  @derive Jason.Encoder
  typed_embedded_schema null: false, enforce: true do
    field :data, Ecto.Any
    field :source, :string
    field :source_data, Ecto.Any, enforce: false
    field :labels, {:map, {:array, :string}}, default: %{}
    field :label_format, Ecto.Enum, values: [:jsonp, :key], default: :jsonp
    field :policies, {:map, {:array, :string}}, default: %{}
    field :extra_field_info, :map, default: %{}
    field :attributes, Ecto.MapSet, default: MapSet.new(["*"])
  end

  @spec merge(Record.t, Record.t) :: Record.t
  def merge(record1, record2) do
    data = cond do
      is_list(record1.data) ->
        [record2.data | record1.data]
      is_map(record1.data) and is_map(record2.data) ->
        Map.merge(record1.data, record2.data)
      true ->
        [record2.data, record1.data]
    end

    labels = Enum.reduce(record2.labels, record2.labels, fn {k, v}, acc ->
      Map.update(acc, k, v, fn labels -> v ++ labels end)
    end)

    %{record1 | data: data, labels: labels}
  end

  def put(record, [key | path], value) do
    Map.update!(record, key, fn field -> put_in(field, path, value) end)
  end

  def update_data(record, fun) do
    Map.update!(record, :data, fun)
  end

  def put_by_path(data, path, value, :jsonp) do
    Warpath.update(data, path, fn _ -> value end)
  end
  def put_by_path(data, path, value, :key) do
    {:ok, Map.put(data, path, value)}
  end

  def delete_paths(record = %Record{label_format: format}, paths) do
    update_data(record, fn data ->
      Enum.reduce(paths, data, fn path, acc ->
        case format do
          :key -> Map.delete(acc, path)
          :jsonp ->
            {:ok, acc} = Warpath.delete(acc, path)
            acc
        end
      end)
    end)
  end

  @doc """
  Returns a data map containing only records that have the given label.
  """
  def filter_by_label(%Record{data: data, labels: labels, label_format: format}, label) do
    labels
    |> Stream.filter(fn {_path, labels} -> Enum.member?(labels, label) end)
    |> Stream.map(fn {path, _} -> path end)
    |> Stream.map(fn path ->
      case query_path(data, path, format) do
        {:ok, nil} -> nil
        {:ok, value} -> {path, value}
        _ -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Map.new()
  end

  defp query_path(data, path, :jsonp), do: Warpath.query(data, path)
  defp query_path(data, path, :key), do: Map.fetch(data, path)

  def load_labels(value, labels) do
    labels = concat_tokenized_labels(value, labels)
    if :peeked in labels do
      labels
    else
      concat_encrypted_labels(value, labels)
    end
  end

  defp concat_encrypted_labels(value, labels) do
    case JumpWire.Vault.peek_metadata(value) do
      {:ok, peeked} ->
        peeked |> Stream.concat(labels) |> Enum.dedup()

      _ -> labels
    end
  end

  defp concat_tokenized_labels("SldUT0tO" <> _, labels) do
    Enum.dedup([:token | labels])
  end
  defp concat_tokenized_labels(_value, labels), do: labels
end
