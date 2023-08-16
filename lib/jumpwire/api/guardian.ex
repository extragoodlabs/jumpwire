defmodule JumpWire.API.Guardian do
  @moduledoc """
  Guardian pipeline that handles authorization and authentication for
  API requests.
  """

  use Guardian,
    otp_app: :jumpwire,
    token_module: JumpWire.API.Token

  @impl Guardian
  def subject_for_token({id, _perms}, _claims), do: {:ok, id}
  def subject_for_token(id, _claims), do: {:ok, id}

  @impl Guardian
  def resource_from_claims({_id, _permissions}), do: {:ok, nil}
  def resource_from_claims(_), do: {:error, :invalid_claims}

  @impl Guardian
  def verify_claims(claims, _opts) do
    case claims do
      {id, %{"PERMISSIONS" => permission}} -> {:ok, {id, permission}}
      _ -> {:ok, claims}
    end
  end
end
