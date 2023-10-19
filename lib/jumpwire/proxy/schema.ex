defmodule JumpWire.Proxy.Schema do
  use JumpWire.Schema
  import Ecto.Changeset
  alias JumpWire.Manifest
  alias __MODULE__
  require Logger

  typed_embedded_schema null: false do
    field :name, :string
    field :manifest_id, :string
    field :fields, :map
    field :organization_id, :string
    field :schema, :map, default: %{"properties" => %{}}
  end

  def from_json(schema, org_id) do
    schema =
      %Schema{organization_id: org_id}
      |> cast(schema, [:id, :name, :manifest_id, :fields, :organization_id, :schema])
      |> update_change(:fields, &normalize_fields/1)
      |> validate_required([:id, :name, :manifest_id, :fields, :organization_id])

    with {:ok, schema} <- apply_action(schema, :insert),
         %Manifest{} <- JumpWire.GlobalConfig.get(:manifests, {org_id, schema.manifest_id}) do
      {:ok, schema}
    else
      nil ->
        # JumpWire doesn't have the Manifest for the Schema we are loading.
        # This scenario may happen when the web controller is managing the
        # keys and, for whatever reason, it is unable to retrieve the
        # Manifest data from an upstream secrets manager.
        schema_id = get_change(schema, :id)
        manifest_id = get_change(schema, :manifest_id)
        Logger.error("Unable to find manifest #{manifest_id} for schema #{schema_id}")
        {:error, :manifest_not_found}

      error ->
        error
    end
  end

  defp normalize_fields(fields) do
    fields
    |> Stream.map(fn
      {path, label} when is_binary(label) -> {path, [label]}
      field -> field
    end)
    |> Stream.map(fn
      field = {"$." <> _path, _labels} -> field
      {path, labels} -> {"$.#{path}", labels}
      field -> field
    end)
    |> Map.new()
  end

  def hook(schema = %Schema{}, lifecycle) when lifecycle in [:insert, :update] do
    Task.Supervisor.async_nolink(JumpWire.ProxySupervisor, fn ->
      JumpWire.Tracer.context(org_id: schema.organization_id, manifest: schema.manifest_id)
      Logger.debug("Running upsert hooks for schema #{schema.id}")

      manifest = JumpWire.GlobalConfig.get(:manifests, {schema.organization_id, schema.manifest_id})

      mod =
        case manifest.root_type do
          :postgresql ->
            JumpWire.Proxy.Postgres.Setup

          :mysql ->
            JumpWire.Proxy.MySQL.Setup

          _ ->
            Logger.warn("Unhandled root type #{manifest.root_type}")
            nil
        end

      unless is_nil(mod) do
        mod.on_schema_upsert(manifest, schema)
      end
    end)
  end

  def hook(_schema, _lifecycle), do: Task.completed(:ok)

  def fetch(org_id, manifest_id, schema_id) do
    JumpWire.GlobalConfig.fetch(:proxy_schemas, {org_id, manifest_id, schema_id})
  end

  @doc """
  Put a manifest into the global config.
  """
  def put(org_id, schema) do
    JumpWire.GlobalConfig.put(:proxy_schemas, {org_id, schema.manifest_id, schema.id}, schema)
  end

  @doc """
  List all known schemas for a given org.
  """
  def list_all(org_id) do
    JumpWire.GlobalConfig.all(:proxy_schemas, {org_id, :_, :_})
  end

  @doc """
  List all known schemas for a manifest.
  """
  def list_all(org_id, manifest_id) do
    JumpWire.GlobalConfig.all(:proxy_schemas, {org_id, manifest_id, :_})
  end

  @doc """
  Delete the schema from the global config.
  """
  def delete(org_id, manifest_id, id) do
    JumpWire.GlobalConfig.delete(:proxy_schemas, {org_id, manifest_id, id})
  end

  def denormalize_schema_fields(schema) do
    denormalize_fields(schema.fields)
  end

  defp denormalize_fields(fields) when is_map(fields) do
    fields
    |> Enum.map(&denormalize_field/1)
    |> Map.new()
  end

  defp denormalize_fields(fields) when is_list(fields), do: Enum.map(fields, &denormalize_fields/1)
  defp denormalize_fields(value), do: value

  defp denormalize_field({"$." <> path, [label]}), do: {path, label}
  defp denormalize_field({"$." <> path, labels}), do: {path, denormalize_fields(labels)}
  defp denormalize_field({path, labels}), do: {denormalize_fields(path), denormalize_fields(labels)}
end
