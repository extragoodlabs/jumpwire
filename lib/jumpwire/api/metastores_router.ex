defmodule JumpWire.API.MetastoresRouter do
  @moduledoc """
  A Plug.Router for handling internal API calls with authentication
  relating to Metastores.
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
        body = JumpWire.Metastore.list_all(assertion.computed.org_id)
        send_json_resp(conn, 200, body)

      _ ->
        send_json_resp(conn, 401, %{error: "SSO login required"})
    end
  end

  post "/" do
    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
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

    with {:ok, assertion} <- @sso_module.fetch_active_assertion(conn),
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

    case @sso_module.fetch_active_assertion(conn) do
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

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    body = %{error: "an unknown error occurred", status: conn.status}
    send_json_resp(conn, conn.status, body)
  end

  defp send_json_resp(conn, status, body) do
    send_resp(conn, status, Jason.encode!(body))
  end
end
