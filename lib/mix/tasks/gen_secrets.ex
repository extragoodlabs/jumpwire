defmodule Mix.Tasks.Jumpwire.Gen.Secrets do
  @moduledoc """
  Generate secrets used for local development.

  This will create a new gitignored secrets file, or append to an
  existing one.
  """

  use Mix.Task

  @preferred_cli_env :dev

  @impl true
  def run(_args) do
    path = "config/#{Mix.env()}.secrets.exs"
    unless File.exists?(path) do
      create_file(path)
    end

    content = [
      gen_signing_token(),
      gen_secret_key(),
      gen_encryption_key(),
    ]
    |> Enum.join("\n")

    File.write!(path, content, [:append])

    IO.puts("Created secrets in #{path}")
  end

  defp create_file(path) do
    content = """
    import Config

    ################################################################################
    # Secrets below automatically generated with jumpwire.gen.secrets
    ################################################################################

    """
    File.write!(path, content)
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode64(padding: false)
    |> binary_part(0, length)
  end

  defp gen_signing_token() do
    token = random_string(64)
    """
    # root bearer token for internal API auth
    config :jumpwire, signing_token: "#{token}"
    """
  end

  defp gen_secret_key() do
    secret = random_string(64)
    """
    # key used for signing tokenized data
    config :jumpwire, :proxy,
      secret_key: "#{secret}"
    """
  end

  defp gen_encryption_key() do
    # the encryption key needs to be 32 bytes after decoding
    secret = :crypto.strong_rand_bytes(32) |> Base.encode64()
    """
    # master key used for deriving new encryption keys
    config :jumpwire, JumpWire.Cloak.KeyRing,
      master_key: "#{secret}"
    """
  end
end
