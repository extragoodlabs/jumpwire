defmodule JumpWire.API.AuthPipeline do
  @moduledoc false

  use Guardian.Plug.Pipeline,
    otp_app: :jumpwire,
    module: JumpWire.API.Guardian,
    error_handler: JumpWire.API.ErrorHandler

  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.VerifySession, refresh_from_cookie: true
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource
  plug JumpWire.API.AuthorizationPlug
end
