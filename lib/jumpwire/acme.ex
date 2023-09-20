defmodule JumpWire.ACME do
  @moduledoc """
  Generate, manage, and renew TLS certificates using an ACME server.
  """

  require Logger
  alias SiteEncrypt.Acme.Client.API
  use JumpWire.Retry

  def store_cert_config(name, %{key: key, cert: cert, cacert: chain}) do
    pem_key = X509.PrivateKey.from_pem!(key)
    der_cert = X509.Certificate.from_pem!(cert) |> X509.Certificate.to_der()
    der_chain = X509.Certificate.from_pem!(chain) |> X509.Certificate.to_der()
    store_cert_config(name, pem_key, der_cert, der_chain)
  end

  defp store_cert_config(name, pem_key, der_cert, der_chain) do
    der_key = {:RSAPrivateKey, X509.PrivateKey.to_der(pem_key)}
    value = [key: der_key, cert: der_cert, cacert: der_chain]
    JumpWire.SSO.set_tls_cert(name, der_cert, pem_key)
    name = String.to_charlist(name)
    JumpWire.GlobalConfig.put(:certificates, name, value)
  end

  def ensure_cert() do
    config = Application.get_env(:jumpwire, :acme) |> Map.new()

    if config[:generate] do
      ensure_cert(config)
    end

    # Load a selfsigned cert as a fallback
    generate_self_signed_cert()
  end

  defp generate_self_signed_cert() do
    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(
      key,
      "/CN=JumpWire Self-Signed",
      template: :server,
      extensions: [
        subject_alt_name: X509.Certificate.Extension.subject_alt_name(["localhost", "*"])
      ]
    ) |> X509.Certificate.to_der()
    store_cert_config("selfsigned", key, cert, cert)
  end

  def ensure_cert(config = %{hostname: hostname}) when is_binary(hostname) do
    File.mkdir_p!(config.cert_dir)

    JumpWire.TLS.cached_cert(hostname)
    |> then(fn
      nil -> read_from_disk(hostname, config)
      {:ok, cert} ->
        store_cert_disk(cert, hostname, config)
        {:ok, cert}
    end)
    |> if_nil(fn ->
      case validate_domain(hostname) do
        :ok -> order_cert(hostname, config)
        err ->
          Logger.error("Invalid ACME configuration")
          {:error, err}
      end
    end)
  end

  def validate_domain(""), do: :invalid
  def validate_domain("."), do: :invalid
  def validate_domain(host) when is_binary(host) do
    host |> String.split(".", trim: true) |> validate_domain()
  end
  def validate_domain([part | _]) when byte_size(part) > 63, do: :invalid
  def validate_domain([_ | rest]), do: validate_domain(rest)
  def validate_domain([]), do: :ok
  def validate_domain(_), do: :invalid

  def order_cert(domain, config) do
    retry with: exponential_backoff(1_000) |> randomize() |> expiry(300_000) do
      key = get_account_key(config)
      with {:ok, session} <- account_session(key, config),
           task = %Task{} <- new_cert(session, domain, config) do
        task
      else
        err ->
          message =
            case err do
              {:error, %{body: body}, _session} -> body
              {:error, env, _session} -> env
              {:error, err} -> err
              err -> err
            end

          Logger.error("Failed to create HTTP session for letsencrypt: #{inspect message}")
          {:error, message}
      end
    end
  end

  def renew_expired(config = %{hostname: host, cert_renewal_seconds: min_seconds}) do
    case JumpWire.TLS.cached_cert(host) do
      nil ->
        Logger.debug("No certificate to renew")
        nil

      {:ok, cert_data} ->
        cert = Keyword.get(cert_data, :cert)
        if cert_remaining_seconds(cert) < min_seconds do
          Logger.info("Renewing certificate for #{host}")
          order_cert(host, config)
        end
    end
  end

  defp cert_remaining_seconds(cert) when is_binary(cert) do
    cert |> X509.Certificate.from_der!() |> cert_remaining_seconds()
  end
  defp cert_remaining_seconds(cert) do
    {:Validity, _not_before, not_after} = X509.Certificate.validity(cert)
    now = DateTime.utc_now()
    not_after |> X509.DateTime.to_datetime() |> DateTime.diff(now)
  end

  def get_account_key(%{cert_dir: dir}) do
    path = Path.join(dir, "account")

    case JumpWire.GlobalConfig.get(:certificates, :acme_key) do
      nil ->
        case File.stat(path) do
          {:ok, _} -> JOSE.JWK.from_file(path)
          _ -> nil
        end

      key ->
        # Persist the account key to disk in case this was synced from another node
        JOSE.JWK.to_file(path, key)
        key
    end
  end

  def delete_account_key(%{cert_dir: dir}) do
    JumpWire.GlobalConfig.put(:certificates, :acme_key, nil)
    Path.join(dir, "account") |> File.rm()
  end

  defp read_from_disk(domain, %{cert_dir: root_dir}) do
    path = Path.join(root_dir, domain)

    cert_data = [:key, :cert, :cacert]
    |> Enum.map(fn key ->
      case Path.join(path, Atom.to_string(key)) |> File.read() do
        {:ok, data} -> {key, data}
        _ -> {key, nil}
      end
    end)
    |> Enum.into(%{})

    if nil in Map.values(cert_data) do
      File.rm_rf!(path)
      nil
    else
      Logger.debug("Found PKI data on disk for #{domain}")
      store_cert_config(domain, cert_data)
      {:ok, cert_data}
    end
  end

  defp account_session(nil, config) do
    Logger.info("Creating new account")
    account_key = JOSE.JWK.generate_key({:rsa, config.key_size})
    acme_config = Application.get_env(:jumpwire, :acme)
    email = Keyword.get(acme_config, :email)

    with {:ok, session} <- API.new_session(config.directory_url, account_key),
         {:ok, session} <- API.new_account(session, [email]) do
      JumpWire.GlobalConfig.put(:certificates, :acme_key, session.account_key)
      Path.join(config.cert_dir, "account") |> JOSE.JWK.to_file(session.account_key)
      {:ok, session}
    end
  end

  defp account_session(key, config) do
    Logger.debug("Using existing ACME account")
    with {:ok, session} <- API.new_session(config.directory_url, key),
         {:ok, session} <- API.fetch_kid(session) do
      {:ok, session}
    else
      {:error, %{"type" => "urn:ietf:params:acme:error:accountDoesNotExist"}, _session} ->
        Logger.warn("ACME account reported invalid, purging")
        delete_account_key(config)
        account_session(nil, config)
      err -> err
    end
  end

  defp new_cert(session, domain, config) do
    Task.Supervisor.async_nolink(JumpWire.ACMESupervisor, fn ->
      delay = Map.get(config, :cert_delay_seconds, 0)
      Process.sleep(delay * 1000)

      retry with: exponential_backoff(1_000) |> randomize() |> expiry(300_000) do
        Logger.info("Ordering a new certificate for #{domain}")
        with {:ok, order, session} <- API.new_order(session, [domain]),
             _ <- Logger.debug("Waiting for cert order to be ready"),
             {private_key, order, session} <- process_new_order(session, order, domain, config) do
          {:ok, cert, chain, _session} = API.get_cert(session, order)
          cert_data = %{cert: cert, key: private_key, cacert: chain}
          store_cert(cert_data, domain, config)
          {:ok, cert_data}
        else
          err ->
            Logger.error("Failed to process ACME order: #{inspect err}")
            :error
        end
      end
    end)
  end

  defp store_cert(value, name, config) do
    store_cert_config(name, value)
    store_cert_disk(value, name, config)
  end

  defp store_cert_disk(cert_info, name, config) do
    path = Path.join(config.cert_dir, name)
    File.mkdir_p!(path)
    Enum.each(cert_info, fn {key, value} ->
      # write the key, cert, and cacert to separate files
      Path.join(path, Atom.to_string(key)) |> File.write(value)
    end)
  end

  defp authorize_order(authorizations, session, domain, config) do
    Enum.reduce_while(authorizations, {[], session}, fn authorization, {pending, session} ->
      case authorize(session, authorization, domain, config) do
        {:pending, challenge, session} -> {:cont, {[{authorization, challenge} | pending], session}}
        {:valid, session} -> {:cont, {pending, session}}
        err -> {:halt, err}
      end
    end)
  end

  defp process_new_order(session, order = %{status: :pending}, domain, config) do
    Logger.debug("Certificate for #{domain} is pending")
    case authorize_order(order.authorizations, session, domain, config) do
      {:error, _} = err -> err

      {pending, session} ->
        {pending_authorizations, pending_challenges} = Enum.unzip(pending)
        # blocks until all challenges have been received
        JumpWire.ACME.Challenge.await_challenges(pending_challenges)

        # keep polling the API until at least one challenge returns valid
        {:ok, session} =
          retry with: constant_backoff(2_000) |> Stream.take(300), atoms: [:pending] do
            validate_authorizations(session, pending_authorizations)
          end

        {:ok, order, session} = API.wait_for_order_ready(session, order)
        process_new_order(session, order, domain, config)
    end
  end

  defp process_new_order(session, order = %{status: :ready}, domain, config) do
    Logger.info("Certificate for #{domain} is ready")

    private_key = X509.PrivateKey.new_rsa(config.key_size)
    csr = private_key
    |> X509.CSR.new(
      {:rdnSequence, []},
      extension_request: [X509.Certificate.Extension.subject_alt_name([domain])]
    )
    |> X509.CSR.to_der()

    {:ok, _finalization, session} = API.finalize(session, order, csr)
    {:ok, order, session} = API.wait_for_order_ready(session, order)

    pem_key = private_key |> X509.PrivateKey.to_pem()
    {pem_key, order, session}
  end

  defp authorize(session, authorization, _domain, _config) do
    with {:ok, challenges, session} <- API.authorization(session, authorization) do
      challenges = Enum.group_by(challenges, fn c -> c.type end)

      case challenges do
        %{"http-01" => [%{status: :valid} | _]} -> {:valid, session}
        %{"dns-01" => [%{status: :valid} | _]} -> {:valid, session}

        %{"http-01" => [challenge = %{status: :pending} | _]} ->
          Logger.info("Attempting http-01 validation")
          key_thumbprint = JOSE.JWK.thumbprint(session.account_key)
          JumpWire.ACME.Challenge.register_challenge(challenge.token, key_thumbprint)
          {:ok, _challenge_response, session} = API.challenge(session, challenge)
          {:pending, challenge.token, session}

        _ -> {:error, :invalid_challenge}
      end
    end
  end

  defp validate_authorizations(session, []), do: {:ok, session}
  defp validate_authorizations(session, [authorization | other_authorizations]) do
    Logger.debug("Checking validity of authorization #{authorization}")

    {:ok, challenges, session} = API.authorization(session, authorization)

    # Authorization statuses from RFC8555: https://datatracker.ietf.org/doc/html/rfc8555#section-7.1.6
    statuses = challenges |> Stream.map(& &1.status) |> Enum.uniq()
    cond do
      :ready in statuses ->
        validate_authorizations(session, other_authorizations)

      :valid in statuses ->
        validate_authorizations(session, other_authorizations)

      :invalid in statuses ->
        Logger.error("Invalid challenges reported: #{inspect challenges}")
        {:error, :invalid}

      :pending in statuses or :processing in statuses ->
          :pending

      true ->
        Logger.error("Unknown challenge status: #{inspect challenges}")
        {:error, :invalid}
    end
  end


  defp if_nil(nil, fun), do: fun.()
  defp if_nil(val, _), do: val
end
