defmodule JumpWire.Manifest do
  use JumpWire.Schema
  require Logger
  import Ecto.Changeset
  alias __MODULE__

  @proxy_types [:postgresql, :mysql]

  typed_embedded_schema null: false do
    field :name, :string
    field :root_type, Ecto.Enum, values: [:jumpwire | @proxy_types]
    field :configuration, :map
    field :credentials, :map, default: nil, null: true, redact: true
    field :classification, :string
    field :organization_id, :string
  end

  def proxy_types(), do: @proxy_types

  def from_json(manifest, org_id) do
    %Manifest{organization_id: org_id}
    |> cast(manifest, [:id, :name, :root_type, :configuration, :classification, :organization_id, :credentials])
    |> validate_required([:id, :name, :root_type, :organization_id])
    |> apply_action(:insert)
    |> JumpWire.Credentials.load()
  end

  def reverse_token(manifest = %Manifest{root_type: :postgresql}, token) do
    JumpWire.Proxy.Postgres.Token.reverse_token(manifest, token)
  end

  def reverse_token(manifest = %Manifest{root_type: :mysql}, token) do
    JumpWire.Proxy.MySQL.Token.reverse_token(manifest, token)
  end

  def reverse_token(_, _, _, _), do: {:error, :not_found}

  def hook(manifest = %Manifest{root_type: :postgresql}, :delete) do
    Task.Supervisor.async_nolink(JumpWire.ProxySupervisor, fn ->
      JumpWire.Tracer.context(org_id: manifest.organization_id, manifest: manifest.id)
      Logger.debug("Running delete hooks for postgres database")

      case JumpWire.Proxy.Postgres.Setup.disable_database(manifest) do
        :ok ->
          :ok

        err ->
          Logger.error("Failed to disable encryption for postgres database: #{inspect(err)}")
          err
      end
    end)
  end

  def hook(manifest = %Manifest{root_type: :postgresql}, _lifecycle) do
    Task.Supervisor.async_nolink(JumpWire.ProxySupervisor, fn ->
      JumpWire.Tracer.context(org_id: manifest.organization_id, manifest: manifest.id)
      Logger.debug("Running upsert hooks for postgres database")

      case JumpWire.Proxy.Postgres.Manager.start_supervised(manifest) do
        {:ok, pid} ->
          {:ok, pid}

        err ->
          Logger.error("Failed to start PostgreSQL manager. Schema updates will not be processed: #{inspect(err)}")
          err
      end
    end)
  end

  def hook(manifest = %Manifest{root_type: :mysql}, :delete) do
    Task.Supervisor.async_nolink(JumpWire.ProxySupervisor, fn ->
      JumpWire.Tracer.context(org_id: manifest.organization_id, manifest: manifest.id)
      Logger.debug("Running delete hooks for mysql database")

      case JumpWire.Proxy.MySQL.Setup.disable_database(manifest) do
        :ok ->
          :ok

        err ->
          Logger.error("Failed to disable encryption for mysql database: #{inspect(err)}")
          err
      end
    end)
  end

  def hook(manifest = %Manifest{root_type: :mysql}, _lifecycle) do
    Task.Supervisor.async_nolink(JumpWire.ProxySupervisor, fn ->
      JumpWire.Tracer.context(org_id: manifest.organization_id, manifest: manifest.id)
      Logger.debug("Running upsert hooks for mysql database")

      case JumpWire.Proxy.MySQL.Setup.enable_database(manifest) do
        :ok ->
          :ok

        err ->
          Logger.error("Failed to enable encryption for mysql database: #{inspect(err)}")
          err
      end
    end)
  end

  def hook(_manifest, _lifecycle), do: Task.completed(:ok)

  @doc """
  Retrieve the database name from the configuration of a SQL manifest.
  """
  def database_name(%Manifest{configuration: config}) do
    Map.get(config, "database")
  end

  def extract_schemas(manifest = %Manifest{root_type: :postgresql}) do
    JumpWire.Manifest.Postgresql.extract(manifest)
  end

  def extract_schemas(manifest = %Manifest{root_type: :mysql}) do
    JumpWire.Manifest.MySQL.extract(manifest)
  end

  def extract_schemas(_), do: {:error, :unknown_type}

  @doc """
  Find policies that would apply the specified handling to data entering the database. For
  matching policies, the labels it applies to are returned.
  """
  def policy_labels(manifest) do
    default = [encrypt: MapSet.new(), tokenize: MapSet.new()]

    JumpWire.Policy.list_all(manifest.organization_id)
    |> Stream.filter(fn %{handling: handling} ->
      Enum.member?([:encrypt, :tokenize], handling)
    end)
    |> Stream.reject(fn %{allowed_classification: classification} ->
      not is_nil(classification) and classification == manifest.classification
    end)
    |> Enum.reduce(default, fn p, acc ->
      update_in(acc, [p.handling], fn labels -> MapSet.put(labels, p.label) end)
    end)
  end

  @doc """
  Return all the manifests for the specified organization.
  """
  def all(org_id) do
    JumpWire.GlobalConfig.all(:manifests, {org_id, :_})
  end

  @spec fetch(String.t(), String.t() | :all) :: [Manifest.t()] | {:error, :not_found} | {:ok, [Manifest.t()]}
  @doc """
  Attempt to find and return a manifest from the provided ID. A special
  ID value of `router` will return a nil manifest with no error.
  This is intended as a placeholder for further processing.
  """
  def fetch(_org_id, "router"), do: {:ok, nil}

  def fetch(org_id, manifest_id) do
    JumpWire.GlobalConfig.fetch(:manifests, {org_id, manifest_id})
  end

  @doc """
  Find all manifests with a matching type for this org.
  """
  def get_by_type(org_id, type) do
    JumpWire.GlobalConfig.all(:manifests, {org_id, :_})
    |> Enum.filter(fn m ->
      m.root_type == type || to_string(m.root_type) == type
    end)
  end

  @doc """
  Put a manifest into the global config.
  """
  def put(org_id, manifest) do
    JumpWire.GlobalConfig.put(:manifests, {org_id, manifest.id}, manifest)
  end

  @doc """
  Delete the manifest from the global config.
  """
  def delete(org_id, manifest_id) do
    JumpWire.GlobalConfig.delete(:manifests, {org_id, manifest_id})
  end
end
