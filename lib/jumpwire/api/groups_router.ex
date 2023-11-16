defmodule JumpWire.API.GroupsRouter do
  @moduledoc """
  A Plug.Router for handling internal API calls with authentication.
  """

  use Plug.Router
  require Logger
  import JumpWire.Router.Helpers

  plug :match
  plug :dispatch

  get "/" do
    case fetch_active_assertion(conn) do
      {:ok, assertion} ->
        body = JumpWire.Group.list_all(assertion.computed.org_id)
        send_json_resp(conn, 200, body)

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  post "/" do
    with {:ok, assertion} <- fetch_active_assertion(conn),
         uuid <- Uniq.UUID.uuid4(),
         updated <- conn.body_params |> Map.put("id", uuid),
         {:ok, group} <- JumpWire.Group.from_json({updated["name"], updated}, assertion.computed.org_id),
         {:ok, group} <- JumpWire.Group.put(assertion.computed.org_id, group) do
      send_json_resp(conn, 201, group)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      {:error, reason} ->
        Logger.error("Failed to process group: #{inspect(reason)}")
        send_resp(conn, 400, "Failed to process group")

      error ->
        Logger.error("Failed to create group: #{inspect(error)}")
        send_json_resp(conn, 500, %{error: "Failed to create group"})
    end
  end

  get "/:id" do
    id = String.downcase(id)

    with {:ok, assertion} <- fetch_active_assertion(conn),
         {:ok, group} <- JumpWire.Group.fetch(assertion.computed.org_id, id) do
      send_json_resp(conn, 200, group)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      _ ->
        send_json_resp(conn, 404, %{error: "Group not found"})
    end
  end

  delete "/:id" do
    id = String.downcase(id)

    case fetch_active_assertion(conn) do
      {:ok, assertion} ->
        JumpWire.Group.delete(assertion.computed.org_id, id)
        send_json_resp(conn, 200, %{message: "Group deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  match _ do
    send_resp(conn, 404, %{error: "not found"})
  end
end
