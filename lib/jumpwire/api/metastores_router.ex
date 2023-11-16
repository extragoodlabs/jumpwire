defmodule JumpWire.API.MetastoresRouter do
  @moduledoc """
  A Plug.Router for handling internal API calls with authentication
  relating to Metastores.
  """

  use Plug.Router
  import JumpWire.Router.Helpers
  require Logger

  plug :match
  plug :dispatch

  get "/" do
    case fetch_active_assertion(conn) do
      {:ok, assertion} ->
        body = JumpWire.Metastore.list_all(assertion.computed.org_id)
        send_json_resp(conn, 200, body)

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  post "/" do
    with {:ok, assertion} <- fetch_active_assertion(conn),
         uuid <- Uniq.UUID.uuid4(),
         updated <- conn.body_params |> Map.put("id", uuid),
         {:ok, metastore} <- JumpWire.Metastore.from_json(updated, assertion.computed.org_id),
         {:ok, metastore} <- JumpWire.Metastore.put(assertion.computed.org_id, metastore) do
      send_json_resp(conn, 201, metastore)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      {:error, reason} ->
        Logger.error("Failed to process metastore: #{inspect(reason)}")
        send_resp(conn, 400, "Failed to process metastore")

      error ->
        Logger.error("Failed to create metastore: #{inspect(error)}")
        send_json_resp(conn, 500, %{error: "Failed to create metastore"})
    end
  end

  get "/:id" do
    id = String.downcase(id)

    with {:ok, assertion} <- fetch_active_assertion(conn),
         {:ok, metastore} <- JumpWire.Metastore.fetch(assertion.computed.org_id, id) do
      send_json_resp(conn, 200, metastore)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      _ ->
        send_json_resp(conn, 404, %{error: "metastore not found"})
    end
  end

  delete "/:id" do
    id = String.downcase(id)

    case fetch_active_assertion(conn) do
      {:ok, assertion} ->
        JumpWire.Metastore.delete(assertion.computed.org_id, id)
        send_json_resp(conn, 200, %{message: "metastore deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  match _ do
    send_resp(conn, 404, %{error: "not found"})
  end
end
