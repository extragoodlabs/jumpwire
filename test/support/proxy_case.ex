defmodule JumpWire.ProxyCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias JumpWire.ClientAuth
      alias JumpWire.Manifest
      import ExUnit.CaptureLog

      setup_all do
        org_id = JumpWire.Metadata.get_org_id()
        client = %ClientAuth{
          id: Uniq.UUID.uuid4(),
          name: "proxy auth",
          classification: "Internal",
          organization_id: org_id,
          attributes: MapSet.new(["classification:Internal"]),
        }
        JumpWire.GlobalConfig.set(:client_auth, org_id, %{{org_id, client.id} => client})

        encrypt_policy = %JumpWire.Policy{
          version: 1,
          allowed_classification: "Internal",
          handling: :encrypt,
          id: Uniq.UUID.uuid4(),
          label: "secret",
          name: "encrypt",
          organization_id: org_id,
        }
        tokenize_policy = %JumpWire.Policy{
          version: 1,
          allowed_classification: "Internal",
          handling: :tokenize,
          id: Uniq.UUID.uuid4(),
          label: "phone_number",
          name: "tokenize",
          organization_id: org_id,
        }
        policies = %{
          {org_id, encrypt_policy.id} => encrypt_policy,
          {org_id, tokenize_policy.id} => tokenize_policy,
        }
        JumpWire.GlobalConfig.set(:policies, org_id, policies)

        token = Application.get_env(:jumpwire, :proxy, [])
        |> Keyword.get(:secret_key)
        |> Plug.Crypto.sign("manifest", {org_id, client.id})

        %{token: token, org_id: org_id, client: client, policies: policies}
      end

      setup %{policies: policies, org_id: org_id} do
        on_exit fn ->
          # Clean-up persistent connection cache between tests to avoid flakiness
          :ets.delete_all_objects(:manifest_connections)
          JumpWire.GlobalConfig.set(:policies, org_id, policies)
        end
      end
    end
  end
end
