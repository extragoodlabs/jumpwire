defmodule JumpWire.Proxy.MySQL.Token do
  alias JumpWire.Proxy.MySQL
  alias JumpWire.Manifest

  def reverse_token(manifest = %Manifest{organization_id: org_id}, token = %JumpWire.Token{}) do
    MySQL.Setup.with_pooled_conn(manifest, {:error, :not_found}, fn conn ->
      query = """
      SELECT #{token.field}_jw_enc FROM #{token.table_id} WHERE #{token.field} = ? LIMIT 1
      """

      case MyXQL.query(conn, query, [token.encoded]) do
        {:ok, %{rows: [[encrypted]]}} ->
          JumpWire.GlobalConfig.put(
            :tokens,
            {org_id, manifest.id, {token.table_id, token.field, token.encoded}},
            encrypted
          )

          JumpWire.Vault.decrypt_and_decode(encrypted, org_id)
        _ -> {:error, :not_found}
      end
    end)
  end
end
