defmodule JumpWire.API.PoliciesRouter do
  @moduledoc """
  A Plug.Router for handling internal API calls with policies.
  """

  use Plug.Router
  require Logger
  import JumpWire.Router.Helpers

  plug :match
  plug :dispatch

  get "/" do
    case fetch_active_assertion(conn) do
      {:ok, assertion} ->
        body = JumpWire.Policy.list_all(assertion.computed.org_id)
        send_json_resp(conn, 200, body)

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  post "/" do
    with {:ok, assertion} <- fetch_active_assertion(conn),
         uuid <- Uniq.UUID.uuid4(),
         updated <- conn.body_params |> Map.put("id", uuid),
         {:ok, policy} <- JumpWire.Policy.from_json(updated, assertion.computed.org_id),
         {:ok, policy} <- JumpWire.Policy.put(:insert, assertion.computed.org_id, policy) do
      send_json_resp(conn, 201, policy)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      {:error, reason} ->
        Logger.error("Failed to process policy: #{inspect(reason)}")
        send_resp(conn, 400, "Failed to process policy")

      error ->
        Logger.error("Failed to create policy: #{inspect(error)}")
        send_json_resp(conn, 500, %{error: "Failed to create policy"})
    end
  end

  put "/:id" do
    id = String.downcase(id)

    with {:ok, assertion} <- fetch_active_assertion(conn),
         # verify the policy exists
         _ <- JumpWire.Policy.fetch(assertion.computed.org_id, id),
         body <- conn.body_params,
         {:ok, policy} <- JumpWire.Policy.from_json(body, assertion.computed.org_id),
         {:ok, policy} <- JumpWire.Policy.put(:update, assertion.computed.org_id, policy) do
      send_json_resp(conn, 200, policy)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      {:error, reason} ->
        Logger.error("Failed to process policy: #{inspect(reason)}")
        send_resp(conn, 400, "Failed to process policy")

      error ->
        Logger.error("Failed to update policy: #{inspect(error)}")
        send_json_resp(conn, 500, %{error: "Failed to update policy"})
    end
  end

  get "/:id" do
    id = String.downcase(id)

    with {:ok, assertion} <- fetch_active_assertion(conn),
         {:ok, policy} <- JumpWire.Policy.fetch(assertion.computed.org_id, id) do
      send_json_resp(conn, 200, policy)
    else
      :error ->
        send_json_resp(conn, 401, %{error: "SSO login required"})

      _ ->
        send_json_resp(conn, 404, %{error: "policy not found"})
    end
  end

  delete "/:id" do
    id = String.downcase(id)

    case fetch_active_assertion(conn) do
      {:ok, assertion} ->
        JumpWire.Policy.delete(assertion.computed.org_id, id)
        send_json_resp(conn, 200, %{message: "policy deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  match _ do
    send_resp(conn, 404, %{error: "not found"})
  end
end
