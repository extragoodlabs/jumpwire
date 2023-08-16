defmodule JumpWire.TLS do
  @moduledoc """
  Handlers for interacting with cached TLS certificates.
  """

  def cached_cert(hostname) when is_binary(hostname) do
    hostname = String.to_charlist(hostname)
    cached_cert(hostname)
  end
  def cached_cert(hostname) do
    case JumpWire.GlobalConfig.get(:certificates, hostname) do
      nil ->
        # If the exact cert name could not be found, try finding a cached wildcard cert
        case hostname do
          [?*, ?. | _] -> nil
          _ -> cached_cert([?*, ?. | hostname])
        end

      cert -> {:ok, cert}
    end
  end

  def sni_fun(hostname) do
    case cached_cert(hostname)  do
      {:ok, cert} ->
        cert_opts(cert)

      _ ->
        case cached_cert('selfsigned') do
          {:ok, cert} -> cert_opts(cert)
          _ -> []
        end
    end
  end

  defp cert_opts(%{key: nil}), do: []
  defp cert_opts(%{cacert: nil}), do: []
  defp cert_opts(%{cert: nil}), do: []
  defp cert_opts(%{key: key, cacert: cacert, cert: cert}), do: [key: key, cacert: cacert, cert: cert]
  defp cert_opts(opts) when is_list(opts), do: opts
  defp cert_opts(_), do: []
end
