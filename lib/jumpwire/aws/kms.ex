defmodule JumpWire.AWS.KMS do
  @moduledoc """
  Module for interacting with the AWS KMS API.
  """

  require Logger

  @doc """
  Form an alias with a predetermined prefix based off a user's configured
  key name. Does nothing if an ARN is passed.
  """
  def key_alias(name = "arn:" <> _, _), do: name
  def key_alias(name = "alias/" <> _, org_id), do: Path.join(name, org_id)
  def key_alias(name, org_id), do: Path.join(["alias", name, org_id])

  @doc """
  Create and alias a master KMS key. This is used to generate and decrypt future subkeys. Takes a key alias name as its only argument and returns the new
  key ID.
  """
  @spec create_master_key(String.t) :: {:ok, String.t()} | {:error, any()}
  def create_master_key(master_id = "arn:" <> _rest ) do
    Logger.error("AWS KMS key specified as an arn (#{master_id}) must already exist and cannot be automatically created.")
    {:error, :invalid}
  end
  def create_master_key(master_id) do
    Logger.info("Creating a new AWS KMS master key")
    with {:ok, result} <- ExAws.KMS.create_key(description: "JumpWire managed master key") |> ExAws.request(),
         %{"KeyMetadata" => %{"KeyId" => key_id}} <- result,
         {:ok, _} <- ExAws.KMS.create_alias(master_id, key_id) |> ExAws.request() do
      Logger.info("AWS KMS key #{key_id} created with alias #{master_id}")
      {:ok, key_id}
    end
  end

  @doc """
  Create a new data key using the specified master key.
  The key can be an ARN, key ID (UUID), or an alias. If an alias is
  specified but that master key does not exist it will be created.

  https://docs.aws.amazon.com/kms/latest/APIReference/API_GenerateDataKey.html
  """
  def generate_key(master_id, create_master \\ true) do
    Logger.info("Creating a data key from AWS KMS key #{master_id}")
    result = ExAws.KMS.generate_data_key(master_id, key_spec: "AES_256") |> ExAws.request()

    if create_master do
      with {:error, {"NotFoundException", _}} <- result,
           {:ok, _} <- create_master_key(master_id) do
        # Attempt to create the data key again, but if the master still
        # doesn't exist then let it fail.
        generate_key(master_id, false)
      end
    else
      result
    end
  end

  @doc """
  Decrypt a chunk of data that was encrypted with an AWS KMS key.

  The data should be passed as raw bytes - it will be Base64 encoded
  before being sent to the KMS API.
  """
  @spec decrypt(binary()) :: {:ok, String.t()} | :error
  def decrypt(blob) do
    op = blob |> JumpWire.Base64.encode() |> ExAws.KMS.decrypt()
    case ExAws.request(op) do
      {:ok, %{"Plaintext" => key}} ->
        JumpWire.Base64.decode(key)

      err ->
        Logger.error("Could not decrypt with KMS: #{inspect err}")
        :error
    end
  end
end
