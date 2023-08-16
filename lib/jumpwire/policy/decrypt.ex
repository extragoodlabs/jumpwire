defmodule JumpWire.Policy.Decrypt do
  @moduledoc """
  Matching fields that are already encrypted will be decrypted if the data
  is being sent to a client with an allowed data classification category.
  """

  alias JumpWire.Record
  require Logger

  @behaviour JumpWire.Policy

  @impl true
  def handle(record, matches, policy, _request) do
    case decrypt_fields(record, matches, policy.organization_id) do
      {:ok, record = %Record{}} -> {:cont, record}
      {:ok, data} -> {:cont, %{record | data: data}}
      err -> {:halt, err}
    end
  end

  defp decrypt_fields(record, fields, org_id) do
    Enum.reduce_while(fields, {:ok, record}, fn {path, value}, {:ok, record} ->
      policies = Map.update(record.policies, :decrypted, [path], fn paths -> [path | paths] end)

      case JumpWire.Vault.decrypt_and_decode(value, org_id) do
        {:ok, value, decoded_labels} ->
          {:ok, data} = Record.put_by_path(record.data, path, value, record.label_format)
          field_labels = record.labels
          |> Map.get(path, [])
          |> Stream.concat(decoded_labels)
          |> Enum.dedup()
          labels = Map.put(record.labels, path, field_labels)
          record = %{record | labels: labels, data: data, policies: policies}
          {:cont, {:ok, record}}

        {:error, :invalid_format} ->
          Logger.debug("Attempted to decrypt data that was not encrypted")
          {:cont, {:ok, %{record | policies: policies}}}

        {:error, %Cloak.MissingCipher{}} ->
          Logger.warn("Attempted to decrypt data without correct key")
          {:cont, {:ok, record}}

        :error ->
          {:halt, {:error, :decryption_failed}}

        err ->
          {:halt, err}
      end
    end)
  end
end
