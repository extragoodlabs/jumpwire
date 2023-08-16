defmodule JumpWire.Proxy.Token do
  @moduledoc """
  Guardian.Token implementation that uses encrypted tokens generated
  by Plug.Crypto. These tokens are generated as client credentials in
  the UI.

  Note that this module is only a partial implementation of the
  Guardian.Token behaviour. Decoding tokens is fully supported, but
  encoding is not.
  """

  @behaviour Guardian.Token

  defmodule UnimplementedError do
    defexception message: "Not implemented"

    defimpl String.Chars, for: __MODULE__ do
      def to_string(err), do: err.message
    end
  end

  @impl Guardian.Token
  def build_claims(_mod, _resource, _sub, _claims, _opts) do
    raise %UnimplementedError{message: "build_claims not implemented"}
  end

  @impl Guardian.Token
  def create_token(_mod, _claims, _opts) do
    raise %UnimplementedError{message: "create_token not implemented"}
  end

  @doc """
  Decodes the token and validates the signature.

  Options:

  * `secret` - Override the configured secret. `Guardian.Config.config_value` is valid
  """
  @impl Guardian.Token
  def decode_token(_mod, token, opts \\ []) do
    secret = fetch_verifying_secret(opts)
    case JumpWire.Proxy.verify_token(secret, token) do
      {:ok, {org_id, client_id}} -> {:ok, %{org: org_id, client: client_id}}
      err -> err
    end
  end

  @impl Guardian.Token
  def exchange(_mod, _old_token, _from_type, _to_type, _opts) do
    raise %UnimplementedError{message: "exchange not implemented"}
  end

  @doc """
  Inspect the token without any validation or signature checking.
  Return an map with keys: `org` and `client`.
  """
  @impl Guardian.Token
  @spec peek(module, String.t | nil) :: map | nil
  def peek(_mod, nil), do: nil
  def peek(_mod, token) do
    # Copying logic from private functions in Plug.Crypto
    # https://github.com/elixir-plug/plug_crypto/blob/4ef6db0ee6bb7649bebb17ffc44b7d410453016c/lib/plug/crypto/message_verifier.ex#L78
    with [_, payload, _] <- String.split(token, ".", parts: 3),
         {:ok, payload} <- Base.url_decode64(payload, padding: false),
         {data, _, _} <- Plug.Crypto.non_executable_binary_to_term(payload),
         {org_id, client_id} <- data do
      %{org: org_id, client: client_id}
    else
      _ -> nil
    end
  end

  @impl Guardian.Token
  def refresh(_mod, _old_token, _opts) do
    raise %UnimplementedError{message: "refresh not implemented"}
  end

  @impl Guardian.Token
  def revoke(_mod, _claims, _token, _opts) do
    raise %UnimplementedError{message: "revoke not implemented"}
  end

  @doc """
  Generate unique token id.
  """
  @impl Guardian.Token
  def token_id(), do: Guardian.UUID.generate()

  @impl Guardian.Token
  def verify_claims(mod, claims, opts) do
    mod.verify_claims(claims, opts)
  end

  defp fetch_verifying_secret(opts) do
    default_secret = Application.get_env(:jumpwire, :proxy, [])
    |> Keyword.get(:secret_key)

    Keyword.get(opts, :secret, default_secret)
  end
end
