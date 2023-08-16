defmodule JumpWire.Proxy.Storage.File do
  @moduledoc """
  Store credentials in a local JSON file. This is extremely
  insecure and only useful for local development.
  """

  @behaviour JumpWire.Proxy.Storage

  @impl JumpWire.Proxy.Storage
  def enabled?() do
    Application.get_env(:jumpwire, __MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  @impl JumpWire.Proxy.Storage
  def store_credentials(db) do
    file = db_path(db.organization_id, db.id)
    directory = Path.dirname(file)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(file, Jason.encode!(db.credentials)) do
      {:ok, db}
    end
  end

  @impl JumpWire.Proxy.Storage
  def load_credentials(db) do
    file = db_path(db.organization_id, db.id)
    with {:ok, raw} <- File.read(file),
         {:ok, creds} <- Jason.decode(raw) do
      db = %{db | credentials: creds}
      {:ok, db}
    end
  end

  @impl JumpWire.Proxy.Storage
  def delete_credentials(db) do
    file = db_path(db.organization_id, db.id)
    with :ok <- File.rm(file) do
      {:ok, db}
    end
  end

  defp db_path(org_id, id) do
    Path.join([
      "jumpwire_credentials",
      org_id,
      "manifest",
      id,
    ])
  end
end
