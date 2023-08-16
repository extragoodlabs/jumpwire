defmodule JumpWire.Policy.Tokenize do
  @moduledoc """
  Transform fields with a consistent hash.
  """

  alias JumpWire.Record
  alias JumpWire.Policy
  require Logger

  @behaviour JumpWire.Policy

  @impl true
  def handle(record, matches, policy, request) do
    manifest_id = Map.get(request, :manifest_id)
    case hash_fields(record, matches, policy, manifest_id) do
      {:ok, record = %Record{}} -> {:cont, record}
      err -> {:halt, err}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp hash_fields(record = %Record{}, fields, %Policy{organization_id: org_id}, manifest_id) do
    format = record.label_format
    Enum.reduce_while(fields, {:ok, record}, fn {field, value}, {:ok, acc} ->
      labels = Map.get(record.labels, field, [])
      labels = Record.load_labels(value, labels)
      table_id =
        case get_in(record.extra_field_info, [:tables, field]) do
          id when is_integer(id) -> <<id::32>>
          id -> id
        end

      field_name =
        case get_in(record.extra_field_info, [:aliases, field]) do
          nil -> field
          alias_name -> alias_name
        end

      cond do
        is_atom(value) ->
          # The record doesn't have actual data, most likely coming from a DB query rather than the result
          {:cont, {:ok, acc}}

        :token in labels ->
          {:cont, {:ok, acc}}

        is_nil(manifest_id) ->
          Logger.error("Missing manifest for tokenizing field")
          {:halt, {:error, :not_found}}

        is_nil(table_id) ->
          Logger.error("Missing table ID for tokenizing field")
          {:halt, {:error, :not_found}}

        true ->
          token = %JumpWire.Token{
            manifest_id: manifest_id,
            table_id: table_id,
            field: field_name,
            value: value,
          } |> JumpWire.Token.encode()

          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case JumpWire.Vault.encode_and_encrypt(value, %{labels: labels}, org_id) do
            {:ok, value} ->
              policies = Map.update(acc.policies, :tokenized, [field], fn paths -> [field | paths] end)
              JumpWire.GlobalConfig.put(:tokens, {org_id, manifest_id, {table_id, field, token}}, value)
              {:ok, data} = Record.put_by_path(acc.data, field, token, format)
              acc = %{acc | data: data, policies: policies}
              {:cont, {:ok, acc}}
            err -> {:halt, err}
          end
      end
    end)
  end
end
