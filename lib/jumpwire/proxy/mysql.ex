defmodule JumpWire.Proxy.MySQL do
  @moduledoc """
  Proxy incoming TCP connections to a MySQL server.

  The MySQL handshake occurs between JumpWire and the client as soon as the client opens
  a TCP socket. Once completed, JumpWire opens another socket to the upstream server
  and performs another handshake using credentials from the configured manifest.

  After the client and database authentication, most messages are simply
  passed from one socket to the other. A termination of either end will
  also cause the other socket to be closed.

  Resultset messages (sent in response to a COM_QUERY from the client) are fully parsed
  and transformed into records. Each record has policies applied to it, and then the result
  is serialized back into a resultset before being forwarded to the client.
  """

  # TODO: send COM_QUIT when closing DB socket
  # TODO: compatability with MySQL 5.7

  use JumpWire.Proxy.Database, manifest_type: :mysql
  alias JumpWire.Proxy.{Database, MySQL}
  alias JumpWire.Proxy.MySQL.Messages
  alias MyXQL.Protocol.{Flags, Records}
  require MyXQL.Protocol.Records
  import JumpWire.Proxy.MySQL.Parser

  @max_packet_size 16_777_215

  @impl Database
  def on_boot() do
    priv_key = X509.PrivateKey.new_rsa(2048)
    pub_key = X509.PublicKey.derive(priv_key)
    %{private_key: priv_key, public_key: pub_key}
  end

  @impl Database
  def init(state) do
    # auth data is null terminated so the nonce can't have any 0 bytes in it
    nonce = :crypto.strong_rand_bytes(20) |> :binary.replace(<<0>>, <<128>>, [:global])

    nonce
    |> Messages.handshake()
    |> encode_and_send(0, state.client_socket)

    socket = %{state.client_socket | state: {:fast_auth, nonce}}
    Map.merge(state, %{client_socket: socket, command: nil})
  end

  @impl Database
  def params_from_manifest(manifest = %Manifest{root_type: :mysql}) do
    database = Map.get(manifest.configuration, "database")
    hostname = Map.get(manifest.configuration, "hostname", "localhost")
    sni = String.to_charlist(hostname)
    {:ok, db_opts, meta} = manifest.configuration
    |> Map.merge(manifest.credentials)
    |> Map.put_new("port", 3306)
    |> parse_manifest_config(manifest.organization_id)

    ssl = Map.get(manifest.configuration, "ssl", true)
    ssl_opts = Application.get_env(:jumpwire, :proxy)[:client_ssl]
    cert_dir = :code.priv_dir(:jumpwire) |> Path.join("cert")
    cacertfile = if String.ends_with?(hostname, ".rds.amazonaws.com") do
      # Use the AWS RDS cert bundle for all RDS connections
      Path.join(cert_dir, "aws-rds-bundle.pem")
    else
      Keyword.get(ssl_opts, :cacertfile)
    end

    ssl_opts = ssl_opts
    |> Keyword.put(:customize_hostname_check, [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)])
    |> Keyword.put(:server_name_indication, sni)
    |> Keyword.put(:cacertfile, cacertfile)

    params = Keyword.merge(db_opts, [database: database, ssl: ssl, ssl_opts: ssl_opts])
    {:ok, params, meta}
  end

  defp parse_manifest_config(%{"vault_database" => vault_db, "vault_role" => vault_role}, org_id)
  when not is_nil(vault_db) and not is_nil(vault_role) do
    # TODO: validate that vault works with MySQL
    JumpWire.Proxy.Storage.Vault.credentials(vault_db, vault_role, org_id)
  end

  defp parse_manifest_config(
    %{"username" => user, "hostname" => host, "password" => password, "port" => port}, _org_id
  ) do
    port = if is_binary(port) do
      case Integer.parse(port) do
        {port, ""} -> port
        _ -> 5432
      end
    else
      port
    end
    params = [username: user, hostname: host, port: port, password: password]
    {:ok, params, nil}
  end

  defp connect_to_db(manifest = %Manifest{id: id}, state) do
    {:ok, db_opts, meta} = params_from_manifest(manifest)
    case meta do
      %{lease: id, duration: ttl} ->
        timer = Integer.floor_div(ttl * 1000, 2)
        Process.send_after(self(), {:vault_renew, id}, timer)
      _ -> nil
    end

    {:ok, db_socket} = db_opts[:hostname]
    |> String.to_charlist()
    |> :gen_tcp.connect(db_opts[:port], @socket_opts)

    # Find all schemas for the current database manifest
    schemas = JumpWire.Proxy.Schema.list_all(manifest.organization_id, id)
    |> Stream.map(fn schema ->
      fields = schema.fields
      |> Stream.map(fn
        {"$." <> name, labels} -> {name, labels}
        field -> field
      end)
      |> Map.new()
      {schema.name, fields}
    end)
    |> Map.new()

    metadata = %{
      client_id: state.client_id,
      db_id: id,
      manifest_id: id,
      organization_id: state.organization_id,
      attributes: MapSet.new(["*"]),
      session_id: Uniq.UUID.uuid4(),
    }

    Database.put_tables(state.organization_id, id, %{}, schemas)

    %{state |
      db_socket: %Socket{transport: :ranch_tcp, socket: db_socket},
      db_opts: db_opts,
      metadata: metadata}
  end

  @impl Database
  def db_recv(
    msg = <<len::uint3, seq, payload::binary-size(len), rest::binary>>,
    state = %{flags: %{parse_responses: true}, db_socket: %Socket{state: :ready}, command: {:query, query_type}}
  ) do
    # Query response
    # TODO: this could also be EOF
    result =
      case payload do
        <<0, _rest::binary>> -> {:ok, msg}  # OK
        <<255, _rest::binary>> -> {:ok, msg}  # ERROR
        _ -> MySQL.Resultset.parse(payload, seq, rest, state)
      end

    state =
      case result do
        {:ok, msg} ->
          :ok = Database.msg_send(state.client_socket, msg)
          stop_time = System.monotonic_time(:microsecond)
          %{state | db_buffer: "", fields: nil, stop_time: stop_time}

        {:eof, acc, msg} ->
          Logger.debug("Expecting more resultset data")
          command = {:query_more, query_type}
          %{state | db_buffer: msg, fields: acc, command: command}

        err ->
          Logger.error("Error parsing resultset: #{inspect err}")
      end

    :ok = Database.socket_active(state.db_socket)
    {:noreply, state}
  end

  @impl Database
  def db_recv(msg, state = %{flags: %{parse_responses: true}, db_socket: %Socket{state: :ready}, command: {:query_more, _}}) do
    # Query response with buffered data
    # TODO: this could also be EOF
    {acc, cols, packets} = state.fields
    result = MySQL.Resultset.parse_data(state.db_buffer <> msg, cols, packets, state, acc)
    state =
      case result do
        {:ok, msg} ->
          :ok = Database.msg_send(state.client_socket, msg)
          %{state | db_buffer: "", fields: nil}

        {:eof, acc, msg} ->
          Logger.debug("Expecting more resultset data")
          %{state | db_buffer: msg, fields: acc}

        err ->
          Logger.error("Error parsing resultset: #{inspect err}")
      end

    :ok = Database.socket_active(state.db_socket)
    {:noreply, state}
  end

  @impl Database
  def db_recv(msg, state = %{db_socket: %Socket{state: :ready}}) do
    # Pass the message straight to the client
    :ok = Database.msg_send(state.client_socket, msg)
    :ok = Database.socket_active(state.db_socket)
    {:noreply, state}
  end

  @impl Database
  def db_recv(msg = <<len::uint3, seq, payload::binary-size(len), rest::binary>>, state) do
    # Messages received from the upstream server before JumpWire has finished
    # the initial authentication/handshake
    next_seq = seq + 1

    result =
      case payload do
        <<10, _::binary>> ->
          # Handshake
          send_handshake_response(payload, state)

        <<1, 4>> ->
          # FullAuth
          perform_full_auth(next_seq, state)

        <<1, data::binary>> ->
          # AuthMoreData
          handle_auth_more_data(next_seq, data, state)

        <<254, _warnings::16, _status_flags::16>> ->
          # EOF
          state

        <<254, data::binary>> ->
          # AuthSwitchRequest
          handle_auth_switch_request(data, next_seq, state)

        <<0, _rest::binary>> ->
          # OK
          MyXQL.Protocol.decode_generic_response(payload)
          |> handle_db_ok(next_seq, state)

        <<255, _rest::binary>> ->
          # Error
          MyXQL.Protocol.decode_generic_response(payload)
          |> handle_db_error(next_seq, state)

        _ ->
          :ok = Database.msg_send(state.client_socket, msg)
          state
      end

    if byte_size(rest) > 0 do
      Logger.error("Extra unhandled DB auth data: #{inspect rest, limit: :infinity}")
    end

    with state when is_map(state) <- result do
      :ok = Database.socket_active(state.db_socket)
      {:noreply, state, @timeout}
    end
  end

  @impl Database
  def client_recv(msg, state = %{client_socket: %Socket{state: :ready}}) do
    state = handle_client_com(msg, state)
    :ok = Database.msg_send(state.db_socket, msg)
    :ok = Database.socket_active(state.client_socket)
    {:noreply, state}
  end

  @impl Database
  def client_recv(<<len::uint3, seq, payload::binary-size(len), rest::binary>>, state) do
    next_seq = seq + 1

    if byte_size(rest) > 0 do
      Logger.error("Extra unhandled client data: #{inspect rest, limit: :infinity}")
    end

    case handle_client_auth(payload, next_seq, state) do
      {:stop, _, _} = resp -> resp
      state -> {:noreply, state, @timeout}
    end
  end

  @impl Database
  def client_recv(_, state) do
    Logger.info("Unexpected message sent from unauthenticated client")
    Database.close_proxy(state)
  end

  def handle_client_auth(
    <<_flags::32-little, _max_pkt::32-little, _charset, _filler::binary-size(23)>>,
    _seq,
    state = %{client_socket: %Socket{state: {:fast_auth, _}}}
  ) do
    # SSLRequest
    %Socket{transport: :ranch_tcp, socket: socket, state: sock_state} = state.client_socket
    case :ranch_ssl.handshake(socket, state.server_ssl_opts, @timeout) do
      {:ok, ssl_sock} ->
        Logger.debug("Switched client socket to SSL")
        socket = %Socket{transport: :ranch_ssl, socket: ssl_sock, state: sock_state}
        :ok = Database.socket_active(socket)
        %{state | client_socket: socket}

      err ->
        Logger.error("Failed to upgrade client socket for SSL: #{inspect err}")
        Database.close_proxy(state)
    end
  end

  def handle_client_auth(
    <<flags::32-little, max_pkt::32-little, charset, _filler::binary-size(23), rest::binary>>,
    seq,
    state = %{client_socket: %Socket{state: {:fast_auth, nonce}}}
  ) do
    # HandshakeResponse
    params = %{flags: flags, max_packet_size: max_pkt, charset: charset}
    with {:ok, handshake} <- parse_handshake_response(rest, params) do
      msg = Messages.fast_auth(handshake.plugin)
      |> MyXQL.Protocol.encode_packet(seq, handshake.max_packet_size)
      :ok = Database.msg_send(state.client_socket, msg)
      :ok = Database.socket_active(state.client_socket)
      socket = %{state.client_socket | state: {:full_auth, nonce}}
      %{state | startup_params: handshake, client_socket: socket}
    else
      _ ->
        Logger.error("Failed to parse handshake response, closing proxy")
        Database.close_proxy(state)
    end
  end

  def handle_client_auth(<<2>>, seq, state) do
    # PublicKeyRequest
    pubkey = X509.PublicKey.to_pem(state.public_key)
    [1, pubkey] |> encode_and_send(seq, state.client_socket)
    :ok = Database.socket_active(state.client_socket)
    state
  end

  def handle_client_auth(payload, seq, state = %{client_socket: %Socket{transport: :ranch_ssl}}) do
    # Password in plaintext (only sent over SSL socket)
    {token, ""} = Messages.parse_null_terminated_binary(payload)
    authenticate_client(token, seq, state)
  end

  def handle_client_auth(payload, seq, state = %{client_socket: %Socket{state: {:full_auth, nonce}}}) do
    # Password encrypted with our public key
    {:ok, auth_data} = safe_decrypt(payload, state.private_key)
    auth_len = byte_size(auth_data)
    padded_data = pad_auth_data(nonce, byte_size(nonce), auth_len)
    :crypto.exor(auth_data, padded_data) |> :binary.part(0, auth_len - 1)
    |> authenticate_client(seq, state)
  end

  def handle_client_auth(_, seq, state) do
    Logger.error("Unknown auth message from client")
    Messages.auth_error("Unknown message")
    |> encode_and_send(seq, state.client_socket)
    :ok = Database.socket_active(state.client_socket)
    state
  end

  defp authenticate_client(token, seq, state) do
    db_id = state.startup_params.username
    with {:ok, {org_id, client_id}} <- JumpWire.Proxy.verify_token(token),
         {:ok, client} <- JumpWire.ClientAuth.fetch(org_id, client_id),
           true <- JumpWire.ClientAuth.authorized?(client, db_id),
         {:ok, db} <- JumpWire.GlobalConfig.fetch(:manifests, {org_id, db_id}) do
      JumpWire.Tracer.context(org_id: org_id, manifest: db_id, client: client_id)
      Logger.info("Client successfully authenticated")
      JumpWire.Analytics.proxy_authenticated(org_id, :mysql)
      Messages.ok_msg() |> encode_and_send(seq, state.client_socket)

      state = %{state |
                client_id: client_id,
                client_auth: client,
                client_socket: Map.put(state.client_socket, :state, :ready),
                organization_id: org_id,
                db_manifest: db,
               }
      connect_to_db(db, state)
    else
      err ->
        Logger.warn("Client failed to authenticate: #{inspect err}")
        Messages.auth_error("Authentication failed")
        |> encode_and_send(seq, state.client_socket)
        :ok = Database.socket_active(state.client_socket)
        state
    end
  end

  def handle_client_com("", state), do: state
  def handle_client_com(<<len::uint3, 0, payload::binary-size(len), rest::binary>>, state) do
    state = track_previous_query(state)

    # New command
    state =
      case payload do
        <<3, _rest::binary>> ->
          # COM_QUERY
          %{state | command: {:query, :text}}
          |> with_start_time()

        <<22, _rest::binary>> ->
          # COM_STMT_PREPARE
          %{state | command: nil}
          |> with_start_time()

        <<23, _rest::binary>> ->
          # COM_STMT_EXECUTE
          %{state | command: {:query, :binary}}

        <<25, _statement_id::uint4>> ->
          # COM_STMT_CLOSE
          %{state | command: nil}

        <<25, _statement_id::uint4, _rows::uint4>> ->
          # COM_STMT_FETCH
          # TODO: test this, it will return a multi-resultset
          %{state | command: {:query, :binary}}
          |> with_start_time()

        _ ->
          %{state | command: nil}
      end

    handle_client_com(rest, state)
  end
  def handle_client_com(_msg, state), do: state

  defp safe_decrypt(ciphertext, key) do
    try do
      data = :public_key.decrypt_private(ciphertext, key, rsa_pad: :rsa_pkcs1_oaep_padding)
      {:ok, data}
    rescue
      e in ErlangError ->
        Logger.error(inspect e)
        {:error, e.original}
    end
  end

  # Repeat str as needed and truncate final string to target_len
  # E.g. "foobar", 12 -> "foobarfoobar"
  # E.g. "foobar", 15 -> "foobarfoobarfoo"
  defp pad_auth_data(_auth_data, _len, 0), do: ""
  defp pad_auth_data(auth_data, len, target_len) when len == target_len, do: auth_data
  defp pad_auth_data(auth_data, len, target_len) when len > target_len do
    :binary.part(auth_data, 0, target_len)
  end
  defp pad_auth_data(auth_data, len, target_len) do
    auth_data <> pad_auth_data(auth_data, len, target_len - len)
  end

  defp parse_handshake_response(data, params = %{flags: flags}) do
    with {username, data} <- Messages.parse_null_terminated_binary(data) do
      {auth_resp, data} =
      if Flags.has_capability_flag?(flags, :client_plugin_auth_lenenc_client_data) do
        Messages.parse_length_encoded(data)
      else
        <<len, auth_resp::binary-size(len), rest::binary>> = data
        {auth_resp, rest}
      end

      {database, data} =
      if Flags.has_capability_flag?(flags, :client_connect_with_db) do
        Messages.parse_null_terminated_binary(data)
      else
        {nil, data}
      end

      {client_plugin_name, data} =
      if Flags.has_capability_flag?(flags, :client_plugin_auth) do
        Messages.parse_null_terminated_binary(data)
      else
        {nil, data}
      end

      {client_attrs, _data} =
      if Flags.has_capability_flag?(flags, :client_connect_attrs) do
        Messages.parse_length_encoded(data)
      else
        {"", data}
      end
      client_attrs = parse_client_attrs(client_attrs)

      parsed = %{
        attrs: client_attrs,
        plugin: client_plugin_name,
        database: database,
        auth_resp: auth_resp,
        username: username,
      } |> Map.merge(params)
      {:ok, parsed}
    else
      _ -> :error
    end
  end

  defp handle_db_ok(_ok, _next_seq, state = %{db_socket: %Socket{state: :ready}}), do: state
  defp handle_db_ok(_ok, _next_seq, state) do
    Logger.info("Authenticated to upstream server")
    :ok = Database.socket_active(state.client_socket)
    socket = Socket.set_state(state.db_socket, :ready)
    %{state | db_socket: socket}
  end

  defp handle_db_error(_error, _next_seq, state = %{db_socket: %Socket{state: :ready}}), do: state
  defp handle_db_error(error, _next_seq, state) do
    Logger.info("Error authenticating to upstream server: #{inspect error}")
    Database.close_proxy(state)
  end

  defp send_handshake_response(payload, state) do
    config = MyXQL.Client.Config.new(state.db_opts)
    sequence_number = 1

    with Records.initial_handshake() = hs <- MyXQL.Protocol.decode_initial_handshake(payload),
         {:ok, flags} <- MyXQL.Protocol.build_capability_flags(config, hs) do
      # Ensure that :client_deprecate_eof is never set. Parsing of resultsets will fail if it
      # is, since binary rows and OK packets are difficult to distinguish.
      flags = MySQL.Messages.unset_capability_flag(flags, :client_deprecate_eof)
      Records.initial_handshake(auth_plugin_name: auth_name, auth_plugin_data: auth_data) = hs

      case ssl_request(flags, sequence_number, state) do
        {:ok, seq, state} ->
          Logger.debug("Sending handshake response to upstream server")
          auth_resp = MyXQL.Protocol.Auth.auth_response(config, auth_name, auth_data)
          Messages.handshake_response(config, flags, auth_resp)
          |> encode_and_send(seq, state.db_socket)
          socket = Map.put(state.db_socket, :state, {:fast_auth, auth_data})
          %{state | db_socket: socket}

        {:error, reason} ->
          Logger.error("Failed to establish SSL connection: #{inspect reason}")
          Database.close_proxy(state)
      end
    else
      err ->
        Logger.error("Error sending handshake response: #{inspect err}")
        Database.close_proxy(state)
    end
  end

  defp ssl_request(flags, sequence_number, state) do
    if MyXQL.Protocol.Flags.has_capability_flag?(flags, :client_ssl) do
      Logger.debug("Sending SSL request to upstream server")
      Messages.ssl_request(flags)
      |> encode_and_send(sequence_number, state.db_socket)

      case :ssl.connect(state.db_socket.socket, state.db_opts[:ssl_opts], @timeout) do
        {:ok, ssl_sock} ->
          Logger.debug("Established SSL connection to MySQL")
          socket = %Socket{transport: :ssl, socket: ssl_sock, state: state.db_socket.state}
          state = %{state | db_socket: socket}
          :ok = Database.socket_active(state.db_socket)
          {:ok, sequence_number + 1, state}

        err -> err
      end
    else
      {:ok, sequence_number, state}
    end
  end

  defp perform_full_auth(seq, state = %{db_socket: %Socket{transport: :ssl, state: {:fast_auth, auth_data}}}) do
    [state.db_opts[:password], 0]
    |> encode_and_send(seq, state.db_socket)
    socket = Socket.set_state(state.db_socket, {:full_auth, auth_data})
    %{state | db_socket: socket}
  end
  defp perform_full_auth(seq, state = %{db_socket: %Socket{state: {:fast_auth, auth_data}}}) do
    # request public key
    encode_and_send(<<2>>, seq, state.db_socket)
    socket = Socket.set_state(state.db_socket, {:full_auth, auth_data})
    %{state | db_socket: socket}
  end
  defp perform_full_auth(_seq, state) do
    Logger.error("Unexpected request to start full auth flow")
    Database.close_proxy(state)
  end

  defp handle_auth_more_data(seq, public_key, state = %{db_socket: %Socket{state: {:full_auth, auth_data}}}) do
    MyXQL.Protocol.Auth.encrypt_sha_password(state.db_opts[:password], public_key, auth_data)
    |> encode_and_send(seq, state.db_socket)
    state
  end
  defp handle_auth_more_data(_seq, _data, state) do
    Logger.error("Unexpected AuthMoreData packet received")
    Database.close_proxy(state)
  end

  defp handle_auth_switch_request(data, seq, state) do
    {auth_name, data} = Messages.parse_null_terminated_binary(data)
    {auth_data, ""} = Messages.parse_null_terminated_binary(data)
    Logger.debug("Authenticating with #{auth_name} to upstream server")
    config = MyXQL.Client.Config.new(state.db_opts)
    MyXQL.Protocol.Auth.auth_response(config, auth_name, auth_data)
    |> encode_and_send(seq, state.db_socket)
    %{state | db_auth: {:fast_auth, auth_data}}
  end

  defp parse_client_attrs(data), do: parse_client_attrs(data, %{})
  defp parse_client_attrs(<<>>, acc), do: acc
  defp parse_client_attrs(data, acc) do
    {key, data} = Messages.parse_length_encoded(data)
    {value, data} = Messages.parse_length_encoded(data)
    acc = Map.put(acc, key, value)
    parse_client_attrs(data, acc)
  end

  defp encode_and_send(payload, seq, socket) do
    msg = MyXQL.Protocol.encode_packet(payload, seq, @max_packet_size)
    :ok = Database.msg_send(socket, msg)
  end

  defp track_previous_query(state = %{start_time: nil}), do: state
  defp track_previous_query(state = %{stop_time: nil}), do: state

  # Unlike the Postgres implementation, for MySQL we need to track the query time once the
  # next query executes. This is necessary because, in the event of a multi-resultset in a
  # stored procedure, I was unable to deterministically figure out when the execution actually
  # finished. In Postgres, we have the `ReadyForQuery` message that can be used for this purpose.
  # If you want to try it yourself, play around with the following query:
  # https://dev.mysql.com/doc/internals/en/multi-resultset.html (archive link in commit history)
  defp track_previous_query(state = %{start_time: start, stop_time: stop}) do
    telemetry_tags = %{
      client: state.client_id,
      database: state.db_manifest.configuration["database"],
      organization: state.organization_id
    }

    :telemetry.execute([:database, :client], %{duration: stop - start, count: 1}, telemetry_tags)
    %{state | start_time: nil, stop_time: nil}
  end

  defp with_start_time(state), do: %{state | start_time: System.monotonic_time(:microsecond)}
end
