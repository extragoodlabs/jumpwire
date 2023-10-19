Mox.Server.start_link([])
ExUnit.start(trace: true)

# mock setup
Mox.defmock(JumpWire.TeslaMock, for: Tesla.Adapter)
Mox.defmock(JumpWire.SSO.MockImpl, for: JumpWire.SSO)

Excontainers.ResourcesReaper.start_link()

Application.get_env(:jumpwire, JumpWire.Cloak.KeyRing)[:default_org] |> JumpWire.Vault.load_keys()
