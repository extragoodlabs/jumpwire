defmodule JumpWire.Policy.Detokenize do
  @moduledoc """
  Transform fields with a consistent hash.
  """

  alias JumpWire.Record
  alias JumpWire.Policy
  require Logger

  @behaviour JumpWire.Policy

  @impl true
  def handle(record, matches, policy, _request) do
    case dehash_fields(record, matches, policy) do
      {:ok, record = %Record{}} -> {:cont, record}
      err -> {:halt, err}
    end
  end

  defp dehash_fields(record = %Record{}, fields, %Policy{organization_id: org_id}) do
    fields
    |> Stream.filter(fn {_, token} -> is_binary(token) end)
    |> Stream.filter(fn {_, token} -> String.starts_with?(token, "SldUT0tO") end)
    |> Enum.reduce_while({:ok, record}, fn {path, token}, {:ok, record} ->
      with {:ok, token} <- JumpWire.Token.decode(token),
           {:ok, value, decoded_labels} <- JumpWire.Token.reverse_token(org_id, token) do
        {:ok, data} = Record.put_by_path(record.data, path, value, record.label_format)
        field_labels = record.labels
        |> Map.get(path, [])
        |> Stream.concat(decoded_labels)
        |> Enum.dedup()
        labels = Map.put(record.labels, path, field_labels)
        policies = Map.update(record.policies, :detokenized, [path], fn paths -> [path | paths] end)
        record = %{record | labels: labels, data: data, policies: policies}
        {:cont, {:ok, record}}
      else
        {:error, :not_found} ->
          {:cont, {:ok, record}}
        err ->
          {:halt, err}
      end
    end)
  end
end
