defmodule JumpWire.Metadata do
  def sentry_tags(org) do
    version = Application.spec(:jumpwire, :vsn) |> to_string()
    %{"version" => version, "organization" => org}
  end

  def set_org_id(org_id) do
    JumpWire.update_env(:metadata, :org_id, org_id)
    Application.put_env(:sentry, :tags, sentry_tags(org_id))
  end

  def get_org_id() do
    Application.get_env(:jumpwire, :metadata)[:org_id]
  end

  def get_org_id_as_uuid() do
    get_org_id() |> org_id_to_uuid()
  end

  def org_id_to_uuid(org_id = "org_" <> _) do
    Uniq.UUID.uuid5(:oid, "urn:jumpwire.io:organization:#{org_id}")
  end
  def org_id_to_uuid(org_id), do: org_id

  def set_node_id() do
    id = Uniq.UUID.uuid4()
    JumpWire.update_env(:metadata, :node_id, id)
  end

  def get_node_id() do
    Application.get_env(:jumpwire, :metadata)[:node_id]
  end
end
