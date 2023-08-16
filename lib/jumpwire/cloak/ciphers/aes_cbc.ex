defmodule JumpWire.Cloak.Ciphers.AES.CBC do
  @moduledoc """
  A `Cloak.Cipher` which encrypts values with the AES cipher in CBC (Cipher Block Chaining) mode.
  Internally relies on Erlang's `:crypto.block_encrypt/4`.
  """

  @behaviour Cloak.Cipher

  alias Cloak.Tags.{Encoder, Decoder}
  alias Cloak.Crypto

  @block_size 16
  @cipher Crypto.map_cipher(:aes_256_cbc)

  @doc """
  Callback implementation for `Cloak.Cipher`. Encrypts a value using
  AES in CBC mode.

  Generates a random IV for every encryption, and prepends the key tag, IV,
  and ciphertag to the beginning of the ciphertext. The format can be
  diagrammed like this:

      +----------------------------------------------------------+
      |                 HEADER            |         BODY         |
      +-------------------+---------------+----------------------+
      | Key Tag (n bytes) | IV (n bytes)  | Ciphertext (n bytes) |
      +-------------------+---------------+----------------------+
      |                   |_________________________________
      |                                                     |
      +---------------+-----------------+-------------------+
      | Type (1 byte) | Length (1 byte) | Key Tag (n bytes) |
      +---------------+-----------------+-------------------+

  The `Key Tag` component of the header breaks down into a `Type`, `Length`,
  and `Value` triplet for easy decoding.

  **Important**: Because a random IV is used for every encryption, `encrypt/2`
  will not produce the same ciphertext twice for the same value.
  """
  @impl true
  def encrypt(plaintext, opts) do
    key = Keyword.fetch!(opts, :key)
    tag = Keyword.fetch!(opts, :tag)
    iv = Crypto.strong_rand_bytes(@block_size)

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
    ciphertext = :crypto.crypto_one_time(@cipher, key, iv, plaintext, encrypt: true)
    {:ok, Encoder.encode(tag) <> iv <> ciphertext}
  end

  @doc """
  Callback implementation for `Cloak.Cipher`. Decrypts a value
  encrypted with AES in CBC mode.
  """
  @impl true
  def decrypt(ciphertext, opts) do
    if can_decrypt?(ciphertext, opts) do
      key = Keyword.fetch!(opts, :key)

      %{remainder: <<iv::binary-size(@block_size), ciphertext::binary>>} = Decoder.decode(ciphertext)

      plaintext = :crypto.crypto_one_time(@cipher, key, iv, ciphertext, encrypt: false)

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
      %{
        tag: ^tag,
        remainder: <<_iv::binary-size(@block_size), _ciphertext::binary>>
      } ->
        true

      _other ->
        false
    end
  end
end
