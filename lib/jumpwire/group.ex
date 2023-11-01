defmodule JumpWire.Group do
  @moduledoc """
  Schema to represent a group and associated permissions. For each label,
  every group should have a default deny policy as well as an access policy
  specifying exactly which actions are allowed for that label.
  """

  use JumpWire.Schema
  import Ecto.Changeset

  typed_embedded_schema null: false do
    field :name, :string
    field :source, :string
    field :permissions, Ecto.MapSet, default: MapSet.new()
    field :members, {:array, :string}, default: []
    field :organization_id, :string
    embeds_many :policies, JumpWire.Policy
  end

  def from_json({name, data}, org_id) do
    changeset =
      %__MODULE__{organization_id: org_id}
      |> cast(data, [:id, :source, :permissions, :members, :organization_id])
      |> put_change(:name, name)
      |> validate_required([:name, :organization_id])

    changeset =
      case fetch_change(changeset, :permissions) do
        {:ok, permissions} -> cast_policies(changeset, permissions)
        _ -> changeset
      end

    changeset
    |> apply_action(:insert)
    |> store_policies()
  end

  def from_json(_, _) do
    %__MODULE__{}
    |> change()
    |> add_error(:name, "invalid structure passed")
    |> apply_action(:insert)
  end

  def hook(_group, _action), do: Task.completed(:ok)

  def store_policies({:ok, group}) do
    Enum.map(group.policies, fn p -> JumpWire.GlobalConfig.put(:policies, p) end)
    {:ok, group}
  end

  def store_policies(res), do: res

  def fetch(org_id, group_id) do
    key = {org_id, group_id}
    JumpWire.GlobalConfig.fetch(:groups, key)
  end

  def put(org_id, group) do
    JumpWire.GlobalConfig.put(:groups, {org_id, group.id}, group)

    store_policies({:ok, group})
  end

  def list_all(org_id) do
    JumpWire.GlobalConfig.all(:groups, {org_id, :_})
  end

  def delete(org_id, group_id) do
    JumpWire.GlobalConfig.delete(:groups, {org_id, group_id})
  end

  def cast_policies(changeset, permissions) do
    group_name = get_field(changeset, :name)
    org_id = get_field(changeset, :organization_id)

    actions = JumpWire.Proxy.db_actions() |> MapSet.new()

    permissions =
      permissions
      |> Stream.map(fn p -> String.split(p, ":", parts: 2) end)
      |> Enum.group_by(&List.last/1, &List.first/1)

    labels = JumpWire.Proxy.list_labels(org_id)

    policies =
      permissions
      |> Map.keys()
      |> Stream.concat(labels)
      |> Stream.uniq()
      |> Enum.flat_map(fn label ->
        allowed = Map.get(permissions, label, []) |> MapSet.new()

        rule =
          MapSet.difference(actions, allowed)
          |> Stream.map(fn action -> "not:#{action}:#{label}" end)
          |> MapSet.new()
          |> MapSet.put("group:#{group_name}")

        allow = group_access_policy(group_name, org_id, label, rule)
        deny = group_deny_policy(group_name, org_id, label)
        [allow, deny]
      end)

    put_embed(changeset, :policies, policies)
  end

  defp group_access_policy(group_name, org_id, label, rule) do
    id = org_id |> JumpWire.Metadata.org_id_to_uuid() |> Uniq.UUID.uuid5("#{group_name}:#{label}")

    attrs = %{
      id: id,
      version: 2,
      handling: :access,
      apply_on_match: true,
      name: "#{group_name} #{label} access",
      label: label,
      attributes: [rule],
      organization_id: org_id
    }

    JumpWire.Policy.changeset(%JumpWire.Policy{}, attrs)
  end

  defp group_deny_policy(group_name, org_id, label) do
    id = org_id |> JumpWire.Metadata.org_id_to_uuid() |> Uniq.UUID.uuid5("#{group_name}:#{label}:default_deny")

    attrs = %{
      id: id,
      label: label,
      version: 2,
      name: "#{group_name} #{label} default deny",
      handling: :block,
      apply_on_match: true,
      attributes: [MapSet.new(["group:#{group_name}"])],
      organization_id: org_id
    }

    JumpWire.Policy.changeset(%JumpWire.Policy{}, attrs)
  end
end
