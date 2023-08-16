defmodule JumpWire.Token.Router do
  require Logger
  use Plug.Router
  use Plug.ErrorHandler
  alias JumpWire.Record

  plug :fetch_query_params
  # VerifyAuthorization plug validates the auth token, including organization_id and manifest_id
  plug JumpWire.Token.VerifyAuthorization
  # VerifyToken plug verifies the token and base64 decodes
  plug JumpWire.Token.VerifyToken
  plug :match
  plug :dispatch

  get "/" do
    organization_id = conn.assigns.organization_id
    authz_manifest_id = conn.assigns.manifest_id

    policies = JumpWire.Policy.list_all(organization_id)

    # Note there are two manifests at work here, one for the proxy that is attempting to read data,
    # and another associated with the schema that has labels
    with {:ok, token} <- JumpWire.Token.decode(conn.assigns.decode64_token),
         table <- decode_tableid(token.table_id),
         {:ok, schema_id} <- JumpWire.GlobalConfig.fetch(:reverse_schemas, {organization_id, table}),
         {:ok, authz_manifest} <- JumpWire.GlobalConfig.fetch(:manifests, {organization_id, authz_manifest_id}) do
      info = %{
        module: __MODULE__,
        classification: authz_manifest.classification,
        type: :token_api_get,
        # TODO: fetch from conn
        request_id: Uniq.UUID.uuid4(),
        upstream_id: token.manifest_id,
        organization_id: organization_id,
        attributes: MapSet.new(["*", "classification:#{authz_manifest.classification}"]),
      }

      schema =
        case JumpWire.GlobalConfig.match_all(:proxy_schemas, {organization_id, token.manifest_id, :_}, %{id: schema_id}) do
          [] -> nil
          [{_, schema} | _] -> schema
        end
      data = %{token.field => conn.assigns.param_token}

      res = cond do
        is_nil(schema) ->
          {:error, :not_found}

        map_size(schema.fields) == 0 ->
          # shortcut to skip policies if there are no labels on the data
          Logger.debug("No schema field labels, skipping policies")
          %Record{data: data, source: __MODULE__}

        true ->
          record = %Record{
            data: data,
            labels: schema.fields,
            source: __MODULE__
          }
          policies
          |> Enum.reduce_while(record, fn p, acc -> JumpWire.Policy.apply_policy(p, acc, info) end)
      end

      case res do
        :blocked ->
          send_error(conn, :unauthorized, "Request blocked")

        {:error, :not_found} ->
          Logger.error("Token metadata does not match a schema")
          send_error(conn, :bad_request, "Invalid token")

        {:error, err} ->
          Logger.error("Error applying policy: #{inspect(err)}")
          send_error(conn, :internal_server_error, "Policy error")

        :error ->
          Logger.error("Unknown error applying policy")
          send_error(conn, :internal_server_error, "Policy error")

        %Record{data: data} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(:ok, Jason.encode!(data))
      end
    else
      err ->
        Logger.warn("Could not decode token: #{inspect(err)}")
        send_error(conn, :internal_server_error, "An unknown error has occurred")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp decode_tableid(table_id) do
    case table_id do
      <<table::32>> -> table
      _ -> table_id
    end
  end

  defp send_error(conn, status, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{msg: reason}))
    |> halt()
  end
end
