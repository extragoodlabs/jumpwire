defmodule JumpWire.Cloak.Ciphers.AES.ECB do
  @moduledoc """
  A `Cloak.Cipher` which encrypts values with the AES cipher in ECB (electronic codebook) mode.
  Internally relies on Erlang's `:crypto.block_encrypt/4`.

  This mode causes identical plaintext + keys to generate identical ciphertext and as such
  should be used carefully.
  """

  @behaviour Cloak.Cipher

  alias Cloak.Tags.{Encoder, Decoder}
  alias Cloak.Crypto

  @block_size 16
  @cipher Crypto.map_cipher(:aes_128_ecb)

  @doc """
  Callback implementation for `Cloak.Cipher`. Encrypts a value using
  AES in ECB mode.

  Prepends the key tag and ciphertag to the beginning of the ciphertext. The format can be
  diagrammed like this:

      +------------------------------------------+
      |       HEADER      |         BODY         |
      +-------------------+---------------+------+
      | Key Tag (n bytes) | Ciphertext (n bytes) |
      +-------------------+---------------+------+
      |                   |_________________________________
      |                                                     |
      +---------------+-----------------+-------------------+
      | Type (1 byte) | Length (1 byte) | Key Tag (n bytes) |
      +---------------+-----------------+-------------------+

  The `Key Tag` component of the header breaks down into a `Type`, `Length`,
  and `Value` triplet for easy decoding.
  """
  @impl true
  def encrypt(plaintext, opts) do
    key = Keyword.fetch!(opts, :key)
    tag = Keyword.fetch!(opts, :tag)

    checksum = :crypto.hash(:md5, plaintext)
    plaintext = checksum <> plaintext

    text_size = byte_size(plaintext)
    pad_size =
      case rem(text_size, @block_size) do
        0 -> @block_size
        n -> @block_size - n
      end
    padding = String.duplicate(<<pad_size>>, pad_size)

    plaintext = plaintext <> padding
    ciphertext = :crypto.crypto_one_time(@cipher, key, plaintext, encrypt: true)
    {:ok, Encoder.encode(tag) <> ciphertext}
  end

  @doc """
  Callback implementation for `Cloak.Cipher`. Decrypts a value
  encrypted with AES in ECB mode.
  """
  @impl true
  def decrypt(ciphertext, opts) do
    if can_decrypt?(ciphertext, opts) do
      key = Keyword.fetch!(opts, :key)

      %{remainder: ciphertext} = Decoder.decode(ciphertext)

      plaintext = :crypto.crypto_one_time(@cipher, key, ciphertext, encrypt: false)

      # Strip padding from the text
      pad_size = :binary.last(plaintext)
      plaintext = :binary.part(plaintext, 0, byte_size(plaintext) - pad_size)

      # Validate the checksum
      <<checksum::binary-size(16), plaintext::binary>> = plaintext
      case :crypto.hash(:md5, plaintext) do
        ^checksum -> {:ok, plaintext}
        _ -> {:error, :invalid_checksum}
      end
    else
      :error
    end
  end

  @doc """
  Callback implementation for `Cloak.Cipher`. Determines whether this module
  can decrypt the given ciphertext.
  """
  @impl true
  def can_decrypt?(ciphertext, opts) do
    tag = Keyword.fetch!(opts, :tag)

    case Decoder.decode(ciphertext) do
      %{tag: ^tag} -> true
      _other -> false
    end
  end
end
