defmodule JumpWire.Proxy.Postgres do
  @moduledoc """
  Proxy incoming TCP connections to a PostgreSQL server.

  An initial socket is opened for the client connecting to the proxy. Once
  the client sends a StartupMessage, the params params are parsed and stored
  in the GenServer state. The proxy responds with an authentication request.

  ## Authentication

  The username sent does not matter, but the password is expected to be a
  Phoenix.Token with a manifest ID encoded. The ID will be matched against
  known JumpWire auth manifests to find the client classification.
  Assuming one is found, a second socket is established to the
  upstream postgres database.

  Currently MD5 and SASL with SCRAM-SHA-256 are the only supported authentication
  challenges from the postgres server.

  ## Normal flow

  After the client and database authentication, most messages are simply
  passed from one socket to the other. A termination of either end will
  also cause the other socket to be closed.

  TODOs:
  - swap gen_tcp with DBConnection for better error handling
  - reconnect on timeouts
  """

  use JumpWire.Proxy.Database, manifest_type: :postgresql
  require Postgrex.Messages
  alias JumpWire.Proxy.Postgres.Messages
  alias JumpWire.Proxy.Database
  alias JumpWire.Proxy.SQL.Parser

  @impl Database
  def init(state) do
    Map.put(state, :types, Postgrex.Types.new(Postgrex.DefaultTypes))
  end

  @impl Database
  def db_recv(<<?R, 12::32, 5::32, salt::binary-4>>, state = %{db_socket: %Socket{state: :init}, db_opts: upstream}) do
    # AuthenticationMD5Password

    inner_hash = :crypto.hash(:md5, upstream[:password] <> upstream[:username]) |> Base.encode16() |> String.downcase()
    hash = :crypto.hash(:md5, inner_hash <> salt) |> Base.encode16() |> String.downcase()
    body = <<"md5"::binary, hash::binary, 0>>
    len = byte_size(body) + 4
    msg = <<?p, len::32, body::binary>>
    :ok = Database.msg_send(state.db_socket, msg)
    :ok = Database.socket_active(state.db_socket)
    {:noreply, state, @timeout}
  end

  @impl Database
  def db_recv(<<?R, _len::32, 10::32, data::binary>>, state = %{db_socket: %Socket{state: :init}}) do
    # AuthenticationSASL

    mechanisms = data
    |> :binary.bin_to_list()
    |> Stream.chunk_by(fn x -> x == 0 end)
    |> Stream.chunk_every(2)
    |> Enum.map(fn [key, _,] -> :binary.list_to_bin(key) end)

    nonce = :crypto.strong_rand_bytes(18) |> Base.encode64(padding: false)

    if "SCRAM-SHA-256" in mechanisms do
      :ok = Database.msg_send(state.db_socket, Messages.sasl_initial_response(nonce))
    else
      Logger.warn("Received a SASL auth request without any supported mechanisms")
    end

    :ok = Database.socket_active(state.db_socket)
    {:noreply, state, @timeout}
  end

  @impl Database
  def db_recv(<<?R, _len::32, 11::32, data::binary>>, state = %{db_socket: %Socket{state: :init}, db_opts: upstream}) do
    # AuthenticationSASLContinue

    password = upstream[:password]
    [[_, nonce], _, proof] = Postgrex.SCRAM.verify(data, [password: password])

    :ok = Database.msg_send(state.db_socket, Messages.sasl_response(nonce, proof))
    :ok = Database.socket_active(state.db_socket)
    {:noreply, state, @timeout}
  end

  @impl Database
  def db_recv(<<?R, len::32, 12::32, rest::binary>>, state = %{db_socket: %Socket{state: :init}}) do
    # AuthenticationSASLFinal
    sasl_size = len - 8
    <<_sasl_data::binary-size(sasl_size), rest::binary>> = rest
    db_recv(rest, state)
  end

  @impl Database
  def db_recv(<<?R, 8::integer-32, 0::32, msg::binary>>, state = %{db_socket: %Socket{state: :init}}) do
    # AuthenticationOk, possibly more frames
    Logger.debug("Authenticated to upstream postgresql")
    session_id = JumpWire.Events.database_client_connected(state.metadata)

    :ok = Database.socket_active(state.db_socket)
    state = state
    |> Map.update!(:metadata, fn m -> Map.put(m, :session_id, session_id) end)
    |> Map.update!(:db_socket, fn s -> Socket.set_state(s, :ready) end)
    |> forward_auth_ready(msg)
    |> flush_queue()

    {:noreply, state}
  end

  @impl Database
  def db_recv(<<?N>>, state = %{db_socket: %Socket{ssl: ssl}})
  when ssl in [:require, :verify] do
    # SSLResponse
    Logger.warn("SSL required but not supported by the server")
    Database.close_proxy(state)
  end

  @impl Database
  def db_recv(<<?S>>, state = %{db_socket: %Socket{socket: socket}, db_opts: opts}) do
    # SSLResponse
    case :ssl.connect(socket, opts[:ssl_opts], @timeout) do
      {:ok, ssl_sock} ->
        Logger.debug("Established SSL connection to postgres")
        msg = Messages.startup_message(state.startup_params)

        socket = %Socket{transport: :ssl, socket: ssl_sock, state: state.db_socket.state}
        :ok = Database.msg_send(socket, msg)
        :ok = Database.socket_active(socket)
        {:noreply, %{state | db_socket: socket}}

      {:error, reason} ->
        Logger.error("Failed to establish SSL connection: #{inspect reason}")
        Database.close_proxy(state)
    end
  end

  @impl Database
  def db_recv(data, state) do
    # handle data coming from postgres
    data = state.db_buffer <> data
    state = parse_message(data, state)
    :ok = Database.socket_active(state.db_socket)
    {:noreply, state}
  end

  defp set_query_start_time(state) do
    # If we already started the timer, keep the previous value.
    # This is used in the extended protocol, e.g. on the Bind or Execute messages
    case state.start_time do
      nil -> %{state | start_time: System.monotonic_time(:microsecond)}
      _ -> state
    end
  end

  @impl Database
  def client_recv(data, state = %{client_buffer: b}) when is_binary(b) do
    # concat the incoming data with the buffer and process it
    data = state.client_buffer <> data
    state = %{state | client_buffer: nil}
    client_recv(data, state)
  end

  @impl Database
  def client_recv(data = <<?Q, len::integer-32, rest::binary>>, state) do
    # Query (simple protocol)
    state = set_query_start_time(state)

    query_size = len - 5
    # TODO: recursively handle the remaining data

    # the size of `rest` should be one byte larger than the query size
    # (for the terminating null byte).
    # any larger and there are more commands to process
    # any smaller and part of the query is missing - likely coming in
    # another TCP packet
    if byte_size(rest) > query_size do
      <<query::binary-size(query_size), 0, _other::binary>> = rest
      parse_client_query(:simple, query, data, state)
    else
      :ok = Database.socket_active(state.client_socket)
      {:noreply, %{state | client_buffer: data}, @timeout}
    end
  end

  @impl Database
  def client_recv(data = <<?P, len::integer-32, rest::binary>>, state) do
    # Parse (extended protocol)
    state = set_query_start_time(state)
    query_size = len - 7

    # the size of `rest` should be one byte larger than the query size
    # (for the terminating null byte).
    # any larger and there are more commands to process
    # any smaller and part of the query is missing - likely coming in
    # another TCP packet
    if byte_size(rest) > query_size do
      <<query::binary-size(query_size), 0, params::binary>> = rest

      # the query is the name of the prepared statement followed by the query.
      [prepared_statement_name, query] = :binary.split(query, <<0>>)
      query_info = {:parse, prepared_statement_name, params}

      # TODO: parse the prepared statement if it exists
      # TODO: parse params based on num_params
      # TODO: recursively handle the remaining data

      parse_client_query(query_info, query, data, state)
    else
      :ok = Database.socket_active(state.client_socket)
      {:noreply, %{state | client_buffer: data}, @timeout}
    end
  end

  @impl Database
  def client_recv(data, state = %{db_socket: %Socket{state: :ready}}) do
    # handle data coming from a client
    :ok = Database.msg_send(state.db_socket, data)
    :ok = Database.socket_active(state.client_socket)
    {:noreply, state}
  end

  @impl Database
  def client_recv(<<8::32, 1234::16, 5679::16>>, state) do
    # SSLRequest
    Logger.debug("Negotiating client SSL connection")
    with %Socket{socket: socket, transport: :ranch_tcp, state: :init} <- state.client_socket,
         :ok <- Database.msg_send(state.client_socket, "S"),
         {:ok, socket} <- :ranch_ssl.handshake(socket, state.server_ssl_opts, @timeout),
         client_socket <- %Socket{transport: :ranch_ssl, socket: socket},
         :ok <- Database.socket_active(client_socket) do
      {:noreply, %{state | client_socket: client_socket}, @timeout}
    else
      err ->
        Logger.error("Unable to establish client SSL connection: #{inspect err}")
        Database.close_proxy(state)
    end
  end

  @impl Database
  def client_recv(<<?p, len::integer-32, data::binary>>, state) do
    # PasswordMessage
    token_size = len - 5
    <<token::binary-size(token_size), 0>> = data

    state =
      with {:ok, {org_id, client_id}} <- JumpWire.Proxy.verify_token(token),
           {:ok, client} <- JumpWire.ClientAuth.fetch(org_id, client_id),
             %{"user" => db_id} <- state.startup_params,
           {:ok, state} <- client_authenticated(client, org_id, db_id, state) do
        JumpWire.Tracer.context(client: client_id)
        Logger.debug("Found client for postgresql token")
        JumpWire.Analytics.proxy_authenticated(org_id, :postgresql)
        state
      else
        _ ->
          Logger.warn("Invalid authentication token provided")
          Database.msg_send(state.client_socket, Messages.failed_auth_error())
          state
      end

    :ok = Database.socket_active(state.client_socket)
    {:noreply, state, @timeout}
  end

  @impl Database
  def client_recv(<<_len::integer-32, 0, 3, _minor::integer-16, data::binary>>, state) do
    # StartupMessage
    params = parse_startup_params(data)
    state = %{state | startup_params: params}
    nonce = Uniq.UUID.uuid4()
    JumpWire.Tracer.context(client: nonce)

    # If the user is likely a human and does not have
    # pregenerated credentials, we create a magic login link.
    # To avoid an unneeded auth flow and password prompt, we check
    # if the username is a UUID (and thus probably using clientauth
    # credentials).
    with {:ok, username} <- Map.fetch(params, "user"),
         :error <- Ecto.UUID.dump(username) do

      # Create a message directing the user to visit the web interface if one is connected, or
      # approving the authentication atttempt with jwctl otherwise
      auth_msg =
        case JumpWire.Websocket.generate_token(nonce, "postgresql", state.organization_id) do
          {:ok, url} -> "Authenticate by visiting:\n    #{url}"
          _ ->
            token = JumpWire.API.Token.sign_jit_auth_request(nonce, :postgresql)
            "Authenticate with jwctl:\n\njwctl db login #{token}"
        end

      Logger.debug("Generated client magic login")

      :ok = Database.msg_send(state.client_socket, Messages.authentication_ok())
      :ok = Database.msg_send(state.client_socket, Messages.passwordless_auth(auth_msg))
      socket = Map.put(state.client_socket, :state, {:auth, :blocked})
      :ok = Database.socket_active(socket)
      {:noreply, %{state | client_id: nonce, client_socket: socket}}
    else
      _ ->
        :ok = Database.msg_send(state.client_socket, Messages.authentication_cleartext_password())
        :ok = Database.socket_active(state.client_socket)
        {:noreply, state, @timeout}
    end
  end

  @impl Database
  def client_recv(_msg, state) do
    Logger.info("Unexpected message sent from unauthenticated client")
    Database.close_proxy(state)
  end

  @impl Database
  def client_authenticated(client, org_id, db_id, state) do
    with true <- JumpWire.ClientAuth.authorized?(client, db_id),
         {:ok, db} <- JumpWire.Manifest.fetch(org_id, db_id) do
      JumpWire.Tracer.context(org_id: org_id, client: client.id)
      state = %{state |
                organization_id: org_id,
                client_auth: client,
                client_id: client.id,
                db_manifest: db}
      {:ok, connect_to_db(db, state)}
    end
  end

  defp query_statements_to_requests(statements) do
    Enum.reduce_while(statements, {:ok, []}, fn {statement, ref}, {_, requests} ->
      case Parser.to_request(statement) do
        {:ok, request} ->
          request = %{request | source: ref}
          {:cont, {:ok, [request | requests]}}

        _ -> {:halt, :error}
      end
    end)
  end

  defp parse_client_query(query_info, query, data, state = %{flags: %{parse_requests: true}}) do
    with {:ok, statements} <- Parser.parse_postgresql(query),
         {:ok, requests} <- query_statements_to_requests(statements) do
      handle_client_query(requests, query_info, state)
    else
      err ->
        Logger.warn("Unable to parse PostgreSQL statement: #{inspect err}")
        :ok = Database.msg_send(state.db_socket, data)
        :ok = Database.socket_active(state.client_socket)
        {:noreply, state}
    end
  end
  defp parse_client_query(_query_info, _query, data, state) do
    :ok = Database.msg_send(state.db_socket, data)
    :ok = Database.socket_active(state.client_socket)
    {:noreply, state}
  end

  @spec handle_client_query(
    [JumpWire.Proxy.Request.t()],
    :simple | {:parse, binary(), binary()},
    Database.state()
  ) :: {:noreply, Database.state()}
  def handle_client_query(requests, query_info, state) do
    result = Enum.reduce_while(requests, {:ok, []}, fn req, {:ok, acc} ->
      _handle_request(req, acc, state)
    end)

    case result do
      {:ok, iolist} ->
        data = Messages.query(query_info, iolist)
        :ok = Database.msg_send(state.db_socket, data)
        :ok = Database.socket_active(state.client_socket)
        {:noreply, state}

      {:error, err} ->
        Database.msg_send(state.client_socket, err)
        :ok = Database.socket_active(state.client_socket)
        {:noreply, state}
    end
  end

  defp _handle_request(request, acc, state) do
    case apply_request_policies(request, state) do
      {:ok, _request, ref} ->
        case Parser.to_sql(ref) do
          {:ok, sql} -> {:cont, {:ok, [acc, sql]}}
          err -> {:halt, err}
        end

      err -> {:halt, err}
    end
  end

  defp parse_startup_params(data) do
    # will contains keys such as database and user
    data
    |> :binary.bin_to_list()
    |> Stream.chunk_by(fn x -> x == 0 end)
    |> Stream.chunk_every(4)
    |> Stream.map(fn [key, _, value, _] ->
      {:binary.list_to_bin(key), :binary.list_to_bin(value)}
    end)
    |> Stream.flat_map(fn
      {"user", value} ->
        case String.split(value, "#", parts: 2) do
          [user, jw_id] ->
            [{"user", user}, {"jw_id", Database.sanitize_id(jw_id)}]

          _ -> [{"user", value}]
        end
      x -> [x]
    end)
    |> Map.new()
  end

  @doc """
  Create Postgrex params from a manifest.
  """
  @impl Database
  def params_from_manifest(manifest = %Manifest{root_type: :postgresql}) do
    JumpWire.Proxy.Postgres.Setup.postgrex_params(manifest.configuration, manifest.credentials, manifest.organization_id)
  end

  defp connect_to_db(nil, state) do
    Logger.debug("Waiting for query before connecting to upstream DB")

    ready_msg = [
      Messages.default_parameter_status(),
      # TODO: figure out how to send valid BackendKeyData
      Messages.ready_for_query(),
    ]

    state = forward_auth_ready(state, ready_msg)
    :ok = Database.socket_active(state.client_socket)
    state
  end

  defp connect_to_db(manifest = %Manifest{id: id}, state) do
    state = Database.close_db_socket(state)
    JumpWire.Tracer.context(manifest: id)
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

    # update with manifest username/database
    # TODO: is this the right thing to do if the startup_params and manifest db don't match?
    startup_params = state.startup_params
    |> Map.put("user", db_opts[:username])
    |> Map.put("database", db_opts[:database])

    msg = if db_opts[:ssl] do
      Messages.ssl_request()
    else
      Messages.startup_message(startup_params)
    end

    ssl_mode = if db_opts[:ssl], do: :verify, else: nil
    socket = %Socket{transport: :ranch_tcp, socket: db_socket, ssl: ssl_mode}
    Database.msg_send(socket, msg)

    metadata = %{
      client_id: state.client_id,
      identity_id: state.client_auth.identity_id,
      db_id: id,
      manifest_id: id,
      organization_id: state.organization_id,
      attributes: MapSet.new(["*"]),
    }

    %{state |
      db_socket: socket,
      startup_params: startup_params,
      db_opts: db_opts,
      metadata: metadata}
  end

  def parse_message("", state), do: %{state | db_buffer: ""}
  def parse_message(<<tag, len::integer-32, rest::binary>> = msg, state) do
    data_size = len - 4

    case rest do
      <<data::binary-size(data_size), rest::binary>> ->
        {res, state} = handle_message(tag, len, data, state)
        :ok = Database.msg_send(state.client_socket, res)

        parse_message(rest, state)

      _ ->
        %{state | db_buffer: msg}
    end
  end
  def parse_message(msg, state), do: %{state | db_buffer: msg}

  defp handle_message(tag = ?T, len, data, state = %{flags: %{parse_responses: true}}) do
    {:msg_row_desc, fields} = Postgrex.Messages.parse(data, tag, len)
    # For each field description, find the original column name (undoing
    # any aliases in the SELECT statement) and labels based on that name.
    # The aliased field info is sent to the client without modification.
    {labels, tables, aliases} = fields
    |> Stream.map(fn field = Postgrex.Messages.row_field(name: alias_name, table_oid: oid) ->
      {column_name, labels} = get_field_labels(field, state)
      {alias_name, {labels, oid, column_name}}
    end)
    |> Enum.reduce({[], Map.new(), Map.new}, fn {alias_name, {labels, oid, column_name}}, {label_list, table_map, aliases_map} ->
      {[{alias_name, labels} | label_list], Map.put(table_map, alias_name, oid), Map.put(aliases_map, alias_name, column_name)}
    end)
    # NOTE that order matters for labels! Labels and fields list must be consistent
    # with each other
    labels = Enum.reverse(labels)

    policies = JumpWire.Policy.list_all(state.organization_id)
    msg = [tag, <<len::integer-32>>, data]
    {msg, %{state | fields: {labels, tables, aliases}, policies: policies}}
  end

  defp handle_message(?D, len, raw = <<_num_cols::integer-16, data::binary>>, state = %{flags: %{parse_responses: true}}) do
    {labels, tables, aliases} = state.fields
    case state.policies do
      [] -> {[?D, <<len::integer-32>>, raw], state}

      policies ->
        data
        |> decode_fields(labels, tables, aliases)
        |> apply_response_policies(policies, labels, ?D, state)
    end
  end

  defp handle_message(tag = ?Z, len, data, state = %{start_time: nil}) do
    msg = <<tag, len::integer-32, data::binary>>
    state = %{state | policy_error: false}
    {msg, state}
  end

  defp handle_message(tag = ?Z, len, data, state = %{start_time: start_time}) do
    duration = System.monotonic_time(:microsecond) - start_time

    telemetry_tags = %{
      client: state.client_id,
      database: state.db_manifest.configuration["database"],
      organization: state.organization_id
    }

    :telemetry.execute([:database, :client], %{duration: duration, count: 1}, telemetry_tags)
    msg = <<tag, len::integer-32, data::binary>>
    state = %{state | policy_error: false, start_time: nil}
    {msg, state}
  end

  defp handle_message(?C, _len, _data, state = %{policy_error: true}) do
    # Send a generic error to force psql (and probably other ORMs) to fail
    # If we just pass on the CommandComplete message, any errors sent while processing
    # data rows will be ignored.
    {Messages.internal_error(), state}
  end

  defp handle_message(?C, _len, data, state) do
    # CommandComplete message
    # INSERT commands have a tag of `INSERT oid rows`. Everything else is `command rows`
    # For non-SELECT completions, we just pass along the the value
    # reported by postgres and ignore our internal counter.
    # We don't have an accurate count of rows for INSERTs, and
    # can probably never have a count for UPDATEs.
    data =
      case String.split(data, " ") do
        ["SELECT", _rows] -> "SELECT #{state.row_count}" <> <<0>>
        _ -> data
      end

    len = byte_size(data) + 4  # length includes itself
    msg = <<?C, len::integer-32, data::binary>>
    {msg, %{state | row_count: 0}}
  end

  defp handle_message(tag, len, data, state) do
    msg = <<tag, len::integer-32, data::binary>>
    {msg, state}
  end

  defp decode_fields(data, labels, tables, aliases) do
    decode_fields(data, labels, tables, aliases, {%{}, %{}})
  end
  defp decode_fields(<<>>, _, tables, aliases, {data, data_labels}) do
    attr = data_labels |> Map.values() |> List.flatten() |> Stream.map(fn l -> "select:#{l}" end) |> MapSet.new()

    %Record{
      data: data,
      labels: data_labels,
      source: "postgres",
      label_format: :key,
      extra_field_info: %{tables: tables, aliases: aliases},
      attributes: attr,
    }
  end
  defp decode_fields(
    <<255, 255, 255, 255, rest::binary>>,
    [{name, labels} | fields],
    tables,
    aliases,
    {data, data_labels}
  ) do
    data = Map.put(data, name, nil)
    data_labels =
      case labels do
        [] -> data_labels
        _ -> Map.put(data_labels, name, labels)
      end
    decode_fields(rest, fields, tables, aliases, {data, data_labels})
  end
  defp decode_fields(
    <<len::integer-32, field::binary-size(len), rest::binary>>,
    [{name, labels} | fields],
    tables,
    aliases,
    {data, data_labels}
  ) do
    labels = Record.load_labels(field, labels)
    data_labels =
      case labels do
        [] -> data_labels
        _ -> Map.put(data_labels, name, labels)
      end
    data = Map.put(data, name, field)
    decode_fields(rest, fields, tables, aliases, {data, data_labels})
  end

  @doc """
  Lookup a JumpWire schema that matches the postgres row description and return the
  associated field labels.
  """
  def get_field_labels(Postgrex.Messages.row_field(column: column, table_oid: table_oid, name: name), state) do
    case Database.fetch_tables(state.organization_id, state.db_manifest.id) do
      {:ok, {_tables, schemas}} ->
        schemas
        |> Map.get(table_oid, %{})
        |> Map.get(column, {name, []})

      _ -> {name, []}
    end
  end

  defp encode_row_field(name, data) do
    case Map.get(data, name) do
      nil ->
        <<-1::integer-32>>

      value ->
        len = byte_size(value)
        [<<len::integer-32>>, value]
    end
  end

  @doc """
  Apply policies to an incoming request, which might be trying
  to access labeled data but may or may not have any new data set in
  the request.
  """
  @spec apply_request_policies(JumpWire.Proxy.Request.t(), Database.state())
  :: {:ok, JumpWire.Proxy.Request.t(), binary()} | {:error, binary()}
  def apply_request_policies(request, state) do
    policies = JumpWire.Policy.list_all(state.organization_id)
    record = request_to_record(request, state)

    case Database.apply_policies(record, policies, state) do
      :blocked ->
        request_blocked(record, state)

      {:error, err} ->
        Logger.error("Error applying policy: #{inspect err}")
        {:error, [Messages.policy_error(err), Messages.ready_for_query()]}

      %Record{source_data: data} ->
        JumpWire.Events.database_accessed(record.attributes, state.metadata)
        {:ok, request, data}
    end
  end

  defp request_to_record(request, state = %{db_manifest: %{id: db_id, configuration: config}}) do
    org_id = state.organization_id

    schemas =
      case Database.fetch_tables(org_id, db_id) do
        {:ok, schemas} -> schemas
        _ -> {%{}, %{}}
      end

    default_namespace = Map.get(config, "schema", "public")

    %Record{
      data: %{},
      labels: %{},
      source: "postgres",
      source_data: request.source,
      label_format: :key,
    }
    |> merge_request_field_labels(request.select, :select, schemas, default_namespace)
    |> merge_request_field_labels(request.update, :update, schemas, default_namespace)
    |> merge_request_field_labels(request.delete, :delete, schemas, default_namespace)
    |> merge_request_field_labels(request.insert, :insert, schemas, default_namespace)
  end

  defp request_to_record(request, _state) do
    %Record{
      data: %{},
      labels: %{},
      source: "postgres",
      source_data: request.source,
      label_format: :key,
    }
  end

  defp request_blocked(record, state) do
    JumpWire.Events.database_request_blocked(state.metadata)

    # only take SQL related attributes
    permissions = record.attributes
    |> Stream.filter(fn
      "select:" <> _ -> true
      "insert:" <> _ -> true
      "update:" <> _ -> true
      "delete:" <> _ -> true
      _ -> false
    end)
    |> Enum.to_list()

    msg =
      case JumpWire.Websocket.request_access(state.client_id, state.db_manifest.id, state.organization_id, permissions) do
        {:ok, url} ->
          Logger.info("Requested additional DB access: #{inspect permissions}", client: state.client_id)
          Messages.policy_blocked_error(url)

        _ ->
          Messages.policy_blocked_error()
      end

    {:error, [msg, Messages.ready_for_query()]}
  end

  defp merge_request_field_labels(record, fields, type, {tables, schemas}, default_namespace) do
    fields
    |> Stream.flat_map(fn
      %{column: :wildcard, table: table, schema: namespace} ->
        # Find and return all fields for this table
        namespace = namespace || default_namespace
        Map.get(tables, {namespace, table}, [])

      %{column: col, table: table, schema: namespace} ->
        namespace = namespace || default_namespace
        find_field(tables, namespace, table, col)
    end)
    |> Stream.map(fn field ->
      # find any labels for this field
      schemas
      |> Map.get(field[:id], %{})
      |> Map.get(field[:column_id], {field[:column], []})
    end)
    |> Enum.reduce(record, fn {field, labels}, acc ->
      # update the record based on the fields being accessed
      acc
      |> Map.update!(:data, fn data -> Map.put(data, field, :query) end)
      |> Map.update!(:labels, fn l -> Map.put(l, field, labels) end)
      |> Map.update!(:attributes, fn attr ->
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        Enum.reduce(labels, attr, fn label, attr ->
          MapSet.put(attr, "#{type}:#{label}")
        end)
      end)
    end)
  end

  defp find_field(tables, namespace, table, col) do
    case Map.fetch(tables, {namespace, table}) do
      {:ok, fields} ->
        case Enum.find(fields, fn %{column: name} -> name == col end) do
          nil ->
            Logger.debug("Could not find colummn #{col} in postgres schema for table #{namespace}.#{table}")
            []

          field -> [field]
        end

      _ ->
        Logger.debug("No schema stored for postgres table #{namespace}.#{table}, skipping field mapping")
        []
    end
  end

  defp apply_response_policies(record, policies, fields, tag, state) do
    case Database.apply_policies(record, policies, state) do
      :blocked ->
        {Messages.policy_blocked_error(), state}

      {:error, err} ->
        Logger.error("Error applying policy: #{inspect err}")
        state = %{state | policy_error: true}
        {Messages.policy_error(err), state}

      %Record{} = rec ->
        JumpWire.Events.database_field_accessed(rec, state.metadata)
        # convert the record back into a list of fields, preserving the order
        # that postgres originally used
        data = Enum.map(fields, fn {name, _} ->
          encode_row_field(name, rec.data)
        end)

        state = Map.update!(state, :row_count, fn n -> n + 1 end)

        num = Enum.count(fields)
        len = :erlang.iolist_size(data) + 6
        msg = [tag, <<len::integer-32, num::integer-16>> | data]
        {msg, state}
    end
  end

  @doc """
  Send an AuthenticationOk message from the server to the client if one
  has not already been sent. Afterwards, forward additional messages.
  These are usually ParameterStatus messages followed by a BackendKeyData.

  Since the upstream server can change mid-connection, the startup messages
  should only be passed to the client the first time they are seen.
  """
  def forward_auth_ready(state = %{client_socket: %Socket{state: :init}}, msg) do
    socket = state.client_socket
    auth_msg = Messages.authentication_ok()
    :ok = Database.msg_send(socket, [auth_msg | msg])
    %{state | client_socket: Map.put(socket, :state, :ready)}
  end
  def forward_auth_ready(state = %{client_socket: %Socket{state: {:auth, :blocked}}}, msg) do
    socket = state.client_socket
    :ok = Database.msg_send(socket, msg)
    %{state | client_socket: Map.put(socket, :state, :ready)}
  end
  def forward_auth_ready(state, _state), do: state

  @doc """
  Take all queued messages and push them to the server.
  This is intended to be called when the client has been buffering
  and the server connection is now ready.
  """
  def flush_queue(state = %{queue: []}), do: state
  def flush_queue(state) do
    state.queue
    |> Enum.reverse()
    |> Enum.each(fn msg ->
      :ok = Database.msg_send(state.db_socket, msg)
    end)

    :ok = Database.socket_active(state.client_socket)

    %{state | queue: []}
  end
end
