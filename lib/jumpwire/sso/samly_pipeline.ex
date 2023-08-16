defmodule JumpWire.SSO.SamlyPipeline do
  @moduledoc """
  Pipeline that runs after a user is authenticated with SSO,
  before the assertion is saved.
  """

  use Plug.Builder
  require Logger

  plug :compute_attributes

  def compute_attributes(conn, _opts) do
    assertion = conn.private[:samly_assertion]

    subject_name = assertion.subject.name
    idp_id = assertion.idp_id
    permissions = %{all: [:root]}

    org_id = JumpWire.Metadata.get_org_id()
    user_id = JumpWire.Metadata.get_org_id_as_uuid() |> Uniq.UUID.uuid5("#{idp_id}:#{subject_name}")

    group_attribute = Application.get_env(:jumpwire, :sso)[:group_attribute]
    groups = Samly.get_attribute(assertion, group_attribute)

    Logger.debug("SSO authentication succeeded for #{user_id} with the following groups: #{inspect groups}")
    computed = %{org_id: org_id, groups: groups, id: user_id}
    assertion = %{assertion | computed: computed}

    conn
    |> put_private(:samly_assertion, assertion)
    |> JumpWire.API.Guardian.Plug.sign_in(user_id, permissions)
    |> JumpWire.API.Guardian.Plug.remember_me(user_id, permissions)
  end
end
