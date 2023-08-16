defmodule JumpWire.SSO do
  @moduledoc """
  Helpers for working with SSO authentication and authorization.
  """

  require Logger

  @spec fetch_assertion(Plug.Conn.t, String.t) :: {:ok, any} | :error
  def fetch_assertion(conn, key) do
    case Samly.State.get_assertion(conn, key) do
      nil -> :error
      assertion -> {:ok, assertion}
    end
  end

  @spec fetch_active_assertion(Plug.Conn.t) :: {:ok, any} | :error
  def fetch_active_assertion(conn) do
    case Samly.get_active_assertion(conn) do
      nil -> :error
      assertion -> {:ok, assertion}
    end
  end

  @doc """
  Mark a new certificate and key for use with SSO SAML requests. This
  is used when the cert is dynamically generated or otherwise loaded
  at runtime.
  """
  def set_tls_cert(name, cert, key) do
    opts = Application.get_env(:samly, Samly.Provider)

    service_providers = opts
    |> Keyword.get(:service_providers, [])
    |> Stream.filter(fn sp -> sp[:generated_cert] == name end)
    |> Stream.map(&Samly.SpData.load_provider/1)
    |> Stream.map(fn sp -> put_new_cert(sp, cert, key) end)
    |> Stream.filter(fn sp_data -> sp_data.valid? end)
    |> Stream.map(fn sp_data -> {sp_data.id, sp_data} end)
    |> Enum.into(%{})

    loaded_sps = Application.get_env(:samly, :service_providers)
    service_providers = Map.merge(loaded_sps, service_providers)

    # Only refresh the IdPs if an SP has changed
    if loaded_sps != service_providers do
      identity_providers = opts
      |> Keyword.get(:identity_providers, [])
      |> Samly.IdpData.load_providers(service_providers)

      Application.put_env(:samly, :service_providers, service_providers)
      Application.put_env(:samly, :identity_providers, identity_providers)
    end
  end

  defp put_new_cert(sp = %{cert: :undefined, key: :undefined}, cert, key) do
    Logger.debug("Setting new TLS certificate for SP #{inspect sp.id}")
    %{sp | cert: cert, key: key}
  end
  defp put_new_cert(sp, _cert, _key), do: sp

  @doc """
  Create an client based on a user's SAML assertions.
  """
  def create_client(assertion, id, manifest_id) do
    attributes = assertion.computed.groups
    |> Stream.map(fn group -> "group:#{group}" end)
    |> MapSet.new()

    attrs = %{
      name: "ephemeral user",
      id: id,
      manifest_id: manifest_id,
      identity_id: assertion.computed.id,
      attributes: attributes,
    }
    JumpWire.ClientAuth.from_json(attrs, assertion.computed.org_id)
  end
end
