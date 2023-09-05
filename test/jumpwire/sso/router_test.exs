defmodule JumpWire.SSO.RouterTest do
  use ExUnit.Case, async: true
  use Plug.Test
  alias JumpWire.SSO.Router

  @opts Router.init([])

  test "listing idps" do
    config = Application.get_env(:samly, Samly.Provider)
    on_exit fn ->
      Application.put_env(:samly, Samly.Provider, config)
    end

    idp = %{
      id: Faker.App.name(),
      sp_id: "jumpwire",
      base_url: "/sso",
      metadata_file: "/dev/null",
      pre_session_create_pipeline: JumpWire.SSO.SamlyPipeline,
    }
    config = Keyword.put(config, :identity_providers, [idp])
    Application.put_env(:samly, Samly.Provider, config)

    conn = conn(:get, "/")
    |> Router.call(@opts)

    assert conn.status == 200
    assert {:ok, body} = Jason.decode(conn.resp_body)
    assert [idp.id] == body
  end

  test "listing idps without any configured" do
    conn = conn(:get, "/")
    |> Router.call(@opts)

    assert conn.status == 200
    assert conn.resp_body == "[]"
  end
end
