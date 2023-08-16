defmodule JumpWire.Policy.Encrypt do
  @moduledoc """
  Any matching unencrypted fields will be encrypted.
  """

  alias JumpWire.Record
  require Logger

  @behaviour JumpWire.Policy

  @impl true
  def handle(record, matches, policy, _request) do
    org_id = policy.organization_id
    key = policy.encryption_key

    case encrypt_fields(record, matches, org_id, key) do
      {:ok, record = %Record{}} -> {:cont, record}
      {:ok, data} -> {:cont, %{record | data: data}}
      err -> {:halt, err}
    end
  end

  defp encrypt_fields(record, fields, org_id, key) do
    format = record.label_format
    Enum.reduce_while(fields, {:ok, record}, fn {path, value}, {:ok, acc} ->
      labels = Map.get(record.labels, path, [])
      labels = Record.load_labels(value, labels)

      cond do
        is_atom(value) ->
          # The record doesn't have actual data, most likely coming from a DB query rather than the result
          {:cont, {:ok, acc}}

        :encrypted in labels ->
          {:cont, {:ok, acc}}

        true ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case JumpWire.Vault.encode_and_encrypt(value, %{labels: labels}, org_id, key) do
            {:ok, value} ->
              policies = Map.update(acc.policies, :encrypted, [path], fn paths -> [path | paths] end)
              {:ok, data} = Record.put_by_path(acc.data, path, value, format)
              acc = %{acc | data: data, policies: policies}
              {:cont, {:ok, acc}}

            err ->
              Logger.error("Unable to encrypt fields: #{inspect err}")
              {:halt, err}
          end
      end
    end)
  end
end
