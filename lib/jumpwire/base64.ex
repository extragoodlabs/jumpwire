defmodule JumpWire.Base64 do
  use Rustler, otp_app: :jumpwire, crate: "jumpwire_base64"

  @spec decode(binary) :: {:ok, binary} | {:error, atom}
  def decode(_b64), do: :erlang.nif_error(:nif_not_loaded)

  @spec decode!(binary) :: binary
  def decode!(text) do
    case decode(text) do
      {:ok, res} -> res
      _ -> raise %ArgumentError{message: "invalid base64 binary"}
    end
  end

  @spec encode(binary) :: binary
  def encode(_s), do: :erlang.nif_error(:nif_not_loaded)
end
