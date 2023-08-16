defmodule JumpWire.Proxy.Postgres.Token do
  alias JumpWire.Proxy.Postgres
  alias JumpWire.Manifest

  def reverse_token(manifest = %Manifest{organization_id: org_id}, token = %JumpWire.Token{}) do
    Postgres.Setup.with_pooled_conn(manifest, {:error, :not_found}, fn conn ->
      table = oid_to_relname(conn, manifest, token.table_id)
      query = """
      SELECT #{token.field}_jw_enc FROM #{table} WHERE #{token.field} = $1 LIMIT 1
      """

      case Postgrex.query!(conn, query, [token.encoded]) do
        %{rows: [[encrypted]]} ->
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

  defp oid_to_relname(conn, manifest = %Manifest{}, <<oid::32>>) do
    # turn OID into usable name
    key = {manifest.organization_id, manifest.id, oid}
    case JumpWire.GlobalConfig.fetch(:manifest_metadata, key) do
      {:ok, relname} ->
        relname

      _ ->
        %{rows: [[relname]]} = Postgrex.query!(conn, "SELECT relname FROM pg_class WHERE oid = $1", [oid])
        # NB: this table will not be cleaned up when manifests are
        # deleted. The data size is very small though, and it should be
        # rare to delete a manifest that has been used to create tokens.
        JumpWire.GlobalConfig.put(:manifest_metadata, key, relname)
        relname
    end
  end
end
