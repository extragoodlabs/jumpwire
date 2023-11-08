defmodule JumpWire.API.PoliciesRouter do
  @moduledoc """
  A Plug.Router for handling internal API calls with policies.
  """

  use Plug.Router
  use Honeybadger.Plug
  use Plug.ErrorHandler
  import JumpWire.Router.Helpers
  require Logger

  @sso_module Application.compile_env(:jumpwire, [:sso, :module])

  plug :match
  plug :put_secret_key_base

  plug Plug.Session,
    store: :cookie,
    key: "_jumpwire_key",
    signing_salt: "I5bC7Dc3"

  plug :dispatch

  get "/" do
    case @sso_module.fetch_active_assertion(conn) do
      {:ok, assertion} ->
        body = JumpWire.Policy.list_all(assertion.computed.org_id)
        send_json_resp(conn, 200, body)

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  post "/" do
    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
         uuid <- Uniq.UUID.uuid4(),
         updated <- conn.body_params |> Map.put("id", uuid),
         {:ok, group} <- JumpWire.Policy.from_json(updated, assertion.computed.org_id),
         {:ok, group} <- JumpWire.Policy.put(assertion.computed.org_id, group) do
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

    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
         {:ok, group} <- JumpWire.Policy.fetch(assertion.computed.org_id, id) do
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

    case @sso_module.fetch_active_assertion(conn) do
      {:ok, assertion} ->
        JumpWire.Policy.delete(assertion.computed.org_id, id)
        send_json_resp(conn, 200, %{message: "Group deleted"})

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  match _ do
    send_resp(conn, 404, %{error: "not found"})
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    body = %{error: "an unknown error occurred", status: conn.status}
    send_json_resp(conn, conn.status, body)
  end

  defp send_json_resp(conn, status, body) do
    send_resp(conn, status, Jason.encode!(body))
  end
end
