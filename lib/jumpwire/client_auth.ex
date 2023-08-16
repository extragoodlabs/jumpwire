defmodule JumpWire.ClientAuth do
  @moduledoc """
  A representation of a proxy client's authentication and authorization.
  The client can either be limited to a specific manifest or allowed
  on the entire cluster.
  """

  use JumpWire.Schema
  require Logger
  import Ecto.Changeset
  alias __MODULE__

  typed_embedded_schema null: false do
    field :name, :string
    field :classification, :string
    field :organization_id, :string
    field :identity_id, Ecto.UUID
    field :manifest_id, Ecto.UUID
    field :attributes, Ecto.MapSet, default: MapSet.new()
  end

  def from_json(attrs, org_id) do
    %ClientAuth{organization_id: org_id}
    |> cast(attrs, [:id, :name, :classification, :organization_id, :identity_id, :manifest_id, :attributes])
    |> validate_required([:id, :name, :organization_id])
    |> apply_action(:insert)
  end

  def hook(_policy, _lifecycle), do: Task.completed(:ok)

  @doc """
  Try finding the client in either the :client_auth table or the
  deprecated :manifests table.
  """
  def fetch(org_id, client_id) do
    key = {org_id, client_id}
    case JumpWire.GlobalConfig.fetch(:client_auth, key) do
      {:ok, client} -> {:ok, client}
      _ ->
        case JumpWire.GlobalConfig.fetch(:manifests, key) do
          {:ok, manifest} -> from_manifest(manifest)
          err -> err
        end
    end
  end

  defp from_manifest(manifest) do
    attrs = Map.from_struct(manifest)
    case attrs do
      %{classification: c} when not is_nil(c) ->
        attrs
        |> Map.put(:attributes, MapSet.new(["classification:#{c}"]))
        |> from_json(manifest.organization_id)

      _ -> attrs
    end
  end

  @doc """
  Check when a given client is authorized to connect to the manifest.
  """
  def authorized?(%ClientAuth{manifest_id: nil}, _), do: true
  def authorized?(%ClientAuth{manifest_id: id}, id), do: true
  def authorized?(%JumpWire.Manifest{}, _), do: true  # legacy clientauth storage
  def authorized?(_, _), do: false

  def get_attributes(client) do
    empty_mapset = MapSet.new()
    client_id = "client:#{client.id}"
    case client do
      %{classification: c, attributes: ^empty_mapset} when not is_nil(c) ->
        Logger.warn("Using deprecated client auth structure")
        MapSet.new(["classification:#{c}", client_id, "*"])

      _ ->
        client.attributes
        |> MapSet.put("*")
        |> MapSet.put(client_id)
    end
  end
end
