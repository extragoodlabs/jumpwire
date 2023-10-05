defmodule JumpWire.Proxy.Postgres.Messages do
  # NB: error code appendix: https://www.postgresql.org/docs/current/errcodes-appendix.html

  @default_parameter_status %{
    "application_name" => "jumpwire",
    "server_version" => "13.9",
  } |> Enum.map(fn {name, value} ->
    # length = name + value + 4 length bytes + 2 null bytes
    len = byte_size(name) + byte_size(value) + 6
    <<?S, len::32, name::binary, 0, value::binary, 0>>
  end)

  def ready_for_query(), do: <<?Z, 5::32, ?I>>

  def default_parameter_status() do
    # Normally these are passed through from the actual PostgreSQL server,
    # but when lazy-loading connections we need to send something to the
    # client. Some parameters are expected and will break ORMs if not set.
    #
    # https://www.postgresql.org/docs/15/protocol-flow.html#PROTOCOL-ASYNC

    @default_parameter_status
  end

  def authentication_ok(), do: <<?R, 8::32, 0::32>>

  def authentication_md5_password() do
    salt = :crypto.strong_rand_bytes(4)
    <<?R, 12::32, 5::32, salt::binary>>
  end

  def authentication_cleartext_password(), do: <<?R, 8::32, 3::32>>

  def sasl_initial_response(nonce) do
    auth = " n,,n=,r=#{nonce}"
    body = <<"SCRAM-SHA-256"::binary, 0::32, auth::binary>>
    len = byte_size(body) + 4
    <<?p, len::32, body::binary>>
  end

  def sasl_response(nonce, proof) do
    body = "c=biws,r=#{nonce},p=#{proof}"
    len = byte_size(body) + 4
    <<?p, len::32, body::binary>>
  end

  def terminate(), do: <<?X, 4::32>>

  def ssl_request(), do: <<8::32, 1234::16, 5679::16>>

  def failed_auth_error() do
    body = <<?S, "ERROR", 0, ?C, "28P01", 0, ?M, "invalid password", 0, 0>>
    len = byte_size(body) + 4
    <<?E, len::32, body::binary>>
  end

  def policy_blocked_error() do
    body = <<?S, "ERROR", 0, ?C, "42501", 0, ?M, "blocked by JumpWire policy", 0, 0>>
    len = byte_size(body) + 4
    <<?E, len::32, body::binary>>
  end

  def policy_blocked_error(url) do
    body = <<?S, "ERROR", 0, ?C, "42501", 0, ?M, "blocked by JumpWire policy. A request for additional access was generated and can be viewed at:\n    ", url::binary, 0, 0>>
    len = byte_size(body) + 4
    <<?E, len::32, body::binary>>
  end

  def internal_error() do
    body = <<?S, "ERROR", 0, ?C, "XX000", 0, ?M, "error in JumpWire processing", 0, 0>>
    len = byte_size(body) + 4
    <<?E, len::32, body::binary>>
  end

  def policy_error(err) do
    msg =
      case err do
        :metastore_failure -> "failed to connect to kv store"
        :key_storage -> "could not load encryption keys"
        _ -> "unknown"
      end

    body = <<?S, "ERROR", 0, ?C, "XX000", 0, ?M, "error applying JumpWire policy to row: ", msg::binary, 0, 0>>
    len = byte_size(body) + 4
    <<?E, len::32, body::binary>>
  end

  @doc """
  A NoticeResponse message containing information for authenticating via
  a magic link. NoticeResponse messages should be displayed by the client
  and must be accepted at any point.
  """
  def passwordless_auth(message) do
    code = "57000"  # operator_intervention
    body = <<?S, "NOTICE", 0, ?C, code::binary, 0, ?M, "Protected by JumpWire\n", message::binary, 0, 0>>
    len = byte_size(body) + 4
    [<<?N, len::32>>, body]
  end

  def startup_message(params) do
    # Filter out any params that are JumpWire specific
    params = params |> Stream.reject(fn {key, _} -> String.starts_with?(key, "jw_") end)

    version = <<196_608::32>>
    body = params
    |> Stream.map(fn {key, value} ->
      key <> <<0>> <> value <> <<0>>
    end)
    |> Enum.reduce(version, fn param, acc -> acc <> param end)
    body = body <> <<0>>
    len = byte_size(body) + 4
    <<len::32, body::binary>>
  end

  def query(:simple, data) do
    # simple query
    len = :erlang.iolist_size(data) + 5
    [<<?Q, len::integer-32>>, data, 0]
  end

  def query({:parse, name, params}, data) do
    # prepared statement, also called a Parse message
    len = :erlang.iolist_size(name) + :erlang.iolist_size(data) + 8
    [<<?P, len::integer-32>>, name, 0, data, 0, params]
  end
end
