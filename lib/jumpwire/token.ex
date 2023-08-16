defmodule JumpWire.Token do
  use JumpWire.Schema
  alias __MODULE__

  typed_embedded_schema null: false do
    field :manifest_id, :string
    field :table_id, :string
    field :field, :string
    field :value, :string
    field :encoded, :string, null: true
  end

  @spec decode(binary) :: {:ok, Token.t} | {:error, any}
  def decode(<<"JWTOKN",
    36, manifest_id::binary-size(36),
    table_len, table_id::binary-size(table_len),
    field_len::32, field::binary-size(field_len),
    hash::binary>>
  ) do
    token = %Token{
      manifest_id: manifest_id,
      table_id: table_id,
      field: field,
      value: hash,
    }
    {:ok, token}
  end

  def decode(token) when is_binary(token) do
    with {:ok, blob} <- JumpWire.Base64.decode(token),
         {:ok, token_struct} <- decode(blob) do
      {:ok, %{token_struct | encoded: token}}
    end
  end

  def decode(_), do: {:error, :invalid}

  def encode(token = %Token{}) do
    field_len = byte_size(token.field)
    hash = :crypto.hash(:sha256, token.value)
    table_len = byte_size(token.table_id)

    token = <<"JWTOKN", 36, token.manifest_id::binary-size(36),
      table_len, token.table_id::binary, field_len::32, token.field::binary-size(field_len),
      hash::binary>>
    JumpWire.Base64.encode(token)
  end

  @doc """
  Attempt to retrieve the original value from a token.

  A cache is first checked for the token key. If found, an encrypted value will be returned
  and can be decrypted to the original value. If that fails a query will be made against a
  database for the encrypted value. The database to query is defined by the manifest_id
  encoded in the token.
  """
  @spec reverse_token(String.t, Token.t) :: {:ok, String.t, list} | {:error, atom}
  def reverse_token(org_id, token = %Token{}) do
    key = {token.table_id, token.field, token.encoded}

    case JumpWire.GlobalConfig.fetch(:tokens, {org_id, token.manifest_id, key}) do
      {:ok, encrypted} ->
        JumpWire.Vault.decrypt_and_decode(encrypted, org_id)

      _ ->
        JumpWire.GlobalConfig.get(:manifests, {org_id, token.manifest_id})
        |> JumpWire.Manifest.reverse_token(token)
    end
  end
end
