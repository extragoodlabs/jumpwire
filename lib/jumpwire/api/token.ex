defmodule JumpWire.API.Token do
  @moduledoc """
  Provide a way to generate and verify bearer tokens for use in API authentication.

  These are intended to be used when interacting directly with the JumpWire service, and not as a passthrough for proxy auth.
  """

  @behaviour Guardian.Token
  alias JumpWire.API.UnimplementedError

  @max_age 60 * 60 * 24 * 365 * 10
  @salt "bearer token"
  @sso_key_salt "sso_assertion_key"
  @jit_auth_salt "jit authz"
  @root_permissions %{all: [:root]}

  @doc """
  Generate a signed token representing an SSO key. This is useful when a
  user is attempting to pass authentication from their browser to a CLI
  or other tool.
  """
  def sign_sso_key(sso_key) do
    get_root_token()
    |> Plug.Crypto.sign(@sso_key_salt, sso_key, max_age: 60 * 10)
  end

  @doc """
  Validate and decode a token containing a key for an authenticated SSO
  session.
  """
  def verify_sso_key(token) do
    get_root_token()
    |> Plug.Crypto.verify(@sso_key_salt, token)
  end

  @doc """
  Generate a signed token representing a JIT authentication attempt.
  """
  def sign_jit_auth_request(nonce, type) do
    get_root_token()
    |> Plug.Crypto.sign(@jit_auth_salt, {nonce, type}, max_age: 60 * 60)
  end

  @doc """
  Validate and decode a token containing a key for an authentication attempt.
  """
  def verify_jit_auth_request(token) do
    get_root_token() |> Plug.Crypto.verify(@jit_auth_salt, token)
  end

  @doc """
  Encodes and signs data into a token you can send to clients.

  Permissions is expected to be a keyword list or map of the HTTP method to the
  allowed route segments. For example, `[get: ["status"]]`.
  """
  @spec generate(Keyword.t | map | {any, map}) :: binary
  def generate({_id, permissions}), do: generate(permissions)

  def generate(permissions) do
    permissions = convert_permissions(permissions)

    data = {token_id(), permissions}
    get_root_token()
    |> Plug.Crypto.sign(@salt, data, max_age: @max_age)
  end

  defp convert_permissions(permissions) do
    # convert the permissions into a format that is easier to use
    # with the authorization plug
    permissions
    |> Stream.map(fn {method, list} ->
      method = method |> to_string |> String.upcase()
      {method, list}
    end)
    |> Map.new()
  end

  @doc """
  Decodes the original data from the token and verifies its integrity.

  The mechanism for passing the token to the client is typically through a
  cookie, a JSON response body, or HTTP header.
  """
  @spec verify(binary) ::
  {:ok, {term, [atom]}} | {:error, :expired | :invalid | :missing}
  def verify(token) do
    case get_root_token() do
      ^token -> {:ok, {:root, @root_permissions}}
      root -> Plug.Crypto.verify(root, @salt, token, max_age: @max_age)
    end
  end

  @doc """
  Retrieve the root token to use as a signing secret.
  """
  def get_root_token() do
    Application.get_env(:jumpwire, :signing_token)
  end

  @doc """
  Generate a new root token and persist it.
  """
  def generate_root_token() do
    token = :crypto.strong_rand_bytes(32) |> JumpWire.Base64.encode()
    Application.put_env(:jumpwire, :signing_token, token, persistent: true)
    token
  end

  @doc """
  Decodes the token and validates the signature.
  """
  @impl Guardian.Token
  def decode_token(_mod, token, _opts \\ []) do
    verify(token)
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

  @doc """
  Inspect the token without any validation or signature checking.
  Return an map with keys: `org` and `client`.
  """
  @impl Guardian.Token
  @spec peek(module, String.t | nil) :: map | nil
  def peek(_mod, nil), do: nil
  def peek(mod, token) do
    root_token = get_root_token()
    peek(mod, token, root_token)
  end

  defp peek(_mod, token, token) do
    {:root, @root_permissions}
  end
  defp peek(_mod, token, _root_token) do
    # Copying logic from private functions in Plug.Crypto
    # https://github.com/elixir-plug/plug_crypto/blob/4ef6db0ee6bb7649bebb17ffc44b7d410453016c/lib/plug/crypto/message_verifier.ex#L78
    with [_, payload, _] <- String.split(token, ".", parts: 3),
         {:ok, payload} <- Base.url_decode64(payload, padding: false),
         {data, _, _} <- Plug.Crypto.non_executable_binary_to_term(payload) do
      data
    else
      _ -> nil
    end
  end

  @impl Guardian.Token
  def build_claims(_mod, _resource, sub, claims, _opts) do
    {:ok, %{sub: sub, permissions: claims, type: "refresh"}}
  end

  @impl Guardian.Token
  def create_token(_mod, claims, _opts) do
    {:ok, generate(claims)}
  end

  @impl Guardian.Token
  def exchange(_mod, _old_token, _from_type, _to_type, _opts) do
    raise %UnimplementedError{message: "exchange not implemented"}
  end

  @impl Guardian.Token
  def refresh(_mod, _old_token, _opts) do
    raise %UnimplementedError{message: "refresh not implemented"}
  end

  @impl Guardian.Token
  def revoke(_mod, _claims, _token, _opts) do
    raise %UnimplementedError{message: "revoke not implemented"}
  end
end
